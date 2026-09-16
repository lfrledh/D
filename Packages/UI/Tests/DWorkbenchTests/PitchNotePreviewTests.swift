import DInference
import Foundation
import Testing
@testable import DWorkbench

@Suite("Pitch note preview")
struct PitchNotePreviewTests {
    @Test
    func encodesIndependentPCMHeaderTimingSilenceEnvelopeAndPitch() throws {
        let frames = Array(repeating: frame(nil), count: 5)
            + Array(repeating: frame(440), count: 5)
            + Array(repeating: frame(nil), count: 5)
            + Array(repeating: frame(523.2511306), count: 5)
        let result = makeResult(frames, sampleCount: frames.count * 256 + 17)

        let wave = try ParsedWave(PitchNotePreview.encodeWAV(result: result))
        #expect(wave.formatTag == 1)
        #expect(wave.channels == 1)
        #expect(wave.sampleRate == 48_000)
        #expect(wave.byteRate == 96_000)
        #expect(wave.blockAlign == 2)
        #expect(wave.bitsPerSample == 16)
        #expect(wave.samples.count == result.sampleCount * 3)

        let leadingEnd = 5 * 256 * 3
        let firstEnd = 10 * 256 * 3
        let gapEnd = 15 * 256 * 3
        let secondEnd = 20 * 256 * 3
        #expect(wave.samples[..<leadingEnd].allSatisfy { $0 == 0 })
        #expect(wave.samples[firstEnd..<gapEnd].allSatisfy { $0 == 0 })
        #expect(wave.samples[secondEnd...].allSatisfy { $0 == 0 })

        #expect(wave.samples[leadingEnd] == 0)
        #expect(wave.samples[firstEnd - 1] == 0)
        #expect(wave.samples[gapEnd] == 0)
        #expect(wave.samples[secondEnd - 1] == 0)
        #expect(wave.samples[leadingEnd + 100] == expectedSample(frequency: 440, localFrame: 100,
                                                                 frameCount: firstEnd - leadingEnd))

        let firstFrequency = measuredFrequency(Array(wave.samples[leadingEnd..<firstEnd]))
        let secondFrequency = measuredFrequency(Array(wave.samples[gapEnd..<secondEnd]))
        #expect(abs(firstFrequency - 440) < 1)
        #expect(abs(secondFrequency - 523.2511306) < 1)
        #expect(wave.samples.map { abs(Int($0)) }.max() ?? 0 <= 6_554)
        #expect(wave.samples.map { abs(Int($0)) }.max() ?? 0 >= 6_500)
    }

    @Test
    func adjacentNotesStopAndRestSeparatedSameNoteRestartsPhase() throws {
        let frames = Array(repeating: frame(440), count: 5)
            + Array(repeating: frame(523.2511306), count: 5)
            + [frame(nil)]
            + Array(repeating: frame(440), count: 5)
        let wave = try ParsedWave(PitchNotePreview.encodeWAV(result: makeResult(frames)))
        let noteFrames = 5 * 256 * 3
        let firstA = Array(wave.samples[0..<noteFrames])
        let cStart = noteFrames
        let cEnd = noteFrames * 2
        let secondAStart = cEnd + 256 * 3

        #expect(wave.samples[noteFrames - 1] == 0)
        #expect(wave.samples[cStart] == 0)
        #expect(wave.samples[cEnd - 1] == 0)
        #expect(wave.samples[cEnd..<secondAStart].allSatisfy { $0 == 0 })
        #expect(wave.samples[secondAStart] == 0)
        #expect(firstA == Array(wave.samples[secondAStart..<(secondAStart + noteFrames)]))
    }

    @Test
    func deterministicBytesPreserveMaximumDurationAndPartialTail() throws {
        var frames = Array(repeating: frame(nil), count: 7_500)
        for index in 0..<5 { frames[index] = frame(440) }
        let result = makeResult(frames, sampleCount: 1_920_000)

        let first = try PitchNotePreview.encodeWAV(result: result)
        let second = try PitchNotePreview.encodeWAV(result: result)
        #expect(first == second)
        #expect(first.count == 44 + 120 * 48_000 * 2)

        let wave = try ParsedWave(first)
        let noteEnd = 5 * 256 * 3
        #expect(wave.samples[noteEnd...].allSatisfy { $0 == 0 })
    }

    @Test
    func rejectsNoExchangeableNotesAndInvalidResult() throws {
        let shortRun = makeResult([
            frame(440), frame(440), frame(440), frame(440), frame(nil)
        ])
        #expect(throws: InferenceFailure.self) {
            try PitchNotePreview.encodeWAV(result: shortRun)
        }

        let valid = makeResult(Array(repeating: frame(440), count: 5))
        let invalid = PitchAnalysisResult(
            runID: valid.runID, source: valid.source, inputSHA256: valid.inputSHA256,
            sampleCount: valid.sampleCount, frames: valid.frames, schemaVersion: 2
        )
        #expect(throws: InferenceFailure.self) {
            try PitchNotePreview.encodeWAV(result: invalid)
        }
    }

    @Test
    func preCancelledEncodingThrowsCancellation() async {
        let result = makeResult(Array(repeating: frame(440), count: 5))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try PitchNotePreview.encodeWAV(result: result)
        }
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    private func makeResult(_ frames: [PitchFrame], sampleCount: Int? = nil) -> PitchAnalysisResult {
        let samples = sampleCount ?? frames.count * 256
        let source = PitchSourceIdentity(
            assetID: UUID(), documentID: UUID(), documentRevision: 1,
            contentSHA256: String(repeating: "a", count: 64), sampleRate: 16_000,
            frameCount: Int64(samples), startFrame: 0, endFrame: Int64(samples)
        )
        return PitchAnalysisResult(
            runID: UUID(), source: source, inputSHA256: String(repeating: "b", count: 64),
            sampleCount: samples, frames: frames
        )
    }

    private func frame(_ pitchHz: Double?) -> PitchFrame {
        PitchFrame(pitchHz: pitchHz, confidence: pitchHz == nil ? 0 : 0.95, voiced: pitchHz != nil)
    }

    private func expectedSample(frequency: Double, localFrame: Int, frameCount: Int) -> Int16 {
        let envelope = min(1.0, min(Double(localFrame) / 240,
                                    Double(frameCount - 1 - localFrame) / 240))
        let phase = 2 * Double.pi * frequency * Double(localFrame) / 48_000
        return Int16((sin(phase) * 0.2 * envelope * Double(Int16.max))
            .rounded(.toNearestOrAwayFromZero))
    }

    private func measuredFrequency(_ samples: [Int16]) -> Double {
        let steady = samples.indices.dropFirst(240).dropLast(240)
        var crossings: [Int] = []
        for index in steady.dropFirst() where samples[index - 1] <= 0 && samples[index] > 0 {
            crossings.append(index)
        }
        guard crossings.count > 1, let first = crossings.first, let last = crossings.last else { return 0 }
        return Double(crossings.count - 1) * 48_000 / Double(last - first)
    }
}

private struct ParsedWave {
    let formatTag: UInt16
    let channels: UInt16
    let sampleRate: UInt32
    let byteRate: UInt32
    let blockAlign: UInt16
    let bitsPerSample: UInt16
    let samples: [Int16]

    init(_ data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count >= 44,
              Array(bytes[0..<4]) == Array("RIFF".utf8),
              Self.read32(bytes, 4) == UInt32(bytes.count - 8),
              Array(bytes[8..<12]) == Array("WAVE".utf8),
              Array(bytes[12..<16]) == Array("fmt ".utf8),
              Self.read32(bytes, 16) == 16,
              Array(bytes[36..<40]) == Array("data".utf8),
              Self.read32(bytes, 40) == UInt32(bytes.count - 44),
              (bytes.count - 44).isMultiple(of: 2) else {
            throw ParseError.invalidWave
        }
        formatTag = Self.read16(bytes, 20)
        channels = Self.read16(bytes, 22)
        sampleRate = Self.read32(bytes, 24)
        byteRate = Self.read32(bytes, 28)
        blockAlign = Self.read16(bytes, 32)
        bitsPerSample = Self.read16(bytes, 34)
        samples = stride(from: 44, to: bytes.count, by: 2).map {
            Int16(bitPattern: Self.read16(bytes, $0))
        }
    }

    private enum ParseError: Error { case invalidWave }

    private static func read16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func read32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }
}
