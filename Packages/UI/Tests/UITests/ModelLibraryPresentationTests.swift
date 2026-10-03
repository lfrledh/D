import Foundation
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
