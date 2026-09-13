import DInference
import Foundation
import Testing

@Suite("Video request snapshots")
struct VideoRequestTests {
    private func request(width: Int = 832, height: Int = 480, frames: Int = 17,
                         rate: VideoFrameRate = .init(numerator: 16),
                         steps: Int = 50, guidance: Float = 6, shift: Float = 8,
                         prompt: String = "镜头 slowly moves 🌅 e\u{301}", seed: UInt64 = 42) -> VideoRequest {
        VideoRequest(prompt: prompt, negativePrompt: "", width: width, height: height,
                     frameCount: frames, frameRate: rate, steps: steps,
                     guidanceScale: guidance, scheduleShift: shift, seed: seed,
                     executionProfile: .init(identifier: "candidate-wan21", revision: 1))
    }

    @Test func snapshotPreservesUnicodeSeedAndRationalRate() throws {
        let value = request(rate: .init(numerator: 30_000, denominator: 1_001), seed: .max)
        try value.validate()
        let restored = try JSONDecoder().decode(VideoRequest.self, from: JSONEncoder().encode(value))
        #expect(restored == value)
        #expect(restored.seed == UInt64.max)
        #expect(restored.negativePrompt.isEmpty)
        #expect(restored.frameRate.denominator == 1_001)
    }

    @Test func modelAndHardwareLimitsAreNotCommonRequestLimits() throws {
        // Common representation is not an execution claim. An actual adapter must
        // check its own supported dimensions, frame stride, token budget and seed.
        try request(width: 3840, height: 2160, frames: 241).validate()
        try request(width: 64, height: 64, frames: 2).validate()
        try request(frames: 1).validate()
    }

    @Test func invalidDimensionsAndOverflowFailWithoutAllocation() {
        for value in [request(width: 0), request(height: -1), request(frames: 0),
                      request(width: .max), request(width: .max / 2, height: 2),
                      request(frames: .max), request(width: 1, height: 1, frames: .max,
                                                   rate: .init(numerator: 1, denominator: .max))] {
            #expect(throws: (any Error).self) { try value.validate() }
        }
    }

    @Test func invalidTimesAndNonfiniteParametersAreNotDefaulted() {
        for value in [request(rate: .init(numerator: 0)), request(rate: .init(numerator: 1, denominator: -1)),
                      request(steps: 0), request(guidance: .nan), request(guidance: .infinity),
                      request(guidance: -1), request(shift: 0), request(shift: .infinity),
                      request(prompt: " \n\t ")] {
            #expect(throws: (any Error).self) { try value.validate() }
        }
    }

    @Test func malformedSerializedTypesDoNotBecomeValidRequests() throws {
        let encoded = try JSONEncoder().encode(request())
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["frameCount"] = true
        let malformed = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(VideoRequest.self, from: malformed) }
    }
}
