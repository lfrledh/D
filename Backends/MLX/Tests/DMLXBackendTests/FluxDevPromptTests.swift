import Foundation
import Flux2
import MLX
import Testing
import Tokenizers

@Suite("FLUX Dev complete prompt budget")
struct FluxDevPromptTests {
    @Test func completeTemplateRejectsOverflowAndKeepsLegacyDefault() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let tokenizer = try await AutoTokenizer.from(modelFolder: root
            .appendingPathComponent("Vendor/flux2-swift/fixtures/flux2_klein4b/tokenizer"))
        let processor = Flux2PixtralProcessor(tokenizer: tokenizer,
            padTokenId: try #require(tokenizer.eosTokenId), maxLength: 512,
            chatTemplate: .literal("{% for m in messages %}{{ m['role'] }}: {% for p in m['content'] %}{{ p['text'] }}{% endfor %}\n{% endfor %}"))
        let prompt = "A red cup beside a blue bottle"
        let full = try processor.encode(prompts: [prompt], systemMessage: "Follow the complete prompt", truncation: false)
        let count = Int(full.attentionMask.asArray(Int32.self).reduce(0, +))
        #expect(count > 1)
        let exact = try processor.encode(prompts: [prompt], systemMessage: "Follow the complete prompt", maxLength: count, truncation: false)
        #expect(exact.inputIds.shape == [1, count])
        do {
            _ = try processor.encode(prompts: [prompt], systemMessage: "Follow the complete prompt", maxLength: count - 1, truncation: false)
            Issue.record("An overlong complete template must fail")
        } catch Flux2PixtralProcessorError.tokenExpansionOverflow(let actual, let limit) {
            #expect(actual == count)
            #expect(limit == count - 1)
        }
        let legacy = try processor.encode(prompts: [prompt], systemMessage: "Follow the complete prompt", maxLength: count - 1)
        #expect(legacy.inputIds.asArray(Int32.self) == Array(exact.inputIds.asArray(Int32.self).prefix(count - 1)))
    }
}
