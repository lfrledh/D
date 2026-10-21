import AppKit
import SwiftUI

/// A finite set of presentation commands. Owners below invoke their existing actions.
enum WorkflowKeyboardCommand: String, Codable, CaseIterable {
    case search, tags, leftTools, rightTools, activity, preview, pointer, hand, undo, redo, showAll, runCheck
    var titleKey: String { "workspace.shortcut." + rawValue }
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
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(workflowText(language, "workspace.shortcuts.workspaceShortcuts")).font(.headline)
            TextField(workflowText(language, "workspace.shortcuts.searchCommands"), text: $query)
            Text(workflowText(language, "workspace.shortcuts.focusTheWorkspaceOrLibraryFirstTextEditingAndComposition"))
                .font(.caption).foregroundStyle(.secondary)
            if let issue { Text(issue).foregroundStyle(.red).font(.caption) }
            ForEach(WorkflowKeyboardCommand.allCases.filter { query.isEmpty || workflowText(language, $0.titleKey).localizedStandardContains(query) }, id: \.self) { command in
                HStack {
                    Text(workflowText(language, command.titleKey)); Spacer()
                    Button(recording == command ? workflowText(language, "workspace.shortcuts.pressShortcut") : preferences.binding(command).display) {
                        issue = nil; recording = command
                    }.frame(minWidth: 140)
                    if recording == command {
                        WorkflowKeyRecorder { value in
                            recording = nil
                            guard let value else { return }
                            guard value.valid, !value.reserved else { issue = workflowText(language, "workspace.shortcuts.useCommandOrControlWithALetterOrDigitSystem"); return }
                            if let other = preferences.conflict(value, for: command) {
                                issue = workflowText(language, "workspace.shortcuts.conflict") + workflowText(language, other.titleKey); return
                            }
                            var next = state.preferences; var keys = preferences
                            keys.overrides[command] = value; next.workflowKeyboard = keys; state.update(next)
                        }.frame(width: 1, height: 1)
                    }
                }
            }
            Button(workflowText(language, "workspace.shortcuts.restoreDefaultShortcuts")) {
                recording = nil; issue = nil; var next = state.preferences; next.workflowKeyboard = nil; state.update(next)
            }
        }.disabled(state.hasInvalidStoredRecord)
    }
}
