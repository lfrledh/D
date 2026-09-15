import Foundation

/// SING1 score data. This version's budgets are input-format safety limits, not a
/// memory-size or six-second model limit. Acoustic interpretation stays in adapters.
public struct SingingPhrase: Sendable, Codable, Equatable {
    public let schemaVersion: Int64
    public let id: String
    public let revision: Int64
    public let ticksPerSecond: Int64
    public let language: String
    public let durationTicks: Int64
    public let notes: [SingingNote]
    public let lyricUnits: [SingingLyricUnit]

    public init(schemaVersion: Int64 = 1, id: String, revision: Int64,
                ticksPerSecond: Int64 = 1_000_000, language: String,
                durationTicks: Int64, notes: [SingingNote], lyricUnits: [SingingLyricUnit]) {
        self.schemaVersion = schemaVersion; self.id = id; self.revision = revision
        self.ticksPerSecond = ticksPerSecond; self.language = language
        self.durationTicks = durationTicks; self.notes = notes; self.lyricUnits = lyricUnits
    }
}

public struct SingingNote: Sendable, Codable, Equatable {
    public let id: String
    public let startTick: Int64
    public let endTick: Int64
    public let midiPitch: Int?

    public init(id: String, startTick: Int64, endTick: Int64, midiPitch: Int?) {
        self.id = id; self.startTick = startTick; self.endTick = endTick; self.midiPitch = midiPitch
    }

    private enum CodingKeys: String, CodingKey { case id, startTick, endTick, midiPitch }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard c.contains(.midiPitch) else {
            throw InferenceFailure.invalidRequest("A singing rest requires an explicit null midiPitch.")
        }
        id = try c.decode(String.self, forKey: .id)
        startTick = try c.decode(Int64.self, forKey: .startTick)
        endTick = try c.decode(Int64.self, forKey: .endTick)
        midiPitch = try c.decodeIfPresent(Int.self, forKey: .midiPitch)
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(startTick, forKey: .startTick)
        try c.encode(endTick, forKey: .endTick)
        if let midiPitch { try c.encode(midiPitch, forKey: .midiPitch) }
        else { try c.encodeNil(forKey: .midiPitch) }
    }
}

public struct SingingLyricUnit: Sendable, Codable, Equatable {
    public let id: String
    public let text: String
    public let noteIDs: [String]
    public init(id: String, text: String, noteIDs: [String]) {
        self.id = id; self.text = text; self.noteIDs = noteIDs
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.text.utf8.elementsEqual(rhs.text.utf8) && lhs.noteIDs == rhs.noteIDs
    }
}

public struct SingingPronunciationUnit: Sendable, Codable, Equatable {
    public let unitID: String
    public let phonemes: [String]
    public init(unitID: String, phonemes: [String]) { self.unitID = unitID; self.phonemes = phonemes }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.unitID == rhs.unitID && SingingValidation.sameStrings(lhs.phonemes, rhs.phonemes)
    }
}

public struct SingingPronunciations: Sendable, Codable, Equatable {
    public let schemaVersion: Int64
    public let phraseID: String
    public let phraseRevision: Int64
    public let language: String
    public let inventoryID: String
    public let inventoryRevision: String
    public let symbols: [String]
    public let silenceToken: String
    public let units: [SingingPronunciationUnit]

    public init(schemaVersion: Int64 = 1, phraseID: String, phraseRevision: Int64,
                language: String, inventoryID: String, inventoryRevision: String,
                symbols: [String], silenceToken: String, units: [SingingPronunciationUnit]) {
        self.schemaVersion = schemaVersion; self.phraseID = phraseID; self.phraseRevision = phraseRevision
        self.language = language; self.inventoryID = inventoryID; self.inventoryRevision = inventoryRevision
        self.symbols = symbols; self.silenceToken = silenceToken; self.units = units
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.schemaVersion == rhs.schemaVersion && lhs.phraseID == rhs.phraseID
        && lhs.phraseRevision == rhs.phraseRevision && lhs.language == rhs.language
        && lhs.inventoryID.utf8.elementsEqual(rhs.inventoryID.utf8)
        && lhs.inventoryRevision.utf8.elementsEqual(rhs.inventoryRevision.utf8)
        && SingingValidation.sameStrings(lhs.symbols, rhs.symbols)
        && lhs.silenceToken.utf8.elementsEqual(rhs.silenceToken.utf8) && lhs.units == rhs.units
    }
}

public enum SingingUsePurpose: String, Sendable, Codable, Equatable {
    case internalDevelopment, personalCreation, commercialCreation
}

/// A caller's explicit, purpose- and material-bound declaration. It does not grant
/// rights or prove that D may redistribute someone else's models or materials.
public struct SingingUseQualification: Sendable, Codable, Equatable {
    public let confirmedApplicable: Bool
    public let purpose: SingingUsePurpose
    public let bankArchiveSHA256: String
    public let bankTermsSHA256: String
    public let vocoderRevision: String
    public let vocoderLicenseSHA256: String

    public init(confirmedApplicable: Bool, purpose: SingingUsePurpose,
                bankArchiveSHA256: String, bankTermsSHA256: String,
                vocoderRevision: String, vocoderLicenseSHA256: String) {
        self.confirmedApplicable = confirmedApplicable; self.purpose = purpose
        self.bankArchiveSHA256 = bankArchiveSHA256; self.bankTermsSHA256 = bankTermsSHA256
        self.vocoderRevision = vocoderRevision; self.vocoderLicenseSHA256 = vocoderLicenseSHA256
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.confirmedApplicable == rhs.confirmedApplicable && lhs.purpose == rhs.purpose
        && SingingValidation.sameStrings(
            [lhs.bankArchiveSHA256, lhs.bankTermsSHA256, lhs.vocoderRevision, lhs.vocoderLicenseSHA256],
            [rhs.bankArchiveSHA256, rhs.bankTermsSHA256, rhs.vocoderRevision, rhs.vocoderLicenseSHA256])
    }
}

/// Immutable structured input; the outer inference request identifies the voice
/// bank and run. No prompt/seed defaults or opaque model-parameter dictionary.
public struct SingingRequest: Sendable, Codable, Equatable {
    public let profileID: String
    public let phrase: SingingPhrase
    public let pronunciations: SingingPronunciations
    public let vowelIndices: [Int?]
    public let vocoder: ModelReference
    public let qualification: SingingUseQualification

    public init(profileID: String, phrase: SingingPhrase, pronunciations: SingingPronunciations,
                vowelIndices: [Int?], vocoder: ModelReference, qualification: SingingUseQualification) {
        self.profileID = profileID; self.phrase = phrase; self.pronunciations = pronunciations
        self.vowelIndices = vowelIndices; self.vocoder = vocoder; self.qualification = qualification
    }

    /// Common SING1 shape/association checks, before profile and material admission.
    /// Raw JSON callers additionally need a strict lexical-number decoder: generic
    /// Codable implementations may accept decimal syntax for an integral value.
    public func validate() throws {
        try SingingValidation.validate(self)
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.profileID.utf8.elementsEqual(rhs.profileID.utf8) && lhs.phrase == rhs.phrase
        && lhs.pronunciations == rhs.pronunciations && lhs.vowelIndices == rhs.vowelIndices
        && lhs.qualification == rhs.qualification
        && lhs.vocoder.directory.absoluteURL == rhs.vocoder.directory.absoluteURL
        && lhs.vocoder.revision.map { Data($0.utf8) } == rhs.vocoder.revision.map { Data($0.utf8) }
    }
}

private enum SingingValidation {
    static func require(_ value: Bool, _ message: String) throws {
        guard value else { throw InferenceFailure.invalidRequest("Singing: " + message) }
    }
    static func sameStrings(_ lhs: [String], _ rhs: [String]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { $0.utf8.elementsEqual($1.utf8) }
    }
    // Python SING1 isspace/strip semantics, explicitly including control separators.
    static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09...0x0D, 0x1C...0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A,
             0x2028...0x2029, 0x202F, 0x205F, 0x3000: true
        default: false
        }
    }
    static func identifier(_ text: String, maximum: Int, label: String) throws {
        try require(!text.isEmpty && text.utf8.count <= maximum && !text.contains("\0")
                    && !text.unicodeScalars.contains(where: isSpace), "invalid " + label)
    }
    static func uuid(_ value: String) throws -> UUID {
        guard value.utf8.count == 36, let id = UUID(uuidString: value),
              id.uuidString.lowercased() == value.lowercased() else {
            throw InferenceFailure.invalidRequest("Singing: UUID must use its standard hyphenated spelling.")
        }
        return id
    }
    static func digest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func validate(_ value: SingingRequest) throws {
        try identifier(value.profileID, maximum: 256, label: "profile identifier")
        let q = value.qualification
        try require(q.confirmedApplicable && digest(q.bankArchiveSHA256) && digest(q.bankTermsSHA256)
                    && digest(q.vocoderLicenseSHA256), "an applicable material-bound use declaration is required")
        try identifier(q.vocoderRevision, maximum: 256, label: "vocoder revision")
        try require(value.vocoder.directory.isFileURL && value.vocoder.directory.path.hasPrefix("/")
                    && [nil, "", "localhost"].contains(value.vocoder.directory.host)
                    && value.vocoder.revision.map { Data($0.utf8) } == Data(q.vocoderRevision.utf8),
                    "invalid or differently qualified local vocoder")

        let p = value.phrase; let pronunciation = value.pronunciations
        try require(p.schemaVersion == 1 && p.revision > 0 && p.ticksPerSecond == 1_000_000
                    && p.language == "zh" && (1...600_000_000).contains(p.durationTicks), "unsupported SING1 phrase")
        try require((1...4096).contains(p.notes.count) && (1...4096).contains(p.lyricUnits.count), "phrase item budget exceeded")
        let phraseID = try uuid(p.id)
        var definitions: Set<UUID> = [phraseID]
        var noteIDs: [UUID] = []; var previousEnd: Int64 = 0
        for note in p.notes {
            let id = try uuid(note.id)
            try require(definitions.insert(id).inserted, "duplicate definition UUID")
            try require(note.startTick == previousEnd && note.startTick >= 0
                        && note.endTick > note.startTick && note.endTick <= p.durationTicks,
                        "notes must contiguously cover the original time axis")
            if let pitch = note.midiPitch { try require((0...127).contains(pitch), "invalid MIDI pitch") }
            noteIDs.append(id); previousEnd = note.endTick
        }
        try require(previousEnd == p.durationTicks, "notes do not reach the phrase end")
        var offset = 0; var totalText = 0; var hasVoiced = false
        var unitIDs: [UUID] = []; var rests: [Bool] = []
        for unit in p.lyricUnits {
            let id = try uuid(unit.id)
            try require(definitions.insert(id).inserted, "duplicate definition UUID")
            let count = unit.noteIDs.count
            try require((1...4096).contains(count) && count <= noteIDs.count - offset,
                        "lyric note references exceed the original notes")
            let references = try unit.noteIDs.map(uuid)
            try require(references.elementsEqual(noteIDs[offset..<(offset + count)]), "lyric note references are missing, repeated or reordered")
            let grouped = p.notes[offset..<(offset + count)]
            let rest = grouped.allSatisfy { $0.midiPitch == nil }
            try require(rest || grouped.allSatisfy { $0.midiPitch != nil }, "one lyric unit cannot mix rest and voice")
            let textBytes = unit.text.utf8.count
            try require(textBytes <= 4096 && textBytes <= 262_144 - totalText && !unit.text.contains("\0"), "lyric text budget or content invalid")
            totalText += textBytes
            if rest {
                try require(count == 1 && unit.text.isEmpty, "a rest unit requires one rest note and empty text")
            } else {
                try require(unit.text.unicodeScalars.contains { !isSpace($0) }, "a voiced unit requires lyric text")
                hasVoiced = true
            }
            offset += count; unitIDs.append(id); rests.append(rest)
        }
        try require(offset == noteIDs.count && hasVoiced, "every note must belong to a unit and the phrase must contain voice")
        try require(pronunciation.schemaVersion == 1 && pronunciation.phraseRevision == p.revision
                    && pronunciation.language == p.language, "pronunciation version or language does not match")
        try require(try uuid(pronunciation.phraseID) == phraseID, "pronunciation belongs to a different phrase")
        try identifier(pronunciation.inventoryID, maximum: 256, label: "inventory identifier")
        try identifier(pronunciation.inventoryRevision, maximum: 256, label: "inventory revision")
        try require((1...8192).contains(pronunciation.symbols.count), "invalid inventory size")
        var symbols = Set<Data>()
        for symbol in pronunciation.symbols {
            try identifier(symbol, maximum: 128, label: "phoneme symbol")
            try require(symbols.insert(Data(symbol.utf8)).inserted, "duplicate phoneme symbol")
        }
        try require(pronunciation.silenceToken == "SP" && symbols.contains(Data("SP".utf8)), "inventory must declare SP silence")
        try require(pronunciation.units.count == unitIDs.count && value.vowelIndices.count == unitIDs.count,
                    "pronunciation units and vowel anchors must cover every lyric unit")
        var phonemeCount = 0
        for (index, unit) in pronunciation.units.enumerated() {
            try require(try uuid(unit.unitID) == unitIDs[index], "pronunciation units must retain lyric order")
            try require(!unit.phonemes.isEmpty && unit.phonemes.count <= 8192 - phonemeCount, "invalid phoneme count")
            phonemeCount += unit.phonemes.count
            for symbol in unit.phonemes {
                try identifier(symbol, maximum: 128, label: "phoneme")
                try require(symbols.contains(Data(symbol.utf8)), "unknown phoneme")
            }
            if rests[index] {
                try require(unit.phonemes == ["SP"] && value.vowelIndices[index] == nil, "rest must have only SP and no vowel anchor")
            } else {
                try require(!unit.phonemes.contains("SP"), "voiced unit cannot contain silence")
                guard let vowel = value.vowelIndices[index], unit.phonemes.indices.contains(vowel) else {
                    throw InferenceFailure.invalidRequest("Singing: voiced unit requires an in-range vowel anchor.")
                }
            }
        }
    }
}
