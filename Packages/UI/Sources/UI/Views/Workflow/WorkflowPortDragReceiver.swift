import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A port connection is a local mouse gesture, not a file/Transferable drag.
/// One responder owns preview, target hit testing, cancellation and release.
struct WorkflowPortDragReceiver: NSViewRepresentable {
    let port: WorkflowPortIdentity
    let scope: WorkflowCanvasScope
    let enabled: Bool
    var visibleAt: (CGPoint) -> Bool = { _ in true }
    let onClick: () -> Void
    let onChange: (CGSize) -> Void
    let onEnd: (WorkflowPortIdentity?) -> Void
    var onLibraryDrop: ((WorkflowCanvasTransfer) -> Bool)? = nil
    @Environment(\.isEnabled) private var environmentEnabled

    func makeNSView(context: Context) -> WorkflowPortDragView {
        let view = WorkflowPortDragView()
        view.setAccessibilityElement(false)
        return view
    }
    func updateNSView(_ view: WorkflowPortDragView, context: Context) {
        let accepts = enabled && environmentEnabled
        if view.port != port || view.scope != scope || !accepts { view.cancel(notify: false) }
        view.port = port; view.scope = scope; view.enabled = accepts; view.visibleAt = visibleAt
        view.onClick = onClick; view.onChange = onChange; view.onEnd = onEnd
        view.onLibraryDrop = onLibraryDrop
    }
    static func dismantleNSView(_ view: WorkflowPortDragView, coordinator: ()) {
        view.cancel(notify: false)
    }
}

final class WorkflowPortDragView: NSView {
    var port: WorkflowPortIdentity?
    var scope: WorkflowCanvasScope?
    var enabled = false
    var visibleAt: (CGPoint) -> Bool = { _ in true }
    var onClick: () -> Void = {}
    var onChange: (CGSize) -> Void = { _ in }
    var onEnd: (WorkflowPortIdentity?) -> Void = { _ in }
    var onLibraryDrop: ((WorkflowCanvasTransfer) -> Bool)?
    private static let libraryType = NSPasteboard.PasteboardType(UTType.workflowCanvasItem.identifier)
    private var librarySession: (sequence: Int, scope: WorkflowCanvasScope, port: WorkflowPortIdentity, board: String, change: Int, value: WorkflowCanvasTransfer)?
    private var consumedLibrarySequence: Int?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([Self.libraryType])
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([Self.libraryType])
    }
    // The visible native port owns both local wire gestures and incoming library
    // drops. A SwiftUI drop target below this receiver is not the native hit owner.
    private func libraryPayload(_ sender: any NSDraggingInfo) -> WorkflowCanvasTransfer? {
        guard enabled, !isHiddenOrHasHiddenAncestor, onLibraryDrop != nil,
              let window, sender.draggingDestinationWindow === window,
              sender.draggingSourceOperationMask.contains(.copy), port?.input == true,
              let scope, sender.draggingSequenceNumber != consumedLibrarySequence else { return nil }
        guard let items = sender.draggingPasteboard.pasteboardItems, items.count == 1,
              let bytes = items[0].data(forType: Self.libraryType),
              let value = try? WorkflowCanvasTransfer.decode(bytes),
              let payload = value.libraryPayload, payload.items.count == 1,
              payload.owner.projectID == scope.projectID,
              payload.owner.instanceID == scope.instanceID else { return nil }
        return value
    }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        librarySession = nil
        guard let value = libraryPayload(sender), let scope, let port else { return [] }
        librarySession = (sender.draggingSequenceNumber, scope, port, sender.draggingPasteboard.name.rawValue, sender.draggingPasteboard.changeCount, value)
        return draggingUpdated(sender)
    }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard librarySession?.sequence == sender.draggingSequenceNumber,
              librarySession?.scope == scope, librarySession?.port == port,
              enabled, !isHiddenOrHasHiddenAncestor, onLibraryDrop != nil,
              let window, sender.draggingDestinationWindow === window,
              sender.draggingSourceOperationMask.contains(.copy),
              librarySession?.board == sender.draggingPasteboard.name.rawValue,
              librarySession?.change == sender.draggingPasteboard.changeCount else { return [] }
        let point = convert(sender.draggingLocation, from: nil)
        guard bounds.width > 0, bounds.height > 0,
              visibleAt(CGPoint(x: point.x - bounds.midX, y: point.y - bounds.midY)),
              pow((point.x - bounds.midX) / (bounds.width / 2), 2)
                + pow((point.y - bounds.midY) / (bounds.height / 2), 2) <= 1 else { return [] }
        return .copy
    }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) { librarySession = nil }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        draggingUpdated(sender).contains(.copy)
    }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard prepareForDragOperation(sender), let value = librarySession?.value,
              let onLibraryDrop else { librarySession = nil; return false }
        // Consume before calling the controller; re-entrant/repeated delivery of
        // this native sequence cannot create a second source or connection.
        librarySession = nil
        consumedLibrarySequence = sender.draggingSequenceNumber
        return onLibraryDrop(value)
    }
    private var start: CGPoint?
    private var dragging = false
    private var escapeMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard enabled, !isHiddenOrHasHiddenAncestor else { return nil }
        let local = convert(point, from: superview)
        guard visibleAt(CGPoint(x: local.x - bounds.midX, y: local.y - bounds.midY)) else { return nil }
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        return pow((local.x - bounds.midX) / (bounds.width / 2), 2)
            + pow((local.y - bounds.midY) / (bounds.height / 2), 2) <= 1 ? self : nil
    }
    override func mouseDown(with event: NSEvent) {
        guard enabled, event.buttonNumber == 0, let window, window.isKeyWindow else { return }
        cancel(notify: false)
        start = convert(event.locationInWindow, from: nil)
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.start != nil, event.window === self.window, event.keyCode == 53 else { return event }
            self.cancel(); return nil
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
            object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancel() }
            }
    }
    override func mouseDragged(with event: NSEvent) {
        guard enabled, let start, port != nil else { cancel(); return }
        let point = convert(event.locationInWindow, from: nil)
        guard dragging || hypot(point.x - start.x, point.y - start.y) >= 2 else { return }
        dragging = true
        // The dot and its small receiver share the same center. Native conversion
        // already includes the graph's zoom; do not divide this delta again.
        let dot = CGPoint(x: bounds.midX, y: bounds.midY)
        onChange(CGSize(width: point.x - dot.x, height: point.y - dot.y))
    }
    override func mouseUp(with event: NSEvent) {
        guard start != nil else { return }
        let wasDragging = dragging
        let destination = target(at: event.locationInWindow)
        let click = enabled && bounds.contains(convert(event.locationInWindow, from: nil))
            && window?.isKeyWindow == true
        cancel(notify: false) // Consume the gesture before any controller mutation.
        if wasDragging { onEnd(destination) } else if click { onClick() }
    }
    private func target(at windowPoint: CGPoint) -> WorkflowPortIdentity? {
        guard enabled, let window, window.isKeyWindow, let content = window.contentView else { return nil }
        let point = content.superview?.convert(windowPoint, from: nil) ?? windowPoint
        guard let target = content.hitTest(point) as? WorkflowPortDragView,
              target.enabled, target.scope == scope, target.port != port else { return nil }
        return target.port
    }
    func cancel(notify: Bool = true) {
        let wasDragging = dragging
        start = nil; dragging = false
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }; escapeMonitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }; resignObserver = nil
        if notify && wasDragging { onEnd(nil) }
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { librarySession = nil; cancel() }
        super.viewWillMove(toWindow: newWindow)
    }
}

/// Opaque cards must also occlude native event receivers in lower cards. The
/// viewport owns node gestures; this transparent receiver only establishes z-order.
struct WorkflowNodePlateReceiver: NSViewRepresentable {
    var scale: CGFloat = 1
    func makeNSView(context: Context) -> WorkflowNodePlateView { WorkflowNodePlateView() }
    func updateNSView(_ view: WorkflowNodePlateView, context: Context) { view.scale = scale }
}
final class WorkflowNodePlateView: NSView {
    var scale: CGFloat = 1
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHiddenOrHasHiddenAncestor else { return nil }
        return RoundedRectangle(cornerRadius: 13 * scale, style: .continuous).path(in: bounds).cgPath.contains(convert(point, from: superview)) ? self : nil
    }
}
