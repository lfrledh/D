import DWorkbench
import Foundation
import Testing
@testable import UI

@Suite
struct TextSelectionEditorTests {
    @Test func replacementUsesExactUTF8BytesRatherThanCanonicalStringEquality() {
        #expect(TextSelectionEditorState.needsTextReplacement(current: "e\u{301}", incoming: "é"))
        #expect(!TextSelectionEditorState.needsTextReplacement(current: "👩‍💻", incoming: "👩‍💻"))
    }

    @Test func rangeRequiresCharacterAlignedNonEmptyUTF16Selection() throws {
        let document = try TextDraftDocument(text: "中e\u{301}👩‍💻🇯🇵Z")
        #expect(TextSelectionEditorState.validRange(NSRange(location: 1, length: 2), in: document) != nil)
        #expect(TextSelectionEditorState.validRange(NSRange(location: 2, length: 1), in: document) == nil)
        #expect(TextSelectionEditorState.validRange(NSRange(location: 3, length: 1), in: document) == nil)
        #expect(TextSelectionEditorState.validRange(NSRange(location: 0, length: 0), in: document) == nil)
    }

    @Test func programmaticStateCanRecognizeNoTextReplacement() {
        #expect(!TextSelectionEditorState.needsTextReplacement(current: "原稿", incoming: "原稿"))
    }
}
