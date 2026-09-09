import DInference
@testable import DMLXBackend
import Foundation
import Testing

@Suite("Image execution profiles (CPU metadata only)")
struct ImageExecutionProfileTests {
    struct Dimensions: Sendable {
        let width: Int
        let height: Int
    }

    struct Settings: Sendable {
        let width: Int
        let height: Int
        let steps: Int
        let guidance: Float
    }

    @Test("The verified profile declares the existing fixed contract")
    func verifiedDeclaration() {
        let profile = ImageExecutionProfile.verified512
        #expect(profile.identifier == "verified512")
        #expect(profile.minimumWidth == 512 && profile.maximumWidth == 512)
        #expect(profile.minimumHeight == 512 && profile.maximumHeight == 512)
        #expect(profile.dimensionMultiple == 32)
        #expect(profile.maximumPixelCount == 512 * 512)
        #expect(profile.steps == 4 && profile.guidanceScale == 1)
        #expect(profile.maximumTextTokens == 512)
    }

    @Test("Both profiles retain the same 512-square estimate")
    func sharedVerifiedEstimate() throws {
        let expected = UInt64(8 * 1024 * 1024 * 1024)
        #expect(try ImageExecutionProfile.verified512.estimatedPeakBytes(width: 512, height: 512) == expected)
        #expect(try ImageExecutionProfile.scalableKlein4B.estimatedPeakBytes(width: 512, height: 512) == expected)
    }

    @Test("The scalable profile accepts declared shape metadata", arguments: [
        Dimensions(width: 512, height: 256), Dimensions(width: 768, height: 512),
        Dimensions(width: 1024, height: 1024), Dimensions(width: 2048, height: 2048),
    ])
    func scalableShapes(dimensions: Dimensions) throws {
        try ImageExecutionProfile.scalableKlein4B.validate(
            request(width: dimensions.width, height: dimensions.height))
        #expect(try ImageExecutionProfile.scalableKlein4B.estimatedPeakBytes(
            width: dimensions.width, height: dimensions.height)
            >= UInt64(8 * 1024 * 1024 * 1024))
    }

    @Test("The scalable profile rejects invalid metadata", arguments: [
        Settings(width: 0, height: 512, steps: 4, guidance: 1),
        Settings(width: -32, height: 512, steps: 4, guidance: 1),
        Settings(width: 257, height: 512, steps: 4, guidance: 1),
        Settings(width: 512, height: 257, steps: 4, guidance: 1),
        Settings(width: 2080, height: 512, steps: 4, guidance: 1),
        Settings(width: 512, height: 2080, steps: 4, guidance: 1),
        Settings(width: 2048, height: 2048, steps: 5, guidance: 1),
        Settings(width: 2048, height: 2048, steps: 4, guidance: 2),
        Settings(width: 2048, height: 2048, steps: 4, guidance: .nan),
        Settings(width: Int.max, height: Int.max, steps: 4, guidance: 1),
    ])
    func invalidScalableMetadata(settings: Settings) {
        #expect(throws: InferenceFailure.self) {
            try ImageExecutionProfile.scalableKlein4B.validate(
                request(width: settings.width, height: settings.height,
                        steps: settings.steps, guidance: settings.guidance))
        }
    }

    @Test("Workspace estimates are monotonic by accepted pixel area")
    func monotonicEstimates() throws {
        let dimensions = [(512, 256), (512, 512), (768, 512), (1024, 1024), (2048, 2048)]
        let estimates = try dimensions.map {
            try ImageExecutionProfile.scalableKlein4B.estimatedPeakBytes(width: $0.0, height: $0.1)
        }
        #expect(zip(estimates, estimates.dropFirst()).allSatisfy { $0.0 <= $0.1 })
    }

    @Test("Default profile keeps every former rejection")
    func verifiedRejections() {
        for image in [
            request(width: 256, height: 512), request(width: 512, height: 768),
            request(width: 512, height: 512, steps: 5),
            request(width: 512, height: 512, guidance: 2),
            request(width: 512, height: 512, guidance: .nan),
        ] {
            #expect(throws: InferenceFailure.self) {
                try ImageExecutionProfile.verified512.validate(image)
            }
        }
    }

    @Test("Allocator limits use the estimate by default and permit an explicit ceiling")
    func allocatorLimits() throws {
        let estimated = UInt64(8 * 1024 * 1024 * 1024)
        let defaultConfiguration = MLXImageBackendConfiguration(
            artifactDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true))
        #expect(defaultConfiguration.profile == .verified512)
        #expect(try defaultConfiguration.allocatorMemoryLimit(estimatedPeakBytes: estimated) == Int(estimated))
        #expect(throws: InferenceFailure.self) {
            try defaultConfiguration.allocatorMemoryLimit(estimatedPeakBytes: UInt64.max)
        }

        let explicitLimit = 6 * 1024 * 1024 * 1024
        let cappedConfiguration = MLXImageBackendConfiguration(
            artifactDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true),
            profile: .scalableKlein4B, memoryLimitBytes: explicitLimit)
        #expect(try cappedConfiguration.allocatorMemoryLimit(estimatedPeakBytes: UInt64.max) == explicitLimit)
    }

    private func request(width: Int, height: Int, steps: Int = 4,
                         guidance: Float = 1) -> ImageRequest {
        .init(prompt: "CPU metadata fixture", width: width, height: height,
              steps: steps, guidanceScale: guidance, seed: 42)
    }
}
