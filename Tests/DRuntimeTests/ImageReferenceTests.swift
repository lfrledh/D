import DInference
import Foundation
import Testing

@Suite("Explicit image reference contract")
struct ImageReferenceTests {
    let reference = ImageReference(url: URL(fileURLWithPath: "/reference.rgb"),
        sha256: String(repeating: "a", count: 64), byteCount: 512 * 512 * 3, width: 512, height: 512)

    @Test func identityAndLegacy() throws {
        let request = ImageRequest(prompt: "change the sky", width: 512, height: 512, steps: 4,
            guidanceScale: 1, seed: 42, executionProfile: ImageExecutionCapability.referenceKlein4B.profile,
            referenceImage: reference)
        #expect(try ImageExecutionCapability.scalableKlein4B.resolvedCapability(for: request) == .referenceKlein4B)
        #expect(throws: (any Error).self) { try ImageExecutionCapability.verified512.validate(request) }
        #expect(try JSONDecoder().decode(ImageRequest.self, from: JSONEncoder().encode(request)) == request)
        let old = ImageRequest(prompt: "old", width: 512, height: 512, steps: 4, guidanceScale: 1, seed: 0)
        #expect(try JSONDecoder().decode(ImageRequest.self, from: JSONEncoder().encode(old)).referenceImage == nil)
        #expect(ImageExecutionCapability.referenceKlein4B.contract.inputRoles == [.prompt, .image])
        #expect(try ImageExecutionCapability.referenceKlein4B.estimatedPeakBytes(for: request) == 9 * 1024 * 1024 * 1024)
    }
    @Test func noIgnoredOrMissingReference() throws {
        for profile in [nil, ImageExecutionCapability.scalableKlein4B.profile] {
            let request = ImageRequest(prompt: "edit", width: 512, height: 512, steps: 4,
                guidanceScale: 1, seed: 0, executionProfile: profile, referenceImage: reference)
            #expect(throws: (any Error).self) { try ImageExecutionCapability.scalableKlein4B.validate(request) }
        }
        let missing = ImageRequest(prompt: "edit", width: 512, height: 512, steps: 4,
            guidanceScale: 1, seed: 0, executionProfile: ImageExecutionCapability.referenceKlein4B.profile)
        #expect(throws: (any Error).self) { try ImageExecutionCapability.scalableKlein4B.validate(missing) }
        for width in [0, 255, 513, Int.max] {
            let bad = ImageReference(url: reference.url, sha256: reference.sha256,
                byteCount: reference.byteCount, width: width, height: 512)
            #expect(throws: (any Error).self) { try bad.validate() }
        }
    }
}
