import DInference
import SwiftUI

/// The workbench presents saved project values and application actions, never model objects.
public struct WorkbenchView: View {
    @Bindable private var model: WorkbenchModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showInspector = true
    @State private var showTasks = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(model: WorkbenchModel) { self.model = model }

    public var body: some View {
        Group {
            if model.manifest != nil {
                projectWorkbench
            } else {
                WorkbenchWelcome(model: model)
            }
        }
        .frame(minWidth: 860, minHeight: 580)
        .disabled(model.isChangingProject)
        .overlay {
            if model.isChangingProject {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在整理项目…").font(.callout)
                }
                .padding(24)
                .background(.background, in: RoundedRectangle(cornerRadius: 18))
                .shadow(color: .black.opacity(0.10), radius: 20, y: 8)
            }
        }
        .alert("操作未完成", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.clearError() } }
        )) {
            Button("好", role: .cancel) { model.clearError() }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var projectWorkbench: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ArtworkSidebar(model: model)
                .navigationSplitViewColumnWidth(min: 190, ideal: 225, max: 320)
        } detail: {
            VStack(spacing: 0) {
                canvas.frame(maxWidth: .infinity, maxHeight: .infinity)
                if let jobs = model.manifest?.jobs, !jobs.isEmpty {
                    Divider()
                    WorkbenchTasks(model: model, isExpanded: $showTasks)
                }
            }
            .navigationTitle(model.manifest?.name ?? "D")
            .inspector(isPresented: $showInspector) {
                GenerationInspector(model: model)
                    .inspectorColumnWidth(min: 280, ideal: 310, max: 400)
            }
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Menu {
                        Button("新建项目…", systemImage: "doc.badge.plus") {
                            Task { await model.newProject() }
                        }
                        Button("打开项目…", systemImage: "folder") {
                            Task { await model.openProject() }
                        }
                        Divider()
                        Button("检查可恢复作品", systemImage: "arrow.clockwise") {
                            Task { await model.recoverArtifacts() }
                        }
                        .disabled(model.isBusy)
                        Button("关闭项目", systemImage: "xmark") {
                            Task { await model.closeProject() }
                        }
                    } label: {
                        Label("项目", systemImage: "folder")
                    }
                    .accessibilityIdentifier("project-menu")
                    .help("项目操作")
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        guard let job = model.selectedJob else { return }
                        Task { await model.copySettings(from: job.id) }
                    } label: {
                        Label("使用生成条件", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(model.selectedJob == nil)
                    .accessibilityIdentifier("copy-settings")
                    .help("将这张作品的提示词和 seed 复制到新草稿")

                    Button {
                        Task { await model.exportSelected() }
                    } label: {
                        Label("导出作品…", systemImage: "square.and.arrow.up")
                    }
                    .disabled(model.selectedAsset == nil)
                    .accessibilityIdentifier("export-artwork")
                    .help("导出原始 PNG")

                    Button {
                        withAnimation(reduceMotion ? nil : .default) { showInspector.toggle() }
                    } label: {
                        Label("创作参数", systemImage: "sidebar.right")
                    }
                    .accessibilityIdentifier("toggle-inspector")
                    .help("显示或隐藏创作参数")
                }
            }
        }
        .onChange(of: model.manifest?.jobs.count) { oldValue, newValue in
            if (newValue ?? 0) > (oldValue ?? 0) {
                withAnimation(reduceMotion ? nil : .default) { showTasks = true }
            }
        }
    }

    @ViewBuilder private var canvas: some View {
        if let asset = model.selectedAsset, let url = model.assetURLs[asset.id] {
            ArtworkCanvas(url: url, label: "已保存的作品")
        } else if model.selectedAsset != nil {
            ContentUnavailableView("作品暂时无法访问", systemImage: "externaldrive.badge.exclamationmark",
                description: Text("请连接项目所在的磁盘，然后重新打开项目。已保存的作品不会被移除。"))
        } else {
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                ContentUnavailableView {
                    Label("从一个想法开始", systemImage: "photo.on.rectangle.angled")
                } description: {
                    Text("在右侧描述你想创作的画面。\n作品会自动保存在这个项目中。")
                }
            }
        }
    }
}

private struct ArtworkSidebar: View {
    @Bindable var model: WorkbenchModel

    var body: some View {
        List(selection: $model.selectedAssetID) {
            Section {
                if let assets = model.manifest?.assets, !assets.isEmpty {
                    ForEach(assets.reversed(), id: \.id) { asset in
                        HStack(spacing: 10) {
                            ArtworkThumbnail(url: model.assetURLs[asset.id])
                            VStack(alignment: .leading, spacing: 5) {
                                Text(title(for: asset)).font(.callout.weight(.medium)).lineLimit(2)
                                Text(subtitle(for: asset))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .padding(.vertical, 4)
                        .tag(asset.id)
                        .accessibilityIdentifier("artwork-\(asset.id.uuidString)")
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("还没有作品").font(.callout.weight(.medium))
                        Text("完成的图片会出现在这里。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 12)
                    .listRowSeparator(.hidden)
                }
            } header: {
                HStack {
                    Text("作品")
                    Spacer()
                    Text("\(model.manifest?.assets.count ?? 0)").monospacedDigit()
                }
            }
        }
        .listStyle(.sidebar)
        .accessibilityIdentifier("artwork-list")
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 7) {
                Image(systemName: "externaldrive")
                Text("保存在项目中")
                Spacer(minLength: 0)
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 18).padding(.vertical, 12)
            .help(model.projectURL?.path ?? "")
        }
    }

    private func title(for asset: ProjectAsset) -> String {
        guard let job = model.manifest?.jobs.first(where: { $0.id == asset.jobID }),
              case .image(let request) = job.request.input else { return "恢复的作品" }
        return request.prompt
    }

    private func subtitle(for asset: ProjectAsset) -> String {
        guard let job = model.manifest?.jobs.first(where: { $0.id == asset.jobID }) else { return "PNG" }
        return job.createdAt.formatted(date: .abbreviated, time: .shortened)
    }
}

private struct WorkbenchWelcome: View {
    @Bindable var model: WorkbenchModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 14) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 46, weight: .light))
                    .foregroundStyle(.tint)
                    .padding(.bottom, 8)
                    .accessibilityHidden(true)
                Text("你的创作，留在你的 Mac")
                    .font(.largeTitle.weight(.semibold))
                Text("用 D 将想法变成作品。\n从一个项目开始，保存每一张图片和它的生成条件。")
                    .font(.body).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).lineSpacing(5)
            }
            if reduceTransparency {
                actions.buttonStyle(.bordered).controlSize(.large)
            } else {
                GlassEffectContainer(spacing: 20) {
                    actions.buttonStyle(.glass).controlSize(.large)
                }
            }
            Text("本地生成 · 项目自动保存")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("D")
    }

    private var actions: some View {
        HStack(spacing: 16) {
            Button {
                Task { await model.newProject() }
            } label: {
                Label("新建项目…", systemImage: "plus").padding(.horizontal, 9)
            }
            .accessibilityIdentifier("new-project")
            Button {
                Task { await model.openProject() }
            } label: {
                Label("打开项目…", systemImage: "folder").padding(.horizontal, 9)
            }
            .accessibilityIdentifier("open-project")
        }
    }
}
