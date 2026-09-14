import DInference
import Foundation

/// A deterministic, approximate monophonic note explanation of a pitch trajectory.
///
/// Notes cover only complete 256-sample analysis blocks. A partial final block is
/// deliberately outside this interpretation's coverage.
public struct PitchInterpretation: Sendable, Codable, Equatable {
    public static let version = "equal-tempered-contiguous-5-v1"

    public let notes: [PitchNote]

    public init(result: PitchAnalysisResult) throws {
        try result.validate()

        var notes: [PitchNote] = []
        var run: Run?

        for (index, frame) in result.frames.enumerated() {
            guard frame.voiced, let pitchHz = frame.pitchHz else {
                Self.append(run, to: &notes)
                run = nil
                continue
            }

            let midi = Self.nearestEqualTemperedMIDINote(for: pitchHz)
            if var current = run, current.midiNote == midi {
                current.append(confidence: frame.confidence)
                run = current
            } else {
                Self.append(run, to: &notes)
                run = Run(firstFrameIndex: index, midiNote: midi, confidence: frame.confidence)
            }
        }
        Self.append(run, to: &notes)
        self.notes = notes
    }

    /// Uses the contract's nearest-semitone rule, with halfway values away from zero.
    static func nearestEqualTemperedMIDINote(for pitchHz: Double) -> Int {
        Int((69 + 12 * log2(pitchHz / 440)).rounded(.toNearestOrAwayFromZero))
    }

    private static func append(_ run: Run?, to notes: inout [PitchNote]) {
        guard let run, run.frameCount >= 5 else { return }
        notes.append(PitchNote(
            startSample: run.firstFrameIndex * 256,
            endSample: (run.firstFrameIndex + run.frameCount) * 256,
            midiNote: run.midiNote,
            meanConfidence: run.confidenceTotal / Double(run.frameCount)
        ))
    }

    private struct Run {
        let firstFrameIndex: Int
        let midiNote: Int
        var frameCount: Int = 1
        var confidenceTotal: Double

        init(firstFrameIndex: Int, midiNote: Int, confidence: Double) {
            self.firstFrameIndex = firstFrameIndex
            self.midiNote = midiNote
            self.confidenceTotal = confidence
        }

        mutating func append(confidence: Double) {
            frameCount += 1
            confidenceTotal += confidence
        }
    }
}

/// A contiguous approximate note measured in mono 16 kHz analysis samples.
public struct PitchNote: Sendable, Codable, Equatable {
    public let startSample: Int
    public let endSample: Int
    public let midiNote: Int
    public let meanConfidence: Double

    public init(startSample: Int, endSample: Int, midiNote: Int, meanConfidence: Double) {
        self.startSample = startSample
        self.endSample = endSample
        self.midiNote = midiNote
        self.meanConfidence = meanConfidence
    }
}
