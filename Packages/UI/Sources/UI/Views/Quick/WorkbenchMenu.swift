import AppKit
import SwiftUI

/// Menus use declared command values, never reflection over SwiftUI children.
@MainActor struct WorkbenchMenuRows {
    var items: [WorkbenchPopupItem]
    var accessibleLeaves: [WorkbenchPopupItem] {
        func leaves(_ item: WorkbenchPopupItem, enabled: Bool, valid: @escaping () -> Bool) -> [WorkbenchPopupItem] {
            let allowed = enabled && item.enabled
            let gate = { valid() && item.isCurrent() }
            if !item.children.isEmpty { return item.children.flatMap { leaves($0, enabled: allowed, valid: gate) } }
            guard !item.separator, item.action != nil else { return [] }
            var copy = item; copy.enabled = allowed; copy.isCurrent = gate; return [copy]
        }
        return items.flatMap { leaves($0, enabled: true, valid: { true }) }
    }
    func disabled(_ disabled: Bool) -> Self { var copy = self; copy.items = items.map { var item = $0; item.enabled = item.enabled && !disabled; return item }; return copy }
    func featureHelp(_ id: String, language: UILanguageStore?, unavailableReason: String? = nil) -> Self {
        help(WorkbenchFeatures.purpose(id, language: language) + (unavailableReason.map { "\n" + $0 } ?? ""))
    }
    func help(_ help: String) -> Self { var copy = self; copy.items = items.map { var item = $0; item.help = help; return item }; return copy }
    func font(_ font: Font?) -> Self { self }
    func foregroundStyle<S: ShapeStyle>(_ style: S) -> Self { self }
    func validation(_ isCurrent: @escaping () -> Bool) -> Self { var copy = self; copy.items = items.map { var item = $0; let previous = item.isCurrent; item.isCurrent = { previous() && isCurrent() }; return item }; return copy }
    func accessibilityIdentifier(_ id: String) -> Self { var copy = self; copy.items = items.map { var item = $0; item.accessibilityID = id; return item }; return copy }
    func keyboardShortcut(_ key: KeyEquivalent, modifiers: EventModifiers = .command) -> Self {
        var copy = self
        let shortcut = (modifiers.contains(.control) ? "⌃" : "") + (modifiers.contains(.option) ? "⌥" : "") + (modifiers.contains(.shift) ? "⇧" : "") + (modifiers.contains(.command) ? "⌘" : "") + String(key.character).uppercased()
        copy.items = items.map { var item = $0; item.shortcut = shortcut; return item }; return copy
    }
}
@resultBuilder @MainActor enum WorkbenchMenuBuilder {
    static func buildBlock(_ values: WorkbenchMenuRows...) -> WorkbenchMenuRows { .init(items: values.flatMap(\.items)) }
    static func buildExpression(_ value: WorkbenchMenuRows) -> WorkbenchMenuRows { value }
    static func buildOptional(_ value: WorkbenchMenuRows?) -> WorkbenchMenuRows { value ?? .init(items: []) }
    static func buildEither(first: WorkbenchMenuRows) -> WorkbenchMenuRows { first }
    static func buildEither(second: WorkbenchMenuRows) -> WorkbenchMenuRows { second }
    static func buildArray(_ values: [WorkbenchMenuRows]) -> WorkbenchMenuRows { .init(items: values.flatMap(\.items)) }
    static func buildLimitedAvailability(_ value: WorkbenchMenuRows) -> WorkbenchMenuRows { value }
}
@MainActor func WorkbenchMenuAction(_ title: String, systemImage: String? = nil, role: ButtonRole? = nil,
    id: String? = nil, file: StaticString = #fileID, line: UInt = #line, action: @escaping () -> Void) -> WorkbenchMenuRows {
    .init(items: [.init(id: id ?? "\(file):\(line)", title: title, symbol: systemImage, role: role == .destructive ? .destructive : .normal, action: action)])
}
@MainActor func WorkbenchMenuDivider(file: StaticString = #fileID, line: UInt = #line) -> WorkbenchMenuRows {
    .init(items: [.init(id: "\(file):\(line)", title: "", enabled: false, separator: true)])
}
@MainActor func WorkbenchMenuText(_ title: String, file: StaticString = #fileID, line: UInt = #line) -> WorkbenchMenuRows {
    .init(items: [.init(id: "\(file):\(line)", title: title, enabled: false)])
}
@MainActor func WorkbenchSubmenu(_ title: String, systemImage: String? = nil, id: String? = nil,
    file: StaticString = #fileID, line: UInt = #line, @WorkbenchMenuBuilder content: () -> WorkbenchMenuRows) -> WorkbenchMenuRows {
    .init(items: [.init(id: id ?? "\(file):\(line)", title: title, symbol: systemImage, children: content().items)])
}
@MainActor func WorkbenchMenuToggle(_ title: String, isOn: Binding<Bool>, file: StaticString = #fileID, line: UInt = #line) -> WorkbenchMenuRows {
    .init(items: [.init(id: "\(file):\(line)", title: title, checked: isOn.wrappedValue, keepsOpen: true, action: { isOn.wrappedValue.toggle() })])
}
@MainActor func WorkbenchMenuForEach<C: RandomAccessCollection, ID: Hashable>(_ values: C, id: KeyPath<C.Element, ID>, @WorkbenchMenuBuilder content: (C.Element) -> WorkbenchMenuRows) -> WorkbenchMenuRows {
    .init(items: values.flatMap { value in content(value).items.map { var item = $0; item.id = String(reflecting: value[keyPath: id]) + ":" + item.id; return item } })
}
@MainActor func WorkbenchMenuForEach<C: RandomAccessCollection>(_ values: C, @WorkbenchMenuBuilder content: (C.Element) -> WorkbenchMenuRows) -> WorkbenchMenuRows where C.Element: Identifiable {
    WorkbenchMenuForEach(values, id: \.id, content: content)
}
@MainActor func WorkbenchMenuOptions<Value: Hashable>(_ title: String, selection: Binding<Value>, choices: [(Value, String)]) -> WorkbenchMenuRows {
    .init(items: choices.map { value, label in
        .init(id: String(reflecting: value), title: label, checked: selection.wrappedValue == value, action: { selection.wrappedValue = value })
    })
}
private struct WorkbenchMenuContextKey: EnvironmentKey { static let defaultValue = "window" }
extension EnvironmentValues {
    var workbenchMenuContext: String { get { self[WorkbenchMenuContextKey.self] } set { self[WorkbenchMenuContextKey.self] = newValue } }
}
@MainActor @Observable private final class WorkbenchMenuHandle {
    weak var anchor: NSView?
    var open: (() -> Void)?
}
@MainActor struct WorkbenchMenu<Label: View>: View {
    let title: String
    let items: WorkbenchMenuRows
    let label: Label
    var keyboardFocusable = false
    var onPresentationChange: (Bool) -> Void = { _ in }
    var onFocusChange: (Bool) -> Void = { _ in }
    @State private var handle = WorkbenchMenuHandle()
    @FocusState private var focused: Bool
    init(_ title: String = "", keyboardFocusable: Bool = false, onPresentationChange: @escaping (Bool) -> Void = { _ in }, onFocusChange: @escaping (Bool) -> Void = { _ in }, @WorkbenchMenuBuilder content: () -> WorkbenchMenuRows, @ViewBuilder label: () -> Label) {
        self.keyboardFocusable = keyboardFocusable
        self.title = title; self.onPresentationChange = onPresentationChange; self.onFocusChange = onFocusChange; items = content(); self.label = label()
    }
    var body: some View {
        Button { handle.open?() } label: { label }
            .modifier(WorkbenchMenuTabFocus(enabled: keyboardFocusable))
            .focused($focused)
            .onKeyPress(phases: .down) { press in
                guard keyboardFocusable, focused, press.modifiers.isEmpty, press.key == .space || press.key == .return else { return .ignored }
                handle.open?(); return .handled
            }
            .onChange(of: focused) { _, value in onFocusChange(value) }
            .background(WorkbenchMenuAnchor(title: title, items: items.items, handle: handle, restoreTrigger: { focused = true }, onPresentationChange: onPresentationChange).allowsHitTesting(false))
    }
}
private struct WorkbenchMenuTabFocus: ViewModifier {
    let enabled: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if enabled { content.focusable(interactions: [.edit, .activate]) }
        else { content }
    }
}
extension WorkbenchMenu where Label == Text {
    init(_ title: String, @WorkbenchMenuBuilder content: () -> WorkbenchMenuRows) {
        self.init(title, content: content, label: { Text(title) })
    }
}
extension WorkbenchMenu where Label == SwiftUI.Label<Text,Image> {
    init(_ title: String, systemImage: String, @WorkbenchMenuBuilder content: () -> WorkbenchMenuRows) {
        self.init(title, content: content, label: { SwiftUI.Label(title,systemImage:systemImage) })
    }
}
struct WorkbenchSelectionMenu<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let choices: [(Value,String)]
    var body: some View {
        WorkbenchMenu(title) { WorkbenchMenuOptions(title, selection: $selection, choices: choices) } label: {
            HStack(spacing: 5) { Text(choices.first { $0.0 == selection }?.1 ?? title).lineLimit(2); Image(systemName:"chevron.down").font(.caption) }
        }.accessibilityLabel(title)
    }
}
@MainActor private struct WorkbenchMenuAnchor: NSViewRepresentable {
    let title: String
    let items: [WorkbenchPopupItem]
    let handle: WorkbenchMenuHandle
    var restoreTrigger: () -> Void = {}
    var onPresentationChange: (Bool) -> Void = { _ in }
    var contextClick = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.workbenchMenuContext) private var contextID
    @Environment(\.workbenchBackground) private var background
    @Environment(\.chatDisplayPreferences) private var preferences
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dLanguageStore) private var language
    private var style: WorkbenchPopupStyle {
        .resolved(owner: background, preferences: preferences, scheme: scheme,
            reduceMotion: reduceMotion, reduceTransparency: reduceTransparency, increasedContrast: contrast == .increased)
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context:Context) -> WorkbenchMenuAnchorView { let view = WorkbenchMenuAnchorView();view.setAccessibilityElement(false);return view }
    func updateNSView(_ view:WorkbenchMenuAnchorView,context:Context) {
        let c=context.coordinator
        c.contextID=contextID;c.enabled=enabled;c.style=style;c.items=items;c.title=title.isEmpty ? consistencyText(language,"menu.title") : title
        c.anchor=view; c.restoreTrigger = restoreTrigger; c.onPresentationChange = onPresentationChange; view.contextClick = contextClick; view.openContext = { [weak c] in c?.open() }; handle.anchor=view; handle.open={ [weak c] in c?.open() }
        if enabled { c.popup?.update(contextID:contextID,title:c.title,items:items,style:style) }
        else { c.popup?.cancel() }
    }
    static func dismantleNSView(_ view:WorkbenchMenuAnchorView,coordinator:Coordinator) { coordinator.enabled=false;coordinator.popup?.cancel(restoreFocus:false);coordinator.anchor=nil }
    @MainActor final class Coordinator {
        var contextID=""
        var enabled=false
        var style:WorkbenchPopupStyle?
        var items:[WorkbenchPopupItem]=[]
        var title=""
        var restoreTrigger: () -> Void = {}
        var onPresentationChange: (Bool) -> Void = { _ in }
        weak var anchor:NSView?
        weak var popup:WorkbenchPopupOverlay?
        func open() {
            guard enabled,let anchor,let style else { return }
            if let popup { popup.cancel();return }
            let captured=contextID, owner=style.owner
            popup=WorkbenchPopupOverlay.present(from:anchor,contextID:captured,title:title,items:items,style:style,validContext:{ [weak self, weak anchor] in
                guard let self,let anchor else { return false }
                return self.enabled && anchor.window != nil && !anchor.isHiddenOrHasHiddenAncestor && self.contextID == captured && self.style?.owner === owner
            },restoreTrigger: { [weak self] in self?.restoreTrigger() },didClose:{ [weak self] in self?.popup=nil; self?.onPresentationChange(false) })
            if popup != nil { onPresentationChange(true) }
        }
    }
}

struct WorkbenchChoiceValue<Value: Hashable> {
    var value: Value
    var title: String
    var enabled = true
    func disabled(_ disabled: Bool) -> Self { var copy = self; copy.enabled = enabled && !disabled; return copy }
}
struct WorkbenchChoiceRows<Value: Hashable> { var choices: [WorkbenchChoiceValue<Value>] }
func WorkbenchChoice<Value: Hashable>(_ title: String, value: Value) -> WorkbenchChoiceValue<Value> { .init(value:value,title:title) }
@resultBuilder enum WorkbenchChoiceBuilder<Value: Hashable> {
    static func buildBlock(_ values: WorkbenchChoiceRows<Value>...) -> WorkbenchChoiceRows<Value> { .init(choices:values.flatMap(\.choices)) }
    static func buildExpression(_ value: WorkbenchChoiceValue<Value>) -> WorkbenchChoiceRows<Value> { .init(choices:[value]) }
    static func buildExpression(_ value: WorkbenchChoiceRows<Value>) -> WorkbenchChoiceRows<Value> { value }
    static func buildOptional(_ value: WorkbenchChoiceRows<Value>?) -> WorkbenchChoiceRows<Value> { value ?? .init(choices:[]) }
    static func buildEither(first:WorkbenchChoiceRows<Value>) -> WorkbenchChoiceRows<Value> { first }
    static func buildEither(second:WorkbenchChoiceRows<Value>) -> WorkbenchChoiceRows<Value> { second }
    static func buildArray(_ values:[WorkbenchChoiceRows<Value>]) -> WorkbenchChoiceRows<Value> { .init(choices:values.flatMap(\.choices)) }
}
func WorkbenchChoiceForEach<C: RandomAccessCollection, ID: Hashable, Value: Hashable>(_ values:C,id:KeyPath<C.Element,ID>,@WorkbenchChoiceBuilder<Value> content:(C.Element)->WorkbenchChoiceRows<Value>) -> WorkbenchChoiceRows<Value> {
    .init(choices:values.flatMap { content($0).choices })
}
func WorkbenchChoiceForEach<C: RandomAccessCollection, Value: Hashable>(_ values:C,@WorkbenchChoiceBuilder<Value> content:(C.Element)->WorkbenchChoiceRows<Value>) -> WorkbenchChoiceRows<Value> where C.Element:Identifiable {
    .init(choices:values.flatMap { content($0).choices })
}
@MainActor func WorkbenchPickerOptions<Value: Hashable>(_ title:String,selection:Binding<Value>,@WorkbenchChoiceBuilder<Value> content:()->WorkbenchChoiceRows<Value>) -> WorkbenchMenuRows {
    .init(items:content().choices.map { option in
        .init(id:String(reflecting:option.value),title:option.title,enabled:option.enabled,checked:selection.wrappedValue == option.value,action:{ selection.wrappedValue = option.value })
    })
}
struct WorkbenchPicker<Value:Hashable>:View {
    let title:String
    let selection:Binding<Value>
    let choices:WorkbenchChoiceRows<Value>
    private var hidesLabel = false
    func labelsHidden() -> Self { var copy = self; copy.hidesLabel = true; return copy }
    init(_ title:String,selection:Binding<Value>,@WorkbenchChoiceBuilder<Value> content:()->WorkbenchChoiceRows<Value>) { self.title=title;self.selection=selection;choices=content() }
    var body:some View {
        WorkbenchMenu(title) { WorkbenchPickerOptions(title,selection:selection) { choices } } label: {
            HStack(spacing:5) { if !hidesLabel { Text(title).foregroundStyle(.secondary); Spacer(minLength: 8) }; Text(choices.choices.first { $0.value == selection.wrappedValue }?.title ?? title).lineLimit(2);Image(systemName:"chevron.down").font(.caption) }
        }.accessibilityLabel(title)
    }
}

@MainActor private final class WorkbenchMenuAnchorView: NSView {
    var contextClick = false
    var openContext: (() -> Void)?
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard contextClick, let event = NSApp.currentEvent,
              (event.type == .rightMouseDown || event.type == .rightMouseUp ||
               (event.modifierFlags.contains(.control) && (event.type == .leftMouseDown || event.type == .leftMouseUp))),
              bounds.contains(convert(point, from: superview)) else { return nil }
        return self
    }
    override func mouseDown(with event: NSEvent) { if event.modifierFlags.contains(.control) { openContext?() } }
    override func mouseUp(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) { openContext?() }
    override func rightMouseUp(with event: NSEvent) {}
}
@MainActor private struct WorkbenchContextMenuModifier: ViewModifier {
    let rows: WorkbenchMenuRows
    var onPresentationChange: (Bool) -> Void = { _ in }
    @State private var handle = WorkbenchMenuHandle()
    func body(content: Content) -> some View {
        content.overlay(WorkbenchMenuAnchor(title: "", items: rows.items, handle: handle, onPresentationChange: onPresentationChange, contextClick: true))
    }
}
extension View {
    @MainActor func workbenchContextMenu(onPresentationChange: @escaping (Bool) -> Void = { _ in }, @WorkbenchMenuBuilder content: () -> WorkbenchMenuRows) -> some View {
        modifier(WorkbenchContextMenuModifier(rows: content(), onPresentationChange: onPresentationChange))
    }
}
