import Foundation

/// Frozen interpretation; original bytes remain in the asset Store, never in this text.
public struct ChatDocumentSnapshot: Codable, Sendable, Equatable {
    public struct Location: Codable, Sendable, Equatable {
        public let page: Int?
        public let line: Int?
        public let utf16Offset: Int
        public let utf16Length: Int
    }
    public let sourceSHA256: String
    public let format: String
    public let parserVersion: String
    public let ocrRequested: Bool
    public let locations: [Location]
    public let warnings: [String]

    public init(extraction: DocumentTextExtraction, ocrRequested: Bool) {
        sourceSHA256 = extraction.sourceSHA256; format = extraction.format
        parserVersion = extraction.parserVersion; self.ocrRequested = ocrRequested
        locations = extraction.locations.map { .init(page: $0.page, line: $0.line,
            utf16Offset: $0.range.location, utf16Length: $0.range.length) }
        warnings = extraction.warnings
    }
    public func validate(reference: WorkflowAssetReference, text: String) throws {
        guard sourceSHA256 == reference.sha256, ["pdf", "docx"].contains(format),
              !parserVersion.isEmpty, parserVersion.utf8.count <= 256,
              warnings.count <= 1000, warnings.allSatisfy({ $0.utf8.count <= 4096 }) else {
            throw WorkflowIssue("文档解释来源或版本无效。")
        }
        let length = text.utf16.count
        guard locations.count <= length + 1 else { throw WorkflowIssue("文档位置数量超出正文范围。") }
        for position in locations {
            guard position.utf16Offset >= 0, position.utf16Length >= 0,
                  position.utf16Offset <= length,
                  position.utf16Length <= length - position.utf16Offset,
                  Range(NSRange(location: position.utf16Offset, length: position.utf16Length), in: text) != nil,
                  position.page == nil || position.page! > 0, position.line == nil || position.line! > 0 else {
                throw WorkflowIssue("文档解释位置无效。")
            }
        }
    }
}
