import AppKit
import DWorkbench
import SwiftUI

/// Application preferences have one owner; project actions use the captured
/// destination shown here and are dispatched only after this sheet dismisses.
public struct WorkbenchSettingsView: View {
    private enum Section: String, CaseIterable { case appearance, language, assistance, defaults, voice, files, models, network }
    let model: WorkbenchModel
    let library: ModelLibraryModel
    let language: UILanguageStore
    let projectPath: String?
    let searchTargetLabel: String?
    let onProjectFiles: (() -> Void)?
    let onSearchSettings: (() -> Void)?
    let chat: ChatController?
    let isChatContextValid: @MainActor () -> Bool
    @State private var featureHelp = WorkbenchHelpStore()
    @State private var selected: Section = .appearance
    @State private var visited: Set<Section> = [.appearance]
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    public init(model: WorkbenchModel, library: ModelLibraryModel, language: UILanguageStore,
                projectPath: String?, searchTargetLabel: String?,
                onProjectFiles: (() -> Void)?, onSearchSettings: (() -> Void)?,
                chat: ChatController? = nil, initialSection: String = "appearance",
                isChatContextValid: @escaping @MainActor () -> Bool = { true }) {
        self.model = model; self.library = library; self.language = language
        self.projectPath = projectPath; self.searchTargetLabel = searchTargetLabel
        self.onProjectFiles = onProjectFiles; self.onSearchSettings = onSearchSettings
        self.chat = chat; self.isChatContextValid = isChatContextValid
        let first = Section(rawValue: initialSection) ?? .appearance
        _selected = State(initialValue: first); _visited = State(initialValue: [first])
    }
    private func text(_ key: String, _ en: String, _ zh: String) -> String {
        language.text("refinement.settings." + key,
            fallback: language.effectiveLanguageIdentifier.hasPrefix("zh") ? zh : en)
    }
    private func title(_ section: Section) -> String {
        switch section {
        case .appearance: text("appearance", "Appearance", "外观")
        case .files: text("files", "Files", "文件")
        case .models: workflowText(language, "modelManagement.storageTitle")
        case .network: text("networkCredentials", "Network and access", "网络与访问")
        case .defaults: text("chatDefaults", "Chat", "聊天")
        case .voice: text("voice", "Sound", "声音")
        case .language: text("language", "Language", "语言")
        case .assistance: text("operation", "Keyboard and Mouse", "键盘与鼠标")
        }
    }
    private var unavailableChat: some View {
        Text(text("chatUnavailable2", "No chat workspace is available. Opening this page does not create one.", "当前没有可用的聊天工作区；打开此页不会新建会话。")).foregroundStyle(.secondary)
    }
    @ViewBuilder private func settingsPage(_ section: Section) -> some View {
        switch section {
                    case .appearance:
                        ChatDisplayPreferencesPanel(state: model.chatDisplaySettings)
                            .accessibilityIdentifier("settings-appearance-scroll")
                    case .language: LanguageSettingsView(store: language).workbenchHelp("SETTINGS-LANGUAGE")
                    case .files:
                        Form {
                            if let projectPath {
                                LabeledContent(text("targetProject", "Target project", "目标项目"), value: projectPath)
                                Button(text("projectFiles", "Project files, locations and backups…", "项目文件、位置与备份…"), action: { onProjectFiles?() })
                                    .accessibilityIdentifier("settings-project-files").disabled(onProjectFiles == nil)
                            } else {
                                Text(text("noProject", "No project is open.", "尚未打开项目。"))
                                Button(text("openProject", "Open or create a project…", "打开或新建项目…"), action: { onProjectFiles?() })
                                    .accessibilityIdentifier("settings-open-project").disabled(onProjectFiles == nil)
                            }
                            if onProjectFiles == nil {
                                Text(text("filesUnavailable", "Project navigation is unavailable while the workspace is not ready. Open a project from the application File menu or resolve the startup error.",
                                          "工作区尚未就绪，项目导航不可用。请从应用文件菜单打开项目，或先处理启动错误。")).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(text("cacheNote", "The runtime manages caches and temporary output. Moving model files respects active resource protection.",
                                      "缓存与临时产物由现有运行时管理。更改模型位置仍遵守正在使用的资源保护。"))
                                .font(.caption).foregroundStyle(.secondary)
                            if let error = library.errorMessage { Text(error).foregroundStyle(.red) }
                        }.formStyle(.grouped)
                    case .models:
                        ScrollView { ModelStorageDownloadSettings(model: library).padding(20) }
                    case .network:
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                Text(text("proxyNote", "D uses the system network configuration.", "沿用系统网络配置。")).font(.caption).foregroundStyle(.secondary)
                                Divider()
                                if let chat { ChatSearchCredentialsPanel(chat: chat, isAvailable: isChatContextValid).disabled(!isChatContextValid()) } else { unavailableChat }
                            }.padding(20)
                        }
                    case .defaults:
                        ScrollView {
                            if let chat {
                                VStack(alignment: .leading, spacing: 12) {
                                    if let searchTargetLabel { Text(searchTargetLabel).font(.caption).foregroundStyle(.secondary) }
                                    ChatDefaultsSettingsPanel(chat: chat, isAvailable: isChatContextValid).disabled(!isChatContextValid())
                                }.padding(20)
                            } else { unavailableChat.padding(20) }
                        }
                    case .voice:
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                Toggle(text("endSound", "Sound after a result is saved", "结果保存后播放提示音"), isOn: Binding(
                                    get: { model.chatDisplaySettings.preferences.endSound == true },
                                    set: { value in var next = model.chatDisplaySettings.preferences; next.endSound = value; model.chatDisplaySettings.update(next) }))
                                    .disabled(model.chatDisplaySettings.hasInvalidStoredRecord)
                                    .accessibilityIdentifier("chat-display-end-sound")
                                if let chat { ChatSpeechSettingsPanel(chat: chat).disabled(!isChatContextValid()) } else { unavailableChat }
                            }.padding(20)
                        }
                    case .assistance:
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                Text(title(.assistance)).font(.headline)
                                WorkflowKeyboardSettings(state: model.chatDisplaySettings)
                                Divider()
                                WorkbenchPicker(text("sendShortcut", "Send shortcut", "发送快捷键"), selection: Binding(
                                    get: { model.chatDisplaySettings.preferences.sendShortcut },
                                    set: { value in var next = model.chatDisplaySettings.preferences; next.sendShortcut = value; model.chatDisplaySettings.update(next) })) {
                                        WorkbenchChoice("Command–Return", value:ChatDisplayPreferences.SendShortcut.commandReturn)
                                        WorkbenchChoice(text("return", "Return", "回车"), value:ChatDisplayPreferences.SendShortcut.return)
                                    }.accessibilityIdentifier("chat-display-send-shortcut")
                                    .disabled(model.chatDisplaySettings.hasInvalidStoredRecord)
                                Text(text("inputHelp2", "System composition, selection and Undo remain available. Shift–Return inserts a newline.", "保留系统组字、选区及撤销。Shift–回车换行。"))
                                Divider()
                                Text(text("canvas", "Canvas", "画布")).font(.headline)
                                HStack {
                                    Text(text("wheelSpeed", "Wheel zoom speed", "滚轮缩放速度")).workbenchHelp("WORKSPACE-ZOOM-SPEED")
                                    Spacer()
                                    Text(String(format: "%.2f×", model.chatDisplaySettings.preferences.canvasNavigation?.wheelSpeed ?? 1))
                                        .monospacedDigit()
                                }
                                HStack {
                                    Text(text("slow", "Slow", "慢"))
                                    Slider(value: Binding(get: { model.chatDisplaySettings.preferences.canvasNavigation?.wheelSpeed ?? 1 },
                                        set: { value in
                                            var next = model.chatDisplaySettings.preferences
                                            next.canvasNavigation = .init(wheelSpeed: value)
                                            model.chatDisplaySettings.update(next)
                                        }), in: WorkflowCanvasNavigationPreferences.speedRange)
                                        .accessibilityIdentifier("canvas-wheel-speed")
                                        .accessibilityLabel(text("wheelSpeed", "Wheel zoom speed", "滚轮缩放速度"))
                                    Text(text("fast", "Fast", "快"))
                                    Button(text("resetWheelSpeed", "Reset Default", "恢复默认")) {
                                        var next = model.chatDisplaySettings.preferences; next.canvasNavigation = .init()
                                        model.chatDisplaySettings.update(next)
                                    }.buttonStyle(WorkbenchGlassButtonStyle(compact: true))
                                }.disabled(model.chatDisplaySettings.hasInvalidStoredRecord)
                                Text(text("canvasHelp", "Canvas: pointer selects and connects; hand pans; wheel zooms. Show All Nodes changes the viewport, not node positions.",
                                          "画布：指针选择和连接；手形平移；滚轮缩放。“显示全部节点”只移动视野，不重排节点。"))
                            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                        }
        }
    }
    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(text("title", "Settings", "设置")).font(.title2.bold())
                Spacer()
                WorkbenchFeatureGuideButton(store: featureHelp)
                Button(text("done", "Done", "完成")) { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20)
            if chat != nil && !isChatContextValid() {
                Text(text("targetChanged2", "The captured workspace changed. Reopen Settings from the intended workspace.", "设置目标已改变，请回到目标工作区后重新打开设置。")).foregroundStyle(.red).padding(.horizontal)
            }
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Section.allCases, id: \.self) { section in
                        Button { visited.insert(section); selected = section } label: {
                            Text(title(section)).frame(maxWidth: .infinity, alignment: .leading).padding(10)
                                .background(selected == section ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(WorkbenchRowButtonStyle(cornerRadius: 10)).accessibilityIdentifier("settings-" + section.rawValue)
                            .accessibilityAddTraits(selected == section ? .isSelected : [])
                    }
                    Spacer()
                    if let searchTargetLabel { Text(searchTargetLabel).font(.caption).foregroundStyle(.secondary) }
                    Text(text("scope", "Application preferences and the captured workspace. Each section states its scope.",
                              "应用偏好与当前工作区；各项均标明实际作用范围。")).font(.caption).foregroundStyle(.secondary)
                }.padding(16).frame(width: 210)
                Divider()
                ZStack {
                    ForEach(Section.allCases.filter { visited.contains($0) }, id: \.self) { section in
                        RetainedContentHost(content: settingsPage(section)
                            .environment(\.dLanguageStore, language)
                            .environment(\.chatDisplayPreferences, model.chatDisplaySettings.preferences)
                            .preferredColorScheme(colorScheme)
                            .foregroundStyle(model.chatDisplaySettings.preferences.resolvedAppearance.palette(for: colorScheme).foregroundColor,
                                model.chatDisplaySettings.preferences.resolvedAppearance.palette(for: colorScheme).secondaryColor)
                            .tint(model.chatDisplaySettings.preferences.resolvedAppearance.palette(for: colorScheme).accentColor)
                            .disabled(selected != section),
                            visible: selected == section, identifier: "settings-page-" + section.rawValue)
                            .allowsHitTesting(selected == section).accessibilityHidden(selected != section)
                    }

                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.frame(minWidth: 700, idealWidth: 840, minHeight: 520, idealHeight: 660)
            .environment(\.workbenchHelpStore, featureHelp)
            .sheet(item: $featureHelp.presentation) { WorkbenchFeatureGuide(presentation: $0, store: featureHelp).environment(\.dLanguageStore, language) }
            .workbenchTheme(paintsCanvas: false)
            .environment(\.dLanguageStore, language)
            .environment(\.chatDisplayPreferences, model.chatDisplaySettings.preferences)
            .preferredColorScheme(model.chatDisplaySettings.preferences.preferredColorScheme)

    }
}
