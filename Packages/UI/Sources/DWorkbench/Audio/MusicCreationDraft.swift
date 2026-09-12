import DInference
import Foundation

/// Editable note text is preserved exactly so incomplete or invalid work can still be saved.
public struct MusicNoteDraft: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var pitchText: String
    public var startText: String
    public var durationText: String

    public init(id: UUID = UUID(), pitchText: String = "", startText: String = "",
                durationText: String = "") {
        self.id = id
        self.pitchText = pitchText
        self.startText = startText
        self.durationText = durationText
    }
}

/// A saveable editing draft. Validation happens only when an immutable sequence is requested.
public struct MusicCreationDraft: Codable, Sendable, Equatable {
    public var notes: [MusicNoteDraft]
    /// `false` means absent conditioning; `true` with no rows means explicit empty conditioning.
    public var hasNoteCondition: Bool

    public init(notes: [MusicNoteDraft] = [], hasNoteCondition: Bool = false) {
        self.notes = notes
        self.hasNoteCondition = hasNoteCondition
    }

    public static var example: Self {
        Self(notes: [
            MusicNoteDraft(pitchText: "C4", startText: "0", durationText: "1.2"),
            MusicNoteDraft(pitchText: "E4", startText: "0", durationText: "1.2"),
            MusicNoteDraft(pitchText: "G4", startText: "0", durationText: "1.2")
        ], hasNoteCondition: true)
    }

    public func makeSequence(durationText: String) throws -> AudioNoteSequence {
        let durationFrames = try MusicDraftValue.frames(
            from: durationText,
            allowingZero: false,
            field: "duration"
        )

        let events: [AudioNoteEvent]?
        if hasNoteCondition {
            guard notes.count <= 512 else {
                throw InferenceFailure.invalidRequest("A music condition accepts at most 512 note rows.")
            }
            events = try notes.map { note in
                let pitch = try MusicDraftValue.pitch(from: note.pitchText)
                let startFrame = try MusicDraftValue.frames(
                    from: note.startText,
                    allowingZero: true,
                    field: "note start"
                )
                let noteDuration = try MusicDraftValue.frames(
                    from: note.durationText,
                    allowingZero: false,
                    field: "note duration"
                )
                let (endFrame, overflow) = startFrame.addingReportingOverflow(noteDuration)
                guard !overflow else {
                    throw InferenceFailure.invalidRequest("A note interval is too large.")
                }
                return AudioNoteEvent(pitch: pitch, startFrame: startFrame, endFrame: endFrame)
            }
        } else {
            events = nil
        }

        let sequence = AudioNoteSequence(durationFrames: durationFrames, notes: events)
        try sequence.validate()
        return sequence
    }
}

private enum MusicDraftValue {
    private static let maximumTimeBytes = 64
    private static let maximumPitchBytes = 16

    static func frames(from text: String, allowingZero: Bool, field: String) throws -> Int {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty, bytes.count <= maximumTimeBytes else {
            throw InferenceFailure.invalidRequest("Invalid \(field).")
        }

        var dot: Int?
        for (index, byte) in bytes.enumerated() {
            if byte == 46 {
                guard dot == nil else {
                    throw InferenceFailure.invalidRequest("Invalid \(field).")
                }
                dot = index
            } else if !(48...57).contains(byte) {
                throw InferenceFailure.invalidRequest("Invalid \(field).")
            }
        }

        let wholeEnd = dot ?? bytes.count
        guard wholeEnd > 0, dot.map({ $0 + 1 < bytes.count }) ?? true else {
            throw InferenceFailure.invalidRequest("Invalid \(field).")
        }

        var whole = 0
        for byte in bytes[..<wholeEnd] {
            let (scaled, multiplyOverflow) = whole.multipliedReportingOverflow(by: 10)
            let (next, addOverflow) = scaled.addingReportingOverflow(Int(byte - 48))
            guard !multiplyOverflow, !addOverflow else {
                throw InferenceFailure.invalidRequest("Invalid \(field).")
            }
            whole = next
        }

        var fraction = dot.map { Array(bytes[($0 + 1)...]) } ?? []
        while fraction.last == 48 { fraction.removeLast() }
        guard fraction.count <= 2 else {
            throw InferenceFailure.invalidRequest("\(field.capitalized) must align to 40 ms frames.")
        }

        var hundredths = 0
        if fraction.count == 1 {
            hundredths = Int(fraction[0] - 48) * 10
        } else if fraction.count == 2 {
            hundredths = Int(fraction[0] - 48) * 10 + Int(fraction[1] - 48)
        }
        guard hundredths.isMultiple(of: 4) else {
            throw InferenceFailure.invalidRequest("\(field.capitalized) must align to 40 ms frames.")
        }

        let (wholeFrames, multiplyOverflow) = whole.multipliedReportingOverflow(by: 25)
        let (frames, addOverflow) = wholeFrames.addingReportingOverflow(hundredths / 4)
        guard !multiplyOverflow, !addOverflow, allowingZero ? frames >= 0 : frames > 0 else {
            throw InferenceFailure.invalidRequest("Invalid \(field).")
        }
        return frames
    }

    static func pitch(from text: String) throws -> Int {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty, bytes.count <= maximumPitchBytes else {
            throw InferenceFailure.invalidRequest("Invalid note pitch.")
        }

        if bytes.allSatisfy({ (48...57).contains($0) }) {
            guard let pitch = Int(text), (0...127).contains(pitch) else {
                throw InferenceFailure.invalidRequest("Note pitch must be in the MIDI range 0 through 127.")
            }
            return pitch
        }

        let pitchClass: Int
        switch bytes[0] {
        case 67: pitchClass = 0  // C
        case 68: pitchClass = 2  // D
        case 69: pitchClass = 4  // E
        case 70: pitchClass = 5  // F
        case 71: pitchClass = 7  // G
        case 65: pitchClass = 9  // A
        case 66: pitchClass = 11 // B
        default: throw InferenceFailure.invalidRequest("Invalid note name.")
        }

        var cursor = 1
        var accidental = 0
        if cursor < bytes.count, bytes[cursor] == 35 || bytes[cursor] == 98 {
            accidental = bytes[cursor] == 35 ? 1 : -1
            cursor += 1
        }
        guard cursor < bytes.count else {
            throw InferenceFailure.invalidRequest("A note name requires an octave.")
        }

        let octaveBytes = Array(bytes[cursor...])
        let octave: Int
        if octaveBytes == [45, 49] {
            octave = -1
        } else {
            guard octaveBytes.allSatisfy({ (48...57).contains($0) }),
                  let parsed = Int(String(decoding: octaveBytes, as: UTF8.self)) else {
                throw InferenceFailure.invalidRequest("Invalid note octave.")
            }
            octave = parsed
        }

        let (octaveBase, addOverflow) = octave.addingReportingOverflow(1)
        let (scaledOctave, multiplyOverflow) = octaveBase.multipliedReportingOverflow(by: 12)
        let (naturalPitch, classOverflow) = scaledOctave.addingReportingOverflow(pitchClass)
        let (pitch, accidentalOverflow) = naturalPitch.addingReportingOverflow(accidental)
        guard !addOverflow, !multiplyOverflow, !classOverflow, !accidentalOverflow,
              (0...127).contains(pitch) else {
            throw InferenceFailure.invalidRequest("Note pitch must be in the MIDI range 0 through 127.")
        }
        return pitch
    }
}
