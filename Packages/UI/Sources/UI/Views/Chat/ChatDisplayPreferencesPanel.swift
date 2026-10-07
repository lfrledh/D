import SwiftUI

struct ChatDisplayPreferencesPanel: View {
    let state: ChatDisplayPreferencesState
    @Environment(\.dLanguageStore) private var language
    @State private var editingScheme: ColorScheme = .light
    @State private var hexDrafts: [String: String] = [:]

    private enum PaletteField: String, CaseIterable {
        case foreground, secondary, canvas, panel, accent

        func value(in palette: WorkbenchPalette) -> String {
            switch self {
            case .foreground: palette.foreground
            case .secondary: palette.secondary
            case .canvas: palette.canvas
            case .panel: palette.panel
            case .accent: palette.accent
            }
        }

        func set(_ value: String, in palette: inout WorkbenchPalette) {
            switch self {
            case .foreground: palette.foreground = value
            case .secondary: palette.secondary = value
            case .canvas: palette.canvas = value
            case .panel: palette.panel = value
            case .accent: palette.accent = value
            }
        }
    }

    private func wording(_ en: String, _ zh: String) -> String {
        language?.effectiveLanguageIdentifier.hasPrefix("zh") == true ? zh : en
    }

    @discardableResult
    private func change(_ edit: (inout ChatDisplayPreferences) -> Void) -> Bool {
        var candidate = state.preferences
        edit(&candidate)
        return state.update(candidate)
    }

    private var selectedPalette: WorkbenchPalette {
        state.preferences.resolvedAppearance.palette(for: editingScheme)
    }

    private func draftKey(_ field: PaletteField) -> String {
        "\(editingScheme == .dark ? "dark" : "light").\(field.rawValue)"
    }

    private func editHex(_ field: PaletteField, value: String) {
        let key = draftKey(field)
        hexDrafts[key] = value
        guard WorkbenchPalette.isValidHex(value) else { return }
        let normalized = value.uppercased()
        if change({ preferences in
            var appearance = preferences.resolvedAppearance
            if editingScheme == .dark {
                field.set(normalized, in: &appearance.dark)
            } else {
                field.set(normalized, in: &appearance.light)
            }
            preferences.appearance = appearance
        }) {
            hexDrafts.removeValue(forKey: key)
        }
    }

    private func paletteField(_ field: PaletteField) -> some View {
        let key = draftKey(field)
        let draft = hexDrafts[key]
        return VStack(alignment: .leading, spacing: 3) {
            TextField(field.rawValue.capitalized, text: Binding(
                get: { hexDrafts[key] ?? field.value(in: selectedPalette) },
                set: { editHex(field, value: $0) }))
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("workbench-\(key)")
            if let draft, !WorkbenchPalette.isValidHex(draft) {
                Text(wording("Use #RRGGBB (six hexadecimal digits). The saved color is unchanged.",
                             "请输入 #RRGGBB（六位十六进制）。已保存颜色不会改变。"))
                    .font(.caption).foregroundStyle(.red)
            }
        }
    }

    var body: some View {
        Form {
            if state.hasInvalidStoredRecord {
                Text(wording("Saved chat display settings are invalid. The original record is preserved. Reset it to edit these settings.",
                             "已保存的聊天显示设置无效。原始记录已保留。重置后才能编辑这些设置。"))
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("chat-display-invalid-record")
                Button(wording("Reset display settings", "重置显示设置")) { state.reset() }
                    .accessibilityIdentifier("chat-display-reset")
            }

            Section {
            Picker(wording("Appearance", "外观"), selection: Binding(
                get: { state.preferences.theme }, set: { value in change { $0.theme = value } })) {
                    Text(wording("System", "跟随系统")).tag(ChatDisplayPreferences.Theme.system)
                    Text(wording("Light", "浅色")).tag(ChatDisplayPreferences.Theme.light)
                    Text(wording("Dark", "深色")).tag(ChatDisplayPreferences.Theme.dark)
                }
                .accessibilityIdentifier("chat-display-theme")

            Stepper(value: Binding(get: { state.preferences.textPointSize },
                                   set: { value in change { $0.textPointSize = value } }), in: 12...28) {
                Text("\(wording("Text size", "文字大小")): \(state.preferences.textPointSize) pt")
            }
            .accessibilityIdentifier("chat-display-text-size")

            Stepper(value: Binding(get: { state.preferences.transcriptWidth },
                                   set: { value in change { $0.transcriptWidth = value } }), in: 480...1100, step: 20) {
                Text("\(wording("Transcript width", "记录宽度")): \(state.preferences.transcriptWidth) pt")
            }
            .accessibilityIdentifier("chat-display-transcript-width")

            Toggle(wording("Wrap code lines", "代码自动换行"), isOn: Binding(
                get: { state.preferences.wrapsCode }, set: { value in change { $0.wrapsCode = value } }))
                .accessibilityIdentifier("chat-display-code-wrap")

            Toggle(wording("Sound after a result is saved", "结果保存后播放提示音"), isOn: Binding(
                get: { state.preferences.endSound == true }, set: { value in change { $0.endSound = value } }))
                .accessibilityIdentifier("chat-display-end-sound")
            Picker(wording("Send shortcut", "发送快捷键"), selection: Binding(
                get: { state.preferences.sendShortcut }, set: { value in change { $0.sendShortcut = value } })) {
                    Text(wording("Command–Return", "Command–回车")).tag(ChatDisplayPreferences.SendShortcut.commandReturn)
                    Text(wording("Return", "回车")).tag(ChatDisplayPreferences.SendShortcut.`return`)
                }
                .accessibilityIdentifier("chat-display-send-shortcut")
            }
            .disabled(state.hasInvalidStoredRecord)

            Section(wording("Workbench colors", "工作台配色")) {
                Picker(wording("Editing palette", "编辑配色"), selection: $editingScheme) {
                    Text(wording("Light", "浅色")).tag(ColorScheme.light)
                    Text(wording("Dark", "深色")).tag(ColorScheme.dark)
                }
                .accessibilityIdentifier("workbench-palette-selection")
                ForEach(PaletteField.allCases, id: \.self) { field in
                    paletteField(field)
                }
                let issues = selectedPalette.contrastIssues(
                    backgroundTransparency: state.preferences.resolvedAppearance.backgroundTransparency)
                if !issues.isEmpty {
                    Text(wording("Low contrast: ", "对比度较低：") + issues.joined(separator: ", "))
                        .font(.caption).foregroundStyle(.red)
                        .accessibilityIdentifier("workbench-low-contrast")
                }
                Button(wording("Reset selected palette", "重置当前配色")) {
                    let scheme = editingScheme
                    if change({ preferences in
                        var appearance = preferences.resolvedAppearance
                        appearance.resetPalette(for: scheme)
                        preferences.appearance = appearance
                    }) {
                        hexDrafts = hexDrafts.filter { !$0.key.hasPrefix(scheme == .dark ? "dark." : "light.") }
                    }
                }
                .accessibilityIdentifier("workbench-palette-reset")
            }
            .disabled(state.hasInvalidStoredRecord)

            Section(wording("Effects", "视觉效果")) {
                VStack(alignment: .leading) {
                    Text("\(wording("Background transparency", "背景透明度")): \(Int(state.preferences.resolvedAppearance.backgroundTransparency * 100))%")
                    Slider(value: Binding(
                        get: { state.preferences.resolvedAppearance.backgroundTransparency },
                        set: { value in change { preferences in
                            var appearance = preferences.resolvedAppearance
                            appearance.backgroundTransparency = value
                            preferences.appearance = appearance
                        } }), in: 0...1)
                        .accessibilityIdentifier("workbench-background-transparency")
                }
                VStack(alignment: .leading) {
                    Text("\(wording("Motion", "动态效果")): \(Int(state.preferences.resolvedAppearance.motion * 100))%")
                    Slider(value: Binding(
                        get: { state.preferences.resolvedAppearance.motion },
                        set: { value in change { preferences in
                            var appearance = preferences.resolvedAppearance
                            appearance.motion = value
                            preferences.appearance = appearance
                        } }), in: 0...1)
                        .accessibilityIdentifier("workbench-motion")
                }
                Toggle(wording("Lightweight appearance", "轻量外观"), isOn: Binding(
                    get: { state.preferences.resolvedAppearance.lightweight },
                    set: { value in change { preferences in
                        var appearance = preferences.resolvedAppearance
                        appearance.lightweight = value
                        preferences.appearance = appearance
                    } }))
                    .accessibilityIdentifier("workbench-lightweight")
            }
            .disabled(state.hasInvalidStoredRecord)
        }
        .onAppear { if state.preferences.theme == .dark { editingScheme = .dark } }
    }
}
