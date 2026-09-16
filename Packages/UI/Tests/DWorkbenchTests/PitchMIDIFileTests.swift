import DInference
import Foundation
import Testing
@testable import DWorkbench

@Suite("Pitch MIDI file")
struct PitchMIDIFileTests {
    @Test
    func encodesRelativeTimingMetadataAndTrailingRestDeterministically() throws {
        let result = makeResult([
            frames(440, count: 10),
            [unvoiced(), unvoiced()],
            frames(523.2511306, count: 5)
        ].flatMap { $0 }, sampleCount: 4_500, startFrame: 9_000)

        let first = try PitchMIDIFile.encode(result: result)
        let second = try PitchMIDIFile.encode(result: result)
        #expect(first == second)

        let file = try MIDIFile(first)
        #expect(file.format == 0)
        #expect(file.trackCount == 1)
        #expect(file.division == 960)
        #expect(file.events == [
            .tempo(tick: 0, microsecondsPerQuarterNote: 500_000),
            .text(tick: 0, "D approximate free-time notes; 120 BPM encodes time; velocity 80 is synthetic"),
            .noteOn(tick: 0, note: 69, velocity: 80),
            .noteOff(tick: 307, note: 69),
            .noteOn(tick: 369, note: 72, velocity: 80),
            .noteOff(tick: 522, note: 72),
            .endOfTrack(tick: 540)
        ])
    }

    @Test
    func ordersSameTickNoteOffBeforeNoteOnAndRepresentsReattacks() throws {
        let adjacent = makeResult(frames(440, count: 5) + frames(523.2511306, count: 5))
        let adjacentEvents = try MIDIFile(PitchMIDIFile.encode(result: adjacent)).events
        #expect(adjacentEvents == [
            .tempo(tick: 0, microsecondsPerQuarterNote: 500_000),
            .text(tick: 0, "D approximate free-time notes; 120 BPM encodes time; velocity 80 is synthetic"),
            .noteOn(tick: 0, note: 69, velocity: 80),
            .noteOff(tick: 154, note: 69),
            .noteOn(tick: 154, note: 72, velocity: 80),
            .noteOff(tick: 307, note: 72),
            .endOfTrack(tick: 307)
        ])

        let reattack = makeResult(frames(440, count: 5) + [unvoiced()] + frames(440, count: 5))
        let reattackEvents = try MIDIFile(PitchMIDIFile.encode(result: reattack)).events
        #expect(reattackEvents.contains(.noteOff(tick: 154, note: 69)))
        #expect(reattackEvents.contains(.noteOn(tick: 184, note: 69, velocity: 80)))
    }

    @Test
    func rejectsSilentShortAndInvalidAnalysisWithoutProducingMIDI() throws {
        #expect(throws: InferenceFailure.self) {
            try PitchMIDIFile.encode(result: makeResult(Array(repeating: unvoiced(), count: 5)))
        }
        #expect(throws: InferenceFailure.self) {
            try PitchMIDIFile.encode(result: makeResult(frames(440, count: 4)))
        }

        let valid = makeResult(frames(440, count: 5))
        let invalid = PitchAnalysisResult(runID: valid.runID, source: valid.source,
                                          inputSHA256: valid.inputSHA256, sampleCount: valid.sampleCount,
                                          frames: valid.frames, profile: "wrong-profile")
        #expect(throws: InferenceFailure.self) { try PitchMIDIFile.encode(result: invalid) }
    }

    private func makeResult(_ values: [PitchFrame], sampleCount: Int? = nil, startFrame: Int64 = 0) -> PitchAnalysisResult {
        let count = sampleCount ?? values.count * 256
        let source = PitchSourceIdentity(assetID: UUID(), documentID: UUID(), documentRevision: 1,
                                         contentSHA256: String(repeating: "a", count: 64), sampleRate: 16_000,
                                         frameCount: startFrame + Int64(count), startFrame: startFrame,
                                         endFrame: startFrame + Int64(count))
        return PitchAnalysisResult(runID: UUID(), source: source, inputSHA256: String(repeating: "b", count: 64),
                                   sampleCount: count, frames: values)
    }

    private func frames(_ pitchHz: Double, count: Int) -> [PitchFrame] {
        Array(repeating: PitchFrame(pitchHz: pitchHz, confidence: 0.95, voiced: true), count: count)
    }

    private func unvoiced() -> PitchFrame {
        PitchFrame(pitchHz: nil, confidence: 0, voiced: false)
    }
}

private struct MIDIFile {
    enum Event: Equatable {
        case tempo(tick: Int, microsecondsPerQuarterNote: Int)
        case text(tick: Int, String)
        case noteOn(tick: Int, note: Int, velocity: Int)
        case noteOff(tick: Int, note: Int)
        case endOfTrack(tick: Int)
    }

    let format: Int
    let trackCount: Int
    let division: Int
    let events: [Event]

    init(_ data: Data) throws {
        var reader = MIDIReader(data)
        #expect(try reader.readASCII(count: 4) == "MThd")
        #expect(try reader.readUInt32() == 6)
        format = try reader.readUInt16()
        trackCount = try reader.readUInt16()
        division = try reader.readUInt16()
        #expect(try reader.readASCII(count: 4) == "MTrk")
        let trackLength = Int(try reader.readUInt32())
        let track = try reader.readData(count: trackLength)
        #expect(reader.isAtEnd)
        events = try Self.parseTrack(track)
    }

    private static func parseTrack(_ data: Data) throws -> [Event] {
        var reader = MIDIReader(data)
        var tick = 0
        var events: [Event] = []
        while !reader.isAtEnd {
            tick += try reader.readVLQ()
            let status = try reader.readByte()
            switch status {
            case 0x80:
                let note = Int(try reader.readByte())
                #expect(try reader.readByte() == 0)
                events.append(.noteOff(tick: tick, note: note))
            case 0x90:
                events.append(.noteOn(tick: tick, note: Int(try reader.readByte()), velocity: Int(try reader.readByte())))
            case 0xFF:
                let type = try reader.readByte()
                let count = try reader.readVLQ()
                let payload = try reader.readData(count: count)
                switch type {
                case 0x51:
                    #expect(payload.count == 3)
                    events.append(.tempo(tick: tick, microsecondsPerQuarterNote: payload.reduce(0) { $0 * 256 + Int($1) }))
                case 0x01:
                    events.append(.text(tick: tick, try #require(String(data: payload, encoding: .ascii))))
                case 0x2F:
                    #expect(payload.isEmpty)
                    events.append(.endOfTrack(tick: tick))
                default:
                    Issue.record("Unexpected meta event")
                }
            default:
                Issue.record("Unexpected MIDI status")
            }
        }
        return events
    }
}

private struct MIDIReader {
    private let data: Data
    private var offset = 0

    init(_ data: Data) { self.data = data }
    var isAtEnd: Bool { offset == data.count }

    mutating func readByte() throws -> UInt8 {
        guard offset < data.count else { throw MIDIParseError.truncated }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func readData(count: Int) throws -> Data {
        guard count >= 0, count <= data.count - offset else { throw MIDIParseError.truncated }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }

    mutating func readASCII(count: Int) throws -> String {
        guard let string = String(data: try readData(count: count), encoding: .ascii) else { throw MIDIParseError.invalid }
        return string
    }

    mutating func readUInt16() throws -> Int {
        Int(try readByte()) * 256 + Int(try readByte())
    }

    mutating func readUInt32() throws -> UInt32 {
        UInt32(try readByte()) << 24 | UInt32(try readByte()) << 16 | UInt32(try readByte()) << 8 | UInt32(try readByte())
    }

    mutating func readVLQ() throws -> Int {
        var value = 0
        for _ in 0..<4 {
            let byte = try readByte()
            value = value * 128 + Int(byte & 0x7F)
            if byte & 0x80 == 0 { return value }
        }
        throw MIDIParseError.invalid
    }
}

private enum MIDIParseError: Error { case truncated, invalid }
