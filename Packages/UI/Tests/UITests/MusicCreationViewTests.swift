import DInference
@testable import DWorkbench
import Testing
@testable import UI

@Suite("Music creation view", .serialized)
@MainActor
struct MusicCreationViewTests {
    @Test
    func musicProfileRequiresAnAvailableHostAndARealNoteWhenEnabled() {
        var draft = AudioCreationDraft(prompt: "木吉他", profile: .conditionedMusic,
                                       music: .init(notes: [], hasNoteCondition: true))
        #expect(!AudioCreationButtonHandler.canSubmit(draft, source: nil, hostAllowsGeneration: true,
                                                       hasPendingRangeInput: false))
        draft.music?.notes = [.init(pitchText: "C4", startText: "0", durationText: "1")]
        #expect(AudioCreationButtonHandler.canSubmit(draft, source: nil, hostAllowsGeneration: true,
                                                      hasPendingRangeInput: false))
        #expect(!AudioCreationButtonHandler.canSubmit(draft, source: nil, hostAllowsGeneration: false,
                                                       hasPendingRangeInput: false))
    }

    @Test
    func musicProfileKeepsConditionRowsAndDoesNotPermitSourceOperations() {
        let row = MusicNoteDraft(pitchText: "not-yet-valid", startText: "-", durationText: "")
        let draft = AudioCreationDraft(prompt: "钢琴", operation: .generate, editRegion: nil,
                                       profile: .conditionedMusic,
                                       music: .init(notes: [row], hasNoteCondition: true))
        #expect(draft.music?.notes == [row])
        #expect(draft.operation == .generate)
        #expect(draft.editRegion == nil)
        #expect(!AudioCreationButtonHandler.canGenerate(draft, source: nil))
    }
}
