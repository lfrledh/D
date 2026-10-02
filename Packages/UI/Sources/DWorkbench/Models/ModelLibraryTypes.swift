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
    /// Legacy Codable key; interpreted using digestAlgorithm for newer catalog files.
    public let sha256: String
    public var digest: String { sha256 }
    public let digestAlgorithm: ModelDigestAlgorithm
    public let sourceRepository: String?
    public let sourceRevision: String?
    public let remotePath: String?
    public init(path: String, size: UInt64, sha256: String,
                digestAlgorithm: ModelDigestAlgorithm = .sha256, sourceRepository: String? = nil,
                sourceRevision: String? = nil, remotePath: String? = nil) {
        self.path = path; self.size = size; self.sha256 = sha256
        self.digestAlgorithm = digestAlgorithm; self.sourceRepository = sourceRepository
        self.sourceRevision = sourceRevision; self.remotePath = remotePath
    }
    private enum CodingKeys: String, CodingKey { case path, size, sha256, digestAlgorithm, sourceRepository, sourceRevision, remotePath }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(path: try values.decode(String.self, forKey: .path),
                  size: try values.decode(UInt64.self, forKey: .size),
                  sha256: try values.decode(String.self, forKey: .sha256),
                  digestAlgorithm: try values.decodeIfPresent(ModelDigestAlgorithm.self, forKey: .digestAlgorithm) ?? .sha256,
                  sourceRepository: try values.decodeIfPresent(String.self, forKey: .sourceRepository),
                  sourceRevision: try values.decodeIfPresent(String.self, forKey: .sourceRevision),
                  remotePath: try values.decodeIfPresent(String.self, forKey: .remotePath))
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(path, forKey: .path); try values.encode(size, forKey: .size)
        try values.encode(sha256, forKey: .sha256)
        if digestAlgorithm != .sha256 { try values.encode(digestAlgorithm, forKey: .digestAlgorithm) }
        try values.encodeIfPresent(sourceRepository, forKey: .sourceRepository)
        try values.encodeIfPresent(sourceRevision, forKey: .sourceRevision)
        try values.encodeIfPresent(remotePath, forKey: .remotePath)
    }
}

public enum ModelDigestAlgorithm: String, Codable, Hashable, Sendable { case sha256, gitBlobSHA1 }
public enum ModelPreparation: String, Codable, Hashable, Sendable { case none, required }

public struct ModelCatalogEntry: Identifiable, Codable, Sendable {
    public let id: String
    public let title: String
    public let repository: String
    public let revision: String
    public let files: [ModelFile]
    public let imageProfile: ImageModelProfile?
    /// Workflow operationID, despite the legacy property name.
    public let workflowProfileID: String?
    /// Adapter model choice (for example text:<revision>), distinct from operationID.
    public let workflowIdentity: String?
    public let preparation: ModelPreparation
    public let modelSpec: String
    public let memoryGuidance: String
    public let provenance: String?
    public var totalBytes: UInt64 { files.reduce(0) { $0 + $1.size } }
    public init(id: String, title: String, repository: String, revision: String, files: [ModelFile],
                imageProfile: ImageModelProfile? = nil, workflowProfileID: String? = nil,
                workflowIdentity: String? = nil, preparation: ModelPreparation = .none,
                modelSpec: String = "固定版本模型文件", memoryGuidance: String = "运行所需内存取决于所选设备与任务；安装后仍需验证执行引擎。",
                provenance: String? = nil) {
        self.id = id; self.title = title; self.repository = repository; self.revision = revision
        self.files = files; self.imageProfile = imageProfile; self.workflowProfileID = workflowProfileID
        self.workflowIdentity = workflowIdentity; self.preparation = preparation
        self.modelSpec = modelSpec; self.memoryGuidance = memoryGuidance; self.provenance = provenance
    }
    private enum CodingKeys: String, CodingKey {
        case id, title, repository, revision, files, imageProfile, workflowProfileID, workflowIdentity
        case preparation, modelSpec, memoryGuidance, provenance
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try values.decode(String.self, forKey: .id), title: try values.decode(String.self, forKey: .title),
                  repository: try values.decode(String.self, forKey: .repository), revision: try values.decode(String.self, forKey: .revision),
                  files: try values.decode([ModelFile].self, forKey: .files),
                  imageProfile: try values.decodeIfPresent(ImageModelProfile.self, forKey: .imageProfile),
                  workflowProfileID: try values.decodeIfPresent(String.self, forKey: .workflowProfileID),
                  workflowIdentity: try values.decodeIfPresent(String.self, forKey: .workflowIdentity),
                  preparation: try values.decodeIfPresent(ModelPreparation.self, forKey: .preparation) ?? .none,
                  modelSpec: try values.decodeIfPresent(String.self, forKey: .modelSpec) ?? "固定版本模型文件",
                  memoryGuidance: try values.decodeIfPresent(String.self, forKey: .memoryGuidance) ?? "运行所需内存取决于设备与任务。",
                  provenance: try values.decodeIfPresent(String.self, forKey: .provenance))
    }
}

/// Selection admits verified files for an existing workflow route. Runtime
/// availability remains a separate concern checked when execution begins.
public enum ModelLibrarySelection {
    public static func canUse(_ record: ModelRecord, entry: ModelCatalogEntry?, hasPendingAction: Bool) -> Bool {
        guard record.state == .installed, record.availability == .available,
              !hasPendingAction, let entry, entry.id == record.catalogID,
              entry.revision == record.revision, entry.preparation == .none else { return false }
        // Old Klein installations predate the workflow fields.
        if entry.imageProfile != nil, entry.workflowProfileID == nil, entry.workflowIdentity == nil { return true }
        guard let operationID = entry.workflowProfileID,
              let identity = entry.workflowIdentity else { return false }
        switch operationID {
        case WorkflowModelRoutes.qwen35, WorkflowModelRoutes.qwen38:
            return identity == "text:" + entry.revision
        case WorkflowModelRoutes.fluxDev, "d.image.generate":
            return identity == "image:" + entry.revision
        case WorkflowModelRoutes.ace, "d.music.generate":
            return identity == "music:" + entry.revision
        default:
            return false
        }
    }
}

public enum ModelCatalog {
    public static let flux2ID = "flux2-klein-4b-q8"
    public static func entries() throws -> [ModelCatalogEntry] { try FrozenModelCatalog.entries() }
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
            revision: manifest.revision, files: manifest.files, imageProfile: .flux2Klein,
            workflowProfileID: "d.image.generate", workflowIdentity: "image:" + manifest.revision,
            modelSpec: "蒸馏 Klein 4B · 8 位量化", memoryGuidance: "M4 / 16 GiB 上已有有限实测；约需 8 GiB 单任务预算。")
    }
}

public enum ModelInstallationState: String, Codable, Sendable {
    case registered, queued, downloading, pausing, paused, verifying, publishing, installed, preparationRequired, failed
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
    public let downloadCredentialConnected: Bool
    public let copyProgress: ModelCopyProgress?
}

public struct ModelCopyProgress: Sendable {
    public let sourceID: ModelID
    public let copiedBytes: UInt64
    public let totalBytes: UInt64
}

public struct ModelUsageLease: Sendable {
    public let id: UUID
    public let modelID: ModelID
    public let reference: ModelReference
}

public enum ModelLibraryError: Error, LocalizedError, Sendable {
    case invalidCatalog(String), unavailable(String), busy(String), unsafePath(String)
    case operationPaused
    case integrity(String), download(String), accessDenied(String), storage(String), insufficientSpace(required: UInt64, available: UInt64)
    public var errorDescription: String? {
        switch self {
        case .invalidCatalog(let reason), .unavailable(let reason), .busy(let reason), .unsafePath(let reason),
             .integrity(let reason), .download(let reason), .accessDenied(let reason), .storage(let reason): reason
        case .operationPaused: "操作已暂停，可稍后继续。"
        case .insufficientSpace(let required, let available):
            "模型安装空间不足：还需 \(required) 字节，可用 \(available) 字节。请选择空间足够的磁盘。"
        }
    }
}
