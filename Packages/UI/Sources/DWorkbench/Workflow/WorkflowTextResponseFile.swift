import DInference
import Foundation

/// Terminal execution facts are separate from parsed channels and disk state.
/// Optional fields on existing records keep old projects readable.
public struct WorkflowLanguageEnd: Codable, Sendable, Equatable {
    public enum Cause: String, Codable, Sendable { case completed, length, stopped, executionError, invalidOutput, inputIntegrity, cleanupUnconfirmed, unknown }
    public let cause: Cause
    public let diagnostic: String?
    public init(_ cause: Cause, diagnostic: String? = nil) { self.cause = cause; self.diagnostic = diagnostic }
    public var interrupted: Bool { cause != .completed }
    public var inspectionOnly: Bool { cause == .inputIntegrity || cause == .cleanupUnconfirmed }
    public func noticeKey(reasoningOnly: Bool = false) -> String {
        let suffix = reasoningOnly ? "Reasoning" : ""
        switch cause {
        case .length: return "partial.length" + suffix
        case .stopped: return "partial.stopped" + suffix
        case .executionError: return "partial.interrupted" + suffix
        case .invalidOutput: return "partial.validation"
        case .inputIntegrity: return "partial.integrity"
        case .cleanupUnconfirmed: return "partial.cleanup"
        case .unknown: return "partial.unknown"
        case .completed: return "partial.contract"
        }
    }
}

/// One terminal handoff, scoped by the caller's exact step/attempt ID. Raw-only
/// content is deliberately not promoted to a parsed answer or a tool request.
public struct WorkflowLanguageContent: Codable, Sendable, Equatable {
    public let rawText: String
    public let response: TextResponse?
    public let end: WorkflowLanguageEnd?
    public init(rawText: String, response: TextResponse? = nil, end: WorkflowLanguageEnd? = nil) {
        self.rawText = rawText; self.response = response; self.end = end
    }
    public var reasoningOnly: Bool { response?.finalText?.isEmpty != false && response?.reasoningText?.isEmpty == false }
}

/// Version 1 remains readable. Version 2 also carries unparsed accepted prefixes.
/// Long content stays in the existing asset, not duplicated in workflow history.
enum WorkflowTextResponseFile {
    static let mediaType = "application/vnd.d.text-response+json"
    static let maximumBytes = 64 * 1_024 * 1_024
    private struct Envelope: Codable {
        let version: Int
        let response: TextResponse?
        let rawText: String?
        let end: WorkflowLanguageEnd?
    }
    static func encode(_ response: TextResponse) throws -> Data {
        try encoded(Envelope(version: 1, response: response, rawText: nil, end: nil))
    }
    static func encode(_ content: WorkflowLanguageContent) throws -> Data {
        // Parsed responses already own their raw bytes; never encode them twice.
        try encoded(Envelope(version: 2, response: content.response,
            rawText: content.response == nil ? content.rawText : nil, end: content.end))
    }
    private static func encoded(_ envelope: Envelope) throws -> Data {
        let bytes = try JSONEncoder().encode(envelope)
        guard bytes.count <= maximumBytes else { throw WorkflowIssue("完整模型响应超过 64 MiB 应用资产预算；未截断响应。") }
        return bytes
    }
    static func decodeContent(_ bytes: Data) throws -> WorkflowLanguageContent {
        guard bytes.count <= maximumBytes else { throw WorkflowIssue("模型响应超过解析预算。") }
        let envelope = try JSONDecoder().decode(Envelope.self, from: bytes)
        guard [1, 2].contains(envelope.version),
              let raw = envelope.response?.rawText ?? envelope.rawText,
              envelope.rawText == nil || envelope.response == nil else { throw WorkflowIssue("模型响应文件版本或内容无效。") }
        return .init(rawText: raw, response: envelope.response, end: envelope.end)
    }
    static func decode(_ bytes: Data) throws -> TextResponse {
        guard let response = try decodeContent(bytes).response else { throw WorkflowIssue("原始内容尚未分离为正文或思考。") }
        return response
    }
}
