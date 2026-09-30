import DInference
import Foundation
import Testing

@Suite("External video execution profile values")
struct ExternalVideoExecutionProfileTests {
    @Test("Quantized LTX test identity cannot be substituted for the full recipe")
    func quantizedIdentity() throws {
        let value = ltxRequest(profile: .ltx23Q8GemmaQ4)
        try ExternalVideoExecutionProfile.ltx23Q8GemmaQ4.validate(value)
        #expect(throws: InferenceFailure.self) {
            try ExternalVideoExecutionProfile.ltx23BF16Full.validate(value)
        }
        #expect(try JSONDecoder().decode(VideoRequest.self, from: JSONEncoder().encode(value)) == value)
    }
    private let unicodePrompt = "镜头 🌅 e\u{301}"

    private func request(
        profile: ExternalVideoExecutionProfile = .h3BF16Full,
        options: VideoAdapterOptions? = .h3(streamWeights: false),
        prompt: String = "镜头 🌅 e\u{301}",
        negativePrompt: String = "",
        width: Int = 768,
        height: Int = 1344,
        frames: Int = 22,
        rate: VideoFrameRate = .init(numerator: 24),
        steps: Int = 2,
        guidance: Float = 1,
        shift: Float = 1,
        seed: UInt64 = .max,
        revision: Int = 1
    ) -> VideoRequest {
        VideoRequest(
            prompt: prompt, negativePrompt: negativePrompt,
            width: width, height: height, frameCount: frames,
            frameRate: rate, steps: steps, guidanceScale: guidance,
            scheduleShift: shift, seed: seed,
            executionProfile: .init(identifier: profile.rawValue, revision: revision),
            adapterOptions: options)
    }

    /// Every LTX rejection starts from this valid request; overrides change one input.
    private func ltxRequest(
        profile: ExternalVideoExecutionProfile,
        options: VideoAdapterOptions? = .ltx(streamWeights: false, spatiotemporalGuidance: 0),
        width: Int = 64,
        height: Int = 64,
        frames: Int = 9,
        rate: VideoFrameRate = .init(numerator: 24),
        steps: Int = 2,
        guidance: Float = 1,
        shift: Float = 1,
        seed: UInt64 = 42,
        revision: Int = 1
    ) -> VideoRequest {
        request(profile: profile, options: options, width: width, height: height,
                frames: frames, rate: rate, steps: steps, guidance: guidance,
                shift: shift, seed: seed, revision: revision)
    }

    @Test("Legacy JSON has no adapter field and preserves the Wan request")
    func legacyJSON() throws {
        let old = VideoRequest(
            prompt: unicodePrompt, negativePrompt: "", width: 832, height: 480,
            frameCount: 17, frameRate: .init(numerator: 16), steps: 50,
            guidanceScale: 6, scheduleShift: 8, seed: 42,
            executionProfile: VideoExecutionCapability.wan21.profile)
        let encoded = try JSONEncoder().encode(old)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["adapterOptions"] == nil)
        let restored = try JSONDecoder().decode(VideoRequest.self, from: encoded)
        #expect(restored == old)
        #expect(restored.adapterOptions == nil)
        try VideoExecutionCapability.wan21.validate(restored)
    }

    @Test("Wan rejects foreign adapter options instead of silently ignoring them")
    func wanRejectsForeignOptions() throws {
        for option in [VideoAdapterOptions.h3(streamWeights: true),
                       .ltx(streamWeights: false, spatiotemporalGuidance: 1)] {
            let value = VideoRequest(prompt: "valid", negativePrompt: "", width: 256, height: 256,
                frameCount: 17, frameRate: .init(numerator: 16), steps: 4,
                guidanceScale: 5, scheduleShift: 5, seed: 42,
                executionProfile: VideoExecutionCapability.wan21.profile, adapterOptions: option)
            try value.validate()
            #expect(throws: InferenceFailure.self) { try VideoExecutionCapability.wan21.validate(value) }
        }
    }

    @Test("Typed options round-trip, and streaming changes only its own value")
    func optionsRoundTrip() throws {
        for profile in ExternalVideoExecutionProfile.allCases {
            let offOptions: VideoAdapterOptions = profile == .h3BF16Full
                ? .h3(streamWeights: false)
                : .ltx(streamWeights: false, spatiotemporalGuidance: 0.75)
            let onOptions: VideoAdapterOptions = profile == .h3BF16Full
                ? .h3(streamWeights: true)
                : .ltx(streamWeights: true, spatiotemporalGuidance: 0.75)
            let off = request(profile: profile, options: offOptions, width: 32, height: 32,
                              frames: profile == .h3BF16Full ? 22 : 9,
                              seed: 42)
            let on = request(profile: profile, options: onOptions, width: 32, height: 32,
                             frames: profile == .h3BF16Full ? 22 : 9,
                             seed: 42)
            try profile.validate(off)
            try profile.validate(on)
            #expect(try JSONDecoder().decode(VideoRequest.self, from: JSONEncoder().encode(off)) == off)
            #expect(try JSONDecoder().decode(VideoRequest.self, from: JSONEncoder().encode(on)) == on)
            #expect(on.prompt == unicodePrompt)
            #expect(on.prompt == off.prompt)
            #expect(on.seed == off.seed)
            #expect(on.width == off.width && on.height == off.height)
            #expect(on.frameCount == off.frameCount && on.frameRate == off.frameRate)
            #expect(on.steps == off.steps && on.executionProfile == off.executionProfile)
            #expect(on.guidanceScale == off.guidanceScale && on.scheduleShift == off.scheduleShift)
        }
    }

    @Test("Profile identities are frozen at revision one")
    func identities() {
        #expect(ExternalVideoExecutionProfile.allCases.map(\.rawValue) == [
            "minimax-h3-fl2va-bf16-full-v1",
            "ltx-2.3-dev-bf16-full-v1",
            "ltx-2.5-dev-bf16-full-v1",
        ])
        for profile in ExternalVideoExecutionProfile.allCases {
            #expect(profile.reference == ExecutionProfileReference(identifier: profile.rawValue, revision: 1))
        }
    }

    @Test("H3 accepts exact recipe edges without a hardware memory cap")
    func h3Edges() throws {
        try ExternalVideoExecutionProfile.h3BF16Full.validate(request())
        try ExternalVideoExecutionProfile.h3BF16Full.validate(
            request(width: 32, height: 32, frames: 362,
                    rate: .init(numerator: 48, denominator: 2), steps: 1000))
        #expect(request().seed == UInt64.max)
    }

    @Test("H3 rejects off-recipe geometry, time, controls and negative prompts")
    func h3Rejections() {
        let invalid = [
            request(width: 31), request(height: 1345),
            request(width: 1024, height: 1024),
            request(frames: 21), request(frames: 23), request(frames: 363),
            request(rate: .init(numerator: 24_000, denominator: 1001)),
            request(steps: 1), request(steps: 1001),
            request(negativePrompt: " "),
            request(guidance: 1.01), request(shift: 1.01),
            request(options: nil),
            request(options: .ltx(streamWeights: false, spatiotemporalGuidance: 0)),
            request(revision: 2),
        ]
        for value in invalid {
            #expect(throws: InferenceFailure.self) {
                try ExternalVideoExecutionProfile.h3BF16Full.validate(value)
            }
        }
    }

    @Test("Both LTX dev recipes accept positive rational fps and large full-size values")
    func ltxEdges() throws {
        for profile in [ExternalVideoExecutionProfile.ltx23BF16Full, .ltx25BF16Full] {
            try profile.validate(request(
                profile: profile, options: .ltx(streamWeights: false, spatiotemporalGuidance: 0),
                width: 32, height: 32, frames: 1,
                rate: .init(numerator: 1, denominator: 1001), steps: 1, seed: 0))
            try profile.validate(request(
                profile: profile, options: .ltx(streamWeights: true, spatiotemporalGuidance: 2.5),
                width: 1024, height: 1024, frames: 17,
                rate: .init(numerator: 30_000, denominator: 1001), steps: 50,
                guidance: 4.5, seed: UInt64(UInt32.max)))
        }
    }

    @Test("LTX rejects wrong options, revisions, seeds, strides and nonfinite STG")
    func ltxRejections() throws {
        for profile in [ExternalVideoExecutionProfile.ltx23BF16Full, .ltx25BF16Full] {
            let baseline = ltxRequest(profile: profile)
            try baseline.validate()
            try profile.validate(baseline)

            let invalid = [
                ltxRequest(profile: profile, options: nil),
                ltxRequest(profile: profile, options: .h3(streamWeights: false)),
                ltxRequest(profile: profile, revision: 2),
                ltxRequest(profile: profile, width: 31),
                ltxRequest(profile: profile, height: 33),
                ltxRequest(profile: profile, frames: 0),
                ltxRequest(profile: profile, frames: 10),
                ltxRequest(profile: profile, steps: 0),
                ltxRequest(profile: profile, rate: .init(numerator: 0)),
                ltxRequest(profile: profile, seed: UInt64(UInt32.max) + 1),
                ltxRequest(profile: profile, shift: 2),
                ltxRequest(profile: profile, guidance: .nan),
                ltxRequest(profile: profile, options: .ltx(streamWeights: false, spatiotemporalGuidance: -.infinity)),
                ltxRequest(profile: profile, options: .ltx(streamWeights: false, spatiotemporalGuidance: .nan)),
                ltxRequest(profile: profile, options: .ltx(streamWeights: false, spatiotemporalGuidance: -0.1)),
                ltxRequest(profile: profile, width: Int.max - 31),
            ]
            for value in invalid {
                #expect(throws: InferenceFailure.self) { try profile.validate(value) }
            }

            let otherProfile: ExternalVideoExecutionProfile = profile == .ltx23BF16Full
                ? .ltx25BF16Full : .ltx23BF16Full
            let mismatched = ltxRequest(profile: otherProfile)
            try otherProfile.validate(mismatched)
            #expect(throws: InferenceFailure.self) { try profile.validate(mismatched) }
        }
    }

    @Test("Common validation rejects nonfinite STG but leaves legacy and H3 values intact")
    func commonSTG() throws {
        try request(options: nil).validate()
        try request(options: .h3(streamWeights: true)).validate()
        #expect(throws: InferenceFailure.self) {
            try request(options: .ltx(streamWeights: true, spatiotemporalGuidance: .infinity)).validate()
        }
    }
}
