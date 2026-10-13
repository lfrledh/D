import Foundation
import CryptoKit
import Darwin
import Observation
import Synchronization
import Testing
@testable import DWorkbench
import UI

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
    var continuation: CheckedContinuation<Void, Never>?
    func download(_ range: ModelByteRange, to descriptor: Int32) async throws {
        count += 1; started = true
        await withCheckedContinuation { continuation = $0 }
        let data = Data(repeating: 0x41, count: Int(range.end - range.start + 1))
        try ModelDirectory.write(data, to: descriptor)
        guard fsync(descriptor) == 0 else { throw ModelLibraryError.storage("Fixture fsync failed") }
    }
    func open() { continuation?.resume(); continuation = nil }
}
