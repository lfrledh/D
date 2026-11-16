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
    // Full-window pages share the parent's measured safe navigation inset.
    // Native child hosts otherwise apply the title area's inset a second time.
    var inheritsWindowSafeArea = true
    // Opt in only for full-window pages retained behind another workspace.
    var preservesHiddenSize = false

    func makeNSView(context: Context) -> NSView {
        let host = RetainedNativeHostingView(rootView: RetainedContentRoot(content: content, lifecycle: context.environment.metadataEditorLifecycle, background: context.environment.workbenchBackground, appearance: context.environment.workbenchAppearanceState, language: context.environment.dLanguageStore, widths: context.environment.workbenchPanelWidths, surfaceGroup: context.environment.workbenchSurfaceGroup, menuContext: context.environment.workbenchMenuContext, modelReadiness: context.environment.workbenchModelReadiness, preparation: context.environment.workflowModelPreparation, installations: context.environment.workflowModelInstallations, featureHelp: context.environment.workbenchHelpStore, contentVisible: visible && context.environment.workbenchContentVisible, childClose: context.environment.workbenchChildClose, tips: context.environment.workbenchTips, sidebars: context.environment.workbenchSidebars, navigationTop: context.environment.workbenchNavigationTop, navigationModeWidth: context.environment.workbenchNavigationModeWidth, windowControlSize: context.environment.workbenchWindowControlSize, visualContext: WorkbenchVisualContext(context.environment)))
        host.sizingOptions = []
        if !inheritsWindowSafeArea { host.safeAreaRegions = [] }
        host.setAccessibilityIdentifier(identifier)
        host.setInitialVisibility(visible)
        if preservesHiddenSize { return RetainedGeometryView(host: host, visible: visible) }
        return host
    }
    func updateNSView(_ view: NSView, context: Context) {
        let wrapper = view as? RetainedGeometryView<RetainedContentRoot<Content>>
        let host = wrapper?.host ?? (view as! RetainedNativeHostingView<RetainedContentRoot<Content>>)
        #if DEBUG
        WorkbenchCategoryUpdateProbe.retainedUpdate?()
        #endif
        host.rootView = RetainedContentRoot(content: content, lifecycle: context.environment.metadataEditorLifecycle, background: context.environment.workbenchBackground, appearance: context.environment.workbenchAppearanceState, language: context.environment.dLanguageStore, widths: context.environment.workbenchPanelWidths, surfaceGroup: context.environment.workbenchSurfaceGroup, menuContext: context.environment.workbenchMenuContext, modelReadiness: context.environment.workbenchModelReadiness, preparation: context.environment.workflowModelPreparation, installations: context.environment.workflowModelInstallations, featureHelp: context.environment.workbenchHelpStore, contentVisible: visible && context.environment.workbenchContentVisible, childClose: context.environment.workbenchChildClose, tips: context.environment.workbenchTips, sidebars: context.environment.workbenchSidebars, navigationTop: context.environment.workbenchNavigationTop, navigationModeWidth: context.environment.workbenchNavigationModeWidth, windowControlSize: context.environment.workbenchWindowControlSize, visualContext: WorkbenchVisualContext(context.environment))
        if let wrapper { wrapper.updateVisibility(visible) }
        else { host.requestVisibility(visible) }
    }
    static func dismantleNSView(_ view: NSView, coordinator: ()) {
        let wrapper = view as? RetainedGeometryView<RetainedContentRoot<Content>>
        let host = wrapper?.host ?? (view as! RetainedNativeHostingView<RetainedContentRoot<Content>>)
        host.prepareToShow = nil
        host.invalidateVisibility()
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        .init(width: proposal.width ?? fallbackSize.width, height: proposal.height ?? fallbackSize.height)
    }
}

/// The visible layout container follows its parent while an inactive page keeps
/// its last useful content size. The same native editor stays mounted and still
/// receives content/environment changes; no snapshot or content cache is used.
@MainActor final class RetainedGeometryView<Content: View>: NSView {
    let host: RetainedNativeHostingView<Content>
    private var visible: Bool

    init(host: RetainedNativeHostingView<Content>, visible: Bool) {
        self.host = host; self.visible = visible
        super.init(frame: .zero)
        setAccessibilityElement(false)
        addSubview(host)
        host.prepareToShow = { [weak self] in self?.syncGeometry() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func updateVisibility(_ value: Bool) {
        visible = value
        if value { syncGeometry() }
        host.requestVisibility(value)
    }
    private func syncGeometry() {
        guard visible || host.bounds.isEmpty else { return }
        let target = NSRect(origin: .zero, size: bounds.size)
        if host.frame != target { host.frame = target }
    }
    override func layout() {
        super.layout()
        syncGeometry()
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard visible else { return nil }
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
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
    var prepareToShow: (() -> Void)?

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
            if self.isHidden != !self.desiredVisible {
                if self.desiredVisible { self.prepareToShow?() }
                self.isHidden = !self.desiredVisible
            }
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
    var tips: TipStore? = nil
    var sidebars: WorkbenchSidebarState? = nil
    var navigationTop: CGFloat = 48
    var navigationModeWidth: CGFloat = 232
    var windowControlSize = CGSize(width: 80, height: 32)
    var visualContext: WorkbenchVisualContext? = nil
    private var visual: WorkbenchVisualContext {
        var value = visualContext ?? .init()
        value.state = appearance; value.background = background; value.language = language
        return value
    }
    var body: some View {
        content.environment(\.workbenchChildClose, childClose).environment(\.metadataEditorLifecycle, lifecycle)
            .environment(\.workbenchSidebars, sidebars)
            .environment(\.workbenchTips, tips)
            .environment(\.workbenchNavigationTop, navigationTop)
            .environment(\.workbenchNavigationModeWidth, navigationModeWidth)
            .environment(\.workbenchWindowControlSize, windowControlSize)
            .focusEffectDisabled()
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
