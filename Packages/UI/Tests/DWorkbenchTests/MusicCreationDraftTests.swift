import DInference
import Foundation
import Testing
@testable import DWorkbench

@Suite("Music creation draft and condition file")
struct MusicCreationDraftTests {
    @Test func codablePreservesRawUnicodeInvalidTextAndUUIDOrder() throws {
        let firstID = UUID()
        let secondID = UUID()
        let draft = MusicCreationDraft(notes: [
            MusicNoteDraft(id: firstID, pitchText: "中文🎵", startText: "未完成",
                           durationText: "e\u{301}"),
            MusicNoteDraft(id: secondID, pitchText: "C♯4", startText: "-",
                           durationText: "0.0400000001")
        ], hasNoteCondition: true)

        let restored = try JSONDecoder().decode(
            MusicCreationDraft.self,
            from: JSONEncoder().encode(draft)
        )
        #expect(restored == draft)
        #expect(restored.notes.map(\.id) == [firstID, secondID])
        #expect(throws: Error.self) { try restored.makeSequence(durationText: "1") }
    }

    @Test func acceptsIntegerNamesEnharmonicsChordsAndAdjacentNotes() throws {
        let draft = MusicCreationDraft(notes: [
            MusicNoteDraft(pitchText: "60", startText: "0", durationText: "0.04"),
            MusicNoteDraft(pitchText: "C#4", startText: "0", durationText: "0.04"),
            MusicNoteDraft(pitchText: "Db4", startText: "0.04", durationText: "0.04"),
            MusicNoteDraft(pitchText: "E4", startText: "0", durationText: "0.08"),
            MusicNoteDraft(pitchText: "G4", startText: "0", durationText: "0.08")
        ], hasNoteCondition: true)

        let sequence = try draft.makeSequence(durationText: "0.0800")
        let notes = try #require(sequence.notes)
        #expect(sequence.durationFrames == 2)
        #expect(notes.map(\.pitch) == [60, 61, 61, 64, 67])
        #expect(notes[1].endFrame == notes[2].startFrame)
        try sequence.validate()
    }

    @Test func conditionPresenceDistinguishesNilFromExplicitEmpty() throws {
        let invalidHiddenRow = MusicNoteDraft(pitchText: "not a pitch", startText: "also invalid",
                                              durationText: "still invalid")
        let absent = try MusicCreationDraft(notes: [invalidHiddenRow], hasNoteCondition: false)
            .makeSequence(durationText: "1")
        let empty = try MusicCreationDraft(notes: [], hasNoteCondition: true)
            .makeSequence(durationText: "1")
        #expect(absent.notes == nil)
        #expect(empty.notes == [])

        let absentData = try MusicConditionFile.encode(
            MusicCreationDraft(notes: [], hasNoteCondition: false), durationText: "1"
        )
        let emptyData = try MusicConditionFile.encode(
            MusicCreationDraft(notes: [], hasNoteCondition: true), durationText: "1"
        )
        #expect(!String(decoding: absentData, as: UTF8.self).contains("\"notes\""))
        #expect(String(decoding: emptyData, as: UTF8.self).contains("\"notes\":[]"))
        #expect(try MusicConditionFile.decode(absentData).draft.hasNoteCondition == false)
        #expect(try MusicConditionFile.decode(emptyData).draft.hasNoteCondition == true)
    }

    @Test func decimalClockIsExactAndRejectsSignsApproximationAndOverflow() throws {
        let valid = MusicCreationDraft(notes: [
            MusicNoteDraft(pitchText: "C4", startText: "0", durationText: "0.04")
        ], hasNoteCondition: true)
        #expect(try valid.makeSequence(durationText: "0.04").durationFrames == 1)

        for invalidDuration in ["0.03", "0.0400000001", "+0.04", " 0.04", "0.04 ",
                                "1e1", "NaN", "Infinity", "-0.04", ".04", "0.",
                                String(repeating: "9", count: 64)] {
            #expect(throws: Error.self) {
                try valid.makeSequence(durationText: invalidDuration)
            }
        }
        let zeroLength = MusicCreationDraft(notes: [
            MusicNoteDraft(pitchText: "C4", startText: "0", durationText: "0")
        ], hasNoteCondition: true)
        #expect(throws: Error.self) { try zeroLength.makeSequence(durationText: "1") }
    }

    @Test func rejectsPitchIntervalBoundaryOverlapAndRowFailures() {
        func make(_ pitch: String, _ start: String, _ duration: String,
                  total: String = "1") throws -> AudioNoteSequence {
            try MusicCreationDraft(notes: [
                MusicNoteDraft(pitchText: pitch, startText: start, durationText: duration)
            ], hasNoteCondition: true).makeSequence(durationText: total)
        }

        for pitch in ["-1", "128", "c4", "C", "C##4", "C+4", "H4", "C♯4", "C-2", "G#9"] {
            #expect(throws: Error.self) { try make(pitch, "0", "0.04") }
        }
        #expect(throws: Error.self) { try make("C4", "0.96", "0.08") }
        #expect(throws: Error.self) { try make("C4", "400", "0.04") }

        let overlap = MusicCreationDraft(notes: [
            MusicNoteDraft(pitchText: "C4", startText: "0", durationText: "0.08"),
            MusicNoteDraft(pitchText: "60", startText: "0.04", durationText: "0.08")
        ], hasNoteCondition: true)
        #expect(throws: Error.self) { try overlap.makeSequence(durationText: "1") }

        let tooMany = MusicCreationDraft(
            notes: Array(repeating: MusicNoteDraft(pitchText: "C4", startText: "0",
                                                   durationText: "0.04"), count: 513),
            hasNoteCondition: true
        )
        #expect(throws: Error.self) { try tooMany.makeSequence(durationText: "1") }
    }

    @Test func strictDecodeRejectsStructuralAndNumericImpostors() throws {
        let valid = "{\"schemaVersion\":1,\"frameRate\":25,\"durationFrames\":1,\"notes\":[]}"
        _ = try MusicConditionFile.decode(data(valid))

        let invalidInputs = [
            "{\"schemaVersion\":1,\"schemaVersion\":1,\"frameRate\":25,\"durationFrames\":1}",
            "{\"schemaVersion\":1.0,\"frameRate\":25,\"durationFrames\":1}",
            "{\"schemaVersion\":true,\"frameRate\":25,\"durationFrames\":1}",
            "{\"schemaVersion\":1,\"frameRate\":25,\"durationFrames\":1,\"unknown\":0}",
            "{\"schemaVersion\":1,\"frameRate\":25,\"durationFrames\":1,\"notes\":null}",
            "{\"schemaVersion\":2,\"frameRate\":25,\"durationFrames\":1}",
            "{\"schemaVersion\":1,\"frameRate\":24,\"durationFrames\":1}",
            "{\"schemaVersion\":1,\"frameRate\":25,\"durationFrames\":401}",
            "{\"schemaVersion\":1,\"frameRate\":25,\"durationFrames\":1,\"notes\":[{\"pitch\":true,\"startFrame\":0,\"endFrame\":1}]}",
            "{\"schemaVersion\":1,\"frameRate\":25,\"durationFrames\":1,\"notes\":[{\"pitch\":60,\"pitch\":60,\"startFrame\":0,\"endFrame\":1}]}",
            "{\"schemaVersion\":1,\"frameRate\":25,\"durationFrames\":1,\"notes\":[{\"pitch\":60,\"startFrame\":0,\"endFrame\":1,\"x\":0}]}",
            "{\"schemaVersion\":01,\"frameRate\":25,\"durationFrames\":1}",
            "{\"schemaVersion\":1,\"frameRate\":25,\"durationFrames\":1} trailing"
        ]
        for input in invalidInputs {
            #expect(throws: Error.self) { try MusicConditionFile.decode(data(input)) }
        }
    }

    @Test func strictDecodeEnforcesDepthSizeUTF8AndCount() {
        let tooDeep = "{\"x\":[[[[[[[[[]]]]]]]]]}"
        #expect(throws: Error.self) { try MusicConditionFile.decode(data(tooDeep)) }
        #expect(throws: Error.self) {
            try MusicConditionFile.decode(Data(repeating: 32, count: 128 * 1024 + 1))
        }
        #expect(throws: Error.self) { try MusicConditionFile.decode(Data([0xff])) }

        let rows = Array(repeating: "{\"pitch\":60,\"startFrame\":0,\"endFrame\":1}", count: 513)
            .joined(separator: ",")
        let tooMany = "{\"schemaVersion\":1,\"frameRate\":25,\"durationFrames\":1,\"notes\":[\(rows)]}"
        #expect(throws: Error.self) { try MusicConditionFile.decode(data(tooMany)) }
    }

    @Test func safeRoundTripPreservesSequenceSemanticsAndFreshensExternalUUIDs() throws {
        let savedID = UUID()
        let draft = MusicCreationDraft(notes: [
            MusicNoteDraft(id: savedID, pitchText: "Db4", startText: "0", durationText: "0.12"),
            MusicNoteDraft(pitchText: "C4", startText: "0.12", durationText: "0.08")
        ], hasNoteCondition: true)
        let before = try draft.makeSequence(durationText: "1.20")
        let encoded = try MusicConditionFile.encode(draft, durationText: "1.20")
        let decoded = try MusicConditionFile.decode(encoded)
        let after = try decoded.draft.makeSequence(durationText: decoded.durationText)

        #expect(decoded.durationText == "1.2")
        #expect(decoded.draft.hasNoteCondition)
        #expect(decoded.draft.notes[0].id != savedID)
        #expect(after == before)
        #expect(String(decoding: encoded, as: UTF8.self) ==
                "{\"schemaVersion\":1,\"frameRate\":25,\"durationFrames\":30,\"notes\":[{\"pitch\":61,\"startFrame\":0,\"endFrame\":3},{\"pitch\":60,\"startFrame\":3,\"endFrame\":5}]}")
    }

    private func data(_ string: String) -> Data { Data(string.utf8) }
}
