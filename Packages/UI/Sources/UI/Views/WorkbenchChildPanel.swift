import AppKit
import DWorkbench
import SwiftUI
import Observation

/// A presentation-only gate. Drafts and writes remain owned by the existing editor.
@MainActor @Observable final class WorkbenchChildCloseGate {
    var asksToClose = false
    var saving = false
    var failure: String?
    var failureKey: String?
    var allowsDiscard = true
    @ObservationIgnored var dirty = false
    @ObservationIgnored var busy = false
    @ObservationIgnored var save: (() async throws -> Void)?
    @ObservationIgnored var commit: () -> Void = {}
    @ObservationIgnored var isCurrentSurface: () -> Bool = { true }
    private struct Protection {
        let dirty: Bool; let busy: Bool; let allowsDiscard: Bool
        let save: (() async throws -> Void)?
    }
    @ObservationIgnored private var protections: [UUID: Protection] = [:]
    @ObservationIgnored private var protectionOrder: [UUID] = []
    func register(_ id: UUID, dirty: Bool, busy: Bool, allowsDiscard: Bool, save: (() async throws -> Void)?) {
        guard active else { return }
        if protections[id] == nil { protectionOrder.append(id) }
        protections[id] = .init(dirty: dirty, busy: busy, allowsDiscard: allowsDiscard, save: save)
        refreshProtections()
    }
    func unregister(_ id: UUID) {
        protections.removeValue(forKey: id); protectionOrder.removeAll { $0 == id }
        if active { refreshProtections() }
    }
    private func refreshProtections() {
        let records = protectionOrder.compactMap { protections[$0] }, drafts = records.filter(\.dirty)
        let saves = drafts.compactMap(\.save)
        let combined: (() async throws -> Void)? = !drafts.isEmpty && saves.count == drafts.count
            ? { for save in saves { try await save() } } : nil
        update(dirty: !drafts.isEmpty, busy: records.contains(where: \.busy),
               allowsDiscard: drafts.allSatisfy(\.allowsDiscard), save: combined)
    }
    @ObservationIgnored var afterClose: (() -> Void)?
    @ObservationIgnored private var closeWaiters: [CheckedContinuation<Bool, Never>] = []
    var hasCloseWaiter: Bool { !closeWaiters.isEmpty }
    @ObservationIgnored private var pendingClose = false
    @ObservationIgnored private var active = true

    func update(dirty: Bool, busy: Bool, allowsDiscard: Bool = true, save: (() async throws -> Void)?) {
        self.dirty = dirty; self.busy = busy; self.allowsDiscard = allowsDiscard; self.save = save
        if pendingClose && !busy && !saving {
            pendingClose = false
            Task { @MainActor [weak self] in self?.requestClose() }
        }
    }
    func requestClose() {
        guard active, isCurrentSurface() else { return }
        guard !saving && !busy else { pendingClose = true; return }
        if asksToClose { keepEditing(); return }
        if dirty { asksToClose = true } else { commit() }
    }
    func keepEditing() { guard !saving && !busy else { return }; asksToClose = false; pendingClose = false; afterClose = nil; resolveClose(false) }
    private func resolveClose(_ value: Bool) { let pending = closeWaiters; closeWaiters = []; for waiter in pending { waiter.resume(returning: value) } }
    func waitForClose() async -> Bool {
        guard active else { return false }
        return await withCheckedContinuation { continuation in
            let first = closeWaiters.isEmpty
            closeWaiters.append(continuation)
            afterClose = nil // Termination takes priority over a pending navigation.
            if first && !asksToClose { requestClose() }
        }
    }
    func detach() { active = false; pendingClose = false; commit = {}; save = nil; protections = [:]; protectionOrder = []; isCurrentSurface = { false } }
    func finishClose() -> (() -> Void)? {
        let navigation = afterClose; afterClose = nil
        resolveClose(true); invalidate(); return navigation
    }
    func invalidate() { active = false; pendingClose = false; commit = {}; save = nil; afterClose = nil; protections = [:]; protectionOrder = []; isCurrentSurface = { false }; resolveClose(false) }
    func discard() { guard active && isCurrentSurface() && allowsDiscard && !saving && !busy else { return }; asksToClose = false; commit() }
    func saveAndClose() {
        guard active, isCurrentSurface(), !saving, !busy, let save else { return }
        saving = true; failure = nil; failureKey = nil
        Task { @MainActor in
            do { try await save(); guard active else { return }; saving = false; asksToClose = false; pendingClose = false; commit() }
            catch { guard active else { return }; saving = false; pendingClose = false; failure = error.localizedDescription; failureKey = (error as? WorkflowIssue)?.code }
        }
    }
}

private struct ChildCloseKey: EnvironmentKey { static let defaultValue: WorkbenchChildCloseGate? = nil }
extension EnvironmentValues {
    var workbenchChildClose: WorkbenchChildCloseGate? {
        get { self[ChildCloseKey.self] }
        set { self[ChildCloseKey.self] = newValue }
    }
}

/// Native sheets outside D's own presentation continue to use SwiftUI's dismiss.
@propertyWrapper struct WorkbenchDismiss: DynamicProperty {
    @Environment(\.dismiss) private var native
    @Environment(\.workbenchChildClose) private var panel
    var wrappedValue: @MainActor () -> Void { { if let panel { panel.requestClose() } else { native() } } }
    var projectedValue: @MainActor () -> Void { { if let panel { panel.commit() } else { native() } } }
}

public struct WorkbenchChildPanelSize: Equatable {
    public init(width: CGFloat = 840, height: CGFloat = 560, download: Bool = false) { self.width = width; self.height = height; self.download = download }
    var width: CGFloat = 840
    var height: CGFloat = 560
    var download = false
    func resolve(in parent: CGSize) -> CGSize {
        let margin: CGFloat = download ? 64 : 48
        return .init(width: max(1, min(width, parent.width * (download ? 0.82 : 1), parent.width - margin)),
                     height: max(1, min(height, parent.height * (download ? 0.78 : 1), parent.height - margin)))
    }
}

/// Only mounted panels are registered. No global click monitor or background poll.
@MainActor public enum WorkbenchChildPanels {
    private static var mounted: [WeakPanel] = []
    private static let owners = NSHashTable<NSWindow>.weakObjects()
    private static var escapeMonitor: Any?
    public static func registerOwner(_ window: NSWindow) { owners.add(window) }
    static func isOwner(_ window: NSWindow) -> Bool { owners.contains(window) }
    private final class WeakPanel {
        weak var view: WorkbenchChildOverlay?
        init(_ view: WorkbenchChildOverlay) { self.view = view }
    }
    fileprivate static func add(_ view: WorkbenchChildOverlay) {
        mounted.removeAll { $0.view == nil }; mounted.append(WeakPanel(view))
        if escapeMonitor == nil {
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.window === NSApp.keyWindow, RunLoop.current.currentMode != .eventTracking,
                      let gate = orphanedEscapeTarget(event, on: event.window) else { return event }
                gate.requestClose(); return nil
            }
        }
    }
    fileprivate static func remove(_ view: WorkbenchChildOverlay) {
        mounted.removeAll { $0.view == nil || $0.view === view }
        if mounted.isEmpty, let escapeMonitor { NSEvent.removeMonitor(escapeMonitor); self.escapeMonitor = nil }
    }
    /// A removed/folded editor can leave the window/root as responder. Only that
    /// orphaned path needs a fallback; live child controls, menus and composition
    /// keep their own cancellation, with no focus repair or event replay.
    static func orphanedEscapeTarget(_ event: NSEvent, on window: NSWindow?) -> WorkbenchChildCloseGate? {
        guard event.type == .keyDown, event.keyCode == 53, !event.isARepeat,
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
              let window, event.window === window, window.attachedSheet == nil,
              NSApp.modalWindow == nil, !(NSApp.keyWindow is NSSavePanel), !WorkbenchPopupOverlay.isPresented(on: window), let panel = top(on: window) else { return nil }
        let responder = window.firstResponder
        if let client = responder as? NSTextInputClient, client.hasMarkedText() { return nil }
        if let view = responder as? NSView, view.window === window, !view.isHiddenOrHasHiddenAncestor {
            if view.isDescendant(of: panel.host) || responder is NSTextInputClient { return nil }
        }
        return panel.gate
    }
    fileprivate static func top(on window: NSWindow?) -> WorkbenchChildOverlay? {
        guard let window else { return nil }
        return mounted.reversed().compactMap(\.view).first { $0.window === window && !$0.isHidden }
    }
    public static func isPresented(on window: NSWindow?) -> Bool { top(on: window) != nil }
    /// System navigation is explicit. Close all layers in order, and execute only
    /// after their own draft gates have accepted. Cancelling a gate cancels intent.
    public static func navigate(on window: NSWindow?, perform: @escaping @MainActor () -> Void) {
        guard let window else { perform(); return }
        guard window.isKeyWindow, window.attachedSheet == nil, NSApp.modalWindow == nil else { return }
        guard let panel = top(on: window) else { perform(); return }
        guard !panel.gate.hasCloseWaiter else { return }
        panel.gate.afterClose = { [weak window] in
            guard let window, window.isKeyWindow else { return }
            navigate(on: window, perform: perform)
        }
        panel.gate.requestClose()
    }

    public static func prepareForClosing(on window: NSWindow?) async -> Bool {
        guard let window else { return true }
        guard window.attachedSheet == nil, NSApp.modalWindow == nil else { return false }
        guard let panel = top(on: window) else { return true }
        let approved = await panel.gate.waitForClose()
        guard approved else { return false }
        return await prepareForClosing(on: window)
    }
    static func restoreFocus(_ responder: NSResponder?, editorDelegate: AnyObject?, on owner: NSWindow?) {
        guard let owner, owner.isKeyWindow, let view = responder as? NSView, view.window === owner,
              !view.isHiddenOrHasHiddenAncestor, (view as? NSControl)?.isEnabled != false, permitsCommands(from: view, on: owner) else { return }
        if let editor = view as? NSTextView, editor.isFieldEditor {
            guard editor.delegate === editorDelegate, let target = editor.delegate as? NSView, target.window === owner,
                  (target as? NSControl)?.isEnabled != false, !target.isHiddenOrHasHiddenAncestor, permitsCommands(from: target, on: owner) else { return }
            owner.makeFirstResponder(target)
        } else { owner.makeFirstResponder(view) }
    }
    static func frontmostSurface(on window: NSWindow?) -> NSView? { top(on: window) }
    static func permitsCommands(from view: NSView?, on window: NSWindow?) -> Bool {
        guard let panel = top(on: window) else { return true }
        return view?.isDescendant(of: panel.host) == true && !panel.gate.asksToClose
    }

    @discardableResult public static func requestClose(on window: NSWindow?) -> Bool {
        guard let window, window.attachedSheet == nil, NSApp.modalWindow == nil, !(NSApp.keyWindow is NSSavePanel), let top = top(on: window) else { return false }
        top.gate.requestClose(); return true
    }
}

/// Owns the initial responder before any field is clicked. NSTextView keeps
/// composition handling when it is the responder; this host only handles its own Escape.
@MainActor final class WorkbenchChildHostingView: NSHostingView<AnyView> {
    let closeGate: WorkbenchChildCloseGate
    init(rootView: AnyView, gate: WorkbenchChildCloseGate) {
        closeGate = gate
        super.init(rootView: rootView)
    }
    required init(rootView: AnyView) { fatalError("Use init(rootView:gate:)") }
    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:)") }
    override var acceptsFirstResponder: Bool { true }
    override func cancelOperation(_ sender: Any?) {
        guard let window, WorkbenchChildPanels.top(on: window)?.host === self,
              window.attachedSheet == nil, NSApp.modalWindow == nil, !(NSApp.keyWindow is NSSavePanel),
              (window.firstResponder as? NSTextView)?.hasMarkedText() != true else { return }
        closeGate.requestClose()
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            cancelOperation(nil)
        } else { super.keyDown(with: event) }
    }
}

/// B is a native hit-test barrier. AppKit keeps the entire mouse gesture here,
/// including a drag out of the parent. C never reaches this view.
@MainActor private final class WorkbenchChildOverlay: NSView {
    let gate: WorkbenchChildCloseGate
    let host: WorkbenchChildHostingView
    var size: WorkbenchChildPanelSize
    weak var previousResponder: NSResponder?
    weak var previousEditorDelegate: AnyObject?
    func captureFocus(_ window: NSWindow) {
        previousResponder = window.firstResponder
        previousEditorDelegate = (window.firstResponder as? NSTextView)?.delegate
    }
    override var isFlipped: Bool { true }
    init(content: AnyView, gate: WorkbenchChildCloseGate, size: WorkbenchChildPanelSize) {
        self.gate = gate; self.size = size; host = WorkbenchChildHostingView(rootView: content, gate: gate)
        super.init(frame: .zero)
        autoresizingMask = [.width, .height]; host.sizingOptions = []
        addSubview(host)
        gate.isCurrentSurface = { [weak self] in
            guard let self, let window = self.window else { return false }
            return WorkbenchChildPanels.top(on: window) === self && window.attachedSheet == nil && NSApp.modalWindow == nil
        }
        setAccessibilityIdentifier("workbench-child-backdrop")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    override func layout() {
        super.layout()
        let resolved = size.resolve(in: bounds.size)
        host.frame = .init(x: (bounds.width - resolved.width) / 2, y: (bounds.height - resolved.height) / 2,
                           width: resolved.width, height: resolved.height)
    }
    override func mouseDown(with event: NSEvent) {
        guard let window, event.window === window,
              window.attachedSheet == nil, NSApp.modalWindow == nil, !(NSApp.keyWindow is NSSavePanel),
              WorkbenchChildPanels.top(on: window) === self,
              !WorkbenchPopupOverlay.isPresented(on: window) else { return }
        // SwiftUI's noninteractive title/padding can hit this barrier directly,
        // or an inner NSView can forward an unhandled mouseDown here. Neither is
        // an outside click. Use the current hosting surface, not the child hit,
        // and include its corner/padding bounds (but not its external shadow).
        guard bounds.contains(convert(event.locationInWindow, from: nil)),
              !host.bounds.contains(host.convert(event.locationInWindow, from: nil)) else { return }
        gate.requestClose()
    }
    override func rightMouseDown(with event: NSEvent) { mouseDown(with: event) }
    override func otherMouseDown(with event: NSEvent) { mouseDown(with: event) }
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
}

/// Imperative viewer sessions use the same owned surface and event barrier.
/// Their exact Store/value identity remains in WorkflowViewerSession.
@MainActor final class WorkbenchChildPanelHandle {
    private let overlay: WorkbenchChildOverlay
    private let content: AnyView
    private let preferences: ChatDisplayPreferencesState
    private let language: UILanguageStore?
    private var title: String
    private var visualContext: WorkbenchVisualContext
    private var observer: NSObjectProtocol?
    var didClose: (() -> Void)?
    var isVisible: Bool { overlay.superview != nil }
    init?(owner: NSWindow, title: String, content: AnyView, preferences: ChatDisplayPreferencesState, language: UILanguageStore?, size: WorkbenchChildPanelSize = .init(width: 800, height: 640)) {
        guard let root = owner.contentView, let parent = root.superview else { return nil }
        self.content = content; self.title = title; self.preferences = preferences; self.language = language
        var visual = WorkbenchVisualContext()
        visual.state = preferences; visual.language = language
        visual.background = WorkbenchBackgroundOwner.attachedCanvas(in: owner)
        visualContext = visual
        let gate = WorkbenchChildCloseGate()
        overlay = WorkbenchChildOverlay(content: AnyView(WorkbenchChildSurface(content: content, gate: gate, title: title).modifier(WorkbenchVisualBridge(context: visual))), gate: gate, size: size)
        gate.commit = { [weak self] in self?.close() }
        overlay.captureFocus(owner)
        overlay.frame = root.convert(root.bounds, to: parent)
        parent.addSubview(overlay, positioned: .above, relativeTo: nil)
        WorkbenchChildPanels.add(overlay); overlay.needsLayout = true
        observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: owner, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
        DispatchQueue.main.async { [weak self, weak owner] in
            guard let self, let owner, owner.isKeyWindow, WorkbenchChildPanels.top(on: owner) === self.overlay else { return }
            owner.makeFirstResponder(self.overlay.host)
        }
    }
    func setTitle(_ title: String) {
        self.title = title
        overlay.host.rootView = AnyView(WorkbenchChildSurface(content: content, gate: overlay.gate, title: title).modifier(WorkbenchVisualBridge(context: visualContext)))
    }
    func orderFront() {
        guard let parent = overlay.superview else { return }
        parent.addSubview(overlay, positioned: .above, relativeTo: nil)
        WorkbenchChildPanels.remove(overlay); WorkbenchChildPanels.add(overlay)
    }
    func close() {
        guard isVisible else { return }
        let owner = overlay.window, responder = overlay.previousResponder, delegate = overlay.previousEditorDelegate
        overlay.gate.detach()
        WorkbenchChildPanels.remove(overlay); overlay.removeFromSuperview()
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        didClose?()
        let gate = overlay.gate
        DispatchQueue.main.async {
            let navigation = gate.finishClose()
            if let navigation { navigation(); return }
            WorkbenchChildPanels.restoreFocus(responder, editorDelegate: delegate, on: owner)
        }
    }
}

private struct WorkbenchChildSurface: View {
    let content: AnyView
    let gate: WorkbenchChildCloseGate
    let title: String
    @Environment(\.dLanguageStore) private var language
    private let shape = RoundedRectangle(cornerRadius: WorkbenchSurfaceMetrics.childRadius, style: .continuous)
    private func t(_ key: String) -> String { workflowText(language, "childPanel." + key) }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline).lineLimit(2)
                Spacer(minLength: 12)
                Button { gate.requestClose() } label: { Image(systemName: "xmark").frame(width: 32, height: 32).contentShape(Rectangle()) }
                    .buttonStyle(WorkbenchIconButtonStyle(diameter: 32)).accessibilityLabel(title.isEmpty ? t("close") : t("closeNamed").replacingOccurrences(of: "{name}", with: title))
                    .help(t("close")).accessibilityIdentifier("child-panel-close")
            }.padding(.horizontal, 16).frame(height: 52)
            content.frame(maxWidth: .infinity, maxHeight: .infinity).clipped().disabled(gate.saving)
        }
        .environment(\.workbenchChildClose, gate)
        .workbenchTheme(paintsCanvas: false)
        .workbenchPanel(in: shape)
        .onExitCommand { gate.requestClose() }
        .overlay {
            if gate.asksToClose {
                ZStack {
                    shape.fill(Color.black.opacity(0.08)).contentShape(shape).onTapGesture { gate.keepEditing() }
                    VStack(alignment: .leading, spacing: 16) {
                        Text(t(gate.save == nil ? "unsubmitted" : "unsaved")).font(.headline)
                        if let failure = gate.failure { WorkbenchIssueText(raw: failure, key: gate.failureKey).foregroundStyle(.red).textSelection(.enabled) }
                        if gate.saving { ProgressView() }
                        HStack {
                            Button(t("keep")) { gate.keepEditing() }.keyboardShortcut(.cancelAction)
                            Spacer()
                            if gate.allowsDiscard { Button(t(gate.save == nil ? "discard" : "withoutSaving"), role: .destructive) { gate.discard() } }
                            if gate.save != nil { Button(t("save")) { gate.saveAndClose() }.buttonStyle(WorkbenchPrimaryButtonStyle()).frame(minHeight: 36).keyboardShortcut(.defaultAction) }
                        }.buttonStyle(WorkbenchGlassButtonStyle())
                        .environment(\.workbenchActionHeight, 36).disabled(gate.saving)
                    }.padding(24).frame(maxWidth: 520).workbenchPanel(cornerRadius: 16)
                }.accessibilityIdentifier("child-panel-unsaved")
            }
        }
    }
}

/// Existing imperative commands keep their NSAlert response contract. In an
/// owned D window, only presentation is adapted to the shared child surface.
/// Startup/termination without a canvas retains native presentation and gates.
@MainActor public enum WorkbenchConfirmation {
    public static func present(_ alert: NSAlert, owner: NSWindow?,
                               cancelResponse: NSApplication.ModalResponse = .alertSecondButtonReturn,
                               destructiveIndices: Set<Int> = []) async -> NSApplication.ModalResponse {
        guard let owner, let canvas = WorkbenchBackgroundOwner.attachedCanvas(in: owner),
              let state = canvas.presentationState else {
            if let owner { return await alert.beginSheetModal(for: owner) }
            return alert.runModal()
        }
        let request = Pending()
        return await withCheckedContinuation { continuation in
            request.continuation = continuation
            let buttons = alert.buttons.enumerated().map { index, button in
                Choice(id: index, title: button.title, isDefault: button.keyEquivalent == "\r",
                    destructive: destructiveIndices.contains(index))
            }
            let body = VStack(alignment: .leading, spacing: 16) {
                ScrollView { Text(alert.informativeText).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                HStack(spacing: 8) {
                    ForEach(buttons) { choice in
                        Button(choice.title, role: choice.destructive ? .destructive : nil) {
                            request.finish(.init(rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + choice.id))
                        }.buttonStyle(WorkbenchGlassButtonStyle(prominent: choice.isDefault && !choice.destructive))
                            .modifier(DefaultAction(enabled: choice.isDefault)).frame(minHeight: 36)
                    }
                }.environment(\.workbenchActionHeight, 36).frame(maxWidth: .infinity, alignment: .trailing)
            }.padding(20)
            request.panel = WorkbenchChildPanelHandle(owner: owner, title: alert.messageText, content: AnyView(body),
                preferences: state, language: canvas.presentationLanguage, size: .init(width: 560, height: 300))
            request.panel?.didClose = { request.finish(cancelResponse) }
            if request.panel == nil { request.finish(cancelResponse) }
        }
    }
    private struct Choice: Identifiable { let id: Int; let title: String; let isDefault: Bool; let destructive: Bool }
    private struct DefaultAction: ViewModifier {
        let enabled: Bool
        @ViewBuilder func body(content: Content) -> some View {
            if enabled { content.keyboardShortcut(.defaultAction) } else { content }
        }
    }
    @MainActor private final class Pending {
        var continuation: CheckedContinuation<NSApplication.ModalResponse, Never>?
        var panel: WorkbenchChildPanelHandle?
        func finish(_ response: NSApplication.ModalResponse) {
            guard let continuation else { return }
            self.continuation = nil
            let closing = panel; panel = nil; closing?.didClose = nil; closing?.close()
            continuation.resume(returning: response)
        }
    }
}

private struct ChildProtection: NSViewRepresentable {
    let dirty: Bool
    let busy: Bool
    let allowsDiscard: Bool
    let save: (() async throws -> Void)?
    @Environment(\.workbenchChildClose) private var gate
    @MainActor final class Registration {
        let id = UUID()
        weak var gate: WorkbenchChildCloseGate?
        func detach() { gate?.unregister(id); gate = nil }
    }
    func makeCoordinator() -> Registration { Registration() }
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        if context.coordinator.gate !== gate { context.coordinator.detach(); context.coordinator.gate = gate }
        gate?.register(context.coordinator.id, dirty: dirty, busy: busy, allowsDiscard: allowsDiscard, save: save)
    }
    static func dismantleNSView(_ view: NSView, coordinator: Registration) { coordinator.detach() }
}

private struct ChildPresentation: NSViewRepresentable {
    let identity: AnyHashable?
    let content: AnyView?
    let title: String
    let size: WorkbenchChildPanelSize
    let close: () -> Void
    let onDismiss: (() -> Void)?
    func makeNSView(context: Context) -> Marker { Marker() }
    func updateNSView(_ marker: Marker, context: Context) {
        marker.configure(identity: identity, content: content, title: title, size: size,
                         environment: context.environment, close: close, onDismiss: onDismiss)
    }
    static func dismantleNSView(_ marker: Marker, coordinator: ()) { DispatchQueue.main.async { marker.invalidate() } }
    @MainActor final class Marker: NSView {
        private var overlay: WorkbenchChildOverlay?
        private var currentID: AnyHashable?
        private var nextID: AnyHashable?
        private var nextContent: AnyView?
        private var nextTitle = ""
        private var nextSize = WorkbenchChildPanelSize()
        private var environment = EnvironmentValues()
        private var close: () -> Void = {}
        private var onDismiss: (() -> Void)?
        private var queued = false
        private var invalid = false
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); schedule() }
        func configure(identity: AnyHashable?, content: AnyView?, title: String, size: WorkbenchChildPanelSize,
                       environment: EnvironmentValues, close: @escaping () -> Void, onDismiss: (() -> Void)?) {
            nextID = identity; nextContent = content; nextTitle = title; nextSize = size
            self.environment = environment; self.close = close; self.onDismiss = onDismiss; schedule()
        }
        private func schedule() {
            guard !queued, !invalid else { return }; queued = true
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.invalid else { return }; self.queued = false; self.apply()
            }
        }
        private func apply() {
            guard let window, let contentRoot = window.contentView, let root = contentRoot.superview else { return }
            if currentID != nextID { remove(); currentID = nextID }
            guard nextID != nil, let nextContent else { return }
            let gate = overlay?.gate ?? WorkbenchChildCloseGate()
            gate.commit = close
            let surface = AnyView(WorkbenchChildSurface(content: nextContent, gate: gate, title: nextTitle)
                .environment(\.self, environment))
            if let overlay { overlay.host.rootView = surface; overlay.size = nextSize; overlay.needsLayout = true }
            else {
                let panel = WorkbenchChildOverlay(content: surface, gate: gate, size: nextSize)
                panel.captureFocus(window); panel.frame = contentRoot.convert(contentRoot.bounds, to: root)
                overlay = panel; root.addSubview(panel, positioned: .above, relativeTo: nil)
                WorkbenchChildPanels.add(panel); panel.needsLayout = true
                // Defer responder traversal, as with RetainedContentHost visibility.
                DispatchQueue.main.async { [weak panel] in
                    guard let panel, WorkbenchChildPanels.top(on: window) === panel, window.isKeyWindow else { return }
                    window.makeFirstResponder(panel.host)
                }
            }
        }
        private func remove() {
            guard let overlay else { return }
            let owner = overlay.window, responder = overlay.previousResponder, delegate = overlay.previousEditorDelegate
            overlay.gate.detach()
            WorkbenchChildPanels.remove(overlay); overlay.removeFromSuperview(); self.overlay = nil
            let callback = onDismiss, gate = overlay.gate
            DispatchQueue.main.async {
                callback?()
                let navigation = gate.finishClose()
                if let navigation { DispatchQueue.main.async { navigation() }; return }
                WorkbenchChildPanels.restoreFocus(responder, editorDelegate: delegate, on: owner)
            }
        }
        func invalidate() { invalid = true; remove() }
    }
}

extension View {
    /// D-owned confirmations use the same owner/environment/close barrier as
    /// other child surfaces. Actions retain their captured object and explicitly
    /// clear the presenting binding; no command reflection or redispatch.
    func workbenchConfirmation<Actions: View, Message: View>(_ title: String,
        isPresented: Binding<Bool>, @ViewBuilder actions: () -> Actions,
        @ViewBuilder message: () -> Message) -> some View {
        workbenchSheet(isPresented: isPresented, title: title, size: .init(width: 560, height: 300)) {
            VStack(alignment: .leading, spacing: 16) {
                ScrollView { message().textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                HStack(spacing: 8) { actions() }.environment(\.workbenchActionHeight, 36).frame(maxWidth: .infinity, alignment: .trailing)
            }.padding(20)
        }
    }
    func workbenchConfirmation<Value, Actions: View, Message: View>(_ title: String,
        isPresented: Binding<Bool>, presenting value: Value?, @ViewBuilder actions: (Value) -> Actions,
        @ViewBuilder message: (Value) -> Message) -> some View {
        workbenchConfirmation(title, isPresented: isPresented) {
            if let value { actions(value) }
        } message: { if let value { message(value) } }
    }
    func workbenchConfirmation<Actions: View>(_ title: String, isPresented: Binding<Bool>,
        @ViewBuilder actions: () -> Actions) -> some View {
        workbenchConfirmation(title, isPresented: isPresented, actions: actions, message: { EmptyView() })
    }
    func workbenchCloseProtection(isDirty: Bool, isSaving: Bool = false, allowsDiscard: Bool = true, save: (() async throws -> Void)? = nil) -> some View {
        background(ChildProtection(dirty: isDirty, busy: isSaving, allowsDiscard: allowsDiscard, save: save).frame(width: 0, height: 0))
    }
    public func workbenchSheet<Content: View>(isPresented: Binding<Bool>, title: String = "", size: WorkbenchChildPanelSize = .init(),
                                      onDismiss: (() -> Void)? = nil, @ViewBuilder content: () -> Content) -> some View {
        background(ChildPresentation(identity: isPresented.wrappedValue ? AnyHashable(true) : nil,
            content: isPresented.wrappedValue ? AnyView(content()) : nil, title: title, size: size,
            close: { isPresented.wrappedValue = false }, onDismiss: onDismiss).frame(width: 0, height: 0))
    }
    public func workbenchSheet<Item: Identifiable, Content: View>(item: Binding<Item?>, title: String = "", size: WorkbenchChildPanelSize = .init(),
                                                         onDismiss: (() -> Void)? = nil, @ViewBuilder content: (Item) -> Content) -> some View {
        let capturedID = item.wrappedValue?.id
        return background(ChildPresentation(identity: item.wrappedValue.map { AnyHashable($0.id) },
            content: item.wrappedValue.map { AnyView(content($0)) }, title: title, size: size,
            close: { if item.wrappedValue?.id == capturedID { item.wrappedValue = nil } }, onDismiss: onDismiss).frame(width: 0, height: 0))
    }
    func workbenchPopover<Content: View>(isPresented: Binding<Bool>, title: String = "", arrowEdge: Edge = .top, @ViewBuilder content: () -> Content) -> some View {
        workbenchSheet(isPresented: isPresented, title: title, size: .init(width: 560, height: 520), content: content)
    }
    func workbenchPopover<Item: Identifiable, Content: View>(item: Binding<Item?>, title: String = "", @ViewBuilder content: (Item) -> Content) -> some View {
        workbenchSheet(item: item, title: title, size: .init(width: 560, height: 520), content: content)
    }
}

/// Reads the child's environment at the button, including computed subviews whose
/// presenter itself belongs to a different (parent) panel.
struct WorkbenchRequestCloseButton: View {
    let title: String
    var fallback: () -> Void
    @Environment(\.workbenchChildClose) private var gate
    var body: some View {
        Button(title) { if let gate { gate.requestClose() } else { fallback() } }
    }
}
