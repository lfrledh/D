import Foundation

/// Project-owned source interpretation. Search indexes are disposable projections.
public struct ChatKnowledgeDocument: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID { material.reference.assetID }
    public let material: ChatAttachment
    public init(material: ChatAttachment) { self.material = material }

    public func extraction() throws -> DocumentTextExtraction {
        guard let text = material.textSnapshot else { throw WorkflowIssue("资料缺少已保存的文字解释。") }
        if let metadata = material.documentSnapshot {
            try metadata.validate(reference: material.reference, text: text)
            return .init(text: text, sourceSHA256: metadata.sourceSHA256, format: metadata.format,
                parserVersion: metadata.parserVersion,
                locations: metadata.locations.map { .init(page: $0.page, line: $0.line,
                    range: NSRange(location: $0.utf16Offset, length: $0.utf16Length)) }, warnings: metadata.warnings)
        }
        guard material.reference.kind == .text else { throw WorkflowIssue("资料格式缺少解释版本。") }
        var locations: [DocumentTextLocation] = [], offset = 0
        let ns = text as NSString
        // Preserve exact UTF-16 line boundaries; no text normalization.
        while offset < ns.length {
            var start = 0, end = 0, contents = 0
            ns.getLineStart(&start, end: &end, contentsEnd: &contents, for: NSRange(location: offset, length: 0))
            locations.append(.init(page: nil, line: locations.count + 1,
                range: NSRange(location: start, length: contents - start)))
            offset = end
        }
        return .init(text: text, sourceSHA256: material.reference.sha256, format: "plain-text",
            parserVersion: "utf8-lines-v1", locations: locations, warnings: [])
    }
}

/// Exact excerpts selected for a future call, later retained on that attempt.
public struct ChatKnowledgeExcerpt: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let source: WorkflowAssetReference
    public let name: String
    public let text: String
    public let utf16Offset: Int
    public let utf16Length: Int
    public let page: Int?
    public let line: Int?
    public init(id: UUID = UUID(), source: WorkflowAssetReference, name: String, text: String,
                utf16Offset: Int, utf16Length: Int, page: Int?, line: Int?) {
        self.id = id; self.source = source; self.name = name; self.text = text
        self.utf16Offset = utf16Offset; self.utf16Length = utf16Length; self.page = page; self.line = line
    }
    public func validate() throws {
        guard [.text, .document].contains(source.kind), !name.isEmpty, name.utf8.count <= 512,
              !text.isEmpty, text.utf8.count <= 65_536, utf16Offset >= 0,
              utf16Length == text.utf16.count, utf16Length <= Int.max - utf16Offset,
              page == nil || page! > 0, line == nil || line! > 0 else {
            throw WorkflowIssue("资料引用内容或位置无效。")
        }
    }
    public var promptText: String {
        let position = page.map { "page \($0)" } ?? line.map { "line \($0)" } ?? "UTF-16 \(utf16Offset)"
        return "[Source \(id.uuidString): \(name), \(position); asset \(source.assetID), version \(source.version)]\n\(text)\n[/Source]"
    }
}

public struct ChatKnowledgeSearchResult: Sendable {
    public let excerpts: [ChatKnowledgeExcerpt]
    /// Failed current sources were excluded from this query, not served from cache.
    public let issues: [String]
}
