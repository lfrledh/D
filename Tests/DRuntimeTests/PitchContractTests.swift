import XCTest
import DInference

final class PitchContractTests: XCTestCase {
    private func source(end: Int64 = 96000) -> PitchSourceIdentity {
        .init(assetID: UUID(), documentID: UUID(), documentRevision: 0,
              contentSHA256: String(repeating: "a", count: 64), sampleRate: 48000,
              frameCount: 192000, startFrame: 0, endFrame: end)
    }
    func testFixedTimebaseAndSilence() throws {
        let result = PitchAnalysisResult(runID: UUID(), source: source(),
            inputSHA256: String(repeating: "b", count: 64), sampleCount: 32000,
            frames: Array(repeating: .init(pitchHz: nil, confidence: 0, voiced: false), count: 125))
        try result.validate()
        XCTAssertFalse(result.hasVoicedPitch)
        XCTAssertEqual(result.originalFramePosition(for: 0), 382.5)
        XCTAssertEqual(result.originalFramePosition(for: 1), 1150.5)
    }
    func testRangeAndDigestAreNotOptional() throws {
        XCTAssertThrowsError(try source(end: 0).validate())
        XCTAssertThrowsError(try source(end: 200000).validate())
        XCTAssertFalse(PitchSourceIdentity.isDigest(String(repeating: "A", count: 64)))
        let request = PitchAnalysisRequest(source: source(), inputURL: URL(fileURLWithPath: "/tmp/input.f32"),
            inputSHA256: String(repeating: "a", count: 64), sampleCount: 16000)
        XCTAssertThrowsError(try request.validate())
    }
    func testVoicingAndUnknownAreDistinct() throws {
        for frame in [PitchFrame(pitchHz: 440, confidence: 0.9, voiced: true),
                      .init(pitchHz: nil, confidence: .nan, voiced: false),
                      .init(pitchHz: 0, confidence: 0, voiced: false)] {
            let value = PitchAnalysisResult(runID: UUID(), source: source(end: 768),
                inputSHA256: String(repeating: "b", count: 64), sampleCount: 256, frames: [frame])
            XCTAssertThrowsError(try value.validate())
        }
    }
}
