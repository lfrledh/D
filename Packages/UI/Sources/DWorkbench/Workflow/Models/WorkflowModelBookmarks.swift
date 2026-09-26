import Foundation

/// Private application preferences, never graph data or exported provenance.
/// ModelLibrary remains the image installation owner; this retains existing
/// user-granted text/legacy image bookmarks without making another installer.
@MainActor struct WorkflowModelBookmarks {
    struct Entry: Codable, Equatable {
        let identity: String
        let kind: WorkflowModelKind
        let name: String
        let bookmark: Data
    }
    private struct Archive: Codable { var version = 1; var entries: [Entry] = [] }
    let settings: UserDefaults
    static let key = "workbench.workflowModelBookmarks.v1"
    func entries() throws -> [Entry] {
        guard let object = settings.object(forKey: Self.key) else { return [] }
        guard let data = object as? Data, data.count <= 4 * 1024 * 1024,
              let value = try? JSONDecoder().decode(Archive.self, from: data), value.version == 1,
              value.entries.count <= 128, Set(value.entries.map(\.identity)).count == value.entries.count,
              value.entries.allSatisfy({ !$0.identity.isEmpty && !$0.bookmark.isEmpty }) else {
            throw WorkflowIssue("流程模型授权记录损坏，原值已保留；请恢复偏好备份，不会覆盖或改用其他模型。")
        }
        return value.entries
    }
    private static let installationKey = "workbench.workflowImageInstallations.v1"
    private func installations() throws -> [String: String] {
        guard let object = settings.object(forKey: Self.installationKey) else { return [:] }
        guard let table = object as? [String: String], table.count <= 128,
              table.allSatisfy({ !$0.key.isEmpty && UUID(uuidString: $0.value) != nil }) else {
            throw WorkflowIssue("图像安装绑定损坏，原记录已保留。")
        }
        return table
    }
    func installation(for identity: String) throws -> ModelID? {
        try installations()[identity].flatMap { UUID(uuidString: $0) }.map { ModelID(rawValue: $0) }
    }
    func rememberInstallation(identity: String, id: ModelID) throws {
        var table = try installations(); table[identity] = id.description
        guard table.count <= 128 else { throw WorkflowIssue("已登记模型过多。") }
        settings.set(table, forKey: Self.installationKey)
    }
    func remember(identity: String, kind: WorkflowModelKind, name: String, bookmark: Data) throws {
        guard !identity.isEmpty, !bookmark.isEmpty else { throw WorkflowIssue("模型授权身份或书签为空。") }
        var values = try entries()
        values.removeAll { $0.identity == identity }
        values.append(.init(identity: identity, kind: kind, name: name, bookmark: bookmark))
        guard values.count <= 128 else { throw WorkflowIssue("已登记模型过多，请保留现有记录。") }
        let encoded = try JSONEncoder().encode(Archive(entries: values))
        guard encoded.count <= 4 * 1024 * 1024 else { throw WorkflowIssue("模型授权记录超过限制。") }
        settings.set(encoded, forKey: Self.key)
    }
}

/// Captured before an asynchronous chooser. Selection changes do not redirect it.
public struct WorkflowModelSelectionTarget: Sendable, Equatable {
    public let graphID: UUID
    public let nodeID: UUID
    public let operationID: String
    public let kind: WorkflowModelKind
    public let previousIdentity: String
}
