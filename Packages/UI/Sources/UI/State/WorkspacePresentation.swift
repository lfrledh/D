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
