import Foundation

/// Editable text owned by one chat session. Storage and asset publication are owned by the caller.
public struct ChatArtifactContent: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case plainText, markdown, code, csv, html, svg, mermaid
    }

    public enum ValidationError: LocalizedError, Equatable {
        case blankTitle
        case titleTooLong
        case sourceTooLarge
        case invalidRevision
        case revisionOverflow
        case invalidSourceKind
        case invalidOutputKind

        public var errorDescription: String? {
            switch self {
            case .blankTitle: "Artifact title cannot be blank."
            case .titleTooLong: "Artifact title exceeds 256 characters."
            case .sourceTooLarge: "Artifact source exceeds 1 MiB of UTF-8."
            case .invalidRevision: "Artifact revision must be positive."
            case .revisionOverflow: "Artifact revision cannot be incremented."
            case .invalidSourceKind: "Artifact origin must be a text or document asset."
            case .invalidOutputKind: "Artifact output must be a text or document asset."
            }
        }
    }

    public static let maximumSourceBytes = 1_048_576
    public static let maximumTitleCharacters = 256

    public let id: UUID
    public let revision: Int
    public let sessionID: UUID
    public var title: String
    public var kind: Kind
    public var text: String
    /// The original input; it stays attached to every edited revision.
    public let source: WorkflowAssetReference?
    /// The asset containing this exact persisted revision, when published.
    public var output: WorkflowAssetReference?

    public init(id: UUID = UUID(), revision: Int = 1, sessionID: UUID,
                title: String, kind: Kind, text: String,
                source: WorkflowAssetReference? = nil, output: WorkflowAssetReference? = nil) {
        self.id = id
        self.revision = revision
        self.sessionID = sessionID
        self.title = title
        self.kind = kind
        self.text = text
        self.source = source
        self.output = output
    }

    public func validate() throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError.blankTitle
        }
        guard title.count <= Self.maximumTitleCharacters else { throw ValidationError.titleTooLong }
        guard text.utf8.count <= Self.maximumSourceBytes else { throw ValidationError.sourceTooLarge }
        guard revision > 0 else { throw ValidationError.invalidRevision }
        if let source, source.kind != .text && source.kind != .document {
            throw ValidationError.invalidSourceKind
        }
        if let output, output.kind != .text && output.kind != .document {
            throw ValidationError.invalidOutputKind
        }
    }

    /// Creates a new unpublished revision from edited fields, retaining identity and origin.
    public func revised() throws -> Self {
        try validate()
        guard revision < Int.max else { throw ValidationError.revisionOverflow }
        return Self(id: id, revision: revision + 1, sessionID: sessionID,
                    title: title, kind: kind, text: text, source: source, output: nil)
    }
}
