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

/// Fixed supported origins; catalog files cannot supply arbitrary credential destinations.
public enum ModelFileSource: String, Codable, Hashable, Sendable { case huggingFace, githubRaw }

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
    public let source: ModelFileSource?
    public init(path: String, size: UInt64, sha256: String,
                digestAlgorithm: ModelDigestAlgorithm = .sha256, sourceRepository: String? = nil,
                sourceRevision: String? = nil, remotePath: String? = nil, source: ModelFileSource? = nil) {
        self.path = path; self.size = size; self.sha256 = sha256
        self.digestAlgorithm = digestAlgorithm; self.sourceRepository = sourceRepository
        self.sourceRevision = sourceRevision; self.remotePath = remotePath; self.source = source
    }
    private enum CodingKeys: String, CodingKey { case path, size, sha256, digestAlgorithm, sourceRepository, sourceRevision, remotePath, source }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(path: try values.decode(String.self, forKey: .path),
                  size: try values.decode(UInt64.self, forKey: .size),
                  sha256: try values.decode(String.self, forKey: .sha256),
                  digestAlgorithm: try values.decodeIfPresent(ModelDigestAlgorithm.self, forKey: .digestAlgorithm) ?? .sha256,
                  sourceRepository: try values.decodeIfPresent(String.self, forKey: .sourceRepository),
                  sourceRevision: try values.decodeIfPresent(String.self, forKey: .sourceRevision),
                  remotePath: try values.decodeIfPresent(String.self, forKey: .remotePath),
                  source: try values.decodeIfPresent(ModelFileSource.self, forKey: .source))
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(path, forKey: .path); try values.encode(size, forKey: .size)
        try values.encode(sha256, forKey: .sha256)
        if digestAlgorithm != .sha256 { try values.encode(digestAlgorithm, forKey: .digestAlgorithm) }
        try values.encodeIfPresent(sourceRepository, forKey: .sourceRepository)
        try values.encodeIfPresent(sourceRevision, forKey: .sourceRevision)
        try values.encodeIfPresent(remotePath, forKey: .remotePath)
        try values.encodeIfPresent(source, forKey: .source)
    }
}

public enum ModelDigestAlgorithm: String, Codable, Hashable, Sendable { case sha256, gitBlobSHA1 }
public enum ModelPreparation: String, Codable, Hashable, Sendable { case none, required }

public struct ModelCatalogEntry: Identifiable, Codable, Sendable, Equatable {
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
        guard record.registrationState == .registered, record.state == .installed, record.availability == .available,
              !hasPendingAction, let entry, entry.id == record.catalogID,
              entry.revision == record.revision, entry.preparation == .none else { return false }
        // Old Klein installations predate the workflow fields.
        if entry.imageProfile != nil, entry.workflowProfileID == nil, entry.workflowIdentity == nil { return true }
        guard let operationID = entry.workflowProfileID,
              let identity = entry.workflowIdentity else { return false }
        switch operationID {
        case "d.music.pitch":
            return ModelCatalog.isPitch(entry)
        case "d.model.language":
            return identity == "text:" + entry.revision && WorkflowModelRoutes.legacyTextOperations(identity: identity).contains(operationID)
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
    public static let pitchID = "swift-f0-0.1.2-cpu-v1"
    public static let pitchSourceRevision = "8e968fe53b818da318d46e14b84b3d0b41192ad1"
    public static let pitchIdentity = "pitch:" + PitchAnalysisRequest.modelSHA256
    /// Source commit and frozen execution digest are different identities. Only this
    /// exact, checksum-verified catalog mapping joins them; no generic revision bypass.
    public static func isPitch(_ entry: ModelCatalogEntry) -> Bool {
        entry.id == pitchID && entry.repository == "lars76/swift-f0"
            && entry.revision == pitchSourceRevision && entry.workflowProfileID == "d.music.pitch"
            && entry.workflowIdentity == pitchIdentity && entry.preparation == .none
            && entry.files.contains { $0.path == "model.onnx" && $0.size == 399_114
                && $0.sha256 == PitchAnalysisRequest.modelSHA256 && $0.digestAlgorithm == .sha256
                && $0.source == .githubRaw && $0.remotePath == "swift_f0/model.onnx"
                && $0.sourceRepository == nil && $0.sourceRevision == nil }
    }
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

public struct ModelRecord: Identifiable, Codable, Sendable, Equatable {
    public let id: ModelID
    public let catalogID: String
    public let revision: String
    public var storage: ModelStorageKind
    public var state: ModelInstallationState
    public var availability: ModelAvailability
    public var downloadedBytes: UInt64
    public private(set) var totalBytes: UInt64
    public var error: String?
    public var directory: URL?
    public var activeLeaseCount: Int
    public var registrationState: ModelRegistrationState = .registered
    func replacingTotalBytes(_ value: UInt64) -> Self { var copy = self; copy.totalBytes = value; return copy }
    public init(id: ModelID, catalogID: String, revision: String, storage: ModelStorageKind,
                state: ModelInstallationState, availability: ModelAvailability, downloadedBytes: UInt64,
                totalBytes: UInt64, error: String?, directory: URL?, activeLeaseCount: Int,
                registrationState: ModelRegistrationState = .registered) {
        self.id = id; self.catalogID = catalogID; self.revision = revision; self.storage = storage
        self.state = state; self.availability = availability; self.downloadedBytes = downloadedBytes
        self.totalBytes = totalBytes; self.error = error; self.directory = directory
        self.activeLeaseCount = activeLeaseCount; self.registrationState = registrationState
    }
    private enum CodingKeys: String, CodingKey {
        case id, catalogID, revision, storage, state, availability, downloadedBytes, totalBytes, error, directory, activeLeaseCount, registrationState
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let state = try c.decode(ModelInstallationState.self, forKey: .state)
        self.init(id: try c.decode(ModelID.self, forKey: .id), catalogID: try c.decode(String.self, forKey: .catalogID),
            revision: try c.decode(String.self, forKey: .revision), storage: try c.decode(ModelStorageKind.self, forKey: .storage),
            state: state, availability: try c.decode(ModelAvailability.self, forKey: .availability),
            downloadedBytes: try c.decode(UInt64.self, forKey: .downloadedBytes), totalBytes: try c.decode(UInt64.self, forKey: .totalBytes),
            error: try c.decodeIfPresent(String.self, forKey: .error), directory: try c.decodeIfPresent(URL.self, forKey: .directory),
            activeLeaseCount: try c.decode(Int.self, forKey: .activeLeaseCount),
            registrationState: try c.decodeIfPresent(ModelRegistrationState.self, forKey: .registrationState) ?? (state == .installed ? .registered : .unregistered))
    }
}

public struct ModelLibrarySnapshot: Sendable, Equatable {
    public let revision: UInt64
    public let rootURL: URL?
    public let catalog: [ModelCatalogEntry]
    public let records: [ModelRecord]
    public let downloadCredentialConnected: Bool
    public let copyProgress: ModelCopyProgress?
    public var resources: [ModelResource] = []
    public var downloads: [ModelDownloadTask] = []
    public var queueState: ModelDownloadQueueState = .waitingForResume
    public var queueError: String? = nil
}

public struct ModelCopyProgress: Sendable, Equatable {
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


/// A local copy and an execution registration have different command identities.
/// Legacy copies retain the UUID of their original installation without rewriting projects.
public struct ModelResourceID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID
    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public var description: String { rawValue.uuidString }
    public var modelID: ModelID { .init(rawValue: rawValue) }
}
public enum ModelRegistrationState: String, Codable, Sendable { case unregistered, pending, registered }
public enum ModelResourceFileState: String, Codable, Sendable { case partial, unchecked, verified, invalid, deleting, deleted }
public enum ModelResourceOrigin: String, Codable, Sendable { case download, local, prepared, legacy }
public enum ModelResourceRole: String, Codable, Sendable { case original, execution }
public enum ModelDownloadQueueState: String, Codable, Sendable { case running, paused, waitingForResume }
public enum ModelDownloadPostAction: String, Codable, Sendable { case filesOnly, register }
public enum ModelDownloadState: String, Codable, Sendable {
    case queued, downloading, verifying, publishing, waitingRetry, paused, failed, completed, cancelled
    public var isTerminal: Bool { [.failed, .completed, .cancelled].contains(self) }
    public var isActive: Bool { [.downloading, .verifying, .publishing].contains(self) }
}
public struct ModelResourceEvent: Codable, Sendable, Equatable, Identifiable {
    public var id = UUID()
    public let action: String
    public let date: Date?
    public let result: String?
}
/// One current file owner; removing history never restores an older request.
public struct ModelDownloadOwnership: Codable, Sendable, Equatable {
    public let taskID: UUID
    public let attemptID: UUID
    public let generation: UUID
    public init(_ task: ModelDownloadTask) {
        taskID = task.id; attemptID = task.attemptID; generation = task.generation
    }
    public func matches(_ task: ModelDownloadTask) -> Bool {
        taskID == task.id && attemptID == task.attemptID && generation == task.generation
    }
}
public struct ModelResourceControl: Codable, Sendable, Equatable {
    public var fileState: ModelResourceFileState
    public var downloadOwner: ModelDownloadOwnership?
    public var origin: ModelResourceOrigin
    public var role: ModelResourceRole = .original
    public var parentResourceID: ModelResourceID?
    public var executionRevision: String?
    public var retryNotBefore: Date?
    public var preparationRecipe: String?
    public var requiredPaths: [String]?
    public var requiresTokenizerUpgrade: Bool?
    public var lastVerified: Date?
    public var lastAccessCheck: Date?
    public var events: [ModelResourceEvent] = []
    public init(fileState: ModelResourceFileState, origin: ModelResourceOrigin) {
        self.fileState = fileState; self.origin = origin
    }
}
public struct ModelResource: Identifiable, Sendable, Equatable {
    public var id: ModelResourceID { .init(rawValue: record.id.rawValue) }
    public let record: ModelRecord
    public let control: ModelResourceControl
}
public struct ModelDownloadTask: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let resourceID: ModelResourceID
    public let catalogID: String
    public private(set) var recipeIdentity: String
    public var state: ModelDownloadState
    public var postAction: ModelDownloadPostAction
    public var attemptID: UUID
    public var generation: UUID
    public var attempts: Int
    public var automaticRetries: Int
    public var earliestRetry: Date?
    public var error: String?
    public var firstError: String?
    public var postActionError: String?
    public let createdAt: Date?
    public var completedAt: Date?
    func upgradingRecipe(_ value: String) -> Self {
        var copy = self; copy.recipeIdentity = value
        // Reject UI commands captured against the former recipe; attempt identity
        // changes only when the existing scheduler actually dispatches work.
        copy.generation = UUID()
        return copy
    }
    public init(resourceID: ModelResourceID, catalogID: String, recipeIdentity: String,
                postAction: ModelDownloadPostAction, createdAt: Date? = Date()) {
        id = UUID(); self.resourceID = resourceID; self.catalogID = catalogID; self.recipeIdentity = recipeIdentity
        state = .queued; self.postAction = postAction; attemptID = UUID(); generation = UUID()
        attempts = 0; automaticRetries = 0; self.createdAt = createdAt
    }
}

/// Only classified transport errors may schedule another attempt. No URL or token is retained.
struct ModelTransientDownloadError: LocalizedError, Sendable {
    let status: Int?
    let retryAfter: Date?
    var errorDescription: String? { status.map { "Temporary server failure (HTTP \($0))." } ?? "Temporary connection failure." }
}

/// Existing project configuration is inventory evidence, not a managed download.
public struct ModelReadOnlyConfiguration: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let identity: String
    public let location: URL?
    public let selectable: Bool
    public init(id: String, title: String, identity: String, location: URL?, selectable: Bool = false) {
        self.id = id; self.title = title; self.identity = identity; self.location = location; self.selectable = selectable
    }
}
