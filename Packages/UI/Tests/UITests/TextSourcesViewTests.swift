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

    @Test func historyRowsFollowFrozenExcerptOrderAndExactSourceIdentity() throws {
        let first = try source(text: "第一份资料", name: "同名.txt")
        let second = try source(text: "第二份资料", name: "同名.txt")
        let secondExcerpt = try TextSourceExcerpt(source: second, range: NSRange(location: 0, length: 2))
        let firstExcerpt = try TextSourceExcerpt(source: first, range: NSRange(location: 0, length: 2))
        let rows = TextSourcesHistoryPresentation.excerptRows(sources: [first, second], excerpts: [secondExcerpt, firstExcerpt])
        #expect(rows.map(\.label) == ["[S1]", "[S2]"])
        #expect(rows.map(\.sourceDigest) == [second.sha256, first.sha256])
        #expect(rows.map(\.sourceRevision) == [second.revision, first.revision])
        #expect(rows.allSatisfy { $0.sourceName == "同名.txt" })
    }

    @Test func historyRowsKeepMultipleExcerptsForOneSourceInExcerptOrder() throws {
        let original = try source(text: "甲乙丙丁", name: "one.txt")
        let first = try TextSourceExcerpt(source: original, range: NSRange(location: 0, length: 1))
        let second = try TextSourceExcerpt(source: original, range: NSRange(location: 2, length: 1))
        let rows = TextSourcesHistoryPresentation.excerptRows(sources: [original], excerpts: [first, second])
        #expect(rows.map(\.label) == ["[S1]", "[S2]"])
        #expect(rows.map(\.text) == ["甲", "丙"])
        #expect(rows.allSatisfy { $0.sourceDigest == original.sha256 && $0.sourceRevision == original.revision })
    }

    @Test func historyPresentationLocalizesDisposition() {
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
