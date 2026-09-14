import CryptoKit
import DInference
import Foundation

/// Storage/parser budgets, independent of a model's token context or the Mac's memory.
public enum TextSourcesLimits {
    public static let sourceBytes = 512 * 1_024
    public static let sources = 8
    public static let excerpts = 32
    public static let records = 16
    public static let questionBytes = 16 * 1_024
    public static let promptBytes = 512 * 1_024
    public static let archiveBytes = 8 * 1_024 * 1_024
}

public enum TextSourcesError: Error, Sendable, Equatable, LocalizedError {
    case invalid(String)
    case limit(String)
    case stale
    case busy
    case file(String)
    public var errorDescription: String? {
        switch self {
        case .invalid(let value), .limit(let value), .file(let value): value
        case .stale: "问题、资料或正文已经改变；旧回答仍可查看，请重新生成后再采用。"
        case .busy: "请先等待当前任务停止并释放资源。"
        }
    }
}

/// Original UTF-8 bytes are authoritative. Coordinates refer to decoded text with an optional BOM removed.
public struct TextSourceSnapshot: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let revision: UUID
    public let displayName: String
    public let bytes: Data
    public let sha256: String

    public init(id: UUID = UUID(), revision: UUID = UUID(), displayName: String, bytes: Data) throws {
        guard !bytes.isEmpty, bytes.count <= TextSourcesLimits.sourceBytes else {
            throw TextSourcesError.limit("单份文字资料必须为 1 字节至 512 KiB。")
        }
        self.id = id; self.revision = revision; self.displayName = displayName; self.bytes = bytes
        sha256 = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        _ = try validatedText()
    }

    public func validatedText() throws -> String {
        guard !bytes.isEmpty, bytes.count <= TextSourcesLimits.sourceBytes else {
            throw TextSourcesError.limit("单份文字资料必须为 1 字节至 512 KiB。")
        }
        guard !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              displayName.utf8.count <= 512,
              !displayName.contains("/"), !displayName.contains("\\"),
              !displayName.unicodeScalars.contains(where: {
                  $0.properties.generalCategory == .control ||
                  (0x202A...0x202E).contains($0.value) || (0x2066...0x2069).contains($0.value) ||
                  [0x061C, 0x200E, 0x200F].contains($0.value)
              }) else {
            throw TextSourcesError.invalid("资料名称无效；这里只保存文件名，不保存绝对路径。")
        }
        guard sha256 == SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() else {
            throw TextSourcesError.invalid("资料摘要与原始内容不符。")
        }
        let content = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? bytes.dropFirst(3) : bytes[...]
        guard let text = String(data: Data(content), encoding: .utf8), !text.isEmpty,
              !text.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw TextSourcesError.invalid("资料不是有效的非空 UTF-8 文本。")
        }
        return text
    }
}

public struct TextSourceExcerpt: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let sourceID: UUID
    public let sourceRevision: UUID
    public let sourceSHA256: String
    public let utf16Location: Int
    public let utf16Length: Int
    public let text: String

    public init(id: UUID = UUID(), source: TextSourceSnapshot, range: NSRange) throws {
        let text = try source.validatedText()
        let draft = try TextDraftDocument(id: source.id, revision: source.revision, text: text)
        let selected = try TextRewriteSelection(document: draft, range: range)
        self.id = id; sourceID = source.id; sourceRevision = source.revision; sourceSHA256 = source.sha256
        utf16Location = range.location; utf16Length = range.length; self.text = selected.selectedText
    }

    public func validate(against source: TextSourceSnapshot) throws {
        let actual = try TextSourceExcerpt(id: id, source: source,
                                          range: NSRange(location: utf16Location, length: utf16Length))
        guard sourceID == actual.sourceID, sourceRevision == actual.sourceRevision,
              sourceSHA256 == actual.sourceSHA256,
              text.utf8.elementsEqual(actual.text.utf8) else {
            throw TextSourcesError.invalid("引用片段的位置、修订或内容与资料不符。")
        }
    }
}

/// Identifies the exact instruction template used at submission time, not the archive schema.
public enum TextSourcesPromptTemplate: String, Codable, Sendable {
    case v1 = "sources.v1"
    case v2 = "sources.v2"
}

public struct TextSourcesSubmission: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let notebookRevision: UUID
    public let targetDocumentID: UUID
    public let targetDocumentRevision: UUID
    public let question: String
    public let sources: [TextSourceSnapshot]
    public let excerpts: [TextSourceExcerpt]
    public let request: TextRequest
    /// Installed profile identity and exact revision; never the local model path.
    public let modelID: String
    public let modelRevision: String?
    public let promptTemplate: TextSourcesPromptTemplate

    public init(id: UUID = UUID(), notebookRevision: UUID, targetDocumentID: UUID,
                targetDocumentRevision: UUID, question: String, sources: [TextSourceSnapshot],
                excerpts: [TextSourceExcerpt], request: TextRequest, modelID: String, modelRevision: String?,
                promptTemplate: TextSourcesPromptTemplate = .v1) {
        self.id = id; self.notebookRevision = notebookRevision; self.targetDocumentID = targetDocumentID
        self.targetDocumentRevision = targetDocumentRevision; self.question = question
        self.sources = sources; self.excerpts = excerpts; self.request = request
        self.modelID = modelID; self.modelRevision = modelRevision
        self.promptTemplate = promptTemplate
    }

    private enum CodingKeys: String, CodingKey {
        case id, notebookRevision, targetDocumentID, targetDocumentRevision, question, sources, excerpts
        case request, modelID, modelRevision, promptTemplate
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        notebookRevision = try container.decode(UUID.self, forKey: .notebookRevision)
        targetDocumentID = try container.decode(UUID.self, forKey: .targetDocumentID)
        targetDocumentRevision = try container.decode(UUID.self, forKey: .targetDocumentRevision)
        question = try container.decode(String.self, forKey: .question)
        sources = try container.decode([TextSourceSnapshot].self, forKey: .sources)
        excerpts = try container.decode([TextSourceExcerpt].self, forKey: .excerpts)
        request = try container.decode(TextRequest.self, forKey: .request)
        modelID = try container.decode(String.self, forKey: .modelID)
        modelRevision = try container.decodeIfPresent(String.self, forKey: .modelRevision)
        // Only an absent field denotes historical v1. Explicit null and unknown values are corruption.
        promptTemplate = container.contains(.promptTemplate)
            ? try container.decode(TextSourcesPromptTemplate.self, forKey: .promptTemplate) : .v1
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(notebookRevision, forKey: .notebookRevision)
        try container.encode(targetDocumentID, forKey: .targetDocumentID)
        try container.encode(targetDocumentRevision, forKey: .targetDocumentRevision)
        try container.encode(question, forKey: .question)
        try container.encode(sources, forKey: .sources)
        try container.encode(excerpts, forKey: .excerpts)
        try container.encode(request, forKey: .request)
        try container.encode(modelID, forKey: .modelID)
        try container.encodeIfPresent(modelRevision, forKey: .modelRevision)
        // Preserve legacy encoded size, including archives already at their storage budget.
        if promptTemplate != .v1 { try container.encode(promptTemplate, forKey: .promptTemplate) }
    }
}

public enum TextSourceAnswerDisposition: String, Codable, Sendable { case pending, accepted, rejected, undone }

public struct TextSourceAnswerRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID { submission.id }
    public let submission: TextSourcesSubmission
    public let answer: String
    public let completedAt: Date
    /// Only execution metrics from an explicit allowlist; no arbitrary provider strings/paths.
    public let metrics: [String: String]
    public var disposition: TextSourceAnswerDisposition

    public init(submission: TextSourcesSubmission, answer: String, completedAt: Date = Date(),
                metrics: [String: String] = [:], disposition: TextSourceAnswerDisposition = .pending) {
        self.submission = submission; self.answer = answer; self.completedAt = completedAt
        self.metrics = metrics; self.disposition = disposition
    }
}

/// Stored beside textDraft in the same project transaction, not inside the rewrite editor's value.
public struct TextSourcesNotebook: Codable, Sendable, Equatable {
    public var revision: UUID
    /// Editable input revision; recording a result does not itself stale that result.
    public var inputRevision: UUID
    public var question: String
    public var sources: [TextSourceSnapshot]
    public var excerpts: [TextSourceExcerpt]
    public var records: [TextSourceAnswerRecord]

    public init(revision: UUID = UUID(), inputRevision: UUID = UUID(), question: String = "", sources: [TextSourceSnapshot] = [],
                excerpts: [TextSourceExcerpt] = [], records: [TextSourceAnswerRecord] = []) {
        self.revision = revision; self.inputRevision = inputRevision; self.question = question; self.sources = sources
        self.excerpts = excerpts; self.records = records
    }
}
