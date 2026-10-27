import AppKit
import Foundation
import DWorkbench
import SwiftUI

public struct RecentProjectSummary: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let detail: String
    public init(id: String, name: String, detail: String) { self.id = id; self.name = name; self.detail = detail }
}
public enum WorkspacePane: String, CaseIterable, Identifiable {
    case creations, assets, nodes
    public var id: Self { self }
    public var title: String {
        switch self { case .creations: "创作"; case .assets: "资产"; case .nodes: "模型节点" }
    }
}

/// The visible UI supplies the exact enabled state, including unapplied parameter edits.
@MainActor public struct WorkbenchGenerationCommand {
    public let title: String
    public let isEnabled: Bool
    public let action: () -> Void
    public init(title: String, isEnabled: Bool, action: @escaping () -> Void) {
        self.title = title; self.isEnabled = isEnabled; self.action = action
    }
}
private struct WorkbenchGenerationKey: FocusedValueKey { typealias Value = WorkbenchGenerationCommand }
public extension FocusedValues {
    var workbenchGeneration: WorkbenchGenerationCommand? {
        get { self[WorkbenchGenerationKey.self] }
        set { self[WorkbenchGenerationKey.self] = newValue }
    }
}

/// Ephemeral destination protection; never a saved chat/graph or execution request.
@MainActor
struct ChatToolsNavigationRequest: Equatable {
    let id = UUID()
    let controller: ObjectIdentifier
    let store: ObjectIdentifier
    let sessionID: UUID?
    init(chat: ChatController) {
        controller = ObjectIdentifier(chat); store = ObjectIdentifier(chat.store)
        sessionID = chat.state.selectedSessionID
    }
    func matches(_ chat: ChatController) -> Bool {
        controller == ObjectIdentifier(chat) && store == ObjectIdentifier(chat.store)
            && sessionID == chat.state.selectedSessionID
    }
}

private struct WorkbenchSaveKey: FocusedValueKey { typealias Value = WorkbenchGenerationCommand }
public extension FocusedValues {
    var workbenchSave: WorkbenchGenerationCommand? {
        get { self[WorkbenchSaveKey.self] }
        set { self[WorkbenchSaveKey.self] = newValue }
    }
}

/// Route the standard close command to its captured native window. Delegates
/// retain ownership of unsaved work, annotation drafts and asynchronous drains.
@MainActor public enum WorkbenchWindowCloseCommand {
    public static func perform(on window: NSWindow?) {
        if let editor = window?.firstResponder as? NSTextView, editor.hasMarkedText() { return }
        if WorkbenchChildPanels.requestClose(on: window) { return }
        guard let window, window.styleMask.contains(.closable),
              window.sheetParent == nil, window.attachedSheet == nil else { return }
        window.performClose(nil)
    }
}

/// The mounted canvas offers its existing actions to the standard menus. Text
/// editors retain the native Edit commands and their own Undo manager.
@MainActor public struct WorkbenchCanvasCommands {
    public let edit: [WorkbenchGenerationCommand]
    public let legend: WorkbenchGenerationCommand
    public var scope: WorkbenchCommandScope? = nil
    public var zoom: [WorkbenchGenerationCommand] = []
    public var sidebars: [WorkbenchGenerationCommand] = []
    public var run: WorkbenchGenerationCommand? = nil
    public var settings: WorkbenchGenerationCommand? = nil
    public var pause: WorkbenchGenerationCommand? = nil
    public var resume: WorkbenchGenerationCommand? = nil
    public var stop: WorkbenchGenerationCommand? = nil
    public var retrySave: WorkbenchGenerationCommand? = nil
    public var workflow: [WorkbenchGenerationCommand] = []
    public var templates: [WorkbenchGenerationCommand] = []
    public var workflowChoices: [WorkbenchChoiceCommand] = []
    public var save: WorkbenchGenerationCommand? = nil
    public var manageNodes: WorkbenchGenerationCommand? = nil
    public init(edit: [WorkbenchGenerationCommand], legend: WorkbenchGenerationCommand) {
        self.edit = edit; self.legend = legend
    }
}
private struct WorkbenchCanvasKey: FocusedValueKey { typealias Value = WorkbenchCanvasCommands }
public extension FocusedValues {
    var workbenchCanvas: WorkbenchCanvasCommands? {
        get { self[WorkbenchCanvasKey.self] }
        set { self[WorkbenchCanvasKey.self] = newValue }
    }
}

/// The native window is captured by each mounted command provider. A retained
/// page or a different key window cannot execute its stale menu closure.
@MainActor @Observable public final class WorkbenchCommandScope {
    public weak var window: NSWindow?
    weak var sourceView: NSView?
    public init() {}
    public var permitsNavigation: Bool { window?.isKeyWindow == true && window?.attachedSheet == nil && NSApp.modalWindow == nil }
    public var permitsVisibleCommands: Bool { sourceView.map { !$0.isHiddenOrHasHiddenAncestor } == true && permitsCommands }
    public var permitsCommands: Bool { window?.isKeyWindow == true && window?.attachedSheet == nil && WorkbenchChildPanels.permitsCommands(from: sourceView, on: window) }
}
struct WorkbenchCommandWindow: NSViewRepresentable {
    let scope: WorkbenchCommandScope
    func makeNSView(context: Context) -> View { View(scope: scope) }
    func updateNSView(_ view: View, context: Context) { view.scope = scope; scope.window = view.window; scope.sourceView = view }
    static func dismantleNSView(_ view: View, coordinator: ()) { if view.scope.window === view.window { view.scope.window = nil } }
    final class View: NSView {
        var scope: WorkbenchCommandScope
        init(scope: WorkbenchCommandScope) { self.scope = scope; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:)") }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); scope.window = window; scope.sourceView = self }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

@MainActor public struct WorkbenchChoiceCommand {
    public let command: WorkbenchGenerationCommand
    public let selected: Bool
    public init(_ command: WorkbenchGenerationCommand, selected: Bool) { self.command = command; self.selected = selected }
}
@MainActor public struct WorkbenchWorkspaceCommands {
    public let workflow: Bool
    public let chat: Bool
    public let scope: WorkbenchCommandScope
    public let newProject: WorkbenchGenerationCommand
    public let openProject: WorkbenchGenerationCommand
    public let recent: [WorkbenchGenerationCommand]
    public let files: WorkbenchGenerationCommand
    public let quickDestination: [WorkbenchChoiceCommand]
    public let importAsset: WorkbenchGenerationCommand
    public let legacy: WorkbenchGenerationCommand
    public let modes: [WorkbenchChoiceCommand]
    public let sidebars: [WorkbenchGenerationCommand]
    public let help: WorkbenchGenerationCommand
    public let thirdPartyNotices: WorkbenchGenerationCommand
    public let stop: WorkbenchGenerationCommand?
    public let retrySave: WorkbenchGenerationCommand?
}
private struct WorkbenchWorkspaceKey: FocusedValueKey { typealias Value = WorkbenchWorkspaceCommands }
private struct WorkbenchAssetExportKey: FocusedValueKey { typealias Value = WorkbenchGenerationCommand }
public extension FocusedValues {
    var workbenchWorkspace: WorkbenchWorkspaceCommands? {
        get { self[WorkbenchWorkspaceKey.self] }
        set { self[WorkbenchWorkspaceKey.self] = newValue }
    }
    var workbenchAssetExport: WorkbenchGenerationCommand? {
        get { self[WorkbenchAssetExportKey.self] }
        set { self[WorkbenchAssetExportKey.self] = newValue }
    }
}
@MainActor func systemMenuText(_ language: UILanguageStore?, _ key: String) -> String {
    workflowText(language, "systemMenu." + key)
}

@MainActor public struct WorkbenchChatCommands {
    public let run: WorkbenchGenerationCommand
    public let stop: WorkbenchGenerationCommand
    public let retrySave: WorkbenchGenerationCommand?
}
private struct WorkbenchChatKey: FocusedValueKey { typealias Value = WorkbenchChatCommands }
public extension FocusedValues {
    var workbenchChat: WorkbenchChatCommands? {
        get { self[WorkbenchChatKey.self] }
        set { self[WorkbenchChatKey.self] = newValue }
    }
}

extension EnvironmentValues {
    @Entry var workbenchSaveAction: WorkbenchGenerationCommand? = nil
}
