import DInference
@testable import DMLXBackend
import Foundation
import Testing

@Suite("Image execution selection (CPU metadata only)")
struct ImageExecutionSelectionTests {
    @Test("Compatibility profiles forward every value and estimate")
    func compatibilityForwarding() throws {
        let wrapper = ImageExecutionProfile.scalableKlein4B
        let capability = ImageExecutionCapability.scalableKlein4B
        #expect(wrapper.identifier == capability.profile.identifier)
        #expect(wrapper.minimumWidth == capability.minimumWidth)
        #expect(wrapper.maximumWidth == capability.maximumWidth)
        #expect(wrapper.minimumHeight == capability.minimumHeight)
        #expect(wrapper.maximumHeight == capability.maximumHeight)
        #expect(wrapper.dimensionMultiple == capability.dimensionMultiple)
        #expect(wrapper.maximumPixelCount == capability.maximumPixelCount)
        #expect(wrapper.steps == capability.steps)
        #expect(wrapper.guidanceScale == capability.guidanceScale)
        #expect(wrapper.maximumTextTokens == capability.maximumTextTokens)
        #expect(try wrapper.estimatedPeakBytes(width: 1024, height: 1024)
                == capability.estimatedPeakBytes(width: 1024, height: 1024))
    }

    @Test("Backend exposes its immutable host capability")
    func backendCapability() throws {
        let path = try #require(ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"])
        let backend = try MLXImageBackend(configuration: MLXImageBackendConfiguration(
            artifactDirectory: URL(fileURLWithPath: path, isDirectory: true),
            profile: .scalableKlein4B))
        #expect(backend.executionCapability == .scalableKlein4B)
    }

    @Test("Metadata records the actual resolved profile and revision")
    func resolvedMetadata() {
        let verified = MLXImageBackend.executionProfileMetadata(
            ImageExecutionCapability.verified512.profile)
        #expect(verified["imageExecutionProfile"] == "verified512")
        #expect(verified["imageExecutionProfileRevision"] == "1")

        let scalable = MLXImageBackend.executionProfileMetadata(
            ImageExecutionCapability.scalableKlein4B.profile)
        #expect(scalable["imageExecutionProfile"] == "scalableKlein4B")
        #expect(scalable["imageExecutionProfileRevision"] == "1")
    }
}
