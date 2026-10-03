import Foundation
import Testing
@testable import DWorkbench

@Suite("Quick category navigation", .serialized) @MainActor
struct QuickCategoryTests {
    @Test func selectionPreservesDraftsPortsAndDoesNotExecute() async throws {
        let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent("category-" + UUID().uuidString + ".dproject")
        let store = try await ProjectStore.create(at: base, name: "category")
        var calls = 0
        let c = QuickGenerationController(store: store) { calls += 1; throw WorkflowIssue("not requested") }
        await c.load()
        c.select(operationID: WorkflowModelRoutes.qwen35, modelID: "text:fixture")
        let text = try #require(c.draft?.id)
        c.setParameter("task", value: .text("草稿 e\u{301} 🙂"), draftID: text)
        c.setInput("content", value: .data(.text("参考材料")), draftID: text)
        #expect(c.definition?.inputs.contains(where: { $0.id == "images" }) == true)
        #expect(c.definition?.inputs.contains(where: { $0.id == "video" }) == true)
        c.selectCategory(.audio); #expect(c.draft == nil)
        c.select(operationID: "d.image.generate", modelID: "image:fixture")
        #expect(c.category == .image)
        c.selectCategory(.video); #expect(c.draft == nil)
        c.selectCategory(.text)
        #expect(c.draft?.node.parameters["task"] == .text("草稿 e\u{301} 🙂"))
        #expect(c.draft?.inputs["content"] == .data(.text("参考材料")))
        #expect(calls == 0)
        try await c.flush(); let saved = c.state
        try await store.close()
        let reopened = try await ProjectStore.open(at: base)
        let restored = QuickGenerationController(store: reopened) { throw WorkflowIssue("no execution") }
        await restored.load(); #expect(restored.state == saved); #expect(restored.category == .text)
        restored.selectCategory(.image); #expect(restored.draft?.node.parameters["modelID"] == .text("image:fixture"))
        try await restored.prepareForTermination(); try await reopened.close()
    }
    @Test func oldStateHasNoInventedNavigationAndInvalidReferenceIsRejected() throws {
        let old = Data(#"{"version":1,"revision":0,"drafts":[],"runs":[]}"#.utf8)
        let state = try JSONDecoder().decode(QuickCreationState.self, from: old)
        #expect(state.navigation == nil); try state.validate()
        var invalid = state; invalid.navigation = .init(selected: .text, lastDrafts: ["text":"missing"])
        #expect(throws: (any Error).self) { try invalid.validate() }
        #expect(QuickCategory.category(for: WorkflowModelRoutes.qwen35) == .text)
        #expect(QuickCategory.category(for: WorkflowModelRoutes.ace) == .audio)
        #expect(QuickCategory.category(for: "d.video.generate") == .video)
    }
}
