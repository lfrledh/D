import SwiftUI

struct ChatDisplayPreferencesPanel: View {
    let state: ChatDisplayPreferencesState
    @Environment(\.dLanguageStore) private var language

    private func wording(_ en: String, _ zh: String) -> String {
        language?.effectiveLanguageIdentifier.hasPrefix("zh") == true ? zh : en
    }

    private func change(_ edit: (inout ChatDisplayPreferences) -> Void) {
        var candidate = state.preferences
        edit(&candidate)
        state.update(candidate)
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
        }
    }
}
