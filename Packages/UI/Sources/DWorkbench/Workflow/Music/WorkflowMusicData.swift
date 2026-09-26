import Foundation

public enum WorkflowMusicClock: String, Codable, Sendable, Equatable, CaseIterable {
    case seconds
    case quarterNotes

    fileprivate var unit: String {
        switch self {
        case .seconds: "s"
        case .quarterNotes: "quarterNote"
        }
    }

    fileprivate var limit: Double {
        switch self {
        case .seconds: 120
        case .quarterNotes: 512
        }
    }
}

public struct WorkflowNoteEvent: Codable, Sendable, Equatable {
    public var id: String
    public var pitch: Int
    public var start: Double
    public var end: Double
    public var velocity: Double

    public init(id: String, pitch: Int, start: Double, end: Double, velocity: Double) {
        self.id = id
        self.pitch = pitch
        self.start = start
        self.end = end
        self.velocity = velocity
    }
}

public struct WorkflowTempoMap: Codable, Sendable, Equatable {
    public var beatsPerMinute: Double
    public var firstBeatSeconds: Double
    public var numerator: Int
    public var denominator: Int

    public init(beatsPerMinute: Double, firstBeatSeconds: Double,
                numerator: Int, denominator: Int) {
        self.beatsPerMinute = beatsPerMinute
        self.firstBeatSeconds = firstBeatSeconds
        self.numerator = numerator
        self.denominator = denominator
    }

    public static var schema: WorkflowDataSchema { .record(schemaFields) }

    public func validate() throws {
        guard beatsPerMinute.isFinite, (20...300).contains(beatsPerMinute) else {
            throw WorkflowIssue("Tempo BPM must be finite and in 20...300.")
        }
        guard firstBeatSeconds.isFinite, (-120...120).contains(firstBeatSeconds) else {
            throw WorkflowIssue("Tempo firstBeatSeconds must be in -120...120.")
        }
        guard (1...16).contains(numerator), [2, 4, 8, 16].contains(denominator) else {
            throw WorkflowIssue("Tempo time signature is outside the supported range.")
        }
    }

    public func datum() throws -> WorkflowDatum {
        try validate()
        return .record(schema: Self.schemaFields, fields: [
            "format": .text("d.music.tempo"),
            "version": .number(1, unit: nil),
            "beatsPerMinute": .number(beatsPerMinute, unit: "BPM"),
            "firstBeatSeconds": .number(firstBeatSeconds, unit: "s"),
            "numerator": .number(Double(numerator), unit: nil),
            "denominator": .number(Double(denominator), unit: nil),
        ])
    }

    public init(datum: WorkflowDatum) throws {
        let fields = try musicRecord(datum, expected: Self.schema)
        try musicRequireText(fields, "format", equals: "d.music.tempo")
        try musicRequireVersion(fields)
        beatsPerMinute = try musicNumber(fields, "beatsPerMinute", unit: "BPM")
        firstBeatSeconds = try musicNumber(fields, "firstBeatSeconds", unit: "s")
        numerator = try musicInteger(fields, "numerator", unit: nil)
        denominator = try musicInteger(fields, "denominator", unit: nil)
        try validate()
    }

    fileprivate static let schemaFields: [WorkflowRecordField] = [
        .init("format", .text),
        .init("version", .number(unit: nil)),
        .init("beatsPerMinute", .number(unit: "BPM")),
        .init("firstBeatSeconds", .number(unit: "s")),
        .init("numerator", .number(unit: nil)),
        .init("denominator", .number(unit: nil)),
    ]
}

public struct WorkflowNoteSequence: Codable, Sendable, Equatable {
    public var version: Int
    public var clock: WorkflowMusicClock
    public var notes: [WorkflowNoteEvent]
    public var duration: Double
    public var tempo: WorkflowTempoMap?
    public var sources: [WorkflowAssetReference]

    public init(version: Int = 1, clock: WorkflowMusicClock,
                notes: [WorkflowNoteEvent], duration: Double,
                tempo: WorkflowTempoMap? = nil,
                sources: [WorkflowAssetReference] = []) {
        self.version = version
        self.clock = clock
        self.notes = notes
        self.duration = duration
        self.tempo = tempo
        self.sources = sources
    }

    public static func schema(clock: WorkflowMusicClock) -> WorkflowDataSchema {
        .record(schemaFields(clock: clock))
    }

    public func validate() throws {
        guard version == 1 else { throw WorkflowIssue("Unsupported note-sequence version.") }
        guard duration.isFinite, duration >= 0 else {
            throw WorkflowIssue("Note-sequence duration must be a finite nonnegative endpoint.")
        }
        guard notes.count <= 4_096 else { throw WorkflowIssue("A note sequence may contain at most 4096 notes.") }
        guard Set(notes.map(\.id)).count == notes.count else { throw WorkflowIssue("Note IDs must be unique.") }

        var earliest = 0.0
        for note in notes {
            guard !note.id.isEmpty, note.id.utf8.count <= 256 else { throw WorkflowIssue("Note ID is empty or too long.") }
            guard (0...127).contains(note.pitch) else { throw WorkflowIssue("Note pitch must be in MIDI 0...127.") }
            guard note.start.isFinite, note.end.isFinite, note.velocity.isFinite else {
                throw WorkflowIssue("Note time and velocity must be finite.")
            }
            guard note.start >= -clock.limit, note.end >= -clock.limit,
                  note.start < note.end, note.end <= duration else {
                throw WorkflowIssue("Note interval is outside the sequence endpoint or pickup limit.")
            }
            guard (0...1).contains(note.velocity) else { throw WorkflowIssue("Note velocity must be in 0...1.") }
            earliest = min(earliest, note.start)
        }
        guard duration - earliest <= clock.limit else {
            throw WorkflowIssue("Note-sequence occupied span exceeds the clock budget.")
        }
        try tempo?.validate()
        try musicValidateSources(sources)
    }

    public func datum() throws -> WorkflowDatum {
        try validate()
        let noteFields = Self.noteFields(clock: clock)
        let noteItems = notes.map { note in
            WorkflowDataItem(id: note.id, value: .record(schema: noteFields, fields: [
                "id": .text(note.id),
                "pitch": .number(Double(note.pitch), unit: "MIDI"),
                "start": .number(note.start, unit: clock.unit),
                "end": .number(note.end, unit: clock.unit),
                "velocity": .number(note.velocity, unit: nil),
            ]))
        }
        return .record(schema: Self.schemaFields(clock: clock), fields: [
            "format": .text("d.music.notes"),
            "version": .number(Double(version), unit: nil),
            "clock": .enumeration(clock.rawValue, choices: WorkflowMusicClock.allCases.map(\.rawValue)),
            "duration": .number(duration, unit: clock.unit),
            "notes": .list(element: .record(noteFields), items: noteItems),
            "tempo": try tempo?.datum() ?? .none(WorkflowTempoMap.schema),
            "sources": try musicSourcesDatum(sources),
        ])
    }

    public init(datum: WorkflowDatum) throws {
        let clock = try musicClock(in: datum)
        let fields = try musicRecord(datum, expected: Self.schema(clock: clock))
        try musicRequireText(fields, "format", equals: "d.music.notes")
        version = try musicInteger(fields, "version", unit: nil)
        self.clock = clock
        duration = try musicNumber(fields, "duration", unit: clock.unit)

        guard case .list(_, let items)? = fields["notes"] else { throw WorkflowIssue("Missing typed notes list.") }
        notes = try items.map { item in
            let noteFields = try musicRecord(item.value, expected: .record(Self.noteFields(clock: clock)))
            let id = try musicText(noteFields, "id")
            guard item.id == id else { throw WorkflowIssue("Note list identity does not match note ID.") }
            return WorkflowNoteEvent(
                id: id,
                pitch: try musicInteger(noteFields, "pitch", unit: "MIDI"),
                start: try musicNumber(noteFields, "start", unit: clock.unit),
                end: try musicNumber(noteFields, "end", unit: clock.unit),
                velocity: try musicNumber(noteFields, "velocity", unit: nil)
            )
        }

        guard let tempoDatum = fields["tempo"] else { throw WorkflowIssue("Missing tempo field.") }
        if case .none(let declared) = tempoDatum {
            guard declared == WorkflowTempoMap.schema else { throw WorkflowIssue("Tempo optional schema is invalid.") }
            tempo = nil
        } else {
            tempo = try WorkflowTempoMap(datum: tempoDatum)
        }
        sources = try musicSources(from: fields["sources"])
        try validate()
    }

    fileprivate static func noteFields(clock: WorkflowMusicClock) -> [WorkflowRecordField] {
        [
            .init("id", .text),
            .init("pitch", .number(unit: "MIDI")),
            .init("start", .number(unit: clock.unit)),
            .init("end", .number(unit: clock.unit)),
            .init("velocity", .number(unit: nil)),
        ]
    }

    fileprivate static func schemaFields(clock: WorkflowMusicClock) -> [WorkflowRecordField] {
        [
            .init("format", .text),
            .init("version", .number(unit: nil)),
            .init("clock", .enumeration(WorkflowMusicClock.allCases.map(\.rawValue))),
            .init("duration", .number(unit: clock.unit)),
            .init("notes", .list(.record(noteFields(clock: clock)))),
            .init("tempo", .optional(WorkflowTempoMap.schema)),
            .init("sources", musicSourcesSchema),
        ]
    }
}

public enum WorkflowChordQuality: String, Codable, Sendable, Equatable, CaseIterable {
    case major
    case minor
    case dominant7
    case major7
    case minor7
    case diminished

    var intervals: [Int] {
        switch self {
        case .major: [0, 4, 7]
        case .minor: [0, 3, 7]
        case .dominant7: [0, 4, 7, 10]
        case .major7: [0, 4, 7, 11]
        case .minor7: [0, 3, 7, 10]
        case .diminished: [0, 3, 6]
        }
    }
}

public struct WorkflowChordEvent: Codable, Sendable, Equatable {
    public var id: String
    public var root: Int
    public var quality: WorkflowChordQuality
    public var octave: Int
    public var inversion: Int
    public var start: Double
    public var end: Double

    public init(id: String, root: Int, quality: WorkflowChordQuality,
                octave: Int, inversion: Int, start: Double, end: Double) {
        self.id = id
        self.root = root
        self.quality = quality
        self.octave = octave
        self.inversion = inversion
        self.start = start
        self.end = end
    }

    func voicedPitches() throws -> [Int] {
        guard (0...11).contains(root), (-1...9).contains(octave),
              quality.intervals.indices.contains(inversion) else {
            throw WorkflowIssue("Chord root, octave, or inversion is outside its supported range.")
        }
        let rootPitch = (octave + 1) * 12 + root
        var pitches = quality.intervals.map { rootPitch + $0 }
        for index in 0..<inversion { pitches[index] += 12 }
        pitches.sort()
        guard pitches.allSatisfy({ (0...127).contains($0) }) else {
            throw WorkflowIssue("Chord voicing exceeds MIDI 0...127.")
        }
        return pitches
    }
}

public struct WorkflowChordTrack: Codable, Sendable, Equatable {
    public var version: Int
    public var chords: [WorkflowChordEvent]
    public var duration: Double
    public var tempo: WorkflowTempoMap?
    public var sources: [WorkflowAssetReference]

    public init(version: Int = 1, chords: [WorkflowChordEvent], duration: Double,
                tempo: WorkflowTempoMap? = nil,
                sources: [WorkflowAssetReference] = []) {
        self.version = version
        self.chords = chords
        self.duration = duration
        self.tempo = tempo
        self.sources = sources
    }

    public static var schema: WorkflowDataSchema { .record(schemaFields) }

    public func validate() throws {
        guard version == 1 else { throw WorkflowIssue("Unsupported chord-track version.") }
        guard duration.isFinite, duration >= 0 else {
            throw WorkflowIssue("Chord-track duration must be a finite nonnegative endpoint.")
        }
        guard chords.count <= 256 else { throw WorkflowIssue("A chord track may contain at most 256 chords.") }
        guard Set(chords.map(\.id)).count == chords.count else { throw WorkflowIssue("Chord IDs must be unique.") }

        var earliest = 0.0
        for chord in chords {
            guard !chord.id.isEmpty, chord.id.utf8.count <= 256 else { throw WorkflowIssue("Chord ID is empty or too long.") }
            guard chord.start.isFinite, chord.end.isFinite,
                  chord.start >= -512, chord.end >= -512,
                  chord.start < chord.end, chord.end <= duration else {
                throw WorkflowIssue("Chord interval is outside the track endpoint or pickup limit.")
            }
            _ = try chord.voicedPitches()
            earliest = min(earliest, chord.start)
        }
        guard duration - earliest <= 512 else { throw WorkflowIssue("Chord-track occupied span exceeds 512 quarter notes.") }
        try tempo?.validate()
        try musicValidateSources(sources)
    }

    public func datum() throws -> WorkflowDatum {
        try validate()
        let items = chords.map { chord in
            WorkflowDataItem(id: chord.id, value: .record(schema: Self.chordFields, fields: [
                "id": .text(chord.id),
                "root": .number(Double(chord.root), unit: "pitchClass"),
                "quality": .enumeration(chord.quality.rawValue, choices: WorkflowChordQuality.allCases.map(\.rawValue)),
                "octave": .number(Double(chord.octave), unit: nil),
                "inversion": .number(Double(chord.inversion), unit: nil),
                "start": .number(chord.start, unit: "quarterNote"),
                "end": .number(chord.end, unit: "quarterNote"),
            ]))
        }
        return .record(schema: Self.schemaFields, fields: [
            "format": .text("d.music.chords"),
            "version": .number(Double(version), unit: nil),
            "duration": .number(duration, unit: "quarterNote"),
            "chords": .list(element: .record(Self.chordFields), items: items),
            "tempo": try tempo?.datum() ?? .none(WorkflowTempoMap.schema),
            "sources": try musicSourcesDatum(sources),
        ])
    }

    public init(datum: WorkflowDatum) throws {
        let fields = try musicRecord(datum, expected: Self.schema)
        try musicRequireText(fields, "format", equals: "d.music.chords")
        version = try musicInteger(fields, "version", unit: nil)
        duration = try musicNumber(fields, "duration", unit: "quarterNote")
        guard case .list(_, let items)? = fields["chords"] else { throw WorkflowIssue("Missing typed chords list.") }
        chords = try items.map { item in
            let chordFields = try musicRecord(item.value, expected: .record(Self.chordFields))
            let id = try musicText(chordFields, "id")
            guard item.id == id else { throw WorkflowIssue("Chord list identity does not match chord ID.") }
            let qualityText = try musicEnumeration(chordFields, "quality")
            guard let quality = WorkflowChordQuality(rawValue: qualityText) else { throw WorkflowIssue("Unknown chord quality.") }
            return WorkflowChordEvent(
                id: id,
                root: try musicInteger(chordFields, "root", unit: "pitchClass"),
                quality: quality,
                octave: try musicInteger(chordFields, "octave", unit: nil),
                inversion: try musicInteger(chordFields, "inversion", unit: nil),
                start: try musicNumber(chordFields, "start", unit: "quarterNote"),
                end: try musicNumber(chordFields, "end", unit: "quarterNote")
            )
        }
        guard let tempoDatum = fields["tempo"] else { throw WorkflowIssue("Missing tempo field.") }
        if case .none(let declared) = tempoDatum {
            guard declared == WorkflowTempoMap.schema else { throw WorkflowIssue("Tempo optional schema is invalid.") }
            tempo = nil
        } else {
            tempo = try WorkflowTempoMap(datum: tempoDatum)
        }
        sources = try musicSources(from: fields["sources"])
        try validate()
    }

    fileprivate static let chordFields: [WorkflowRecordField] = [
        .init("id", .text),
        .init("root", .number(unit: "pitchClass")),
        .init("quality", .enumeration(WorkflowChordQuality.allCases.map(\.rawValue))),
        .init("octave", .number(unit: nil)),
        .init("inversion", .number(unit: nil)),
        .init("start", .number(unit: "quarterNote")),
        .init("end", .number(unit: "quarterNote")),
    ]

    fileprivate static let schemaFields: [WorkflowRecordField] = [
        .init("format", .text),
        .init("version", .number(unit: nil)),
        .init("duration", .number(unit: "quarterNote")),
        .init("chords", .list(.record(chordFields))),
        .init("tempo", .optional(WorkflowTempoMap.schema)),
        .init("sources", musicSourcesSchema),
    ]
}

private let musicSourceFields: [WorkflowRecordField] = [
    .init("projectID", .text),
    .init("assetID", .text),
    .init("version", .text),
    .init("kind", .text),
    .init("sha256", .text),
]

private let musicSourcesSchema = WorkflowDataSchema.list(.record(musicSourceFields))

private func musicValidateSources(_ sources: [WorkflowAssetReference]) throws {
    let identities = sources.map { "\($0.assetID.uuidString):\($0.version.uuidString)" }
    guard Set(identities).count == identities.count else { throw WorkflowIssue("Music source identities must be unique.") }
    for source in sources {
        try WorkflowDatum.asset(source).validate(as: .asset(source.kind))
    }
}

private func musicSourcesDatum(_ sources: [WorkflowAssetReference]) throws -> WorkflowDatum {
    try musicValidateSources(sources)
    return .list(element: .record(musicSourceFields), items: sources.map { source in
        let identity = "\(source.assetID.uuidString):\(source.version.uuidString)"
        return WorkflowDataItem(id: identity, value: .record(schema: musicSourceFields, fields: [
            "projectID": .text(source.projectID.uuidString),
            "assetID": .text(source.assetID.uuidString),
            "version": .text(source.version.uuidString),
            "kind": .text(source.kind.rawValue),
            "sha256": .text(source.sha256),
        ]))
    })
}

private func musicSources(from datum: WorkflowDatum?) throws -> [WorkflowAssetReference] {
    guard let datum else { throw WorkflowIssue("Missing sources field.") }
    try datum.validate(as: musicSourcesSchema)
    guard case .list(_, let items) = datum else { throw WorkflowIssue("Sources must be a typed list.") }
    let sources = try items.map { item in
        let fields = try musicRecord(item.value, expected: .record(musicSourceFields))
        guard let projectID = UUID(uuidString: try musicText(fields, "projectID")),
              let assetID = UUID(uuidString: try musicText(fields, "assetID")),
              let version = UUID(uuidString: try musicText(fields, "version")),
              let kind = WorkflowDataKind(rawValue: try musicText(fields, "kind")) else {
            throw WorkflowIssue("Music source UUID or kind is invalid.")
        }
        let identity = "\(assetID.uuidString):\(version.uuidString)"
        guard item.id == identity else { throw WorkflowIssue("Music source list identity is not stable.") }
        return WorkflowAssetReference(projectID: projectID, assetID: assetID, version: version,
                                      kind: kind, sha256: try musicText(fields, "sha256"))
    }
    try musicValidateSources(sources)
    return sources
}

private func musicClock(in datum: WorkflowDatum) throws -> WorkflowMusicClock {
    guard case .record(_, let fields) = datum,
          case .enumeration(let value, let choices)? = fields["clock"],
          choices == WorkflowMusicClock.allCases.map(\.rawValue),
          let clock = WorkflowMusicClock(rawValue: value) else {
        throw WorkflowIssue("Music clock is missing or invalid.")
    }
    return clock
}

private func musicRecord(_ datum: WorkflowDatum,
                         expected: WorkflowDataSchema) throws -> [String: WorkflowDatum] {
    try datum.validate(as: expected)
    guard case .record(_, let fields) = datum else { throw WorkflowIssue("Expected a versioned music record.") }
    return fields
}

private func musicText(_ fields: [String: WorkflowDatum], _ name: String) throws -> String {
    guard case .text(let value)? = fields[name] else { throw WorkflowIssue("Music field \(name) must be text.") }
    return value
}

private func musicRequireText(_ fields: [String: WorkflowDatum], _ name: String,
                              equals required: String) throws {
    guard try musicText(fields, name) == required else { throw WorkflowIssue("Music field \(name) has an unsupported value.") }
}

private func musicEnumeration(_ fields: [String: WorkflowDatum], _ name: String) throws -> String {
    guard case .enumeration(let value, _)? = fields[name] else { throw WorkflowIssue("Music field \(name) must be an enumeration.") }
    return value
}

private func musicNumber(_ fields: [String: WorkflowDatum], _ name: String,
                         unit: String?) throws -> Double {
    guard case .number(let value, let actualUnit)? = fields[name], actualUnit == unit, value.isFinite else {
        throw WorkflowIssue("Music field \(name) has an invalid number or unit.")
    }
    return value
}

private func musicInteger(_ fields: [String: WorkflowDatum], _ name: String,
                          unit: String?) throws -> Int {
    let value = try musicNumber(fields, name, unit: unit)
    guard let integer = Int(exactly: value) else {
        throw WorkflowIssue("Music field \(name) must be an integer.")
    }
    return integer
}

private func musicRequireVersion(_ fields: [String: WorkflowDatum]) throws {
    guard try musicInteger(fields, "version", unit: nil) == 1 else {
        throw WorkflowIssue("Unsupported music record version.")
    }
}
