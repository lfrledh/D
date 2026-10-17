import Foundation
import DInference
import CryptoKit
import Darwin
import Observation
import Synchronization
import Testing
@testable import DWorkbench
@testable import UI

@Suite @MainActor
struct ModelLibraryPresentationTests {
    @Test func idlePollingPreservesPresentationWhileRealChangesStillPublish() async throws {
        let base = try #require(ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"])
        let root = URL(fileURLWithPath: base).appendingPathComponent("LibraryPresentation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try await ModelLibrary(stateDirectory: root.appendingPathComponent("state"))
        let model = ModelLibraryModel(library: library)
        await model.refresh()

        let idleChange = Mutex(false)
        withObservationTracking { _ = model.snapshot } onChange: { idleChange.withLock { $0 = true } }
        await model.refresh()
        await model.refresh()
        #expect(!idleChange.withLock { $0 }, "Unchanged polling must not rebuild an open native menu")

        let location = root.appendingPathComponent("models")
        try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true)
        let realChange = Mutex(false)
        withObservationTracking { _ = model.snapshot } onChange: { realChange.withLock { $0 = true } }
        await model.configureRoot(at: location)
        #expect(model.errorMessage == nil)
        #expect(realChange.withLock { $0 })
        #expect(model.rootURL?.resolvingSymlinksInPath().path == location.resolvingSymlinksInPath().path)

        let settledChange = Mutex(false)
        withObservationTracking { _ = model.snapshot } onChange: { settledChange.withLock { $0 = true } }
        await model.refresh()
        #expect(!settledChange.withLock { $0 })
    }
}


extension ModelLibraryPresentationTests {
    @Test func closingAndSwitchingManagerRetainsActiveDownloadAndClearsOnlyTarget() async throws {
        let base = try #require(ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"])
        let root = URL(fileURLWithPath: base).appendingPathComponent("ManagerLifecycle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data(repeating: 0x41, count: 4096), transfer = PresentationTransfer()
        let entry = ModelCatalogEntry(id: "presentation", title: "Presentation fixture", repository: "fixture/ui", revision: String(repeating: "a", count: 40),
            files: [.init(path: "payload.bin", size: UInt64(bytes.count), sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())])
        let library = try await ModelLibrary(stateDirectory: root.appendingPathComponent("state"), catalog: [entry], transport: transfer)
        try await library.configureRoot(at: root)
        let model = ModelLibraryModel(library: library)
        let task = try await library.enqueueDownloads([entry.id])[0]
        while await transfer.started == false { await Task.yield() }
        var selected = false
        model.presentSelection { _ in selected = true }
        model.configurationSelectionAction = { _ in selected = true }
        model.resourceSearch = "资源"; model.taskSearch = "fixture"; model.resourceFilter = "attention"
        model.selectedResource = task.resourceID; model.selectedTask = task.id
        model.workspace = "downloads"; model.isPresented = false; model.clearSelectionContext()
        model.workspace = "resources"
        await transfer.open()
        for _ in 0..<500 {
            await model.refresh()
            if model.snapshot?.downloads.first?.state == .completed { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.snapshot?.downloads.first?.state == .completed)
        model.presentManagement()
        #expect(!selected && model.selectionAction == nil && model.configurationSelectionAction == nil)
        #expect(model.resourceSearch == "资源" && model.taskSearch == "fixture" && model.resourceFilter == "attention")
        #expect(model.selectedResource == task.resourceID && model.selectedTask == task.id)
        #expect(await transfer.count == 1)
        try await library.shutdown()
    }
}
private actor PresentationTransfer: ModelRangeTransport {
    var started = false, count = 0
    private var released = false
    var continuation: CheckedContinuation<Void, Never>?
    func download(_ range: ModelByteRange, to descriptor: Int32) async throws {
        count += 1; started = true
        if !released { await withCheckedContinuation { continuation = $0 } }
        let data = Data(repeating: 0x41, count: Int(range.end - range.start + 1))
        try ModelDirectory.write(data, to: descriptor)
        guard fsync(descriptor) == 0 else { throw ModelLibraryError.storage("Fixture fsync failed") }
    }
    func open() { released = true; continuation?.resume(); continuation = nil }
}

// DDM finite independent review regression — no window, file panel or credentials.
extension ModelLibraryPresentationTests {
    @Test(arguments: ["queued", "paused", "cancelled", "cleared"])
    func independentReviewWaitingRecordsDoNotBlockRecoveryControls(phase: String) async throws {
        let base = try #require(ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"])
        let root = URL(fileURLWithPath: base).appendingPathComponent("ManagerRecovery-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data(repeating: 0x41, count: 4096)
        let transfer = PresentationTransfer()
        let entry = ModelCatalogEntry(id: "recovery-presentation", title: "Recovery fixture",
            repository: "fixture/recovery", revision: String(repeating: "a", count: 40),
            files: [.init(path: "payload.bin", size: UInt64(bytes.count),
                sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())])
        let library = try await ModelLibrary(stateDirectory: root.appendingPathComponent("state"),
            catalog: [entry], transport: transfer)
        try await library.configureRoot(at: root)
        try await library.pauseQueue()
        let task = try await library.enqueueDownloads([entry.id])[0]
        if phase == "paused" { try await library.pauseDownload(task.id) }
        if phase == "cancelled" || phase == "cleared" { try await library.cancelDownload(task.id) }
        if phase == "cleared" { try await library.clearDownloadHistory([task.id]) }
        let model = ModelLibraryModel(library: library)
        await model.refresh()
        #expect(model.snapshot?.queueState == .paused)
        #expect(!model.hasActiveWork)
        #expect(model.activityCount == 0)
        #expect(model.canChooseRoot)
        #expect(model.canChangeDownloadCredential)
        #expect(await transfer.count == 0)
        // The row remains a managed partial resource, not an invisible orphan.
        #expect(model.snapshot?.resources.first?.id == task.resourceID)
        try await library.shutdown()
    }
}

extension ModelLibraryPresentationTests {
    @Test(arguments: [false, true])
    func finiteReviewActiveAndDrainingDownloadsKeepRecoveryProtected(cancel: Bool) async throws {
        let base = try #require(ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"])
        let root = URL(fileURLWithPath: base).appendingPathComponent("ActiveRecovery-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data(repeating: 0x41, count: 4096), transfer = PresentationTransfer()
        let entry = ModelCatalogEntry(id: "active", title: "Active fixture", repository: "fixture/active", revision: String(repeating: "a", count: 40),
            files: [.init(path: "payload.bin", size: UInt64(bytes.count), sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())])
        let library = try await ModelLibrary(stateDirectory: root.appendingPathComponent("state"), catalog: [entry], transport: transfer)
        try await library.configureRoot(at: root)
        let model = ModelLibraryModel(library: library)
        var stopping: Task<Void, any Error>?
        do {
        let task = try await library.enqueueDownloads([entry.id])[0]
        for _ in 0..<500 {
            if await transfer.started { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(await transfer.started)
        await model.refresh()
        #expect(model.hasActiveWork && model.activityCount == 1) // Resource + task count once.
        #expect(!model.canChooseRoot && !model.canChangeDownloadCredential)
        await #expect(throws: ModelLibraryError.self) { try await library.configureRoot(at: root) }
        await #expect(throws: ModelLibraryError.self) { try await library.disconnectDownloadCredential() }
        stopping = Task {
            if cancel { try await library.cancelDownload(task.id) }
            else { try await library.pauseDownload(task.id) }
        }
        for _ in 0..<500 {
            await model.refresh()
            if model.snapshot?.downloads.first?.state == (cancel ? .cancelled : .paused) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(model.snapshot?.downloads.first?.state == (cancel ? .cancelled : .paused))
        #expect(model.records.first?.state == .downloading) // Worker still owns the range until it drains.
        #expect(model.hasActiveWork && model.activityCount == 1)
        #expect(!model.canChooseRoot && !model.canChangeDownloadCredential)
        await #expect(throws: ModelLibraryError.self) { try await library.configureRoot(at: root) }
        await #expect(throws: ModelLibraryError.self) { try await library.disconnectDownloadCredential() }
        await #expect(throws: ModelLibraryError.self) { try await library.deleteOwnedCopy(task.resourceID) }
        await #expect(throws: ModelLibraryError.self) { try await library.unregister(task.resourceID.modelID) }
        await transfer.open(); try await stopping?.value
        await model.refresh()
        #expect(!model.hasActiveWork && model.canChooseRoot && model.canChangeDownloadCredential)
        #expect(await transfer.count == 1)
        #expect(model.snapshot?.resources.first?.id == task.resourceID)
        try await library.shutdown()
        } catch {
            await transfer.open(); stopping?.cancel()
            _ = try? await stopping?.value
            try? await library.shutdown(); throw error
        }
    }
}

extension ModelLibraryPresentationTests {
    @Test(arguments: [ModelInstallationState.downloading, .verifying, .publishing, .pausing, .queued])
    func finiteReviewProductionActivityProjectionCountsOwnedResourcesOnce(phase: ModelInstallationState) {
        let id = ModelID()
        let record = ModelRecord(id: id, catalogID: "fixture", revision: "fixture", storage: .managed,
            state: phase, availability: .available, downloadedBytes: 0, totalBytes: 1, error: nil,
            directory: nil, activeLeaseCount: 0, registrationState: .unregistered)
        var task = ModelDownloadTask(resourceID: .init(rawValue: id.rawValue), catalogID: "fixture", recipeIdentity: "fixture", postAction: .filesOnly)
        task.state = .downloading
        let snapshot = ModelLibrarySnapshot(revision: 1, rootURL: nil, catalog: [], records: [record],
            downloadCredentialConnected: false, copyProgress: nil, downloads: [task])
        #expect(ModelLibraryModel.activityCount(in: snapshot) == 1)
        var taskOnly = snapshot; taskOnly.downloads = [task, task]
        #expect(ModelLibraryModel.activityCount(in: taskOnly) == 1)
        let recordOnly = ModelLibrarySnapshot(revision: 1, rootURL: nil, catalog: [], records: [record], downloadCredentialConnected: false, copyProgress: nil)
        #expect(ModelLibraryModel.activityCount(in: recordOnly) == (phase == .queued ? 0 : 1))
        let copying = ModelLibrarySnapshot(revision: 1, rootURL: nil, catalog: [], records: [], downloadCredentialConnected: false,
            copyProgress: .init(sourceID: id, copiedBytes: 0, totalBytes: 1))
        #expect(ModelLibraryModel.activityCount(in: copying) == 1)
        #expect(ModelLibraryModel.activityCount(in: nil) == 0)
    }
}

extension ModelLibraryPresentationTests {
    @Test func nodeDraftDownloadJoinUsesExactRouteAndIdentity() throws {
        let catalog = try ModelCatalog.entries()
        for entry in catalog {
            let operation = try #require(entry.workflowProfileID), identity = try #require(entry.workflowIdentity)
            #expect(ModelLibraryModel.nodeDownloadEntry(operationID: operation, identity: identity, catalog: catalog)?.id == entry.id)
            #expect(ModelLibraryModel.nodeDownloadEntry(operationID: "d.text.input", identity: identity, catalog: catalog) == nil)
            #expect(ModelLibraryModel.nodeDownloadEntry(operationID: operation, identity: identity + "-other", catalog: catalog) == nil)
            #expect(ModelLibraryModel.nodeDownloadEntry(operationID: operation, identity: identity, catalog: catalog + [entry]) == nil)
        }
    }

    @Test(arguments: ["new", "files-only", "existing-files", "paused", "target-changed", "bind-failed", "registration-failed", "raw-video"])
    func nodePreparationUsesExistingQueueAndExactCopy(scenario: String) async throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"]))
            .appendingPathComponent("NodePreparation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixed = try #require(ModelCatalog.entries().first { scenario == "raw-video" ? $0.preparation != .none : $0.id == ModelCatalog.flux2ID })
        let bytes = Data(repeating: 0x41, count: 4096), transport = PresentationTransfer()
        let entry = ModelCatalogEntry(id: fixed.id, title: "Tiny isolated copy", repository: "fixture/node", revision: fixed.revision,
            files: [.init(path: "payload.bin", size: UInt64(bytes.count), sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())],
            workflowProfileID: fixed.workflowProfileID, workflowIdentity: fixed.workflowIdentity, preparation: fixed.preparation)
        let faults = Mutex((armed: scenario == "registration-failed", count: 0))
        let library = try await ModelLibrary(stateDirectory: root.appendingPathComponent("state"), catalog: [entry], transport: transport,
            checkpoint: { phase in
                if phase == "registration.beforeWrite" {
                    let fail = faults.withLock { value in value.count += 1; return value.armed }
                    if fail { throw ModelLibraryError.storage("isolated registration save failure") }
                }
            })
        try FileManager.default.createDirectory(at: root.appendingPathComponent("files"), withIntermediateDirectories: true)
        try await library.configureRoot(at: root.appendingPathComponent("files"))
        let model = ModelLibraryModel(library: library)
        var current = true, bound: [ModelID] = []
        let operation = try #require(entry.workflowProfileID), identity = try #require(entry.workflowIdentity)
        let bind: @MainActor (ModelID, @escaping @MainActor () -> Bool) async throws -> Void = { id, authorized in
            guard current, authorized() else { throw WorkflowIssue("stale target") }
            if scenario == "bind-failed" { throw WorkflowIssue("isolated adapter validation failure") }
            let lease = try await library.acquire(id); await library.release(lease)
            bound.append(id)
        }
        do {
            if scenario == "paused" { try await library.pauseQueue() }
            if ["files-only", "existing-files"].contains(scenario) {
                _ = try await library.enqueueDownloads([entry.id], postAction: .filesOnly)
            }
            if scenario == "existing-files" {
                await transport.open()
                for _ in 0..<500 {
                    if (await library.snapshot()).downloads.first?.state == .completed { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                let task = try #require((await library.snapshot()).downloads.first)
                try #require(task.state == .completed)
                try await library.clearDownloadHistory([task.id])
            }
            await model.prepareNode(operationID: operation, identity: identity, isCurrent: { current }, bind: bind)
            if model.preparingNodeIdentities.contains(identity) {
                await model.prepareNode(operationID: operation, identity: identity, isCurrent: { current }, bind: bind)
            }
            model.isPresented = false; model.clearSelectionContext() // Closing the manager cannot cancel the request.
            if scenario == "target-changed" { current = false }
            if scenario == "paused" {
                for _ in 0..<5 { await model.refresh() }
                #expect(model.snapshot?.queueState == .paused)
                #expect(await transport.count == 0 && bound.isEmpty)
            } else {
                await transport.open()
                for _ in 0..<500 {
                    await model.refresh()
                    if !model.preparingNodeIdentities.contains(identity), model.snapshot?.downloads.first?.state == .completed || scenario == "existing-files" { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                for _ in 0..<5 { await model.refresh() }
                let resource = try #require(model.snapshot?.resources.first)
                #expect(await transport.count == 1)
                #expect(resource.record.revision == entry.revision && resource.control.fileState == .verified)
                let shouldBind = ["new", "files-only", "existing-files"].contains(scenario)
                #expect(bound == (shouldBind ? [resource.record.id] : []))
                #expect(model.preparingNodeIdentities.isEmpty)
                if scenario == "files-only" { #expect(model.snapshot?.downloads.first?.postAction == .filesOnly) }
                if scenario == "existing-files" { #expect(model.snapshot?.downloads.isEmpty == true) }
                if scenario == "registration-failed" {
                    #expect(faults.withLock { $0.count } == 1, "Refresh must not retry failed registration")
                    #expect(resource.record.registrationState == .pending) // Existing register intent is pending after its write fails.
                    #expect(!resource.control.events.contains { $0.action == "registered" })
                    #expect(model.errorMessage?.contains("isolated registration") == true)
                    faults.withLock { $0.armed = false }
                    try await library.pauseQueue() // Unrelated save cannot resurrect success.
                }
                if scenario == "bind-failed" { #expect(model.errorMessage?.contains("adapter validation") == true) }
                if scenario == "target-changed" { #expect(model.errorMessage != nil) }
                if scenario == "raw-video" { #expect(model.preparationNotice != nil && resource.record.state == .preparationRequired) }
            }
            await transport.open(); try await library.shutdown()
            let disk = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("state/index.json"))) as? [String: Any]
            #expect(disk != nil)
            let coldState = root.appendingPathComponent("cold-state")
            try FileManager.default.createDirectory(at: coldState, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: root.appendingPathComponent("state/index.json"), to: coldState.appendingPathComponent("index.json"))
            let cold = try await ModelLibrary(stateDirectory: coldState, catalog: [entry], transport: transport)
            let readback = await cold.snapshot()
            #expect(readback.resources.first?.record.id == model.snapshot?.resources.first?.record.id)
            if scenario == "registration-failed" {
                #expect(readback.resources.first?.record.registrationState == .pending)
                #expect(readback.resources.first?.control.events.contains { $0.action == "registered" } == false)
            }
            try await cold.shutdown()
        } catch { await transport.open(); try? await library.shutdown(); throw error }
    }
}

extension ModelLibraryPresentationTests {
    @Test(arguments: [false, true])
    func explicitUnregisterRevokesNodePreparationEvenDuringBinding(duringBinding: Bool) async throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"]))
            .appendingPathComponent("NodeRevocation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixed = try #require(ModelCatalog.entries().first { $0.id == ModelCatalog.flux2ID })
        let bytes = Data(repeating: 0x41, count: 4096), transport = PresentationTransfer()
        let entry = ModelCatalogEntry(id: fixed.id, title: "Revocation copy", repository: "fixture/revocation", revision: fixed.revision,
            files: [.init(path: "payload.bin", size: UInt64(bytes.count), sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())],
            workflowProfileID: fixed.workflowProfileID, workflowIdentity: fixed.workflowIdentity)
        let library = try await ModelLibrary(stateDirectory: root.appendingPathComponent("state"), catalog: [entry], transport: transport)
        try await library.configureRoot(at: root)
        let model = ModelLibraryModel(library: library), gate = NodeBindingGate()
        var entered = false, bound = false
        await model.prepareNode(operationID: try #require(entry.workflowProfileID), identity: try #require(entry.workflowIdentity), isCurrent: { true }) { _, authorized in
            entered = true
            if duringBinding { await gate.wait() }
            guard authorized() else { throw WorkflowIssue("Preparation authorization revoked") }
            bound = true
        }
        await transport.open()
        for _ in 0..<500 {
            if (await library.snapshot()).downloads.first?.state == .completed { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let resource = try #require((await library.snapshot()).resources.first)
        try #require(resource.record.registrationState == .registered)
        var refresh: Task<Void, Never>?
        if duringBinding {
            refresh = Task { await model.refresh() }
            for _ in 0..<500 { if entered { break }; await Task.yield() }
            try #require(entered)
        }
        await model.unregisterResource(resource)
        await gate.open(); await refresh?.value
        for _ in 0..<5 { await model.refresh() }
        #expect(!bound && model.preparingNodeIdentities.isEmpty)
        #expect(model.snapshot?.resources.first?.record.registrationState == .unregistered)
        #expect(model.snapshot?.resources.first?.control.fileState == .verified)
        #expect(await transport.count == 1)
        try await library.shutdown()
    }
}
private actor NodeBindingGate {
    var continuation: CheckedContinuation<Void, Never>?
    var released = false
    func wait() async { if !released { await withCheckedContinuation { continuation = $0 } } }
    func open() { released = true; continuation?.resume(); continuation = nil }
}

extension ModelLibraryPresentationTests {
    @Test func preparedDraftBindsRealProjectInstallationWithoutEditingGraphOrSubmitting() async throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"]))
            .appendingPathComponent("NodeProjectBinding-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixed = try #require(ModelCatalog.entries().first { $0.id == ModelCatalog.flux2ID })
        let bytes = Data(repeating: 0x41, count: 4096), transport = PresentationTransfer(), engine = PreparationNoInference()
        let entry = ModelCatalogEntry(id: fixed.id, title: "Tiny integration fixture", repository: "fixture/project", revision: fixed.revision,
            files: [.init(path: "payload.bin", size: UInt64(bytes.count), sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())],
            workflowProfileID: fixed.workflowProfileID, workflowIdentity: fixed.workflowIdentity)
        let library = try await ModelLibrary(stateDirectory: root.appendingPathComponent("state"), catalog: [entry], transport: transport)
        try await library.configureRoot(at: root)
        let suite = "D.NodePreparation." + UUID().uuidString
        let settings = try #require(UserDefaults(suiteName: suite)); defer { settings.removePersistentDomain(forName: suite) }
        let owner = ProjectSession(sessionFactory: { _ in WorkbenchSession(engine: engine, backendID: "fixture-never",
            status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) }, shutdown: {}, cleanup: {}, validateModel: { _ in }) },
            settings: settings, modelLibrary: library)
        await owner.createProject(at: root.appendingPathComponent("Fixture.dproject")); await owner.openWorkflow()
        let controller = try #require(owner.workflow), identity = try #require(entry.workflowIdentity), operation = try #require(entry.workflowProfileID)
        controller.addNode(operationID: operation, modelID: identity)
        let node = try #require(controller.graph?.nodes.last), target = try #require(controller.modelSelectionTarget(nodeID: node.id))
        try await controller.saveExplicitEdits()
        let graph = controller.graphs, undo = controller.canUndo, store = try #require(owner.currentStore)
        let before = await store.snapshot(), model = ModelLibraryModel(library: library)
        await model.prepareNode(operationID: operation, identity: identity, isCurrent: { controller.isCurrent(target) }) { id, authorized in
            _ = try await owner.selectWorkflowInstallation(id: id) { choice in
                try owner.checkWorkflowModelSelection(target: target, controller: controller)
                guard authorized(), choice.id == identity else { throw WorkflowIssue("Changed exact target") }
            }
        }
        await transport.open()
        for _ in 0..<500 {
            await model.refresh()
            if model.preparingNodeIdentities.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.errorMessage == nil)
        let record = try #require(model.snapshot?.resources.first?.record)
        #expect(owner.workflowInstallationID(for: identity) == record.id)
        #expect(owner.explicitModelReadiness[identity] == .available)
        #expect(controller.modelChoices.contains { $0.id == identity })
        #expect(controller.graphs == graph && controller.canUndo == undo)
        #expect((await store.snapshot()).revision == before.revision)
        #expect((await engine.submissions) == 0)
        #expect(record.activeLeaseCount == 0 && record.registrationState == .registered)
        await owner.closeProject(); try await library.shutdown()
    }
}
private actor PreparationNoInference: InferenceEngine {
    private(set) var submissions = 0
    func submit(_ request: InferenceRequest, backendID: String) async throws -> InferenceRun {
        submissions += 1; throw WorkflowIssue("Fixture must not infer")
    }
}
