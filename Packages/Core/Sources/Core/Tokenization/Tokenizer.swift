import Foundation

/// A protocol that all tokenizers must conform to.
public protocol Tokenizer: Sendable {
    func encode(text: String) -> [Int]
    func decode(tokens: [Int]) -> String
    var eosTokenId: Int? { get }
    /// Applies the chat template to format messages for model input.
    /// Default implementation throws `TokenizerError.chatTemplateNotSupported`.
    func applyChatTemplate(messages: [[String: String]]) throws -> [Int]
}

public extension Tokenizer {
    func applyChatTemplate(messages: [[String: String]]) throws -> [Int] {
        throw TokenizerError.chatTemplateNotSupported
    }
}

/// Errors that can occur during tokenizer operations.
public enum TokenizerError: Error, LocalizedError {
    case chatTemplateNotSupported
    case chatTemplateFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .chatTemplateNotSupported:
            return "This tokenizer does not support chat templating."
        case .chatTemplateFailed(let reason):
            return "Chat template failed: \(reason)"
        }
    }
}
