import DWorkbench
import Foundation
import Testing
@testable import UI

@Suite("Chat artifact editor state and previews")
struct ChatArtifactEditorTests {
    private func artifact(_ kind: ChatArtifactContent.Kind = .plainText,
                          text: String = "original", published: Bool = false) -> ChatArtifactContent {
        let output: WorkflowAssetReference? = published
            ? .init(projectID: UUID(), assetID: UUID(), kind: .document, sha256: "published") : nil
        return .init(sessionID: UUID(), title: "Source", kind: kind, text: text, output: output)
    }

    private func published(_ submitted: ChatArtifactContent) -> ChatArtifactContent {
        var result = submitted
        result.output = .init(projectID: UUID(), assetID: UUID(), kind: .text, sha256: "saved")
        return result
    }

    @Test @MainActor func immutableSubmittedSnapshotAndReturnedBaseline() async {
        let state = ChatArtifactEditorState(content: artifact())
        state.updateTitle("Edited")
        state.updateText("before save")
        var firstSubmission: ChatArtifactContent?
        await state.save { submitted in
            firstSubmission = submitted
            try await Task.sleep(for: .milliseconds(1))
            state.updateText("after submit")
            return published(submitted)
        }
        #expect(firstSubmission?.revision == 1)
        #expect(firstSubmission?.text == "before save")
        #expect(firstSubmission?.output == nil)
        #expect(state.baseline.text == "before save")
        #expect(state.baseline.output != nil)
        #expect(state.draft.text == "after submit")
        #expect(state.draft.revision == 1)
        #expect(state.isDirty)

        await state.save { submitted in
            #expect(submitted.id == firstSubmission?.id)
            #expect(submitted.sessionID == firstSubmission?.sessionID)
            #expect(submitted.revision == 2)
            #expect(submitted.text == "after submit")
            #expect(submitted.output == nil)
            return published(submitted)
        }
        #expect(state.baseline.revision == 2)
        #expect(state.draft.revision == 2)
        #expect(!state.isDirty)
        #expect(!state.canSave)
    }

    @Test @MainActor func canonicalUnicodeEditsAreDirtyAndSurviveSaveAwait() async {
        let decomposed = "e\u{301}"
        let composed = "\u{e9}"
        var original = artifact(text: decomposed, published: true)
        original.title = decomposed
        let state = ChatArtifactEditorState(content: original)
        state.updateTitle(composed)
        state.updateText(composed)
        #expect(state.isDirty)
        #expect(state.canSave)
        #expect(state.draft.title.utf8.elementsEqual(composed.utf8))
        #expect(state.draft.text.utf8.elementsEqual(composed.utf8))

        await state.save { submitted in
            #expect(submitted.revision == 2)
            #expect(submitted.title.utf8.elementsEqual(composed.utf8))
            #expect(submitted.text.utf8.elementsEqual(composed.utf8))
            try await Task.sleep(for: .milliseconds(1))
            state.updateTitle(decomposed)
            state.updateText(decomposed)
            return published(submitted)
        }
        #expect(state.issue == nil)
        #expect(state.baseline.title.utf8.elementsEqual(composed.utf8))
        #expect(state.baseline.text.utf8.elementsEqual(composed.utf8))
        #expect(state.draft.title.utf8.elementsEqual(decomposed.utf8))
        #expect(state.draft.text.utf8.elementsEqual(decomposed.utf8))
        #expect(state.isDirty)
        #expect(state.canSave)
    }

    @Test @MainActor func receiptRejectsCanonicallyEqualButByteDifferentFields() async {
        let decomposed = "e\u{301}"
        let composed = "\u{e9}"

        let titleState = ChatArtifactEditorState(content: artifact(published: true))
        titleState.updateTitle(decomposed)
        await titleState.save { submitted in
            var returned = published(submitted)
            returned.title = composed
            return returned
        }
        #expect(titleState.issue?.contains("did not match") == true)
        #expect(titleState.baseline.revision == 1)
        #expect(titleState.draft.title.utf8.elementsEqual(decomposed.utf8))

        let textState = ChatArtifactEditorState(content: artifact(published: true))
        textState.updateText(decomposed)
        await textState.save { submitted in
            var returned = published(submitted)
            returned.text = composed
            return returned
        }
        #expect(textState.issue?.contains("did not match") == true)
        #expect(textState.baseline.revision == 1)
        #expect(textState.draft.text.utf8.elementsEqual(decomposed.utf8))
    }

    @Test @MainActor func failedSaveKeepsDraftAndPublishedBaseline() async {
        let original = artifact(.markdown, text: "old", published: true)
        let state = ChatArtifactEditorState(content: original)
        state.updateText("new 🎨")
        await state.save { submitted in
            #expect(submitted.revision == 2)
            #expect(submitted.output == nil)
            throw NSError(domain: "save", code: 7, userInfo: [NSLocalizedDescriptionKey: "Disk unavailable"])
        }
        #expect(state.baseline == original)
        #expect(state.draft.text == "new 🎨")
        #expect(state.isDirty)
        #expect(state.canSave)
        #expect(state.issue == "Disk unavailable")
        var didClose = false
        state.requestClose { didClose = true }
        #expect(state.asksToDiscard)
        #expect(!didClose)

        await state.save { submitted in
            let wrong = ChatArtifactContent(id: submitted.id, revision: submitted.revision,
                sessionID: UUID(), title: submitted.title, kind: submitted.kind,
                text: submitted.text, source: submitted.source, output: published(submitted).output)
            return wrong
        }
        #expect(state.baseline == original)
        #expect(state.draft.text == "new 🎨")
        #expect(state.issue?.contains("did not match") == true)

        await state.save { $0 }
        #expect(state.baseline == original)
        #expect(state.draft.text == "new 🎨")
        #expect(state.issue?.contains("no published output") == true)
    }

    @Test @MainActor func saveIsSingleFlightAndCleanCloseNeedsNoDiscard() async {
        let state = ChatArtifactEditorState(content: artifact(published: true))
        state.updateText("changed")
        var calls = 0
        await state.save { submitted in
            calls += 1
            await state.save { _ in
                calls += 1
                return submitted
            }
            return published(submitted)
        }
        #expect(calls == 1)
        #expect(!state.isSaving)
        var closed = false
        state.requestClose { closed = true }
        #expect(closed)
        #expect(!state.asksToDiscard)
    }

    @Test @MainActor func plainMarkdownCodeAndWebFormatsStayExplicit() {
        for kind in [ChatArtifactContent.Kind.plainText, .markdown, .code, .html, .svg] {
            let state = ChatArtifactEditorState(content: artifact(kind, text: "<b>text</b>"))
            state.togglePreview(mermaidDocument: nil)
            #expect(state.preview?.kind == kind)
            #expect(state.preview?.text == "<b>text</b>")
            #expect(state.preview?.javaScriptEnabled == false)
            if kind == .html || kind == .svg {
                #expect(state.preview?.webDocument == "<b>text</b>")
            } else {
                #expect(state.preview?.webDocument == nil)
            }
        }

        let html = ChatArtifactEditorState(content: artifact(.html, text: "<p>old</p>"))
        html.togglePreview(mermaidDocument: nil)
        html.setJavaScriptEnabled(true)
        #expect(html.previewNeedsRefresh)
        #expect(html.preview == nil)
        html.refreshPreview(mermaidDocument: nil)
        #expect(html.preview?.javaScriptEnabled == true)
        html.updateText("<script>changed()</script>")
        #expect(html.javaScriptEnabled == false)
        #expect(html.previewNeedsRefresh)
        #expect(html.preview == nil)
        html.refreshPreview(mermaidDocument: nil)
        #expect(html.preview?.javaScriptEnabled == false)
        #expect(html.preview?.text == "<script>changed()</script>")
    }

    @Test @MainActor func mermaidRequiresSuppliedRendererAndNeverUsesAPlaceholderParser() {
        let state = ChatArtifactEditorState(content: artifact(.mermaid, text: "graph TD; A-->B"))
        state.togglePreview(mermaidDocument: nil)
        #expect(state.preview == nil)
        #expect(state.previewIssue?.contains("no local renderer") == true)
        state.refreshPreview { source in
            #expect(source == "graph TD; A-->B")
            return "<svg id='local'></svg><script>render()</script>"
        }
        #expect(state.preview?.webDocument?.contains("id='local'") == true)
        #expect(state.preview?.javaScriptEnabled == true)
        #expect(state.previewIssue == nil)
    }

    @Test @MainActor func csvEscapesScriptAndParsesQuotedUnicodeAndNewlines() throws {
        let html = try ChatArtifactCSVPreview.document("name,content\r\n🎨,\"<script>alert('x')</script> & \"\"quote\"\"\nnext\"\r\n")
        #expect(html.contains("🎨"))
        #expect(html.contains("&lt;script&gt;alert(&#39;x&#39;)&lt;/script&gt;"))
        #expect(html.contains("&amp; &quot;quote&quot;\nnext"))
        #expect(!html.contains("<script>"))
        #expect(html.components(separatedBy: "<tr>").count == 3)
        #expect(throws: ChatArtifactEditorError.self) {
            try ChatArtifactCSVPreview.document("a,\"unterminated")
        }
        #expect(throws: ChatArtifactEditorError.self) {
            try ChatArtifactCSVPreview.document("a,b\n1,\"x\"y")
        }
        #expect(throws: ChatArtifactEditorError.self) {
            try ChatArtifactCSVPreview.document(String(repeating: "x\n", count: 201))
        }
        #expect(throws: ChatArtifactEditorError.self) {
            try ChatArtifactCSVPreview.document(String(repeating: "<", count: 300_000))
        }
    }

    @Test @MainActor func csvSyntaxAndEscapingRecognizeASCIIBeforeCombiningMarks() throws {
        let combining = "\u{301}"
        let html = try ChatArtifactCSVPreview.document("a,\(combining)b\n\"\(combining)c\",<\(combining)d")
        let table = "<table><tr><td>a</td><td>\(combining)b</td></tr><tr><td>\(combining)c</td><td>&lt;\(combining)d</td></tr></table>"
        // String.components uses grapheme-aware matching; compare the complete
        // escaped table bytes so a combining mark at a tag boundary is not a false oracle.
        #expect(html.utf8.suffix(table.utf8.count).elementsEqual(table.utf8))

    }
}
