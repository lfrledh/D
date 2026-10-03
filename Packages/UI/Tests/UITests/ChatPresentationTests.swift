import Foundation
import SwiftUI
import Testing
@testable import UI

@Suite("Chat presentation boundaries")
struct ChatPresentationTests {
    @Test func literalSourceRemainsAvailableDuringStreamingAndParseDelay() {
        let final = "# Answer\n\n| A | B |\n|---|---|\n| 1 | 2 |"
        let original = "<think>reasoning</think>\n" + final
        #expect(ChatMarkdownPresentation.literalText(rendered: final, raw: original, streaming: true,
            showingRaw: false, parsed: nil, hasDocument: false) == final)
        #expect(ChatMarkdownPresentation.literalText(rendered: final, raw: original, streaming: false,
            showingRaw: false, parsed: nil, hasDocument: false) == final)
        #expect(ChatMarkdownPresentation.literalText(rendered: final, raw: original, streaming: false,
            showingRaw: true, parsed: final, hasDocument: true) == original)
        #expect(ChatMarkdownPresentation.literalText(rendered: final, raw: original, streaming: false,
            showingRaw: false, parsed: final, hasDocument: true) == nil)
    }

    @Test func markdownCannotLoadImagesOrOpenModelLinks() {
        #expect(!ChatMarkdownPresentation.config.imageConfig.enabled)
        if case .discarded = ChatMarkdownPresentation.discardURL(URL(string: "https://example.invalid/model")!) {
            // The action actually injected into the rendered document declines links.
        } else {
            Issue.record("Chat Markdown must decline link activation")
        }
    }

    @Test func sharedAssetDropRequiresExactStoreInstance() {
        let project = UUID(), original = UUID(), copy = UUID()
        #expect(ChatAssetDropScope.accepts(projectID: project, instanceID: original,
            manifestProjectID: project, manifestInstanceID: original))
        #expect(!ChatAssetDropScope.accepts(projectID: project, instanceID: original,
            manifestProjectID: project, manifestInstanceID: copy))
        #expect(!ChatAssetDropScope.accepts(projectID: UUID(), instanceID: original,
            manifestProjectID: project, manifestInstanceID: original))
        #expect(!ChatAssetDropScope.accepts(projectID: project, instanceID: nil,
            manifestProjectID: project, manifestInstanceID: copy))
        #expect(ChatAssetDropScope.accepts(projectID: project, instanceID: nil,
            manifestProjectID: project, manifestInstanceID: project))
    }
}
