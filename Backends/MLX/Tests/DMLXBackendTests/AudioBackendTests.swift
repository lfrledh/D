import CryptoKit
import Darwin
import DInference
@testable import DMLXBackend
import Foundation
import Testing

@Suite("AUDIO1 inventory and owned provider process", .serialized)
struct AudioBackendTests {
    @Test("Explicit 48 kHz output must decode while the legacy default remains 44.1 kHz")
    func outputClockIsExplicitAndNegativeFramesThrow() throws {
        let fixture = try AudioFixture()
        defer { fixture.remove() }
        var wave = try Data(contentsOf: fixture.source)
        func replace(_ value: UInt32, at offset: Int) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { wave.replaceSubrange(offset..<(offset + 4), with: $0) }
        }
        replace(48_000, at: 24)
        replace(48_000 * 8, at: 28)
        try wave.write(to: fixture.source)
        let claim = AudioProviderArtifact(path: fixture.source.path,
            sha256: SHA256.hash(data: wave).map { String(format: "%02x", $0) }.joined(),
            byteCount: UInt64(wave.count), frameCount: 44, sampleRate: 48_000,
            channels: 2, encoding: "float32")
        #expect(throws: (any Error).self) {
            _ = try AudioWAV.validateOutput(fixture.source, claim: claim, expectedFrames: 44)
        }
        #expect(try AudioWAV.validateOutput(fixture.source, claim: claim, expectedFrames: 44,
                                           expectedSampleRate: 48_000).url == fixture.source)
        for invalid in [Int64(-1), 0] {
            #expect(throws: (any Error).self) {
                _ = try AudioWAV.validateOutput(fixture.source, claim: claim, expectedFrames: invalid,
                                               expectedSampleRate: 48_000)
            }
        }
    }

    @Test("Each profile uses exactly four weights and the frozen conservative estimate",
          arguments: AudioBackendProfile.allCases)
    func inventoryEstimate(profile: AudioBackendProfile) throws {
        let fixture = try AudioFixture(profile: profile)
        defer { fixture.remove() }
        let inventory = try AudioModelInventory.inspect(
            fixture.request(), configuration: fixture.configuration(profile: profile))
        #expect(inventory.weights.count == 4)
        #expect(inventory.estimatedPeakBytes == 2 * UInt64(fixture.weightSize)
                + 1024 * 1024 * 1024 + 64 * 1024 * 1024)
    }

    @Test("Estimate arithmetic rejects overflow instead of wrapping")
    func estimateOverflow() {
        expectInvalid { _ = try AudioModelInventory.estimate(largestWeight: UInt64.max, durationSeconds: 1) }
    }

    @Test("Inventory rejects profile limits without loading model code")
    func inventoryLimits() throws {
        let fixture = try AudioFixture()
        defer { fixture.remove() }
        for request in [
            fixture.request(seed: UInt64(UInt32.max)),
            fixture.request(steps: 101),
            fixture.request(guidance: 0.99),
            fixture.request(guidance: 15.01),
            fixture.request(duration: 120.001),
        ] {
            expectInvalid { _ = try AudioModelInventory.inspect(request, configuration: fixture.configuration()) }
        }
        _ = try AudioModelInventory.inspect(
            fixture.request(seed: UInt64(UInt32.max) - 1, steps: 100, guidance: 15, duration: 120),
            configuration: fixture.configuration())
    }

    @Test("Manifest parsing rejects corruption, Boolean numerics, extra files, and escaped duplicate keys")
    func manifestStrictness() throws {
        let mutations: [(String) -> String] = [
            { $0.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":true") },
            { $0.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":2") },
            { $0.replacingOccurrences(of: "\"files\":[", with: "\"unknown\":0,\"files\":[") },
            { $0.replacingOccurrences(of: "\"repository\":", with: "\"r\\u0065pository\":\"duplicate\",\"repository\":") },
            { $0.replacingOccurrences(of: "]}", with: ",{\"path\":\"MLX/extra.npz\",\"size\":1,\"sha256\":\"\(String(repeating: "0", count: 64))\"}]}") },
        ]
        for mutate in mutations {
            let fixture = try AudioFixture()
            defer { fixture.remove() }
            try Data(mutate(fixture.manifestText).utf8).write(to: fixture.manifest)
            expectInvalid { _ = try AudioModelInventory.inspect(fixture.request(), configuration: fixture.configuration()) }
        }
    }

    @Test("Missing, replaced, symlink, wrong-size, and overlapping model inputs fail admission")
    func inventoryFilesAndPaths() throws {
        for kind in ["missing", "size", "symlink", "overlap"] {
            let fixture = try AudioFixture()
            defer { fixture.remove() }
            let weight = fixture.model.appendingPathComponent("MLX/dit_sm-music_f16.npz")
            var configuration = fixture.configuration()
            switch kind {
            case "missing": try FileManager.default.removeItem(at: weight)
            case "size": try Data("different-size".utf8).write(to: weight)
            case "symlink":
                try FileManager.default.removeItem(at: weight)
                try FileManager.default.createSymbolicLink(
                    at: weight, withDestinationURL: fixture.model.appendingPathComponent("MLX/t5gemma_f16.npz"))
            default:
                configuration = fixture.configuration(artifactDirectory: fixture.model)
            }
            expectInvalid { _ = try AudioModelInventory.inspect(fixture.request(), configuration: configuration) }
        }
    }

    @Test("Source clock, duration, regular-file identity, digest, and WAV metadata are independently checked")
    func sourceValidation() throws {
        let fixture = try AudioFixture()
        defer { fixture.remove() }
        let valid = try fixture.editRequest(operation: .variation)
        _ = try AudioModelInventory.inspect(valid, configuration: fixture.configuration())
        _ = try AudioWAV.validateSource(fixture.source, reference: try #require(valid.audio?.source))

        expectInvalid {
            _ = try AudioModelInventory.inspect(try fixture.editRequest(operation: .variation, sampleRate: 48_000),
                                                configuration: fixture.configuration())
        }
        expectInvalid {
            _ = try AudioModelInventory.inspect(try fixture.editRequest(operation: .variation, frames: 43),
                                                configuration: fixture.configuration())
        }
        let badDigest = AudioSourceReference(url: fixture.source, sha256: String(repeating: "0", count: 64),
                                             frameCount: 44, sampleRate: 44_100, channels: 2)
        #expect(throws: (any Error).self) { _ = try AudioWAV.validateSource(fixture.source, reference: badDigest) }
    }

    @Test("Frame conversion uses ties-to-even and edit output is source-sized")
    func frameRoundingAndSourceBoundary() async throws {
        let fixture = try AudioFixture()
        defer { fixture.remove() }
        expectInvalid {
            _ = try AudioModelInventory.inspect(
                fixture.request(duration: 0.5 / 44_100), configuration: fixture.configuration())
        }
        _ = try AudioModelInventory.inspect(
            fixture.request(duration: 2.5 / 44_100), configuration: fixture.configuration())
        _ = try AudioModelInventory.inspect(
            try fixture.editRequest(operation: .variation, duration: 44.5 / 44_100),
            configuration: fixture.configuration())
        expectInvalid {
            _ = try AudioModelInventory.inspect(
                try fixture.editRequest(operation: .variation, duration: 44.500_001 / 44_100),
                configuration: fixture.configuration())
        }
        let backend = try MLXAudioBackend(configuration: fixture.configuration())
        let generation = try await backend.execute(fixture.request(duration: 2.5 / 44_100)) { _ in }
        await backend.release()
        #expect(generation.artifacts.count == 1)
        let result = try await backend.execute(
            try fixture.editRequest(operation: .variation, duration: 44.5 / 44_100)) { _ in }
        await backend.release()
        #expect(result.artifacts.count == 1)
    }

    @Test("Protocol numbers compare semantically without losing UInt64 and never treat Boolean as numeric")
    func protocolNumberSemantics() throws {
        var integers = AudioJSONParser(
            data: Data(#"{"value":18446744073709551615}"#.utf8), maximumDepth: 8)
        var adjacent = AudioJSONParser(
            data: Data(#"{"value":18446744073709551614}"#.utf8), maximumDepth: 8)
        let large = try integers.parse()
        let preceding = try adjacent.parse()
        #expect(large != preceding)

        var oneInteger = AudioJSONParser(data: Data(#"{"value":1}"#.utf8), maximumDepth: 8)
        var oneFloat = AudioJSONParser(data: Data(#"{"value":1.0}"#.utf8), maximumDepth: 8)
        let integerValue = try oneInteger.parse()
        let floatValue = try oneFloat.parse()
        #expect(integerValue == floatValue)
        var boolean = AudioJSONParser(data: Data(#"{"value":true}"#.utf8), maximumDepth: 8)
        #expect(try integerValue != boolean.parse())
    }

    @Test("Malformed, symlinked, and special source files fail before child launch",
          arguments: ["malformed", "symlink", "fifo"])
    func unsafeSource(kind: String) throws {
        let fixture = try AudioFixture()
        defer { fixture.remove() }
        let digest: String
        switch kind {
        case "malformed":
            let data = Data("not-wave".utf8)
            try data.write(to: fixture.source)
            digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        case "symlink":
            let target = fixture.root.appendingPathComponent("target.wav")
            try FileManager.default.copyItem(at: fixture.source, to: target)
            try FileManager.default.removeItem(at: fixture.source)
            try FileManager.default.createSymbolicLink(at: fixture.source, withDestinationURL: target)
            let data = try Data(contentsOf: target)
            digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        default:
            try FileManager.default.removeItem(at: fixture.source)
            #expect(Darwin.mkfifo(fixture.source.path, 0o600) == 0)
            digest = String(repeating: "0", count: 64)
        }
        let source = AudioSourceReference(url: fixture.source, sha256: digest, frameCount: 44,
                                          sampleRate: 44_100, channels: 2)
        let request = InferenceRequest(
            model: ModelReference(directory: fixture.model,
                                  revision: AudioBackendConfiguration.registeredModelRevision),
            input: .audio(AudioRequest(operation: .variation, prompt: "valid", durationSeconds: 0.001,
                                       seed: 42, steps: 8, source: source)))
        if kind == "malformed" {
            _ = try AudioModelInventory.inspect(request, configuration: fixture.configuration())
            #expect(throws: (any Error).self) { _ = try AudioWAV.validateSource(fixture.source, reference: source) }
        } else {
            expectInvalid { _ = try AudioModelInventory.inspect(request, configuration: fixture.configuration()) }
        }
    }

    @Test("Missing license acknowledgement creates no run or child")
    func licenseGate() async throws {
        let fixture = try AudioFixture()
        defer { fixture.remove() }
        let denied = AudioBackendConfiguration(
            pythonExecutable: URL(fileURLWithPath: "/usr/bin/python3"), providerScript: fixture.script,
            vendorDirectory: fixture.vendor, modelManifest: fixture.manifest,
            artifactDirectory: fixture.artifacts, profile: .smMusic)
        let backend = try MLXAudioBackend(configuration: denied)
        do { _ = try await backend.execute(fixture.request()) { _ in }; Issue.record("License gate was bypassed") }
        catch InferenceFailure.invalidRequest {} catch { Issue.record("Unexpected license failure: \(error)") }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.artifacts.path).isEmpty)
    }

    @Test("Valid fixture drains, validates float32 WAV, emits once, and survives release",
          .timeLimit(.minutes(1)))
    func validProcess() async throws {
        let fixture = try AudioFixture()
        defer { fixture.remove() }
        let backend = try MLXAudioBackend(configuration: fixture.configuration())
        let request = fixture.request(prompt: "stderr")
        let recorder = AudioEventRecorder()
        let result = try await backend.execute(request) { await recorder.append($0) }
        await backend.release()
        let events = await recorder.snapshot()
        let artifact = try #require(result.artifacts.first)
        #expect(FileManager.default.fileExists(atPath: artifact.url.path))
        #expect(events.contains(.progress(completed: 1, total: 2)))
        #expect(events.contains(.artifact(artifact)))
        #expect(result.metadata["profile"] == "sm-music")
        #expect(result.metadata["modelRevision"] == AudioBackendConfiguration.registeredModelRevision)
        #expect(FileManager.default.fileExists(atPath: try #require(result.metadata["recordPath"])))
    }

    @Test("Progress is delivered while the child lives with independently drained pipes",
          .timeLimit(.minutes(1)), arguments: ["silent-stderr", "large-stderr"])
    func liveProgressWithIndependentPipeDrain(mode: String) async throws {
        let fixture = try AudioFixture()
        defer { fixture.remove() }
        let acknowledgement = fixture.root.appendingPathComponent("progress-ack-\(mode)")
        let backend = try MLXAudioBackend(configuration: fixture.configuration(timeout: 6))
        let recorder = AudioEventRecorder()
        let prompt = "live-progress-\(mode)|\(acknowledgement.path)"

        let result: InferenceResult
        do {
            result = try await backend.execute(fixture.request(prompt: prompt)) { output in
                await recorder.append(output)
                if output == .progress(completed: 1, total: 2) {
                    try Data("acknowledged\n".utf8).write(to: acknowledgement, options: .withoutOverwriting)
                }
            }
        } catch {
            await backend.release()
            throw error
        }
        await backend.release()

        let events = await recorder.snapshot()
        let progressIndex = try #require(events.firstIndex(of: .progress(completed: 1, total: 2)))
        let artifactIndex = try #require(events.firstIndex {
            if case .artifact = $0 { true } else { false }
        })
        #expect(FileManager.default.fileExists(atPath: acknowledgement.path))
        #expect(progressIndex < artifactIndex)
        #expect(result.artifacts.count == 1)
    }

    @Test("Malformed, stale, wrong-run, duplicate-terminal, nonzero, WAV, hash, and metadata failures drain",
          .timeLimit(.minutes(1)),
          arguments: ["malformed", "long-line", "excess-stdout", "missing-terminal", "stale", "wrong-run",
                      "duplicate", "nonzero", "bad-wav", "bad-hash", "bad-metadata"])
    func controlledFailures(mode: String) async throws {
        let fixture = try AudioFixture()
        defer { fixture.remove() }
        let backend = try MLXAudioBackend(configuration: fixture.configuration())
        await expectBackendFailure { try await backend.execute(fixture.request(prompt: mode)) { _ in } }
        await backend.release()
        // Failed provider runs remain for diagnostics and release never scans or deletes them.
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.artifacts.path).count == 1)
    }

    @Test("Independent metadata validation rejects request and provenance corruption in both result copies",
          .timeLimit(.minutes(1)),
          arguments: ["bad-request-prompt", "bad-request-seed", "bad-request-boolean",
                      "bad-source-digest", "bad-profile", "bad-revision", "bad-precision",
                      "bad-weight-hash"])
    func metadataCounterexamples(mode: String) async throws {
        let fixture = try AudioFixture()
        defer { fixture.remove() }
        let backend = try MLXAudioBackend(configuration: fixture.configuration())
        let request = mode == "bad-source-digest"
            ? try fixture.editRequest(operation: .variation, prompt: mode)
            : fixture.request(prompt: mode)
        await expectBackendFailure { try await backend.execute(request) { _ in } }
        await backend.release()
    }

    @Test("Incomplete inpaint metadata fails without trapping and permits the next task",
          .timeLimit(.minutes(1)), arguments: ["missing-requested-region", "missing-effective-region"])
    func incompleteInpaintMetadata(mode: String) async throws {
        let fixture = try AudioFixture(frames: 8192)
        defer { fixture.remove() }
        let sourceBefore = try Data(contentsOf: fixture.source)
        let backend = try MLXAudioBackend(configuration: fixture.configuration())
        let request = try fixture.editRequest(operation: .inpaint, prompt: mode,
                                             frames: 8192, duration: 8192.0 / 44_100.0)
        await expectBackendFailure { try await backend.execute(request) { _ in } }
        await backend.release()
        #expect(try Data(contentsOf: fixture.source) == sourceBefore)
        let next = try await backend.execute(fixture.request()) { _ in }
        await backend.release()
        #expect(next.artifacts.count == 1)
    }

    @Test("Partially available MLX measurements retain null unknown values")
    func partialMeasurementMetadata() async throws {
        let fixture = try AudioFixture()
        defer { fixture.remove() }
        let backend = try MLXAudioBackend(configuration: fixture.configuration())
        let result = try await backend.execute(fixture.request(prompt: "partial-measurements")) { _ in }
        await backend.release()
        #expect(result.artifacts.count == 1)
    }

    @Test("Semantically equal integer and decimal result snapshots are accepted")
    func semanticResultCopies() async throws {
        let fixture = try AudioFixture()
        defer { fixture.remove() }
        let backend = try MLXAudioBackend(configuration: fixture.configuration())
        let result = try await backend.execute(fixture.request(prompt: "semantic-number")) { _ in }
        await backend.release()
        #expect(result.artifacts.count == 1)
    }

    @Test("Throwing emit terminates only the owned child and releases the shared lease",
          .timeLimit(.minutes(1)))
    func emitFailureThenNextJob() async throws {
        let fixture = try AudioFixture()
        defer { fixture.remove() }
        let backend = try MLXAudioBackend(configuration: fixture.configuration())
        await expectBackendFailure {
            try await backend.execute(fixture.request(prompt: "slow-after-progress")) { _ in
                throw FixtureError.consumer
            }
        }
        await backend.release()
        let result = try await backend.execute(fixture.request(prompt: "valid")) { _ in }
        await backend.release()
        #expect(result.artifacts.count == 1)
    }

    @Test("Cancellation drains before lease handoff and permits the next job",
          .timeLimit(.minutes(1)))
    func cancellationThenNextJob() async throws {
        let fixture = try AudioFixture()
        defer { fixture.remove() }
        let backend = try MLXAudioBackend(configuration: fixture.configuration())
        let running = Task { try await backend.execute(fixture.request(prompt: "slow")) { _ in } }
        try await Task.sleep(for: .milliseconds(150))
        running.cancel()
        do { _ = try await running.value; Issue.record("Cancelled child completed") }
        catch is CancellationError {}
        catch { Issue.record("Expected CancellationError, received \(error)") }
        await backend.release()
        let result = try await backend.execute(fixture.request(prompt: "valid")) { _ in }
        await backend.release()
        #expect(result.artifacts.count == 1)
    }

    @Test("Timeout escalates from TERM to owned-PID KILL and fully drains",
          .timeLimit(.minutes(1)))
    func timeoutIgnoringTERM() async throws {
        let fixture = try AudioFixture()
        defer { fixture.remove() }
        let backend = try MLXAudioBackend(configuration: fixture.configuration(timeout: 0.1, grace: 0.1))
        await expectBackendFailure(containing: "timed out") {
            try await backend.execute(fixture.request(prompt: "ignore-term")) { _ in }
        }
        await backend.release()
    }

    @Test("Private access transport uses a static cwd and cleans after successful or failed child",
          .timeLimit(.minutes(1)))
    func privateAccessTransport() async throws {
        for mode in ["valid", "nonzero", "ignore-term"] {
            let fixture = try AudioFixture()
            defer { fixture.remove() }
            let bootstrap = fixture.root.appendingPathComponent("private-access")
            try FileManager.default.createDirectory(at: bootstrap, withIntermediateDirectories: false)
            try fixture.installAccessAssertions()
            let originalSource = try Data(contentsOf: fixture.source)
            let backend = try MLXAudioBackend(configuration: fixture.accessConfiguration(
                root: bootstrap, timeout: mode == "ignore-term" ? 0.2 : 5))
            if mode == "valid" {
                let result = try await backend.execute(fixture.request()) { _ in }
                #expect(result.artifacts.count == 1)
            } else {
                do { _ = try await backend.execute(fixture.request(prompt: mode)) { _ in }; Issue.record("Expected child failure") }
                catch {}
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: bootstrap.path).isEmpty)
            #expect(try Data(contentsOf: fixture.source) == originalSource)
            await backend.release()
        }
    }

    @Test("Cancellation removes private access only after the child stops and next run works",
          .timeLimit(.minutes(1)))
    func privateAccessCancellation() async throws {
        let fixture = try AudioFixture(); defer { fixture.remove() }
        let bootstrap = fixture.root.appendingPathComponent("private-access")
        try FileManager.default.createDirectory(at: bootstrap, withIntermediateDirectories: false)
        try fixture.installAccessAssertions()
        let backend = try MLXAudioBackend(configuration: fixture.accessConfiguration(root: bootstrap))
        let started = AudioEventRecorder()
        let task = Task {
            try await backend.execute(fixture.request(prompt: "slow")) { await started.append($0) }
        }
        for _ in 0..<100 {
            if !(await started.snapshot()).isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!(await started.snapshot()).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: bootstrap.path).count == 1)
        task.cancel()
        do { _ = try await task.value; Issue.record("Expected cancellation") }
        catch is CancellationError {} catch { Issue.record("Unexpected cancellation result: \(error)") }
        #expect(try FileManager.default.contentsOfDirectory(atPath: bootstrap.path).isEmpty)
        await backend.release()
        _ = try await backend.execute(fixture.request()) { _ in }
        await backend.release()
        #expect(try FileManager.default.contentsOfDirectory(atPath: bootstrap.path).isEmpty)
    }

    @Test("Dynamic model acknowledgement and deployment failure reject before creating run data")
    func applicationAdmissionChecks() async throws {
        let fixture = try AudioFixture(); defer { fixture.remove() }
        let bootstrap = fixture.root.appendingPathComponent("private-access")
        try FileManager.default.createDirectory(at: bootstrap, withIntermediateDirectories: false)
        let denied = try MLXAudioBackend(configuration: fixture.accessConfiguration(
            root: bootstrap, acknowledged: false, check: { false }))
        do { _ = try await denied.execute(fixture.request()) { _ in }; Issue.record("Expected acknowledgement refusal") }
        catch InferenceFailure.invalidRequest {} catch { Issue.record("Unexpected error: \(error)") }
        await denied.release()
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.artifacts.path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: bootstrap.path).isEmpty)
        let invalid = try MLXAudioBackend(configuration: fixture.accessConfiguration(
            root: bootstrap, deployment: { throw FixtureError.consumer }))
        do { _ = try await invalid.execute(fixture.request()) { _ in }; Issue.record("Expected deployment refusal") }
        catch {}
        await invalid.release()
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.artifacts.path).isEmpty)
        try fixture.installAccessAssertions()
        let granted = try MLXAudioBackend(configuration: fixture.accessConfiguration(
            root: bootstrap, acknowledged: false, check: { true }))
        _ = try await granted.execute(fixture.request()) { _ in }
        await granted.release()
        #expect(try FileManager.default.contentsOfDirectory(atPath: bootstrap.path).isEmpty)
    }

    @Test("Provider cannot mutate protected source/model and publications survive release",
          .timeLimit(.minutes(1)))
    func protectedInputsAndPublication() async throws {
        let fixture = try AudioFixture()
        defer { fixture.remove() }
        let sourceBefore = try Data(contentsOf: fixture.source)
        let weight = fixture.model.appendingPathComponent("MLX/dit_sm-music_f16.npz")
        let weightBefore = try Data(contentsOf: weight)
        let backend = try MLXAudioBackend(configuration: fixture.configuration())
        let result = try await backend.execute(try fixture.editRequest(operation: .variation)) { _ in }
        await backend.release()
        #expect(try Data(contentsOf: fixture.source) == sourceBefore)
        #expect(try Data(contentsOf: weight) == weightBefore)
        #expect(FileManager.default.fileExists(atPath: try #require(result.artifacts.first).url.path))
    }
}

private enum FixtureError: Error { case consumer }

private actor AudioEventRecorder {
    private var events: [InferenceOutput] = []
    func append(_ event: InferenceOutput) { events.append(event) }
    func snapshot() -> [InferenceOutput] { events }
}

private struct AudioFixture {
    let root: URL
    let model: URL
    let vendor: URL
    let artifacts: URL
    let source: URL
    let script: URL
    let manifest: URL
    let manifestText: String
    let weightSize: Int

    init(profile: AudioBackendProfile = .smMusic, frames: Int = 44) throws {
        let parent = ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
        root = parent.resolvingSymlinksInPath().appendingPathComponent("D-audio-fixture-\(UUID().uuidString)")
        model = root.appendingPathComponent("model")
        vendor = root.appendingPathComponent("vendor")
        artifacts = root.appendingPathComponent("artifacts")
        source = root.appendingPathComponent("source.wav")
        script = root.appendingPathComponent("fake-provider.py")
        manifest = root.appendingPathComponent("manifest.json")
        let fixtureWeightSize = 257
        try FileManager.default.createDirectory(at: model.appendingPathComponent("MLX"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: vendor, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        let names = [
            "dit_sm-music_f16.npz", "dit_sm-sfx_f16.npz", "dit_medium_f16.npz",
            "t5gemma_f16.npz", "same_s_encoder_f32.npz", "same_s_decoder_f32.npz",
            "same_l_encoder_f32.npz", "same_l_decoder_f32.npz",
        ]
        for name in names {
            try Data(repeating: UInt8(name.utf8.first!), count: fixtureWeightSize)
                .write(to: model.appendingPathComponent("MLX/\(name)"))
        }
        let digest = String(repeating: "a", count: 64)
        let dit: String
        switch profile {
        case .smMusic: dit = "dit_sm-music_f16.npz"
        case .smSFX: dit = "dit_sm-sfx_f16.npz"
        case .medium: dit = "dit_medium_f16.npz"
        }
        let codec = profile == .medium ? "same_l" : "same_s"
        let files = [dit, "t5gemma_f16.npz", "\(codec)_encoder_f32.npz", "\(codec)_decoder_f32.npz"].map {
            "{\"path\":\"MLX/\($0)\",\"size\":\(fixtureWeightSize),\"sha256\":\"\(digest)\"}"
        }.joined(separator: ",")
        manifestText = "{\"schemaVersion\":1,\"repository\":\"stabilityai/stable-audio-3-optimized\",\"revision\":\"\(AudioBackendConfiguration.registeredModelRevision)\",\"files\":[\(files)]}"
        weightSize = fixtureWeightSize
        try Data(manifestText.utf8).write(to: manifest)
        try Self.floatWAV(frames: frames).write(to: source)
        try Data(Self.providerScript.utf8).write(to: script)
    }

    func configuration(profile: AudioBackendProfile = .smMusic,
                       artifactDirectory: URL? = nil, timeout: Double = 10,
                       grace: Double = 0.2) -> AudioBackendConfiguration {
        AudioBackendConfiguration(
            pythonExecutable: URL(fileURLWithPath: "/usr/bin/python3"), providerScript: script,
            vendorDirectory: vendor, modelManifest: manifest,
            artifactDirectory: artifactDirectory ?? artifacts, profile: profile,
            licenseAcknowledged: true, timeoutSeconds: timeout, cancellationGraceSeconds: grace)
    }

    func accessConfiguration(root: URL, timeout: Double = 5, acknowledged: Bool = true,
                             check: (@Sendable () async -> Bool)? = nil,
                             deployment: (@Sendable () throws -> Void)? = nil) -> AudioBackendConfiguration {
        AudioBackendConfiguration(pythonExecutable: URL(fileURLWithPath: "/usr/bin/python3"),
            providerScript: script, vendorDirectory: vendor, modelManifest: manifest,
            artifactDirectory: artifacts, profile: .smMusic, licenseAcknowledged: acknowledged,
            timeoutSeconds: timeout, cancellationGraceSeconds: 0.1,
            accessBootstrapRoot: root, confirmDeployment: deployment, modelUseAcknowledged: check)
    }

    func installAccessAssertions() throws {
        var body = try String(contentsOf: script, encoding: .utf8)
        body = body.replacingOccurrences(of: "a=p.parse_args()", with: #"""
for flag in ('access-manifest','access-run-id','access-source-directory'):
    p.add_argument('--'+flag)
a=p.parse_args()
assert a.access_manifest and a.access_run_id
assert os.getcwd() == os.path.dirname(a.access_manifest)
assert os.stat(a.access_manifest).st_mode & 0o777 == 0o600
with open(a.access_manifest,'r',encoding='utf-8') as f: capability=json.load(f)
assert capability['runID']==a.access_run_id
assert {item['path'] for item in capability['grants']} == {a.model_directory,os.path.dirname(a.request)}
assert all(item['bookmark'] for item in capability['grants'])
"""#)
        try Data(body.utf8).write(to: script)
    }

    func request(prompt: String = "valid", seed: UInt64 = 42, steps: Int = 8,
                 guidance: Float = 1, duration: Double = 0.001) -> InferenceRequest {
        InferenceRequest(model: ModelReference(directory: model,
                                                revision: AudioBackendConfiguration.registeredModelRevision),
                         input: .audio(AudioRequest(operation: .generate, prompt: prompt,
                                                    durationSeconds: duration, seed: seed,
                                                    steps: steps, guidanceScale: guidance)))
    }

    func editRequest(operation: AudioOperation, prompt: String = "valid", sampleRate: Int = 44_100,
                     frames: Int64 = 44, duration: Double = 0.001) throws -> InferenceRequest {
        let data = try Data(contentsOf: source)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let reference = AudioSourceReference(url: source, sha256: digest, frameCount: frames,
                                             sampleRate: sampleRate, channels: 2)
        let region = operation == .inpaint ? AudioEditRegion(startFrame: 1, endFrame: frames) : nil
        return InferenceRequest(
            model: ModelReference(directory: model, revision: AudioBackendConfiguration.registeredModelRevision),
            input: .audio(AudioRequest(operation: operation, prompt: prompt, durationSeconds: duration,
                                       seed: 42, steps: 8, source: reference, editRegion: region)))
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    private static func floatWAV(frames: Int) -> Data {
        var result = Data("RIFF".utf8)
        append(UInt32(36 + frames * 8), to: &result)
        result.append(Data("WAVEfmt ".utf8)); append(UInt32(16), to: &result)
        append(UInt16(3), to: &result); append(UInt16(2), to: &result)
        append(UInt32(44_100), to: &result); append(UInt32(44_100 * 8), to: &result)
        append(UInt16(8), to: &result); append(UInt16(32), to: &result)
        result.append(Data("data".utf8)); append(UInt32(frames * 8), to: &result)
        for _ in 0..<(frames * 2) { append(Float(0).bitPattern, to: &result) }
        return result
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    private static let providerScript = #"""
import argparse, hashlib, json, math, os, signal, struct, sys, time
p=argparse.ArgumentParser()
for name in ('request','job-directory','model-directory','profile','manifest','vendor-directory'):
    p.add_argument('--'+name, required=True)
a=p.parse_args()
with open(a.request,'r',encoding='utf-8') as f: r=json.load(f)
if 'HOME' in os.environ: print('{"unexpected":"HOME"}'); sys.exit(2)
mode=r['prompt']
run=r['runID']
if mode=='malformed': print('{'); sys.exit(0)
if mode=='long-line': print('x'*(2*1024*1024+1)); sys.exit(0)
if mode=='excess-stdout': sys.stdout.write('x'*(16*1024*1024+1)); sys.stdout.flush(); sys.exit(0)
if mode=='nonzero': print(json.dumps({'schemaVersion':1,'type':'error','runID':run,'kind':'engine','message':'fixture failure'})); sys.exit(1)
ack_path=None
if mode.startswith('live-progress-'):
    mode,ack_path=mode.split('|',1)
    time.sleep(0.2)
print(json.dumps({'schemaVersion':1,'type':'progress','runID':run,'phase':'validating','completed':1,'total':2}),flush=True)
if mode=='live-progress-large-stderr':
    sys.stderr.buffer.write(b'e'*(512*1024))
    sys.stderr.buffer.flush()
if ack_path is not None:
    deadline=time.monotonic()+2.0
    while not os.path.exists(ack_path) and time.monotonic()<deadline: time.sleep(0.01)
    if not os.path.exists(ack_path):
        print('progress acknowledgement timed out',file=sys.stderr,flush=True)
        sys.exit(3)
if mode=='missing-terminal': sys.exit(0)
if mode=='slow-after-progress': time.sleep(5)
if mode=='slow': time.sleep(5)
if mode=='ignore-term':
    signal.signal(signal.SIGTERM, lambda *_: None)
    time.sleep(5)
if mode=='stderr': print('fixture diagnostic only',file=sys.stderr,flush=True)
frames=r.get('source',{}).get('frameCount',round(r['durationSeconds']*44100))
pcm=b''.join(struct.pack('<f',0.0) for _ in range(frames*2))
wav=b'RIFF'+struct.pack('<I',36+len(pcm))+b'WAVEfmt '+struct.pack('<IHHIIHH',16,3,2,44100,352800,8,32)+b'data'+struct.pack('<I',len(pcm))+pcm
if mode=='bad-wav': wav=b'not a wave'
out=os.path.join(a.job_directory,'output.wav')
with open(out,'xb') as f: f.write(wav)
sha=hashlib.sha256(wav).hexdigest()
artifact={'path':out,'sha256':sha,'byteCount':len(wav),'frameCount':frames,'sampleRate':44100,'channels':2,'encoding':'float32'}
if mode=='stale': artifact['path']=os.path.join(a.job_directory,'..','stale.wav')
if mode=='bad-hash': artifact['sha256']='0'*64
if mode=='bad-metadata': artifact['frameCount']=frames+1
with open(a.manifest,'r',encoding='utf-8') as f: manifest=json.load(f)
snapshot=json.loads(json.dumps(r))
if 'source' in snapshot: snapshot['source'].pop('path',None)
metadata={
    'request':snapshot,
    'profile':a.profile,
    'modelRepository':'stabilityai/stable-audio-3-optimized',
    'modelRevision':manifest['revision'],
    'weightManifest':manifest['files'],
    'vendorRevision':'779434a908193105335fd8d833418603625b2859',
    'precision':{'dit':'float16','text':'float16','encoder':'float32','decoder':'float32','master':'float32'},
    'timingsSeconds':{'fixture':0.0},
    'mlxAllocations':{'measurementKind':'unavailable','measurementPhase':'notMeasured',
                      'activeBytes':None,'cacheBytes':None,'peakBytes':None},
}
if 'source' in r:
    metadata['sourceSampleEncoding']='float32'
    metadata['sourceToMasterConversion']='IEEE-float32-preserved'
if r['operation']=='variation':
    metadata['variationGuarantee']='approximate reference; no exact melody guarantee'
if r['operation']=='inpaint':
    region=r['editRegion']
    latent_count=max(1,math.ceil(r['durationSeconds']*44100/4096))
    metadata['requestedRegionFrames']={'startFrame':region['startFrame'],'endFrame':region['endFrame']}
    metadata['effectiveLatentRegion']={'start':max(0,round(region['startFrame']/4096)),
                                       'end':min(latent_count,round(region['endFrame']/4096))}
    metadata['inpaintBoundaryPolicy']='no-crossfade; exact float32 source conversion outside requested frames'
if mode=='missing-requested-region': metadata.pop('requestedRegionFrames',None)
if mode=='missing-effective-region': metadata.pop('effectiveLatentRegion',None)
if mode=='partial-measurements':
    metadata['mlxAllocations'].update(measurementKind='partial-mlx-allocator',activeBytes=1,observedActiveLowerBoundBytes=1)
if mode=='bad-request-prompt': metadata['request']['prompt']='corrupted'
if mode=='bad-request-seed': metadata['request']['seed']=metadata['request']['seed']+1
if mode=='bad-request-boolean': metadata['request']['seed']=True
if mode=='bad-source-digest': metadata['request']['source']['sha256']='0'*64
if mode=='bad-profile': metadata['profile']='sm-sfx'
if mode=='bad-revision': metadata['modelRevision']='wrong-revision'
if mode=='bad-precision': metadata['precision']['dit']='float32'
if mode=='bad-weight-hash': metadata['weightManifest'][0]['sha256']='0'*64
event={'schemaVersion':1,'type':'result','runID':run,'artifact':artifact,'metadata':metadata}
with open(os.path.join(a.job_directory,'result.json'),'x',encoding='utf-8') as f: json.dump(event,f,separators=(',',':'))
if mode=='wrong-run': event['runID']='00000000-0000-0000-0000-000000000000'
if mode=='semantic-number': event['metadata']['request']['seed']=42.0
print(json.dumps(event,separators=(',',':')),flush=True)
if mode=='duplicate': print(json.dumps(event,separators=(',',':')),flush=True)
"""#
}

private extension InferenceRequest {
    var audio: AudioRequest? { if case .audio(let value) = input { value } else { nil } }
}

private func expectInvalid(_ operation: () throws -> Void) {
    do { try operation(); Issue.record("Invalid audio fixture was accepted") }
    catch InferenceFailure.invalidRequest {} catch { Issue.record("Expected invalidRequest, received \(error)") }
}

private func expectBackendFailure(containing text: String? = nil,
                                  _ operation: () async throws -> InferenceResult) async {
    do { _ = try await operation(); Issue.record("Provider fixture unexpectedly succeeded") }
    catch InferenceFailure.backendFailed(let reason) {
        if let text { #expect(reason.contains(text)) }
    } catch { Issue.record("Expected backendFailed, received \(error)") }
}
