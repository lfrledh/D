import AppKit
import DWorkbench
import SwiftUI

/// AppKit hiding retains the pane's editor identity while removing hidden views
/// from input and key-view navigation. Resizing an open pane never hides it.
struct RetainedContentHost<Content: View>: NSViewRepresentable {
    let content: Content
    let visible: Bool
    let identifier: String
    var fallbackSize = CGSize(width: 240, height: 640)

    func makeNSView(context: Context) -> RetainedNativeHostingView<RetainedContentRoot<Content>> {
        let host = RetainedNativeHostingView(rootView: RetainedContentRoot(content: content, lifecycle: context.environment.metadataEditorLifecycle, background: context.environment.workbenchBackground, appearance: context.environment.workbenchAppearanceState, language: context.environment.dLanguageStore, widths: context.environment.workbenchPanelWidths, surfaceGroup: context.environment.workbenchSurfaceGroup, menuContext: context.environment.workbenchMenuContext, modelReadiness: context.environment.workbenchModelReadiness, preparation: context.environment.workflowModelPreparation, installations: context.environment.workflowModelInstallations, featureHelp: context.environment.workbenchHelpStore, contentVisible: visible && context.environment.workbenchContentVisible, childClose: context.environment.workbenchChildClose, modeSize: context.environment.workbenchModeSize, windowControlSize: context.environment.workbenchWindowControlSize, visualContext: WorkbenchVisualContext(context.environment)))
        host.sizingOptions = []
        host.setAccessibilityIdentifier(identifier)
        host.setInitialVisibility(visible)
        return host
    }
    func updateNSView(_ host: RetainedNativeHostingView<RetainedContentRoot<Content>>, context: Context) {
        #if DEBUG
        WorkbenchCategoryUpdateProbe.retainedUpdate?()
        #endif
        host.rootView = RetainedContentRoot(content: content, lifecycle: context.environment.metadataEditorLifecycle, background: context.environment.workbenchBackground, appearance: context.environment.workbenchAppearanceState, language: context.environment.dLanguageStore, widths: context.environment.workbenchPanelWidths, surfaceGroup: context.environment.workbenchSurfaceGroup, menuContext: context.environment.workbenchMenuContext, modelReadiness: context.environment.workbenchModelReadiness, preparation: context.environment.workflowModelPreparation, installations: context.environment.workflowModelInstallations, featureHelp: context.environment.workbenchHelpStore, contentVisible: visible && context.environment.workbenchContentVisible, childClose: context.environment.workbenchChildClose, modeSize: context.environment.workbenchModeSize, windowControlSize: context.environment.workbenchWindowControlSize, visualContext: WorkbenchVisualContext(context.environment))
        host.requestVisibility(visible)
    }
    static func dismantleNSView(_ host: RetainedNativeHostingView<RetainedContentRoot<Content>>, coordinator: ()) {
        host.invalidateVisibility()
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: RetainedNativeHostingView<RetainedContentRoot<Content>>, context: Context) -> CGSize? {
        .init(width: proposal.width ?? fallbackSize.width, height: proposal.height ?? fallbackSize.height)
    }
}

/// AppKit hiding may synchronously traverse sibling hosting views to find the
/// next key view. Doing that inside updateNSView re-enters AttributeGraph while
/// it is updating preferences. Keep one latest visibility request per host and
/// apply native hiding after that update stack has unwound.
@MainActor final class RetainedNativeHostingView<Content: View>: NSHostingView<Content> {
    private var desiredVisible = true
    private var visibilityQueued = false
    private var visibilityInvalidated = false

    func setInitialVisibility(_ visible: Bool) {
        desiredVisible = visible
        isHidden = !visible // Initial host is not attached to a window/key loop.
    }

    func requestVisibility(_ visible: Bool) {
        guard !visibilityInvalidated else { return }
        desiredVisible = visible
        guard !visibilityQueued, isHidden != !visible else { return }
        visibilityQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.visibilityInvalidated else { return }
            self.visibilityQueued = false
            if self.isHidden != !self.desiredVisible { self.isHidden = !self.desiredVisible }
        }
    }

    func invalidateVisibility() {
        visibilityInvalidated = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard desiredVisible, !visibilityInvalidated else { return nil }
        return super.hitTest(point)
    }
}


/// A fixed root type forwards the close gate through each native host boundary.
/// Updating the gate does not replace the editor's structural identity.
struct RetainedContentRoot<Content: View>: View {
    let content: Content
    let lifecycle: MetadataEditorLifecycle
    var background: WorkbenchBackgroundOwner? = nil
    var appearance: ChatDisplayPreferencesState? = nil
    var language: UILanguageStore? = nil
    var widths = WorkbenchPanelWidths()
    var surfaceGroup: String? = nil
    var menuContext = "window"
    var modelReadiness: [String: SharedLibraryReadiness] = [:]
    var preparation: WorkflowModelPreparationState? = nil
    var installations: [String: ModelID] = [:]
    var featureHelp: WorkbenchHelpStore? = nil
    var contentVisible = true
    var childClose: WorkbenchChildCloseGate? = nil
    var modeSize = CGSize(width: 232, height: 52)
    var windowControlSize = CGSize(width: 80, height: 32)
    var visualContext: WorkbenchVisualContext? = nil
    private var visual: WorkbenchVisualContext {
        var value = visualContext ?? .init()
        value.state = appearance; value.background = background; value.language = language
        return value
    }
    var body: some View {
        content.environment(\.workbenchChildClose, childClose).environment(\.metadataEditorLifecycle, lifecycle)
            .environment(\.workbenchModeSize, modeSize)
            .environment(\.workbenchWindowControlSize, windowControlSize)
            .environment(\.workbenchContentVisible, contentVisible)
            .environment(\.workbenchBackground, background)
            .environment(\.workbenchAppearanceState, appearance)
            .environment(\.dLanguageStore, language)
            .environment(\.locale, Locale(identifier: language?.effectiveLanguageIdentifier ?? Locale.current.identifier))
            .environment(\.workbenchPanelWidths, widths)
            .environment(\.workbenchSurfaceGroup, surfaceGroup)
            .environment(\.workbenchMenuContext, menuContext)
            .environment(\.workbenchModelReadiness, modelReadiness)
            .environment(\.workflowModelPreparation, preparation)
            .environment(\.workflowModelInstallations, installations)
            .environment(\.workbenchHelpStore, featureHelp)
            .modifier(WorkbenchVisualBridge(context: visual))
    }
}

private struct WorkbenchContentVisibleKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    var workbenchContentVisible: Bool {
        get { self[WorkbenchContentVisibleKey.self] }
        set { self[WorkbenchContentVisibleKey.self] = newValue }
    }
}
