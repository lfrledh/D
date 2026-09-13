import DInference
@testable import DWorkbench
import Foundation
import Testing

@Suite("Image generation settings")
struct ImageGenerationSettingsTests {
    @Test("Legacy and initializer defaults remain verified 512")
    func legacyDefaults() {
        let defaults = ImageGenerationSettings()
        #expect(defaults == .legacy)
        #expect(defaults.width == 512)
        #expect(defaults.height == 512)
        #expect(defaults.executionProfile == ImageExecutionCapability.verified512.profile)
    }

    @Test("Requests explicitly carry the selected profile and capability constants")
    func explicitRequest() throws {
        let settings = ImageGenerationSettings(
            width: 768, height: 512,
            executionProfile: ImageExecutionCapability.scalableKlein4B.profile)
        let request = try settings.request(
            prompt: "Wide landscape", seed: 99,
            capability: .scalableKlein4B)
        #expect(request.prompt == "Wide landscape")
        #expect(request.width == 768 && request.height == 512)
        #expect(request.steps == 4 && request.guidanceScale == 1)
        #expect(request.seed == 99)
        #expect(request.executionProfile == ImageExecutionCapability.scalableKlein4B.profile)
    }

    @Test("Strict hosts reject scalable selections even at 512 square")
    func hostMismatch() {
        let settings = ImageGenerationSettings(
            executionProfile: ImageExecutionCapability.scalableKlein4B.profile)
        #expect(throws: InferenceFailure.self) {
            try settings.request(prompt: "Square", seed: 1, capability: .verified512)
        }
    }

    @Test("Unknown decoded profiles are preserved for viewing and rejected for execution")
    func unknownProfileRoundTrip() throws {
        let unknown = ExecutionProfileReference(identifier: "future-image-profile", revision: 7)
        let settings = ImageGenerationSettings(width: 640, height: 640, executionProfile: unknown)
        let decoded = try JSONDecoder().decode(
            ImageGenerationSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
        #expect(decoded.executionProfile == unknown)
        #expect(throws: InferenceFailure.self) {
            try decoded.request(prompt: "Future", seed: 2, capability: .scalableKlein4B)
        }
    }

    @Test("Dimension validation occurs before a request is returned")
    func invalidDimensions() {
        for settings in [
            ImageGenerationSettings(width: 255, height: 512,
                                    executionProfile: ImageExecutionCapability.scalableKlein4B.profile),
            ImageGenerationSettings(width: 513, height: 512,
                                    executionProfile: ImageExecutionCapability.scalableKlein4B.profile),
            ImageGenerationSettings(width: Int.max, height: Int.max,
                                    executionProfile: ImageExecutionCapability.scalableKlein4B.profile),
        ] {
            #expect(throws: InferenceFailure.self) {
                try settings.request(prompt: "Invalid", seed: 3, capability: .scalableKlein4B)
            }
        }
    }
}
