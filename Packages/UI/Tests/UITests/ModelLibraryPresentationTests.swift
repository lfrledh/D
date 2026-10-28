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
    @Test func memoryRefreshPreservesPresentationWhileRealChangesStillPublish() async throws {
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
        #expect(!idleChange.withLock { $0 }, "Unchanged memory refresh must not rebuild an open native menu")

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
    @Test func unregisterDuringPreparationRefreshCannotRegisterExistingCopyAgain() async throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"]))
            .appendingPathComponent("NodeInitializationRevocation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try ModelCatalog.entries(), bytes = Data(repeating: 0x41, count: 4096)
        let target = try #require(catalog.first { $0.id == ModelCatalog.flux2ID })
        let other = try #require(catalog.first { $0.id != target.id && $0.preparation == .none })
        let entries = [target, other].map { fixed in
            ModelCatalogEntry(id: fixed.id, title: "Initialization fixture", repository: "fixture/initialization", revision: fixed.revision,
                files: [.init(path: "payload.bin", size: UInt64(bytes.count), sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())],
                workflowProfileID: fixed.workflowProfileID, workflowIdentity: fixed.workflowIdentity)
        }
        let transport = PresentationTransfer(), gate = NodeBindingGate()
        let library = try await ModelLibrary(stateDirectory: root.appendingPathComponent("state"), catalog: entries, transport: transport)
        try await library.configureRoot(at: root)
        await transport.open()
        _ = try await library.enqueueDownloads([target.id], postAction: .register)
        for _ in 0..<500 {
            if (await library.snapshot()).downloads.first?.state == .completed { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let resource = try #require((await library.snapshot()).resources.first { $0.record.catalogID == target.id })
        try #require(resource.record.registrationState == .registered)
        var registrationEvents = resource.control.events.filter { $0.action == "registered" }.count
        try await library.pauseQueue()
        let model = ModelLibraryModel(library: library)
        var entered = false, bound = false
        // Another real request makes the target's initial refresh suspend inside
        // reconciliation, without replacing snapshot or the production consumer.
        await model.prepareNode(operationID: try #require(other.workflowProfileID), identity: try #require(other.workflowIdentity), isCurrent: { true }) { _, _ in
            entered = true; await gate.wait()
        }
        try await library.resumeQueue()
        for _ in 0..<500 {
            if (await library.snapshot()).downloads.last?.state == .completed { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let operation = try #require(target.workflowProfileID), identity = try #require(target.workflowIdentity)
        let prepare = Task { await model.prepareNode(operationID: operation, identity: identity, isCurrent: { true }) { _, _ in bound = true } }
        for _ in 0..<500 { if entered { break }; await Task.yield() }
        let callbackWasNotEntered = !entered
        await prepare.value
        registrationEvents = (await library.snapshot()).resources.first { $0.id == resource.id }!.control.events.filter { $0.action == "registered" }.count
        await model.unregisterResource(resource)
        await gate.open(); await prepare.value
        for _ in 0..<5 { await model.refresh() }
        #expect(callbackWasNotEntered && !bound && model.preparingNodeIdentities.isEmpty)
        let final = try #require(model.snapshot?.resources.first { $0.id == resource.id })
        #expect(final.record.registrationState == .unregistered && final.control.fileState == .verified)
        #expect(final.id == resource.id)
        #expect(final.control.events.filter { $0.action == "registered" }.count == registrationEvents)
        #expect(final.control.events.last?.action == "unregistered")
        #expect(model.snapshot?.downloads.count == 2)
        #expect(await transport.count == 2)
        try await library.shutdown()
    }

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
            if entry.id == "stable-audio-small-music" {
                #expect(entry.workflowProfileID == nil && entry.workflowIdentity == nil)
                #expect(ModelLibraryModel.nodeDownloadEntry(operationID: "d.music.generate", identity: "music:" + entry.revision, catalog: catalog) == nil)
                continue
            }
            let operation = try #require(entry.workflowProfileID), identity = try #require(entry.workflowIdentity)
            if operation == "d.model.language" {
                #expect(ModelLibraryModel.nodeDownloadEntry(operationID: "d.text.rewrite", identity: identity, catalog: catalog)?.id == entry.id)
                #expect(ModelLibraryModel.nodeDownloadEntry(operationID: WorkflowModelRoutes.qwen35, identity: identity, catalog: catalog) == nil)
            }
            #expect(ModelLibraryModel.nodeDownloadEntry(operationID: operation, identity: identity, catalog: catalog)?.id == entry.id)
            #expect(ModelLibraryModel.nodeDownloadEntry(operationID: "d.text.input", identity: identity, catalog: catalog) == nil)
            #expect(ModelLibraryModel.nodeDownloadEntry(operationID: operation, identity: identity + "-other", catalog: catalog) == nil)
            #expect(ModelLibraryModel.nodeDownloadEntry(operationID: operation, identity: identity, catalog: catalog + [entry]) == nil)
        }
    }

    @Test(arguments: ["new", "files-only", "existing-files", "paused", "target-changed", "bind-failed", "registration-failed", "raw-video", "delete-old-history"])
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
        model.start(); defer { model.stop() }
        var current = true, bound: [ModelID] = []
        let operation = try #require(entry.workflowProfileID), identity = try #require(entry.workflowIdentity)
        let bind: @MainActor (ModelID, @escaping @MainActor () -> Bool) async throws -> Void = { id, authorized in
            guard current, authorized() else { throw WorkflowIssue("stale target") }
            if scenario == "bind-failed" { throw WorkflowIssue("isolated adapter validation failure") }
            let lease = try await library.acquire(id); await library.release(lease)
            bound.append(id)
        }
        do {
            var oldTask: ModelDownloadTask?
            if scenario == "delete-old-history" {
                try await library.pauseQueue()
                let old = try await library.enqueueDownloads([entry.id], postAction: .register)[0]
                try await library.cancelDownload(old.id)
                oldTask = try #require((await library.snapshot()).downloads.first)
                try await library.resumeQueue()
            }
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
            if let oldTask {
                #expect(model.preparingNodeIdentities.contains(identity))
                await model.deleteTask(oldTask, cleanupPartial: false)
                #expect(model.errorMessage == nil && model.preparingNodeIdentities.contains(identity))
                #expect(model.snapshot?.downloads.count == 1)
            }
            model.isPresented = false; model.clearSelectionContext() // Closing the manager cannot cancel the request.
            if scenario == "target-changed" { current = false }
            if scenario == "paused" {
                for _ in 0..<5 { await Task.yield() }
                #expect(model.snapshot?.queueState == .paused)
                #expect(await transport.count == 0 && bound.isEmpty)
            } else {
                await transport.open()
                for _ in 0..<500 {
                    if !model.preparingNodeIdentities.contains(identity), model.snapshot?.downloads.first?.state == .completed || scenario == "existing-files" { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                for _ in 0..<5 { await Task.yield() }
                let resource = try #require(model.snapshot?.resources.first)
                #expect(await transport.count == 1)
                #expect(resource.record.revision == entry.revision && resource.control.fileState == .verified)
                #expect(bound.isEmpty, "Accepted acquisition never binds the current view")
                if !["registration-failed", "raw-video"].contains(scenario) {
                    #expect(resource.record.registrationState == .registered)
                }
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
                if scenario == "bind-failed" { #expect(model.errorMessage == nil, "The view callback must not run after acquisition") }
                if scenario == "target-changed" { #expect(model.errorMessage == nil, "Navigation after acceptance must not reject service completion") }
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
    func explicitUnregisterRevokesNodePreparationBeforeOrAfterPresentation(duringBinding: Bool) async throws {
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
            await refresh?.value
            #expect(!entered, "No completion binding is retained")
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
    @Test func preparedDraftRegistersWithoutBindingOrEditingGraphOrSubmitting() async throws {
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
        #expect(owner.workflowInstallationID(for: identity) == nil, "Acquisition must not rewrite an explicit installation choice")
        owner.observeModelAvailability(try #require(model.snapshot))
        for _ in 0..<500 {
            if owner.explicitModelReadiness[identity] == .available { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(owner.explicitModelReadiness[identity] == .available, "The event-owned check must finish without another view action")
        #expect(controller.graph?.nodes.contains { $0.parameters["modelID"]?.string == identity } == true)
        #expect(controller.graphs == graph && controller.canUndo == undo)
        #expect((await store.snapshot()).revision == before.revision)
        #expect((await engine.submissions) == 0)
        #expect(record.activeLeaseCount == 0 && record.registrationState == .registered)
        let resource = try #require(model.snapshot?.resources.first)
        let downloads = model.snapshot?.downloads
        await model.unregisterResource(resource)
        #expect(model.preparationNotice != nil)
        await model.registerResource(try #require(model.snapshot?.resources.first))
        #expect(model.errorMessage == nil && model.preparationNotice == nil)
        #expect(model.snapshot?.resources.first?.record.registrationState == .registered)
        #expect(model.snapshot?.downloads == downloads)
        #expect(controller.graphs == graph && controller.canUndo == undo)
        #expect((await engine.submissions) == 0)
        await owner.closeProject(); try await library.shutdown()
    }
}
private actor PreparationNoInference: InferenceEngine {
    private(set) var submissions = 0
    func submit(_ request: InferenceRequest, backendID: String) async throws -> InferenceRun {
        submissions += 1; throw WorkflowIssue("Fixture must not infer")
    }
}

extension ModelLibraryPresentationTests {
    @Test func explicitManagerDestinationsDoNotInheritLastPageOrSelectionTarget() async throws {
        let base = try #require(ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"])
        let root = URL(fileURLWithPath: base).appendingPathComponent("ManagerRoutes-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try await ModelLibrary(stateDirectory: root)
        let model = ModelLibraryModel(library: library)
        var selected = false
        model.presentSelection { _ in selected = true }
        model.workspace = "downloads"; model.presentManagement()
        #expect(model.workspace == "resources" && model.selectionAction == nil && !selected)
        model.presentDownloads()
        #expect(model.workspace == "downloads" && model.selectionAction == nil)
        model.presentSelection { _ in selected = true }
        #expect(model.workspace == "resources" && model.selectionAction != nil && !selected)
        model.presentDownloads()
        #expect(model.selectionAction == nil && !selected)
        try await library.shutdown()
    }
}

extension ModelLibraryPresentationTests {
    @Test func downloadManagerButtonsPreserveQueueScopeAndDrainPresentation() async throws {
        let base = try #require(ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"])
        let root = URL(fileURLWithPath: base).appendingPathComponent("ManagerCommands-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data(repeating: 0x41, count: 4096), transfer = PresentationTransfer()
        let entry = ModelCatalogEntry(id: "manager-command", title: "Manager command fixture", repository: "fixture/ui", revision: String(repeating: "a", count: 40),
            files: [.init(path: "payload.bin", size: UInt64(bytes.count), sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())])
        let library = try await ModelLibrary(stateDirectory: root.appendingPathComponent("state"), catalog: [entry], transport: transfer)
        try await library.configureRoot(at: root)
        let model = ModelLibraryModel(library: library)
        await model.refresh(); await model.pauseQueue(); await model.enqueue([entry.id], register: true)
        let queued = try #require(model.snapshot?.downloads.first)
        #expect(!model.queueIsRunning)
        #expect(await transfer.count == 0)
        await model.cancelTask(queued.id, keepPartial: true)
        let stopped = try #require(model.snapshot?.downloads.first)
        model.errorMessage = "Previous command failed"
        await model.continueTask(stopped)
        #expect(model.errorMessage == nil && !model.queueIsRunning)
        let resumed = try #require(model.snapshot?.downloads.last)
        #expect(resumed.id != stopped.id && resumed.postAction == .register)
        #expect(model.currentDownloadResource(for: stopped) == nil && !model.canContinueDownload(stopped))
        #expect(model.currentDownloadResource(for: resumed) != nil)
        await model.resumeQueue()
        for _ in 0..<500 { if await transfer.started { break }; await Task.yield() }
        await model.refresh()
        let active = try #require(model.snapshot?.downloads.last)
        let pause = Task { await model.pauseTask(active.id) }
        for _ in 0..<500 { if model.pendingActions[active.resourceID.modelID] != nil { break }; await Task.yield() }
        if case .pausing? = model.pendingActions[active.resourceID.modelID] { } else { Issue.record("Pause must remain pending until the transfer drains") }
        #expect(model.pendingDownloadAction(for: stopped) == nil)
        #expect(model.pendingDownloadAction(for: active) != nil)
        await transfer.open(); await pause.value
        #expect(model.pendingActions[active.resourceID.modelID] == nil)
        #expect(model.snapshot?.downloads.last?.state == .paused)
        await model.continueTask(try #require(model.snapshot?.downloads.last))
        for _ in 0..<500 { await model.refresh(); if model.snapshot?.downloads.last?.state == .completed { break }; try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.snapshot?.downloads.last?.state == .completed)
        #expect(model.snapshot?.resources.first?.record.registrationState == .registered)
        let completed = try #require(model.snapshot?.downloads.last)
        await model.deleteTask(completed, cleanupPartial: false)
        #expect(model.errorMessage == nil)
        #expect(model.currentDownloadResource(for: stopped) == nil && !model.canContinueDownload(stopped))
        let before = await transfer.count
        await model.continueTask(stopped)
        #expect(model.errorMessage != nil)
        #expect(await transfer.count == before)
        #expect(model.snapshot?.resources.first?.control.fileState == .verified)
        #expect(model.snapshot?.downloads.count == 1)
        try await library.shutdown()
    }
}

// QUALITY-CLOSEOUT-20261026: event-driven ownership, no manager lifetime timer.
extension ModelLibraryPresentationTests {
    @Test func idleObservationAndRepeatedOpenDoNotScanOrProjectPeriodically() async throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"]))
            .appendingPathComponent("QualityIdle-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try await ModelLibrary(stateDirectory: root)
        let model = ModelLibraryModel(library: library)
        model.start(); model.start(); defer { model.stop() }
        for _ in 0..<500 { if model.snapshot != nil { break }; await Task.yield() }
        #expect(model.snapshot != nil)
        #expect(await library.observationCount == 1)
        model.isPresented = true
        await model.refresh(checkFiles: true)
        let checks = await library.availabilityCheckCount
        let publications = await library.statePublicationCount
        let projections = model.preparationProjectionCount
        try await Task.sleep(for: .milliseconds(900))
        model.isPresented = false
        try await Task.sleep(for: .milliseconds(900))
        #expect(await library.availabilityCheckCount == checks)
        #expect(await library.statePublicationCount == publications)
        #expect(model.preparationProjectionCount == projections)
        model.stop()
        for _ in 0..<500 { if await library.observationCount == 0 { break }; await Task.yield() }
        #expect(await library.observationCount == 0)
        model.start()
        for _ in 0..<500 { if await library.observationCount == 1 { break }; await Task.yield() }
        #expect(await library.observationCount == 1)
        try await library.shutdown()
    }

    @Test(arguments: ["zh-Hans", "en"])
    func unknownCatalogUsesLanguageResourceWithoutOpeningPanel(locale: String) async throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"]))
            .appendingPathComponent("QualityLanguage-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data(repeating: 0x41, count: 4096)
        let entry = ModelCatalogEntry(id: "quality-language", title: "Official fixture name", repository: "fixture/language", revision: String(repeating: "a", count: 40),
            files: [.init(path: "payload.bin", size: UInt64(bytes.count), sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())])
        let library = try await ModelLibrary(stateDirectory: root.appendingPathComponent("state"), catalog: [entry])
        let language = UILanguageStore(preferredLanguages: [locale]); try language.select(locale)
        let model = ModelLibraryModel(library: library, language: language)
        await model.refresh()
        let before = await library.snapshot()
        await model.registerExisting(catalogID: "unknown-fixture")
        #expect(model.errorMessage == (locale == "en" ? "The selected model is not in the built-in model catalog." : "所选模型不在内置模型目录中。"))
        #expect(!model.isChoosingLocation && model.globalOperation == nil)
        #expect(await library.snapshot() == before)
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try bytes.write(to: source.appendingPathComponent("payload.bin"))
        let id = try await library.registerExisting(at: source, catalogID: entry.id)
        await model.refresh()
        let record = try #require(model.snapshot?.records.first)
        #expect(model.status(for: record) == (locale == "en" ? "Files verified; the execution engine needs separate validation" : "文件已校验；执行引擎需单独验证"))
        var prepared = false
        await model.prepareVideo(id) { _, _ in prepared = true }
        #expect(!prepared && !model.isChoosingLocation)
        #expect(model.errorMessage?.contains(locale == "en" ? "complete preparation engine" : "完整准备引擎") == true)
        #expect(try Data(contentsOf: source.appendingPathComponent("payload.bin")) == bytes)
        try await library.shutdown()
    }
}

extension ModelLibraryPresentationTests {
    @Test func lastCompletionAcrossTwoAcquisitionsIsDrainedWithoutPolling() async throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"]))
            .appendingPathComponent("QualityBinding-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixed = Array(try ModelCatalog.entries().filter { $0.preparation == .none && $0.workflowIdentity != nil && $0.workflowProfileID != nil }.prefix(2))
        #expect(fixed.count == 2)
        let bytes = Data(repeating: 0x41, count: 4096)
        let entries = fixed.map { item in
            ModelCatalogEntry(id: item.id, title: item.title, repository: "fixture/events", revision: item.revision,
                files: [.init(path: "payload.bin", size: UInt64(bytes.count), sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())],
                workflowProfileID: item.workflowProfileID, workflowIdentity: item.workflowIdentity)
        }
        let transfer = PresentationTransfer(), gate = NodeBindingGate()
        await transfer.open()
        let library = try await ModelLibrary(stateDirectory: root.appendingPathComponent("state"), catalog: entries, transport: transfer)
        try await library.configureRoot(at: root)
        try await library.pauseQueue()
        let model = ModelLibraryModel(library: library)
        model.start(); defer { model.stop() }
        var entered = false, bound: [ModelID] = []
        await model.prepareNode(operationID: try #require(entries[0].workflowProfileID), identity: try #require(entries[0].workflowIdentity), isCurrent: { true }) { id, authorized in
            entered = true; await gate.wait()
            guard authorized() else { return }; bound.append(id)
        }
        await model.prepareNode(operationID: try #require(entries[1].workflowProfileID), identity: try #require(entries[1].workflowIdentity), isCurrent: { true }) { id, authorized in
            guard authorized() else { return }; bound.append(id)
        }
        model.isPresented = false; model.clearSelectionContext()
        try await library.resumeQueue()
        await gate.open()
        for _ in 0..<500 {
            if model.preparingNodeIdentities.isEmpty && model.snapshot?.resources.filter({ $0.record.registrationState == .registered }).count == 2 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(bound.isEmpty)
        #expect(model.snapshot?.resources.filter { $0.record.registrationState == .registered }.count == 2)
        #expect(model.preparingNodeIdentities.isEmpty)
        #expect(await library.availabilityCheckCount == 1, "Configure root only; byte events cannot scan files")
        #expect(await transfer.count == 2)
        await model.volumeChanged(URL(fileURLWithPath: "/Volumes/Unrelated-Quality-Fixture"))
        #expect(await library.availabilityCheckCount == 1, "Unrelated volume notification must not scan this library")
        try await library.shutdown()
    }
}

extension ModelLibraryPresentationTests {
    @Test func destroyingIdlePresentationReleasesSubscriptionWithoutAnotherEvent() async throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"]))
            .appendingPathComponent("QualityLifetime-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try await ModelLibrary(stateDirectory: root)
        var model: ModelLibraryModel? = ModelLibraryModel(library: library)
        weak var weakModel = model
        model?.start()
        for _ in 0..<500 { if model?.snapshot != nil { break }; await Task.yield() }
        #expect(await library.observationCount == 1)
        model = nil
        for _ in 0..<500 { if await library.observationCount == 0 { break }; await Task.yield() }
        #expect(weakModel == nil)
        #expect(await library.observationCount == 0)
        try await library.shutdown()
    }
}

extension ModelLibraryPresentationTests {
    @Test(arguments: [false, true])
    func missingTokenizerResourceButtonQueuesExactResourceWithoutResumingAll(clearHistory: Bool) async throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"]))
            .appendingPathComponent("TokenizerCommand-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = try #require(ModelCatalog.entries().first { $0.id == "wan21-t2v-1.3b-bf16" })
        let old = ModelCatalogEntry(id: entry.id, title: entry.title, repository: entry.repository, revision: entry.revision,
            files: Array(entry.files.prefix(3)), workflowProfileID: entry.workflowProfileID,
            workflowIdentity: entry.workflowIdentity, preparation: entry.preparation)
        let transfer = PresentationTransfer()
        var previous: ModelLibrary? = try await ModelLibrary(stateDirectory: root.appendingPathComponent("state"),
            catalog: [old], transport: transfer, availableBytesOverride: UInt64.max)
        try await previous!.configureRoot(at: root)
        let task = try await previous!.enqueueDownloads([old.id], postAction: .register, startIfIdle: false)[0]
        try await previous!.cancelDownload(task.id)
        if clearHistory { try await previous!.clearDownloadHistory([task.id]) }
        try await previous!.shutdown(); previous = nil
        let library = try await ModelLibrary(stateDirectory: root.appendingPathComponent("state"),
            catalog: [entry], transport: transfer, availableBytesOverride: UInt64.max)
        let model = ModelLibraryModel(library: library)
        await model.refresh()
        let resource = try #require(model.snapshot?.resources.first)
        #expect(resource.control.requiresTokenizerUpgrade == true)
        await model.continueResource(resource)
        #expect(model.errorMessage == nil)
        let queued = try #require(model.snapshot?.downloads.last)
        #expect(queued.resourceID == task.resourceID && queued.state == .queued)
        #expect(queued.postAction == (clearHistory ? .filesOnly : .register))
        let requests = await transfer.count
        #expect(!model.queueIsRunning && requests == 0)
        try await library.shutdown()
    }
}

extension ModelLibraryPresentationTests {
    @Test func acquisitionRequestDefaultsAndFailureDoNotEnqueueOrLoseSelection() async throws {
        let base = try #require(ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"])
        let root = URL(fileURLWithPath: base).appendingPathComponent("Acquisition-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data(repeating: 0x41, count: 4096), transfer = PresentationTransfer()
        let fixed = try #require(ModelCatalog.entries().first { $0.id == ModelCatalog.flux2ID })
        let entry = ModelCatalogEntry(id: fixed.id, title: "Isolated request", repository: "fixture/request", revision: fixed.revision,
            files: [.init(path: "payload.bin", size: UInt64(bytes.count), sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())],
            workflowProfileID: fixed.workflowProfileID, workflowIdentity: fixed.workflowIdentity)
        let fault = Mutex(true)
        let library = try await ModelLibrary(stateDirectory: root.appendingPathComponent("state"), catalog: [entry], transport: transfer,
            checkpoint: { phase in if phase == "enqueue.beforeWrite", fault.withLock({ $0 }) { throw ModelLibraryError.storage("isolated enqueue failure") } })
        try await library.configureRoot(at: root); try await library.pauseQueue()
        let model = ModelLibraryModel(library: library); await model.refresh()
        var bound = false
        await model.requestNodeAcquisition(operationID: try #require(entry.workflowProfileID), identity: try #require(entry.workflowIdentity), title: "Captured node", isCurrent: { true }) { _, _ in bound = true }
        let request = try #require(model.acquisitionRequest)
        #expect(request.catalogIDs == [entry.id] && request.target?.title == "Captured node")
        #expect(await library.snapshot().downloads.isEmpty && !bound)
        model.requestAcquisition(catalogIDs: []) // Cannot replace an unsubmitted request.
        #expect(model.acquisitionRequest?.id == request.id)
        await model.confirmAcquisition(requestID: request.id, entries: [entry], register: false, useTarget: false)
        #expect(model.acquisitionRequest?.id == request.id && model.errorMessage != nil)
        #expect(await library.snapshot().downloads.isEmpty && !bound)
        fault.withLock { $0 = false }
        await model.confirmAcquisition(requestID: request.id, entries: [entry], register: false, useTarget: false)
        let snapshot = await library.snapshot(), task = try #require(snapshot.downloads.first)
        #expect(task.postAction == .filesOnly && task.acquisitionSnapshot != nil && snapshot.queueState == .paused && !bound)
        #expect(model.acquisitionRequest == nil)
        model.requestAcquisition(catalogIDs: [entry.id]); let next = try #require(model.acquisitionRequest)
        await model.confirmAcquisition(requestID: request.id, entries: [entry], register: true, useTarget: false)
        let afterStale = await library.snapshot()
        #expect(model.acquisitionRequest?.id == next.id && afterStale.downloads.first?.postAction == .filesOnly)
        try await library.shutdown()
    }
}


extension ModelLibraryPresentationTests {
    @Test func acquisitionUsesVerifiedExternalCopyWithoutManagedDownload() async throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"]))
            .appendingPathComponent("AcquisitionExternal-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixed = try #require(ModelCatalog.entries().first { $0.id == ModelCatalog.flux2ID })
        let bytes = Data(repeating: 0x41, count: 4096), transfer = PresentationTransfer()
        let entry = ModelCatalogEntry(id: fixed.id, title: "Exact fixture", repository: "fixture/external", revision: fixed.revision,
            files: [.init(path: "payload.bin", size: UInt64(bytes.count), sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())],
            workflowProfileID: fixed.workflowProfileID, workflowIdentity: fixed.workflowIdentity)
        let source = root.appendingPathComponent("source"); try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try bytes.write(to: source.appendingPathComponent("payload.bin"))
        let library = try await ModelLibrary(stateDirectory: root.appendingPathComponent("state"), catalog: [entry], transport: transfer)
        let id = try await library.registerExisting(at: source, catalogID: entry.id)
        let model = ModelLibraryModel(library: library); await model.refresh()
        let resources = ModelLibraryModel.acquisitionResources(entry, snapshot: model.snapshot)
        #expect(resources.count == 1 && resources[0].record.storage == .external)
        var bound: ModelID?
        await model.requestNodeAcquisition(operationID: try #require(entry.workflowProfileID), identity: try #require(entry.workflowIdentity),
            title: "Exact fixture", isCurrent: { true }) { selected, authorized in
            #expect(authorized()); bound = selected
        }
        let request = try #require(model.acquisitionRequest)
        let beforeEvents = resources[0].control.events
        await model.confirmExistingRegistration(requestID: request.id, resource: resources[0], useTarget: true)
        let afterUse = await library.snapshot()
        #expect(afterUse.resources.first?.control.events == beforeEvents, "Selecting a registered model must not register it again")
        #expect(bound == id && model.acquisitionRequest == nil && model.errorMessage == nil)
        #expect(model.snapshot?.downloads.isEmpty == true && model.snapshot?.resources.count == 1)
        #expect(await transfer.count == 0)
        #expect(try Data(contentsOf: source.appendingPathComponent("payload.bin")) == bytes)
        try await library.shutdown()
    }
}


extension ModelLibraryPresentationTests {
    @Test func localFileSubmissionClearsOnlyCommittedDraft() async throws {
        let base = try #require(ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"])
        let root = URL(fileURLWithPath: base).appendingPathComponent("LocalDraft-" + UUID().uuidString)
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data(repeating: 0x41, count: 4096)
        let file = source.appendingPathComponent("payload.bin")
        try bytes.write(to: file)
        let entry = ModelCatalogEntry(id: "local-draft", title: "Local draft fixture", repository: "fixture/ui", revision: String(repeating: "a", count: 40),
            files: [.init(path: "payload.bin", size: UInt64(bytes.count), sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())])
        let library = try await ModelLibrary(stateDirectory: root.appendingPathComponent("state"), catalog: [entry])
        let model = ModelLibraryModel(library: library)
        await model.chooseLocalFiles(at: source, catalogID: entry.id)
        #expect(model.localFileSelection != nil)
        try Data(repeating: 0x42, count: 4096).write(to: file)
        let failed = await model.submitLocalFiles(storage: .external)
        #expect(!failed && model.localFileSelection != nil && model.errorMessage != nil)
        let afterFailure = await library.snapshot()
        #expect(afterFailure.records.allSatisfy { $0.registrationState != .registered })
        try bytes.write(to: file)
        await model.chooseLocalFiles(at: source, catalogID: entry.id)
        let saved = await model.submitLocalFiles(storage: .external)
        #expect(saved && model.localFileSelection == nil && model.errorMessage == nil)
        let afterSuccess = await library.snapshot()
        #expect(afterSuccess.records.filter { $0.registrationState == .registered }.count == 1)
        let duplicate = await model.submitLocalFiles(storage: .external)
        let afterDuplicate = await library.snapshot()
        #expect(!duplicate && afterDuplicate.records == afterSuccess.records)
        try await library.shutdown()
    }
}
