import AppKit
import DWorkbench
import SwiftUI

/// Application preferences have one owner; project actions use the captured
/// destination shown here and are dispatched only after this sheet dismisses.
public struct WorkbenchSettingsView: View {
    private enum Section: String, CaseIterable { case appearance, files, network, credentials, language, assistance }
    let model: WorkbenchModel
    let library: ModelLibraryModel
    let language: UILanguageStore
    let projectPath: String?
    let searchTargetLabel: String?
    let onProjectFiles: (() -> Void)?
    let onSearchSettings: (() -> Void)?
    @State private var selected: Section = .appearance
    @State private var modelsVisible = false
    @Environment(\.dismiss) private var dismiss

    public init(model: WorkbenchModel, library: ModelLibraryModel, language: UILanguageStore,
                projectPath: String?, searchTargetLabel: String?,
                onProjectFiles: (() -> Void)?, onSearchSettings: (() -> Void)?) {
        self.model = model; self.library = library; self.language = language
        self.projectPath = projectPath; self.searchTargetLabel = searchTargetLabel
        self.onProjectFiles = onProjectFiles; self.onSearchSettings = onSearchSettings
    }
    private func text(_ key: String, _ en: String, _ zh: String) -> String {
        language.text("refinement.settings." + key,
            fallback: language.effectiveLanguageIdentifier.hasPrefix("zh") ? zh : en)
    }
    private func title(_ section: Section) -> String {
        switch section {
        case .appearance: text("appearance", "Appearance", "外观")
        case .files: text("files", "Files and locations", "文件与路径")
        case .network: text("network", "Network", "网络")
        case .credentials: text("credentials", "API credentials", "API 凭证")
        case .language: text("language", "Language", "语言")
        case .assistance: text("assistance", "Controls and accessibility", "操作与辅助")
        }
    }
    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(text("title", "Settings", "设置")).font(.title2.bold())
                Spacer()
                Button(text("done", "Done", "完成")) { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20)
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Section.allCases, id: \.self) { section in
                        Button { selected = section } label: {
                            Text(title(section)).frame(maxWidth: .infinity, alignment: .leading).padding(10)
                                .background(selected == section ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain).accessibilityIdentifier("settings-" + section.rawValue)
                            .accessibilityAddTraits(selected == section ? .isSelected : [])
                    }
                    Spacer()
                    Text(text("scope", "Model parameters belong to the next request. These are application preferences.",
                              "模型参数属于下一次请求；这里管理应用偏好。")).font(.caption).foregroundStyle(.secondary)
                }.padding(16).frame(width: 210)
                Divider()
                Group {
                    switch selected {
                    case .appearance: ChatDisplayPreferencesPanel(state: model.chatDisplaySettings)
                    case .language: LanguageSettingsView(store: language)
                    case .files:
                        Form {
                            LabeledContent(text("modelLibrary", "Model library", "模型库"),
                                value: library.rootURL?.path ?? text("notSet", "Not set", "尚未指定"))
                            Button(text("chooseModelLocation", "Choose model library location…", "选择模型库位置…")) {
                                Task { await library.chooseRoot() }
                            }.disabled(!library.canChooseRoot)
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
                    case .network:
                        Form {
                            Text(text("downloadNote", "The existing downloader manages model downloads. Opening Settings does not connect or load a model.",
                                      "模型下载由已有下载器管理；不会因打开设置而联网或加载模型。"))
                            Button(text("downloadManager", "Downloads and installation…", "下载与安装管理…")) { modelsVisible = true }
                            Text(text("proxyNote", "D uses the system network configuration; there is no separate proxy switch.",
                                      "代理与网络连接沿用系统配置；D 没有独立的代理开关。")).font(.caption).foregroundStyle(.secondary)
                        }.formStyle(.grouped)
                    case .credentials:
                        Form {
                            Text(text("hf", "Hugging Face download credentials", "Hugging Face 下载凭据")).font(.headline)
                            Text(library.downloadCredentialConnected
                                ? text("connected", "Local token file connected", "已连接本地令牌文件")
                                : text("disconnected", "Not connected; public files remain available", "未连接；公开文件仍可下载"))
                            Button(text("chooseCredential", "Choose credential file…", "选择凭据文件…")) {
                                Task { await library.chooseDownloadCredential() }
                            }.disabled(!library.canChangeDownloadCredential)
                            if library.downloadCredentialConnected {
                                Button(text("removeConnection", "Remove connection", "移除连接")) {
                                    Task { await library.removeDownloadCredential() }
                                }.disabled(!library.canChangeDownloadCredential)
                            }
                            Divider()
                            Text("Brave / Bocha").font(.headline)
                            Text(text("searchNote", "Uses the existing local search credentials. Live service validation is deferred. Opening this page sends no request.",
                                      "沿用现有本地搜索凭据。真实服务验证仍延期；打开此页不会发出请求。"))
                            if let searchTargetLabel { LabeledContent(text("targetChat", "Target conversation", "目标会话"), value: searchTargetLabel) }
                            Button(text("searchTools", "Open conversation search and tools", "打开会话的搜索与工具")) { onSearchSettings?() }
                                .disabled(onSearchSettings == nil).accessibilityIdentifier("settings-search-tools")
                            if onSearchSettings == nil {
                                Text(text("chatUnavailable", "The conversation store is unavailable. Return to the workbench to prepare a workspace.",
                                          "会话存储尚不可用，请返回工作台准备工作区。")).font(.caption).foregroundStyle(.secondary)
                            }
                        }.formStyle(.grouped)
                    case .assistance:
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                Text(title(.assistance)).font(.headline)
                                Text(text("inputHelp", "Text fields retain system composition, selection and Undo. Set send shortcut, text size and code wrapping in Appearance.",
                                          "输入框内保留系统组字、选区及撤销。发送快捷键、正文大小和代码换行在外观中调整。"))
                                Text(text("canvasHelp", "Canvas: pointer selects and connects; hand pans; wheel zooms; middle click centers. Fit view changes the viewport, not node positions.",
                                          "画布：指针选择和连接；手形平移；滚轮缩放；中键回到中心。适配视图只移动视野，不重排节点。"))
                                Button(text("downloadManager", "Downloads and installation…", "下载与安装管理…")) { modelsVisible = true }
                            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.frame(minWidth: 700, idealWidth: 840, minHeight: 520, idealHeight: 660)
            .workbenchTheme()
            .environment(\.dLanguageStore, language)
            .environment(\.chatDisplayPreferences, model.chatDisplaySettings.preferences)
            .preferredColorScheme(model.chatDisplaySettings.preferences.preferredColorScheme)
            .sheet(isPresented: $modelsVisible) { ModelLibraryView(model: library).workbenchTheme()
                .environment(\.dLanguageStore, language) }
    }
}
