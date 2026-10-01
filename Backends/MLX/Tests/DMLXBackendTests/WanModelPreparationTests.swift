import DInference
import Foundation
import Testing
@testable import DMLXBackend

@Suite("Wan offline preparation bridge (bounded CPU process fixtures)", .serialized)
struct WanModelPreparationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["D_TEST_WAN_PREPARE_ENGINE"] != nil),
          .timeLimit(.minutes(30)))
    func originalWeightsThroughPackagedPreparationBridge() async throws {
        let env = ProcessInfo.processInfo.environment
        let engine = URL(fileURLWithPath: try #require(env["D_TEST_WAN_PREPARE_ENGINE"]))
        let source = URL(fileURLWithPath: try #require(env["D_TEST_WAN_ORIGINAL_DIR"]))
        let destination = URL(fileURLWithPath: try #require(env["D_TEST_WAN_PREPARED_OUTPUT"]))
        let root = URL(fileURLWithPath: try #require(env["D_TEST_TEMP_DIR"]))
        let names = ["models_t5_umt5-xxl-enc-bf16.pth", "diffusion_pytorch_model.safetensors", "Wan2.1_VAE.pth"]
        func identity() throws -> [AudioFileSystem.Identity] {
            try names.map { try AudioFileSystem.regularFile(source.appendingPathComponent($0), label: $0, maximumBytes: nil) }
        }
        let before = try identity(), started = Date()
        let access = root.appendingPathComponent("wan-real-access-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: access, withIntermediateDirectories: false)
        let bridge = try WanModelPreparation(configuration: .init(
            pythonExecutable: engine.appendingPathComponent("python/bin/python3"),
            providerScript: engine.appendingPathComponent("provider/d_video_prepare.py"),
            accessBootstrapRoot: access, timeoutSeconds: 1_700))
        try await bridge.prepare(source: source, destination: destination)
        try #require(identity() == before)
        try #require(FileManager.default.contentsOfDirectory(atPath: access.path).isEmpty)
        let token = UUID()
        try await MLXExecutionLease.shared.acquire(token)
        await MLXExecutionLease.shared.relinquish(token)
        let data = try Data(contentsOf: destination.appendingPathComponent("D-VIDEO-PREPARED.json"))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        try #require(object["complete"] as? Bool == true)
        try #require((object["tensors"] as? [Any])?.count == 1_261)
        let result: [String: Any] = ["seconds": Date().timeIntervalSince(started), "source": source.path,
            "destination": destination.path, "engine": engine.path, "originalIdentitiesUnchanged": true,
            "sharedPermitReacquired": true, "manifestBytes": data.count]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("wan-real-bridge.json"), options: .withoutOverwriting)
    }

    @Test func deadlinesAndExistingDestination() async throws {
        let fixture = try Fixture(mode: "success")
        #expect(throws: InferenceFailure.self) {
            _ = try WanModelPreparation(configuration: fixture.configuration(timeout: .infinity))
        }
        let destination = fixture.root.appendingPathComponent("existing")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let sentinel = destination.appendingPathComponent("keep")
        try Data("keep".utf8).write(to: sentinel)
        let bridge = try WanModelPreparation(configuration: fixture.configuration())
        await #expect(throws: InferenceFailure.self) {
            try await bridge.prepare(source: fixture.source, destination: destination)
        }
        #expect(try Data(contentsOf: sentinel) == Data("keep".utf8))
    }

    @Test func successAndFailureDrainPermit() async throws {
        for mode in ["success", "failure", "invalid", "invalid-bool"] {
            let fixture = try Fixture(mode: mode)
            let bridge = try WanModelPreparation(configuration: fixture.configuration())
            let destination = fixture.root.appendingPathComponent("prepared")
            if mode == "success" {
                try await bridge.prepare(source: fixture.source, destination: destination)
                #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("D-VIDEO-PREPARED.json").path))
            } else {
                await #expect(throws: InferenceFailure.self) {
                    try await bridge.prepare(source: fixture.source, destination: destination)
                }
                if mode == "failure" { #expect(!FileManager.default.fileExists(atPath: destination.path)) }
            }
            #expect(try Data(contentsOf: fixture.source.appendingPathComponent("original")) == Data("original".utf8))
            let token = UUID()
            try await MLXExecutionLease.shared.acquire(token)
            await MLXExecutionLease.shared.relinquish(token)
        }
    }

    @Test func drainedAccessCleanupFailureReleasesPermit() async throws {
        let fixture = try Fixture(mode: "access-failure")
        let bridge = try WanModelPreparation(configuration: fixture.configuration(access: true))
        do {
            try await bridge.prepare(source: fixture.source,
                                     destination: fixture.root.appendingPathComponent("prepared"))
            Issue.record("Expected owned access cleanup failure")
        } catch {
            #expect(error.localizedDescription.contains("access cleanup"))
        }
        let bootstrap = try FileManager.default.contentsOfDirectory(atPath: fixture.accessRoot.path)
        #expect(bootstrap.count == 1)
        #expect(FileManager.default.fileExists(atPath: fixture.accessRoot.appendingPathComponent(bootstrap[0]).appendingPathComponent("unknown").path))
        let token = UUID()
        try await MLXExecutionLease.shared.acquire(token)
        await MLXExecutionLease.shared.relinquish(token)
    }

    @Test func preCancelledDoesNotLaunch() async throws {
        let fixture = try Fixture(mode: "success")
        let bridge = try WanModelPreparation(configuration: fixture.configuration())
        let destination = fixture.root.appendingPathComponent("cancelled")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await bridge.prepare(source: fixture.source, destination: destination)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func timeoutAndCancellationDrainOwnedChild() async throws {
        let timeout = try Fixture(mode: "wait")
        let timedBridge = try WanModelPreparation(configuration: timeout.configuration(timeout: 0.2))
        await #expect(throws: InferenceFailure.self) {
            try await timedBridge.prepare(source: timeout.source, destination: timeout.root.appendingPathComponent("timed"))
        }
        let cancellation = try Fixture(mode: "wait")
        let bridge = try WanModelPreparation(configuration: cancellation.configuration())
        let task = Task { try await bridge.prepare(source: cancellation.source,
                                                   destination: cancellation.root.appendingPathComponent("cancelled")) }
        let started = cancellation.source.appendingPathComponent("started")
        let deadline = ContinuousClock.now + .seconds(5)
        while !FileManager.default.fileExists(atPath: started.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: started.path))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let token = UUID()
        try await MLXExecutionLease.shared.acquire(token)
        await MLXExecutionLease.shared.relinquish(token)
    }
}

private struct Fixture {
    let root: URL
    let source: URL
    let script: URL
    let accessRoot: URL

    init(mode: String) throws {
        let parent = try #require(ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"])
        root = URL(fileURLWithPath: parent).appendingPathComponent("wan-bridge-" + UUID().uuidString)
        source = root.appendingPathComponent("originals")
        script = root.appendingPathComponent("fixture.py")
        accessRoot = URL(fileURLWithPath: parent).appendingPathComponent("wan-access-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: accessRoot, withIntermediateDirectories: false)
        try Data("original".utf8).write(to: source.appendingPathComponent("original"))
        for (name, size) in [("models_t5_umt5-xxl-enc-bf16.pth", UInt64(11_361_920_418)),
                             ("diffusion_pytorch_model.safetensors", UInt64(5_676_070_424)),
                             ("Wan2.1_VAE.pth", UInt64(507_609_880))] {
            let url = source.appendingPathComponent(name)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: size) // Sparse fixture; no model bytes are written.
            try handle.close()
        }
        let code = "mode = " + String(reflecting: mode) + "\n" + #"""
import hashlib, json, pathlib, sys, time
def option(name): return pathlib.Path(sys.argv[sys.argv.index(name) + 1])
source = option('--source'); destination = option('--destination')
if mode == 'access-failure':
    (pathlib.Path.cwd() / 'unknown').write_text('retain')
    sys.exit(7)
if mode == 'failure': sys.exit(7)
if mode == 'wait':
    (source / 'started').write_text('started')
    time.sleep(30)
destination.mkdir()
if mode == 'invalid':
    (destination / 'D-VIDEO-PREPARED.json').write_text(json.dumps({
        'complete': True, 'revision': '37ec512624d61f7aa208f7ea8140a131f93afc9a',
        'tensors': [{'name': 'synthetic'}]}))
    sys.exit(0)
fixed = [
    ('text', 'models_t5_umt5-xxl-enc-bf16.pth', 11361920418, '7cace0da2b446bbbbc57d031ab6cf163a3d59b366da94e5afe36745b746fd81d', 242),
    ('diffusion', 'diffusion_pytorch_model.safetensors', 5676070424, '96b6b242ca1c2f24e9d02cd6596066fab6d310e2d7538f33ae267cb18d957e8f', 825),
    ('vae', 'Wan2.1_VAE.pth', 507609880, '38071ab59bd94681c686fa51d75a1968f64e470262043be31f7a094e442fd981', 194)]
manifest = {'schemaVersion': 1, 'complete': True, 'repository': 'Wan-AI/Wan2.1-T2V-1.3B',
    'revision': '37ec512624d61f7aa208f7ea8140a131f93afc9a',
    'preparation': 'original-names-tensor-shards-v1',
    'precision': {'text': 'BF16', 'diffusion': 'BF16 with original FP32 time/head/modulation/norm tensors', 'vae': 'F32'},
    'originals': [], 'tensors': []}
for role, name, size, digest, count in fixed:
    manifest['originals'].append({'path': name, 'size': size, 'sha256': digest})
    (destination / role).mkdir()
    for index in range(count):
        relative = f'{role}/{index:04d}.safetensors'
        content = b'synthetic fixture'
        (destination / relative).write_bytes(content)
        manifest['tensors'].append({'role': role, 'name': f'tensor_{index}', 'path': relative,
            'shape': [1], 'dtype': 'F32' if role == 'vae' else 'BF16',
            'size': len(content), 'sha256': hashlib.sha256(content).hexdigest()})
if mode == 'invalid-bool': manifest['tensors'][0]['size'] = True
(destination / 'D-VIDEO-PREPARED.json').write_text(json.dumps(manifest))
"""#
        try Data(code.utf8).write(to: script)
    }

    func configuration(timeout: Double = 5, access: Bool = false) -> WanModelPreparationConfiguration {
        .init(pythonExecutable: URL(fileURLWithPath: "/usr/bin/python3"), providerScript: script,
              accessBootstrapRoot: access ? accessRoot : nil,
              timeoutSeconds: timeout, cancellationGraceSeconds: 0.1)
    }
}
