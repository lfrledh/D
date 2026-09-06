import Foundation
import Tokenizers
import Core

/// A wrapper that makes Transformers' Tokenizer conform to our Core.Tokenizer protocol.
public final class TransformersTokenizer: @unchecked Sendable, Core.Tokenizer {
    private let tokenizer: any Tokenizers.Tokenizer

    public init(tokenizer: any Tokenizers.Tokenizer) {
        self.tokenizer = tokenizer
    }

    public func encode(text: String) -> [Int] {
        return tokenizer.encode(text: text)
    }

    public func decode(tokens: [Int]) -> String {
        return tokenizer.decode(tokens: tokens)
    }

    public var eosTokenId: Int? {
        return tokenizer.eosTokenId
    }

    public func applyChatTemplate(messages: [[String: String]]) throws -> [Int] {
        // Transformers.Tokenizer expects messages as [[String: any Sendable]], but we have [[String: String]]
        // Convert to the required format.
        let sendableMessages = messages.map { dict in
            dict.mapValues { $0 as any Sendable }
        }
        return try tokenizer.applyChatTemplate(messages: sendableMessages)
    }
}
