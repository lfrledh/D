import DInference
import DWorkbench
import SwiftUI

/// The workbench presents saved project values and application actions, never model objects.
public struct WorkbenchView: View {
    @Bindable private var model: WorkbenchModel
    private let library: ModelLibraryModel?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showInspector = true
    @State private var showTasks = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(model: WorkbenchModel, library: ModelLibraryModel? = nil) {
        self.model = model
        self.library = library
    }

    public var body: some View {
        Group {
            if model.manifest != nil {
                projectWorkbench
            } else {
                WorkbenchWelcome(model: model, library: library)
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
        .sheet(isPresented: Binding(
            get: { library?.isPresented ?? false },
            set: { library?.isPresented = $0 }
        )) {
            if let library {
                ModelLibraryView(model: library, selectedModelID: model.selectedModelID,
                    canSelect: model.manifest != nil && !model.isChangingProject) { id in
                    await model.selectModel(id: id)
                    if model.selectedModelID == id {
                        library.isPresented = false
                    } else if let message = model.errorMessage {
                        library.errorMessage = message
                        model.clearError()
                    }
                }
            }
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
                GenerationInspector(model: model, library: library)
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
                    if let library {
                        Button {
                            library.isPresented = true
                        } label: {
                            Label("模型库", systemImage: "cube.transparent")
                        }
                        .accessibilityIdentifier("open-model-library")
                        .help(library.hasActiveWork ? "模型库有 \(library.activityCount) 项安装操作进行中" : "管理、安装和选择模型")
                    }
                    Button {
                        guard let job = model.selectedJob else { return }
                        Task { await model.copySettings(from: job.id) }
                    } label: {
                        Label("基于条件新建创作", systemImage: "arrow.branch")
                    }
                    .disabled(model.selectedJob == nil)
                    .accessibilityIdentifier("copy-settings")
                    .help("将实际提示词与 seed 复制到独立创作；不使用图片作为输入")

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
        .onChange(of: model.projectURL) { _, _ in model.invalidateComparison() }
        .onChange(of: model.manifest?.jobs.count) { oldValue, newValue in
            if (newValue ?? 0) > (oldValue ?? 0) {
                withAnimation(reduceMotion ? nil : .default) { showTasks = true }
            }
        }
    }

    @ViewBuilder private var canvas: some View {
        if model.isComparing {
            ArtworkComparison(model: model)
        } else if let asset = model.selectedAsset, let url = model.assetURLs[asset.id] {
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
    @State private var namingContext: DocumentNameContext?

    var body: some View {
        // A sidebar List combines custom multi-action rows into one accessibility
        // element on macOS. Keep navigation and secondary actions as real buttons.
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                sidebarHeading("项目")
                Button {
                    Task { await model.showAllArtworks() }
                } label: {
                    Label("全部作品", systemImage: "square.grid.2x2")
                        .fontWeight(model.showingAllArtworks ? .semibold : .regular)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                        .contentShape(Rectangle())
                }
                .background(model.showingAllArtworks ? Color.accentColor.opacity(0.12) : .clear,
                            in: RoundedRectangle(cornerRadius: 7))
                .accessibilityIdentifier("all-artworks")
                .accessibilityAddTraits(model.showingAllArtworks ? .isSelected : [])
                sidebarHeading("创作")
                ForEach(model.documents, id: \.id) { document in
                    HStack(spacing: 4) {
                        Button {
                            Task { await model.switchDocument(to: document.id) }
                        } label: {
                            Label(document.name, systemImage: "doc.text.image")
                                .lineLimit(2)
                                .fontWeight(!model.showingAllArtworks && model.activeDocumentID == document.id ? .semibold : .regular)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                                .contentShape(Rectangle())
                        }
                        .accessibilityIdentifier("document-\(document.id.uuidString)")
                        .accessibilityAddTraits(!model.showingAllArtworks && model.activeDocumentID == document.id ? .isSelected : [])
                        Button {
                            model.beginEditing()
                            namingContext = DocumentNameContext(documentID: document.id, name: document.name)
                        } label: { Image(systemName: "pencil").frame(width: 24, height: 28) }
                        .help("重命名创作")
                        .accessibilityLabel("重命名 \(document.name)")
                        .accessibilityIdentifier("rename-document-\(document.id.uuidString)")
                    }
                    .padding(.horizontal, 8)
                    .background(!model.showingAllArtworks && model.activeDocumentID == document.id
                                ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
                    .accessibilityElement(children: .contain)
                }
                Button {
                    model.beginEditing()
                    namingContext = DocumentNameContext(documentID: nil, name: "新创作")
                } label: {
                    Label("新建创作", systemImage: "plus")
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                        .contentShape(Rectangle())
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .accessibilityIdentifier("new-document")
                HStack {
                    sidebarHeading(model.showingAllArtworks ? "全部作品" : "候选作品")
                    Spacer()
                    Text("\(model.visibleAssets.count)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                ForEach(model.visibleAssets.reversed(), id: \.id) { asset in candidateRow(asset) }
                if model.visibleAssets.isEmpty {
                    Text("完成的图片会出现在这里。")
                        .font(.caption).foregroundStyle(.secondary).padding(8)
                }
            }.padding(10)
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier("artwork-list")
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    model.beginComparison()
                } label: {
                    Label("比较已选 \(model.comparisonSelection.count)/2", systemImage: "rectangle.split.2x1")
                }
                .buttonStyle(.bordered)
                .disabled(model.comparisonSelection.count != 2)
                .accessibilityIdentifier("compare-artworks")
                Label("保存在项目中", systemImage: "externaldrive")
                    .font(.caption).foregroundStyle(.secondary)
                    .help(model.projectURL?.path ?? "")
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(item: $namingContext, onDismiss: { model.endEditing() }) { context in
            DocumentNameEditor(model: model, context: context)
        }
    }

    private func sidebarHeading(_ name: String) -> some View {
        Text(name).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.top, 10)
            .accessibilityAddTraits(.isHeader)
    }

    private func candidateRow(_ asset: ProjectAsset) -> some View {
        HStack(spacing: 8) {
            Button {
                Task { await model.selectAsset(asset.id) }
            } label: {
                HStack(spacing: 8) {
                    ArtworkThumbnail(url: model.assetURLs[asset.id])
                    VStack(alignment: .leading, spacing: 4) {
                        Text(asset.name).font(.callout.weight(model.selectedAssetID == asset.id ? .semibold : .regular))
                            .lineLimit(2)
                        HStack(spacing: 4) {
                            if asset.isFavorite { Image(systemName: "star.fill").accessibilityLabel("已收藏") }
                            if model.documents.contains(where: { $0.adoptedAssetID == asset.id }) {
                                Label("已采用", systemImage: "checkmark.seal.fill")
                            }
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }
            .disabled(model.isComparing)
            .accessibilityLabel(asset.name)
            .accessibilityIdentifier("artwork-\(asset.id.uuidString)")
            .accessibilityAddTraits(model.selectedAssetID == asset.id ? .isSelected : [])
            Button {
                model.toggleComparisonCandidate(asset.id)
            } label: {
                Image(systemName: model.comparisonSelection.contains(asset.id) ? "checkmark.circle.fill" : "circle")
            }
            .disabled(!model.comparisonSelection.contains(asset.id) && model.comparisonSelection.count == 2)
            .help("选择两张作品进行比较")
            .accessibilityLabel("比较 \(asset.name)")
            .accessibilityValue(model.comparisonSelection.contains(asset.id) ? "已选择" : "未选择")
            .accessibilityIdentifier("compare-select-\(asset.id.uuidString)")
        }
        .padding(8)
        .background(model.selectedAssetID == asset.id ? Color.accentColor.opacity(0.10) : .clear,
                    in: RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .contain)
    }
}

/// One immutable presentation value prevents the sheet from capturing mismatched
/// mode/name state when it is first presented.
private struct DocumentNameContext: Identifiable {
    let id = UUID()
    let documentID: UUID?
    let name: String
    var title: String { documentID == nil ? "新建创作" : "重命名创作" }
}

private struct DocumentNameEditor: View {
    @Bindable var model: WorkbenchModel
    let context: DocumentNameContext
    @State private var name: String
    @State private var saving = false
    @State private var saveError: String?
    @Environment(\.dismiss) private var dismiss

    init(model: WorkbenchModel, context: DocumentNameContext) {
        self.model = model
        self.context = context
        _name = State(initialValue: context.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(context.title).font(.headline)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(context.title)
                .accessibilityIdentifier("document-name-title")
            TextField("创作名称", text: $name)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("document-name")
            if let saveError { Text(saveError).font(.caption).foregroundStyle(.red) }
            if model.editorCloseAttempted {
                Text("请先保存或取消编辑，再关闭项目或退出 D。")
                    .font(.caption).accessibilityIdentifier("pending-editor-close")
            }
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    let previousCount = model.documents.count
                    saving = true
                    Task {
                        if let id = context.documentID { await model.renameDocument(id: id, name: value) }
                        else { await model.createDocument(name: value) }
                        saving = false
                        let saved = context.documentID.map { identifier in
                            model.documents.contains { $0.id == identifier && $0.name == value }
                        } ?? (model.documents.count > previousCount && model.activeDocument?.name == value)
                        if saved { dismiss() }
                        else {
                            saveError = model.errorMessage ?? "未能保存，名称仍然保留。"
                            model.clearError()
                        }
                    }
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("save-document-name")
            }
        }.padding(24).frame(width: 320)
            .disabled(saving).interactiveDismissDisabled()
    }
}

private struct WorkbenchWelcome: View {
    @Bindable var model: WorkbenchModel
    let library: ModelLibraryModel?
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
            if let library {
                Button {
                    library.isPresented = true
                } label: {
                    Label("模型库", systemImage: "cube.transparent").padding(.horizontal, 9)
                }
                .accessibilityIdentifier("open-model-library")
                .help("安装或登记模型，无需先打开项目")
            }
        }
    }
}
