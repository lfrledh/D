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
