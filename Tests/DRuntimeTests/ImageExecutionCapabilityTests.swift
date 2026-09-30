import DInference
import Foundation
import Testing

@Suite("Image execution capability")
struct ImageExecutionCapabilityTests {
    @Test("Frozen declarations preserve the existing implementation constants")
    func declarations() {
        let verified = ImageExecutionCapability.verified512
        #expect(verified.profile == ExecutionProfileReference(identifier: "verified512", revision: 1))
        #expect(verified.minimumWidth == 512 && verified.maximumWidth == 512)
        #expect(verified.minimumHeight == 512 && verified.maximumHeight == 512)
        #expect(verified.dimensionMultiple == 32)
        #expect(verified.maximumPixelCount == 512 * 512)
        #expect(verified.steps == 4 && verified.guidanceScale == 1)
        #expect(verified.maximumTextTokens == 512)
        #expect(verified.contract.operationID == "image.generate")
        #expect(verified.contract.inputRoles == [.prompt])
        #expect(verified.contract.outputRole == .image)
        #expect(verified.contract.controlFidelity == .approximate)
        #expect(verified.contract.cancellation == .drainBeforeRelease)

        let scalable = ImageExecutionCapability.scalableKlein4B
        #expect(scalable.profile == ExecutionProfileReference(identifier: "scalableKlein4B", revision: 1))
        #expect(scalable.minimumWidth == 256 && scalable.maximumWidth == 2048)
        #expect(scalable.minimumHeight == 256 && scalable.maximumHeight == 2048)
        #expect(scalable.dimensionMultiple == 32)
        #expect(scalable.maximumPixelCount == 2048 * 2048)
        #expect(scalable.steps == verified.steps)
        #expect(scalable.guidanceScale == verified.guidanceScale)
        #expect(scalable.maximumTextTokens == verified.maximumTextTokens)
    }

    @Test("Legacy nil requests use the immutable host capability")
    func legacyResolution() throws {
        let verifiedRequest = request(width: 512, height: 512)
        #expect(try ImageExecutionCapability.verified512.resolvedCapability(
            for: verifiedRequest) == .verified512)

        let scalableRequest = request(width: 768, height: 512)
        #expect(try ImageExecutionCapability.scalableKlein4B.resolvedCapability(
            for: scalableRequest) == .scalableKlein4B)
    }

    @Test("Explicit profiles resolve strictly within the host envelope")
    func explicitResolution() throws {
        let verified = request(
            width: 512, height: 512,
            profile: ImageExecutionCapability.verified512.profile)
        #expect(try ImageExecutionCapability.scalableKlein4B.resolvedCapability(
            for: verified) == .verified512)

        let scalable = request(
            width: 768, height: 512,
            profile: ImageExecutionCapability.scalableKlein4B.profile)
        #expect(try ImageExecutionCapability.scalableKlein4B.resolvedCapability(
            for: scalable) == .scalableKlein4B)

        let scalableAt512 = request(
            width: 512, height: 512,
            profile: ImageExecutionCapability.scalableKlein4B.profile)
        #expect(throws: InferenceFailure.self) {
            try ImageExecutionCapability.verified512.validate(scalableAt512)
        }
    }

    @Test("Unknown identifiers and revisions remain values but cannot execute")
    func unknownProfiles() {
        for profile in [
            ExecutionProfileReference(identifier: "unknown-image", revision: 1),
            ExecutionProfileReference(identifier: "verified512", revision: 2),
            ExecutionProfileReference(identifier: "scalableKlein4B", revision: 0),
        ] {
            #expect(throws: InferenceFailure.self) {
                try ImageExecutionCapability.scalableKlein4B.validate(
                    request(width: 512, height: 512, profile: profile))
            }
        }
    }

    @Test("Bounds, stride, area, steps and guidance are enforced by the resolved profile")
    func invalidSettings() {
        let scalable = ImageExecutionCapability.scalableKlein4B.profile
        for image in [
            request(width: 224, height: 512, profile: scalable),
            request(width: 2080, height: 512, profile: scalable),
            request(width: 257, height: 512, profile: scalable),
            request(width: 512, height: 257, profile: scalable),
            request(width: Int.max, height: Int.max, profile: scalable),
            request(width: 512, height: 512, steps: 5, profile: scalable),
            request(width: 512, height: 512, guidance: 2, profile: scalable),
            request(width: 512, height: 512, guidance: .nan, profile: scalable),
        ] {
            #expect(throws: InferenceFailure.self) {
                try ImageExecutionCapability.scalableKlein4B.validate(image)
            }
        }
    }

    @Test("Peak estimates preserve the exact former formula")
    func estimates() throws {
        let gibibyte = UInt64(1024 * 1024 * 1024)
        #expect(try ImageExecutionCapability.verified512.estimatedPeakBytes(
            width: 512, height: 512) == 8 * gibibyte)
        #expect(try ImageExecutionCapability.scalableKlein4B.estimatedPeakBytes(
            width: 512, height: 256) == 8 * gibibyte)
        #expect(try ImageExecutionCapability.scalableKlein4B.estimatedPeakBytes(
            width: 768, height: 512) == 8 * gibibyte + gibibyte / 2)
        #expect(try ImageExecutionCapability.scalableKlein4B.estimatedPeakBytes(
            width: 2048, height: 2048) == 23 * gibibyte)
    }

    @Test("Ordered reference forms resolve without ambiguity or truncation")
    func orderedReferences() throws {
        let first = reference("a")
        let second = reference("b")
        let profile = ImageExecutionCapability.referenceKlein4B.profile
        let nilInput = image(references: nil)
        #expect(try nilInput.resolvedReferences().isEmpty)
        let legacy = ImageRequest(prompt: "test", width: 512, height: 512, steps: 4,
                                  guidanceScale: 1, seed: 0, executionProfile: profile,
                                  referenceImage: first)
        #expect(try legacy.resolvedReferences() == [first])
        let ordered = image(references: [second, first], profile: profile)
        #expect(try ordered.resolvedReferences() == [second, first])
        #expect(try JSONDecoder().decode(ImageRequest.self, from: JSONEncoder().encode(ordered)) == ordered)
        #expect(try ImageExecutionCapability.referenceKlein4B.resolvedCapability(for: ordered) == .referenceKlein4B)
        #expect(try ImageExecutionCapability.referenceKlein4B.estimatedPeakBytes(for: ordered)
                == 10 * 1024 * 1024 * 1024)
        let nine = image(references: Array(repeating: first, count: 9), profile: profile)
        #expect(try nine.resolvedReferences().count == 9)
        #expect(try ImageExecutionCapability.referenceKlein4B.estimatedPeakBytes(for: nine)
                == 17 * 1024 * 1024 * 1024)
        #expect(throws: InferenceFailure.self) { try image(references: []).resolvedReferences() }
        let ambiguous = ImageRequest(prompt: "test", width: 512, height: 512, steps: 4,
                                     guidanceScale: 1, seed: 0, executionProfile: profile,
                                     referenceImage: first, referenceImages: [second])
        #expect(throws: InferenceFailure.self) { try ambiguous.resolvedReferences() }
        let bad = ImageReference(url: URL(fileURLWithPath: "/tmp/bad"), sha256: "bad",
                                 byteCount: 1, width: 256, height: 256)
        #expect(throws: InferenceFailure.self) { try image(references: [first, bad]).resolvedReferences() }
        #expect(throws: InferenceFailure.self) {
            try ImageExecutionCapability.verified512.validate(image(references: [first], profile: profile))
        }
        let legacyJSON = try JSONEncoder().encode(legacy)
        let decoded = try JSONDecoder().decode(ImageRequest.self, from: legacyJSON)
        #expect(decoded.referenceImages == nil)
        #expect(try decoded.resolvedReferences() == [first])
    }

    @Test("Invalid ordered reference requests are rejected", arguments: [
        "empty", "ambiguous", "invalid", "missing", "verified",
    ])
    func rejectedReferenceForms(kind: String) {
        let first = reference("a")
        let profile = ImageExecutionCapability.referenceKlein4B.profile
        let candidate: ImageRequest
        switch kind {
        case "empty": candidate = image(references: [], profile: profile)
        case "ambiguous":
            candidate = ImageRequest(prompt: "test", width: 512, height: 512, steps: 4,
                                     guidanceScale: 1, seed: 0, executionProfile: profile,
                                     referenceImage: first, referenceImages: [first])
        case "invalid":
            let bad = ImageReference(url: URL(fileURLWithPath: "/tmp/bad"), sha256: "bad",
                                     byteCount: 1, width: 256, height: 256)
            candidate = image(references: [first, bad], profile: profile)
        case "missing": candidate = image(references: nil, profile: profile)
        default: candidate = image(references: [first], profile: ImageExecutionCapability.verified512.profile)
        }
        #expect(throws: InferenceFailure.self) {
            try ImageExecutionCapability.scalableKlein4B.validate(candidate)
        }
    }

    @Test("Dev BF16 values require explicit profile and a large host envelope")
    func devValues() throws {
        let capability = ImageExecutionCapability.flux2Dev
        #expect(capability.profile.identifier == "flux2-dev-bf16-v1")
        #expect(capability.contract.operationID == "image.flux2Dev")
        #expect(capability.dimensionMultiple == 16)
        #expect(try capability.estimatedPeakBytes(width: 512, height: 512)
                >= 128 * 1024 * 1024 * 1024)
        let valid = ImageRequest(prompt: "test", width: 512, height: 512, steps: 28,
                                 guidanceScale: 4, seed: 0, executionProfile: capability.profile)
        #expect(try capability.resolvedCapability(for: valid) == capability)
        #expect(throws: InferenceFailure.self) {
            try ImageExecutionCapability.scalableKlein4B.validate(valid)
        }
        #expect(throws: InferenceFailure.self) {
            try capability.validate(ImageRequest(prompt: "test", width: 511, height: 512,
                                                 steps: 28, guidanceScale: 4, seed: 0,
                                                 executionProfile: capability.profile))
        }
    }

    private func reference(_ character: String) -> ImageReference {
        ImageReference(url: URL(fileURLWithPath: "/tmp/\(character).rgb"),
                       sha256: String(repeating: character, count: 64),
                       byteCount: 256 * 256 * 3, width: 256, height: 256)
    }

    private func image(references: [ImageReference]?,
                       profile: ExecutionProfileReference? = nil) -> ImageRequest {
        ImageRequest(prompt: "test", width: 512, height: 512, steps: 4,
                     guidanceScale: 1, seed: 0, executionProfile: profile,
                     referenceImages: references)
    }

    private func request(width: Int, height: Int, steps: Int = 4,
                         guidance: Float = 1,
                         profile: ExecutionProfileReference? = nil) -> ImageRequest {
        ImageRequest(prompt: "CPU fixture", width: width, height: height,
                     steps: steps, guidanceScale: guidance, seed: 42,
                     executionProfile: profile)
    }
}
