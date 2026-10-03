import AppKit
import Foundation
import Testing
import WebKit
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

    @Test func preflightBoundsBothModesAndInteractiveRequiresBootstrap() {
        #expect(ChatArtifactWebPreviewPolicy.preflightError(
            source: "<script>new RTCPeerConnection()</script>", javaScriptEnabled: true)
            == nil)
        #expect(ChatArtifactWebPreviewPolicy.preflightError(
            source: "<svg></svg>", javaScriptEnabled: false) == nil)
        let oversize = String(repeating: "x", count: ChatArtifactWebPreviewPolicy.maximumSourceBytes + 1)
        #expect(ChatArtifactWebPreviewPolicy.preflightError(
            source: oversize, javaScriptEnabled: true) == .sourceTooLarge)
        #expect(ChatArtifactWebPreviewPolicy.bootstrapDocument.contains("Content-Security-Policy"))
        #expect(!ChatArtifactWebPreviewPolicy.bootstrapDocument.contains("RTCPeerConnection"))
        #expect(ChatArtifactWebPreviewPolicy.bootstrapProbe.contains("peerconnection"))
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

        let interactive = ChatArtifactWebPreviewPolicy.document(source, javaScriptEnabled: true)
        let interactiveCSP = try #require(interactive.range(of: "http-equiv=\"Content-Security-Policy\""))
        let interactiveSource = try #require(interactive.range(of: source))
        #expect(interactiveCSP.lowerBound < interactiveSource.lowerBound)
        #expect(interactive.contains("script-src 'unsafe-inline'"))
        #expect(interactive.contains("script-src-attr 'unsafe-inline'"))
        #expect(!interactive.contains("'unsafe-eval'"))
        #expect(interactive.contains("connect-src 'none'"))
        #expect(interactive.contains("worker-src 'none'"))
        #expect(interactive.contains("frame-src 'none'"))
        #expect(interactive.contains("media-src 'none'"))
        #expect(interactive.contains("object-src 'none'"))
    }

    @Test @MainActor func realViewerRunsLocalDOMOnlyInInteractiveMode() async throws {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        let coordinator = ChatArtifactWebPreview.Coordinator()
        var errors: [ChatArtifactWebPreviewError] = []
        defer { coordinator.close() }
        let source = """
            <style>#out { color: rgb(7, 8, 9); }</style>
            <input id="entry" value="before"><button id="go">Apply</button>
            <output id="out">idle</output><output id="eval">unknown</output>
            <script>
              document.getElementById('go').addEventListener('click', () => {
                document.getElementById('out').textContent = document.getElementById('entry').value;
              });
              try { eval('1'); document.getElementById('eval').textContent = 'enabled'; }
              catch (_) { document.getElementById('eval').textContent = 'blocked'; }
            </script>
            """

        coordinator.update(in: container, source: source, javaScriptEnabled: false) { errors.append($0) }
        #expect(await waitUntil {
            guard let viewer = viewer(in: container) else { return false }
            return await inspect(viewer, "document.getElementById('out')?.textContent") == "idle"
        })
        let staticViewer = try #require(viewer(in: container))
        #expect(await inspect(staticViewer, "getComputedStyle(document.getElementById('out')).color") == "rgb(7, 8, 9)")
        #expect(await inspect(staticViewer, "document.getElementById('eval').textContent") == "unknown")
        #expect(await inspect(staticViewer, "document.getElementById('go').click(); document.getElementById('out').textContent") == "idle")

        coordinator.update(in: container, source: source, javaScriptEnabled: true) { errors.append($0) }
        #expect(await waitUntil {
            guard let current = viewer(in: container), current !== staticViewer else { return false }
            return await inspect(current, "document.getElementById('eval')?.textContent") == "blocked"
        })
        let interactiveViewer = try #require(viewer(in: container))
        #expect(interactiveViewer !== staticViewer)
        #expect(interactiveViewer.configuration.websiteDataStore.isPersistent == false)
        #expect(interactiveViewer.configuration.defaultWebpagePreferences.isLockdownModeEnabled)
        #expect(await inspect(interactiveViewer, "getComputedStyle(document.getElementById('out')).color") == "rgb(7, 8, 9)")
        #expect(await inspect(interactiveViewer, "document.getElementById('entry').value='after'; document.getElementById('go').click(); document.getElementById('out').textContent") == "after")
        #expect(await inspect(interactiveViewer, "String(!Object.getOwnPropertyNames(globalThis).some(n => /rtc|peerconnection/i.test(n) && typeof globalThis[n] === 'function'))") == "true")
        #expect(await inspect(interactiveViewer, "String(!(window.webkit && window.webkit.messageHandlers && Object.keys(window.webkit.messageHandlers).length))") == "true")
        #expect(errors.isEmpty)
    }

    @Test @MainActor func realViewerDeniesNavigationWindowFileAndMediaAndInvalidatesOldLoads() async throws {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        let coordinator = ChatArtifactWebPreview.Coordinator()
        var errors: [ChatArtifactWebPreviewError] = []
        defer { coordinator.close() }
        let deniedSource = """
            <output id="ready">no</output><output id="popup">unknown</output>
            <output id="media">unknown</output><input id="file" type="file">
            <a id="nav" href="data:text/html,navigated">leave</a>
            <script>
              document.getElementById('ready').textContent = 'yes';
              try { document.getElementById('popup').textContent =
                !window.open('data:text/html,popup') ? 'denied' : 'opened'; }
              catch (_) { document.getElementById('popup').textContent = 'denied'; }
              try { navigator.mediaDevices.getUserMedia({audio:true}).then(
                () => document.getElementById('media').textContent = 'granted',
                () => document.getElementById('media').textContent = 'denied'); }
              catch (_) { document.getElementById('media').textContent = 'denied'; }
            </script>
            """
        coordinator.update(in: container, source: deniedSource, javaScriptEnabled: true) { errors.append($0) }
        #expect(await waitUntil {
            guard let current = viewer(in: container) else { return false }
            return await inspect(current, "document.getElementById('ready')?.textContent") == "yes"
        })
        let first = try #require(viewer(in: container))
        #expect(await inspect(first, "document.getElementById('popup').textContent") == "denied")
        #expect(await waitUntil { await inspect(first, "document.getElementById('media').textContent") == "denied" })
        #expect(await inspect(first, "document.getElementById('file').click(); String(document.getElementById('file').files.length)") == "0")
        #expect(await inspect(first, "document.getElementById('nav').click(); String(location.href)") == "about:blank")
        try? await Task.sleep(for: .milliseconds(150))
        #expect(first.url?.absoluteString == "about:blank")
        #expect(await inspect(first, "document.getElementById('ready')?.textContent") == "yes")

        coordinator.update(in: container, source: "<output id='which'>stale</output>",
                           javaScriptEnabled: true) { errors.append($0) }
        #expect(await waitUntil { viewer(in: container) != nil && viewer(in: container) !== first })
        let stale = try #require(viewer(in: container))
        coordinator.update(in: container, source: "<output id='which'>current</output>",
                           javaScriptEnabled: true) { errors.append($0) }
        #expect(await waitUntil {
            guard let current = viewer(in: container), current !== stale else { return false }
            return await inspect(current, "document.getElementById('which')?.textContent") == "current"
        })
        #expect(viewer(in: container) !== first)
        let current = try #require(viewer(in: container))
        coordinator.update(in: container, source: "<script>document.body.textContent='closed stale'</script>",
                           javaScriptEnabled: true) { errors.append($0) }
        #expect(await waitUntil { viewer(in: container) != nil && viewer(in: container) !== current })
        coordinator.close()
        try? await Task.sleep(for: .milliseconds(150))
        #expect(viewer(in: container) == nil)
        #expect(errors.isEmpty)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["D_CHAT_PREVIEW_PROBE_URL"] != nil))
    @MainActor func optionalExplicitLoopbackProbe() async throws {
        let raw = try #require(ProcessInfo.processInfo.environment["D_CHAT_PREVIEW_PROBE_URL"])
        let url = try #require(URL(string: raw))
        #expect(url.scheme == "http")
        #expect(["127.0.0.1", "localhost", "::1"].contains(url.host ?? ""))
        guard url.scheme == "http", ["127.0.0.1", "localhost", "::1"].contains(url.host ?? "") else { return }
        let encoded = try JSONSerialization.data(withJSONObject: [raw])
        let literal = try #require(String(data: encoded, encoding: .utf8))
        let source = """
            <output id="probe">waiting</output><script>
              const u = \(literal)[0];
              try { fetch(u + '?kind=fetch').catch(() => {}); } catch (_) {}
              try { const x = new XMLHttpRequest(); x.open('GET', u + '?kind=xhr'); x.send(); } catch (_) {}
              try { new WebSocket(u.replace(/^http/, 'ws') + '?kind=websocket'); } catch (_) {}
              try { const i = new Image(); i.src = u + '?kind=image'; document.body.append(i); } catch (_) {}
              document.getElementById('probe').textContent = 'attempted';
              try { location.href = u + '?kind=navigation'; } catch (_) {}
            </script>
            """
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        let coordinator = ChatArtifactWebPreview.Coordinator()
        var errors: [ChatArtifactWebPreviewError] = []
        defer { coordinator.close() }
        coordinator.update(in: container, source: source, javaScriptEnabled: true) { errors.append($0) }
        #expect(await waitUntil {
            guard let current = viewer(in: container) else { return false }
            return await inspect(current, "document.getElementById('probe')?.textContent") == "attempted"
        })
        try? await Task.sleep(for: .seconds(1))
        #expect(viewer(in: container)?.url?.absoluteString == "about:blank")
        #expect(errors.isEmpty)
        // The configured loopback server's request log is the external observation.
    }
}

@MainActor private func viewer(in container: NSView) -> WKWebView? {
    container.subviews.compactMap { $0 as? WKWebView }.first
}

@MainActor private func inspect(_ viewer: WKWebView, _ script: String) async -> String? {
    await withCheckedContinuation { continuation in
        viewer.evaluateJavaScript(script) { value, error in
            continuation.resume(returning: error == nil ? value as? String : nil)
        }
    }
}

@MainActor private func waitUntil(_ condition: @escaping @MainActor () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(8)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(30))
    }
    return false
}
