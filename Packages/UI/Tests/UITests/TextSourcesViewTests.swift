import DWorkbench
import Foundation
import Testing
@testable import UI

struct TextSourcesViewTests {
    @Test func selectionAcceptsChineseAndCombinedEmojiOnlyAtCharacterBoundaries() throws {
        let source = try source(text: "中文👩‍👩‍👧‍👦资料", name: "中文.txt")
        let text = try source.validatedText() as NSString
        let emoji = text.range(of: "👩‍👩‍👧‍👦")
        var state = TextSourcesSelectionState()
        state.select(source)
        state.record(emoji, for: source)
        #expect(state.excerptRange(for: source) == emoji)

        state.record(NSRange(location: emoji.location + 1, length: emoji.length - 1), for: source)
        #expect(state.excerptRange(for: source) == nil)
    }

    @Test func selectionCannotCrossSourceIDOrRevisionAndClearsOnSwitch() throws {
        let original = try source(text: "第一份资料", name: "one.txt")
        let replacement = try TextSourceSnapshot(id: UUID(), revision: UUID(), displayName: "two.txt", bytes: Data("第二份资料".utf8))
        let sameIDNewRevision = try TextSourceSnapshot(id: original.id, revision: UUID(), displayName: "one.txt", bytes: original.bytes)
        var state = TextSourcesSelectionState()
        state.select(original)
        state.record(NSRange(location: 0, length: 2), for: original)
        #expect(state.excerptRange(for: original) != nil)
        #expect(state.excerptRange(for: replacement) == nil)
        #expect(state.excerptRange(for: sameIDNewRevision) == nil)

        state.select(replacement)
        #expect(state.excerptRange(for: replacement) == nil)
        #expect(state.excerptRange(for: original) == nil)
    }

    @Test func selectionRejectsCollapsedAndOutOfBoundsRanges() throws {
        let source = try source(text: "资料内容", name: "range.txt")
        var state = TextSourcesSelectionState()
        state.select(source)
        state.record(NSRange(location: 1, length: 0), for: source)
        #expect(state.excerptRange(for: source) == nil)
        state.record(NSRange(location: 99, length: 1), for: source)
        #expect(state.excerptRange(for: source) == nil)
    }

    @Test func selectionSurvivesQuestionAndAnswerRevisionsWhenExactSourceSurvives() throws {
        let source = try source(text: "保留选择", name: "keep.txt")
        var state = TextSourcesSelectionState()
        state.select(source)
        state.record(NSRange(location: 0, length: 2), for: source)
        state.reconcile(with: [source])
        #expect(state.excerptRange(for: source) != nil)
        state.reconcile(with: [])
        #expect(state.excerptRange(for: source) == nil)
    }

    @Test func questionPresentationAlwaysUsesCallerAcceptedValueAfterRejectedEdit() {
        let accepted = "A"
        let rejected = accepted + String(repeating: "B", count: 16 * 1_024 + 1)
        #expect(TextSourcesQuestionPresentation.displayedQuestion(accepted) == accepted)
        #expect(TextSourcesQuestionPresentation.needsReplacement(current: rejected, accepted: accepted))
        #expect(!TextSourcesQuestionPresentation.needsReplacement(current: accepted, accepted: accepted))
    }

    @Test func historyPresentationUsesExactFrozenSourceIdentityAndLocalizedDisposition() throws {
        let original = try source(text: "保留的片段", name: "同名.txt")
        let sameNameReplacement = try TextSourceSnapshot(id: UUID(), revision: UUID(), displayName: "同名.txt", bytes: Data("新资料".utf8))
        let excerpt = try TextSourceExcerpt(source: original, range: NSRange(location: 0, length: 2))
        #expect(TextSourcesHistoryPresentation.excerpts(for: original, in: [excerpt]).count == 1)
        #expect(TextSourcesHistoryPresentation.excerpts(for: sameNameReplacement, in: [excerpt]).isEmpty)
        #expect(TextSourcesHistoryPresentation.disposition(.accepted) == "已采用")
        #expect(TextSourcesHistoryPresentation.disposition(.rejected) == "已拒绝")
    }

    @Test func narrowLayoutUsesWholePanelScrollAndAdaptableSourceActions() {
        #expect(TextSourcesLayoutPolicy.stacksVertically(width: 600))
        #expect(TextSourcesLayoutPolicy.usesWholePanelScroll(width: 600))
        #expect(!TextSourcesLayoutPolicy.stacksSourceActions(width: 600))
        #expect(TextSourcesLayoutPolicy.stacksSourceActions(width: 480))
        #expect(!TextSourcesLayoutPolicy.usesWholePanelScroll(width: 760))
    }

    private func source(text: String, name: String) throws -> TextSourceSnapshot {
        try TextSourceSnapshot(displayName: name, bytes: Data(text.utf8))
    }
}
