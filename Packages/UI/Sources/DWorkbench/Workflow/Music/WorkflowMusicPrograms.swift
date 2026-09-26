import CryptoKit
import Foundation

public enum WorkflowMusicSnap: String, Codable, Sendable, Equatable, CaseIterable {
    case none
    case quarter
    case eighth
    case sixteenth

    fileprivate var step: Double? {
        switch self {
        case .none: nil
        case .quarter: 1
        case .eighth: 0.5
        case .sixteenth: 0.25
        }
    }
}

public enum WorkflowChordPattern: String, Codable, Sendable, Equatable, CaseIterable {
    case sustained
    case arpeggio
}

public struct WorkflowKeyCandidate: Codable, Sendable, Equatable {
    public var root: Int
    public var mode: String
    public var score: Double
    public var algorithm: String

    public init(root: Int, mode: String, score: Double,
                algorithm: String = "duration-scale-triad-v1") {
        self.root = root
        self.mode = mode
        self.score = score
        self.algorithm = algorithm
    }
}

public enum WorkflowMusicPrograms {
    /// Converts a seconds sequence to quarter notes. Snapping uses
    /// `toNearestOrAwayFromZero`; a collapsed interval is extended by one grid
    /// step, so the returned note boundaries are the boundaries callers show.
    public static func align(sequence: WorkflowNoteSequence, tempo: WorkflowTempoMap,
                             snap: WorkflowMusicSnap) throws -> WorkflowNoteSequence {
        try sequence.validate()
        try tempo.validate()
        guard sequence.clock == .seconds else {
            throw WorkflowIssue("Music alignment accepts seconds input only; it never remaps beat input implicitly.")
        }

        func beat(_ seconds: Double) -> Double {
            (seconds - tempo.firstBeatSeconds) * tempo.beatsPerMinute / 60
        }
        func snapped(_ value: Double) -> Double {
            guard let step = snap.step else { return value }
            return (value / step).rounded(.toNearestOrAwayFromZero) * step
        }

        var mapped: [WorkflowNoteEvent] = []
        mapped.reserveCapacity(sequence.notes.count)
        var latestEnd = 0.0
        for note in sequence.notes {
            var start = snapped(beat(note.start))
            var end = snapped(beat(note.end))
            if let step = snap.step, end <= start { end = start + step }
            guard start.isFinite, end.isFinite, start < end else {
                throw WorkflowIssue("Aligned note boundaries are invalid.")
            }
            mapped.append(.init(id: note.id, pitch: note.pitch, start: start,
                                end: end, velocity: note.velocity))
            latestEnd = max(latestEnd, end)
        }

        let mappedOriginalDuration = beat(sequence.duration)
        let duration = max(0, max(mappedOriginalDuration, latestEnd))
        let result = WorkflowNoteSequence(clock: .quarterNotes, notes: mapped,
                                          duration: duration, tempo: tempo,
                                          sources: sequence.sources)
        try result.validate()
        return result
    }

    /// Scores duration-weighted pitch-class membership. Velocity-zero notes are
    /// silent and are excluded; other velocities do not change the duration weight.
    public static func keys(sequence: WorkflowNoteSequence) throws -> [WorkflowKeyCandidate] {
        try sequence.validate()
        let audible = sequence.notes.filter { $0.velocity > 0 }
        let pitchClasses = Set(audible.map { positiveModulo($0.pitch, 12) })
        guard audible.count >= 3, pitchClasses.count >= 3 else { return [] }

        let totalDuration = audible.reduce(0.0) { $0 + ($1.end - $1.start) }
        guard totalDuration > 0 else { return [] }

        let definitions: [(mode: String, scale: Set<Int>, triad: Set<Int>)] = [
            ("major", Set([0, 2, 4, 5, 7, 9, 11]), Set([0, 4, 7])),
            ("minor", Set([0, 2, 3, 5, 7, 8, 10]), Set([0, 3, 7])),
        ]
        var candidates: [WorkflowKeyCandidate] = []
        candidates.reserveCapacity(24)
        for root in 0..<12 {
            for definition in definitions {
                var fit = 0.0
                for note in audible {
                    let relative = positiveModulo(note.pitch - root, 12)
                    let duration = note.end - note.start
                    if definition.scale.contains(relative) { fit += duration }
                    if definition.triad.contains(relative) { fit += duration * 0.25 }
                }
                candidates.append(.init(root: root, mode: definition.mode,
                                        score: fit / (totalDuration * 1.25)))
            }
        }
        candidates.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.root != $1.root { return $0.root < $1.root }
            return $0.mode < $1.mode
        }
        return Array(candidates.prefix(6))
    }

    public static func chordNotes(track: WorkflowChordTrack,
                                  pattern: WorkflowChordPattern) throws -> WorkflowNoteSequence {
        try track.validate()
        var notes: [WorkflowNoteEvent] = []
        for chord in track.chords {
            let pitches = try chord.voicedPitches()
            switch pattern {
            case .sustained:
                for (index, pitch) in pitches.enumerated() {
                    notes.append(.init(id: derivedNoteID(sourceID: chord.id, pattern: pattern, index: index), pitch: pitch,
                                       start: chord.start, end: chord.end, velocity: 1))
                }
            case .arpeggio:
                var cursor = chord.start
                var index = 0
                while cursor < chord.end {
                    let end = min(cursor + 0.5, chord.end)
                    notes.append(.init(id: derivedNoteID(sourceID: chord.id, pattern: pattern, index: index),
                                       pitch: pitches[index % pitches.count],
                                       start: cursor, end: end, velocity: 1))
                    cursor = end
                    index += 1
                    guard notes.count <= 4_096 else {
                        throw WorkflowIssue("Generated chord notes exceed the 4096-note limit.")
                    }
                }
            }
        }
        let result = WorkflowNoteSequence(clock: .quarterNotes, notes: notes,
                                          duration: track.duration, tempo: track.tempo,
                                          sources: track.sources)
        try result.validate()
        return result
    }

    public static func render(sequence: WorkflowNoteSequence,
                              sampleRate: Int = 48_000) throws -> Data {
        try Task.checkCancellation()
        try sequence.validate()
        guard [16_000, 44_100, 48_000].contains(sampleRate) else {
            throw WorkflowIssue("Reference render sample rate must be 16000, 44100, or 48000.")
        }
        if sequence.clock == .quarterNotes, sequence.tempo == nil {
            throw WorkflowIssue("Beat-clock rendering requires a tempo map.")
        }
        let secondsPerBeat = sequence.tempo.map { 60 / $0.beatsPerMinute }
        let origin = sequence.tempo?.firstBeatSeconds ?? 0
        func seconds(_ value: Double) -> Double {
            switch sequence.clock {
            case .seconds: value
            case .quarterNotes: origin + value * secondsPerBeat!
            }
        }

        let durationSeconds = seconds(sequence.duration)
        guard durationSeconds.isFinite, durationSeconds > 0, durationSeconds <= 120 else {
            throw WorkflowIssue("Reference rendering requires audible-length duration in 0...120 seconds.")
        }
        guard sequence.notes.allSatisfy({ seconds($0.start) >= 0 && seconds($0.end) >= 0 }) else {
            throw WorkflowIssue("Reference rendering rejects events mapped before the timeline origin; crop the pickup first.")
        }

        let audible = try sequence.notes.compactMap { note -> RenderNote? in
            guard note.velocity > 0 else { return nil }
            let start = seconds(note.start)
            let end = seconds(note.end)
            guard start >= 0, end > start, end <= durationSeconds else {
                throw WorkflowIssue("Rendered note maps outside the nonnegative output duration.")
            }
            return RenderNote(pitch: note.pitch, start: start, end: end, velocity: note.velocity)
        }
        try validatePolyphony(audible)

        var computationFrames = 0
        for note in audible {
            let frames = (note.end - note.start) * Double(sampleRate)
            guard frames.isFinite, frames <= Double(Int.max) else { throw WorkflowIssue("Reference render budget overflow.") }
            let rounded = Int(frames.rounded(.up))
            guard computationFrames <= 100_000_000 - rounded else {
                throw WorkflowIssue("Reference render exceeds the 100M note-sample budget.")
            }
            computationFrames += rounded
        }

        let frameDouble = durationSeconds * Double(sampleRate)
        guard frameDouble <= Double(Int.max) else { throw WorkflowIssue("Reference render frame count overflow.") }
        let frameCount = Int(frameDouble.rounded(.up))
        var samples = [Float](repeating: 0, count: frameCount)
        let attack = 0.005
        let release = 0.020

        for (noteIndex, note) in audible.enumerated() {
            if noteIndex & 31 == 0 { try Task.checkCancellation() }
            let firstFrame = max(0, Int((note.start * Double(sampleRate)).rounded(.up)))
            let endFrame = min(frameCount, Int((note.end * Double(sampleRate)).rounded(.up)))
            let frequency = 440 * pow(2, Double(note.pitch - 69) / 12)
            if firstFrame >= endFrame { continue }
            for frame in firstFrame..<endFrame {
                if frame & 4_095 == 0 { try Task.checkCancellation() }
                let time = Double(frame) / Double(sampleRate)
                let local = max(0, time - note.start)
                let remaining = max(0, note.end - time)
                let envelope = min(1, min(local / attack, remaining / release))
                let value = sin(2 * Double.pi * frequency * local) * 0.2 * note.velocity * envelope
                samples[frame] += Float(value)
            }
        }

        var peak = 0.0
        for index in samples.indices {
            if index & 4_095 == 0 { try Task.checkCancellation() }
            peak = max(peak, abs(Double(samples[index])))
        }
        if peak > 0.95 {
            let scale = Float(0.95 / peak)
            for index in samples.indices {
                if index & 4_095 == 0 { try Task.checkCancellation() }
                samples[index] *= scale
            }
        }
        try Task.checkCancellation()
        let wave = try encodeFloat32WAV(samples: samples, sampleRate: sampleRate)
        try Task.checkCancellation()
        return wave
    }

    public static func midi(sequence: WorkflowNoteSequence) throws -> Data {
        try sequence.validate()
        if sequence.clock == .quarterNotes, sequence.tempo == nil {
            throw WorkflowIssue("Beat-clock MIDI requires a tempo map.")
        }
        let tempoBPM = sequence.clock == .seconds ? 120 : sequence.tempo!.beatsPerMinute
        let micros = Int((60_000_000 / tempoBPM).rounded(.toNearestOrAwayFromZero))
        guard (1...0xFF_FFFF).contains(micros) else { throw WorkflowIssue("MIDI tempo is outside the three-byte range.") }

        func timelineQuarterNotes(_ value: Double) -> Double {
            switch sequence.clock {
            case .seconds:
                value * 2 // Seconds-clock MIDI always uses 120 BPM for time encoding.
            case .quarterNotes:
                let mappedSeconds = sequence.tempo!.firstBeatSeconds + value * 60 / tempoBPM
                return mappedSeconds * tempoBPM / 60
            }
        }
        func tick(_ value: Double) throws -> Int {
            let scaled = timelineQuarterNotes(value) * 960
            guard scaled.isFinite, scaled >= 0, scaled <= Double(Int.max) else {
                throw WorkflowIssue("MIDI tick is outside its safe range.")
            }
            return Int(scaled.rounded(.toNearestOrAwayFromZero))
        }
        guard sequence.notes.allSatisfy({
            timelineQuarterNotes($0.start) >= 0 && timelineQuarterNotes($0.end) >= 0
        }) else {
            throw WorkflowIssue("MIDI export rejects events mapped before the timeline origin; crop the pickup first.")
        }

        var byPitch: [Int: [(start: Double, end: Double, startTick: Int, endTick: Int)]] = [:]
        var events: [MIDIEvent] = []
        for note in sequence.notes where note.velocity > 0 {
            let mappedStart = timelineQuarterNotes(note.start)
            let mappedEnd = timelineQuarterNotes(note.end)
            let startTick = try tick(note.start)
            let endTick = try tick(note.end)
            guard endTick > startTick else { throw WorkflowIssue("MIDI quantization collapsed a note to zero length.") }
            let prior = byPitch[note.pitch] ?? []
            guard prior.allSatisfy({ mappedStart >= $0.end || mappedEnd <= $0.start }) else {
                throw WorkflowIssue("MIDI export rejects overlapping notes of the same pitch.")
            }
            guard prior.allSatisfy({ startTick >= $0.endTick || endTick <= $0.startTick }) else {
                throw WorkflowIssue("MIDI tick quantization created a same-pitch overlap.")
            }
            byPitch[note.pitch, default: []].append((mappedStart, mappedEnd, startTick, endTick))
            let velocity = max(1, min(127, Int((note.velocity * 127).rounded(.toNearestOrAwayFromZero))))
            events.append(.init(tick: startTick, pitch: note.pitch, velocity: velocity, isOn: true))
            events.append(.init(tick: endTick, pitch: note.pitch, velocity: 0, isOn: false))
        }
        events.sort()

        let durationTick = try tick(sequence.duration)
        guard durationTick >= (events.last?.tick ?? 0) else { throw WorkflowIssue("MIDI duration precedes its final note event.") }

        var track = Data()
        try appendVLQ(0, to: &track)
        track.append(contentsOf: [0xFF, 0x51, 0x03])
        appendBigEndian(micros, byteCount: 3, to: &track)

        var previousTick = 0
        for event in events {
            try appendVLQ(event.tick - previousTick, to: &track)
            track.append(event.isOn ? 0x90 : 0x80)
            track.append(UInt8(event.pitch))
            track.append(UInt8(event.velocity))
            previousTick = event.tick
        }
        try appendVLQ(durationTick - previousTick, to: &track)
        track.append(contentsOf: [0xFF, 0x2F, 0x00])

        guard track.count <= Int(UInt32.max) else { throw WorkflowIssue("MIDI track is too large.") }
        var file = Data("MThd".utf8)
        appendBigEndian(6, byteCount: 4, to: &file)
        appendBigEndian(0, byteCount: 2, to: &file)
        appendBigEndian(1, byteCount: 2, to: &file)
        appendBigEndian(960, byteCount: 2, to: &file)
        file.append(Data("MTrk".utf8))
        appendBigEndian(track.count, byteCount: 4, to: &file)
        file.append(track)
        return file
    }
}

private struct RenderNote {
    let pitch: Int
    let start: Double
    let end: Double
    let velocity: Double
}

private func derivedNoteID(sourceID: String, pattern: WorkflowChordPattern,
                           index: Int) -> String {
    let payload = "\(sourceID.utf8.count):\(sourceID)|\(pattern.rawValue.utf8.count):\(pattern.rawValue)|\(index)"
    let digest = SHA256.hash(data: Data(payload.utf8)).map { String(format: "%02x", $0) }.joined()
    return "d.music.note.\(digest)"
}

private func validatePolyphony(_ notes: [RenderNote]) throws {
    var boundaries: [(time: Double, delta: Int)] = []
    boundaries.reserveCapacity(notes.count * 2)
    for note in notes {
        boundaries.append((note.start, 1))
        boundaries.append((note.end, -1))
    }
    boundaries.sort {
        if $0.time != $1.time { return $0.time < $1.time }
        return $0.delta < $1.delta // Half-open intervals: endings precede starts.
    }
    var active = 0
    for boundary in boundaries {
        active += boundary.delta
        guard active <= 32 else { throw WorkflowIssue("Reference render exceeds 32 simultaneous notes.") }
    }
}

private func encodeFloat32WAV(samples: [Float], sampleRate: Int) throws -> Data {
    try Task.checkCancellation()
    let dataByteCount = samples.count * MemoryLayout<Float>.size
    guard dataByteCount <= Int(UInt32.max) - 36 else { throw WorkflowIssue("WAV output is too large.") }
    var wave = Data(count: 44 + dataByteCount)
    try wave.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) throws in
        writeASCII("RIFF", at: 0, to: bytes)
        writeLittleEndian(UInt32(36 + dataByteCount), at: 4, to: bytes)
        writeASCII("WAVE", at: 8, to: bytes)
        writeASCII("fmt ", at: 12, to: bytes)
        writeLittleEndian(UInt32(16), at: 16, to: bytes)
        writeLittleEndian(UInt16(3), at: 20, to: bytes) // IEEE Float
        writeLittleEndian(UInt16(1), at: 22, to: bytes)
        writeLittleEndian(UInt32(sampleRate), at: 24, to: bytes)
        writeLittleEndian(UInt32(sampleRate * 4), at: 28, to: bytes)
        writeLittleEndian(UInt16(4), at: 32, to: bytes)
        writeLittleEndian(UInt16(32), at: 34, to: bytes)
        writeASCII("data", at: 36, to: bytes)
        writeLittleEndian(UInt32(dataByteCount), at: 40, to: bytes)
        for (index, sample) in samples.enumerated() {
            if index & 4_095 == 0 { try Task.checkCancellation() }
            writeLittleEndian(sample.bitPattern, at: 44 + index * 4, to: bytes)
        }
    }
    try Task.checkCancellation()
    return wave
}

private func positiveModulo(_ value: Int, _ modulus: Int) -> Int {
    let result = value % modulus
    return result >= 0 ? result : result + modulus
}

private struct MIDIEvent: Comparable {
    let tick: Int
    let pitch: Int
    let velocity: Int
    let isOn: Bool

    static func < (lhs: MIDIEvent, rhs: MIDIEvent) -> Bool {
        if lhs.tick != rhs.tick { return lhs.tick < rhs.tick }
        if lhs.isOn != rhs.isOn { return !lhs.isOn } // note-off before note-on
        if lhs.pitch != rhs.pitch { return lhs.pitch < rhs.pitch }
        return lhs.velocity < rhs.velocity
    }
}

private func appendBigEndian(_ value: Int, byteCount: Int, to data: inout Data) {
    for shift in stride(from: (byteCount - 1) * 8, through: 0, by: -8) {
        data.append(UInt8((value >> shift) & 0xFF))
    }
}

private func appendVLQ(_ value: Int, to data: inout Data) throws {
    guard (0...0x0FFF_FFFF).contains(value) else { throw WorkflowIssue("MIDI VLQ value is outside its safe range.") }
    var bytes = [UInt8(value & 0x7F)]
    var remaining = value >> 7
    while remaining > 0 {
        bytes.append(UInt8(remaining & 0x7F) | 0x80)
        remaining >>= 7
    }
    data.append(contentsOf: bytes.reversed())
}

private func writeASCII(_ value: String, at offset: Int,
                        to bytes: UnsafeMutableRawBufferPointer) {
    for (index, byte) in value.utf8.enumerated() { bytes[offset + index] = byte }
}

private func writeLittleEndian(_ value: UInt16, at offset: Int,
                               to bytes: UnsafeMutableRawBufferPointer) {
    bytes[offset] = UInt8(truncatingIfNeeded: value)
    bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
}

private func writeLittleEndian(_ value: UInt32, at offset: Int,
                               to bytes: UnsafeMutableRawBufferPointer) {
    bytes[offset] = UInt8(truncatingIfNeeded: value)
    bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    bytes[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
    bytes[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
}
