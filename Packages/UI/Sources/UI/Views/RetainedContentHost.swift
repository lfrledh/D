import AppKit
import SwiftUI

/// AppKit hiding retains the pane's editor identity while removing hidden views
/// from input and key-view navigation. Resizing an open pane never hides it.
struct RetainedContentHost<Content: View>: NSViewRepresentable {
    let content: Content
    let visible: Bool
    let identifier: String
    var fallbackSize = CGSize(width: 240, height: 640)

    func makeNSView(context: Context) -> NSHostingView<RetainedContentRoot<Content>> {
        let host = NSHostingView(rootView: RetainedContentRoot(content: content, lifecycle: context.environment.metadataEditorLifecycle, background: context.environment.workbenchBackground, appearance: context.environment.workbenchAppearanceState))
        host.sizingOptions = []
        host.setAccessibilityIdentifier(identifier)
        host.isHidden = !visible
        return host
    }
    func updateNSView(_ host: NSHostingView<RetainedContentRoot<Content>>, context: Context) {
        #if DEBUG
        WorkbenchCategoryUpdateProbe.retainedUpdate?()
        #endif
        host.rootView = RetainedContentRoot(content: content, lifecycle: context.environment.metadataEditorLifecycle, background: context.environment.workbenchBackground, appearance: context.environment.workbenchAppearanceState)
        // Only an actual close/open changes native visibility. Hiding can release
        // the first responder; a layout change must not transiently hide an editor.
        if host.isHidden != !visible { host.isHidden = !visible }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSHostingView<RetainedContentRoot<Content>>, context: Context) -> CGSize? {
        .init(width: proposal.width ?? fallbackSize.width, height: proposal.height ?? fallbackSize.height)
    }
}


/// A fixed root type forwards the close gate through each native host boundary.
/// Updating the gate does not replace the editor's structural identity.
struct RetainedContentRoot<Content: View>: View {
    let content: Content
    let lifecycle: MetadataEditorLifecycle
    var background: WorkbenchBackgroundOwner? = nil
    var appearance: ChatDisplayPreferencesState? = nil
    var body: some View {
        content.environment(\.metadataEditorLifecycle, lifecycle)
            .environment(\.workbenchBackground, background)
            .environment(\.workbenchAppearanceState, appearance)
            .buttonStyle(WorkbenchGlassButtonStyle())
            .menuStyle(WorkbenchGlassMenuStyle())
    }
}
