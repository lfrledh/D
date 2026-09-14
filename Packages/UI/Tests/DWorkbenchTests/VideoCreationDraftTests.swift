import DInference
@testable import DWorkbench
import Foundation
import Testing

struct VideoCreationDraftTests {
    @Test func exactSnapshotAndInvalidEditingRoundTrip() throws {
        var draft = VideoCreationDraft(prompt: "中文 👩🏽‍🎨 e\u{301}", memoryBudgetMiBText: "20480")
        let request = try draft.makeRequest()
        #expect(request.width == 832 && request.height == 480 && request.frameCount == 17)
        #expect(request.steps == 50 && request.seed == 42)
        #expect(try draft.selectedMemoryBudgetBytes() == 20 * 1024 * 1024 * 1024)
        draft.framesText = "1未完成"
        let reopened = try JSONDecoder().decode(VideoCreationDraft.self, from: JSONEncoder().encode(draft))
        #expect(reopened.prompt.utf8.elementsEqual(draft.prompt.utf8))
        #expect(reopened.framesText == draft.framesText)
        #expect(throws: InferenceFailure.self) { try reopened.makeRequest() }
        #expect(request.frameCount == 17)
    }

    @Test func budgetDoesNotGuessOrCapAtDeveloperHardware() throws {
        var draft = VideoCreationDraft(prompt: "test")
        #expect(try draft.selectedMemoryBudgetBytes() == nil)
        for invalid in ["0", "-1", "1.5", " 20", "18446744073709551615", "１２"] {
            draft.memoryBudgetMiBText = invalid
            #expect(throws: InferenceFailure.self) { try draft.selectedMemoryBudgetBytes() }
        }
        draft.memoryBudgetMiBText = "196608"
        #expect(try draft.selectedMemoryBudgetBytes() == 192 * 1024 * 1024 * 1024)
        draft.framesText = "18"
        #expect(throws: InferenceFailure.self) { try draft.makeRequest() }
        draft.framesText = "17"; draft.seedText = "4294967296"
        #expect(throws: InferenceFailure.self) { try draft.makeRequest() }
    }
}
