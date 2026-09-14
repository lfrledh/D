import DInference
import Foundation
import Testing
@testable import DWorkbench

@Suite("Pitch interpretation")
struct PitchInterpretationTests {
    @Test
    func contiguousSameMIDIRunUsesWholeFrameBlocksAndMeanConfidence() throws {
        let result = makeResult([
            frame(440, 0.91), frame(441, 0.92), frame(439, 0.93), frame(440, 0.94), frame(440, 0.95),
            frame(nil, 0.2),
            frame(440, 0.99), frame(440, 0.98), frame(440, 0.97), frame(440, 0.96), frame(440, 0.95)
        ])

        let interpretation = try PitchInterpretation(result: result)
        #expect(interpretation.notes.count == 2)
        #expect(interpretation.notes[0].startSample == 0)
        #expect(interpretation.notes[0].endSample == 1_280)
        #expect(interpretation.notes[0].midiNote == 69)
        #expect(abs(interpretation.notes[0].meanConfidence - 0.93) < 0.000_000_1)
        #expect(interpretation.notes[1].startSample == 1_536)
        #expect(interpretation.notes[1].endSample == 2_816)
        #expect(interpretation.notes[1].midiNote == 69)
    }

    @Test
    func shortRunsPitchChangesAndSilenceNeverBridgeIntoNotes() throws {
        let result = makeResult([
            frame(440, 0.95), frame(440, 0.95), frame(440, 0.95), frame(440, 0.95),
            frame(466.1637615, 0.95), frame(466.1637615, 0.95), frame(466.1637615, 0.95), frame(466.1637615, 0.95),
            frame(nil, 0),
            frame(523.2511306, 0.91), frame(523.2511306, 0.92), frame(523.2511306, 0.93), frame(523.2511306, 0.94), frame(523.2511306, 0.95)
        ])

        let interpretation = try PitchInterpretation(result: result)
        #expect(interpretation.notes.count == 1)
        #expect(interpretation.notes[0].startSample == 2_304)
        #expect(interpretation.notes[0].endSample == 3_584)
        #expect(interpretation.notes[0].midiNote == 72)
        #expect(abs(interpretation.notes[0].meanConfidence - 0.93) < 0.000_000_1)
    }

    @Test
    func midpointRoundingIsAwayFromZeroAndInvalidResultIsRejected() throws {
        let halfwayAboveA4 = 440 * pow(2, 0.5 / 12)
        #expect(PitchInterpretation.nearestEqualTemperedMIDINote(for: halfwayAboveA4) == 70)

        let valid = makeResult(Array(repeating: frame(440, 0.95), count: 5))
        let invalid = PitchAnalysisResult(runID: valid.runID, source: valid.source, inputSHA256: valid.inputSHA256,
                                          sampleCount: valid.sampleCount, frames: valid.frames, schemaVersion: 2)
        #expect(throws: InferenceFailure.self) { try PitchInterpretation(result: invalid) }
    }

    @Test
    func finalPartialBlockIsNeverIncludedInNoteCoverage() throws {
        let result = makeResult(Array(repeating: frame(440, 0.95), count: 5), sampleCount: 1_281)
        let interpretation = try PitchInterpretation(result: result)
        #expect(interpretation.notes.map(\.endSample) == [1_280])
        #expect(result.sampleCount == 1_281)
    }

    private func makeResult(_ frames: [PitchFrame], sampleCount: Int? = nil) -> PitchAnalysisResult {
        let samples = sampleCount ?? frames.count * 256
        let source = PitchSourceIdentity(assetID: UUID(), documentID: UUID(), documentRevision: 1,
                                         contentSHA256: String(repeating: "a", count: 64), sampleRate: 16_000,
                                         frameCount: Int64(samples), startFrame: 0, endFrame: Int64(samples))
        return PitchAnalysisResult(runID: UUID(), source: source, inputSHA256: String(repeating: "b", count: 64),
                                   sampleCount: samples, frames: frames)
    }

    private func frame(_ pitchHz: Double?, _ confidence: Double) -> PitchFrame {
        PitchFrame(pitchHz: pitchHz, confidence: confidence, voiced: pitchHz != nil)
    }
}
