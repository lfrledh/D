import Foundation
import XCTest
import DInference

final class SingingContractTests: XCTestCase {
    private func fixture() -> SingingRequest {
        let p = "aaaaaaaa-0000-0000-0000-000000000001"
        let n = (1...3).map { "bbbbbbbb-0000-0000-0000-00000000000\($0)" }
        let u = (1...2).map { "cccccccc-0000-0000-0000-00000000000\($0)" }
        return SingingRequest(profileID: "fixture-profile",
            phrase: .init(id: p, revision: Int64.max, language: "zh", durationTicks: 3_000_000,
                notes: [.init(id: n[0], startTick: 0, endTick: 1_000_000, midiPitch: 60),
                        .init(id: n[1], startTick: 1_000_000, endTick: 2_000_000, midiPitch: 62),
                        .init(id: n[2], startTick: 2_000_000, endTick: 3_000_000, midiPitch: nil)],
                lyricUnits: [.init(id: u[0], text: "啦👩🏽‍🎤e\u{301}", noteIDs: Array(n.prefix(2))),
                             .init(id: u[1], text: "", noteIDs: [n[2]])]),
            pronunciations: .init(phraseID: p.uppercased(), phraseRevision: Int64.max,
                language: "zh", inventoryID: "fixture", inventoryRevision: "1",
                symbols: ["SP", "l", "a", "é", "e\u{301}"], silenceToken: "SP",
                units: [.init(unitID: u[0], phonemes: ["l", "a"]),
                        .init(unitID: u[1], phonemes: ["SP"])]),
            vowelIndices: [1, nil], vocoder: .init(directory: URL(fileURLWithPath: "/fixture/声音"), revision: "fixed"),
            qualification: .init(confirmedApplicable: true, purpose: .internalDevelopment,
                bankArchiveSHA256: String(repeating: "a", count: 64),
                bankTermsSHA256: String(repeating: "b", count: 64), vocoderRevision: "fixed",
                vocoderLicenseSHA256: String(repeating: "c", count: 64)))
    }

    // These are typed-value tests. Strict wire lexical-number and unknown-key
    // rejection are adapter obligations and are not claimed by JSONDecoder.
    private func changed(_ mutate: (inout [String: Any]) -> Void) throws -> SingingRequest {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture())) as? [String: Any])
        mutate(&object)
        return try JSONDecoder().decode(SingingRequest.self, from: JSONSerialization.data(withJSONObject: object))
    }
    private func changePhrase(_ body: (inout [String: Any]) -> Void) throws -> SingingRequest {
        try changed { root in var p = root["phrase"] as! [String: Any]; body(&p); root["phrase"] = p }
    }
    private func changePronunciation(_ body: (inout [String: Any]) -> Void) throws -> SingingRequest {
        try changed { root in var p = root["pronunciations"] as! [String: Any]; body(&p); root["pronunciations"] = p }
    }

    func testValidMelismaRestAndExactCodableRoundTrip() throws {
        let original = fixture()
        try original.validate()
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(SingingRequest.self, from: data)
        XCTAssertEqual(restored, original)
        XCTAssertEqual(restored.phrase.revision, Int64.max)
        XCTAssertEqual(Array(restored.phrase.lyricUnits[0].text.utf8), Array(original.phrase.lyricUnits[0].text.utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let p = object["phrase"] as! [String: Any]
        let notes = p["notes"] as! [[String: Any]]
        XCTAssertTrue(notes[2]["midiPitch"] is NSNull)
        XCTAssertEqual((object["pronunciations"] as! [String: Any]).count, 9)
    }

    func testMissingRestMarkerIsNotSilence() throws {
        XCTAssertThrowsError(try changePhrase { p in
            var notes = p["notes"] as! [[String: Any]]; notes[2].removeValue(forKey: "midiPitch"); p["notes"] = notes
        })
    }

    func testUUIDIdentityDetectsCaseVariantDuplicates() throws {
        let invalid = try changePhrase { p in
            var notes = p["notes"] as! [[String: Any]]
            notes[1]["id"] = (notes[0]["id"] as! String).uppercased(); p["notes"] = notes
            var units = p["lyricUnits"] as! [[String: Any]]
            units[0]["noteIDs"] = [notes[0]["id"]!, notes[1]["id"]!]; p["lyricUnits"] = units
        }
        XCTAssertThrowsError(try invalid.validate())
        XCTAssertThrowsError(try changePhrase { $0["id"] = "aaaaaaaa000000000000000000000001" }.validate())
    }

    func testStaleOrForeignPronunciationRejected() throws {
        XCTAssertThrowsError(try changePronunciation { $0["phraseRevision"] = 1 }.validate())
        XCTAssertThrowsError(try changePronunciation { $0["phraseID"] = "ffffffff-0000-0000-0000-000000000001" }.validate())
        XCTAssertThrowsError(try changePronunciation { $0["language"] = "en" }.validate())
    }

    func testOriginalAxisCannotBeReorderedGappedOrExtended() throws {
        for key in ["startTick", "endTick"] {
            XCTAssertThrowsError(try changePhrase { p in
                var notes = p["notes"] as! [[String: Any]]; notes[1][key] = 999_999; p["notes"] = notes
            }.validate())
        }
        XCTAssertThrowsError(try changePhrase { p in
            var units = p["lyricUnits"] as! [[String: Any]]
            units[0]["noteIDs"] = (units[0]["noteIDs"] as! [String]).reversed().map { $0 }; p["lyricUnits"] = units
        }.validate())
        XCTAssertThrowsError(try changePhrase { $0["durationTicks"] = 3_000_001 }.validate())
    }

    func testRestMustRemainOneUnvoicedNoteWithSPAndNullAnchor() throws {
        XCTAssertThrowsError(try changed { $0["vowelIndices"] = [1, 0] }.validate())
        XCTAssertThrowsError(try changePronunciation { p in
            var units = p["units"] as! [[String: Any]]; units[1]["phonemes"] = ["a"]; p["units"] = units
        }.validate())
        XCTAssertThrowsError(try changePhrase { p in
            var units = p["lyricUnits"] as! [[String: Any]]; units[1]["text"] = "休止"; p["lyricUnits"] = units
        }.validate())
    }

    func testVowelZeroIsLegalButMissingOutOfRangeAreNot() throws {
        try changed { $0["vowelIndices"] = [0, NSNull()] }.validate()
        for value: Any in [NSNull(), -1, 2] {
            XCTAssertThrowsError(try changed { $0["vowelIndices"] = [value, NSNull()] }.validate())
        }
    }

    func testSymbolsRetainByteIdentityWithoutNormalization() throws {
        try fixture().validate() // composed and decomposed e-acute remain distinct symbols
        XCTAssertThrowsError(try changePronunciation { $0["symbols"] = ["SP", "l", "a", "a"] }.validate())
        let lhs = SingingPronunciationUnit(unitID: "same", phonemes: ["é"])
        let rhs = SingingPronunciationUnit(unitID: "same", phonemes: ["e\u{301}"])
        XCTAssertNotEqual(lhs, rhs)
        XCTAssertNotEqual(SingingLyricUnit(id: "same", text: "é", noteIDs: []),
                          SingingLyricUnit(id: "same", text: "e\u{301}", noteIDs: []))
    }

    func testPythonWhitespaceAndUTF8Budgets() throws {
        for text in ["\u{001c}", "\u{0085}", "\u{3000}", " ", String(repeating: "中", count: 1366), "啦\0"] {
            XCTAssertThrowsError(try changePhrase { p in
                var units = p["lyricUnits"] as! [[String: Any]]; units[0]["text"] = text; p["lyricUnits"] = units
            }.validate())
        }
        XCTAssertThrowsError(try changePronunciation { $0["inventoryID"] = "bank\u{001c}name" }.validate())
    }

    func testUseDeclarationCannotBeImplicitOrChangeMaterialRevision() throws {
        XCTAssertThrowsError(try changed { root in
            var q = root["qualification"] as! [String: Any]; q["confirmedApplicable"] = false; root["qualification"] = q
        }.validate())
        XCTAssertThrowsError(try changed { root in
            var q = root["qualification"] as! [String: Any]; q["vocoderRevision"] = "different"; root["qualification"] = q
        }.validate())
        XCTAssertThrowsError(try changed { root in
            var q = root["qualification"] as! [String: Any]; q["bankTermsSHA256"] = ""; root["qualification"] = q
        }.validate())
    }

    func testQualificationAndProfileIdentityAreNotUnicodeNormalized() throws {
        let composed = try changed { root in
            root["profileID"] = "é"
            var q = root["qualification"] as! [String: Any]; q["vocoderRevision"] = "é"; root["qualification"] = q
            var v = root["vocoder"] as! [String: Any]; v["revision"] = "é"; root["vocoder"] = v
        }
        let decomposed = try changed { root in
            root["profileID"] = "e\u{301}"
            var q = root["qualification"] as! [String: Any]; q["vocoderRevision"] = "e\u{301}"; root["qualification"] = q
            var v = root["vocoder"] as! [String: Any]; v["revision"] = "e\u{301}"; root["vocoder"] = v
        }
        try composed.validate(); try decomposed.validate()
        XCTAssertNotEqual(composed, decomposed)
        XCTAssertNotEqual(composed.qualification, decomposed.qualification)
        XCTAssertThrowsError(try changed { root in
            var q = root["qualification"] as! [String: Any]; q["vocoderRevision"] = "é"; root["qualification"] = q
            var v = root["vocoder"] as! [String: Any]; v["revision"] = "e\u{301}"; root["vocoder"] = v
        }.validate())
        XCTAssertNotEqual(try changed { $0["profileID"] = "é" }, try changed { $0["profileID"] = "e\u{301}" })
    }
}
