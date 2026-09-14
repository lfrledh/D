import DInference
import Foundation
import Testing
@testable import DWorkbench

@Suite("Text sources immutable prompt history")
struct TextSourcesPromptVersionTests {
    @Test("A fixed archive from the previous implementation opens without rebuilding its fixture")
    func frozenLegacyArchive() throws {
        let note = try TextSourcesArchive.decode(TextSourcesLegacyFixture.archive)
        #expect(note.records.count == 1)
        let record = try #require(note.records.first)
        #expect(record.submission.request.prompt.hasPrefix("请仅根据下列资料片段回答问题。"))
        #expect(record.submission.request.prompt.contains("[S序号]"))
        #expect(try note.sources.first?.validatedText() == "项目代号是蓝桉。会议地点是京都。资料没有说明预算、参与人数或日期。")
        let encoded = try TextSourcesArchive.encode(note)
        let reopened = try TextSourcesArchive.decode(encoded)
        #expect(reopened == note)
        #expect(Array(reopened.records[0].submission.request.prompt.utf8) == Array(record.submission.request.prompt.utf8))
    }

    @Test("A real previously saved project opens without changing original manifest bytes")
    func frozenLegacyProject() async throws {
        try await withLegacyProject { root in
            let original = try Data(contentsOf: root.appendingPathComponent("project.json"))
            let store = try await ProjectStore.open(at: root)
            let current = await store.snapshot()
            #expect(current.schemaVersion == 10)
            #expect(current.activeDocument?.textSources?.records.count == 1)
            try await store.close()
            #expect(try Data(contentsOf: root.appendingPathComponent("project.json")) == original)
        }
    }

    private func withLegacyProject(_ body: (URL) async throws -> Void) async throws {
        let base = ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        let root = base.appendingPathComponent("sources-legacy-\(UUID()).dproject")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try TextSourcesLegacyFixture.project.write(to: root.appendingPathComponent("project.json"), options: .withoutOverwriting)
        try await body(root)
    }
}
