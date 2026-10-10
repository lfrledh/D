import AppKit
import AVFAudio
import DWorkbench
import SwiftUI

private struct OpenWorkbenchSettingsKey: EnvironmentKey {
    static let defaultValue: (@MainActor (String) -> Void)? = nil
}
extension EnvironmentValues {
    var openWorkbenchSettings: (@MainActor (String) -> Void)? {
        get { self[OpenWorkbenchSettingsKey.self] }
        set { self[OpenWorkbenchSettingsKey.self] = newValue }
    }
}

/// The controller remains the owner. Settings navigation never creates a session.
struct ChatDefaultsSettingsPanel: View {
    let chat: ChatController
    var isAvailable: @MainActor () -> Bool = { true }
    @Environment(\.dLanguageStore) private var language
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.chatDisplayPreferences) private var preferences
    @State private var draft = ""
    @State private var loaded = false
    @State private var issue: String?
    private func t(_ key: String, _ en: String, _ zh: String) -> String { workflowText(language, "chat.organization." + key, fallback: language?.effectiveLanguageIdentifier.hasPrefix("zh") == true ? zh : en) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(t("defaults.title", "New conversation default rules", "新会话默认规则")).font(.headline)
            Text(chat.isTemporary
                 ? t("defaults.temporaryScope", "Applies only to new conversations in this temporary workspace; kept in memory.", "仅用于此临时工作区的新会话，保存在内存中。")
                 : t("defaults.appScope", "Saved in application preferences. Existing conversations are unchanged.", "保存于应用偏好，不回写已有会话。"))
                .font(.caption).foregroundStyle(.secondary)
            TextSourcesQuestionEditor(value: draft, editEpoch: 0, isEditable: true,
                accessibilityIdentifier: "settings-default-rules", onEdit: { draft = $0 },
                transparentBackground: true, foregroundColor: NSColor(preferences.resolvedAppearance.palette(for: colorScheme).foregroundColor))
                .frame(height: 140).padding(8).workbenchPanel(cornerRadius: 10)
            Text(draft == chat.defaultSystemPrompt ? t("defaults.saved", "Saved default", "已保存的默认规则") : t("defaults.unsaved", "Changes not saved", "修改尚未保存")).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(t("defaults.save", "Save default", "保存默认规则")) {
                    do { guard isAvailable() else { return }; try chat.setDefaultSystemPrompt(draft); issue = nil } catch { issue = error.localizedDescription }
                }.disabled(draft == chat.defaultSystemPrompt)
                Button(t("defaults.discard", "Revert edits", "放弃修改")) { draft = chat.defaultSystemPrompt }
                Button(t("defaults.clear", "Clear editor", "清空编辑框")) { draft = "" }
            }
            if let issue { Text(ChatErrorText.display(issue, language: language)).foregroundStyle(.red) }
            Divider()
            Text(t("presets.title", "Common presets · this workspace", "常用预设 · 当前工作区")).font(.headline)
            Text(t("presets.scope", "Presets belong to this project's store. Managing them does not change a conversation; Apply is explicit.", "预设保存在当前项目中。管理预设不会改变会话；只有点击应用才会生效。"))
                .font(.caption).foregroundStyle(.secondary)
            ChatPresetsManagementPanel(chat: chat, isAvailable: isAvailable, sessionID: chat.state.selectedSessionID)
        }.onAppear { if !loaded { draft = chat.defaultSystemPrompt; loaded = true } }
    }
}

struct ChatPresetsManagementPanel: View {
    let chat: ChatController
    var isAvailable: @MainActor () -> Bool = { true }
    let sessionID: UUID?
    @Environment(\.dLanguageStore) private var language
    @State private var busy = false
    @State private var pending: Data?
    @State private var pendingNames: [String] = []
    @State private var issue: String?
    private func t(_ key: String, _ en: String, _ zh: String) -> String { workflowText(language, "chat.organization." + key, fallback: language?.effectiveLanguageIdentifier.hasPrefix("zh") == true ? zh : en) }
    var body: some View {
        VStack(alignment: .leading) {
            ChatPresetsPanel(chat: chat, sessionID: sessionID,
                onImport: { Task { await importFile() } },
                onExport: { values in Task { await export(values) } }, showsHeading: false).disabled(busy)
            if let pending {
                Text(t("presets.importPreview", "Import copies: ", "将作为副本导入：") + pendingNames.joined(separator: "、"))
                HStack {
                    Button(t("presets.importConfirm", "Import these presets", "导入这些预设")) {
                        do { guard isAvailable() else { return }; try chat.importPresets(pending); self.pending = nil; issue = nil }
                        catch { issue = error.localizedDescription }
                    }
                    Button(t("presets.importCancel", "Cancel import", "取消导入")) { self.pending = nil }
                }
            }
            if let issue { Text(ChatErrorText.display(issue, language: language)).foregroundStyle(.red) }
        }
    }
    private func importFile() async {
        guard !busy, isAvailable() else { return }; busy = true; defer { busy = false }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard await panel.begin() == .OK, let url = panel.url, isAvailable() else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let info = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard info.isRegularFile == true, let size = info.fileSize, size <= 2_097_152 else { throw WorkflowIssue(t("presets.importLimit", "Preset file must be at most 2 MiB.", "预设文件不能超过 2 MiB。")) }
            let data = try Data(contentsOf: url)
            pendingNames = try ChatPresetFile.decode(data).map(\.name); pending = data; issue = nil
        } catch { issue = error.localizedDescription }
    }
    private func export(_ values: [ChatPromptPreset]) async {
        guard !busy, isAvailable() else { return }; busy = true; defer { busy = false }
        do {
            _ = try ChatPresetFile.encode(values)
            let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
            guard await panel.begin() == .OK, let url = panel.url, isAvailable() else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            _ = try await chat.store.exportChatPresets(values, exportID: UUID(), directory: url); issue = nil
        } catch { issue = error.localizedDescription }
    }
}

struct ChatSpeechSettingsPanel: View {
    let chat: ChatController
    @Environment(\.dLanguageStore) private var language
    @State private var voice = ""
    @State private var rate: Double = 0.5
    @State private var voices: [ChatSystemVoice] = []
    @State private var issue: String?
    private func t(_ key: String, _ en: String, _ zh: String) -> String { workflowText(language, "chat.organization." + key, fallback: language?.effectiveLanguageIdentifier.hasPrefix("zh") == true ? zh : en) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(t("voice.title", "Read-aloud voice · current chat workspace", "朗读声音 · 当前聊天工作区")).font(.headline)
            Text(t("voice.scope", "Uses the existing system speech service. Voice and rate last for this opening; they do not change recognition language or the chat model.", "沿用当前系统朗读服务。声音和语速仅本次打开有效，不改变识别语言或聊天模型。"))
                .font(.caption).foregroundStyle(.secondary)
            Picker(t("voice.choice", "System voice", "系统声音"), selection: Binding(get: { voice }, set: { value in
                do { if value.isEmpty { try chat.speech.selectSystemDefaultVoice() } else { try chat.speech.selectVoice(id: value) }; voice = chat.speech.voiceID ?? ""; issue = nil }
                catch { issue = error.localizedDescription }
            })) {
                Text(t("voice.systemDefault", "System default", "系统默认")).tag("")
                ForEach(voices) { Text($0.name + " · " + $0.language).tag($0.id) }
            }
            Text(t("voice.rate", "Reading speed", "朗读速度"))
            Slider(value: Binding(get: { rate }, set: { value in
                do { try chat.speech.setRate(Float(value)); rate = Double(chat.speech.rate); issue = nil } catch { issue = error.localizedDescription }
            }), in: Double(chat.speech.rateRange.lowerBound)...Double(chat.speech.rateRange.upperBound))
            if let issue { Text(ChatErrorText.display(issue, language: language)).foregroundStyle(.red) }
        }.onAppear { voices = chat.speech.availableVoices; voice = chat.speech.voiceID ?? ""; rate = Double(chat.speech.rate) }
            .onReceive(NotificationCenter.default.publisher(for: AVSpeechSynthesizer.availableVoicesDidChangeNotification)) { _ in voices = chat.speech.availableVoices }
    }
}

struct ChatSearchCredentialsPanel: View {
    let chat: ChatController
    var isAvailable: @MainActor () -> Bool = { true }
    @Environment(\.dLanguageStore) private var language
    @State private var busy = false
    @State private var issue: String?
    private func t(_ key: String, _ en: String, _ zh: String) -> String { workflowText(language, "chat.organization." + key, fallback: language?.effectiveLanguageIdentifier.hasPrefix("zh") == true ? zh : en) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(t("credentials.title", "Search credentials", "搜索服务凭据")).font(.headline)
            Text(t("credentials.scope", "Only the local key-file bookmark is stored in application settings. Keys are excluded from projects and backups. Opening this page sends no request; live service validation remains deferred.", "应用设置仅保存本地密钥文件的访问关联；密钥不进入项目与备份。打开此页不发请求；真实服务验证仍延期。"))
                .font(.caption).foregroundStyle(.secondary)
            ForEach([ChatSearchProvider.brave, .bocha], id: \.self) { provider in
                VStack(alignment: .leading, spacing: 6) {
                    Text(provider == .brave ? "Brave Search" : "Bocha Web Search").font(.subheadline.bold())
                    Text(chat.configuredSearchProviders.contains(provider) ? t("credentials.connected", "Local credential connected", "已关联本地凭据") : t("credentials.disconnected", "Not connected", "未关联凭据"))
                    HStack {
                        Button(t("credentials.choose", "Choose key file…", "选择密钥文件…")) { Task { await choose(provider) } }
                        if chat.configuredSearchProviders.contains(provider) {
                            Button(t("credentials.remove", "Remove connection", "移除关联")) { chat.removeSearchCredential(provider) }
                        }
                    }.disabled(busy || chat.isToolRunning)
                }
            }
            if let issue { Text(ChatErrorText.display(issue, language: language)).foregroundStyle(.red) }
        }
    }
    private func choose(_ provider: ChatSearchProvider) async {
        guard !busy, !chat.isToolRunning, isAvailable() else { return }; busy = true; defer { busy = false }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = t("credentials.fileHelp", "Choose a plain-text file containing only your API key, without a trailing newline.", "选择仅含您本人 API 密钥、末尾无换行的本地纯文本文件。")
        guard await panel.begin() == .OK, let url = panel.url, isAvailable() else { return }
        do { try chat.configureSearchCredential(url, provider: provider); issue = nil } catch { issue = error.localizedDescription }
    }
}
