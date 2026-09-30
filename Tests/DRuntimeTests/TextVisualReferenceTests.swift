import DInference
import Foundation
import Testing

@Suite("Text visual request contract")
struct TextVisualReferenceTests {
    private let source = URL(fileURLWithPath: "/tmp/visual.png")
    private let hash = String(repeating: "a", count: 64)

    @Test func legacyCodableAndProfileRejection() throws {
        let legacy = try JSONDecoder().decode(TextRequest.self, from: Data(
            """
            {"prompt":"old","maxTokens":2,"temperature":0.7,"topP":0.95,"execution":null}
            """.utf8))
        #expect(legacy.images == nil && legacy.video == nil && legacy.visualProcessing == nil)
        let request = TextRequest(prompt: "see", images: [TextImageReference(
            url: source, width: 10, height: 10, byteCount: 100, contentSHA256: hash)])
        let old = TextExecutionCapability(maximumPromptTokens: 2048, maximumOutputTokens: 256)
        #expect(throws: (any Error).self) { try old.validate(request) }
        let vlm = TextExecutionCapability(maximumPromptTokens: 32_768, maximumOutputTokens: 8_192,
                                          profile: TextExecutionCapability.qwen35VLMProfile)
        try vlm.validate(request)
        #expect(try JSONDecoder().decode(TextRequest.self, from: JSONEncoder().encode(request)) == request)
    }

    @Test func emptyImagesAndInvalidBoundsFail() {
        let vlm = TextExecutionCapability(maximumPromptTokens: 32_768, maximumOutputTokens: 8_192,
                                          profile: TextExecutionCapability.qwen35VLMProfile)
        #expect(throws: (any Error).self) { try vlm.validate(TextRequest(prompt: "x", images: [])) }
        #expect(throws: (any Error).self) { try TextVisualProcessing(minimumPixels: 200, maximumPixels: 100).validate() }
        #expect(throws: (any Error).self) { try TextVisualProcessing(videoSamplingFPS: 1).validate() }
        #expect(throws: (any Error).self) { try TextVideoReference(
            url: URL(fileURLWithPath: "/tmp/a.mp4"), byteCount: 10,
            contentSHA256: hash.uppercased(), durationSeconds: 2).validate() }
    }

    @Test func modelContextCeilingIsNotTheLegacyBackendLimit() throws {
        let vlm = TextExecutionCapability(maximumPromptTokens: 200_000, maximumOutputTokens: 50_000,
                                          profile: TextExecutionCapability.qwen35VLMProfile)
        try vlm.validate(TextRequest(prompt: "large", maxTokens: 50_000))
        #expect(try vlm.resolvedPromptTokens(for: TextRequest(prompt: "large")) == 200_000)
    }
}
