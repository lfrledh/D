import DWorkbench
import Foundation
import Testing
@testable import UI

@Suite("Project file status presentation")
struct ProjectFilesPresentationTests {
    @Test func missingReferenceStaysMissingAndPartialResultStaysPartial() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent("file-presentation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.txt")
        try Data("fixed source".utf8).write(to: source)
        let store = try await ProjectStore.create(at: root.appendingPathComponent("Work.dproject"), name: "Work")
        let published = try await store.importWorkflowMediaFile(at: source, mode: .reference)
        let initial = try await store.assetLocationOverview(published.asset.id)
        #expect(ProjectFilesPresentation.selectedStatus(initial) == .verified)
        try FileManager.default.removeItem(at: source)
        let missing = try await store.assetLocationOverview(published.asset.id, deep: true)
        #expect(ProjectFilesPresentation.selectedStatus(missing) == .missing)
        let results = try await store.collectProjectMedia()
        #expect(!ProjectFilesPresentation.allSucceeded(results))
        try await store.close()
    }
}
