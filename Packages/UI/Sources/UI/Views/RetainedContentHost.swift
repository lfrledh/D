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

    func makeNSView(context: Context) -> RetainedNativeHostingView<RetainedContentRoot<Content>> {
        let host = RetainedNativeHostingView(rootView: RetainedContentRoot(content: content, lifecycle: context.environment.metadataEditorLifecycle, background: context.environment.workbenchBackground, appearance: context.environment.workbenchAppearanceState, language: context.environment.dLanguageStore, widths: context.environment.workbenchPanelWidths, surfaceGroup: context.environment.workbenchSurfaceGroup, menuContext: context.environment.workbenchMenuContext, modelReadiness: context.environment.workbenchModelReadiness, preparation: context.environment.workflowModelPreparation, installations: context.environment.workflowModelInstallations, featureHelp: context.environment.workbenchHelpStore, contentVisible: visible && context.environment.workbenchContentVisible, childClose: context.environment.workbenchChildClose, tips: context.environment.workbenchTips, sidebars: context.environment.workbenchSidebars, navigationTop: context.environment.workbenchNavigationTop, navigationModeWidth: context.environment.workbenchNavigationModeWidth, windowControlSize: context.environment.workbenchWindowControlSize, visualContext: WorkbenchVisualContext(context.environment)))
        host.sizingOptions = []
        if !inheritsWindowSafeArea { host.safeAreaRegions = [] }
        host.setAccessibilityIdentifier(identifier)
        host.traceIdentifier = identifier
        host.setInitialVisibility(visible)
        return host
    }
    func updateNSView(_ host: RetainedNativeHostingView<RetainedContentRoot<Content>>, context: Context) {
        #if DEBUG
        WorkbenchCategoryUpdateProbe.retainedUpdate?()
        #endif
        let rootTicket = WorkbenchHostLayoutTrace.begin(host, id: identifier, desired: visible, event: "root")
        host.rootView = RetainedContentRoot(content: content, lifecycle: context.environment.metadataEditorLifecycle, background: context.environment.workbenchBackground, appearance: context.environment.workbenchAppearanceState, language: context.environment.dLanguageStore, widths: context.environment.workbenchPanelWidths, surfaceGroup: context.environment.workbenchSurfaceGroup, menuContext: context.environment.workbenchMenuContext, modelReadiness: context.environment.workbenchModelReadiness, preparation: context.environment.workflowModelPreparation, installations: context.environment.workflowModelInstallations, featureHelp: context.environment.workbenchHelpStore, contentVisible: visible && context.environment.workbenchContentVisible, childClose: context.environment.workbenchChildClose, tips: context.environment.workbenchTips, sidebars: context.environment.workbenchSidebars, navigationTop: context.environment.workbenchNavigationTop, navigationModeWidth: context.environment.workbenchNavigationModeWidth, windowControlSize: context.environment.workbenchWindowControlSize, visualContext: WorkbenchVisualContext(context.environment))
        WorkbenchHostLayoutTrace.end(rootTicket, host, desired: visible)
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
    var traceIdentifier = ""
    override func layout() {
        let ticket = WorkbenchHostLayoutTrace.begin(self, id: traceIdentifier, desired: desiredVisible, event: "layout")
        super.layout()
        WorkbenchHostLayoutTrace.end(ticket, self, desired: desiredVisible)
    }
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


// Temporary attribution build only. Removed before normal delivery.
@MainActor private enum WorkbenchHostLayoutTrace {
    struct Ticket { let start: TimeInterval; let number: Int; let parent: Int?; let id: String; let event: String; let desired: Bool }
    struct Record: Codable, Sendable {
        let event: String; let start: TimeInterval; let end: TimeInterval
        let number: Int; let parent: Int?; let id: String
        let hidden: Bool; let hiddenAncestor: Bool; let desired: Bool; let live: Bool
        let width: Double; let height: Double
    }
    struct Snapshot: Codable, Sendable {
        let start: TimeInterval; let end: TimeInterval; let window: Int; let pid: Int32
        let overflow: Int; let rows: [Record]
    }
    private static var installed = false
    private static weak var resizingWindow: NSWindow?
    private static var records: [Record] = []
    private static var stack: [Int] = []
    private static var sequence = 0
    private static var overflow = 0
    private static var observerTokens: [NSObjectProtocol] = []
    private static var started: TimeInterval = 0
    static func prepare() {
        guard !installed else { return }
        installed = true; records.reserveCapacity(4096)
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = cache.appendingPathComponent("B9-host-layout.json")
        observerTokens = [
            NotificationCenter.default.addObserver(forName: NSWindow.willStartLiveResizeNotification, object: nil, queue: .main) { notification in
                MainActor.assumeIsolated {
                    guard let window = notification.object as? NSWindow else { return }
                    resizingWindow = window; records.removeAll(keepingCapacity: true)
                    stack.removeAll(keepingCapacity: true); sequence = 0; overflow = 0
                    started = ProcessInfo.processInfo.systemUptime
                }
            },
            NotificationCenter.default.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: nil, queue: .main) { notification in
                MainActor.assumeIsolated {
                    guard let window = notification.object as? NSWindow, window === resizingWindow else { return }
                    let result = Snapshot(start: started, end: ProcessInfo.processInfo.systemUptime,
                        window: window.windowNumber, pid: ProcessInfo.processInfo.processIdentifier,
                        overflow: overflow + stack.count, rows: records)
                    resizingWindow = nil
                    DispatchQueue.global(qos: .utility).async {
                        if let bytes = try? JSONEncoder().encode(result) {
                            try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
                            try? bytes.write(to: url, options: .atomic)
                        }
                    }
                }
            }
        ]
    }
    static func begin(_ view: NSView, id: String, desired: Bool, event: String) -> Ticket? {
        prepare()
        guard view.window === resizingWindow, resizingWindow != nil else { return nil }
        let ticket = Ticket(start: ProcessInfo.processInfo.systemUptime, number: sequence,
            parent: stack.last, id: id, event: event, desired: desired)
        sequence += 1; stack.append(ticket.number)
        return ticket
    }
    static func end(_ ticket: Ticket?, _ view: NSView, desired: Bool) {
        guard let ticket else { return }
        let end = ProcessInfo.processInfo.systemUptime
        guard stack.last == ticket.number else { overflow += 1; return }
        stack.removeLast()
        guard records.count < 4096 else { overflow += 1; return }
        records.append(.init(event: ticket.event, start: ticket.start, end: end, number: ticket.number,
            parent: ticket.parent, id: ticket.id, hidden: view.isHidden, hiddenAncestor: view.isHiddenOrHasHiddenAncestor,
            desired: desired, live: view.inLiveResize, width: view.bounds.width, height: view.bounds.height))
    }
}
