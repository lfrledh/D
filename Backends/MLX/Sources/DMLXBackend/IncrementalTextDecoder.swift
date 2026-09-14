import DInference
import Foundation

/// Converts cumulative tokenizer output into append-only, byte-preserving deltas.
/// A later token may extend an already emitted grapheme with a combining scalar or ZWJ.
/// Comparing Character counts loses those scalars. Tokenizer prefix rewrites cannot be
/// represented by textDelta and must fail rather than silently corrupt the answer.
struct IncrementalTextDecoder {
    private var emitted = [UInt8]()

    mutating func consume(_ decoded: String, final: Bool = false) throws -> String? {
        // A partial UTF-8 token commonly decodes to a trailing replacement scalar.
        // Wait for the next token; at completion deliver the tokenizer's actual final
        // decoding (which may intentionally contain U+FFFD), without inventing text.
        if !final, decoded.unicodeScalars.last == "\u{fffd}" { return nil }
        let bytes = Array(decoded.utf8)
        guard bytes.starts(with: emitted),
              let delta = String(bytes: bytes.dropFirst(emitted.count), encoding: .utf8) else {
            throw InferenceFailure.backendFailed("Tokenizer rewrote already delivered text; generation cannot safely continue.")
        }
        emitted = bytes
        return delta.isEmpty ? nil : delta
    }
}
