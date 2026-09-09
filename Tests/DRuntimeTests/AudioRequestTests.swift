import DInference
import Foundation
import Testing

@Suite("AUDIO1 common request values")
struct AudioRequestTests {
    private let source = AudioSourceReference(
        url: URL(fileURLWithPath: "/tmp/source.wav"),
        sha256: String(repeating: "a", count: 64), frameCount: 44_100,
        sampleRate: 44_100, channels: 2)

    @Test("All three operation shapes retain their frozen frame-clock values")
    func validOperations() throws {
        let requests = [
            AudioRequest(operation: .generate, prompt: "雨 🎵", durationSeconds: 1,
                         seed: UInt64.max, steps: 1, guidanceScale: 0, strength: 1),
            AudioRequest(operation: .variation, prompt: "variation", durationSeconds: 1,
                         seed: 42, steps: 8, source: source),
            AudioRequest(operation: .inpaint, prompt: "inpaint", durationSeconds: 1,
                         seed: 42, steps: 8, strength: 0.5, source: source,
                         editRegion: AudioEditRegion(startFrame: 1, endFrame: 44_100)),
        ]
        for request in requests { try request.validate() }
        #expect(requests[0].seed == UInt64.max) // Common values do not silently truncate backend-specific seeds.
        #expect(requests[0].prompt == "雨 🎵")
    }

    @Test("Operation-specific fields are never silently ignored")
    func invalidOperationFields() {
        let invalid = [
            AudioRequest(operation: .generate, prompt: "x", durationSeconds: 1, seed: 0,
                         steps: 1, strength: 1, source: source),
            AudioRequest(operation: .generate, prompt: "x", durationSeconds: 1, seed: 0,
                         steps: 1, strength: 0.9),
            AudioRequest(operation: .variation, prompt: "x", durationSeconds: 1, seed: 0,
                         steps: 1),
            AudioRequest(operation: .variation, prompt: "x", durationSeconds: 1, seed: 0,
                         steps: 1, source: source, editRegion: AudioEditRegion(startFrame: 0, endFrame: 1)),
            AudioRequest(operation: .inpaint, prompt: "x", durationSeconds: 1, seed: 0,
                         steps: 1, source: source),
        ]
        for request in invalid { expectInvalid(request) }
    }

    @Test("Inpaint regions are nonempty half-open source-frame intervals")
    func frameIntervals() {
        for region in [
            AudioEditRegion(startFrame: -1, endFrame: 1),
            AudioEditRegion(startFrame: 0, endFrame: 0),
            AudioEditRegion(startFrame: 2, endFrame: 1),
            AudioEditRegion(startFrame: 0, endFrame: 44_101),
        ] {
            expectInvalid(AudioRequest(operation: .inpaint, prompt: "x", durationSeconds: 1,
                                       seed: 0, steps: 1, source: source, editRegion: region))
        }
    }

    @Test("Bad source URLs, hashes, and clocks fail common validation")
    func invalidSources() {
        let candidates = [
            AudioSourceReference(url: URL(string: "https://example.invalid/a.wav")!,
                                 sha256: String(repeating: "a", count: 64), frameCount: 1,
                                 sampleRate: 44_100, channels: 2),
            AudioSourceReference(url: URL(fileURLWithPath: "/tmp/a.wav"), sha256: "ABC",
                                 frameCount: 1, sampleRate: 44_100, channels: 2),
            AudioSourceReference(url: URL(fileURLWithPath: "/tmp/a.wav"),
                                 sha256: String(repeating: "g", count: 64), frameCount: 1,
                                 sampleRate: 44_100, channels: 2),
            AudioSourceReference(url: URL(fileURLWithPath: "/tmp/a.wav"),
                                 sha256: String(repeating: "0", count: 64), frameCount: 0,
                                 sampleRate: 0, channels: 0),
        ]
        for candidate in candidates {
            expectInvalid(AudioRequest(operation: .variation, prompt: "x", durationSeconds: 1,
                                       seed: 0, steps: 1, source: candidate))
        }
    }

    @Test("Nonfinite and malformed numerical values are rejected")
    func invalidNumbers() {
        let invalid = [
            AudioRequest(operation: .generate, prompt: "x", durationSeconds: .nan, seed: 0, steps: 1),
            AudioRequest(operation: .generate, prompt: "x", durationSeconds: .infinity, seed: 0, steps: 1),
            AudioRequest(operation: .generate, prompt: "x", durationSeconds: 1, seed: 0, steps: 0),
            AudioRequest(operation: .generate, prompt: "x", durationSeconds: 1, seed: 0,
                         steps: 1, guidanceScale: .nan),
            AudioRequest(operation: .generate, prompt: "x", durationSeconds: 1, seed: 0,
                         steps: 1, strength: .infinity),
        ]
        for request in invalid { expectInvalid(request) }
    }

    @Test("Codable rejects Boolean tricks and unknown operation values")
    func strictDecodedValueTypes() throws {
        let base = """
        {"operation":"generate","prompt":"字🎵","durationSeconds":1,"seed":SEED,
         "steps":8,"guidanceScale":1,"strength":1}
        """
        let decoder = JSONDecoder()
        for seed in ["true", "-1", "1.5"] {
            #expect(throws: (any Error).self) {
                _ = try decoder.decode(AudioRequest.self, from: Data(base.replacingOccurrences(of: "SEED", with: seed).utf8))
            }
        }
        #expect(throws: (any Error).self) {
            _ = try decoder.decode(AudioRequest.self,
                from: Data(base.replacingOccurrences(of: "SEED", with: "0")
                    .replacingOccurrences(of: "generate", with: "unknown").utf8))
        }
        let maximum = try decoder.decode(
            AudioRequest.self,
            from: Data(base.replacingOccurrences(of: "SEED", with: "18446744073709551615").utf8))
        #expect(maximum.seed == UInt64.max)
        try maximum.validate() // The selected backend, not this value type, applies AUDIO1's narrower seed cap.
    }

    @Test("UTF-8 prompt limit counts bytes without rejecting valid Unicode")
    func promptBytes() throws {
        let accepted = AudioRequest(operation: .generate, prompt: "界", durationSeconds: 1,
                                    seed: 0, steps: 1)
        try accepted.validate()
        expectInvalid(AudioRequest(operation: .generate,
                                   prompt: String(repeating: "界", count: 349_526),
                                   durationSeconds: 1, seed: 0, steps: 1))
    }

    private func expectInvalid(_ request: AudioRequest) {
        do {
            try request.validate()
            Issue.record("Invalid audio request was accepted")
        } catch let failure as InferenceFailure {
            guard case .invalidRequest = failure else { Issue.record("Unexpected failure: \(failure)"); return }
        } catch { Issue.record("Unexpected error: \(error)") }
    }
}
