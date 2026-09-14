import DInference
import Foundation

/// Approximate analysis of human source media, never a replacement sound asset.
public struct PitchAssetMetadata: Codable, Sendable, Equatable {
    public let contentSHA256: String
    public let source: PitchSourceIdentity
    public let interpretationVersion: String
    public init(contentSHA256: String, source: PitchSourceIdentity,
                interpretationVersion: String = "equal-tempered-contiguous-5-v1") {
        self.contentSHA256 = contentSHA256; self.source = source
        self.interpretationVersion = interpretationVersion
    }
}
public struct PitchDocumentState: Codable, Sendable, Equatable {
    public var selectedAssetID: UUID?
    public var acceptedAssetIDs: [UUID]
    public var rejectedAssetIDs: [UUID]
    public var expiredAssetIDs: [UUID] = []
    public init(selectedAssetID: UUID? = nil, acceptedAssetIDs: [UUID] = [], rejectedAssetIDs: [UUID] = []) {
        self.selectedAssetID = selectedAssetID; self.acceptedAssetIDs = acceptedAssetIDs
        self.rejectedAssetIDs = rejectedAssetIDs
    }
}
