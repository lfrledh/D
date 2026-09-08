import Foundation
import DInference

public enum TextDraftError: Error, Sendable, Equatable, LocalizedError {
    case textTooLarge
    case invalidSelection
    case alreadyRunning
    case noAcceptableCandidate
    case noUndoAvailable
    case nonTextOutput
    case emptyReplacement
    case replacementTooLarge
    case archiveTooLarge
    case unsupportedArchiveVersion
    case malformedArchive
    case inferenceFailed(String)

    public var errorDescription: String? {
        switch self {
        case .textTooLarge: "A text draft may not exceed 1 MiB of UTF-8 data."
        case .invalidSelection: "The selection must be a non-empty Character-aligned UTF-16 range."
        case .alreadyRunning: "A rewrite is already running."
        case .noAcceptableCandidate: "There is no candidate that can safely be accepted."
        case .noUndoAvailable: "There is no accepted rewrite that can safely be undone."
        case .nonTextOutput: "The rewrite engine produced non-text output."
        case .emptyReplacement: "The rewrite engine produced an empty replacement."
        case .replacementTooLarge: "The rewrite output exceeds the 1 MiB limit."
        case .archiveTooLarge: "The draft archive exceeds its size limit."
        case .unsupportedArchiveVersion: "The draft archive schema version is unsupported."
        case .malformedArchive: "The draft archive is malformed."
        case .inferenceFailed(let message): message
        }
    }
}

public struct TextDraftDocument: Codable, Sendable, Equatable, Identifiable {
    public static let maximumUTF8Bytes = 1_024 * 1_024

    public let id: UUID
    public let revision: UUID
    public let text: String

    public init(id: UUID = UUID(), revision: UUID = UUID(), text: String = "") throws {
        try Self.validate(text)
        self.id = id
        self.revision = revision
        self.text = text
    }

    public static func validate(_ text: String) throws {
        guard text.utf8.count <= maximumUTF8Bytes else { throw TextDraftError.textTooLarge }
    }

    private enum CodingKeys: String, CodingKey { case id, revision, text }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let id = try values.decode(UUID.self, forKey: .id)
        let revision = try values.decode(UUID.self, forKey: .revision)
        let text = try values.decode(String.self, forKey: .text)
        try self.init(id: id, revision: revision, text: text)
    }
}

public struct TextRewriteSelection: Sendable, Equatable {
    public let documentID: UUID
    public let documentRevision: UUID
    public let utf16Location: Int
    public let utf16Length: Int
    public let selectedText: String

    public init(document: TextDraftDocument, range: NSRange) throws {
        guard range.location != NSNotFound, range.location >= 0, range.length > 0 else {
            throw TextDraftError.invalidSelection
        }
        let total = document.text.utf16.count
        guard range.location <= total, range.length <= total - range.location else {
            throw TextDraftError.invalidSelection
        }
        let start = String.Index(utf16Offset: range.location, in: document.text)
        let end = String.Index(utf16Offset: range.location + range.length, in: document.text)
        guard Self.isCharacterBoundary(start, in: document.text),
              Self.isCharacterBoundary(end, in: document.text) else {
            throw TextDraftError.invalidSelection
        }
        self.documentID = document.id
        self.documentRevision = document.revision
        self.utf16Location = range.location
        self.utf16Length = range.length
        self.selectedText = String(document.text[start..<end])
    }

    func range(in text: String) -> Range<String.Index>? {
        guard utf16Location >= 0, utf16Length > 0,
              utf16Location <= text.utf16.count,
              utf16Length <= text.utf16.count - utf16Location else { return nil }
        let start = String.Index(utf16Offset: utf16Location, in: text)
        let end = String.Index(utf16Offset: utf16Location + utf16Length, in: text)
        guard Self.isCharacterBoundary(start, in: text), Self.isCharacterBoundary(end, in: text) else { return nil }
        return start..<end
    }

    private static func isCharacterBoundary(_ index: String.Index, in text: String) -> Bool {
        index == text.endIndex || text.indices.contains(index)
    }
}

public struct TextRewriteCandidate: Sendable, Equatable {
    public let runID: UUID
    public let selection: TextRewriteSelection
    public let replacement: String
    public let request: InferenceRequest
    public let result: InferenceResult

    public init(runID: UUID, selection: TextRewriteSelection, replacement: String,
                request: InferenceRequest, result: InferenceResult) {
        self.runID = runID
        self.selection = selection
        self.replacement = replacement
        self.request = request
        self.result = result
    }
}
