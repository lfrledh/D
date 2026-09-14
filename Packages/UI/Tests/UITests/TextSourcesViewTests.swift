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

    private func source(text: String, name: String) throws -> TextSourceSnapshot {
        try TextSourceSnapshot(displayName: name, bytes: Data(text.utf8))
    }
}
