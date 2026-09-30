// Independent upstream reproduction; mirrors only the local tokenizer adapter.
import Foundation
import MLXLMCommon
import Tokenizers

/// Loads only an already-installed tokenizer. It cannot fall back to a Hub download.
struct LocalTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        guard directory.isFileURL, directory.path.hasPrefix("/") else {
            throw LocalTokenizerFailure.invalidTemplate("Tokenizer directory must be local.")
        }
        // The upstream local loader uses try? for optional template sidecars. Validate
        // the selected sidecar first so damage cannot fall back to an older template.
        for name in ["chat_template.jinja", "chat_template.json"] {
            let url = directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: url.path) { continue }
            let metadata = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard metadata.isRegularFile == true, metadata.isSymbolicLink != true,
                  let size = metadata.fileSize, size > 0, size <= 1_048_576 else {
                throw LocalTokenizerFailure.invalidTemplate("Invalid local chat template: " + name)
            }
            let data = try Data(contentsOf: url)
            let template: String?
            if name.hasSuffix(".jinja") { template = String(data: data, encoding: .utf8) }
            else { template = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["chat_template"] as? String }
            guard let template, !template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw LocalTokenizerFailure.invalidTemplate("Unreadable local chat template: " + name)
            }
            break // Same documented preference as the upstream loader: jinja before json.
        }
        let tokenizer = try await AutoTokenizer.from(modelFolder: directory)
        guard tokenizer.hasChatTemplate else {
            throw LocalTokenizerFailure.invalidTemplate("This profile requires a local chat template.")
        }
        return LocalTokenizer(base: tokenizer)
    }
}

private struct LocalTokenizer: MLXLMCommon.Tokenizer {
    let base: any Tokenizers.Tokenizer
    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        base.encode(text: text, addSpecialTokens: addSpecialTokens)
    }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        base.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }
    func convertTokenToId(_ token: String) -> Int? { base.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { base.convertIdToToken(id) }
    var bosToken: String? { base.bosToken }
    var eosToken: String? { base.eosToken }
    var unknownToken: String? { base.unknownToken }
    func applyChatTemplate(messages: [[String: any Sendable]],
                           tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        do {
            return try base.applyChatTemplate(messages: messages, tools: tools,
                                              additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw LocalTokenizerFailure.invalidTemplate("The selected chat template is unavailable.")
        }
    }
}

private enum LocalTokenizerFailure: LocalizedError {
    case invalidTemplate(String)
    var errorDescription: String? { switch self { case .invalidTemplate(let reason): reason } }
}
