import DInference
import Foundation

/// Encodes the accepted approximate pitch notes as a deterministic listening aid.
///
/// This preview deliberately uses a plain sine wave. It preserves the analysis
/// selection's free timing, but does not reproduce the source timbre or dynamics.
public enum PitchNotePreview {
    public static func encodeWAV(result: PitchAnalysisResult) throws -> Data {
        try Task.checkCancellation()
        try result.validate()

        let notes = try PitchInterpretation(result: result).notes
        guard !notes.isEmpty else {
            throw InferenceFailure.invalidRequest("The pitch analysis contains no exchangeable notes.")
        }
        try Task.checkCancellation()

        let outputFrameCount = result.sampleCount * 3
        let dataByteCount = outputFrameCount * 2
        var wave = Data(count: 44 + dataByteCount)

        try wave.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) throws in
            writeASCII("RIFF", at: 0, to: bytes)
            writeLittleEndian(UInt32(36 + dataByteCount), at: 4, to: bytes)
            writeASCII("WAVE", at: 8, to: bytes)
            writeASCII("fmt ", at: 12, to: bytes)
            writeLittleEndian(UInt32(16), at: 16, to: bytes)
            writeLittleEndian(UInt16(1), at: 20, to: bytes)
            writeLittleEndian(UInt16(1), at: 22, to: bytes)
            writeLittleEndian(UInt32(48_000), at: 24, to: bytes)
            writeLittleEndian(UInt32(96_000), at: 28, to: bytes)
            writeLittleEndian(UInt16(2), at: 32, to: bytes)
            writeLittleEndian(UInt16(16), at: 34, to: bytes)
            writeASCII("data", at: 36, to: bytes)
            writeLittleEndian(UInt32(dataByteCount), at: 40, to: bytes)

            var noteIndex = 0
            for outputFrame in 0..<outputFrameCount {
                if outputFrame & 4_095 == 0 {
                    try Task.checkCancellation()
                }

                while noteIndex < notes.count, outputFrame >= notes[noteIndex].endSample * 3 {
                    noteIndex += 1
                }

                var sample: Int16 = 0
                if noteIndex < notes.count {
                    let note = notes[noteIndex]
                    let startFrame = note.startSample * 3
                    let endFrame = note.endSample * 3
                    if outputFrame >= startFrame, outputFrame < endFrame {
                        sample = pcmSample(for: note, localFrame: outputFrame - startFrame,
                                           frameCount: endFrame - startFrame)
                    }
                }

                writeLittleEndian(UInt16(bitPattern: sample), at: 44 + outputFrame * 2, to: bytes)
            }
        }

        try Task.checkCancellation()
        return wave
    }

    private static func pcmSample(for note: PitchNote, localFrame: Int, frameCount: Int) -> Int16 {
        let attack = Double(localFrame) / 240
        let release = Double(frameCount - 1 - localFrame) / 240
        let envelope = min(1.0, min(attack, release))
        let frequency = 440 * pow(2, Double(note.midiNote - 69) / 12)
        let phase = 2 * Double.pi * frequency * Double(localFrame) / 48_000
        let value = sin(phase) * 0.2 * envelope * Double(Int16.max)
        return Int16(value.rounded(.toNearestOrAwayFromZero))
    }

    private static func writeASCII(_ value: String, at offset: Int,
                                   to bytes: UnsafeMutableRawBufferPointer) {
        for (index, byte) in value.utf8.enumerated() {
            bytes[offset + index] = byte
        }
    }

    private static func writeLittleEndian(_ value: UInt16, at offset: Int,
                                          to bytes: UnsafeMutableRawBufferPointer) {
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    private static func writeLittleEndian(_ value: UInt32, at offset: Int,
                                          to bytes: UnsafeMutableRawBufferPointer) {
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        bytes[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        bytes[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }
}
