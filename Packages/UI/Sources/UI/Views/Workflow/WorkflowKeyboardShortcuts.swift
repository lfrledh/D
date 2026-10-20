import AppKit
import SwiftUI

/// A finite set of presentation commands. Owners below invoke their existing actions.
enum WorkflowKeyboardCommand: String, Codable, CaseIterable {
    case search, tags, leftTools, rightTools, activity, preview, pointer, hand, undo, redo, showAll, runCheck
    var title: (zh: String, en: String) {
        switch self {
        case .search: ("聚焦当前资料栏搜索", "Focus current library search")
        case .tags: ("打开当前资料栏标签", "Open current library tags")
        case .leftTools: ("切换左侧工具页", "Cycle left tools")
        case .rightTools: ("切换右侧素材页", "Cycle right resources")
        case .activity: ("打开运行记录", "Open run history")
        case .preview: ("只读查看选中素材", "View selected resource")
        case .pointer: ("指针工具", "Pointer tool")
        case .hand: ("手形工具", "Hand tool")
        case .undo: ("撤销画布编辑", "Undo canvas edit")
        case .redo: ("重做画布编辑", "Redo canvas edit")
        case .showAll: ("显示全部节点", "Show all nodes")
        case .runCheck: ("打开运行检查", "Open run check")
        }
    }
    var defaultKey: String {
        switch self {
        case .search: "f"; case .tags: "t"; case .leftTools: "l"; case .rightTools: "r"
        case .activity: "a"; case .preview: "v"; case .pointer: "p"; case .hand: "h"
        case .undo: "z"; case .redo: "y"; case .showAll: "0"; case .runCheck: "g"
        }
    }
}

struct WorkflowKeyBinding: Codable, Equatable, Hashable {
    var key: String
    var command = true
    var option = true
    var shift = false
    var control = false
    var display: String {
        (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "") + key.uppercased()
    }
    var valid: Bool {
        key.count == 1 && key.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII }
            && (command || control)
    }
    var reserved: Bool {
        // System text editing, application File/Settings and send shortcuts keep ownership.
        command && !control && !option && ["a", "c", "v", "x", "z", "q", "w", "h", "m", "n", "o", "s", "e", "f"].contains(key)
    }
    init(key: String, command: Bool = true, option: Bool = true, shift: Bool = false, control: Bool = false) {
        self.key = key.lowercased(); self.command = command; self.option = option; self.shift = shift; self.control = control
    }
    init?(_ event: NSEvent) {
        guard let value = event.charactersIgnoringModifiers?.lowercased(), value.count == 1 else { return nil }
        self.init(key: value, command: event.modifierFlags.contains(.command), option: event.modifierFlags.contains(.option),
                  shift: event.modifierFlags.contains(.shift), control: event.modifierFlags.contains(.control))
    }
    func matches(_ press: KeyPress) -> Bool {
        // Option may transform KeyPress.character; the synchronous native event retains the base key.
        let base = NSApp.currentEvent.flatMap { $0.type == .keyDown ? $0.charactersIgnoringModifiers?.lowercased() : nil }
            ?? press.key.character.lowercased()
        return key == base && command == press.modifiers.contains(.command)
            && option == press.modifiers.contains(.option) && shift == press.modifiers.contains(.shift)
            && control == press.modifiers.contains(.control)
    }
}

struct WorkflowKeyboardPreferences: Codable, Equatable {
    var overrides: [WorkflowKeyboardCommand: WorkflowKeyBinding] = [:]
    func binding(_ command: WorkflowKeyboardCommand) -> WorkflowKeyBinding { overrides[command] ?? .init(key: command.defaultKey) }
    var isValid: Bool {
        let values = WorkflowKeyboardCommand.allCases.map(binding)
        return values.allSatisfy { $0.valid && !$0.reserved } && Set(values).count == values.count
    }
    func conflict(_ value: WorkflowKeyBinding, for command: WorkflowKeyboardCommand) -> WorkflowKeyboardCommand? {
        WorkflowKeyboardCommand.allCases.first { $0 != command && binding($0) == value }
    }
}

private struct WorkflowKeyboardModifier: ViewModifier {
    @Environment(\.chatDisplayPreferences) private var preferences
    @Environment(\.workbenchContentVisible) private var visible
    let perform: (WorkflowKeyboardCommand) -> Bool
    func body(content: Content) -> some View {
        content.onKeyPress(phases: .down) { press in
            guard visible, let window = NSApp.keyWindow, window.attachedSheet == nil,
                  !(window.firstResponder is NSTextView),
                  let command = WorkflowKeyboardCommand.allCases.first(where: { (preferences.workflowKeyboard ?? .init()).binding($0).matches(press) })
            else { return .ignored }
            return perform(command) ? .handled : .ignored
        }
    }
}
extension View {
    func workflowKeyboardCommands(_ perform: @escaping (WorkflowKeyboardCommand) -> Bool) -> some View {
        modifier(WorkflowKeyboardModifier(perform: perform))
    }
}

/// Captures only while this explicit recorder is first responder; no application/global monitor.
private struct WorkflowKeyRecorder: NSViewRepresentable {
    let record: (WorkflowKeyBinding?) -> Void
    func makeNSView(context: Context) -> Recorder { let view = Recorder(); view.record = record; return view }
    func updateNSView(_ view: Recorder, context: Context) { view.record = record }
    final class Recorder: NSView {
        var record: ((WorkflowKeyBinding?) -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); window?.makeFirstResponder(self) }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard window?.firstResponder === self else { return false }
            keyDown(with: event); return true
        }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { record?(nil); return }
            record?(WorkflowKeyBinding(event))
        }
    }
}

struct WorkflowKeyboardSettings: View {
    let state: ChatDisplayPreferencesState
    @Environment(\.dLanguageStore) private var language
    @State private var query = ""
    @State private var recording: WorkflowKeyboardCommand?
    @State private var issue: String?
    private var preferences: WorkflowKeyboardPreferences { state.preferences.workflowKeyboard ?? .init() }
    private func t(_ zh: String, _ en: String) -> String { language?.effectiveLanguageIdentifier.hasPrefix("zh") == true ? zh : en }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(t("工作区快捷键", "Workspace shortcuts")).font(.headline)
            TextField(t("搜索命令", "Search commands"), text: $query)
            Text(t("先聚焦相应工作区或资料栏。文字编辑和输入法优先；运行快捷键只打开检查，不提交运行。",
                   "Focus the workspace or library first. Text editing and composition take priority. Run check never submits a run."))
                .font(.caption).foregroundStyle(.secondary)
            if let issue { Text(issue).foregroundStyle(.red).font(.caption) }
            ForEach(WorkflowKeyboardCommand.allCases.filter { query.isEmpty || t($0.title.zh, $0.title.en).localizedStandardContains(query) }, id: \.self) { command in
                HStack {
                    Text(t(command.title.zh, command.title.en)); Spacer()
                    Button(recording == command ? t("请按组合键…", "Press shortcut…") : preferences.binding(command).display) {
                        issue = nil; recording = command
                    }.frame(minWidth: 140)
                    if recording == command {
                        WorkflowKeyRecorder { value in
                            recording = nil
                            guard let value else { return }
                            guard value.valid, !value.reserved else { issue = t("请使用含 Command 或 Control 的字母/数字组合，保留系统与文字编辑快捷键。", "Use Command or Control with a letter or digit; system and text-editing shortcuts are reserved."); return }
                            if let other = preferences.conflict(value, for: command) {
                                issue = t("冲突：", "Conflict: ") + t(other.title.zh, other.title.en); return
                            }
                            var next = state.preferences; var keys = preferences
                            keys.overrides[command] = value; next.workflowKeyboard = keys; state.update(next)
                        }.frame(width: 1, height: 1)
                    }
                }
            }
            Button(t("恢复快捷键默认值", "Restore default shortcuts")) {
                recording = nil; issue = nil; var next = state.preferences; next.workflowKeyboard = nil; state.update(next)
            }
        }.disabled(state.hasInvalidStoredRecord)
    }
}
