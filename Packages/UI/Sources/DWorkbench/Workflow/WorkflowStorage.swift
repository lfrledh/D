import Foundation

/// A future or unknown operation never passes through a decode/re-encode save.
public struct WorkflowStoredState: Sendable {
    public let archive: WorkflowArchive?
    public let readOnlyReason: String?
    public let originalBytes: Data?
    public init(archive: WorkflowArchive?, readOnlyReason: String? = nil, originalBytes: Data? = nil) {
        self.archive = archive; self.readOnlyReason = readOnlyReason; self.originalBytes = originalBytes
    }
}

public struct WorkflowPublishedAsset: Sendable {
    public let record: WorkflowAssetRecord
    public let asset: ProjectAsset
    public init(record: WorkflowAssetRecord, asset: ProjectAsset) { self.record = record; self.asset = asset }
}

/// Test injection follows the existing Store durable-boundary pattern, without changing filesystem permissions.
enum WorkflowStoreCheckpoint: Sendable { case assetDurable, snapshotDurable, beforeManifest }
