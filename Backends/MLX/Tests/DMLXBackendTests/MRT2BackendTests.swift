import CryptoKit
import Darwin
import DInference
@testable import DMLXBackend
import Foundation
import Testing

@Suite("MRT2 fixed-profile bridge", .serialized)
struct MRT2BackendTests {
    @Test("Public configuration defaults and descriptor are frozen")
    func publicSurface() throws {
        let fixture = try MRT2Fixture()
        defer { fixture.remove() }
        let configuration = fixture.configuration(acknowledged: false)
        #expect(MRT2BackendConfiguration.registeredModelRevision
                == "010aa0dcb0dfd27b24f0ad07b4dad63e8f9521cc")
        #expect(configuration.timeoutSeconds == 600)
        #expect(configuration.cancellationGraceSeconds == 15)
        #expect(configuration.licenseAcknowledged == false)
        let backend = try MLXMRT2Backend(configuration: configuration)
        #expect(backend.descriptor == BackendDescriptor(
            id: "mlx.audio.mrt2", version: "1", capabilities: [.audioGeneration]))
    }

    @Test("Manifest parser requires the exact six-file identity and strict JSON types")
    func manifestStrictness() throws {
        let fixture = try MRT2Fixture()
        defer { fixture.remove() }
        let parsed = try MRT2ModelInventory.parseManifest(fixture.manifestData)
        #expect(parsed.files.count == 6)
        #expect(parsed.license == MRT2ModelInventory.recordedLicense)

        let source = String(decoding: fixture.manifestData, as: UTF8.self)
        let mutations: [(String) -> String] = [
            { $0.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":true") },
            { $0.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":1.0") },
            { $0.replacingOccurrences(of: MRT2ModelInventory.revision, with: "wrong-revision") },
            { $0.replacingOccurrences(of: "\"profile\":", with: "\"pr\\u006ffile\":\"duplicate\",\"profile\":") },
            { $0.replacingOccurrences(of: "455654550", with: "455654551") },
            { $0.replacingOccurrences(of: "\"files\":[", with: "\"unexpected\":0,\"files\":[") },
        ]
        for mutate in mutations {
            expectMRT2Invalid { _ = try MRT2ModelInventory.parseManifest(Data(mutate(source).utf8)) }
        }
    }

    @Test("Admission is MRT2-only and estimate is three GiB plus three PCM copies")
    func admissionAndEstimate() throws {
        let fixture = try MRT2Fixture()
        defer { fixture.remove() }
        let inventory = try MRT2ModelInventory.inspect(
            fixture.request(), configuration: fixture.configuration())
        #expect(inventory.weights.count == 6)
        #expect(inventory.estimatedPeakBytes == 3 * 1024 * 1024 * 1024 + 3 * 1_920 * 2 * 4)

        expectMRT2Invalid {
            _ = try MRT2ModelInventory.inspect(
                fixture.request(revision: "wrong"), configuration: fixture.configuration())
        }
        let diffusion = InferenceRequest(
            model: ModelReference(directory: fixture.model,
                                  revision: MRT2BackendConfiguration.registeredModelRevision),
            input: .audio(AudioRequest(operation: .generate, prompt: "SA3",
                                       durationSeconds: 1, seed: 1, steps: 8)))
        expectMRT2Invalid {
            _ = try MRT2ModelInventory.inspect(diffusion, configuration: fixture.configuration())
        }
        expectMRT2Invalid {
            _ = try MRT2ModelInventory.inspect(
                fixture.request(), configuration: fixture.configuration(artifacts: fixture.model))
        }
        expectMRT2Invalid { _ = try MRT2ModelInventory.estimate(durationFrames: 0) }
    }

    @Test("Missing, resized, symlinked, and changed deployment inputs fail closed",
          arguments: ["missing", "resized", "symlink", "changed-after-admission"])
    func deploymentIdentity(mode: String) throws {
        let fixture = try MRT2Fixture()
        defer { fixture.remove() }
        let first = MRT2ModelInventory.requiredFiles[0]
        let url = fixture.model.appendingPathComponent(first.path)
        if mode == "changed-after-admission" {
            let inventory = try MRT2ModelInventory.inspect(
                fixture.request(), configuration: fixture.configuration())
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: first.size - 1)
            try handle.close()
            expectMRT2Invalid { try inventory.confirmUnchanged() }
            return
        }
        try FileManager.default.removeItem(at: url)
        if mode == "resized" {
            try Data("wrong-size".utf8).write(to: url)
        } else if mode == "symlink" {
            try FileManager.default.createSymbolicLink(
                at: url, withDestinationURL: fixture.model.appendingPathComponent(
                    MRT2ModelInventory.requiredFiles[1].path))
        }
        expectMRT2Invalid {
            _ = try MRT2ModelInventory.inspect(
                fixture.request(), configuration: fixture.configuration())
        }
    }

    @Test("Frozen requests and condition hashes preserve absent versus explicit-empty notes")
    func conditionSemantics() throws {
        let fixture = try MRT2Fixture()
        defer { fixture.remove() }
        let absentRequest = fixture.request(notes: nil)
        let emptyRequest = fixture.request(notes: [])
        let absentAudio = try #require(absentRequest.mrt2Audio)
        let emptyAudio = try #require(emptyRequest.mrt2Audio)
        let absentData = try MLXMRT2Backend.encodeRequest(absentRequest, audio: absentAudio)
        let emptyData = try MLXMRT2Backend.encodeRequest(emptyRequest, audio: emptyAudio)
        #expect(absentData != emptyData)

        let inventory = try MRT2ModelInventory.inspect(
            absentRequest, configuration: fixture.configuration())
        let absent = try MRT2MetadataExpectation(
            requestData: absentData, inventory: inventory, audio: absentAudio)
        let empty = try MRT2MetadataExpectation(
            requestData: emptyData, inventory: inventory, audio: emptyAudio)
        #expect(absent.condition != empty.condition)
        #expect(absent.conditionSHA256 != empty.conditionSHA256)

        let absentObject = try absent.condition.objectAny(context: "absent condition")
        let absentSequence = try absentObject["sequence"]!.objectAny(context: "absent sequence")
        #expect(absentObject["notesMode"] == .string("absent"))
        #expect(absentSequence["notes"] == nil)
        let emptyObject = try empty.condition.objectAny(context: "empty condition")
        let emptySequence = try emptyObject["sequence"]!.objectAny(context: "empty sequence")
        #expect(emptyObject["notesMode"] == .string("explicitEmpty"))
        #expect(emptySequence["notes"] == .array([]))
    }

    @Test("Canonical note ordering is reflected in the condition snapshot")
    func canonicalNotes() throws {
        let fixture = try MRT2Fixture()
        defer { fixture.remove() }
        let notes = [
            AudioNoteEvent(pitch: 67, startFrame: 0, endFrame: 1),
            AudioNoteEvent(pitch: 60, startFrame: 0, endFrame: 1),
        ]
        let request = fixture.request(notes: notes)
        let audio = try #require(request.mrt2Audio)
        let inventory = try MRT2ModelInventory.inspect(request, configuration: fixture.configuration())
        let expectation = try MRT2MetadataExpectation(
            requestData: MLXMRT2Backend.encodeRequest(request, audio: audio),
            inventory: inventory, audio: audio)
        let condition = try expectation.condition.objectAny(context: "condition")
        let sequence = try condition["sequence"]!.objectAny(context: "sequence")
        guard case .array(let canonical)? = sequence["notes"] else {
            Issue.record("Canonical notes were absent")
            return
        }
        let first = try canonical[0].objectAny(context: "first note")
        #expect(first["pitch"] == .integer(60))
    }

    @Test("Pending report promotion is exclusive and validates source and job identities",
          arguments: ["valid", "missing", "tampered", "existing", "source-symlink", "job-symlink",
                      "replaced-hardlink-directory"])
    func pendingReportPromotion(mode: String) throws {
        let fixture = try MRT2Fixture()
        defer { fixture.remove() }
        let actualJob = fixture.root.appendingPathComponent("promotion-job")
        try FileManager.default.createDirectory(at: actualJob, withIntermediateDirectories: false)
        let pending = actualJob.appendingPathComponent(MRT2ReportCommit.pendingName)
        let expected = Data("validated-terminal".utf8)
        try expected.write(to: pending)
        var replacementJob: URL?
        if mode == "replaced-hardlink-directory" {
            let replacement = fixture.root.appendingPathComponent("replacement-job")
            try FileManager.default.createDirectory(
                at: replacement, withIntermediateDirectories: false)
            try FileManager.default.linkItem(
                at: pending,
                to: replacement.appendingPathComponent(MRT2ReportCommit.pendingName))
            replacementJob = replacement
        }
        let (_, identity) = try AudioFileSystem.readRegularFile(
            pending, label: "test pending result", maximumBytes: 1_024)
        let jobIdentity = try MRT2ReportCommit.captureJobIdentity(actualJob)
        var suppliedJob = actualJob
        var displacedJob: URL?

        switch mode {
        case "missing":
            try FileManager.default.removeItem(at: pending)
        case "tampered":
            try FileManager.default.removeItem(at: pending)
            try expected.write(to: pending)
        case "existing":
            try Data("existing-result".utf8).write(
                to: actualJob.appendingPathComponent(MRT2ReportCommit.finalName))
        case "source-symlink":
            let outside = fixture.root.appendingPathComponent("outside-pending")
            try expected.write(to: outside)
            try FileManager.default.removeItem(at: pending)
            try FileManager.default.createSymbolicLink(at: pending, withDestinationURL: outside)
        case "job-symlink":
            let link = fixture.root.appendingPathComponent("promotion-job-link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: actualJob)
            suppliedJob = link
        case "replaced-hardlink-directory":
            let displaced = fixture.root.appendingPathComponent("admitted-job-moved")
            try FileManager.default.moveItem(at: actualJob, to: displaced)
            try FileManager.default.moveItem(at: replacementJob!, to: actualJob)
            displacedJob = displaced
        default: break
        }

        if mode == "valid" {
            let result = try MRT2ReportCommit.promotePending(
                in: suppliedJob, expectedJobIdentity: jobIdentity,
                expectedData: expected, expectedIdentity: identity)
            #expect(result == actualJob.appendingPathComponent(MRT2ReportCommit.finalName))
            #expect(!FileManager.default.fileExists(atPath: pending.path))
            #expect(try Data(contentsOf: result) == expected)
        } else {
            expectMRT2ReportFailure {
                _ = try MRT2ReportCommit.promotePending(
                    in: suppliedJob, expectedJobIdentity: jobIdentity,
                    expectedData: expected, expectedIdentity: identity)
            }
            let final = actualJob.appendingPathComponent(MRT2ReportCommit.finalName)
            if mode == "existing" {
                #expect(try Data(contentsOf: final) == Data("existing-result".utf8))
                #expect(try Data(contentsOf: pending) == expected)
            } else if mode == "replaced-hardlink-directory" {
                #expect(!FileManager.default.fileExists(atPath: final.path))
                let originalPending = try #require(displacedJob).appendingPathComponent(
                    MRT2ReportCommit.pendingName)
                #expect(try Data(contentsOf: originalPending) == expected)
            } else {
                #expect(!FileManager.default.fileExists(atPath: final.path))
            }
        }
    }

    @Test("Access-mode selection and failed post-exit check leave only pending")
    func accessFailureDoesNotCommit() throws {
        let fixture = try MRT2Fixture()
        defer { fixture.remove() }
        let job = fixture.root.appendingPathComponent("failed-access-job")
        try FileManager.default.createDirectory(at: job, withIntermediateDirectories: false)
        let pending = MRT2ReportCommit.observedURL(job: job, accessConfigured: true)
        let standalone = MRT2ReportCommit.observedURL(job: job, accessConfigured: false)
        #expect(pending.lastPathComponent == "pending-result.json")
        #expect(standalone.lastPathComponent == "result.json")
        try Data("pending".utf8).write(to: pending)
        let jobIdentity = try MRT2ReportCommit.captureJobIdentity(job)

        let postExitCheck: () throws -> Void = { throw MRT2FixtureError.accessFinish }
        do {
            try postExitCheck()
            // Production reaches promotion only after the same post-exit barrier succeeds.
            let (_, identity) = try AudioFileSystem.readRegularFile(
                pending, label: "pending", maximumBytes: 1_024)
            _ = try MRT2ReportCommit.promotePending(
                in: job, expectedJobIdentity: jobIdentity,
                expectedData: Data("pending".utf8),
                expectedIdentity: identity)
        } catch MRT2FixtureError.accessFinish {}
        #expect(FileManager.default.fileExists(atPath: pending.path))
        #expect(!FileManager.default.fileExists(atPath: standalone.path))
    }

    @Test("48 kHz float WAV validation rejects frame, channel, sample, and expectation errors")
    func wavValidation() throws {
        let fixture = try MRT2Fixture()
        defer { fixture.remove() }
        let output = fixture.root.appendingPathComponent("direct.wav")
        let valid = MRT2Fixture.floatWAV(frames: 4)
        try valid.write(to: output)
        let validClaim = fixture.claim(output: output, data: valid, frames: 4)
        _ = try AudioWAV.validateOutput(
            output, claim: validClaim, expectedFrames: 4, expectedSampleRate: 48_000)

        expectMRT2BackendFailure {
            _ = try AudioWAV.validateOutput(
                output, claim: validClaim, expectedFrames: -1, expectedSampleRate: 48_000)
        }
        for (name, data, claimedFrames, claimedChannels) in [
            ("channels", MRT2Fixture.floatWAV(frames: 4, channels: 1), Int64(4), 1),
            ("frames", valid, Int64(5), 2),
            ("nonfinite", MRT2Fixture.floatWAV(frames: 4, nonfinite: true), Int64(4), 2),
        ] {
            let candidate = fixture.root.appendingPathComponent("bad-\(name).wav")
            try data.write(to: candidate)
            let adjusted = fixture.claim(
                output: candidate, data: data, frames: claimedFrames, channels: claimedChannels)
            expectMRT2BackendFailure {
                _ = try AudioWAV.validateOutput(
                    candidate, claim: adjusted, expectedFrames: 4, expectedSampleRate: 48_000)
            }
        }
    }

    @Test("Complete provider run validates metadata, emits once, and runs again after release",
          .timeLimit(.minutes(1)))
    func fullProcessAndReuse() async throws {
        let fixture = try MRT2Fixture()
        defer { fixture.remove() }
        let backend = try MLXMRT2Backend(configuration: fixture.configuration())
        let recorder = MRT2EventRecorder()
        let first = try await backend.execute(fixture.request()) { await recorder.append($0) }
        await backend.release()
        #expect(first.artifacts.count == 1)
        #expect(first.metadata["profile"] == MRT2ModelInventory.profile)
        #expect(first.metadata["precision"] == "graph=unknown,output=float32")
        #expect(first.metadata["conditionSHA256"]?.count == 64)
        #expect((await recorder.snapshot()).contains(.progress(completed: 1, total: 1)))

        let second = try await backend.execute(fixture.request(notes: [])) { _ in }
        await backend.release()
        #expect(second.artifacts.count == 1)
    }

    @Test("Request, seed, condition, weights, engine phase, cleanup, and diagnostics are independent",
          .timeLimit(.minutes(1)),
          arguments: ["bad-request", "bad-seed", "bad-condition", "bad-weight",
                      "bad-engine-phase", "bad-cleanup", "bad-diagnostics"])
    func metadataCounterexamples(mode: String) async throws {
        let fixture = try MRT2Fixture()
        defer { fixture.remove() }
        let backend = try MLXMRT2Backend(configuration: fixture.configuration())
        await expectMRT2BackendFailureAsync {
            try await backend.execute(fixture.request(prompt: mode)) { _ in }
        }
        await backend.release()
    }

    @Test("Cancellation, timeout, and consumer failure drain before release",
          .timeLimit(.minutes(1)), arguments: ["cancel", "timeout", "consumer"])
    func stoppedProcesses(mode: String) async throws {
        let fixture = try MRT2Fixture()
        defer { fixture.remove() }
        let backend = try MLXMRT2Backend(configuration: fixture.configuration(
            timeout: mode == "timeout" ? 0.1 : 5, grace: 0.1))
        if mode == "cancel" {
            let recorder = MRT2EventRecorder()
            let task = Task {
                try await backend.execute(fixture.request(prompt: "slow")) {
                    await recorder.append($0)
                }
            }
            for _ in 0..<200 {
                if !(await recorder.snapshot()).isEmpty { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(!(await recorder.snapshot()).isEmpty)
            task.cancel()
            do { _ = try await task.value; Issue.record("Expected MRT2 cancellation") }
            catch is CancellationError {} catch { Issue.record("Unexpected cancellation: \(error)") }
        } else if mode == "timeout" {
            await expectMRT2BackendFailureAsync(containing: "timed out") {
                try await backend.execute(fixture.request(prompt: "slow")) { _ in }
            }
        } else {
            await expectMRT2BackendFailureAsync {
                try await backend.execute(fixture.request(prompt: "slow")) { output in
                    if case .progress = output { throw MRT2FixtureError.consumer }
                }
            }
        }
        await backend.release()
        let next = try await backend.execute(fixture.request()) { _ in }
        await backend.release()
        #expect(next.artifacts.count == 1)
    }

    @Test("License denial asks only at execute and creates no run")
    func licenseGate() async throws {
        let fixture = try MRT2Fixture()
        defer { fixture.remove() }
        let denied = try MLXMRT2Backend(configuration: fixture.configuration(
            acknowledged: false, acknowledgement: { false }))
        _ = try await denied.estimate(fixture.request())
        do {
            _ = try await denied.execute(fixture.request()) { _ in }
            Issue.record("MRT2 license gate was bypassed")
        } catch InferenceFailure.invalidRequest {} catch {
            Issue.record("Unexpected MRT2 license failure: \(error)")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.artifacts.path).isEmpty)
    }
}

private enum MRT2FixtureError: Error { case consumer, accessFinish }

private actor MRT2EventRecorder {
    private var events: [InferenceOutput] = []
    func append(_ event: InferenceOutput) { events.append(event) }
    func snapshot() -> [InferenceOutput] { events }
}

private struct MRT2Fixture {
    let root: URL
    let model: URL
    let vendor: URL
    let artifacts: URL
    let script: URL
    let manifest: URL
    let manifestData: Data

    init() throws {
        let parent = ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        root = parent.resolvingSymlinksInPath()
            .appendingPathComponent("D-mrt2-fixture-\(UUID().uuidString)")
        model = root.appendingPathComponent("model")
        vendor = root.appendingPathComponent("vendor")
        artifacts = root.appendingPathComponent("artifacts")
        script = root.appendingPathComponent("fake-mrt2-provider.py")
        manifest = root.appendingPathComponent("mrt2-small.json")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: vendor, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        for file in MRT2ModelInventory.requiredFiles {
            let url = model.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: file.size)
            try handle.close()
        }
        let files = MRT2ModelInventory.requiredFiles.map {
            "{\"path\":\"\($0.path)\",\"size\":\($0.size),\"sha256\":\"\($0.sha256)\"}"
        }.joined(separator: ",")
        manifestData = Data((
            "{\"schemaVersion\":1,\"profile\":\"\(MRT2ModelInventory.profile)\"," +
            "\"repository\":\"\(MRT2ModelInventory.repository)\"," +
            "\"revision\":\"\(MRT2ModelInventory.revision)\"," +
            "\"license\":\"\(MRT2ModelInventory.recordedLicense)\",\"files\":[\(files)]}"
        ).utf8)
        try manifestData.write(to: manifest)
        try Data(Self.providerScript.utf8).write(to: script)
    }

    func configuration(
        artifacts suppliedArtifacts: URL? = nil,
        timeout: Double = 600,
        grace: Double = 15,
        acknowledged: Bool = true,
        acknowledgement: (@Sendable () async -> Bool)? = nil
    ) -> MRT2BackendConfiguration {
        MRT2BackendConfiguration(
            pythonExecutable: URL(fileURLWithPath:
                "/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-MRT2-CONDITIONS-01/"
                + "run-20260912T150154Z/venv-dev/bin/python3"),
            providerScript: script, vendorDirectory: vendor, modelManifest: manifest,
            artifactDirectory: suppliedArtifacts ?? artifacts,
            licenseAcknowledged: acknowledged, timeoutSeconds: timeout,
            cancellationGraceSeconds: grace, modelUseAcknowledged: acknowledgement)
    }

    func request(
        prompt: String = "valid",
        seed: UInt64 = 42,
        notes: [AudioNoteEvent]? = nil,
        revision: String? = MRT2BackendConfiguration.registeredModelRevision
    ) -> InferenceRequest {
        InferenceRequest(
            model: ModelReference(directory: model, revision: revision),
            input: .audio(AudioRequest(
                prompt: prompt, seed: seed,
                noteSequence: AudioNoteSequence(durationFrames: 1, notes: notes))))
    }

    func claim(
        output: URL,
        data: Data,
        frames: Int64,
        sampleRate: Int = 48_000,
        channels: Int = 2
    ) -> AudioProviderArtifact {
        AudioProviderArtifact(
            path: output.path,
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            byteCount: UInt64(data.count), frameCount: frames,
            sampleRate: sampleRate, channels: channels, encoding: "float32")
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    static func floatWAV(frames: Int, channels: Int = 2, nonfinite: Bool = false) -> Data {
        let sampleBytes = frames * channels * 4
        var result = Data("RIFF".utf8)
        append(UInt32(36 + sampleBytes), to: &result)
        result.append(Data("WAVEfmt ".utf8)); append(UInt32(16), to: &result)
        append(UInt16(3), to: &result); append(UInt16(channels), to: &result)
        append(UInt32(48_000), to: &result)
        append(UInt32(48_000 * channels * 4), to: &result)
        append(UInt16(channels * 4), to: &result); append(UInt16(32), to: &result)
        result.append(Data("data".utf8)); append(UInt32(sampleBytes), to: &result)
        for index in 0..<(frames * channels) {
            append(index == 0 && nonfinite ? Float.nan.bitPattern : Float(0).bitPattern,
                   to: &result)
        }
        return result
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    // MRT2_FIXTURE_PYTHON_BEGIN
    private static let providerScript = #"""
import argparse,hashlib,json,os,signal,struct,sys,time
p=argparse.ArgumentParser()
for name in ('request','job-directory','model-directory','manifest','vendor-directory'):
    p.add_argument('--'+name,required=True)
p.add_argument('--access-manifest');p.add_argument('--access-run-id')
a=p.parse_args()
if (a.access_manifest is None)!=(a.access_run_id is None):raise SystemExit(2)
with open(a.request,'r',encoding='utf-8') as f:r=json.load(f)
run=r['runID'];mode=r['prompt'];seq=r['parameters']['sequence']
print(json.dumps({'schemaVersion':1,'type':'progress','runID':run,'phase':'denoising','completed':1,'total':1}),flush=True)
if mode=='slow':time.sleep(5)
notes=seq.get('notes')
canonical={'schemaVersion':seq['schemaVersion'],'frameRate':seq['frameRate'],'durationFrames':seq['durationFrames']}
if notes is not None:
    canonical['notes']=sorted(notes,key=lambda n:(n['pitch'],n['startFrame'],n['endFrame']))
condition={'sequence':canonical,'notesMode':'absent' if notes is None else ('explicitEmpty' if len(notes)==0 else 'notes')}
condition_bytes=json.dumps(condition,sort_keys=True,separators=(',',':')).encode('utf-8')
frames=seq['durationFrames']*1920
pcm=b''.join(struct.pack('<f',0.0) for _ in range(frames*2))
wav=b'RIFF'+struct.pack('<I',36+len(pcm))+b'WAVEfmt '+struct.pack('<IHHIIHH',16,3,2,48000,384000,8,32)+b'data'+struct.pack('<I',len(pcm))+pcm
out=os.path.join(a.job_directory,'output.wav')
with open(out,'xb') as f:f.write(wav)
with open(a.manifest,'r',encoding='utf-8') as f:manifest=json.load(f)
artifact={'path':out,'sha256':hashlib.sha256(wav).hexdigest(),'byteCount':len(wav),'frameCount':frames,'sampleRate':48000,'channels':2,'encoding':'float32'}
identity={'profile':'mrt2-small-export-v1','model_name':'mrt2_small','model_revision':manifest['revision'],'sdk_repository':'https://github.com/magenta/magenta-realtime','sdk_revision':'694a545e4ba0b88bf1150137b129582166d3e07f','sdk_source_files':['magenta_rt/mlx/system.py','magenta_rt/musiccoca.py','magenta_rt/config.py','magenta_rt/mlx/model.py'],'graph_conversion':'official MLX export loaded with import_function','graph_internal_precision':'unknown','output_conversion':'graph int16 to float32 divided by 32768','mlx_version':'fixture','numpy_version':'fixture','litert_version':'fixture','sentencepiece_version':'fixture','prompt':r['prompt'],'prompt_sentencepiece_tokens':1,'mapper_seed':0,'sampling_seed':r['seed'],'sampling_key_state_index':2,'state_leaf_count':165,'warmup_steps':5,'temperature':1.3,'top_k':40,'cfg_scales':{'musiccoca':3.0,'notes':1.0,'drums':1.0},'closed':False,'released':False}
metadata={'request':r,'profile':manifest['profile'],'modelRepository':manifest['repository'],'modelRevision':manifest['revision'],'weightManifest':manifest['files'],'sdkRevision':'694a545e4ba0b88bf1150137b129582166d3e07f','condition':condition,'conditionSHA256':hashlib.sha256(condition_bytes).hexdigest(),'engineIdentity':identity,'timingsSeconds':{'total':0.0},'mlxAllocations':{'measurementKind':'unavailable','measurementPhase':'fixture','activeBytes':None,'cacheBytes':None,'peakBytes':None},'cleanup':{'released':True}}
if mode=='bad-request':metadata['request']['prompt']='changed'
if mode=='bad-seed':metadata['engineIdentity']['sampling_seed']+=1
if mode=='bad-condition':metadata['condition']['notesMode']='notes'
if mode=='bad-weight':metadata['weightManifest'][0]['sha256']='0'*64
if mode=='bad-engine-phase':metadata['engineIdentity']['closed']=True
if mode=='bad-cleanup':metadata['cleanup']['released']=False
if mode=='bad-diagnostics':metadata['timingsSeconds']['total']=-1.0
event={'schemaVersion':1,'type':'result','runID':run,'artifact':artifact,'metadata':metadata}
record_name='pending-result.json' if a.access_manifest is not None else 'result.json'
with open(os.path.join(a.job_directory,record_name),'x',encoding='utf-8') as f:json.dump(event,f,separators=(',',':'))
print(json.dumps(event,separators=(',',':')),flush=True)
"""#
    // MRT2_FIXTURE_PYTHON_END
}

private extension InferenceRequest {
    var mrt2Audio: AudioRequest? {
        if case .audio(let audio) = input { return audio }
        return nil
    }
}

private func expectMRT2Invalid(_ operation: () throws -> Void) {
    do { try operation(); Issue.record("Invalid MRT2 fixture was accepted") }
    catch InferenceFailure.invalidRequest {} catch {
        Issue.record("Expected invalidRequest, received \(error)")
    }
}

private func expectMRT2BackendFailure(_ operation: () throws -> Void) {
    do { try operation(); Issue.record("Invalid MRT2 output was accepted") }
    catch InferenceFailure.backendFailed {} catch {
        Issue.record("Expected backendFailed, received \(error)")
    }
}

private func expectMRT2ReportFailure(_ operation: () throws -> Void) {
    do { try operation(); Issue.record("Unsafe MRT2 report promotion succeeded") }
    catch InferenceFailure.backendFailed {} catch InferenceFailure.invalidRequest {} catch {
        Issue.record("Expected report promotion failure, received \(error)")
    }
}

private func expectMRT2BackendFailureAsync(
    containing text: String? = nil,
    _ operation: () async throws -> InferenceResult
) async {
    do { _ = try await operation(); Issue.record("MRT2 provider fixture unexpectedly succeeded") }
    catch InferenceFailure.backendFailed(let reason) {
        if let text { #expect(reason.contains(text)) }
    } catch {
        Issue.record("Expected backendFailed, received \(error)")
    }
}
