import Foundation
import Testing
@testable import UI

@Suite("Chat artifact HTML policy")
struct ChatArtifactWebPreviewTests {
    @Test func utf8LimitAcceptsExactBoundaryAndRejectsCompleteOversizeSource() {
        let exact = String(repeating: "a", count: ChatArtifactWebPreviewPolicy.maximumSourceBytes)
        #expect(ChatArtifactWebPreviewPolicy.accepts(exact))
        #expect(!ChatArtifactWebPreviewPolicy.accepts(exact + "a"))

        let unicode = String(repeating: "🖼", count: ChatArtifactWebPreviewPolicy.maximumSourceBytes / 4)
        #expect(ChatArtifactWebPreviewPolicy.accepts(unicode))
        #expect(!ChatArtifactWebPreviewPolicy.accepts(unicode + "🖼"))
    }

    @Test func preflightRejectsRequestedJavaScript() {
        #expect(ChatArtifactWebPreviewPolicy.preflightError(
            source: "<script>new RTCPeerConnection()</script>", javaScriptEnabled: true)
            == .javaScriptUnsupported)
        #expect(ChatArtifactWebPreviewPolicy.preflightError(
            source: "<svg></svg>", javaScriptEnabled: false) == nil)
        let oversize = String(repeating: "x", count: ChatArtifactWebPreviewPolicy.maximumSourceBytes + 1)
        #expect(ChatArtifactWebPreviewPolicy.preflightError(
            source: oversize, javaScriptEnabled: true) == .sourceTooLarge)
    }

    @Test func compiledRulesBlockByDefaultWithOnlyInternalDocumentAndDataImageExceptions() throws {
        let data = Data(ChatArtifactWebPreviewPolicy.contentRules.utf8)
        let rules = try #require(JSONSerialization.jsonObject(with: data) as? [[String: [String: Any]]])
        #expect(rules.count == 3)
        #expect(rules[0]["trigger"]?["url-filter"] as? String == ".*")
        #expect(rules[0]["action"]?["type"] as? String == "block")
        #expect(rules[1]["trigger"]?["url-filter"] as? String == "^data:image/")
        #expect(rules[1]["trigger"]?["resource-type"] as? [String] == ["image"])
        #expect(rules[2]["trigger"]?["url-filter"] as? String == "^about:blank$")
        #expect(rules[2]["trigger"]?["resource-type"] as? [String] == ["document"])
        #expect(rules.dropFirst().allSatisfy { $0["action"]?["type"] as? String == "ignore-previous-rules" })
    }

    @Test func cspPrecedesUntrustedHTMLAndDeniesScriptsAndConnections() throws {
        let source = "<html><head><base href='https://remote.invalid/'></head><body><script>window.x=1</script></body></html>"
        let document = ChatArtifactWebPreviewPolicy.document(source)
        let csp = try #require(document.range(of: "http-equiv=\"Content-Security-Policy\""))
        let untrusted = try #require(document.range(of: source))
        #expect(csp.lowerBound < untrusted.lowerBound)
        #expect(document.contains("default-src 'none'"))
        #expect(document.contains("script-src 'none'"))
        #expect(document.contains("script-src-attr 'none'"))
        #expect(document.contains("connect-src 'none'"))
        #expect(document.contains("worker-src 'none'"))
        #expect(document.contains("frame-src 'none'"))
        #expect(document.contains("font-src 'none'"))
        #expect(document.contains("form-action 'none'"))
        #expect(document.contains("base-uri 'none'"))
    }
}
