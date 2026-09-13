import DInference
@testable import DMLXBackend
import Foundation
import Testing

@Suite("Audio execution capabilities (CPU metadata only)")
struct AudioExecutionCapabilityTests {
    @Test("SA3 declaration follows the selected configuration profile")
    func sa3ProfilesUseExistingDurationLimits() throws {
        for (profile, duration) in [
            (AudioBackendProfile.smMusic, 120.0),
            (.smSFX, 120.0),
            (.medium, 380.0),
        ] {
            let backend = try MLXAudioBackend(configuration: sa3Configuration(profile: profile))
            let capability = backend.executionCapability
            #expect(capability.profile == .init(identifier: profile.rawValue))
            #expect(capability.maximumDurationSeconds == duration)
            #expect(capability.operations == [.generate, .variation, .inpaint])
            #expect(capability.sampleRate == 44_100 && capability.channelCount == 2)
            #expect(capability.maximumConditionFrames == nil && capability.maximumNoteCount == nil)
            #expect(capability.maximumSeed == UInt64(UInt32.max - 1))
        }
    }

    @Test("MRT2 declares only its fixed note-conditioned envelope")
    func mrt2ProfileMatchesProviderValidation() throws {
        let backend = try MLXMRT2Backend(configuration: mrt2Configuration())
        let capability = backend.executionCapability
        #expect(capability.profile == .init(identifier: "mrt2-small-export-v1"))
        #expect(capability.maximumDurationSeconds == 16)
        #expect(capability.sampleRate == 48_000 && capability.channelCount == 2)
        #expect(capability.operations == [.generate])
        #expect(capability.noteControlFidelity == .approximate)
        #expect(capability.maximumConditionFrames == 400 && capability.maximumNoteCount == 512)
        #expect(capability.maximumSeed == UInt64(UInt32.max))
    }

    private func sa3Configuration(profile: AudioBackendProfile) -> AudioBackendConfiguration {
        .init(pythonExecutable: URL(fileURLWithPath: "/tmp/python"),
              providerScript: URL(fileURLWithPath: "/tmp/provider.py"),
              vendorDirectory: URL(fileURLWithPath: "/tmp/vendor", isDirectory: true),
              modelManifest: URL(fileURLWithPath: "/tmp/model.json"),
              artifactDirectory: URL(fileURLWithPath: "/tmp/artifacts", isDirectory: true),
              profile: profile)
    }

    private func mrt2Configuration() -> MRT2BackendConfiguration {
        .init(pythonExecutable: URL(fileURLWithPath: "/tmp/python"),
              providerScript: URL(fileURLWithPath: "/tmp/provider.py"),
              vendorDirectory: URL(fileURLWithPath: "/tmp/vendor", isDirectory: true),
              modelManifest: URL(fileURLWithPath: "/tmp/model.json"),
              artifactDirectory: URL(fileURLWithPath: "/tmp/artifacts", isDirectory: true))
    }
}
