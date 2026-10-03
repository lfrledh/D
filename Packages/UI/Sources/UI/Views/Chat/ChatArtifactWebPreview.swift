import AppKit
import Foundation
import SwiftUI
import WebKit

/// A local, bounded HTML/SVG surface. The owner presents errors and decides when to retry.
public struct ChatArtifactWebPreview: NSViewRepresentable {
    public let source: String
    public let javaScriptEnabled: Bool
    public let onError: @MainActor (ChatArtifactWebPreviewError) -> Void

    public init(source: String, javaScriptEnabled: Bool = false,
                onError: @escaping @MainActor (ChatArtifactWebPreviewError) -> Void) {
        self.source = source
        self.javaScriptEnabled = javaScriptEnabled
        self.onError = onError
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeNSView(context: Context) -> NSView { NSView() }

    public func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update(in: nsView, source: source,
                                   javaScriptEnabled: javaScriptEnabled, onError: onError)
    }

    public static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.close()
    }

    @MainActor
    public final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private var source: String?
        private var javaScriptEnabled = false
        private var onError: (@MainActor (ChatArtifactWebPreviewError) -> Void)?
        private var generation = UUID()
        private var webView: WKWebView?
        private var ruleIdentifier: String?
        private var initialNavigationPending = false
        private enum LoadPhase { case bootstrap, source }
        private var loadPhase: LoadPhase?
        private var bootstrapTimeout: Task<Void, Never>?
        private let ruleStore: WKContentRuleListStore? = WKContentRuleListStore.default()

        func update(in container: NSView, source newSource: String,
                                javaScriptEnabled newJavaScriptEnabled: Bool,
                                onError newOnError: @escaping @MainActor (ChatArtifactWebPreviewError) -> Void) {
            onError = newOnError
            guard source != newSource || javaScriptEnabled != newJavaScriptEnabled else { return }
            closeViewer()
            source = newSource
            javaScriptEnabled = newJavaScriptEnabled
            let currentGeneration = generation

            if let error = ChatArtifactWebPreviewPolicy.preflightError(
                source: newSource, javaScriptEnabled: newJavaScriptEnabled) {
                onError?(error)
                return
            }

            guard let ruleStore else {
                onError?(.protectionUnavailable)
                return
            }

            let identifier = "d.chat.artifact.preview.\(UUID().uuidString)"
            ruleIdentifier = identifier
            ruleStore.compileContentRuleList(forIdentifier: identifier,
                                              encodedContentRuleList: ChatArtifactWebPreviewPolicy.contentRules) {
                [weak self, weak container, store = ruleStore] ruleList, error in
                guard let self, self.generation == currentGeneration,
                      let container, let ruleList, error == nil else {
                    // A replacement or close can race compilation. No stale document may load.
                    store.removeContentRuleList(forIdentifier: identifier) { _ in }
                    if let self, self.generation == currentGeneration {
                        self.onError?(.protectionUnavailable)
                    }
                    return
                }
                self.install(in: container, source: newSource,
                             javaScriptEnabled: newJavaScriptEnabled, ruleList: ruleList)
            }
        }

        private func install(in container: NSView, source: String, javaScriptEnabled: Bool,
                             ruleList: WKContentRuleList) {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.userContentController.add(ruleList)
            configuration.defaultWebpagePreferences.allowsContentJavaScript = javaScriptEnabled
            if javaScriptEnabled {
                // Public, page-scoped preference. The bootstrap also checks the resulting JS world.
                configuration.defaultWebpagePreferences.isLockdownModeEnabled = true
                guard configuration.defaultWebpagePreferences.isLockdownModeEnabled else {
                    onError?(.protectionUnavailable)
                    return
                }
            }
            configuration.mediaTypesRequiringUserActionForPlayback = .all

            let viewer = WKWebView(frame: container.bounds, configuration: configuration)
            viewer.autoresizingMask = [.width, .height]
            viewer.navigationDelegate = self
            viewer.uiDelegate = self
            viewer.allowsLinkPreview = false
            webView = viewer
            initialNavigationPending = true
            loadPhase = javaScriptEnabled ? .bootstrap : .source
            container.addSubview(viewer)
            if javaScriptEnabled {
                // Untrusted source is held outside WebKit until the trusted, empty page is guarded.
                viewer.loadHTMLString(ChatArtifactWebPreviewPolicy.bootstrapDocument, baseURL: nil)
                let currentGeneration = generation
                bootstrapTimeout = Task { @MainActor [weak self, weak viewer] in
                    try? await Task.sleep(for: .seconds(5))
                    guard let self, let viewer, self.generation == currentGeneration,
                          self.webView === viewer, self.loadPhase == .bootstrap else { return }
                    self.fail(.protectionUnavailable, for: viewer)
                }
            } else {
                // The CSP precedes every byte of the untrusted document; no base URL or file grant.
                viewer.loadHTMLString(ChatArtifactWebPreviewPolicy.document(source,
                                                                            javaScriptEnabled: false), baseURL: nil)
            }
        }

        private func closeViewer() {
            generation = UUID()
            bootstrapTimeout?.cancel()
            bootstrapTimeout = nil
            loadPhase = nil
            initialNavigationPending = false
            if let webView {
                webView.stopLoading()
                webView.navigationDelegate = nil
                webView.uiDelegate = nil
                webView.removeFromSuperview()
            }
            webView = nil
            if let ruleIdentifier, let ruleStore {
                ruleStore.removeContentRuleList(forIdentifier: ruleIdentifier) { _ in }
            }
            ruleIdentifier = nil
        }

        func close() {
            closeViewer()
            source = nil
            onError = nil
        }

        private func fail(_ error: ChatArtifactWebPreviewError, for viewer: WKWebView) {
            guard webView === viewer else { return }
            closeViewer()
            onError?(error)
        }

        public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard self.webView === webView, loadPhase == .bootstrap else { return }
            let currentGeneration = generation
            webView.evaluateJavaScript(ChatArtifactWebPreviewPolicy.bootstrapProbe) { [weak self, weak webView] result, error in
                guard let self, let webView, self.generation == currentGeneration,
                      self.webView === webView, self.loadPhase == .bootstrap else { return }
                guard error == nil, result as? Bool == true, let source = self.source else {
                    self.fail(.protectionUnavailable, for: webView)
                    return
                }
                self.bootstrapTimeout?.cancel()
                self.bootstrapTimeout = nil
                self.loadPhase = .source
                self.initialNavigationPending = true
                webView.loadHTMLString(ChatArtifactWebPreviewPolicy.document(source,
                                                                             javaScriptEnabled: true), baseURL: nil)
            }
        }

        public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                            preferences: WKWebpagePreferences,
                            decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
            let initial = self.webView === webView && initialNavigationPending
                && navigationAction.targetFrame?.isMainFrame == true
                && navigationAction.navigationType == .other
                && navigationAction.request.url?.absoluteString == "about:blank"
            if initial { initialNavigationPending = false }
            // Check the per-navigation value before WebKit can run source scripts.
            let guarded = !javaScriptEnabled || (preferences.isLockdownModeEnabled
                && preferences.allowsContentJavaScript)
            decisionHandler(initial && guarded ? .allow : .cancel, preferences)
            if initial && !guarded { fail(.protectionUnavailable, for: webView) }
        }

        public func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                            decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            let internalDocument = self.webView === webView && navigationResponse.isForMainFrame
                && navigationResponse.response.url?.absoluteString == "about:blank"
            decisionHandler(internalDocument ? .allow : .cancel)
        }

        public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                            withError error: Error) {
            fail(.loadFailed, for: webView)
        }

        public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            fail(.loadFailed, for: webView)
        }

        public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            fail(.contentProcessTerminated, for: webView)
        }

        public func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
                completionHandler(.performDefaultHandling, nil)
            } else {
                completionHandler(.rejectProtectionSpace, nil)
            }
        }

        public func webView(_ webView: WKWebView, authenticationChallenge challenge: URLAuthenticationChallenge,
                            shouldAllowDeprecatedTLS decisionHandler: @escaping (Bool) -> Void) {
            decisionHandler(false)
        }

        public func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                            for navigationAction: WKNavigationAction,
                            windowFeatures: WKWindowFeatures) -> WKWebView? { nil }

        public func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                            initiatedBy frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            completionHandler()
        }

        public func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                            initiatedBy frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            completionHandler(false)
        }

        public func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                            defaultText: String?, initiatedBy frame: WKFrameInfo,
                            completionHandler: @escaping (String?) -> Void) {
            completionHandler(nil)
        }

        public func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                            initiatedBy frame: WKFrameInfo,
                            completionHandler: @escaping ([URL]?) -> Void) {
            completionHandler(nil)
        }

        public func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                            initiatedBy frame: WKFrameInfo, type: WKMediaCaptureType,
                            decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            decisionHandler(.deny)
        }

        @available(macOS 27.0, *)
        public func webView(_ webView: WKWebView, requestGeolocationPermissionFor origin: WKSecurityOrigin,
                            initiatedBy frame: WKFrameInfo,
                            decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            decisionHandler(.deny)
        }
    }
}

public enum ChatArtifactWebPreviewError: Error, Equatable {
    case sourceTooLarge
    case protectionUnavailable
    case javaScriptUnsupported
    case loadFailed
    case contentProcessTerminated
}

enum ChatArtifactWebPreviewPolicy {
    static let maximumSourceBytes = 1_048_576

    static func accepts(_ source: String) -> Bool {
        source.utf8.count <= maximumSourceBytes
    }

    static func preflightError(source: String, javaScriptEnabled: Bool) -> ChatArtifactWebPreviewError? {
        if !accepts(source) { return .sourceTooLarge }
        return nil
    }

    // Last matching ignore rule allows only in-document data images and the loadHTMLString document.
    // All other resource requests are blocked before the first document is loaded.
    static let contentRules = """
        [{"trigger":{"url-filter":".*"},"action":{"type":"block"}},
         {"trigger":{"url-filter":"^data:image/","resource-type":["image"]},"action":{"type":"ignore-previous-rules"}},
         {"trigger":{"url-filter":"^about:blank$","resource-type":["document"]},"action":{"type":"ignore-previous-rules"}}]
        """

    static let bootstrapDocument = document("", javaScriptEnabled: true)

    // Evaluated only in the trusted empty document. Lockdown is also checked through
    // the public navigation preference; a visible RTC constructor fails closed.
    static let bootstrapProbe = """
        (() => {
          const known = ['RTCPeerConnection', 'webkitRTCPeerConnection',
            'mozRTCPeerConnection', 'RTCDataChannel', 'webkitRTCDataChannel'];
          const names = Object.getOwnPropertyNames(globalThis);
          return !known.some(name => typeof globalThis[name] === 'function')
            && !names.some(name => /rtc|peerconnection/i.test(name)
              && typeof globalThis[name] === 'function');
        })()
        """

    static func document(_ source: String, javaScriptEnabled: Bool = false) -> String {
        let scripts = javaScriptEnabled
            ? "script-src 'unsafe-inline'; script-src-attr 'unsafe-inline'; "
            : "script-src 'none'; script-src-attr 'none'; "
        let policy = "default-src 'none'; img-src data:; style-src 'unsafe-inline'; "
            + scripts + "connect-src 'none'; "
            + "worker-src 'none'; frame-src 'none'; child-src 'none'; font-src 'none'; "
            + "media-src 'none'; object-src 'none'; form-action 'none'; base-uri 'none'"
        return "<!doctype html><html><head><meta charset=\"utf-8\"><meta http-equiv=\"Content-Security-Policy\" content=\"\(policy)\"></head><body>\(source)</body></html>"
    }
}
