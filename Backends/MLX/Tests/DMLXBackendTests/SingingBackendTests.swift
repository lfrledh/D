import CryptoKit
import DInference
@testable import DMLXBackend
import Foundation
import Testing

@Suite("Singing fixed-profile backend", .serialized)
struct SingingBackendTests {
    @Test("Public configuration and descriptor are frozen")
    func publicSurface() async throws {
        let root = try makeOwnedTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = configuration(root: root)
        #expect(configuration.timeoutSeconds == 600)
        #expect(configuration.cancellationGraceSeconds == 45)
        let backend = try SingingBackend(configuration: configuration)
        #expect(backend.descriptor == BackendDescriptor(
            id: "audio.singing.qixuan", version: "1", capabilities: [.audioSingingGeneration]))
        #expect(throws: (any Error).self) {
            _ = try SingingBackend(configuration: configuration(root: root, timeout: 0))
        }
    }

    @Test("Pinned profile and vendor manifests require exact keys and lexical integers")
    func manifestStrictness() throws {
        let repository = repositoryRoot()
        let profileURL = repository.appendingPathComponent(
            "Backends/Audio/Fixtures/Singing/qixuan-bigvgan-profile-v1.json")
        let sourceURL = repository.appendingPathComponent(
            "Backends/Audio/SingingVendor/source-manifest.json")
        let profileData = try Data(contentsOf: profileURL)
        let sourceData = try Data(contentsOf: sourceURL)
        let profile = try SingingModelInventory.parseProfile(profileData)
        #expect(profile.bankFiles.count == 31)
        #expect(profile.vocoderFiles.count == 3)
        #expect(try SingingModelInventory.parseSourceManifest(sourceData).count == 18)

        let profileText = String(decoding: profileData, as: UTF8.self)
        for mutation in [
            profileText.replacingOccurrences(of: "\"schemaVersion\": 1", with: "\"schemaVersion\": 1.0"),
            profileText.replacingOccurrences(of: "\"sampleRate\": 44100", with: "\"sampleRate\": true"),
            profileText.replacingOccurrences(of: "\"profileID\":", with: "\"unknown\":0,\"profileID\":"),
        ] {
            #expect(throws: (any Error).self) {
                _ = try SingingModelInventory.parseProfile(Data(mutation.utf8))
            }
        }
    }

    @Test("Resource estimate is explicit, overflow-safe, and request-sized")
    func estimate() throws {
        let short = try SingingModelInventory.estimate(declaredBytes: 1_000_000, durationTicks: 1_000_000)
        let long = try SingingModelInventory.estimate(declaredBytes: 1_000_000, durationTicks: 9_000_000)
        #expect(long > short)
        #expect(throws: (any Error).self) {
            _ = try SingingModelInventory.estimate(declaredBytes: UInt64.max, durationTicks: 1)
        }
    }

    @Test("Non-cancellable post-drain seal detects mutation even in a cancelled task")
    func sealMutationOutranksCancellation() async throws {
        let root = try makeOwnedTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("protected-input")
        try Data("before".utf8).write(to: input)
        let seal = try SingingSealedFile.capture(
            input, label: "controlled protected input", maximumBytes: 64, cancellable: true)
        try Data("after!".utf8).write(to: input)
        let task = Task {
            await Task.yield()
            try seal.confirmUnchanged(cancellable: false)
        }
        task.cancel()
        do {
            try await task.value
            Issue.record("Expected input integrity failure")
        } catch let failure as InferenceFailure {
            guard case .inputIntegrityChanged = failure else {
                Issue.record("Expected inputIntegrityChanged, received \(failure)")
                return
            }
        }
    }

    @Test("Owned subprocess accepts exactly seven ordered progress lines and one terminal")
    func controlledProcessProtocol() async throws {
        let root = try makeOwnedTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runID = UUID(uuidString: "12345678-1234-4234-8234-123456789abc")!
        let lines = SingingProviderProtocol.stages.map {
            "{\"type\":\"progress\",\"runID\":\"\(runID.uuidString.lowercased())\",\"stage\":\"\($0)\"}"
        } + ["{\"type\":\"result\",\"runID\":\"\(runID.uuidString.lowercased())\",\"resultPath\":\"result.json\"}"]
        let script = lines.map { "printf '%s\\n' '\($0)'" }.joined(separator: "; ")
        let events = SingingEventRecorder()
        let terminal = try await SingingProviderProtocol.run(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script],
            environment: ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"],
            currentDirectory: root, timeoutSeconds: 5, cancellationGraceSeconds: 1,
            runID: runID, emit: { await events.append($0) })
        #expect(terminal.resultPath == "result.json")
        #expect(await events.count == 7)

        let wrong = "printf '%s\\n' '{\"type\":\"progress\",\"runID\":\"\(runID.uuidString.lowercased())\",\"stage\":\"pitch\"}'"
        await #expect(throws: (any Error).self) {
            _ = try await SingingProviderProtocol.run(
                executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", wrong],
                environment: ["PATH": "/usr/bin:/bin"], currentDirectory: root,
                timeoutSeconds: 5, cancellationGraceSeconds: 1, runID: runID,
                emit: { _ in })
        }
    }

    @Test("Frame clocks include ties-even model framing and half-up delivery")
    func frameClocks() throws {
        #expect(try SingingProviderProtocol.nativeFrames(5_120_000) == 234_496)
        #expect(try SingingProviderProtocol.deliveredFrames(5_120_000) == 225_792)
    }

    @Test("Controlled lifecycle retains the shared lease until release")
    func lifecycleAndSharedLease() async throws {
        let root = try makeOwnedTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let artifacts = root.appendingPathComponent("artifacts", isDirectory: true)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: false)
        let request = backendRequest(bank: root.appendingPathComponent("bank"),
                                     vocoder: root.appendingPathComponent("vocoder"))
        try FileManager.default.createDirectory(at: request.model.directory, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: request.singingValue.vocoder.directory,
                                                withIntermediateDirectories: false)
        let inventory = controlledInventory(request: request, configuration: configuration(root: artifacts))
        let dependencies = try controlledDependencies(inventory: inventory, request: request)
        let first = try SingingBackend(configuration: configuration(root: artifacts), dependencies: dependencies)
        let second = try SingingBackend(configuration: configuration(root: artifacts), dependencies: dependencies)
        let result = try await first.execute(request, emit: { _ in })
        #expect(result.artifacts.count == 1)
        await #expect(throws: (any Error).self) {
            _ = try await second.execute(request, emit: { _ in })
        }
        await first.release()
        let retry = try await second.execute(request, emit: { _ in })
        #expect(retry.artifacts.count == 1)
        await second.release()
    }
}

private actor SingingEventRecorder {
    private var values: [InferenceOutput] = []
    var count: Int { values.count }
    func append(_ value: InferenceOutput) { values.append(value) }
}

private func controlledDependencies(
    inventory: SingingModelInventory, request: InferenceRequest
) throws -> SingingBackendDependencies {
    let requestData = try SingingRequestWire.encode(request)
    let requestSHA = SHA256.hash(data: requestData).map { String(format: "%02x", $0) }.joined()
    return SingingBackendDependencies(
        inspect: { _, _ in inventory },
        run: { _, arguments, _, _, _, _, runID, _ in
            let outputIndex = arguments.firstIndex(of: "--output-directory")!
            let output = URL(fileURLWithPath: arguments[outputIndex + 1], isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
            let frames = try SingingProviderProtocol.deliveredFrames(request.singingValue.phrase.durationTicks)
            let native = try SingingProviderProtocol.nativeFrames(request.singingValue.phrase.durationTicks)
            let wav = controlledWAV(frames: Int(frames))
            let digest = SHA256.hash(data: wav).map { String(format: "%02x", $0) }.joined()
            try wav.write(to: output.appendingPathComponent("output.wav"))
            let stageJSON = SingingProviderProtocol.stages.map {
                "{\"name\":\"\($0)\",\"seconds\":0}"
            }.joined(separator: ",")
            let value = """
            {"schemaVersion":1,"runID":"\(runID.uuidString.lowercased())","profileID":"\(SingingBackendConfiguration.profileID)","status":"rendered","source":{"phraseID":"\(request.singingValue.phrase.id)","phraseRevision":\(request.singingValue.phrase.revision),"requestSHA256":"\(requestSHA)","durationTicks":\(request.singingValue.phrase.durationTicks)},"model":{"bankArchiveSHA256":"\(inventory.profile.bankArchiveSHA256)","vocoderRevision":"\(inventory.profile.vocoderRevision)","vocoderSHA256":"\(String(repeating: "c", count: 64))","bankTermsSHA256":"\(inventory.profile.bankTermsSHA256)","vocoderLicenseSHA256":"\(inventory.profile.vocoderLicenseSHA256)"},"audio":{"path":"output.wav","encoding":"float32LE-WAV","sampleRate":44100,"channels":1,"frameCount":\(frames),"sha256":"\(digest)"},"execution":{"precision":"Qixuan original ONNX CPU; BigVGAN FP32 CPU","seedControl":"unsupported","nativeFrameCount":\(native),"trimHeadSamples":4096,"outputFrameCount":\(frames),"projectionRelativeResidual":0.01,"saturatedSamples":0,"stages":[\(stageJSON)]}}
            """
            try Data(value.utf8).write(to: output.appendingPathComponent("result.json"))
            return SingingProviderTerminal(resultPath: "result.json")
        })
}

private func controlledInventory(
    request: InferenceRequest, configuration: SingingBackendConfiguration
) -> SingingModelInventory {
    let profile = SingingModelInventory.Profile(
        bankArchiveSHA256: SingingBackendConfiguration.bankArchiveSHA256,
        bankTermsSHA256: request.singingValue.qualification.bankTermsSHA256,
        bankFiles: [], vocoderRevision: SingingBackendConfiguration.vocoderRevision,
        vocoderLicenseSHA256: request.singingValue.qualification.vocoderLicenseSHA256,
        vocoderFiles: [.init(path: "bigvgan_generator.pt", byteCount: 1,
                             sha256: String(repeating: "c", count: 64))])
    return SingingModelInventory(
        configuration: configuration, profile: profile, bankDirectory: request.model.directory,
        vocoderDirectory: request.singingValue.vocoder.directory,
        protectedInputs: SingingInputSeal(), estimatedPeakBytes: 2_000_000_000)
}

private func backendRequest(bank: URL, vocoder: URL) -> InferenceRequest {
    let phraseID = "11111111-1111-4111-8111-111111111111"
    let noteID = "22222222-2222-4222-8222-222222222222"
    let unitID = "33333333-3333-4333-8333-333333333333"
    let phrase = SingingPhrase(
        id: phraseID, revision: 9, language: "zh", durationTicks: 1_000_000,
        notes: [SingingNote(id: noteID, startTick: 0, endTick: 1_000_000, midiPitch: 69)],
        lyricUnits: [SingingLyricUnit(id: unitID, text: "唱", noteIDs: [noteID])])
    let pronunciation = SingingPronunciations(
        phraseID: phraseID, phraseRevision: 9, language: "zh", inventoryID: "fixed",
        inventoryRevision: "原样", symbols: ["ch", "ang", "SP"], silenceToken: "SP",
        units: [SingingPronunciationUnit(unitID: unitID, phonemes: ["ch", "ang"])])
    let qualification = SingingUseQualification(
        confirmedApplicable: true, purpose: .internalDevelopment,
        bankArchiveSHA256: SingingBackendConfiguration.bankArchiveSHA256,
        bankTermsSHA256: String(repeating: "a", count: 64),
        vocoderRevision: SingingBackendConfiguration.vocoderRevision,
        vocoderLicenseSHA256: String(repeating: "b", count: 64))
    return InferenceRequest(
        id: UUID(uuidString: "44444444-4444-4444-8444-444444444444")!,
        model: ModelReference(directory: bank, revision: SingingBackendConfiguration.bankArchiveSHA256),
        input: .singing(SingingRequest(
            profileID: SingingBackendConfiguration.profileID, phrase: phrase,
            pronunciations: pronunciation, vowelIndices: [1],
            vocoder: ModelReference(directory: vocoder, revision: SingingBackendConfiguration.vocoderRevision),
            qualification: qualification)))
}

private extension InferenceRequest {
    var singingValue: SingingRequest {
        guard case .singing(let value) = input else { preconditionFailure("controlled singing request") }
        return value
    }
}

private func configuration(
    root: URL, timeout: Double = 600
) -> SingingBackendConfiguration {
    SingingBackendConfiguration(
        pythonExecutable: root.appendingPathComponent("python"),
        providerScript: root.appendingPathComponent("provider.py"),
        vendorDirectory: root.appendingPathComponent("vendor", isDirectory: true),
        profileManifest: root.appendingPathComponent("profile.json"),
        artifactDirectory: root, timeoutSeconds: timeout, cancellationGraceSeconds: 45)
}

private func makeOwnedTestDirectory() throws -> URL {
    let base = URL(fileURLWithPath: "/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-SINGING-BACKEND-01/run-20260915T163855Z-render/bridge/tmp", isDirectory: true)
    let root = base.appendingPathComponent("singing-swift-tests-" + UUID().uuidString.lowercased(),
                                          isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    return root
}

private func repositoryRoot() -> URL {
    var result = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { result.deleteLastPathComponent() }
    return result
}

private func controlledWAV(frames: Int) -> Data {
    let payloadBytes = frames * 4
    var data = Data()
    data.append(contentsOf: "RIFF".utf8)
    append(UInt32(36 + payloadBytes), to: &data)
    data.append(contentsOf: "WAVEfmt ".utf8)
    append(UInt32(16), to: &data)
    append(UInt16(3), to: &data)
    append(UInt16(1), to: &data)
    append(UInt32(44_100), to: &data)
    append(UInt32(44_100 * 4), to: &data)
    append(UInt16(4), to: &data)
    append(UInt16(32), to: &data)
    data.append(contentsOf: "data".utf8)
    append(UInt32(payloadBytes), to: &data)
    let sample = Float(0.25).bitPattern
    for _ in 0..<frames { append(sample, to: &data) }
    return data
}

private func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    var little = value.littleEndian
    withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
}
