import Foundation
import CryptoKit

/// Frozen catalog facts for an exact variant, not a grant of rights or an access credential.
/// Localized summaries are presentation keys; decisions never compare translated text.
public struct ModelAcquisitionDisclosure: Codable, Sendable, Equatable {
    public enum CommercialUse: String, Codable, Sendable { case permittedWithConditions, separateCommercialLicense, nonCommercial, unverified }
    public enum LicenseFee: String, Codable, Sendable { case royaltyFreeWithinTerms, additionalLicenseMayRequireFee, notStated }
    public enum Access: String, Codable, Sendable { case publicRepository, readToken, sourceWebsiteApproval, unverified }
    public struct Source: Codable, Sendable, Equatable {
        public let url: URL
        public let revision: String?
        public let sha256: String?
        public let evidence: String
    }
    public struct Component: Codable, Sendable, Equatable, Identifiable {
        public let id: String
        public let scopes: [String]
        public let license: String?
        public let summaryKey: String
        public let sources: [Source]
    }
    public let version: Int
    public let checkedAt: String
    public let commercialUse: CommercialUse
    public let licenseFee: LicenseFee
    public let access: Access
    public let summaryKey: String
    public let components: [Component]

    public static let unknown = Self(version: 1, checkedAt: "", commercialUse: .unverified,
        licenseFee: .notStated, access: .unverified, summaryKey: "modelAcquisition.summary.unknown", components: [])
}

/// Stored with the existing task. Retry/resume preserves exactly what was shown;
/// catalog updates do not rewrite this evidence or the execution recipe identity.
public struct ModelAcquisitionSnapshot: Codable, Sendable, Equatable {
    public let catalogID: String
    public let revision: String
    public let recipeIdentity: String
    public let disclosureSHA256: String
    public let disclosure: ModelAcquisitionDisclosure
    public init(entry: ModelCatalogEntry, recipeIdentity: String) throws {
        self.catalogID = entry.id; self.revision = entry.revision; self.recipeIdentity = recipeIdentity
        disclosure = entry.acquisitionDisclosure ?? .unknown
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        disclosureSHA256 = SHA256.hash(data: try encoder.encode(disclosure)).map { String(format: "%02x", $0) }.joined()
    }
}
