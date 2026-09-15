import DInference
import Foundation

/// Strict JSON bridge for the frozen SING1/RENDER1 request. Model locations are
/// supplied by the trusted host and are deliberately absent from the wire value.
public enum SingingRequestWire {
    public static func decode(
        _ data: Data,
        model: ModelReference,
        vocoder: ModelReference,
        memoryBudgetBytes: UInt64? = nil
    ) throws -> InferenceRequest {
        guard data.count <= 2 * 1024 * 1024 else {
            throw InferenceFailure.invalidRequest("Singing request exceeds 2 MiB.")
        }
        do {
            var parser = AudioJSONParser(data: data, maximumDepth: 32)
            let root = try parser.parse().object(
                exactKeys: ["schemaVersion", "runID", "profileID", "phrase",
                            "pronunciations", "vowelIndices", "qualification"],
                context: "singing request")
            guard try root.requiredInteger("schemaVersion", "singing schemaVersion") == 1 else {
                throw InferenceFailure.invalidRequest("Unsupported singing request schemaVersion.")
            }
            let runText = try root.requiredString("runID", "singing runID")
            guard let runID = UUID(uuidString: runText),
                  runID.uuidString.lowercased() == runText else {
                throw InferenceFailure.invalidRequest("Singing runID must be a canonical lowercase UUID.")
            }
            let phrase = try decodePhrase(root.required("phrase", "singing phrase"))
            let pronunciations = try decodePronunciations(
                root.required("pronunciations", "singing pronunciations"))
            let anchors = try decodeOptionalIntegers(
                root.required("vowelIndices", "singing vowelIndices"), context: "vowelIndices")
            let qualification = try decodeQualification(
                root.required("qualification", "singing qualification"))
            let singing = SingingRequest(
                profileID: try root.requiredString("profileID", "singing profileID"),
                phrase: phrase,
                pronunciations: pronunciations,
                vowelIndices: anchors,
                vocoder: vocoder,
                qualification: qualification)
            let request = InferenceRequest(
                id: runID, model: model, input: .singing(singing),
                memoryBudgetBytes: memoryBudgetBytes)
            try request.validate()
            return request
        } catch let failure as InferenceFailure {
            throw failure
        } catch {
            throw InferenceFailure.invalidRequest(
                "Invalid strict singing request JSON: \(error.localizedDescription)")
        }
    }

    public static func encode(_ request: InferenceRequest) throws -> Data {
        try request.validate()
        guard case .singing(let singing) = request.input else {
            throw InferenceFailure.unsupportedCapability(request.input.capability)
        }
        let frozen = FrozenRequest(
            runID: request.id.uuidString.lowercased(), profileID: singing.profileID,
            phrase: singing.phrase, pronunciations: singing.pronunciations,
            vowelIndices: singing.vowelIndices, qualification: singing.qualification)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(frozen)
        guard data.count <= 2 * 1024 * 1024 else {
            throw InferenceFailure.invalidRequest("Singing request exceeds 2 MiB.")
        }
        return data
    }

    private static func decodePhrase(_ value: AudioJSONValue) throws -> SingingPhrase {
        let object = try value.object(
            exactKeys: ["schemaVersion", "id", "revision", "ticksPerSecond", "language",
                        "durationTicks", "notes", "lyricUnits"], context: "singing phrase")
        let notesValue = try object.required("notes", "singing notes")
        guard case .array(let noteValues) = notesValue else {
            throw InferenceFailure.invalidRequest("Singing notes must be an array.")
        }
        let lyricsValue = try object.required("lyricUnits", "singing lyricUnits")
        guard case .array(let lyricValues) = lyricsValue else {
            throw InferenceFailure.invalidRequest("Singing lyricUnits must be an array.")
        }
        let notes = try noteValues.map { value -> SingingNote in
            let note = try value.object(
                exactKeys: ["id", "startTick", "endTick", "midiPitch"], context: "singing note")
            let pitchValue = try note.required("midiPitch", "note midiPitch")
            let pitch: Int?
            if case .null = pitchValue {
                pitch = nil
            } else {
                pitch = try exactInt(pitchValue, context: "note midiPitch")
            }
            return SingingNote(
                id: try note.requiredString("id", "note id"),
                startTick: try note.requiredInteger("startTick", "note startTick"),
                endTick: try note.requiredInteger("endTick", "note endTick"),
                midiPitch: pitch)
        }
        let lyricUnits = try lyricValues.map { value -> SingingLyricUnit in
            let unit = try value.object(
                exactKeys: ["id", "text", "noteIDs"], context: "singing lyric unit")
            return SingingLyricUnit(
                id: try unit.requiredString("id", "lyric unit id"),
                text: try unit.requiredString("text", "lyric unit text"),
                noteIDs: try strings(unit.required("noteIDs", "lyric unit noteIDs"),
                                    context: "lyric unit noteIDs"))
        }
        return SingingPhrase(
            schemaVersion: try object.requiredInteger("schemaVersion", "phrase schemaVersion"),
            id: try object.requiredString("id", "phrase id"),
            revision: try object.requiredInteger("revision", "phrase revision"),
            ticksPerSecond: try object.requiredInteger("ticksPerSecond", "phrase ticksPerSecond"),
            language: try object.requiredString("language", "phrase language"),
            durationTicks: try object.requiredInteger("durationTicks", "phrase durationTicks"),
            notes: notes, lyricUnits: lyricUnits)
    }

    private static func decodePronunciations(_ value: AudioJSONValue) throws -> SingingPronunciations {
        let object = try value.object(
            exactKeys: ["schemaVersion", "phraseID", "phraseRevision", "language", "inventoryID",
                        "inventoryRevision", "symbols", "silenceToken", "units"],
            context: "singing pronunciations")
        let unitsValue = try object.required("units", "pronunciation units")
        guard case .array(let unitValues) = unitsValue else {
            throw InferenceFailure.invalidRequest("Pronunciation units must be an array.")
        }
        let units = try unitValues.map { value -> SingingPronunciationUnit in
            let unit = try value.object(
                exactKeys: ["unitID", "phonemes"], context: "pronunciation unit")
            return SingingPronunciationUnit(
                unitID: try unit.requiredString("unitID", "pronunciation unitID"),
                phonemes: try strings(unit.required("phonemes", "pronunciation phonemes"),
                                      context: "pronunciation phonemes"))
        }
        return SingingPronunciations(
            schemaVersion: try object.requiredInteger("schemaVersion", "pronunciation schemaVersion"),
            phraseID: try object.requiredString("phraseID", "pronunciation phraseID"),
            phraseRevision: try object.requiredInteger("phraseRevision", "pronunciation phraseRevision"),
            language: try object.requiredString("language", "pronunciation language"),
            inventoryID: try object.requiredString("inventoryID", "pronunciation inventoryID"),
            inventoryRevision: try object.requiredString("inventoryRevision", "pronunciation inventoryRevision"),
            symbols: try strings(object.required("symbols", "pronunciation symbols"),
                                 context: "pronunciation symbols"),
            silenceToken: try object.requiredString("silenceToken", "pronunciation silenceToken"),
            units: units)
    }

    private static func decodeQualification(_ value: AudioJSONValue) throws -> SingingUseQualification {
        let object = try value.object(
            exactKeys: ["confirmedApplicable", "purpose", "bankArchiveSHA256", "bankTermsSHA256",
                        "vocoderRevision", "vocoderLicenseSHA256"], context: "singing qualification")
        let confirmedValue = try object.required("confirmedApplicable", "qualification confirmedApplicable")
        guard case .bool(let confirmed) = confirmedValue else {
            throw InferenceFailure.invalidRequest("qualification confirmedApplicable must be Boolean.")
        }
        let purposeText = try object.requiredString("purpose", "qualification purpose")
        guard let purpose = SingingUsePurpose(rawValue: purposeText) else {
            throw InferenceFailure.invalidRequest("Unsupported singing use purpose.")
        }
        return SingingUseQualification(
            confirmedApplicable: confirmed, purpose: purpose,
            bankArchiveSHA256: try object.requiredString("bankArchiveSHA256", "qualification bank archive"),
            bankTermsSHA256: try object.requiredString("bankTermsSHA256", "qualification bank terms"),
            vocoderRevision: try object.requiredString("vocoderRevision", "qualification vocoder revision"),
            vocoderLicenseSHA256: try object.requiredString("vocoderLicenseSHA256", "qualification vocoder license"))
    }

    private static func decodeOptionalIntegers(
        _ value: AudioJSONValue, context: String
    ) throws -> [Int?] {
        guard case .array(let values) = value else {
            throw InferenceFailure.invalidRequest("\(context) must be an array.")
        }
        return try values.map {
            if case .null = $0 { return nil }
            return try exactInt($0, context: context)
        }
    }

    private static func strings(_ value: AudioJSONValue, context: String) throws -> [String] {
        guard case .array(let values) = value else {
            throw InferenceFailure.invalidRequest("\(context) must be an array.")
        }
        return try values.map { try $0.requiredString(context: context) }
    }

    private static func exactInt(_ value: AudioJSONValue, context: String) throws -> Int {
        let number = try value.requiredInteger(context: context)
        guard let result = Int(exactly: number) else {
            throw InferenceFailure.invalidRequest("\(context) is outside the platform Int range.")
        }
        return result
    }

    private struct FrozenRequest: Encodable {
        let schemaVersion = 1
        let runID: String
        let profileID: String
        let phrase: SingingPhrase
        let pronunciations: SingingPronunciations
        let vowelIndices: [Int?]
        let qualification: SingingUseQualification
    }
}

private extension Dictionary where Key == String, Value == AudioJSONValue {
    func required(_ key: String, _ context: String) throws -> AudioJSONValue {
        guard let value = self[key] else {
            throw InferenceFailure.invalidRequest("Missing \(context).")
        }
        return value
    }

    func requiredString(_ key: String, _ context: String) throws -> String {
        try required(key, context).requiredString(context: context)
    }

    func requiredInteger(_ key: String, _ context: String) throws -> Int64 {
        try required(key, context).requiredInteger(context: context)
    }
}
