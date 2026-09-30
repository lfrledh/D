import DInference
import Foundation

/// A versioned response asset in the existing Store, not a second conversation history.
/// The budget bounds application parsing/storage, not the model context or maxTokens.
enum WorkflowTextResponseFile {
    static let mediaType = "application/vnd.d.text-response+json"
    static let maximumBytes = 64 * 1_024 * 1_024
    private struct Envelope: Codable { let version: Int; let response: TextResponse }
    static func encode(_ response: TextResponse) throws -> Data {
        let bytes = try JSONEncoder().encode(Envelope(version: 1, response: response))
        guard bytes.count <= maximumBytes else { throw WorkflowIssue("完整模型响应超过 64 MiB 应用资产预算；未截断响应。") }
        return bytes
    }
    static func decode(_ bytes: Data) throws -> TextResponse {
        guard bytes.count <= maximumBytes else { throw WorkflowIssue("模型响应超过解析预算。") }
        let envelope = try JSONDecoder().decode(Envelope.self, from: bytes)
        guard envelope.version == 1 else { throw WorkflowIssue("模型响应文件版本暂不支持。") }
        return envelope.response
    }
}
