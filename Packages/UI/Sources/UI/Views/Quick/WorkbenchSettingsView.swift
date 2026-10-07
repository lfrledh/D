import AppKit
import DWorkbench
import SwiftUI

/// App preferences reuse the same owner as Quick/project/temporary chat. No request is submitted here.
public struct WorkbenchSettingsView: View {
    private enum Section: String, CaseIterable { case appearance = "外观", files = "文件与路径", network = "网络", credentials = "API 凭证", language = "语言", assistance = "操作与辅助" }
    let model: WorkbenchModel
    let library: ModelLibraryModel
    let language: UILanguageStore
    let onProjectFiles: (() -> Void)?
    let onSearchSettings: (() -> Void)?
    @State private var selected: Section = .appearance
    @State private var modelsVisible = false
    @Environment(\.dismiss) private var dismiss
    public init(model: WorkbenchModel, library: ModelLibraryModel, language: UILanguageStore,
                onProjectFiles: (() -> Void)? = nil, onSearchSettings: (() -> Void)? = nil) {
        self.model = model; self.library = library; self.language = language
        self.onProjectFiles = onProjectFiles; self.onSearchSettings = onSearchSettings
    }
    public var body: some View {
        VStack(spacing: 0) {
            HStack { Text("设置").font(.title2.bold()); Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.cancelAction) }.padding(20)
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Section.allCases, id: \.self) { section in
                        Button { selected = section } label: {
                            Text(section.rawValue).frame(maxWidth: .infinity, alignment: .leading).padding(10)
                                .background(selected == section ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain).accessibilityIdentifier("settings-" + String(describing: section))
                    }
                    Spacer()
                    Text("模型参数属于下一次请求；这里管理应用偏好。").font(.caption).foregroundStyle(.secondary)
                }.padding(16).frame(width: 180)
                Divider()
                Group {
                    switch selected {
                    case .appearance: ChatDisplayPreferencesPanel(state: model.chatDisplaySettings)
                    case .language: LanguageSettingsView(store: language)
                    case .files:
                        Form {
                            LabeledContent("模型库", value: library.rootURL?.path ?? "尚未指定")
                            Button("选择模型库位置…") { Task { await library.chooseRoot() } }.disabled(!library.canChooseRoot)
                            if let store = model.projectSession.currentStore { LabeledContent("当前项目", value: store.rootURL.path) }
                            if let onProjectFiles { Button("项目文件、位置与备份…", action: onProjectFiles) }
                            Text("缓存与临时产物由现有运行时管理。更改模型位置仍遵守正在使用的资源保护。").font(.caption).foregroundStyle(.secondary)
                            if let error = library.errorMessage { Text(error).foregroundStyle(.red) }
                        }.formStyle(.grouped)
                    case .network:
                        Form {
                            Text("模型下载由已有下载器管理；不会因打开设置而联网或加载模型。")
                            Button("下载与安装管理…") { modelsVisible = true }
                            Text("代理与网络连接沿用系统配置；D 没有独立的代理开关。").font(.caption).foregroundStyle(.secondary)
                        }.formStyle(.grouped)
                    case .credentials:
                        Form {
                            Text("Hugging Face 下载凭据").font(.headline)
                            Text(library.downloadCredentialConnected ? "已连接本地令牌文件" : "未连接；公开文件仍可下载")
                            Button("选择凭据文件…") { Task { await library.chooseDownloadCredential() } }.disabled(!library.canChangeDownloadCredential)
                            if library.downloadCredentialConnected { Button("移除连接") { Task { await library.removeDownloadCredential() } }.disabled(!library.canChangeDownloadCredential) }
                            Divider()
                            Text("Brave / 博查").font(.headline)
                            Text("沿用聊天中的本地凭据管理。真实服务验证仍延期；打开此页不会发出请求。")
                            if let onSearchSettings { Button("打开聊天的搜索与工具", action: onSearchSettings) }
                            else { Text("快速生成 → 文字 → 检查器 → 数据 → 搜索与工具").font(.caption) }
                        }.formStyle(.grouped)
                    case .assistance:
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                Text("操作与辅助").font(.headline)
                                Text("输入框内保留系统组字、选区及撤销。发送快捷键、正文大小和代码换行在外观中调整。")
                                Text("画布：指针选择和连接；手形平移；滚轮缩放；中键回到中心。右下适配视图只移动视野，不重排节点。")
                                Button("打开模型与组件说明") { modelsVisible = true }
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
