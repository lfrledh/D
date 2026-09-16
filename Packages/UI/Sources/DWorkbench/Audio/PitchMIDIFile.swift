import DInference
import Foundation

/// A deterministic Standard MIDI File representation of approximate free-time pitch notes.
public enum PitchMIDIFile {
    private static let ticksPerQuarterNote = 960
    private static let tempoMicrosecondsPerQuarterNote = 500_000
    private static let text = "D approximate free-time notes; 120 BPM encodes time; velocity 80 is synthetic"

    /// Encodes the validated pitch interpretation as a type-0, single-track SMF.
    public static func encode(result: PitchAnalysisResult) throws -> Data {
        try result.validate()
        let notes = try PitchInterpretation(result: result).notes
        guard !notes.isEmpty else {
            throw InferenceFailure.invalidRequest("Pitch analysis has no exchangeable notes.")
        }

        var events: [Event] = []
        events.reserveCapacity(notes.count * 2)
        for note in notes {
            guard (0...127).contains(note.midiNote),
                  note.startSample >= 0,
                  note.startSample < note.endSample,
                  note.endSample <= result.sampleCount else {
                throw InferenceFailure.invalidRequest("Invalid interpreted pitch note.")
            }
            events.append(Event(tick: tick(forSample: note.startSample), kind: .noteOn(note.midiNote)))
            events.append(Event(tick: tick(forSample: note.endSample), kind: .noteOff(note.midiNote)))
        }
        events.sort()

        var track = Data()
        appendVLQ(0, to: &track)
        track.append(contentsOf: [0xFF, 0x51, 0x03])
        appendBigEndian(tempoMicrosecondsPerQuarterNote, bytes: 3, to: &track)

        let textData = Data(text.utf8)
        appendVLQ(0, to: &track)
        track.append(contentsOf: [0xFF, 0x01])
        appendVLQ(textData.count, to: &track)
        track.append(textData)

        var previousTick = 0
        for event in events {
            appendVLQ(event.tick - previousTick, to: &track)
            switch event.kind {
            case .noteOff(let midiNote):
                track.append(contentsOf: [0x80, UInt8(midiNote), 0])
            case .noteOn(let midiNote):
                track.append(contentsOf: [0x90, UInt8(midiNote), 80])
            }
            previousTick = event.tick
        }

        let endTick = tick(forSample: result.sampleCount)
        guard previousTick <= endTick else {
            throw InferenceFailure.invalidRequest("Pitch note exceeds analysis duration.")
        }
        appendVLQ(endTick - previousTick, to: &track)
        track.append(contentsOf: [0xFF, 0x2F, 0x00])

        var file = Data("MThd".utf8)
        appendBigEndian(6, bytes: 4, to: &file)
        appendBigEndian(0, bytes: 2, to: &file)
        appendBigEndian(1, bytes: 2, to: &file)
        appendBigEndian(ticksPerQuarterNote, bytes: 2, to: &file)
        file.append(Data("MTrk".utf8))
        appendBigEndian(track.count, bytes: 4, to: &file)
        file.append(track)
        return file
    }

    private static func tick(forSample sample: Int) -> Int {
        (sample * 3 + 12) / 25
    }

    private static func appendBigEndian(_ value: Int, bytes: Int, to data: inout Data) {
        for shift in stride(from: (bytes - 1) * 8, through: 0, by: -8) {
            data.append(UInt8((value >> shift) & 0xFF))
        }
    }

    private static func appendVLQ(_ value: Int, to data: inout Data) {
        var bytes = [UInt8(value & 0x7F)]
        var remaining = value >> 7
        while remaining > 0 {
            bytes.append(UInt8(remaining & 0x7F) | 0x80)
            remaining >>= 7
        }
        data.append(contentsOf: bytes.reversed())
    }

    private struct Event: Comparable {
        enum Kind: Comparable {
            case noteOff(Int)
            case noteOn(Int)
        }

        let tick: Int
        let kind: Kind

        static func < (lhs: Event, rhs: Event) -> Bool {
            if lhs.tick != rhs.tick { return lhs.tick < rhs.tick }
            return lhs.kind < rhs.kind
        }
    }
}
