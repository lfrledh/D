import AppKit
import SwiftUI

/// Explicit command values. Presentation refreshes never redirect a captured action.
@MainActor struct WorkbenchPopupItem {
    enum Role { case normal, destructive }
    var id: String
    var title: String
    var symbol: String? = nil
    var role = Role.normal
    var shortcut: String? = nil
    var help: String? = nil
    var accessibilityID: String? = nil
    var enabled = true
    var checked = false
    var separator = false
    var keepsOpen = false
    var children: [WorkbenchPopupItem] = []
    var isCurrent: () -> Bool = { true }
    var action: (() -> Void)? = nil
}
@MainActor struct WorkbenchPopupStyle {
    let owner: WorkbenchBackgroundOwner?
    let palette: WorkbenchPalette
    let strength: Double
    let drawsGlass: Bool
    let legacyFill: NSColor?
    let readability: WorkbenchReadabilitySettings
    var nativeGlass = false
    var foreground: NSColor { NSColor(palette.foregroundColor) }
}
@MainActor private final class WorkbenchPopupEntry {
    let captured: WorkbenchPopupItem
    let children: [WorkbenchPopupEntry]
    var display: WorkbenchPopupItem
    init(_ item: WorkbenchPopupItem) { captured = item; display = item; children = item.children.map(Self.init) }
    var eligible: Bool { !captured.separator && display.enabled && (!children.isEmpty || captured.action != nil) }
    func refresh(_ fresh: WorkbenchPopupItem?) {
        guard let fresh else { display.enabled = false; children.forEach { $0.refresh(nil) }; return }
        display.title = fresh.title; display.symbol = fresh.symbol; display.shortcut = fresh.shortcut
        display.help = fresh.help; display.checked = fresh.checked; display.enabled = captured.enabled && fresh.enabled
        let values = Dictionary(uniqueKeysWithValues: fresh.children.map { ($0.id, $0) })
        for child in children { child.refresh(values[child.captured.id]) }
    }
}
@MainActor private final class WorkbenchPopupRow: NSButton {
    let entry: WorkbenchPopupEntry
    weak var popup: WorkbenchPopupOverlay?
    let depth: Int
    let index: Int
    var menuHighlighted = false { didSet { needsDisplay = true } }
    var foreground = NSColor.labelColor
    private var tracking: NSTrackingArea?
    init(entry: WorkbenchPopupEntry, depth: Int, index: Int) {
        self.entry = entry; self.depth = depth; self.index = index
        super.init(frame: .zero)
        isBordered = false; focusRingType = .none; target = self; action = #selector(pressed)
        setAccessibilityRole(.menuItem); setAccessibilityIdentifier(entry.captured.accessibilityID ?? entry.captured.id); refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    func refresh() {
        title = entry.display.title; isEnabled = entry.eligible
        setAccessibilityLabel(title); setAccessibilityValue(entry.display.checked ? NSNumber(value: true) : nil)
        setAccessibilityHelp([entry.display.help, entry.display.shortcut].compactMap { $0 }.joined(separator: "; ")); needsDisplay = true
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { popup?.hover(depth: depth, index: index) }
    @objc private func pressed() { popup?.activate(depth: depth, index: index) }
    override func draw(_ dirtyRect: NSRect) {
        if menuHighlighted && entry.eligible {
            NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
        let ink = (entry.display.role == .destructive ? NSColor.systemRed : foreground).withAlphaComponent(entry.eligible ? 1 : 0.42)
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: ink, .paragraphStyle: paragraph]
        if entry.display.checked { ("✓" as NSString).draw(in: .init(x: 7, y: 8, width: 17, height: 18), withAttributes: attributes) }
        var titleX: CGFloat = 27
        if let symbol = entry.display.symbol, let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            (icon.withSymbolConfiguration(.init(paletteColors: [ink])) ?? icon).draw(in: .init(x: 27, y: 9, width: 14, height: 14)); titleX = 47
        }
        let trailing = !entry.children.isEmpty ? "›" : (entry.display.shortcut ?? "")
        let trailingWidth = trailing.isEmpty ? 0 : max(18, (trailing as NSString).size(withAttributes: attributes).width)
        (entry.display.title as NSString).draw(in: .init(x: titleX, y: 8, width: max(0, bounds.width-titleX-trailingWidth-20), height: 18), withAttributes: attributes)
        (trailing as NSString).draw(in: .init(x: bounds.width-trailingWidth-9, y: 8, width: trailingWidth, height: 18), withAttributes: attributes)
    }
}
private final class WorkbenchPopupDocument: NSView { override var isFlipped: Bool { true } }
@MainActor private final class WorkbenchPopupPane: NSView {
    let entries: [WorkbenchPopupEntry]
    let glass = WorkbenchBackgroundNSView()
    let nativeGlass = NSGlassEffectView()
    let foreground = WorkbenchPopupDocument()
    private var usesNativeGlass = false
    let scroll = NSScrollView()
    let document = WorkbenchPopupDocument()
    var rows: [WorkbenchPopupRow?] = []
    var separators: [Int: NSBox] = [:]
    var focused: Int?
    weak var parentRow: WorkbenchPopupRow?
    init(entries: [WorkbenchPopupEntry], depth: Int, style: WorkbenchPopupStyle, popup: WorkbenchPopupOverlay) {
        self.entries = entries; super.init(frame: .zero)
        wantsLayer = true; layer?.cornerRadius = 11; layer?.masksToBounds = false; layer?.borderWidth = 0.6
        setAccessibilityElement(false); glass.setAccessibilityElement(false); addSubview(glass)
        nativeGlass.cornerRadius = 11; nativeGlass.style = .regular
        nativeGlass.setAccessibilityElement(false); foreground.setAccessibilityElement(false)
        addSubview(nativeGlass); nativeGlass.contentView = foreground
        scroll.drawsBackground = false; scroll.contentView.drawsBackground = false; scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.documentView = document
        document.setAccessibilityElement(false); foreground.addSubview(scroll)
        for (i,entry) in entries.enumerated() {
            if entry.captured.separator { let line = NSBox(); line.boxType = .separator; document.addSubview(line); separators[i] = line; rows.append(nil) }
            else { let row = WorkbenchPopupRow(entry: entry, depth: depth, index: i); row.popup = popup; document.addSubview(row); rows.append(row) }
        }
        apply(style)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    override var isFlipped: Bool { true }
    var documentHeight: CGFloat { entries.reduce(0) { $0 + ($1.captured.separator ? 9 : 32) } }
    var proposedWidth: CGFloat {
        min(420, max(220, entries.map { ( ($0.display.title + ($0.display.shortcut ?? "")) as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width + ($0.display.symbol == nil ? 64 : 84) }.max() ?? 220))
    }
    func apply(_ style: WorkbenchPopupStyle) {
        if glass.owner !== style.owner || usesNativeGlass != style.nativeGlass { detach() }
        usesNativeGlass = style.nativeGlass
        layer?.masksToBounds = !usesNativeGlass
        nativeGlass.isHidden = !usesNativeGlass
        if usesNativeGlass {
            if nativeGlass.contentView !== foreground { nativeGlass.contentView = foreground }
            glass.isHidden = true; layer?.backgroundColor = nil; layer?.borderWidth = 0
        } else {
            if foreground.superview !== self { nativeGlass.contentView = nil; addSubview(foreground) }
            glass.owner = style.owner; glass.palette = style.palette; glass.strength = style.strength; glass.drawsGlass = style.drawsGlass
            glass.isCanvas = false; glass.surfaceRole = .popup; glass.surfaceGroup = "popup-\(ObjectIdentifier(self))"; glass.readability = style.readability
            glass.contour = { rect, inset in CGPath(roundedRect: rect.insetBy(dx: inset, dy: inset), cornerWidth: max(0,11-inset), cornerHeight: max(0,11-inset), transform: nil) }
            glass.isHidden = style.legacyFill != nil; layer?.backgroundColor = style.legacyFill?.cgColor
            layer?.borderWidth = 0.6; layer?.borderColor = style.foreground.withAlphaComponent(0.22).cgColor
            style.owner?.surfaces.add(glass); glass.needsDisplay = true
        }
        for row in rows.compactMap({ $0 }) { row.foreground = style.foreground; row.refresh() }
        needsLayout = true
    }
    func detach() { glass.owner?.readability.remove(glass); glass.owner?.surfaces.remove(glass); glass.owner = nil }
    override func layout() {
        super.layout(); glass.frame = bounds; nativeGlass.frame = bounds; foreground.frame = bounds; scroll.frame = bounds.insetBy(dx: 6, dy: 6)
        let width = scroll.contentSize.width; document.frame = .init(x: 0, y: 0, width: width, height: documentHeight)
        var y: CGFloat = 0
        for i in entries.indices {
            if entries[i].captured.separator { separators[i]?.frame = .init(x: 6, y: y+4, width: max(0,width-12), height: 1); y += 9 }
            else { rows[i]?.frame = .init(x: 0, y: y, width: width, height: 32); y += 32 }
        }
        glass.owner?.readability.update(glass)
    }
    func focus(_ index: Int?) {
        focused = index
        for i in rows.indices { rows[i]?.menuHighlighted = i == index }
        if let index, let row = rows[index] { document.scrollToVisible(row.frame); NSAccessibility.post(element: row, notification: .focusedUIElementChanged) }
    }
}
@MainActor final class WorkbenchPopupOverlay: NSView {
    private static let opened = NSMapTable<NSWindow, WorkbenchPopupOverlay>.weakToWeakObjects()
    let contextID: AnyHashable
    private let entries: [WorkbenchPopupEntry]
    private let validContext: () -> Bool
    private let didClose: () -> Void
    private let restoreTrigger: () -> Void
    private weak var trigger: NSView?
    private weak var previousResponder: NSResponder?
    private weak var previousEditorDelegate: AnyObject?
    private weak var presentationWindow: NSWindow?
    private var style: WorkbenchPopupStyle
    private var panes: [WorkbenchPopupPane] = []
    private var activeDepth = 0
    private var closed = false
    private var activationPending = false
    private var dismissOnMouseUp = false
    private var typed = ""
    private var typedAt: TimeInterval = 0
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }
    private init(trigger: NSView, contextID: AnyHashable, title: String, items: [WorkbenchPopupItem], style: WorkbenchPopupStyle, validContext: @escaping () -> Bool, restoreTrigger: @escaping () -> Void, didClose: @escaping () -> Void) {
        self.trigger = trigger; self.contextID = contextID; entries = items.map(WorkbenchPopupEntry.init)
        self.style = style; self.validContext = validContext; self.didClose = didClose; self.restoreTrigger = restoreTrigger
        super.init(frame: .zero)
        // A separate transparent compositing layer is required when this overlay
        // is attached above a SwiftUI hosting view. The glass panes must not turn
        // the full-window event receiver into a drawing surface for their parent.
        wantsLayer = true; layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = false
        setAccessibilityRole(.menu); setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    private static func unique(_ items: [WorkbenchPopupItem]) -> Bool { Set(items.map(\.id)).count == items.count && items.allSatisfy { unique($0.children) } }
    static func present(from trigger: NSView, contextID: AnyHashable, title: String, items: [WorkbenchPopupItem], style: WorkbenchPopupStyle, validContext: @escaping () -> Bool, restoreTrigger: @escaping () -> Void = {}, didClose: @escaping () -> Void = {}) -> WorkbenchPopupOverlay? {
        guard validContext(), unique(items), !items.isEmpty, let window = trigger.window, let content = window.contentView, !trigger.isHiddenOrHasHiddenAncestor else { return nil }
        if let owner = style.owner { guard owner.root?.window === window else { return nil } }
        opened.object(forKey: window)?.cancel(restoreFocus: false)
        let popup = WorkbenchPopupOverlay(trigger: trigger, contextID: contextID, title: title, items: items, style: style, validContext: validContext, restoreTrigger: restoreTrigger, didClose: didClose)
        popup.presentationWindow = window; popup.previousResponder = window.firstResponder
        popup.previousEditorDelegate = (window.firstResponder as? NSTextView)?.delegate
        popup.frame = content.bounds; popup.autoresizingMask = [.width,.height]; content.addSubview(popup, positioned: .above, relativeTo: nil)
        opened.setObject(popup, forKey: window); popup.addPane(popup.entries, parent: nil)
        guard window.makeFirstResponder(popup) else { popup.cancel(restoreFocus: false); return nil }
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] { NotificationCenter.default.addObserver(popup, selector: #selector(windowUnavailable), name: name, object: window) }
        NotificationCenter.default.addObserver(popup, selector: #selector(windowUnavailable), name: NSApplication.didResignActiveNotification, object: NSApp)
        popup.focusInitial(depth: 0); return popup
    }
    func update(contextID: AnyHashable, title: String, items: [WorkbenchPopupItem], style next: WorkbenchPopupStyle) {
        guard !closed else { return }
        guard self.contextID == contextID, validContext(), style.owner === next.owner, Self.unique(items) else { cancel(); return }
        style = next; setAccessibilityLabel(title)
        let fresh = Dictionary(uniqueKeysWithValues: items.map { ($0.id,$0) }); entries.forEach { $0.refresh(fresh[$0.captured.id]) }
        if let invalid = panes.indices.dropFirst().first(where: { panes[$0].parentRow?.entry.eligible != true }) { trim(to: invalid) }
        for pane in panes { pane.apply(next); if let i = pane.focused, !pane.entries[i].eligible { pane.focus(nil) } }
        needsLayout = true
    }
    override func layout() {
        super.layout()
        guard let trigger, trigger.window === window else { cancel(restoreFocus: false); return }
        let area = presentationWindow.map { convert($0.contentLayoutRect, from: nil).intersection(bounds).insetBy(dx: 8,dy: 8) } ?? bounds
        guard area.width > 0, area.height > 0 else { return }
        for (depth,pane) in panes.enumerated() {
            let w = min(pane.proposedWidth,area.width), h = min(pane.documentHeight+12,area.height*0.7)
            let anchor = depth == 0 ? convert(trigger.bounds,from:trigger) : pane.parentRow.map { convert($0.bounds,from:$0) } ?? .zero
            var x = anchor.minX, y = anchor.maxY+4
            if depth == 0 { if y+h > area.maxY { y = anchor.minY-h-4 } }
            else { x = panes[depth-1].frame.maxX+4; if x+w > area.maxX { x = panes[depth-1].frame.minX-w-4 }; y = anchor.minY-6 }
            pane.frame = .init(x:max(area.minX,min(x,area.maxX-w)), y:max(area.minY,min(y,area.maxY-h)), width:w,height:h)
            pane.needsLayout = true; pane.layoutSubtreeIfNeeded()
        }
    }
    private func addPane(_ entries: [WorkbenchPopupEntry], parent: WorkbenchPopupRow?) {
        let pane = WorkbenchPopupPane(entries: entries, depth: panes.count, style: style, popup: self)
        pane.parentRow = parent; parent?.setAccessibilityExpanded(true); panes.append(pane); addSubview(pane); needsLayout = true; layoutSubtreeIfNeeded()
    }
    private func trim(to count: Int) {
        while panes.count > count { let pane = panes.removeLast(); pane.parentRow?.setAccessibilityExpanded(false); pane.detach(); pane.removeFromSuperview() }
        activeDepth = min(activeDepth,max(0,panes.count-1))
    }
    private func focusInitial(depth: Int) {
        guard panes.indices.contains(depth) else { return }
        activeDepth = depth; let pane = panes[depth]; pane.focus(pane.entries.firstIndex { $0.eligible && $0.display.checked } ?? pane.entries.firstIndex { $0.eligible })
    }
    fileprivate func hover(depth: Int, index: Int) {
        guard !closed, !activationPending, panes.indices.contains(depth), panes[depth].entries.indices.contains(index), panes[depth].entries[index].eligible else { return }
        activeDepth = depth; panes[depth].focus(index); showChildren(depth: depth,index:index,enter:false)
    }
    private func showChildren(depth: Int,index: Int,enter: Bool) {
        let pane = panes[depth], entry = panes[depth].entries[index]
        guard entry.eligible else { return }
        if panes.count > depth+1, panes[depth+1].parentRow === pane.rows[index] { if enter { focusInitial(depth:depth+1) }; return }
        trim(to:depth+1)
        guard !entry.children.isEmpty, let row = pane.rows[index] else { return }
        addPane(entry.children,parent:row); if enter { focusInitial(depth:depth+1) }
    }
    fileprivate func activate(depth: Int,index: Int) {
        guard !closed, !activationPending, validContext(), panes.indices.contains(depth), panes[depth].entries.indices.contains(index) else { return }
        let entry = panes[depth].entries[index]
        guard entry.eligible,entry.captured.isCurrent() else { return }
        for ancestor in panes.prefix(depth+1).dropFirst() { guard ancestor.parentRow?.entry.eligible == true, ancestor.parentRow?.entry.captured.isCurrent() == true else { cancel();return } }
        if !entry.children.isEmpty { showChildren(depth:depth,index:index,enter:true);return }
        guard let action = entry.captured.action else { return }
        activationPending = true; let gate = validContext, current = entry.captured.isCurrent
        if entry.captured.keepsOpen {
            Task { @MainActor [weak self] in
                guard let self,!self.closed else { return }; self.activationPending = false
                guard gate(), current() else { self.cancel();return }; action()
            }
        } else {
            cancel()
            Task { @MainActor in guard gate(),current() else { return };action() }
        }
    }
    private func move(_ delta:Int) {
        guard panes.indices.contains(activeDepth) else { return };let pane = panes[activeDepth]
        let allowed = pane.entries.indices.filter { pane.entries[$0].eligible }; guard !allowed.isEmpty else { return }
        let old = pane.focused.flatMap { allowed.firstIndex(of:$0) }; let next = old.map { ($0+delta+allowed.count)%allowed.count } ?? (delta<0 ? allowed.count-1 : 0)
        trim(to:activeDepth+1);pane.focus(allowed[next])
    }
    override func keyDown(with event:NSEvent) {
        guard !closed,validContext(),panes.indices.contains(activeDepth) else { cancel();return }
        if !event.modifierFlags.intersection([.command,.control]).isEmpty { super.keyDown(with:event);return }
        switch event.keyCode {
        case 53: if panes.count>1 { trim(to:panes.count-1);activeDepth=panes.count-1 } else { cancel() }
        case 48:
            let window = presentationWindow
            cancel()
            let origin = window?.firstResponder as? NSView
            if let window, let origin, origin.window === window {
                if event.modifierFlags.contains(.shift) { window.selectKeyView(preceding: origin) }
                else { window.selectKeyView(following: origin) }
            }
        case 125:move(1)
        case 126:move(-1)
        case 123:if activeDepth>0 { trim(to:activeDepth);activeDepth=panes.count-1 }
        case 124:if let index=panes[activeDepth].focused { showChildren(depth:activeDepth,index:index,enter:true) }
        case 36,76,49:if let index=panes[activeDepth].focused { activate(depth:activeDepth,index:index) }
        case 115:trim(to:activeDepth+1);panes[activeDepth].focus(panes[activeDepth].entries.firstIndex { $0.eligible })
        case 119:trim(to:activeDepth+1);panes[activeDepth].focus(panes[activeDepth].entries.lastIndex { $0.eligible })
        default:
            guard let text=event.charactersIgnoringModifiers,!text.isEmpty,text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { super.keyDown(with:event);return }
            let now=ProcessInfo.processInfo.systemUptime;if now-typedAt>0.8 { typed="" };typedAt=now
            typed += text.folding(options:[.caseInsensitive,.diacriticInsensitive],locale:.current)
            if let match=panes[activeDepth].entries.firstIndex(where:{ $0.eligible && $0.display.title.folding(options:[.caseInsensitive,.diacriticInsensitive],locale:.current).hasPrefix(typed) }) { trim(to:activeDepth+1); panes[activeDepth].focus(match) }
        }
    }
    override func mouseDown(with event:NSEvent) { dismissOnMouseUp=true }
    override func mouseUp(with event:NSEvent) { if dismissOnMouseUp { cancel() } }
    override func rightMouseDown(with event:NSEvent) { dismissOnMouseUp=true }
    override func rightMouseUp(with event:NSEvent) { if dismissOnMouseUp { cancel() } }
    override func otherMouseDown(with event:NSEvent) { dismissOnMouseUp=true }
    override func otherMouseUp(with event:NSEvent) { if dismissOnMouseUp { cancel() } }
    override func scrollWheel(with event:NSEvent) {}
    @objc private func windowUnavailable(_ notification:Notification) { cancel(restoreFocus:false) }
    func cancel(restoreFocus:Bool=true) {
        guard !closed else { return };closed=true;NotificationCenter.default.removeObserver(self)
        let window=presentationWindow
        if let window,Self.opened.object(forKey:window) === self { Self.opened.removeObject(forKey:window) }
        trim(to:0);removeFromSuperview()
        if restoreFocus,window?.isKeyWindow == true {
            let old=previousResponder as? NSView
            let editorValid=(old as? NSTextView).map { !$0.isFieldEditor || $0.delegate === previousEditorDelegate } ?? true
            if let old,editorValid,old.window === window,!old.isHiddenOrHasHiddenAncestor,(old as? NSControl)?.isEnabled != false,window?.makeFirstResponder(old) == true {}
            else if let trigger,trigger.window === window,!trigger.isHiddenOrHasHiddenAncestor { restoreTrigger() }
        }
        didClose()
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow();if window == nil && !closed { cancel(restoreFocus:false) } }
    isolated deinit { NotificationCenter.default.removeObserver(self) }
}
