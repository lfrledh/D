import CryptoKit
import Foundation

public enum ChatQuoteSelectionError: Error, Sendable, Equatable, LocalizedError {
    case sourceTooLarge
    case invalidRange
    case selectionTooLarge
    case sourceChanged

    public var errorDescription: String? {
        switch self {
        case .sourceTooLarge: "Quote source exceeds 1 MiB of UTF-8 text."
        case .invalidRange: "Select a non-empty range at Swift Character boundaries."
        case .selectionTooLarge: "Quote selection exceeds 64 KiB of UTF-8 text."
        case .sourceChanged: "The quote source or selected text has changed."
        }
    }
}

/// A bounded, immutable copy of the exact raw text offered for quoting.
public struct ChatQuoteSource: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, Equatable {
        case message
        case document
    }

    public static let maximumUTF8Bytes = 1_024 * 1_024

    public let kind: Kind
    public let id: UUID
    public let version: String
    public let text: String
    public let sha256: String

    public init(kind: Kind, id: UUID, version: String, text: String) throws {
        guard text.utf8.count <= Self.maximumUTF8Bytes else {
            throw ChatQuoteSelectionError.sourceTooLarge
        }
        self.kind = kind
        self.id = id
        self.version = version
        self.text = text
        sha256 = Self.digest(text)
    }

    private enum CodingKeys: String, CodingKey { case kind, id, version, text, sha256 }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try values.decode(Kind.self, forKey: .kind)
        let id = try values.decode(UUID.self, forKey: .id)
        let version = try values.decode(String.self, forKey: .version)
        let text = try values.decode(String.self, forKey: .text)
        let recordedDigest = try values.decode(String.self, forKey: .sha256)
        try self.init(kind: kind, id: id, version: version, text: text)
        guard recordedDigest == sha256 else { throw ChatQuoteSelectionError.sourceChanged }
    }

    private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// UTF-16 coordinates belong to one exact version and digest of a message or document.
public struct ChatQuoteSelection: Codable, Sendable, Equatable {
    public static let maximumUTF8Bytes = 64 * 1_024

    public let sourceKind: ChatQuoteSource.Kind
    public let sourceID: UUID
    public let sourceVersion: String
    public let sourceSHA256: String
    public let utf16Location: Int
    public let utf16Length: Int
    public let text: String

    public var range: NSRange { NSRange(location: utf16Location, length: utf16Length) }

    public init(source: ChatQuoteSource, range: NSRange) throws {
        // TextRewriteSelection enforces the same AppKit UTF-16 and Swift Character
        // boundary rules used by the existing source excerpt workflow.
        let document = try TextDraftDocument(id: source.id, text: source.text)
        let selected: TextRewriteSelection
        do {
            selected = try TextRewriteSelection(document: document, range: range)
        } catch {
            throw ChatQuoteSelectionError.invalidRange
        }
        guard selected.selectedText.utf8.count <= Self.maximumUTF8Bytes else {
            throw ChatQuoteSelectionError.selectionTooLarge
        }
        sourceKind = source.kind
        sourceID = source.id
        sourceVersion = source.version
        sourceSHA256 = source.sha256
        utf16Location = range.location
        utf16Length = range.length
        text = selected.selectedText
    }

    public func validate(against source: ChatQuoteSource) throws {
        guard sourceKind == source.kind, sourceID == source.id,
              sourceVersion == source.version, sourceSHA256 == source.sha256 else {
            throw ChatQuoteSelectionError.sourceChanged
        }
        let actual: ChatQuoteSelection
        do {
            actual = try ChatQuoteSelection(source: source, range: range)
        } catch {
            throw ChatQuoteSelectionError.sourceChanged
        }
        guard text.utf8.elementsEqual(actual.text.utf8) else {
            throw ChatQuoteSelectionError.sourceChanged
        }
    }
}

/// One publication identity per exact selection, including its source and range.
/// A retry retains its identity; selecting equal text at another location does not.
public struct ChatQuotePublication: Sendable {
    private var selection: ChatQuoteSelection?
    private var assetID = UUID()
    public init() {}
    public mutating func id(for value: ChatQuoteSelection) -> UUID {
        if selection != value { selection = value; assetID = UUID() }
        return assetID
    }
}
