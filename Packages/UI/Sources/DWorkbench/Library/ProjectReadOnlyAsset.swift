import Foundation

/// A verified read token, not a registration or permission to bind a workflow input.
public struct ProjectReadOnlyAsset: Codable, Sendable, Equatable {
    public let projectID: UUID
    public let instanceID: UUID
    public let assetID: UUID
    public let sha256: String
    public let kind: WorkflowDataKind
    public let mediaType: String
    public let relativePath: String
    public let registeredReference: WorkflowAssetReference?
    init(snapshot: ProjectAssetMetadataSnapshot, sha256: String, kind: WorkflowDataKind) {
        projectID = snapshot.projectID; instanceID = snapshot.instanceID; assetID = snapshot.asset.id
        self.sha256 = sha256; self.kind = kind; mediaType = snapshot.asset.mediaType
        relativePath = snapshot.asset.relativePath; registeredReference = snapshot.record?.reference
    }
}

public struct ProjectReadOnlyContent: Sendable {
    public let token: ProjectReadOnlyAsset
    public let metadata: ProjectAssetMetadataSnapshot
    public let data: Data
    public var text: String? {
        guard token.kind == .text else { return nil }
        if token.mediaType == WorkflowTextResponseFile.mediaType {
            return (try? WorkflowTextResponseFile.decodeContent(data))?.rawText
        }
        return String(data: data, encoding: .utf8)
    }
}
