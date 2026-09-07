import DInference
import Foundation

public enum JobState: String, Codable, Sendable, CaseIterable {
    case queued, preparing, generating, cancelling, releasing, saving
    case completed, cancelled, failed, interrupted

    public var isTerminal: Bool {
        switch self {
        case .completed, .cancelled, .failed, .interrupted: true
        default: false
        }
    }

    public var title: String {
        switch self {
        case .queued: "排队中"
        case .preparing: "准备模型"
        case .generating: "生成中"
        case .cancelling: "正在取消"
        case .releasing: "释放计算资源"
        case .saving: "保存作品"
        case .completed: "已完成"
        case .cancelled: "已取消"
        case .failed: "失败"
        case .interrupted: "已中断"
        }
    }
}

/// Roles describe ownership and purpose, independently of an image's display representation.
public enum AssetRole: String, Codable, Sendable {
    case original, result, preview, thumbnail
}

/// Unknown properties stay nil. A decoded preview must never redefine the original's metadata.
public struct MediaMetadata: Codable, Sendable, Equatable {
    public var width: Int?
    public var height: Int?
    public var bitDepth: Int?
    public var colorSpace: String?

    public init(width: Int? = nil, height: Int? = nil, bitDepth: Int? = nil,
                colorSpace: String? = nil) {
        self.width = width
        self.height = height
        self.bitDepth = bitDepth
        self.colorSpace = colorSpace
    }
}

public struct ProjectAsset: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var jobID: UUID?
    public var relativePath: String
    public var mediaType: String
    public var role: AssetRole
    public var createdAt: Date
    public var metadata: MediaMetadata
    public var name: String
    public var isFavorite: Bool
    public var note: String

    public init(id: UUID = UUID(), jobID: UUID? = nil, relativePath: String,
                mediaType: String = "image/png", role: AssetRole = .result,
                createdAt: Date = Date(), metadata: MediaMetadata = .init(),
                name: String = "未命名作品", isFavorite: Bool = false, note: String = "") {
        self.id = id
        self.jobID = jobID
        self.relativePath = relativePath
        self.mediaType = mediaType
        self.role = role
        self.createdAt = createdAt
        self.metadata = metadata
        self.name = name
        self.isFavorite = isFavorite
        self.note = note
    }

    private enum CodingKeys: String, CodingKey {
        case id, jobID, relativePath, mediaType, role, createdAt, metadata, name, isFavorite, note
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        jobID = try values.decodeIfPresent(UUID.self, forKey: .jobID)
        relativePath = try values.decode(String.self, forKey: .relativePath)
        mediaType = try values.decode(String.self, forKey: .mediaType)
        role = try values.decode(AssetRole.self, forKey: .role)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        metadata = try values.decode(MediaMetadata.self, forKey: .metadata)
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? "未命名作品"
        isFavorite = try values.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        note = try values.decodeIfPresent(String.self, forKey: .note) ?? ""
    }
}

public struct ProjectJob: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var documentID: UUID
    public var request: InferenceRequest
    public var createdAt: Date
    public var state: JobState
    public var error: String?
    public var artifactIDs: [UUID]
    public var resultMetadata: [String: String]

    public init(id: UUID, documentID: UUID, request: InferenceRequest, createdAt: Date = Date(),
                state: JobState = .queued, error: String? = nil,
                artifactIDs: [UUID] = [], resultMetadata: [String: String] = [:]) {
        self.id = id
        self.documentID = documentID
        self.request = request
        self.createdAt = createdAt
        self.state = state
        self.error = error
        self.artifactIDs = artifactIDs
        self.resultMetadata = resultMetadata
    }
}

/// Editable text is preserved verbatim, including an incomplete seed. Admission validation
/// applies to a submitted InferenceRequest, not to the user's unfinished work.
public struct ProjectDraft: Codable, Sendable, Equatable {
    public var prompt: String
    public var randomSeed: Bool
    public var seedText: String

    public init(prompt: String = "", randomSeed: Bool = true, seedText: String = "0") {
        self.prompt = prompt
        self.randomSeed = randomSeed
        self.seedText = seedText
    }
}

public struct ProjectManifest: Codable, Sendable, Equatable, Identifiable {
    public static let currentSchemaVersion = 2
    public var schemaVersion: Int
    /// Monotonic committed state version lets the UI discard a late, stale actor response.
    public var revision: UInt64
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var updatedAt: Date
    public var documents: [ProjectDocument]
    public var activeDocumentID: UUID
    public var activeDocument: ProjectDocument? { documents.first { $0.id == activeDocumentID } }
    /// Compatibility for clients that edit only the active document. New operations capture
    /// a document ID before suspension and address that document explicitly.
    public var draft: ProjectDraft {
        get { activeDocument?.draft ?? .init() }
        set {
            if let index = documents.firstIndex(where: { $0.id == activeDocumentID }) {
                documents[index].draft = newValue
            }
        }
    }
    public var jobs: [ProjectJob]
    public var assets: [ProjectAsset]

    public init(schemaVersion: Int = Self.currentSchemaVersion, revision: UInt64 = 0, id: UUID = UUID(),
                name: String, createdAt: Date = Date(), updatedAt: Date = Date(), draft: ProjectDraft = .init(),
                jobs: [ProjectJob] = [], assets: [ProjectAsset] = [],
                documents: [ProjectDocument]? = nil, activeDocumentID: UUID? = nil) {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        let initialDocuments = documents ?? [ProjectDocument(name: "图像探索", draft: draft)]
        self.documents = initialDocuments
        self.activeDocumentID = activeDocumentID ?? initialDocuments.first?.id ?? UUID()
        self.jobs = jobs
        self.assets = assets
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, revision, id, name, createdAt, updatedAt, draft, jobs, assets, documents, activeDocumentID
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        revision = try values.decodeIfPresent(UInt64.self, forKey: .revision) ?? 0
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        assets = try values.decode([ProjectAsset].self, forKey: .assets)
        if schemaVersion == 1 {
            // Stable across a crash after the backup but before v2 publication. Object
            // categories have separate identity spaces; no existing ID is rewritten.
            let legacyDraft = try values.decodeIfPresent(ProjectDraft.self, forKey: .draft) ?? .init()
            documents = [ProjectDocument(id: id, name: "图像探索", draft: legacyDraft,
                                         selectedAssetID: assets.last(where: { $0.role == .result })?.id)]
            activeDocumentID = id
            let documentID = id
            jobs = try values.decode([LegacyProjectJob].self, forKey: .jobs).map { $0.migrated(documentID: documentID) }
        } else {
            documents = try values.decode([ProjectDocument].self, forKey: .documents)
            activeDocumentID = try values.decode(UUID.self, forKey: .activeDocumentID)
            jobs = try values.decode([ProjectJob].self, forKey: .jobs)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(revision, forKey: .revision)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encode(updatedAt, forKey: .updatedAt)
        try values.encode(documents, forKey: .documents)
        try values.encode(activeDocumentID, forKey: .activeDocumentID)
        try values.encode(jobs, forKey: .jobs)
        try values.encode(assets, forKey: .assets)
    }
}

/// A named exploration owns editable settings and references candidates without copying media.
public struct ProjectDocument: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var draft: ProjectDraft
    /// A reference for the creator, not an implicit image-to-image inference input.
    public var sourceAssetID: UUID?
    public var adoptedAssetID: UUID?
    public var selectedAssetID: UUID?

    public init(id: UUID = UUID(), name: String, draft: ProjectDraft = .init(), sourceAssetID: UUID? = nil,
                adoptedAssetID: UUID? = nil, selectedAssetID: UUID? = nil) {
        self.id = id
        self.name = name
        self.draft = draft
        self.sourceAssetID = sourceAssetID
        self.adoptedAssetID = adoptedAssetID
        self.selectedAssetID = selectedAssetID
    }
}

private struct LegacyProjectJob: Decodable {
    let id: UUID
    let request: InferenceRequest
    let createdAt: Date
    let state: JobState
    let error: String?
    let artifactIDs: [UUID]
    let resultMetadata: [String: String]

    func migrated(documentID: UUID) -> ProjectJob {
        ProjectJob(id: id, documentID: documentID, request: request, createdAt: createdAt,
                   state: state, error: error, artifactIDs: artifactIDs, resultMetadata: resultMetadata)
    }
}

public enum ProjectStoreError: Error, LocalizedError, Sendable, Equatable {
    case invalidProject(String)
    case unsupportedSchema(Int)
    case unsafePath(String)
    case alreadyExists(String)
    case missingJob
    case missingAsset
    case missingDocument
    case invalidImage(String)
    case invalidTransition
    case externalModification
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .invalidProject(let reason): "无法读取 D 项目：\(reason)"
        case .unsupportedSchema(let version): "此项目使用尚不支持的格式版本 \(version)，请使用兼容的 D 版本打开。"
        case .unsafePath(let path): "文件路径不安全或包含符号链接：\(path)"
        case .alreadyExists(let path): "目标已存在，未覆盖任何文件：\(path)"
        case .missingJob: "项目中找不到该任务。"
        case .missingAsset: "项目中找不到该作品。"
        case .missingDocument: "项目中找不到该探索文档。"
        case .invalidImage(let path): "图片无法完整解码，未登记为作品：\(path)"
        case .invalidTransition: "任务已经结束，不能重新改变其运行状态。"
        case .externalModification: "项目清单已被其他程序修改；现有文件已保留，请重新打开后检查。"
        case .io(let reason): "无法访问或保存项目文件：\(reason)。请检查磁盘连接、可用空间和访问权限。"
        }
    }
}
