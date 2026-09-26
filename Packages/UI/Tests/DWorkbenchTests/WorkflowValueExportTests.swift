import Foundation
import Testing
@testable import DWorkbench

struct WorkflowValueExportTests {
    @Test func aggregateBudgetRejectsBeforeEncoding() throws {
        let large = WorkflowDatum.list(element: .text, items: (0..<20).map { .init(id: String($0), value: .text(String(repeating: "a", count: 1_048_576))) })
        try large.validate()
        #expect(throws: WorkflowIssue.self) { try WorkflowValueExportBudget.validate(large) }
        try WorkflowValueExportBudget.validate(.text("中文 \u{0000} \" e\u{301}"))
    }

    @Test func typedExportRoundTripsAndRefusesOverwrite() async throws {
        let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let store = try await ProjectStore.create(at: base.appendingPathComponent("试用.dproject"), name: "试用")
        let before = await store.snapshot(), id = UUID()
        let value = WorkflowDatum.record(schema: [.init("标题", .text), .init("速度", .number(unit: "BPM"))], fields: ["标题": .text("中文 🇯🇵 e\u{301}"), "速度": .number(120, unit: "BPM")])
        let receipt = try await store.exportWorkflowDatum(value, format: "json", name: "结构", exportID: id, directory: base)
        let file = base.appendingPathComponent("结构-\(id.uuidString).dexport/1.json")
        let original = try Data(contentsOf: file)
        #expect(try JSONDecoder().decode(WorkflowDatum.self, from: original) == value)
        #expect(try await store.exportWorkflowDatum(value, format: "json", name: "结构", exportID: id, directory: base) == receipt)
        do { _ = try await store.exportWorkflowDatum(.text("replace"), format: "json", name: "结构", exportID: id, directory: base); Issue.record("overwrote export") } catch {}
        #expect(try Data(contentsOf: file) == original); #expect(await store.snapshot() == before)
        try await store.close()
    }
    @Test func notesExportAsMIDIAndUnknownAssetIsRejected() async throws {
        let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let store = try await ProjectStore.create(at: base.appendingPathComponent("music.dproject"), name: "music")
        let value = try WorkflowNoteSequence(clock: .seconds, notes: [.init(id: "a", pitch: 60, start: 0, end: 1, velocity: 0.5)], duration: 1).datum()
        let id = UUID(); _ = try await store.exportWorkflowDatum(value, format: "midi", name: "notes", exportID: id, directory: base)
        let bytes = try Data(contentsOf: base.appendingPathComponent("notes-\(id.uuidString).dexport/1.mid"))
        #expect(bytes.starts(with: Data("MThd".utf8)))
        let fake = WorkflowAssetReference(projectID: UUID(), assetID: UUID(), kind: .audio, sha256: String(repeating: "a", count: 64))
        do { _ = try await store.exportWorkflowDatum(.asset(fake), format: "json", name: "bad", exportID: UUID(), directory: base); Issue.record("accepted foreign source") } catch {}
        try await store.close()
    }
}
