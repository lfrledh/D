import DInference
@testable import DMLXBackend
import Foundation
import Testing

@Suite("SING1 strict wire")
struct SingingWireTests {
    @Test("Round trip preserves Unicode, UUID spelling, Int64, and explicit rests")
    func roundTrip() throws {
        let request = makeSingingRequest(revision: Int64.max)
        let encoded = try SingingRequestWire.encode(request)
        let decoded = try SingingRequestWire.decode(
            encoded, model: request.model, vocoder: request.singing!.vocoder,
            memoryBudgetBytes: request.memoryBudgetBytes)
        #expect(decoded == request)
        let text = String(decoding: encoded, as: UTF8.self)
        #expect(text.contains("e\\u0301") || text.contains("é"))
        #expect(text.contains("\"midiPitch\":null"))
        #expect(text.contains(String(Int64.max)))
    }

    @Test("Lexical integer, duplicate, unknown, depth, and canonical run rules fail closed")
    func strictFailures() throws {
        let request = makeSingingRequest()
        let encoded = try SingingRequestWire.encode(request)
        let source = String(decoding: encoded, as: UTF8.self)
        let mutations = [
            source.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":true"),
            source.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":1.0"),
            source.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":1e0"),
            source.replacingOccurrences(of: "{", with: "{\"profileID\":\"duplicate\",", options: [], range: source.startIndex..<source.index(after: source.startIndex)),
            source.replacingOccurrences(of: "{", with: "{\"unknown\":0,", options: [], range: source.startIndex..<source.index(after: source.startIndex)),
            source.replacingOccurrences(of: request.id.uuidString.lowercased(), with: request.id.uuidString),
        ]
        for mutation in mutations {
            expectInvalidWire(Data(mutation.utf8), model: request.model, vocoder: request.singing!.vocoder)
        }
        let nested = String(repeating: "[", count: 33) + String(repeating: "]", count: 33)
        expectInvalidWire(Data(nested.utf8), model: request.model, vocoder: request.singing!.vocoder)
    }

    @Test("Missing midiPitch is not treated as an explicit null rest")
    func missingRestPitch() throws {
        let request = makeSingingRequest()
        let source = String(decoding: try SingingRequestWire.encode(request), as: UTF8.self)
        let missing = source.replacingOccurrences(of: "\"midiPitch\":null,", with: "")
        #expect(missing != source)
        expectInvalidWire(Data(missing.utf8), model: request.model, vocoder: request.singing!.vocoder)
    }

    @Test("Nested integer fields reject decimal, exponent, and Boolean spellings")
    func nestedLexicalIntegers() throws {
        let request = makeSingingRequest()
        let source = String(decoding: try SingingRequestWire.encode(request), as: UTF8.self)
        let mutations = [
            source.replacingOccurrences(of: "\"endTick\":1500000", with: "\"endTick\":1500000.0"),
            source.replacingOccurrences(of: "\"phraseRevision\":7", with: "\"phraseRevision\":7e0"),
            source.replacingOccurrences(of: "\"vowelIndices\":[1,null]", with: "\"vowelIndices\":[true,null]"),
        ]
        for mutation in mutations {
            #expect(mutation != source)
            expectInvalidWire(Data(mutation.utf8), model: request.model,
                              vocoder: request.singing!.vocoder)
        }
    }

    @Test("Qualification cannot be absent, false, or defaulted")
    func qualificationRequired() throws {
        let request = makeSingingRequest()
        let source = String(decoding: try SingingRequestWire.encode(request), as: UTF8.self)
        expectInvalidWire(
            Data(source.replacingOccurrences(of: "\"confirmedApplicable\":true",
                                             with: "\"confirmedApplicable\":false").utf8),
            model: request.model, vocoder: request.singing!.vocoder)
        let absent = source.replacingOccurrences(
            of: ",\"qualification\":{\"bankArchiveSHA256\"",
            with: ",\"qualificationMissing\":{\"bankArchiveSHA256\"")
        expectInvalidWire(Data(absent.utf8), model: request.model, vocoder: request.singing!.vocoder)
    }
}

private func makeSingingRequest(revision: Int64 = 7) -> InferenceRequest {
    let runID = UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!
    let phraseID = "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEE1"
    let voicedNote = "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEE2"
    let restNote = "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEE3"
    let voicedUnit = "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEE4"
    let restUnit = "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEE5"
    let phrase = SingingPhrase(
        id: phraseID, revision: revision, language: "zh", durationTicks: 2_000_000,
        notes: [
            SingingNote(id: voicedNote, startTick: 0, endTick: 1_500_000, midiPitch: 69),
            SingingNote(id: restNote, startTick: 1_500_000, endTick: 2_000_000, midiPitch: nil),
        ],
        lyricUnits: [
            SingingLyricUnit(id: voicedUnit, text: "唱 e\u{301}", noteIDs: [voicedNote]),
            SingingLyricUnit(id: restUnit, text: "", noteIDs: [restNote]),
        ])
    let pronunciations = SingingPronunciations(
        phraseID: phraseID, phraseRevision: revision, language: "zh",
        inventoryID: "qixuan-phonemes", inventoryRevision: "原样-R1",
        symbols: ["ch", "ang", "SP"], silenceToken: "SP",
        units: [
            SingingPronunciationUnit(unitID: voicedUnit, phonemes: ["ch", "ang"]),
            SingingPronunciationUnit(unitID: restUnit, phonemes: ["SP"]),
        ])
    let vocoder = ModelReference(
        directory: URL(fileURLWithPath: "/nonexistent/只读-vocoder", isDirectory: true),
        revision: SingingBackendConfiguration.vocoderRevision)
    let qualification = SingingUseQualification(
        confirmedApplicable: true, purpose: .internalDevelopment,
        bankArchiveSHA256: SingingBackendConfiguration.bankArchiveSHA256,
        bankTermsSHA256: String(repeating: "a", count: 64),
        vocoderRevision: SingingBackendConfiguration.vocoderRevision,
        vocoderLicenseSHA256: String(repeating: "b", count: 64))
    return InferenceRequest(
        id: runID,
        model: ModelReference(directory: URL(fileURLWithPath: "/nonexistent/只读-bank", isDirectory: true),
                              revision: SingingBackendConfiguration.bankArchiveSHA256),
        input: .singing(SingingRequest(
            profileID: SingingBackendConfiguration.profileID, phrase: phrase,
            pronunciations: pronunciations, vowelIndices: [1, nil],
            vocoder: vocoder, qualification: qualification)),
        memoryBudgetBytes: UInt64(Int64.max))
}

private extension InferenceRequest {
    var singing: SingingRequest? {
        guard case .singing(let value) = input else { return nil }
        return value
    }
}

private func expectInvalidWire(_ data: Data, model: ModelReference, vocoder: ModelReference) {
    do {
        _ = try SingingRequestWire.decode(data, model: model, vocoder: vocoder)
        Issue.record("Expected strict singing wire rejection")
    } catch {
        #expect(error is InferenceFailure)
    }
}
