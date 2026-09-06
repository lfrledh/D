import DInference
import DRuntime
import CryptoKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import DWorkbench

private actor WorkbenchGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }
}

private actor WorkbenchTestBackend: InferenceBackend {
    nonisolated let descriptor = BackendDescriptor(id: "test.image", version: "1", capabilities: [.imageGeneration])
    let root: URL
    let executeGate: WorkbenchGate?
    let releaseGate: WorkbenchGate?
    private(set) var requests: [InferenceRequest] = []
    private(set) var releaseStarted = false
    private(set) var releaseCount = 0

    init(root: URL, executeGate: WorkbenchGate? = nil, releaseGate: WorkbenchGate? = nil) {
        self.root = root
        self.executeGate = executeGate
        self.releaseGate = releaseGate
    }
    func estimate(_ request: InferenceRequest) throws -> ResourceEstimate { .init(peakBytes: 1) }
    func execute(_ request: InferenceRequest,
                 emit: @escaping @Sendable (InferenceOutput) async throws -> Void) async throws -> InferenceResult {
        requests.append(request)
        if let executeGate { await executeGate.wait() }
        try Task.checkCancellation()
        let folder = root.appendingPathComponent("\(request.id.uuidString)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let url = folder.appendingPathComponent("image.png")
        let context = try #require(CGContext(data: nil, width: 512, height: 512,
            bitsPerComponent: 8, bytesPerRow: 512 * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.4, green: 0.1, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
        let image = try #require(context.makeImage())
        let target = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(target, image, nil)
        #expect(CGImageDestinationFinalize(target))
        let artifact = ArtifactReference(url: url, mediaType: "image/png")
        try await emit(.progress(completed: 4, total: 4))
        try await emit(.artifact(artifact))
        return InferenceResult(artifacts: [artifact], metadata: ["test": "CPU fixture; not MLX validation"])
    }
    func release() async {
        releaseStarted = true
        if let releaseGate { await releaseGate.wait() }
        releaseCount += 1
    }
}

@Suite(.serialized) @MainActor
struct ProjectSessionTests {
    private func temporaryDirectory() throws -> URL {
        let base = ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let directory = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.resolvingSymlinksInPath()
    }

    private func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !(await condition()) {
            if ContinuousClock.now >= deadline { Issue.record("Timed out waiting for application state"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func model(root: URL, backend: WorkbenchTestBackend, library: ModelLibrary? = nil) -> ProjectSession {
        let settings = UserDefaults(suiteName: "D.WorkbenchTests.\(UUID().uuidString)")!
        return ProjectSession(sessionFactory: { _ in
            let runtime = try InferenceRuntime(backends: [backend], configuration: RuntimeConfiguration(memoryBudgetBytes: 100))
            return WorkbenchSession(engine: runtime, backendID: backend.descriptor.id, status: {
                let snapshot = await runtime.snapshot()
                return WorkbenchRuntimeStatus(activeRunID: snapshot.activeRunID, phase: snapshot.phase?.rawValue,
                                               queuedRunIDs: snapshot.queuedRunIDs)
            }, shutdown: { await runtime.shutdown() }, cleanup: {}, validateModel: { url in
                guard FileManager.default.fileExists(atPath: url.path) else { throw CocoaError(.fileNoSuchFile) }
            })
        }, settings: settings, modelLibrary: library)
    }

    private func libraryFixture(at folder: URL) async throws -> (ModelLibrary, ModelID, URL) {
        let original = folder.appendingPathComponent("FixtureModel", isDirectory: true)
        let replacement = folder.appendingPathComponent("ReboundModel", isDirectory: true)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
        let bytes = Data("CPU lifecycle fixture; never loaded as real weights".utf8)
        try bytes.write(to: original.appendingPathComponent("model.safetensors"))
        try FileManager.default.copyItem(at: original, to: replacement)
        let checksum = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let catalog = ModelCatalogEntry(id: "fixture-image", title: "CPU fixture", repository: "fixture/tiny",
            revision: String(repeating: "a", count: 40),
            files: [ModelFile(path: "model.safetensors", size: UInt64(bytes.count), sha256: checksum)], imageProfile: .flux2Klein)
        let library = try await ModelLibrary(stateDirectory: folder.appendingPathComponent("ModelLibraryState"), catalog: [catalog])
        let id = try await library.registerExisting(at: original, catalogID: catalog.id)
        return (library, id, replacement)
    }

    @Test func modelLibraryPinsQueuedAndCancellingTasksUntilAuthoritativeRelease() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (library, id, replacement) = try await libraryFixture(at: folder)
        let project = folder.appendingPathComponent("Pinned.dproject")
        let execute = WorkbenchGate(), release = WorkbenchGate()
        let backend = WorkbenchTestBackend(root: project.appendingPathComponent("Tasks"), executeGate: execute, releaseGate: release)
        let subject = model(root: folder, backend: backend, library: library)
        await subject.createProject(at: project)
        await subject.selectModel(id: id)
        #expect(subject.modelName == "CPU fixture")
        // Readiness refresh must preserve the catalog title rather than expose an installation directory.
        try await Task.sleep(for: .milliseconds(600))
        #expect(subject.modelName == "CPU fixture")
        try #require(subject.canGenerate == false) // An empty prompt is still incomplete.
        subject.prompt = "First pinned task"
        subject.randomSeed = false
        subject.seedText = "0"
        await subject.generate()
        let first = try #require(subject.manifest?.jobs.first)
        try await waitUntil { await backend.requests.count == 1 }
        subject.prompt = "Second pinned task"
        await subject.generate()
        #expect(await library.snapshot().records.first?.activeLeaseCount == 2)
        #expect(first.request.model.revision == String(repeating: "a", count: 40))
        await #expect(throws: ModelLibraryError.self) { try await library.remove(id) }
        await subject.cancel(first.id)
        await execute.open()
        try await waitUntil { await backend.releaseStarted }
        #expect(subject.isBusy)
        #expect(await library.snapshot().records.first?.activeLeaseCount == 2)
        await #expect(throws: ModelLibraryError.self) { try await library.rebind(id, to: replacement) }
        await release.open()
        try await waitUntil { !subject.isBusy }
        #expect(await library.snapshot().records.first?.activeLeaseCount == 0)
        #expect(subject.manifest?.jobs.first?.state == .cancelled)
        #expect(subject.manifest?.jobs.last?.state == .completed)
        try await library.rebind(id, to: replacement)
        try await library.remove(id)
        try await waitUntil { !subject.canGenerate }
        #expect(subject.selectedModelID == id)
        #expect(subject.modelStatus.contains("移除"))
        #expect(await subject.cancelAndCloseProject())
        #expect(FileManager.default.fileExists(atPath: replacement.appendingPathComponent("model.safetensors").path))
    }

    @Test func admissionPersistenceFailureReleasesModelLibraryLeaseWithoutStartingCompute() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (library, id, _) = try await libraryFixture(at: folder)
        let project = folder.appendingPathComponent("CannotWrite.dproject")
        let backend = WorkbenchTestBackend(root: project.appendingPathComponent("Tasks"))
        let subject = model(root: folder, backend: backend, library: library)
        await subject.createProject(at: project)
        await subject.selectModel(id: id)
        subject.prompt = "This request cannot be persisted"
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: project.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: project.path) }
        await subject.generate()
        #expect(subject.errorMessage != nil)
        #expect(subject.manifest?.jobs.isEmpty == true)
        #expect(!subject.isBusy)
        #expect(await backend.requests.isEmpty)
        #expect(await library.snapshot().records.first?.activeLeaseCount == 0)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: project.path)
        #expect(await subject.cancelAndCloseProject())
        try await library.remove(id)
    }

    @Test func finishingAnOlderTaskDoesNotClearTheNewlySelectedInstallation() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (library, firstID, replacement) = try await libraryFixture(at: folder)
        let secondID = try await library.registerExisting(at: replacement, catalogID: "fixture-image")
        #expect(secondID != firstID)
        let project = folder.appendingPathComponent("ChangedSelection.dproject")
        let gate = WorkbenchGate()
        let backend = WorkbenchTestBackend(root: project.appendingPathComponent("Tasks"), executeGate: gate)
        let subject = model(root: folder, backend: backend, library: library)
        await subject.createProject(at: project)
        await subject.selectModel(id: firstID)
        subject.prompt = "Owned by the first installation"
        await subject.generate()
        try await waitUntil { await backend.requests.count == 1 }
        await subject.selectModel(id: secondID)
        #expect(subject.selectedModelID == secondID)
        #expect(await library.snapshot().records.first(where: { $0.id == firstID })?.activeLeaseCount == 1)
        #expect(await library.snapshot().records.first(where: { $0.id == secondID })?.activeLeaseCount == 0)
        await gate.open()
        try await waitUntil { !subject.isBusy }
        #expect(subject.selectedModelID == secondID)
        #expect(subject.modelName == "CPU fixture")
        #expect(subject.canGenerate)
        #expect(await library.snapshot().records.allSatisfy { $0.activeLeaseCount == 0 })
        try await library.remove(firstID)
        #expect(subject.selectedModelID == secondID)
        #expect(await subject.cancelAndCloseProject())
    }

    @Test func draftSnapshotZeroSeedQueueAndHistoryCopy() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = folder.appendingPathComponent("Draft.dproject")
        let gate = WorkbenchGate()
        let backend = WorkbenchTestBackend(root: project.appendingPathComponent("Tasks"), executeGate: gate)
        let subject = model(root: folder, backend: backend)
        await subject.createProject(at: project)
        #expect(subject.errorMessage == nil)
        #expect(subject.manifest != nil)
        await subject.registerModel(at: folder)
        subject.prompt = "First immutable prompt"
        subject.randomSeed = false
        subject.seedText = "0"
        await subject.generate()
        let first = try #require(subject.manifest?.jobs.first)
        subject.prompt = "Second immutable prompt"
        subject.randomSeed = true
        await subject.generate()
        let second = try #require(subject.manifest?.jobs.last)
        subject.prompt = "Unsaved next draft"
        if case .image(let image) = first.request.input {
            #expect(image.seed == 0)
            #expect(image.prompt == "First immutable prompt")
        } else { Issue.record("Expected image request") }
        #expect(subject.manifest?.jobs.count == 2)
        await gate.open()
        try await waitUntil { !subject.isBusy }
        #expect(subject.manifest?.assets.count == 2)
        #expect(subject.manifest?.jobs.allSatisfy { $0.state == .completed } == true)
        let requests = await backend.requests
        #expect(requests == [first.request, second.request])
        await subject.copySettings(from: first.id)
        #expect(subject.prompt == "First immutable prompt")
        #expect(subject.seedText == "0")
        #expect(subject.randomSeed == false)
        #expect(await subject.cancelAndCloseProject())
        await subject.openProject(at: project)
        #expect(subject.prompt == "First immutable prompt")
        #expect(subject.seedText == "0")
        #expect(subject.randomSeed == false)
        #expect(subject.manifest?.assets.count == 2)
        #expect(subject.manifest?.jobs.allSatisfy { $0.state == .completed } == true)
        #expect(await subject.cancelAndCloseProject())
    }

    @Test func cancelRetainsOwnershipThroughReleaseAndQueuedWorkDoesNotStart() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = folder.appendingPathComponent("Cancel.dproject")
        let execute = WorkbenchGate(), release = WorkbenchGate()
        let backend = WorkbenchTestBackend(root: project.appendingPathComponent("Tasks"), executeGate: execute, releaseGate: release)
        let subject = model(root: folder, backend: backend)
        await subject.createProject(at: project)
        #expect(subject.errorMessage == nil)
        await subject.registerModel(at: folder)
        subject.prompt = "Cancel me"
        await subject.generate()
        let first = try #require(subject.manifest?.jobs.first?.id)
        try await waitUntil { await backend.requests.count == 1 }
        await subject.generate()
        await subject.cancel(first)
        await execute.open()
        try await waitUntil { await backend.releaseStarted }
        #expect(subject.isBusy)
        #expect(subject.activeJobIDs.contains(first))
        #expect(subject.manifest?.jobs.first?.state != .cancelled)
        #expect(await backend.requests.count == 1)
        #expect(subject.liveStates[first] == .cancelling)
        await release.open()
        try await waitUntil { !subject.isBusy }
        #expect(subject.manifest?.jobs.first?.state == .cancelled)
        #expect(subject.manifest?.jobs.last?.state == .completed)
        #expect(subject.manifest?.assets.count == 1)
        #expect(await subject.cancelAndCloseProject())
    }

    @Test func unavailableProjectAfterPublicationDoesNotClaimSuccessAndCanRetry() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = folder.appendingPathComponent("Disconnected.dproject")
        let moved = folder.appendingPathComponent("TemporarilyMoved.dproject")
        let release = WorkbenchGate()
        let backend = WorkbenchTestBackend(root: project.appendingPathComponent("Tasks"), releaseGate: release)
        let subject = model(root: folder, backend: backend)
        await subject.createProject(at: project)
        #expect(subject.errorMessage == nil)
        await subject.registerModel(at: folder)
        subject.prompt = "Keep the completed PNG"
        await subject.generate()
        try await waitUntil { await backend.releaseStarted }
        try FileManager.default.moveItem(at: project, to: moved)
        await release.open()
        try await waitUntil { !subject.isBusy }
        #expect(subject.manifest?.jobs.first?.state != .completed)
        #expect(subject.errorMessage != nil)
        #expect(!subject.canGenerate)
        await subject.openProject(at: moved)
        #expect(subject.projectURL == moved)
        #expect(subject.manifest?.jobs.first?.state == .completed)
        #expect(subject.manifest?.assets.count == 1)
        #expect(subject.canGenerate)
        #expect(await subject.cancelAndCloseProject())
    }

    @Test func invalidSeedNeverQueuesOrStartsInference() async throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = folder.appendingPathComponent("Invalid.dproject")
        let backend = WorkbenchTestBackend(root: project.appendingPathComponent("Tasks"))
        let subject = model(root: folder, backend: backend)
        await subject.createProject(at: project)
        #expect(subject.errorMessage == nil)
        await subject.registerModel(at: folder)
        subject.prompt = "Invalid seed"
        subject.randomSeed = false
        subject.seedText = "18446744073709551616"
        await subject.generate()
        #expect(subject.errorMessage != nil)
        #expect(subject.manifest?.jobs.isEmpty == true)
        #expect(await backend.requests.isEmpty)
        subject.prompt = "Unsubmitted work must survive a restart"
        subject.seedText = "-"
        #expect(await subject.cancelAndCloseProject())
        await subject.openProject(at: project)
        #expect(subject.prompt == "Unsubmitted work must survive a restart")
        #expect(subject.seedText == "-")
        #expect(subject.manifest?.jobs.isEmpty == true)
        #expect(await subject.cancelAndCloseProject())
    }
}
