import CoreImage
import CoreMedia
import Foundation
import MLX
import MLXLMCommon
import Testing
@testable import MLXVLM

extension MLXHardwareTests {
@Suite("Qwen timestamped temporal patches", .serialized)
struct QwenVideoPositionTests {
    private struct Tokens: MLXLMCommon.Tokenizer {
        let videos: Int
        let specials = ["<|vision_start|>", "<|vision_end|>", "<|video_pad|>", "<|image_pad|>"]
        func encode(text: String, addSpecialTokens: Bool) -> [Int] {
            var text = text[...], result: [Int] = []
            while !text.isEmpty {
                if let index = specials.firstIndex(where: { text.hasPrefix($0) }) {
                    result.append(index + 1); text = text.dropFirst(specials[index].count)
                } else {
                    result.append(Int(text.unicodeScalars.first!.value) + 100)
                    text = text.dropFirst()
                }
            }
            return result
        }
        func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
            tokenIds.map { $0 < 100 ? specials[$0 - 1] : String(UnicodeScalar($0 - 100)!) }.joined()
        }
        func convertTokenToId(_ token: String) -> Int? { specials.firstIndex(of: token).map { $0 + 1 } }
        func convertIdToToken(_ id: Int) -> String? { (1...4).contains(id) ? specials[id - 1] : nil }
        var bosToken: String? { nil }; var eosToken: String? { nil }; var eosTokenId: Int? { nil }
        var unknownToken: String? { nil }; var unknownTokenId: Int? { nil }
        func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                               additionalContext: [String: any Sendable]?) throws -> [Int] {
            encode(text: "prefix" + String(repeating: "<|vision_start|><|video_pad|><|vision_end|>", count: videos) + "suffix", addSpecialTokens: false)
        }
    }

    @Test func processorPreservesTwoVideosOddPaddingAndOrder() async throws {
        let config = try JSONDecoder().decode(Qwen3VLProcessorConfiguration.self, from: Data("""
        {"image_mean":[0,0,0],"image_std":[1,1,1],"min_pixels":4096,"max_pixels":4096,
         "merge_size":2,"patch_size":16,"temporal_patch_size":2,"image_processor_type":"Qwen2VLImageProcessorFast"}
        """.utf8))
        let tokens = Tokens(videos: 2)
        let processor = Qwen3VLProcessor(config, tokenizer: tokens, preserveSuppliedVideoFrames: true)
        func clip(_ values: [Double], reversed: Bool = false) -> UserInput.Video {
            .frames(values.enumerated().map { index, time in
                let red = (index < 2) != reversed
                return .init(frame: CIImage(color: red ? .red : .blue)
                    .cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64)),
                    timeStamp: CMTime(seconds: time, preferredTimescale: 600))
            })
        }
        let input = try await processor.prepare(input: UserInput(prompt: "order",
            videos: [clip([0, 0.5, 1, 1.5]), clip([3, 3.5, 4], reversed: true)]))
        let prompt = tokens.decode(tokenIds: input.text.tokens.asArray(Int.self), skipSpecialTokens: false)
        let block = "<|vision_start|>" + String(repeating: "<|video_pad|>", count: 4) + "<|vision_end|>"
        #expect(prompt == "prefix<0.2 seconds>" + block + "<1.2 seconds>" + block
            + "<3.2 seconds>" + block + "<4.0 seconds>" + block + "suffix")
        let video = try #require(input.video)
        let grids = try #require(video.frames)
        #expect(grids.map { [$0.t, $0.h, $0.w] } == [[2,4,4], [2,4,4]])
        // Each group of 16 spatial patches still contains consecutive red/red or
        // blue/blue frames. Reversing the second clip reverses these groups.
        let pixels = video.pixels.asArray(Float.self)
        let patchWidth = 3 * 2 * 16 * 16
        #expect(video.pixels.shape == [64, patchWidth])
        for (group, red) in [true, false, false, true].enumerated() {
            let start = group * 16 * patchWidth
            let r = pixels[start], b = pixels[start + 2 * 2 * 16 * 16]
            #expect(red ? r > b : b > r)
        }
        // CoreImage's sRGB resampling returns 0.99999994 for unit primaries.
        // Verify all tensor elements of repeated/odd-padded groups exactly, not
        // equality to an unprocessed RGB literal or a relaxed model tolerance.
        let groupSize = 16 * patchWidth
        #expect(Array(pixels[0..<groupSize]) == Array(pixels[3*groupSize..<4*groupSize]))
        #expect(Array(pixels[groupSize..<2*groupSize]) == Array(pixels[2*groupSize..<3*groupSize]))
    }

    @Test func temporalRopeMatchesOfficialSplitGridReference() {
        // Hand-derived from transformers@a005fc82 Qwen3_5Model.get_rope_index.
        // TS values stand for ordinary timestamp tokens, not visual features.
        let ids = MLXArray([9,8,1,3,3,3,3,2,7,1,3,3,3,3,2,6]).reshaped([1,16])
        let (positions, delta) = Qwen3VLLanguage.getRopeIndex(inputIds: ids,
            imageGridTHW: nil, videoGridTHW: [THW(2,4,4)], spatialMergeSize: 2,
            imageTokenId: 4, videoTokenId: 3, visionStartTokenId: 1)
        #expect(positions.asArray(Int.self) == [
            0,1,2,3,3,3,3,5,6,7,8,8,8,8,10,11,
            0,1,2,3,3,4,4,5,6,7,8,8,9,9,10,11,
            0,1,2,3,4,3,4,5,6,7,8,9,8,9,10,11])
        #expect(delta.asArray(Int.self) == [-4])
        let imageIDs = MLXArray([9,1,4,4,4,4,2,6]).reshaped([1,8])
        let (imagePositions, imageDelta) = Qwen3VLLanguage.getRopeIndex(inputIds: imageIDs,
            imageGridTHW: [THW(1,4,4)], videoGridTHW: nil, spatialMergeSize: 2,
            imageTokenId: 4, videoTokenId: 3, visionStartTokenId: 1)
        #expect(imagePositions.asArray(Int.self) == [0,1,2,2,2,2,4,5, 0,1,2,2,3,3,4,5, 0,1,2,3,2,3,4,5])
        #expect(imageDelta.asArray(Int.self) == [-2])
    }

    @Test func invalidTemporalMetadataCannotSilentlyDropConditions() throws {
        let tokens = Tokens(videos: 1), input = tokens.encode(text: "<|vision_start|><|video_pad|><|vision_end|>")
        for times in [[], [1,0], [.nan,1], [-1,0], [0,0.5,1,1.5,2]] as [[Double]] {
            #expect(throws: (any Error).self) {
                try Qwen3VLProcessor.replaceVideoPaddingTokens(in: input, frames: [THW(2,4,4)],
                    timestamps: [times], temporalPatchSize: 2, mergeSize: 2, tokenizer: tokens)
            }
        }
    }
}
}
