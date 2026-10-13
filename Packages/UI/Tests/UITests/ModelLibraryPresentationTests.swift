import Foundation
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
