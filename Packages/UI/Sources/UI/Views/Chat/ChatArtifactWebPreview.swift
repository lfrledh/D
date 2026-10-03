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
        private let ruleStore: WKContentRuleListStore? = WKContentRuleListStore.default()

        fileprivate func update(in container: NSView, source newSource: String,
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
                self.install(in: container, source: newSource, ruleList: ruleList)
            }
        }

        private func install(in container: NSView, source: String, ruleList: WKContentRuleList) {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.userContentController.add(ruleList)
            configuration.defaultWebpagePreferences.allowsContentJavaScript = false
            configuration.mediaTypesRequiringUserActionForPlayback = .all

            let viewer = WKWebView(frame: container.bounds, configuration: configuration)
            viewer.autoresizingMask = [.width, .height]
            viewer.navigationDelegate = self
            viewer.uiDelegate = self
            viewer.allowsLinkPreview = false
            webView = viewer
            initialNavigationPending = true
            container.addSubview(viewer)
            // The CSP precedes every byte of the untrusted document; no base URL or file grant.
            viewer.loadHTMLString(ChatArtifactWebPreviewPolicy.document(source), baseURL: nil)
        }

        private func closeViewer() {
            generation = UUID()
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

        fileprivate func close() {
            closeViewer()
            source = nil
            onError = nil
        }

        private func fail(_ error: ChatArtifactWebPreviewError, for viewer: WKWebView) {
            guard webView === viewer else { return }
            closeViewer()
            onError?(error)
        }

        public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let initial = self.webView === webView && initialNavigationPending
                && navigationAction.targetFrame?.isMainFrame == true
                && navigationAction.navigationType == .other
                && navigationAction.request.url?.absoluteString == "about:blank"
            if initial { initialNavigationPending = false }
            decisionHandler(initial ? .allow : .cancel)
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
        // CSP and resource rules do not isolate JavaScript RTC/STUN traffic.
        if javaScriptEnabled { return .javaScriptUnsupported }
        return nil
    }

    // Last matching ignore rule allows only in-document data images and the loadHTMLString document.
    // All other resource requests are blocked before the first document is loaded.
    static let contentRules = """
        [{"trigger":{"url-filter":".*"},"action":{"type":"block"}},
         {"trigger":{"url-filter":"^data:image/","resource-type":["image"]},"action":{"type":"ignore-previous-rules"}},
         {"trigger":{"url-filter":"^about:blank$","resource-type":["document"]},"action":{"type":"ignore-previous-rules"}}]
        """

    static func document(_ source: String) -> String {
        let policy = "default-src 'none'; img-src data:; style-src 'unsafe-inline'; "
            + "script-src 'none'; script-src-attr 'none'; connect-src 'none'; "
            + "worker-src 'none'; frame-src 'none'; child-src 'none'; font-src 'none'; "
            + "media-src 'none'; object-src 'none'; form-action 'none'; base-uri 'none'"
        return "<!doctype html><html><head><meta charset=\"utf-8\"><meta http-equiv=\"Content-Security-Policy\" content=\"\(policy)\"></head><body>\(source)</body></html>"
    }
}
