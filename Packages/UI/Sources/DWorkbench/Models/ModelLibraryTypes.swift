import DInference
import Foundation

/// Stable identity of one installation/registration. Catalog ID + revision identifies model content.
public struct ModelID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID
    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public var description: String { rawValue.uuidString }
}

public struct ImageModelProfile: Codable, Hashable, Sendable {
    public let width: Int
    public let height: Int
    public let steps: Int
    public let guidanceScale: Float
    public let estimatedPeakBytes: UInt64
    public let maximumPromptTokens: Int
    public static let flux2Klein = ImageModelProfile(width: 512, height: 512, steps: 4,
        guidanceScale: 1, estimatedPeakBytes: 8 * 1024 * 1024 * 1024, maximumPromptTokens: 512)

    public func request(prompt: String, seed: UInt64) -> ImageRequest {
        .init(prompt: prompt, width: width, height: height, steps: steps, guidanceScale: guidanceScale, seed: seed)
    }
}

public struct ModelFile: Codable, Hashable, Sendable {
    public let path: String
    public let size: UInt64
    public let sha256: String
    public init(path: String, size: UInt64, sha256: String) {
        self.path = path; self.size = size; self.sha256 = sha256
    }
}

public struct ModelCatalogEntry: Identifiable, Codable, Sendable {
    public let id: String
    public let title: String
    public let repository: String
    public let revision: String
    public let files: [ModelFile]
    public let imageProfile: ImageModelProfile
    public var totalBytes: UInt64 { files.reduce(0) { $0 + $1.size } }
    public var modelSpec: String { "FLUX.2 Klein 4B · 8 位量化" }
    public var memoryGuidance: String { "已在 M4 / 16 GiB 验证；单个推理任务约需 8 GiB 预算。" }
}

public enum ModelCatalog {
    public static let flux2ID = "flux2-klein-4b-q8"
    public static func entries() throws -> [ModelCatalogEntry] { [try flux2()] }
    public static func flux2() throws -> ModelCatalogEntry {
        struct Manifest: Decodable { let schemaVersion: Int; let repository: String; let revision: String; let files: [ModelFile] }
        guard let url = Bundle.module.url(forResource: "flux2-klein-model", withExtension: "json") else {
            throw ModelLibraryError.invalidCatalog("缺少固定模型清单。")
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
        guard manifest.schemaVersion == 1,
              manifest.repository == "mzbac/FLUX.2-klein-4B-q8",
              manifest.revision == "ef52ee019fd1d0e75ae4deb40476ba65989716d7", manifest.files.count == 18 else {
            throw ModelLibraryError.invalidCatalog("模型清单与已验证版本不符。")
        }
        return ModelCatalogEntry(id: flux2ID, title: "FLUX.2 Klein 4B q8", repository: manifest.repository,
            revision: manifest.revision, files: manifest.files, imageProfile: .flux2Klein)
    }
}

public enum ModelInstallationState: String, Codable, Sendable {
    case registered, queued, downloading, pausing, paused, verifying, publishing, installed, failed
}
public enum ModelAvailability: String, Codable, Sendable { case available, unavailable, needsAuthorization }
public enum ModelStorageKind: String, Codable, Sendable { case managed, external }

public struct ModelRecord: Identifiable, Codable, Sendable {
    public let id: ModelID
    public let catalogID: String
    public let revision: String
    public var storage: ModelStorageKind
    public var state: ModelInstallationState
    public var availability: ModelAvailability
    public var downloadedBytes: UInt64
    public let totalBytes: UInt64
    public var error: String?
    public var directory: URL?
    public var activeLeaseCount: Int
}

public struct ModelLibrarySnapshot: Sendable {
    public let revision: UInt64
    public let rootURL: URL?
    public let catalog: [ModelCatalogEntry]
    public let records: [ModelRecord]
}

public struct ModelUsageLease: Sendable {
    public let id: UUID
    public let modelID: ModelID
    public let reference: ModelReference
}

public enum ModelLibraryError: Error, LocalizedError, Sendable {
    case invalidCatalog(String), unavailable(String), busy(String), unsafePath(String)
    case operationPaused
    case integrity(String), download(String), storage(String), insufficientSpace(required: UInt64, available: UInt64)
    public var errorDescription: String? {
        switch self {
        case .invalidCatalog(let reason), .unavailable(let reason), .busy(let reason), .unsafePath(let reason),
             .integrity(let reason), .download(let reason), .storage(let reason): reason
        case .operationPaused: "操作已暂停，可稍后继续。"
        case .insufficientSpace(let required, let available):
            "模型安装空间不足：还需 \(required) 字节，可用 \(available) 字节。请选择空间足够的磁盘。"
        }
    }
}
