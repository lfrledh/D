import AppKit
import DWorkbench
import SwiftUI

/// A project entry point backed only by summaries supplied by the application.
@MainActor
public struct ProjectChooserView: View {
    private let recentProjects: [RecentProjectSummary]
    private let isBusy: Bool
    private let onNew: () -> Void
    private let onOpen: () -> Void
    private let onRecent: (String) -> Void
    private let onModels: () -> Void
    private var layoutProbe: ((String, CGRect) -> Void)?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public init(
        recentProjects: [RecentProjectSummary],
        isBusy: Bool,
        onNew: @escaping () -> Void,
        onOpen: @escaping () -> Void,
        onRecent: @escaping (String) -> Void,
        onModels: @escaping () -> Void
    ) {
        self.recentProjects = recentProjects
        self.isBusy = isBusy
        self.onNew = onNew
        self.onOpen = onOpen
        self.onRecent = onRecent
        self.onModels = onModels
    }

    /// Internal rendered-geometry observation for native hosting tests.
    func observingLayout(_ observer: @escaping (String, CGRect) -> Void) -> Self {
        var copy = self
        copy.layoutProbe = observer
        return copy
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 12) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 46, weight: .light))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    Text("选择一个项目")
                        .font(.largeTitle.weight(.semibold))
                    Text("从已有项目继续，或在你的 Mac 上开始新的创作。")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                chooserActions

                VStack(alignment: .leading, spacing: 12) {
                    Text("最近项目")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    if recentProjects.isEmpty {
                        VStack(spacing: 9) {
                            Image(systemName: "clock")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                            Text("还没有最近项目")
                                .font(.headline)
                            Text("打开或新建的项目会显示在这里。")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                        .navigationMeasured("recent-projects-empty", probe: layoutProbe)
                    } else {
                        LazyVStack(spacing: 8) {
                            ForEach(recentProjects) { project in
                                Button {
                                    onRecent(project.id)
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "folder")
                                            .font(.title3)
                                            .foregroundStyle(.tint)
                                            .frame(width: 28)
                                            .accessibilityHidden(true)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(project.name)
                                                .font(.body.weight(.medium))
                                                .lineLimit(2)
                                            if !project.detail.isEmpty {
                                                Text(project.detail)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(2)
                                            }
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        Image(systemName: "chevron.right")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.tertiary)
                                            .accessibilityHidden(true)
                                    }
                                    .padding(12)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
                                .accessibilityIdentifier("recent-project-\(project.id)")
                                .navigationMeasured("recent-project-\(project.id)", probe: layoutProbe)
                            }
                        }
                    }
                }
                .frame(maxWidth: 680, alignment: .leading)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 28)
            .padding(.vertical, 48)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .disabled(isBusy)
        .overlay(alignment: .topTrailing) {
            if isBusy {
                ProgressView("正在整理项目…")
                    .controlSize(.small)
                    .padding(16)
                    .accessibilityIdentifier("project-chooser-progress")
            }
        }
        .coordinateSpace(name: NavigationLayoutSpace.name)
    }

    @ViewBuilder
    private var chooserActions: some View {
        let buttons = HStack(spacing: 14) {
            Button(action: onNew) {
                Label("新建项目…", systemImage: "plus")
                    .padding(.horizontal, 6)
            }
            .accessibilityIdentifier("new-project")
            .navigationMeasured("new-project", probe: layoutProbe)

            Button(action: onOpen) {
                Label("打开项目…", systemImage: "folder")
                    .padding(.horizontal, 6)
            }
            .accessibilityIdentifier("open-project")
            .navigationMeasured("open-project", probe: layoutProbe)

            Button(action: onModels) {
                Label("模型库", systemImage: "cube.transparent")
                    .padding(.horizontal, 6)
            }
            .accessibilityIdentifier("open-model-library")
            .navigationMeasured("open-model-library", probe: layoutProbe)
        }
        .controlSize(.large)

        if reduceTransparency {
            buttons.buttonStyle(.bordered)
        } else {
            GlassEffectContainer(spacing: 18) {
                buttons.buttonStyle(.glass)
            }
        }
    }
}

/// Project-level navigation around modality-specific content supplied by the application.
@MainActor
public struct ProjectWorkspaceShell<Sidebar: View, Editor: View, Inspector: View>: View {
    private let projectName: String
    private let mode: CreatorMode
    private let availableModes: [CreatorMode]
    private let hasInspector: Bool
    private let taskCount: Int
    private let onMode: (CreatorMode) -> Void
    private let onBack: () -> Void
    private let onTasks: () -> Void
    private let onModels: () -> Void
    private let sidebar: Sidebar
    private let editor: Editor
    private let inspector: Inspector
    private var layoutProbe: ((String, CGRect) -> Void)?

    @State private var showsSidebarColumn = true
    @State private var showsInspectorColumn = true
    @State private var showsSidebarPopover = false
    @State private var showsInspectorPopover = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public init(
        projectName: String,
        mode: CreatorMode,
        availableModes: [CreatorMode],
        hasInspector: Bool,
        taskCount: Int,
        onMode: @escaping (CreatorMode) -> Void,
        onBack: @escaping () -> Void,
        onTasks: @escaping () -> Void,
        onModels: @escaping () -> Void,
        @ViewBuilder sidebar: () -> Sidebar,
        @ViewBuilder editor: () -> Editor,
        @ViewBuilder inspector: () -> Inspector
    ) {
        self.projectName = projectName
        self.mode = mode
        self.availableModes = availableModes
        self.hasInspector = hasInspector
        self.taskCount = taskCount
        self.onMode = onMode
        self.onBack = onBack
        self.onTasks = onTasks
        self.onModels = onModels
        self.sidebar = sidebar()
        self.editor = editor()
        self.inspector = inspector()
    }

    /// Internal rendered-geometry observation for native hosting tests.
    func observingLayout(_ observer: @escaping (String, CGRect) -> Void) -> Self {
        var copy = self
        copy.layoutProbe = observer
        return copy
    }

    public var body: some View {
        GeometryReader { viewport in
            let presentation = ShellPresentation(width: viewport.size.width)
            VStack(spacing: 8) {
                projectBar(presentation: presentation)
                modalityBar
                workspace(presentation: presentation)
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .frame(width: viewport.size.width, height: viewport.size.height)
            .onChange(of: presentation.sidebarUsesPopover) { _, usesPopover in
                if !usesPopover { showsSidebarPopover = false }
            }
            .onChange(of: presentation.inspectorUsesPopover) { _, usesPopover in
                if !usesPopover { showsInspectorPopover = false }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .coordinateSpace(name: NavigationLayoutSpace.name)
    }

    private func projectBar(presentation: ShellPresentation) -> some View {
        navigationSurface {
            HStack(spacing: 8) {
                shellButton(
                    title: "返回项目",
                    symbol: "chevron.left",
                    compact: presentation.compactToolbar,
                    action: onBack
                )
                .accessibilityIdentifier("back-to-projects")
                .navigationMeasured("back-to-projects", probe: layoutProbe)

                Text(projectName)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("项目：\(projectName)")
                    .navigationMeasured("project-name", probe: layoutProbe)

                sidebarToggle(presentation: presentation)

                if hasInspector {
                    inspectorToggle(presentation: presentation)
                }

                shellButton(
                    title: taskCount > 0 ? "项目任务 \(taskCount)" : "项目任务",
                    symbol: "list.bullet.rectangle",
                    compact: presentation.compactToolbar,
                    badge: taskCount > 0 ? taskCount : nil,
                    action: onTasks
                )
                .accessibilityIdentifier("open-project-tasks")
                .navigationMeasured("open-project-tasks", probe: layoutProbe)

                shellButton(
                    title: "模型库",
                    symbol: "cube.transparent",
                    compact: presentation.compactToolbar,
                    action: onModels
                )
                .accessibilityIdentifier("open-model-library")
                .navigationMeasured("open-model-library", probe: layoutProbe)
            }
        }
    }

    private var modalityBar: some View {
        navigationSurface {
            HStack(spacing: 6) {
                ForEach(supportedModes) { availableMode in
                    Button {
                        onMode(availableMode)
                    } label: {
                        Label(availableMode.title, systemImage: availableMode.symbol)
                            .fontWeight(availableMode == mode ? .semibold : .regular)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(
                        availableMode == mode ? Color.accentColor.opacity(0.16) : .clear,
                        in: RoundedRectangle(cornerRadius: 9)
                    )
                    .accessibilityIdentifier(modeIdentifier(availableMode))
                    .accessibilityAddTraits(availableMode == mode ? .isSelected : [])
                    .navigationMeasured(modeIdentifier(availableMode), probe: layoutProbe)
                }
            }
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
    }

    private func workspace(presentation: ShellPresentation) -> some View {
        HStack(spacing: 0) {
            if !presentation.sidebarUsesPopover, showsSidebarColumn {
                sidebar
                    .frame(width: 210)
                    .frame(maxHeight: .infinity, alignment: .topLeading)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .navigationMeasured("shell-sidebar", probe: layoutProbe)
                Divider()
            }

            editor
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .underPageBackgroundColor))
                .navigationMeasured("shell-editor", probe: layoutProbe)

            if hasInspector, !presentation.inspectorUsesPopover, showsInspectorColumn {
                Divider()
                inspector
                    .frame(width: 290)
                    .frame(maxHeight: .infinity, alignment: .topLeading)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .navigationMeasured("shell-inspector", probe: layoutProbe)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.45)))
        .navigationMeasured("shell-workspace", probe: layoutProbe)
    }

    private func sidebarToggle(presentation: ShellPresentation) -> some View {
        Button {
            animate {
                if presentation.sidebarUsesPopover {
                    showsSidebarPopover.toggle()
                } else {
                    showsSidebarColumn.toggle()
                }
            }
        } label: {
            Image(systemName: "sidebar.left")
        }
        .accessibilityLabel(presentation.sidebarUsesPopover ? "打开创作列表" : "显示或隐藏创作列表")
        .accessibilityIdentifier("toggle-creations")
        .accessibilityAddTraits((showsSidebarColumn && !presentation.sidebarUsesPopover) || showsSidebarPopover
                                ? .isSelected : [])
        .navigationMeasured("toggle-creations", probe: layoutProbe)
        .popover(isPresented: $showsSidebarPopover, arrowEdge: .top) {
            sidebar
                .frame(width: 260, height: 430, alignment: .topLeading)
                .background(Color(nsColor: .controlBackgroundColor))
        }
    }

    private func inspectorToggle(presentation: ShellPresentation) -> some View {
        Button {
            animate {
                if presentation.inspectorUsesPopover {
                    showsInspectorPopover.toggle()
                } else {
                    showsInspectorColumn.toggle()
                }
            }
        } label: {
            Image(systemName: "sidebar.right")
        }
        .accessibilityLabel(presentation.inspectorUsesPopover ? "打开创作参数" : "显示或隐藏创作参数")
        .accessibilityIdentifier("toggle-inspector")
        .accessibilityAddTraits((showsInspectorColumn && !presentation.inspectorUsesPopover) || showsInspectorPopover
                                ? .isSelected : [])
        .navigationMeasured("toggle-inspector", probe: layoutProbe)
        .popover(isPresented: $showsInspectorPopover, arrowEdge: .top) {
            inspector
                .frame(width: 320, height: 480, alignment: .topLeading)
                .background(Color(nsColor: .controlBackgroundColor))
        }
    }

    private func shellButton(
        title: String,
        symbol: String,
        compact: Bool,
        badge: Int? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            if compact {
                Image(systemName: symbol)
                    .overlay(alignment: .topTrailing) {
                        if let badge {
                            Text("\(badge)")
                                .font(.system(size: 8, weight: .bold))
                                .padding(.horizontal, 3)
                                .padding(.vertical, 1)
                                .foregroundStyle(.white)
                                .background(Color.accentColor, in: Capsule())
                                .fixedSize()
                                .offset(x: 8, y: -7)
                        }
                    }
            } else {
                Label(title, systemImage: symbol)
            }
        }
        .accessibilityLabel(title)
        .help(title)
    }

    @ViewBuilder
    private func navigationSurface<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if reduceTransparency {
            content()
                .padding(7)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator.opacity(0.45)))
        } else {
            GlassEffectContainer(spacing: 10) {
                content()
                    .padding(7)
                    .glassEffect(.regular, in: .rect(cornerRadius: 14))
            }
        }
    }

    private var supportedModes: [CreatorMode] {
        availableModes.reduce(into: []) { result, candidate in
            if !result.contains(candidate) { result.append(candidate) }
        }
    }

    private func modeIdentifier(_ mode: CreatorMode) -> String {
        "creator-mode-\(mode.rawValue)"
    }

    private func animate(_ change: () -> Void) {
        withAnimation(reduceMotion ? nil : .default, change)
    }
}

/// A modality-scoped list. Filtering this value view has no project or session side effects.
@MainActor
public struct ModalityDocumentList: View {
    private let documents: [ProjectDocument]
    private let mode: CreatorMode
    private let selectedDocumentID: UUID?
    private let onSelect: (UUID) -> Void
    private let onCreate: () -> Void
    private var layoutProbe: ((String, CGRect) -> Void)?

    public init(
        documents: [ProjectDocument],
        mode: CreatorMode,
        selectedDocumentID: UUID?,
        onSelect: @escaping (UUID) -> Void,
        onCreate: @escaping () -> Void
    ) {
        self.documents = documents
        self.mode = mode
        self.selectedDocumentID = selectedDocumentID
        self.onSelect = onSelect
        self.onCreate = onCreate
    }

    /// Internal rendered-geometry observation for native hosting tests.
    func observingLayout(_ observer: @escaping (String, CGRect) -> Void) -> Self {
        var copy = self
        copy.layoutProbe = observer
        return copy
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(mode.title)创作")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .accessibilityAddTraits(.isHeader)

            if visibleDocuments.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: mode.symbol)
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("还没有\(mode.title)创作")
                        .font(.callout.weight(.medium))
                    Text("切换模态不会自动创建内容。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .navigationMeasured("modality-documents-empty", probe: layoutProbe)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(visibleDocuments) { document in
                            Button {
                                onSelect(document.id)
                            } label: {
                                Label(document.name, systemImage: documentSymbol(document.kind))
                                    .fontWeight(document.id == selectedDocumentID ? .semibold : .regular)
                                    .lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 9)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .background(
                                document.id == selectedDocumentID ? Color.accentColor.opacity(0.14) : .clear,
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                            .accessibilityIdentifier("document-\(document.id.uuidString)")
                            .accessibilityAddTraits(document.id == selectedDocumentID ? .isSelected : [])
                            .navigationMeasured("document-\(document.id.uuidString)", probe: layoutProbe)
                        }
                    }
                }
            }

            Button(action: onCreate) {
                Label(mode.newDocumentTitle, systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier(newDocumentIdentifier)
            .navigationMeasured(newDocumentIdentifier, probe: layoutProbe)
        }
        .padding(8)
        .coordinateSpace(name: NavigationLayoutSpace.name)
    }

    private var visibleDocuments: [ProjectDocument] {
        documents.filter { CreatorMode($0.kind) == mode }
    }

    private var newDocumentIdentifier: String {
        switch mode {
        case .image: "new-document"
        case .text: "new-text-document"
        case .audio: "new-audio-creation"
        }
    }

    private func documentSymbol(_ kind: ProjectDocumentKind) -> String {
        switch kind {
        case .image: "doc.text.image"
        case .text: "doc.text"
        case .audio: "waveform"
        }
    }
}

private enum NavigationLayoutSpace {
    static let name = "workbench-navigation-layout"
}

private struct ShellPresentation {
    let width: CGFloat
    var inspectorUsesPopover: Bool { width < 1_100 }
    var sidebarUsesPopover: Bool { width < 700 }
    var compactToolbar: Bool { width < 900 }
}

private extension View {
    func navigationMeasured(_ id: String, probe: ((String, CGRect) -> Void)?) -> some View {
        onGeometryChange(for: CGRect.self) { geometry in
            geometry.frame(in: .named(NavigationLayoutSpace.name))
        } action: { rectangle in
            probe?(id, rectangle)
        }
    }
}
