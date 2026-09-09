import CryptoKit
import DInference
import Darwin
import Dispatch
import Foundation
import Testing
@testable import DWorkbench

private actor ProfileMetadataOnlyEngine: InferenceEngine {
    func submit(_ request: InferenceRequest, backendID: String) async throws -> InferenceRun {
        throw InferenceFailure.invalidRequest("Metadata fixture never runs inference.")
    }
}

private final class OneShotHashGate: @unchecked Sendable {
    private let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var hasPaused = false

    var isPaused: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasPaused
    }

    func pauseOnce() {
        lock.lock()
        if hasPaused {
            lock.unlock()
            return
        }
        hasPaused = true
        lock.unlock()
        _ = release.wait(timeout: .now() + .seconds(2))
    }

    func resume() { release.signal() }
}

@Suite(.serialized)
struct TextModelProfileTests {
    private let halfB = "mlx-community/Qwen2.5-0.5B-Instruct-4bit"
    private let oneAndHalfB = "mlx-community/Qwen2.5-1.5B-Instruct-4bit"
    private let sevenB = "mlx-community/Qwen2.5-7B-Instruct-4bit"
    private let thirtyTwoB = "mlx-community/Qwen2.5-32B-Instruct-4bit"

    private func temporaryDirectory() throws -> URL {
        let base = try #require(ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"])
        let directory = URL(fileURLWithPath: base, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.resolvingSymlinksInPath()
    }

    private func checksum(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func file(_ name: String, bytes: Data) -> TextModelManifest.File {
        TextModelManifest.File(name: name, size: UInt64(bytes.count),
                               algorithm: "sha256", checksum: checksum(bytes))
    }

    private func write(_ files: [String: Data], to directory: URL) throws {
        for (name, data) in files {
            try data.write(to: directory.appendingPathComponent(name))
        }
    }

    private func waitUntilPaused(_ gate: OneShotHashGate) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !gate.isPaused {
            guard ContinuousClock.now < deadline else {
                throw InferenceFailure.invalidRequest("Timed out before metadata hash fixture paused.")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func bundledDescriptorsHaveFrozenIdentityOrderAndValidationMeaning() throws {
        let profiles = try TextModelProfiles.registered()
        #expect(profiles.map(\.id) == [halfB, oneAndHalfB, sevenB, thirtyTwoB])
        #expect(profiles.map(\.displayTitle) == [
            "Qwen2.5 0.5B Instruct · 4-bit",
            "Qwen2.5 1.5B Instruct · 4-bit",
            "Qwen2.5 7B Instruct · 4-bit",
            "Qwen2.5 32B Instruct · 4-bit"
        ])
        #expect(profiles.allSatisfy { $0.id == $0.repository && $0.quantizationBits == 4 })
        #expect(profiles[0].validationStatus == .previouslyRealModelVerified)
        #expect(profiles.dropFirst().allSatisfy {
            $0.validationStatus == .registeredAwaitingRealModelValidation
        })
        #expect(try TextModelProfiles.profile(forRevision: profiles[2].revision)?.id == sevenB)
        #expect(try TextModelProfiles.profile(forRevision: "unknown") == nil)
        #expect(try TextModelProfiles.profile(forRevision: nil) == nil)
        #expect(try TextModelProfiles.status(for: nil) == "尚未选择文字模型")
        #expect(try TextModelProfiles.status(for: ModelReference(
            directory: URL(fileURLWithPath: "/metadata-only"), revision: "unknown")) == "文字模型 · 版本未登记")
        #expect(try TextModelProfiles.status(for: ModelReference(
            directory: URL(fileURLWithPath: "/metadata-only"), revision: profiles[0].revision)) ==
            "Qwen2.5 0.5B Instruct · 4-bit · 文件已校验")
        #expect(try TextModelProfiles.status(for: ModelReference(
            directory: URL(fileURLWithPath: "/metadata-only"), revision: profiles[2].revision)) ==
            "Qwen2.5 7B Instruct · 4-bit · 文件已校验 · 推理待本机验证")
    }

    @Test func tinyMetadataFixturesResolveDistinctProfilesOnlyAfterEveryHashMatches() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let smallBytes = Data("AAAA".utf8)
        let largerBytes = Data("BBBB".utf8) // Same size makes hashes, not size, decide identity.
        let small = try TextModelProfiles.registrationForTesting(
            profileID: halfB, files: [file("model.safetensors", bytes: smallBytes)])
        let larger = try TextModelProfiles.registrationForTesting(
            profileID: oneAndHalfB, files: [file("model.safetensors", bytes: largerBytes)])

        let smallDirectory = root.appendingPathComponent("small", isDirectory: true)
        try FileManager.default.createDirectory(at: smallDirectory, withIntermediateDirectories: false)
        try write(["model.safetensors": smallBytes,
                   ".download.lock": Data(),
                   ".provenance.json": Data("metadata only; never identity".utf8)], to: smallDirectory)
        let smallReference = try await TextModelProfiles.verify(
            at: smallDirectory, registrations: [small, larger])
        #expect(smallReference.revision == small.profile.revision)

        let largerDirectory = root.appendingPathComponent("larger", isDirectory: true)
        try FileManager.default.createDirectory(at: largerDirectory, withIntermediateDirectories: false)
        try write(["model.safetensors": largerBytes], to: largerDirectory)
        let largerReference = try await TextModelProfiles.verify(
            at: largerDirectory, registrations: [small, larger])
        #expect(largerReference.revision == larger.profile.revision)

        try Data("CCCC".utf8).write(to: largerDirectory.appendingPathComponent("model.safetensors"))
        await #expect(throws: (any Error).self) {
            try await TextModelProfiles.verify(at: largerDirectory, registrations: [small, larger])
        }
    }

    @Test func missingExtraCorruptAndSameConfigDifferentWeightsNeverRegister() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = Data("{\"quantization\":4}".utf8)
        let expectedWeights = Data("trusted weights".utf8)
        let otherWeights = Data("changed weights".utf8)
        #expect(expectedWeights.count == otherWeights.count)
        let registration = try TextModelProfiles.registrationForTesting(profileID: sevenB, files: [
            file("config.json", bytes: config), file("model.safetensors", bytes: expectedWeights)
        ])

        let missing = root.appendingPathComponent("missing", isDirectory: true)
        try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: false)
        try write(["config.json": config], to: missing)
        await #expect(throws: (any Error).self) {
            try await TextModelProfiles.verify(at: missing, registrations: [registration])
        }

        let extra = root.appendingPathComponent("extra", isDirectory: true)
        try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: false)
        try write(["config.json": config, "model.safetensors": expectedWeights,
                   "unregistered.txt": Data("extra".utf8)], to: extra)
        await #expect(throws: (any Error).self) {
            try await TextModelProfiles.verify(at: extra, registrations: [registration])
        }

        let changed = root.appendingPathComponent("changed", isDirectory: true)
        try FileManager.default.createDirectory(at: changed, withIntermediateDirectories: false)
        try write(["config.json": config, "model.safetensors": otherWeights], to: changed)
        await #expect(throws: (any Error).self) {
            try await TextModelProfiles.verify(at: changed, registrations: [registration])
        }
    }

    @Test func invalidInjectedMetadataDuplicateIdentityAndNativeOverflowFailBeforeAdmission() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("tiny".utf8)
        let valid = try TextModelProfiles.registrationForTesting(
            profileID: halfB, files: [file("weights.bin", bytes: bytes)])

        await #expect(throws: (any Error).self) {
            try await TextModelProfiles.verify(at: root, registrations: [valid, valid])
        }

        let unknownRevision = TextModelRegistration(profile: valid.profile, manifest: TextModelManifest(
            schemaVersion: valid.manifest.schemaVersion,
            repository: valid.manifest.repository,
            revision: String(repeating: "f", count: 40),
            directoryName: valid.manifest.directoryName,
            source: valid.manifest.source,
            files: valid.manifest.files))
        await #expect(throws: (any Error).self) {
            try await TextModelProfiles.verify(at: root, registrations: [unknownRevision])
        }

        for invalidFile in [
            TextModelManifest.File(name: "zero.bin", size: 0, algorithm: "sha256",
                                   checksum: String(repeating: "0", count: 64)),
            TextModelManifest.File(name: "overflow.bin", size: UInt64.max, algorithm: "sha256",
                                   checksum: String(repeating: "0", count: 64)),
            TextModelManifest.File(name: "../escape.bin", size: 1, algorithm: "sha256",
                                   checksum: String(repeating: "0", count: 64)),
            TextModelManifest.File(name: "bad-digest.bin", size: 1, algorithm: "sha256",
                                   checksum: String(repeating: "g", count: 64)),
            TextModelManifest.File(name: "bad-algorithm.bin", size: 1, algorithm: "md5",
                                   checksum: String(repeating: "0", count: 32))
        ] {
            let invalid = TextModelRegistration(profile: valid.profile, manifest: TextModelManifest(
                schemaVersion: 1, repository: valid.profile.repository, revision: valid.profile.revision,
                directoryName: valid.manifest.directoryName, source: valid.manifest.source,
                files: [invalidFile]))
            await #expect(throws: (any Error).self) {
                try await TextModelProfiles.verify(at: root, registrations: [invalid])
            }
        }
    }

    @Test func symlinkRootSymlinkFileSpecialFileAndInvalidBookkeepingAreRejected() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("weight".utf8)
        let registration = try TextModelProfiles.registrationForTesting(
            profileID: halfB, files: [file("weights.bin", bytes: bytes)])

        let target = root.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try write(["weights.bin": bytes], to: target)
        let rootLink = root.appendingPathComponent("root-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: rootLink, withDestinationURL: target)
        await #expect(throws: (any Error).self) {
            try await TextModelProfiles.verify(at: rootLink, registrations: [registration])
        }

        let fileLink = root.appendingPathComponent("file-link", isDirectory: true)
        try FileManager.default.createDirectory(at: fileLink, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(
            at: fileLink.appendingPathComponent("weights.bin"),
            withDestinationURL: target.appendingPathComponent("weights.bin"))
        await #expect(throws: (any Error).self) {
            try await TextModelProfiles.verify(at: fileLink, registrations: [registration])
        }

        let fifo = root.appendingPathComponent("fifo", isDirectory: true)
        try FileManager.default.createDirectory(at: fifo, withIntermediateDirectories: false)
        #expect(Darwin.mkfifo(fifo.appendingPathComponent("weights.bin").path, 0o600) == 0)
        await #expect(throws: (any Error).self) {
            try await TextModelProfiles.verify(at: fifo, registrations: [registration])
        }

        let bookkeeping = root.appendingPathComponent("bookkeeping", isDirectory: true)
        try FileManager.default.createDirectory(at: bookkeeping, withIntermediateDirectories: false)
        try write(["weights.bin": bytes], to: bookkeeping)
        try FileManager.default.createDirectory(
            at: bookkeeping.appendingPathComponent(".provenance.json", isDirectory: true),
            withIntermediateDirectories: false)
        await #expect(throws: (any Error).self) {
            try await TextModelProfiles.verify(at: bookkeeping, registrations: [registration])
        }
    }

    @Test func cancellationWaitsForTheOwnedHashWorkerToStop() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data(repeating: 0x5a, count: 64 * 1024)
        try write(["weights.bin": bytes], to: root)
        let registration = try TextModelProfiles.registrationForTesting(
            profileID: halfB, files: [file("weights.bin", bytes: bytes)])
        let gate = OneShotHashGate()
        let options = TextModelVerificationOptions(hashChunkSize: 1) { gate.pauseOnce() }
        let verification = Task {
            try await TextModelProfiles.verify(at: root, registrations: [registration], options: options)
        }
        defer { verification.cancel(); gate.resume() }
        try await waitUntilPaused(gate)
        let cancellationStarted = ContinuousClock.now
        verification.cancel()
        gate.resume()
        await #expect(throws: CancellationError.self) { try await verification.value }
        #expect(cancellationStarted.duration(to: ContinuousClock.now) < .seconds(1))
    }

    @Test func changingAFileDuringHashNeverPublishesAnIdentity() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = Data(repeating: 0x31, count: 64 * 1024)
        let changed = Data(repeating: 0x32, count: original.count)
        let weights = root.appendingPathComponent("weights.bin")
        try original.write(to: weights)
        let registration = try TextModelProfiles.registrationForTesting(
            profileID: halfB, files: [file("weights.bin", bytes: original)])
        let gate = OneShotHashGate()
        let options = TextModelVerificationOptions(hashChunkSize: 1) { gate.pauseOnce() }
        let verification = Task {
            try await TextModelProfiles.verify(at: root, registrations: [registration], options: options)
        }
        defer { verification.cancel(); gate.resume() }
        try await waitUntilPaused(gate)
        try changed.write(to: weights)
        gate.resume()
        await #expect(throws: (any Error).self) { try await verification.value }
    }

    @Test func originalWrapperKeepsItsTitleAndRejectsAnotherValidRegisteredProfile() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("tiny wrapper fixture; metadata only".utf8)
        try write(["weights.bin": bytes], to: root)
        let original = try TextModelProfiles.registrationForTesting(
            profileID: halfB, files: [file("weights.bin", bytes: bytes)])
        let other = try TextModelProfiles.registrationForTesting(
            profileID: oneAndHalfB, files: [file("weights.bin", bytes: bytes)])
        #expect(FixedTextModel.title == "Qwen2.5 0.5B Instruct · 4-bit")
        #expect(try await FixedTextModel.verify(at: root, registration: original).revision == original.profile.revision)
        await #expect(throws: (any Error).self) {
            try await FixedTextModel.verify(at: root, registration: other)
        }
    }

    @Test @MainActor
    func projectStatusUsesVerifiedRevisionAndRestoresTheUnchangedBookmarkKey() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let modelDirectory = root.appendingPathComponent("model", isDirectory: true)
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: false)
        let projectURL = root.appendingPathComponent("ProfileStatus.dproject", isDirectory: true)
        let profile = try #require(TextModelProfiles.registered().first { $0.id == sevenB })
        let suite = "D.TextModelProfileTests.\(UUID().uuidString)"
        let settings = try #require(UserDefaults(suiteName: suite))
        defer { settings.removePersistentDomain(forName: suite) }

        func subject(revision: String) -> ProjectSession {
            ProjectSession(sessionFactory: { _ in
                WorkbenchSession(
                    engine: ProfileMetadataOnlyEngine(), backendID: "fixture.image",
                    status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) },
                    shutdown: {}, cleanup: {}, validateModel: { _ in },
                    textBackendID: "fixture.text",
                    validateTextModel: { ModelReference(directory: $0, revision: revision) })
            }, settings: settings)
        }

        let first = subject(revision: profile.revision)
        await first.createProject(at: projectURL)
        await first.registerTextModel(at: modelDirectory)
        #expect(first.textModelStatus ==
            "Qwen2.5 7B Instruct · 4-bit · 文件已校验 · 推理待本机验证")
        let bookmark = try #require(settings.data(forKey: "workbench.textModelBookmark.v1"))
        #expect(!bookmark.isEmpty)
        #expect(await first.requestClose())

        let restored = subject(revision: profile.revision)
        await restored.openProject(at: projectURL)
        #expect(restored.textModelStatus ==
            "Qwen2.5 7B Instruct · 4-bit · 文件已校验 · 推理待本机验证")
        #expect(settings.data(forKey: "workbench.textModelBookmark.v1") != nil)
        #expect(await restored.requestClose())

        let unknownProject = root.appendingPathComponent("UnknownStatus.dproject", isDirectory: true)
        let unknown = subject(revision: "fixture-unknown-revision")
        await unknown.createProject(at: unknownProject)
        await unknown.registerTextModel(at: modelDirectory)
        #expect(unknown.textModelStatus == "文字模型 · 版本未登记")
        #expect(await unknown.requestClose())
    }
}
