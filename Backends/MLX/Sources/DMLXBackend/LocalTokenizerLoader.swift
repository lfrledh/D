import Foundation
import Hub
import MLXLMCommon
import Tokenizers

/// Loads only an already-installed tokenizer. It cannot fall back to a Hub download.
struct LocalTokenizerLoader: MLXLMCommon.TokenizerLoader {
    let fileSet: LocalModelFileSet?

    init(fileSet: LocalModelFileSet? = nil) { self.fileSet = fileSet }

    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        guard directory.isFileURL, directory.path.hasPrefix("/") else {
            throw LocalTokenizerFailure.invalidTemplate("Tokenizer directory must be local.")
        }
        if let fileSet { return try loadFixed(from: directory, fileSet: fileSet) }
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

    private func loadFixed(from directory: URL, fileSet: LocalModelFileSet) throws -> any MLXLMCommon.Tokenizer {
        // The upstream folder API probes sidecars. Its config/data initializer performs
        // the same tokenization without observing undeclared neighboring files.
        let configURL = directory.appendingPathComponent("tokenizer_config.json")
        let tokenizerURL = directory.appendingPathComponent("tokenizer.json")
        var config = try parseConfig(configURL)
        let data = try parseConfig(tokenizerURL)
        let template: String?
        if fileSet.admits("chat_template.jinja") {
            let value = try String(contentsOf: directory.appendingPathComponent("chat_template.jinja"), encoding: .utf8)
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw LocalTokenizerFailure.invalidTemplate("Empty admitted chat_template.jinja.")
            }
            template = value
        } else if fileSet.admits("chat_template.json") {
            let value = try parseConfig(directory.appendingPathComponent("chat_template.json")).chatTemplate.string()
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw LocalTokenizerFailure.invalidTemplate("Invalid admitted chat_template.json.")
            }
            template = value
        } else {
            template = nil // The embedded tokenizer_config template retains its precedence.
        }
        if let template {
            guard var values = config.dictionary() else {
                throw LocalTokenizerFailure.invalidTemplate("Invalid tokenizer configuration.")
            }
            values["chat_template"] = Config(template)
            config = Config(values)
        }
        let tokenizer = try PreTrainedTokenizer(tokenizerConfig: config, tokenizerData: data, strict: true)
        guard tokenizer.hasChatTemplate else {
            throw LocalTokenizerFailure.invalidTemplate("This profile requires a local chat template.")
        }
        return LocalTokenizer(base: tokenizer)
    }

    private func parseConfig(_ url: URL) throws -> Config {
        let value = try HubApi.shared.configuration(fileURL: url)
        guard value.dictionary() != nil else {
            throw LocalTokenizerFailure.invalidTemplate("Invalid tokenizer JSON: \(url.lastPathComponent)")
        }
        return value
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
