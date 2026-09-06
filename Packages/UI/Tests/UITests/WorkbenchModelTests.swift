import DInference
import DRuntime
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import UI

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
struct WorkbenchModelTests {
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

    private func model(root: URL, backend: WorkbenchTestBackend) -> WorkbenchModel {
        let settings = UserDefaults(suiteName: "D.WorkbenchTests.\(UUID().uuidString)")!
        return WorkbenchModel(sessionFactory: { _ in
            let runtime = try InferenceRuntime(backends: [backend], configuration: RuntimeConfiguration(memoryBudgetBytes: 100))
            return WorkbenchSession(engine: runtime, backendID: backend.descriptor.id, status: {
                let snapshot = await runtime.snapshot()
                return WorkbenchRuntimeStatus(activeRunID: snapshot.activeRunID, phase: snapshot.phase?.rawValue,
                                               queuedRunIDs: snapshot.queuedRunIDs)
            }, shutdown: { await runtime.shutdown() }, cleanup: {}, validateModel: { url in
                guard FileManager.default.fileExists(atPath: url.path) else { throw CocoaError(.fileNoSuchFile) }
            })
        }, settings: settings)
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
