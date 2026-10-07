import AppKit
import SwiftUI

/// AppKit hiding retains the pane's editor identity while removing hidden views
/// from input and key-view navigation. Resizing an open pane never hides it.
struct RetainedContentHost<Content: View>: NSViewRepresentable {
    let content: Content
    let visible: Bool
    let identifier: String
    var fallbackSize = CGSize(width: 240, height: 640)

    func makeNSView(context: Context) -> NSHostingView<Content> {
        let host = NSHostingView(rootView: content)
        host.sizingOptions = []
        host.setAccessibilityIdentifier(identifier)
        host.isHidden = !visible
        return host
    }
    func updateNSView(_ host: NSHostingView<Content>, context: Context) {
        host.rootView = content
        // Only an actual close/open changes native visibility. Hiding can release
        // the first responder; a layout change must not transiently hide an editor.
        if host.isHidden != !visible { host.isHidden = !visible }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSHostingView<Content>, context: Context) -> CGSize? {
        .init(width: proposal.width ?? fallbackSize.width, height: proposal.height ?? fallbackSize.height)
    }
}

