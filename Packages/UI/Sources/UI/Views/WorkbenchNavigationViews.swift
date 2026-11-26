import AppKit
import DWorkbench
import SwiftUI

/// A project entry point backed only by summaries supplied by the application.
@MainActor
public struct ProjectChooserView: View {
    @Environment(\.dLanguageStore) private var legacyLanguage

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
                    Text(workflowText(legacyLanguage, "consistency.legacy.WorkbenchNavigationViews.222"))
                        .font(.largeTitle.weight(.semibold))
                    Text(workflowText(legacyLanguage, "consistency.legacy.WorkbenchNavigationViews.223"))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                chooserActions

                VStack(alignment: .leading, spacing: 12) {
                    Text(workflowText(legacyLanguage, "consistency.legacy.WorkbenchNavigationViews.224"))
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    if recentProjects.isEmpty {
                        VStack(spacing: 9) {
                            Image(systemName: "clock")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                            Text(workflowText(legacyLanguage, "consistency.legacy.WorkbenchNavigationViews.225"))
                                .font(.headline)
                            Text(workflowText(legacyLanguage, "consistency.legacy.WorkbenchNavigationViews.226"))
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
                ProgressView(workflowText(legacyLanguage, "consistency.legacy.WorkbenchNavigationViews.1"))
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
                Label(workflowText(legacyLanguage, "consistency.legacy.WorkbenchNavigationViews.227"), systemImage: "plus")
                    .padding(.horizontal, 6)
            }
            .accessibilityIdentifier("new-project")
            .navigationMeasured("new-project", probe: layoutProbe)

            Button(action: onOpen) {
                Label(workflowText(legacyLanguage, "consistency.legacy.WorkbenchNavigationViews.228"), systemImage: "folder")
                    .padding(.horizontal, 6)
            }
            .accessibilityIdentifier("open-project")
            .navigationMeasured("open-project", probe: layoutProbe)

            Button(action: onModels) {
                Label(workflowText(legacyLanguage, "consistency.legacy.WorkbenchNavigationViews.229"), systemImage: "cube.transparent")
                    .padding(.horizontal, 6)
            }
            .accessibilityIdentifier("open-model-library")
            .navigationMeasured("open-model-library", probe: layoutProbe)
        }
        .controlSize(.large)

        if reduceTransparency {
            buttons.buttonStyle(WorkbenchGlassButtonStyle())
        } else {
            GlassEffectContainer(spacing: 18) {
                buttons.buttonStyle(WorkbenchGlassButtonStyle())
            }
        }
    }
}

/// A modality-scoped list. Filtering this value view has no project or session side effects.
@MainActor
public struct ModalityDocumentList: View {
    @Environment(\.dLanguageStore) private var legacyLanguage

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
        VStack(alignment: .leading, spacing: 12) {
            Text(consistencyText(legacyLanguage, "copy.WorkbenchNavigationViews.1", arguments: ["v0": String(describing: consistencyText(legacyLanguage, "mode." + mode.rawValue))]))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .accessibilityAddTraits(.isHeader)

            if visibleDocuments.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: mode.symbol)
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text(consistencyText(legacyLanguage, "copy.WorkbenchNavigationViews.2", arguments: ["v0": String(describing: consistencyText(legacyLanguage, "mode." + mode.rawValue))]))
                        .font(.callout.weight(.medium))
                    Text(workflowText(legacyLanguage, "consistency.legacy.WorkbenchNavigationViews.235"))
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
                Label(consistencyText(legacyLanguage, "newCreation." + mode.rawValue), systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(WorkbenchGlassButtonStyle(compact: true))
            .accessibilityIdentifier(newDocumentIdentifier)
            .navigationMeasured(newDocumentIdentifier, probe: layoutProbe)
        }
        .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 16)
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
        case .video: "new-video-creation"
        }
    }

    private func documentSymbol(_ kind: ProjectDocumentKind) -> String {
        switch kind {
        case .image: "doc.text.image"
        case .text: "doc.text"
        case .audio: "waveform"
        case .video: "film"
        }
    }
}

private enum NavigationLayoutSpace {
    static let name = "workbench-navigation-layout"
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
