import CryptoKit
import DInference
import DRuntime
@testable import DMLXBackend
import Foundation
import Testing

@Suite("Singing fixed-profile backend", .serialized)
struct SingingBackendTests {
    @Test("Public configuration and descriptor are frozen")
    func publicSurface() async throws {
        let root = try makeOwnedTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let subjectConfiguration = configuration(root: root)
        #expect(subjectConfiguration.timeoutSeconds == 600)
        #expect(subjectConfiguration.cancellationGraceSeconds == 45)
        #expect(SingingBackendConfiguration.profile(for: SingingBackendConfiguration.profileID)
            == SingingBackendConfiguration.cpuProfile)
        #expect(SingingBackendConfiguration.profile(for: SingingBackendConfiguration.mpsProfileID)
            == SingingBackendConfiguration.mpsProfile)
        #expect(SingingBackendConfiguration.profile(for: "unknown-profile") == nil)
        let backend = try SingingBackend(configuration: subjectConfiguration)
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
        let mpsProfileURL = repository.appendingPathComponent(
            "Backends/Audio/Fixtures/Singing/qixuan-bigvgan-mps-fp32-profile-v1.json")
        let profileData = try Data(contentsOf: profileURL)
        let mpsProfileData = try Data(contentsOf: mpsProfileURL)
        let sourceData = try Data(contentsOf: sourceURL)
        let profile = try SingingModelInventory.parseProfile(profileData)
        #expect(profile.bankFiles.count == 31)
        #expect(profile.vocoderFiles.count == 3)
        #expect(try SingingModelInventory.parseProfile(
            mpsProfileData, deployment: SingingBackendConfiguration.mpsProfile).vocoderFiles.count == 3)
        #expect(throws: (any Error).self) {
            _ = try SingingModelInventory.parseProfile(
                mpsProfileData, deployment: SingingBackendConfiguration.cpuProfile)
        }
        #expect(throws: (any Error).self) {
            _ = try SingingModelInventory.parseProfile(
                profileData, deployment: SingingBackendConfiguration.mpsProfile)
        }
        #expect(try SingingModelInventory.parseSourceManifest(sourceData).count == 18)
        #expect(SingingModelInventory.requiredProviderHelpers == [
            "d_audio_contract.py", "d_singing_prepare.py", "d_singing_timing.py",
            "d_singing_qixuan.py",
        ])

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
        try Data("after!!".utf8).write(to: input)
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

    @Test("Sealing rejects post-close file and parent replacement")
    func postCloseNamedBinding() throws {
        let root = try makeOwnedTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let container = root.appendingPathComponent("container", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: false)
        let input = container.appendingPathComponent("input")
        try Data("same".utf8).write(to: input)
        #expect(throws: (any Error).self) {
            _ = try SingingSealedFile.capture(
                input, label: "replaced file", maximumBytes: 16, cancellable: false,
                afterClose: {
                    try FileManager.default.removeItem(at: input)
                    try Data("same".utf8).write(to: input)
                })
        }

        let second = container.appendingPathComponent("second")
        try Data("same".utf8).write(to: second)
        let displaced = root.appendingPathComponent("displaced", isDirectory: true)
        #expect(throws: (any Error).self) {
            _ = try SingingSealedFile.capture(
                second, label: "replaced parent", maximumBytes: 16, cancellable: false,
                afterClose: {
                    try FileManager.default.moveItem(at: container, to: displaced)
                    try FileManager.default.createDirectory(at: container, withIntermediateDirectories: false)
                    try Data("same".utf8).write(to: container.appendingPathComponent("second"))
                })
        }
    }

    @Test("Sibling creation preserves stable parent binding while parent replacement fails")
    func stableParentBinding() throws {
        let root = try makeOwnedTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let container = root.appendingPathComponent("stable-parent", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: false)
        let input = container.appendingPathComponent("input")
        try Data("sealed".utf8).write(to: input)
        let seal = try SingingSealedFile.capture(
            input, label: "stable parent input", maximumBytes: 64, cancellable: false)
        try Data("allowed sibling".utf8).write(to: container.appendingPathComponent("sibling"))
        try seal.confirmUnchanged(cancellable: false)
    }

    @Test("Growth during bounded reread is an observed integrity change")
    func growthDuringRead() throws {
        let root = try makeOwnedTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("growing-input")
        try Data(repeating: 7, count: 64 * 1024).write(to: input)
        let seal = try SingingSealedFile.capture(
            input, label: "growing input", maximumBytes: 128 * 1024, cancellable: false)
        do {
            try seal.confirmUnchanged(cancellable: false, beforeFinalObservation: {
                let handle = try FileHandle(forWritingTo: input)
                try handle.seekToEnd()
                try handle.write(contentsOf: Data([8]))
                try handle.close()
            })
            Issue.record("Expected growth during reread to be an integrity change")
        } catch let failure as InferenceFailure {
            guard case .inputIntegrityChanged = failure else {
                Issue.record("Growth was not classified as inputIntegrityChanged: \(failure)")
                return
            }
        }
    }

    @Test("Integrity outranks unknown verification failures in either order")
    func sealFailurePriority() throws {
        for integrityFirst in [false, true] {
            var seal = SingingInputSeal()
            let unknown: @Sendable (Bool) throws -> Void = { _ in
                throw InferenceFailure.backendFailed("controlled unknown EIO")
            }
            let changed: @Sendable (Bool) throws -> Void = { _ in
                throw InferenceFailure.inputIntegrityChanged("controlled observed growth")
            }
            seal.addVerification(integrityFirst ? changed : unknown)
            seal.addVerification(integrityFirst ? unknown : changed)
            do {
                try seal.confirmUnchanged(cancellable: false)
                Issue.record("Expected observed integrity failure")
            } catch let failure as InferenceFailure {
                guard case .inputIntegrityChanged = failure else {
                    Issue.record("Unknown verification failure hid observed change: \(failure)")
                    continue
                }
            }
        }
        var unknownOnly = SingingInputSeal()
        unknownOnly.addVerification { _ in
            throw InferenceFailure.backendFailed("controlled unknown EIO")
        }
        do {
            try unknownOnly.confirmUnchanged(cancellable: false)
            Issue.record("Expected unknown-only verification failure")
        } catch let failure as InferenceFailure {
            guard case .backendFailed = failure else {
                Issue.record("Pure unknown I/O was incorrectly called a mutation")
                return
            }
        }
    }

    @Test("Removal and symlink replacement are observed integrity changes")
    func unsafeReplacementKinds() throws {
        let root = try makeOwnedTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for mode in ["removed", "symlink"] {
            let input = root.appendingPathComponent("protected-" + mode)
            let outside = root.appendingPathComponent("outside-" + mode)
            try Data("input".utf8).write(to: input)
            try Data("outside".utf8).write(to: outside)
            let seal = try SingingSealedFile.capture(
                input, label: mode, maximumBytes: 64, cancellable: false)
            try FileManager.default.removeItem(at: input)
            if mode == "symlink" {
                try FileManager.default.createSymbolicLink(at: input, withDestinationURL: outside)
            }
            do {
                try seal.confirmUnchanged(cancellable: false)
                Issue.record("Expected \(mode) integrity change")
            } catch let failure as InferenceFailure {
                guard case .inputIntegrityChanged = failure else {
                    Issue.record("Expected inputIntegrityChanged for \(mode), got \(failure)")
                    continue
                }
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

        var wrongLines = lines
        wrongLines.swapAt(1, 2)
        let wrong = wrongLines.map { "printf '%s\\n' '\($0)'" }.joined(separator: "; ")
        var duplicateLines = lines
        duplicateLines.insert(lines[0], at: 1)
        let duplicate = duplicateLines.map { "printf '%s\\n' '\($0)'" }.joined(separator: "; ")
        let missingTerminal = lines.dropLast().map { "printf '%s\\n' '\($0)'" }.joined(separator: "; ")
        let postTerminal = script + "; printf '%s\\n' '{}'"
        for invalidScript in [wrong, duplicate, missingTerminal, postTerminal] {
            await #expect(throws: (any Error).self) {
                _ = try await SingingProviderProtocol.run(
                    executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", invalidScript],
                    environment: ["PATH": "/usr/bin:/bin"], currentDirectory: root,
                    timeoutSeconds: 5, cancellationGraceSeconds: 1, runID: runID,
                    emit: { _ in })
            }
        }
    }

    @Test("Owned process timeout and consumer failure drain and terminate")
    func processStopsDrain() async throws {
        let root = try makeOwnedTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runID = UUID(uuidString: "12345678-1234-4234-8234-123456789abc")!
        do {
            _ = try await SingingProviderProtocol.run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "while :; do :; done"],
                environment: ["PATH": "/usr/bin:/bin"], currentDirectory: root,
                timeoutSeconds: 0.05, cancellationGraceSeconds: 0.05, runID: runID,
                emit: { _ in })
            Issue.record("Expected owned singing process timeout")
        } catch let failure as InferenceFailure {
            #expect(failure.localizedDescription.contains("timed out"))
        }
        let first = "{\"type\":\"progress\",\"runID\":\"\(runID.uuidString.lowercased())\",\"stage\":\"validation\"}"
        let noisy = "i=0; while [ $i -lt 20000 ]; do printf x >&2; i=$((i+1)); done; printf '%s\\n' '\(first)'; while :; do :; done"
        let consumerEvents = SingingEventRecorder()
        do {
            _ = try await SingingProviderProtocol.run(
                executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", noisy],
                environment: ["PATH": "/usr/bin:/bin"], currentDirectory: root,
                timeoutSeconds: 5, cancellationGraceSeconds: 0.05, runID: runID,
                emit: { value in
                    await consumerEvents.append(value)
                    throw InferenceFailure.consumerTooSlow
                })
            Issue.record("Expected consumer failure")
        } catch let failure as InferenceFailure {
            #expect(failure.localizedDescription.contains("Output buffer is full"))
            #expect(!failure.localizedDescription.contains("timed out"))
        }
        #expect(await consumerEvents.count == 1)
    }

    @Test("Frame clocks include ties-even model framing and half-up delivery")
    func frameClocks() throws {
        #expect(try SingingProviderProtocol.nativeFrames(5_120_000) == 234_496)
        #expect(try SingingProviderProtocol.deliveredFrames(5_120_000) == 225_792)
    }

    @Test("Strict result and independent WAV validation reject one-field false claims")
    func resultAndWAVCounterexamples() throws {
        let root = try makeOwnedTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let request = backendRequest(bank: root.appendingPathComponent("bank"),
                                     vocoder: root.appendingPathComponent("vocoder"))
        let inventory = controlledInventory(request: request, configuration: configuration(root: root))
        let frames = try SingingProviderProtocol.deliveredFrames(request.singingValue.phrase.durationTicks)
        let wav = controlledWAV(frames: Int(frames))
        let validData = try controlledResultData(
            request: request, inventory: inventory, runID: request.id, wav: wav)
        let valid = try SingingProviderProtocol.parseResult(validData)
        let requestSHA = SHA256.hash(data: try SingingRequestWire.encode(request))
            .map { String(format: "%02x", $0) }.joined()
        try SingingProviderProtocol.validate(
            valid, runID: request.id, request: request.singingValue,
            requestSHA256: requestSHA, inventory: inventory)

        let source = String(decoding: validData, as: UTF8.self)
        let parseFailures = [
            source.replacingOccurrences(of: "\"runID\":\"\(request.id.uuidString.lowercased())\"",
                                        with: "\"runID\":null"),
            source.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":1.0"),
            source.replacingOccurrences(of: "\"phraseRevision\":9", with: "\"phraseRevision\":9e0"),
        ]
        for mutation in parseFailures {
            do {
                _ = try SingingProviderProtocol.parseResult(Data(mutation.utf8))
                Issue.record("Expected strict provider result rejection")
            } catch let failure as InferenceFailure {
                guard case .backendFailed = failure else {
                    Issue.record("Provider result error escaped as non-backend failure: \(failure)")
                    continue
                }
            }
        }
        let semanticFailures = [
            source.replacingOccurrences(of: request.id.uuidString.lowercased(),
                                        with: "55555555-5555-4555-8555-555555555555"),
            source.replacingOccurrences(of: "\"path\":\"output.wav\"", with: "\"path\":\"../output.wav\""),
            source.replacingOccurrences(of: "\"channels\":1", with: "\"channels\":2"),
            source.replacingOccurrences(of: "\"frameCount\":\(frames)", with: "\"frameCount\":1"),
        ]
        for mutation in semanticFailures {
            let record = try SingingProviderProtocol.parseResult(Data(mutation.utf8))
            #expect(throws: InferenceFailure.self) {
                try SingingProviderProtocol.validate(
                    record, runID: request.id, request: request.singingValue,
                    requestSHA256: requestSHA, inventory: inventory)
            }
        }

        let output = root.appendingPathComponent("output.wav")
        try wav.write(to: output)
        _ = try SingingProviderProtocol.validateWAV(output, record: valid)
        let digestMutation = source.replacingOccurrences(
            of: valid.audio.sha256, with: String(repeating: "d", count: 64))
        let digestRecord = try SingingProviderProtocol.parseResult(Data(digestMutation.utf8))
        try SingingProviderProtocol.validate(
            digestRecord, runID: request.id, request: request.singingValue,
            requestSHA256: requestSHA, inventory: inventory)
        #expect(throws: InferenceFailure.self) {
            _ = try SingingProviderProtocol.validateWAV(output, record: digestRecord)
        }
        let silent = controlledWAV(frames: Int(frames), sample: 0)
        try silent.write(to: output)
        let silentRecord = try SingingProviderProtocol.parseResult(try controlledResultData(
            request: request, inventory: inventory, runID: request.id, wav: silent))
        #expect(throws: InferenceFailure.self) {
            _ = try SingingProviderProtocol.validateWAV(output, record: silentRecord)
        }
        let nonfinite = controlledWAV(frames: Int(frames), sample: .nan)
        try nonfinite.write(to: output)
        let nonfiniteRecord = try SingingProviderProtocol.parseResult(try controlledResultData(
            request: request, inventory: inventory, runID: request.id, wav: nonfinite))
        #expect(throws: InferenceFailure.self) {
            _ = try SingingProviderProtocol.validateWAV(output, record: nonfiniteRecord)
        }
    }

    @Test("MPS result requires exact profile, digests, devices, versions, and forbidden fallback")
    func mpsResultContract() throws {
        let root = try makeOwnedTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let request = backendRequest(
            bank: root.appendingPathComponent("bank"),
            vocoder: root.appendingPathComponent("vocoder"),
            profileID: SingingBackendConfiguration.mpsProfileID)
        let inventory = controlledInventory(request: request, configuration: configuration(root: root))
        let frames = try SingingProviderProtocol.deliveredFrames(request.singingValue.phrase.durationTicks)
        let wav = controlledWAV(frames: Int(frames))
        let data = try controlledResultData(
            request: request, inventory: inventory, runID: request.id, wav: wav)
        let requestSHA = SHA256.hash(data: try SingingRequestWire.encode(request))
            .map { String(format: "%02x", $0) }.joined()
        let valid = try SingingProviderProtocol.parseResult(data)
        try SingingProviderProtocol.validate(
            valid, runID: request.id, request: request.singingValue,
            requestSHA256: requestSHA, inventory: inventory)
        #expect(valid.schemaVersion == 2)
        #expect(valid.profileID == SingingBackendConfiguration.mpsProfileID)
        #expect(valid.execution.devices?.onnx.actual == "cpu")
        #expect(valid.execution.devices?.vocoder.actual == "mps")

        let source = String(decoding: data, as: UTF8.self)
        for mutation in [
            source.replacingOccurrences(of: "\"schemaVersion\":2", with: "\"schemaVersion\":1"),
            source.replacingOccurrences(
                of: "\"profileID\":\"\(SingingBackendConfiguration.mpsProfileID)\"",
                with: "\"profileID\":\"\(SingingBackendConfiguration.profileID)\""),
            source.replacingOccurrences(of: "\"version\":\"1.20.1\"", with: "\"version\":\"\""),
            source.replacingOccurrences(
                of: "\"version\":\"2.6.0\"",
                with: "\"version\":\"\(String(repeating: "x", count: 129))\""),
            source.replacingOccurrences(
                of: "\"requested\":\"cpu\"", with: "\"unknown\":0,\"requested\":\"cpu\""),
        ] {
            #expect(mutation != source)
            #expect(throws: InferenceFailure.self) {
                _ = try SingingProviderProtocol.parseResult(Data(mutation.utf8))
            }
        }

        for mutation in [
            source.replacingOccurrences(
                of: SingingBackendConfiguration.mpsProfileSHA256,
                with: String(repeating: "d", count: 64)),
            source.replacingOccurrences(of: "\"actual\":\"mps\"", with: "\"actual\":\"cpu\""),
            source.replacingOccurrences(of: "\"fallback\":\"forbidden\"", with: "\"fallback\":\"allowed\""),
            source.replacingOccurrences(
                of: "\"provider\":\"CPUExecutionProvider\"",
                with: "\"provider\":\"CoreMLExecutionProvider\""),
            source.replacingOccurrences(
                of: "\"parameterDevice\":\"mps\"", with: "\"parameterDevice\":\"cpu\""),
        ] {
            #expect(mutation != source)
            let record = try SingingProviderProtocol.parseResult(Data(mutation.utf8))
            #expect(throws: InferenceFailure.self) {
                try SingingProviderProtocol.validate(
                    record, runID: request.id, request: request.singingValue,
                    requestSHA256: requestSHA, inventory: inventory)
            }
        }

        let cpuRequest = backendRequest(
            bank: request.model.directory, vocoder: request.singingValue.vocoder.directory)
        let cpuInventory = controlledInventory(
            request: cpuRequest, configuration: configuration(root: root))
        let cpuData = try controlledResultData(
            request: cpuRequest, inventory: cpuInventory, runID: request.id, wav: wav,
            requestSHA: requestSHA)
        let cpuRecord = try SingingProviderProtocol.parseResult(cpuData)
        #expect(throws: InferenceFailure.self) {
            try SingingProviderProtocol.validate(
                cpuRecord, runID: request.id, request: request.singingValue,
                requestSHA256: requestSHA, inventory: inventory)
        }
        #expect(throws: InferenceFailure.self) {
            try SingingProviderProtocol.validate(
                valid, runID: request.id, request: request.singingValue,
                requestSHA256: requestSHA, inventory: cpuInventory)
        }
        #expect(throws: InferenceFailure.self) {
            try SingingProviderProtocol.validate(
                valid, runID: cpuRequest.id, request: cpuRequest.singingValue,
                requestSHA256: requestSHA, inventory: cpuInventory)
        }
    }

    @Test("MPS backend forbids child fallback and publishes validated device metadata")
    func mpsBackendMetadata() async throws {
        let root = try makeOwnedTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let artifacts = root.appendingPathComponent("artifacts", isDirectory: true)
        let bank = root.appendingPathComponent("bank", isDirectory: true)
        let vocoder = root.appendingPathComponent("vocoder", isDirectory: true)
        for directory in [artifacts, bank, vocoder] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        }
        let request = backendRequest(
            bank: bank, vocoder: vocoder,
            profileID: SingingBackendConfiguration.mpsProfileID)
        let subjectConfiguration = configuration(root: artifacts)
        let inventory = controlledInventory(
            request: request, configuration: subjectConfiguration)
        let dependencies = try controlledDependencies(inventory: inventory, request: request)
        let backend = try SingingBackend(
            configuration: subjectConfiguration, dependencies: dependencies)
        do {
            let result = try await backend.execute(request, emit: { _ in })
            #expect(result.metadata["profile"] == SingingBackendConfiguration.mpsProfileID)
            #expect(result.metadata["onnxDevice"] == "cpu")
            #expect(result.metadata["vocoderDevice"] == "mps")
            #expect(result.metadata["deviceFallback"] == "forbidden")
            #expect(result.metadata["onnxRuntimeVersion"] == "1.20.1")
            #expect(result.metadata["vocoderRuntimeVersion"] == "2.6.0")
            await backend.release()
        } catch {
            await backend.release()
            throw error
        }
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
        do {
            let result = try await first.execute(request, emit: { _ in })
            #expect(result.artifacts.count == 1)
            #expect(result.metadata["onnxDevice"] == nil)
            #expect(result.metadata["vocoderDevice"] == nil)
            #expect(result.metadata["deviceFallback"] == nil)
            await #expect(throws: (any Error).self) {
                _ = try await second.execute(request, emit: { _ in })
            }
            await first.release()
            let retry = try await second.execute(request, emit: { _ in })
            #expect(retry.artifacts.count == 1)
            await second.release()
        } catch {
            await first.release()
            await second.release()
            throw error
        }
    }

    @Test("Runtime cancellation drains owned transport, reports mutation, releases, and runs next")
    func cancellationIntegrityAndRecovery() async throws {
        let root = try makeOwnedTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let artifacts = root.appendingPathComponent("artifacts", isDirectory: true)
        let inputRoot = root.appendingPathComponent("inputs", isDirectory: true)
        let bank = root.appendingPathComponent("bank", isDirectory: true)
        let vocoder = root.appendingPathComponent("vocoder", isDirectory: true)
        for directory in [artifacts, inputRoot, bank, vocoder] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        }
        let protected = inputRoot.appendingPathComponent("protected")
        try Data("before".utf8).write(to: protected)
        let firstRequest = backendRequest(
            bank: bank, vocoder: vocoder,
            profileID: SingingBackendConfiguration.mpsProfileID)
        let cpuRequest = backendRequest(bank: bank, vocoder: vocoder)
        let nextRequest = InferenceRequest(
            id: UUID(), model: cpuRequest.model, input: cpuRequest.input)
        let backendConfiguration = configuration(root: artifacts)
        let marker = root.appendingPathComponent("child-started")
        let dependencies = SingingBackendDependencies(
            inspect: { candidate, configuration in
                var seal = SingingInputSeal()
                _ = try seal.addFile(protected, label: "runtime protected input",
                                     maximumBytes: 64)
                let base = controlledInventory(request: candidate, configuration: configuration)
                return SingingModelInventory(
                    configuration: base.configuration, deployment: base.deployment,
                    profile: base.profile,
                    bankDirectory: base.bankDirectory, vocoderDirectory: base.vocoderDirectory,
                    protectedInputs: seal, estimatedPeakBytes: base.estimatedPeakBytes)
            },
            run: { _, arguments, environment, directory, _, _, runID, emit in
                if runID == firstRequest.id {
                    guard environment["PYTORCH_ENABLE_MPS_FALLBACK"] == "0" else {
                        throw InferenceFailure.backendFailed(
                            "MPS owned child did not forbid PyTorch fallback.")
                    }
                    return try await SingingProviderProtocol.run(
                        executable: URL(fileURLWithPath: "/bin/sh"),
                        arguments: ["-c", "printf started > \"$1\"; while :; do :; done",
                                    "singing-fixture", marker.path],
                        environment: ["PATH": "/usr/bin:/bin"], currentDirectory: directory,
                        timeoutSeconds: 5, cancellationGraceSeconds: 0.05,
                        runID: runID, emit: emit)
                }
                guard environment["PYTORCH_ENABLE_MPS_FALLBACK"] == nil else {
                    throw InferenceFailure.backendFailed(
                        "CPU compatibility child unexpectedly gained an MPS fallback admission setting.")
                }
                let outputIndex = arguments.firstIndex(of: "--output-directory")!
                let output = URL(fileURLWithPath: arguments[outputIndex + 1], isDirectory: true)
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
                let frames = try SingingProviderProtocol.deliveredFrames(
                    nextRequest.singingValue.phrase.durationTicks)
                let wav = controlledWAV(frames: Int(frames))
                try wav.write(to: output.appendingPathComponent("output.wav"))
                try controlledResultData(
                    request: nextRequest,
                    inventory: controlledInventory(request: nextRequest,
                                                   configuration: backendConfiguration),
                    runID: runID, wav: wav)
                    .write(to: output.appendingPathComponent("result.json"))
                return SingingProviderTerminal(resultPath: "result.json")
            })
        let backend = try SingingBackend(configuration: backendConfiguration,
                                         dependencies: dependencies)
        try await withMLXRuntime(backend) { runtime in
            let first = try await runtime.submit(firstRequest, backendID: backend.descriptor.id)
            for _ in 0..<200 where !FileManager.default.fileExists(atPath: marker.path) {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(FileManager.default.fileExists(atPath: marker.path))
            let second = try await runtime.submit(nextRequest, backendID: backend.descriptor.id)
            let handle = try FileHandle(forWritingTo: protected)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("grown".utf8))
            try handle.close()
            await first.cancel()
            guard case .failed(.inputIntegrityChanged(_)) = await first.outcome() else {
                Issue.record("Cancelled changed input must finish as inputIntegrityChanged")
                return
            }
            guard case .completed = await second.outcome() else {
                Issue.record("Following singing task did not run after drain and release")
                return
            }
        }
    }

    @Test("Unchanged owned-process cancellation remains cancelled")
    func ordinaryCancellation() async throws {
        let root = try makeOwnedTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let artifacts = root.appendingPathComponent("artifacts", isDirectory: true)
        let bank = root.appendingPathComponent("bank", isDirectory: true)
        let vocoder = root.appendingPathComponent("vocoder", isDirectory: true)
        for directory in [artifacts, bank, vocoder] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        }
        let request = backendRequest(bank: bank, vocoder: vocoder)
        let inventory = controlledInventory(request: request, configuration: configuration(root: artifacts))
        let marker = root.appendingPathComponent("ordinary-child-started")
        let dependencies = SingingBackendDependencies(
            inspect: { _, _ in inventory },
            run: { _, _, _, directory, _, _, runID, emit in
                try await SingingProviderProtocol.run(
                    executable: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", "printf started > \"$1\"; while :; do :; done",
                                "singing-fixture", marker.path],
                    environment: ["PATH": "/usr/bin:/bin"], currentDirectory: directory,
                    timeoutSeconds: 5, cancellationGraceSeconds: 0.05,
                    runID: runID, emit: emit)
            })
        let backend = try SingingBackend(configuration: configuration(root: artifacts),
                                         dependencies: dependencies)
        try await withMLXRuntime(backend) { runtime in
            let run = try await runtime.submit(request, backendID: backend.descriptor.id)
            for _ in 0..<200 where !FileManager.default.fileExists(atPath: marker.path) {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(FileManager.default.fileExists(atPath: marker.path))
            await run.cancel()
            #expect(await run.outcome() == .cancelled)
        }
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
        run: { _, arguments, environment, _, _, _, runID, _ in
            switch inventory.deployment.vocoderDevice {
            case .cpu:
                guard environment["PYTORCH_ENABLE_MPS_FALLBACK"] == nil else {
                    throw InferenceFailure.backendFailed(
                        "CPU fixture unexpectedly received an MPS fallback setting.")
                }
            case .mps:
                guard environment["PYTORCH_ENABLE_MPS_FALLBACK"] == "0" else {
                    throw InferenceFailure.backendFailed(
                        "MPS fixture did not receive the no-fallback setting.")
                }
            }
            let outputIndex = arguments.firstIndex(of: "--output-directory")!
            let output = URL(fileURLWithPath: arguments[outputIndex + 1], isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
            let frames = try SingingProviderProtocol.deliveredFrames(request.singingValue.phrase.durationTicks)
            let wav = controlledWAV(frames: Int(frames))
            try wav.write(to: output.appendingPathComponent("output.wav"))
            try controlledResultData(request: request, inventory: inventory, runID: runID,
                                     wav: wav, requestSHA: requestSHA)
                .write(to: output.appendingPathComponent("result.json"))
            return SingingProviderTerminal(resultPath: "result.json")
        })
}

private func controlledInventory(
    request: InferenceRequest, configuration: SingingBackendConfiguration
) -> SingingModelInventory {
    let deployment = SingingBackendConfiguration.profile(for: request.singingValue.profileID)!
    let profile = SingingModelInventory.Profile(
        bankArchiveSHA256: SingingBackendConfiguration.bankArchiveSHA256,
        bankTermsSHA256: request.singingValue.qualification.bankTermsSHA256,
        bankFiles: [], vocoderRevision: SingingBackendConfiguration.vocoderRevision,
        vocoderLicenseSHA256: request.singingValue.qualification.vocoderLicenseSHA256,
        vocoderFiles: [.init(path: "bigvgan_generator.pt", byteCount: 1,
                             sha256: String(repeating: "c", count: 64))])
    return SingingModelInventory(
        configuration: configuration, deployment: deployment, profile: profile,
        bankDirectory: request.model.directory,
        vocoderDirectory: request.singingValue.vocoder.directory,
        protectedInputs: SingingInputSeal(), estimatedPeakBytes: 2_000_000_000)
}

private func backendRequest(
    bank: URL, vocoder: URL,
    profileID: String = SingingBackendConfiguration.profileID
) -> InferenceRequest {
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
            profileID: profileID, phrase: phrase,
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
    guard let supplied = ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"],
          supplied.hasPrefix("/"), !supplied.contains("\0") else {
        throw InferenceFailure.invalidRequest("D_TEST_TEMP_DIR must name the explicit test-owned root.")
    }
    let base = URL(fileURLWithPath: supplied, isDirectory: true).standardizedFileURL
    try AudioFileSystem.validateDirectory(base, label: "D_TEST_TEMP_DIR")
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

private func controlledResultData(
    request: InferenceRequest, inventory: SingingModelInventory, runID: UUID, wav: Data,
    requestSHA suppliedRequestSHA: String? = nil
) throws -> Data {
    let requestSHA: String
    if let suppliedRequestSHA {
        requestSHA = suppliedRequestSHA
    } else {
        requestSHA = SHA256.hash(data: try SingingRequestWire.encode(request))
            .map { String(format: "%02x", $0) }.joined()
    }
    let frames = try SingingProviderProtocol.deliveredFrames(request.singingValue.phrase.durationTicks)
    let native = try SingingProviderProtocol.nativeFrames(request.singingValue.phrase.durationTicks)
    let digest = SHA256.hash(data: wav).map { String(format: "%02x", $0) }.joined()
    let stages = SingingProviderProtocol.stages.map {
        "{\"name\":\"\($0)\",\"seconds\":0}"
    }.joined(separator: ",")
    let deployment = inventory.deployment
    let modelDeviceIdentity: String
    let executionDevices: String
    if deployment.vocoderDevice == .mps {
        modelDeviceIdentity =
            ",\"profileSHA256\":\"\(deployment.profileSHA256)\""
            + ",\"vendorManifestSHA256\":\"\(SingingBackendConfiguration.vendorManifestSHA256)\""
        executionDevices =
            ",\"devices\":{\"onnx\":{\"requested\":\"cpu\",\"actual\":\"cpu\","
            + "\"provider\":\"CPUExecutionProvider\",\"runtime\":\"onnxruntime\","
            + "\"version\":\"1.20.1\",\"precision\":\"FP32-original\",\"fallback\":\"forbidden\"},"
            + "\"vocoder\":{\"requested\":\"mps\",\"actual\":\"mps\",\"runtime\":\"torch\","
            + "\"version\":\"2.6.0\",\"precision\":\"FP32\",\"fallback\":\"forbidden\","
            + "\"parameterDevice\":\"mps\",\"bufferDevice\":\"mps\",\"inputDevice\":\"mps\","
            + "\"outputDevice\":\"mps\"}}"
    } else {
        modelDeviceIdentity = ""
        executionDevices = ""
    }
    return Data("""
    {"schemaVersion":\(deployment.resultSchemaVersion),"runID":"\(runID.uuidString.lowercased())","profileID":"\(deployment.profileID)","status":"rendered","source":{"phraseID":"\(request.singingValue.phrase.id)","phraseRevision":\(request.singingValue.phrase.revision),"requestSHA256":"\(requestSHA)","durationTicks":\(request.singingValue.phrase.durationTicks)},"model":{"bankArchiveSHA256":"\(inventory.profile.bankArchiveSHA256)","vocoderRevision":"\(inventory.profile.vocoderRevision)","vocoderSHA256":"\(String(repeating: "c", count: 64))","bankTermsSHA256":"\(inventory.profile.bankTermsSHA256)","vocoderLicenseSHA256":"\(inventory.profile.vocoderLicenseSHA256)"\(modelDeviceIdentity)},"audio":{"path":"output.wav","encoding":"float32LE-WAV","sampleRate":44100,"channels":1,"frameCount":\(frames),"sha256":"\(digest)"},"execution":{"precision":"\(deployment.precision)","seedControl":"unsupported","nativeFrameCount":\(native),"trimHeadSamples":4096,"outputFrameCount":\(frames),"projectionRelativeResidual":0.01,"saturatedSamples":0,"stages":[\(stages)]\(executionDevices)}}
    """.utf8)
}

private func controlledWAV(frames: Int, sample: Float = 0.25) -> Data {
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
    let bits = sample.bitPattern
    for _ in 0..<frames { append(bits, to: &data) }
    return data
}

private func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    var little = value.littleEndian
    withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
}
