import Foundation
import XCTest
@testable import DWorkbench

final class WorkflowMusicProgramsTests: XCTestCase {
    func testNoteSequenceDatumRoundTripPreservesTypedValuesAndSources() throws {
        let source = makeSource()
        let tempo = WorkflowTempoMap(beatsPerMinute: 96, firstBeatSeconds: -0.25,
                                     numerator: 4, denominator: 4)
        let value = WorkflowNoteSequence(
            clock: .seconds,
            notes: [.init(id: "n-α", pitch: 60, start: -0.1, end: 0.5, velocity: 0.75)],
            duration: 1,
            tempo: tempo,
            sources: [source]
        )

        let datum = try value.datum()
        try datum.validate(as: WorkflowNoteSequence.schema(clock: .seconds))
        XCTAssertEqual(try WorkflowNoteSequence(datum: datum), value)
        XCTAssertEqual(datum.assetReferences, []) // Source metadata is inert, not an executable asset datum.
    }

    func testTempoAndChordDatumRoundTrip() throws {
        let tempo = WorkflowTempoMap(beatsPerMinute: 120, firstBeatSeconds: 0,
                                     numerator: 3, denominator: 4)
        XCTAssertEqual(try WorkflowTempoMap(datum: tempo.datum()), tempo)

        let track = WorkflowChordTrack(
            chords: [.init(id: "c1", root: 0, quality: .major7,
                           octave: 4, inversion: 1, start: -1, end: 2)],
            duration: 4,
            tempo: tempo,
            sources: [makeSource()]
        )
        XCTAssertEqual(try WorkflowChordTrack(datum: track.datum()), track)
    }

    func testDatumRejectsBadVersionUnitAndListIdentity() throws {
        let tempo = WorkflowTempoMap(beatsPerMinute: 120, firstBeatSeconds: 0,
                                     numerator: 4, denominator: 4)
        guard case .record(let tempoSchema, var tempoFields) = try tempo.datum() else {
            return XCTFail("Expected tempo record")
        }
        tempoFields["version"] = .number(2, unit: nil)
        XCTAssertThrowsError(try WorkflowTempoMap(datum: .record(schema: tempoSchema, fields: tempoFields)))

        let sequence = WorkflowNoteSequence(
            clock: .seconds,
            notes: [.init(id: "n1", pitch: 60, start: 0, end: 1, velocity: 1)],
            duration: 1
        )
        guard case .record(let outerSchema, var outerFields) = try sequence.datum(),
              case .list(let element, let items)? = outerFields["notes"],
              case .record(let noteSchema, var noteFields) = items[0].value else {
            return XCTFail("Expected typed note record")
        }
        noteFields["start"] = .number(0, unit: "quarterNote")
        outerFields["notes"] = .list(element: element, items: [
            .init(id: "wrong-id", value: .record(schema: noteSchema, fields: noteFields)),
        ])
        XCTAssertThrowsError(try WorkflowNoteSequence(
            datum: .record(schema: outerSchema, fields: outerFields)
        ))
    }

    func testIntegerDecodingRejectsUnrepresentableAndNonIntegerDoublesWithoutTrap() throws {
        let twoTo63 = 9_223_372_036_854_775_808.0
        let tempo = WorkflowTempoMap(beatsPerMinute: 120, firstBeatSeconds: 0,
                                     numerator: 4, denominator: 4)
        guard case .record(let tempoSchema, let validTempoFields) = try tempo.datum() else {
            return XCTFail("Expected tempo record")
        }

        for invalidVersion in [twoTo63, Double(Int.min), 1.5, Double.infinity] {
            var fields = validTempoFields
            fields["version"] = .number(invalidVersion, unit: nil)
            XCTAssertThrowsError(try WorkflowTempoMap(
                datum: .record(schema: tempoSchema, fields: fields)
            ))
        }
        var numeratorFields = validTempoFields
        numeratorFields["numerator"] = .number(twoTo63, unit: nil)
        XCTAssertThrowsError(try WorkflowTempoMap(
            datum: .record(schema: tempoSchema, fields: numeratorFields)
        ))

        let sequence = WorkflowNoteSequence(
            clock: .seconds,
            notes: [.init(id: "n", pitch: 60, start: 0, end: 1, velocity: 1)],
            duration: 1
        )
        guard case .record(let sequenceSchema, var sequenceFields) = try sequence.datum(),
              case .list(let element, let items)? = sequenceFields["notes"],
              case .record(let noteSchema, var noteFields) = items[0].value else {
            return XCTFail("Expected note record")
        }
        noteFields["pitch"] = .number(twoTo63, unit: "MIDI")
        sequenceFields["notes"] = .list(element: element, items: [
            .init(id: "n", value: .record(schema: noteSchema, fields: noteFields)),
        ])
        XCTAssertThrowsError(try WorkflowNoteSequence(
            datum: .record(schema: sequenceSchema, fields: sequenceFields)
        ))
    }

    func testValidationRejectsDuplicateIDsAndOccupiedSpanOverflow() {
        let duplicate = WorkflowNoteSequence(
            clock: .seconds,
            notes: [
                .init(id: "same", pitch: 60, start: 0, end: 1, velocity: 1),
                .init(id: "same", pitch: 62, start: 1, end: 2, velocity: 1),
            ],
            duration: 2
        )
        XCTAssertThrowsError(try duplicate.validate())

        let pickupOverflow = WorkflowNoteSequence(
            clock: .seconds,
            notes: [.init(id: "n", pitch: 60, start: -120, end: -119, velocity: 1)],
            duration: 1
        )
        XCTAssertThrowsError(try pickupOverflow.validate())
    }

    func testMaximumNoteCountDatumValidatesAndRoundTripsWithExpandedValueWalkBudget() throws {
        let notes = (0..<4_096).map {
            WorkflowNoteEvent(id: "n\($0)", pitch: $0 % 128,
                              start: 0, end: 1, velocity: 1)
        }
        let sequence = WorkflowNoteSequence(clock: .seconds, notes: notes, duration: 1)
        let datum = try sequence.datum()
        try datum.validate(as: WorkflowNoteSequence.schema(clock: .seconds))
        XCTAssertEqual(try WorkflowNoteSequence(datum: datum), sequence)

        let tooMany = WorkflowNoteSequence(
            clock: .seconds,
            notes: notes + [.init(id: "overflow", pitch: 60, start: 0, end: 1, velocity: 1)],
            duration: 1
        )
        XCTAssertThrowsError(try tooMany.validate())
    }

    func testAlignUsesTempoOriginAndExposesCollapsedExtension() throws {
        let input = WorkflowNoteSequence(
            clock: .seconds,
            notes: [
                .init(id: "pickup", pitch: 60, start: -0.6, end: -0.1, velocity: 0.5),
                .init(id: "collapsed", pitch: 64, start: 0.1, end: 0.2, velocity: 0.75),
            ],
            duration: 1
        )
        let tempo = WorkflowTempoMap(beatsPerMinute: 60, firstBeatSeconds: 0,
                                     numerator: 4, denominator: 4)
        let output = try WorkflowMusicPrograms.align(sequence: input, tempo: tempo, snap: .quarter)
        XCTAssertEqual(output.clock, .quarterNotes)
        XCTAssertEqual(output.notes[0].start, -1)
        XCTAssertEqual(output.notes[0].end, 0)
        XCTAssertEqual(output.notes[1].start, 0)
        XCTAssertEqual(output.notes[1].end, 1)
        XCTAssertEqual(output.duration, 1)
        XCTAssertEqual(output.notes.map(\.velocity), [0.5, 0.75])

        XCTAssertThrowsError(try WorkflowMusicPrograms.align(sequence: output, tempo: tempo, snap: .none))
    }

    func testAlignRejectsExtensionPastBeatBudget() {
        let input = WorkflowNoteSequence(
            clock: .seconds,
            notes: [.init(id: "edge", pitch: 60, start: 119.9, end: 120, velocity: 1)],
            duration: 120
        )
        let tempo = WorkflowTempoMap(beatsPerMinute: 300, firstBeatSeconds: 0,
                                     numerator: 4, denominator: 4)
        XCTAssertThrowsError(try WorkflowMusicPrograms.align(sequence: input, tempo: tempo, snap: .quarter))
    }

    func testKeysReportsCandidatesNotTruthAndIgnoresSilentNotes() throws {
        let pitches = [60, 62, 64, 65, 67, 69, 71]
        var notes = pitches.enumerated().map {
            WorkflowNoteEvent(id: "n\($0.offset)", pitch: $0.element,
                              start: Double($0.offset), end: Double($0.offset + 1), velocity: 1)
        }
        notes.append(.init(id: "silent", pitch: 61, start: 0, end: 7, velocity: 0))
        let candidates = try WorkflowMusicPrograms.keys(
            sequence: .init(clock: .quarterNotes, notes: notes, duration: 7)
        )
        XCTAssertEqual(candidates.count, 6)
        XCTAssertTrue(candidates.contains { $0.root == 0 && $0.mode == "major" })
        XCTAssertTrue(candidates.contains { $0.root == 9 && $0.mode == "minor" })
        XCTAssertTrue(candidates.allSatisfy { $0.algorithm == "duration-scale-triad-v1" })
        XCTAssertGreaterThanOrEqual(candidates[0].score, candidates[1].score)

        let insufficient = WorkflowNoteSequence(
            clock: .seconds,
            notes: [
                .init(id: "a", pitch: 60, start: 0, end: 1, velocity: 1),
                .init(id: "b", pitch: 64, start: 0, end: 1, velocity: 1),
                .init(id: "c", pitch: 67, start: 0, end: 1, velocity: 0),
            ], duration: 1
        )
        XCTAssertEqual(try WorkflowMusicPrograms.keys(sequence: insufficient), [])
    }

    func testChordVoicingInversionAndArpeggioTiming() throws {
        let track = WorkflowChordTrack(
            chords: [.init(id: "C", root: 0, quality: .major,
                           octave: 4, inversion: 1, start: 0, end: 1.2)],
            duration: 1.2
        )
        let sustained = try WorkflowMusicPrograms.chordNotes(track: track, pattern: .sustained)
        XCTAssertEqual(sustained.notes.map(\.pitch), [64, 67, 72])
        XCTAssertTrue(sustained.notes.allSatisfy { $0.start == 0 && $0.end == 1.2 })

        let arpeggio = try WorkflowMusicPrograms.chordNotes(track: track, pattern: .arpeggio)
        XCTAssertEqual(arpeggio.notes.map(\.pitch), [64, 67, 72])
        XCTAssertEqual(arpeggio.notes.map(\.start), [0, 0.5, 1])
        XCTAssertEqual(arpeggio.notes.map(\.end), [0.5, 1, 1.2])
    }

    func testChordDerivedIDsAreBoundedDeterministicAndUniqueForMaximumSourceID() throws {
        let sourceID = String(repeating: "é", count: 128)
        XCTAssertEqual(sourceID.utf8.count, 256)
        let track = WorkflowChordTrack(
            chords: [.init(id: sourceID, root: 0, quality: .major,
                           octave: 4, inversion: 0, start: 0, end: 1.5)],
            duration: 1.5
        )

        let sustained = try WorkflowMusicPrograms.chordNotes(track: track, pattern: .sustained)
        let sustainedAgain = try WorkflowMusicPrograms.chordNotes(track: track, pattern: .sustained)
        let arpeggio = try WorkflowMusicPrograms.chordNotes(track: track, pattern: .arpeggio)
        XCTAssertEqual(sustained.notes.map(\.id), sustainedAgain.notes.map(\.id))
        XCTAssertEqual(Set(sustained.notes.map(\.id)).count, sustained.notes.count)
        XCTAssertEqual(Set(arpeggio.notes.map(\.id)).count, arpeggio.notes.count)
        XCTAssertTrue((sustained.notes + arpeggio.notes).allSatisfy {
            !$0.id.isEmpty && $0.id.utf8.count <= 256
        })
        XCTAssertTrue(Set(sustained.notes.map(\.id)).isDisjoint(with: Set(arpeggio.notes.map(\.id))))
    }

    func testChordRejectsInvalidInversionAndOutOfMIDIVoicing() {
        let badInversion = WorkflowChordTrack(
            chords: [.init(id: "bad", root: 0, quality: .major,
                           octave: 4, inversion: 3, start: 0, end: 1)], duration: 1
        )
        XCTAssertThrowsError(try badInversion.validate())

        let tooHigh = WorkflowChordTrack(
            chords: [.init(id: "high", root: 11, quality: .major7,
                           octave: 9, inversion: 0, start: 0, end: 1)], duration: 1
        )
        XCTAssertThrowsError(try tooHigh.validate())
    }

    func testRenderProducesDecodableFiniteMonoFloat32WAVInMemory() throws {
        let sequence = WorkflowNoteSequence(
            clock: .seconds,
            notes: [
                .init(id: "a", pitch: 60, start: 0, end: 0.05, velocity: 1),
                .init(id: "b", pitch: 67, start: 0, end: 0.05, velocity: 0.5),
            ],
            duration: 0.05
        )
        let wav = try WorkflowMusicPrograms.render(sequence: sequence, sampleRate: 16_000)
        XCTAssertEqual(String(data: Data(wav[0..<4]), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: Data(wav[8..<12]), encoding: .ascii), "WAVE")
        XCTAssertEqual(uint16LE(wav, 20), 3)
        XCTAssertEqual(uint16LE(wav, 22), 1)
        XCTAssertEqual(uint32LE(wav, 24), 16_000)
        XCTAssertEqual(uint16LE(wav, 34), 32)
        XCTAssertEqual(Int(uint32LE(wav, 40)), wav.count - 44)
        for offset in stride(from: 44, to: wav.count, by: 4) {
            XCTAssertTrue(Float(bitPattern: uint32LE(wav, offset)).isFinite)
        }
    }

    func testRenderRejectsNegativeTimeMissingTempoAndComputationBudget() {
        let negative = WorkflowNoteSequence(
            clock: .seconds,
            notes: [.init(id: "n", pitch: 60, start: -1, end: 0, velocity: 1)],
            duration: 1
        )
        XCTAssertThrowsError(try WorkflowMusicPrograms.render(sequence: negative))

        let noTempo = WorkflowNoteSequence(
            clock: .quarterNotes,
            notes: [.init(id: "n", pitch: 60, start: 0, end: 1, velocity: 1)],
            duration: 1
        )
        XCTAssertThrowsError(try WorkflowMusicPrograms.render(sequence: noTempo))

        let expensiveNotes = (0..<32).map {
            WorkflowNoteEvent(id: "n\($0)", pitch: 40 + $0,
                              start: 0, end: 120, velocity: 1)
        }
        let expensive = WorkflowNoteSequence(clock: .seconds, notes: expensiveNotes, duration: 120)
        XCTAssertThrowsError(try WorkflowMusicPrograms.render(sequence: expensive, sampleRate: 48_000))
    }

    func testRenderRejectsAlreadyCancelledTaskDeterministically() async {
        let sequence = WorkflowNoteSequence(
            clock: .seconds,
            notes: [.init(id: "n", pitch: 60, start: 0, end: 1, velocity: 1)],
            duration: 1
        )
        let task = Task<Data, Error> {
            withUnsafeCurrentTask { current in current?.cancel() }
            return try WorkflowMusicPrograms.render(sequence: sequence)
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled reference render unexpectedly succeeded")
        } catch is CancellationError {
            // Expected: cancellation is observed without timing races.
        } catch {
            XCTFail("Expected CancellationError, received \(error)")
        }
    }

    func testMIDIUsesSMF0TempoVelocityOrderingAndDuration() throws {
        let tempo = WorkflowTempoMap(beatsPerMinute: 100, firstBeatSeconds: 0,
                                     numerator: 4, denominator: 4)
        let sequence = WorkflowNoteSequence(
            clock: .quarterNotes,
            notes: [
                .init(id: "a", pitch: 60, start: 0, end: 1, velocity: 0.5),
                .init(id: "silent", pitch: 70, start: 0, end: 2, velocity: 0),
                .init(id: "b", pitch: 60, start: 1, end: 2, velocity: 1),
            ],
            duration: 3,
            tempo: tempo
        )
        let midi = try WorkflowMusicPrograms.midi(sequence: sequence)
        XCTAssertEqual(String(data: Data(midi[0..<4]), encoding: .ascii), "MThd")
        XCTAssertEqual(uint16BE(midi, 8), 0)
        XCTAssertEqual(uint16BE(midi, 10), 1)
        XCTAssertEqual(uint16BE(midi, 12), 960)
        XCTAssertTrue(containsBytes(midi, [0xFF, 0x51, 0x03, 0x09, 0x27, 0xC0])) // 600000 µs/QN
        XCTAssertTrue(containsBytes(midi, [0x80, 60, 0, 0x00, 0x90, 60, 127]))
        XCTAssertFalse(containsBytes(midi, [0x90, 70]))
        XCTAssertTrue(containsBytes(midi, [0xFF, 0x2F, 0x00]))
    }

    func testMIDISecondsUse120AndRejectOverlapCollapseAndBeatWithoutTempo() throws {
        let seconds = WorkflowNoteSequence(
            clock: .seconds,
            notes: [.init(id: "n", pitch: 60, start: 0, end: 0.5, velocity: 1)],
            duration: 1
        )
        XCTAssertTrue(containsBytes(try WorkflowMusicPrograms.midi(sequence: seconds),
                                    [0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20]))

        let overlap = WorkflowNoteSequence(
            clock: .seconds,
            notes: [
                .init(id: "a", pitch: 60, start: 0, end: 1, velocity: 1),
                .init(id: "b", pitch: 60, start: 0.5, end: 1.5, velocity: 1),
            ], duration: 2
        )
        XCTAssertThrowsError(try WorkflowMusicPrograms.midi(sequence: overlap))

        let collapsed = WorkflowNoteSequence(
            clock: .seconds,
            notes: [.init(id: "tiny", pitch: 60, start: 0, end: 0.0001, velocity: 1)],
            duration: 1
        )
        XCTAssertThrowsError(try WorkflowMusicPrograms.midi(sequence: collapsed))

        let beatWithoutTempo = WorkflowNoteSequence(
            clock: .quarterNotes,
            notes: [.init(id: "n", pitch: 60, start: 0, end: 1, velocity: 1)],
            duration: 1
        )
        XCTAssertThrowsError(try WorkflowMusicPrograms.midi(sequence: beatWithoutTempo))
    }

    func testBeatTimelineOriginOffsetsMIDIAndWAVAndRejectsNegativeMappedTime() throws {
        let positiveTempo = WorkflowTempoMap(beatsPerMinute: 120, firstBeatSeconds: 1,
                                             numerator: 4, denominator: 4)
        let positive = WorkflowNoteSequence(
            clock: .quarterNotes,
            notes: [.init(id: "n", pitch: 60, start: 0, end: 1, velocity: 1)],
            duration: 1,
            tempo: positiveTempo
        )
        let events = try midiChannelEvents(WorkflowMusicPrograms.midi(sequence: positive))
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].tick, 1_920)
        XCTAssertEqual(events[0].status, 0x90)
        XCTAssertEqual(events[1].tick, 2_880)
        XCTAssertEqual(events[1].status, 0x80)

        let wav = try WorkflowMusicPrograms.render(sequence: positive, sampleRate: 16_000)
        XCTAssertEqual(Int(uint32LE(wav, 40)), 24_000 * 4)
        XCTAssertTrue(stride(from: 44, to: 44 + 16_000 * 4, by: 4).allSatisfy {
            uint32LE(wav, $0) == 0
        })
        XCTAssertTrue(stride(from: 44 + 16_000 * 4, to: wav.count, by: 4).contains {
            uint32LE(wav, $0) != 0
        })

        let negativeTempo = WorkflowTempoMap(beatsPerMinute: 120, firstBeatSeconds: -0.25,
                                             numerator: 4, denominator: 4)
        let negativeMapped = WorkflowNoteSequence(
            clock: .quarterNotes,
            notes: [.init(id: "n", pitch: 60, start: 0, end: 1, velocity: 1)],
            duration: 2,
            tempo: negativeTempo
        )
        XCTAssertThrowsError(try WorkflowMusicPrograms.midi(sequence: negativeMapped))
        XCTAssertThrowsError(try WorkflowMusicPrograms.render(sequence: negativeMapped))
    }

    private func makeSource() -> WorkflowAssetReference {
        WorkflowAssetReference(
            projectID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            assetID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            version: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            kind: .audio,
            sha256: String(repeating: "a", count: 64)
        )
    }

    private func uint16LE(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private func uint32LE(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 |
            UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    }

    private func uint16BE(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
    }

    private func uint32BE(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset]) << 24 | UInt32(data[offset + 1]) << 16 |
            UInt32(data[offset + 2]) << 8 | UInt32(data[offset + 3])
    }

    private func midiChannelEvents(_ data: Data) throws -> [(tick: Int, status: UInt8, pitch: UInt8, velocity: UInt8)] {
        guard data.count >= 22,
              String(data: Data(data[14..<18]), encoding: .ascii) == "MTrk" else {
            throw WorkflowIssue("Test MIDI lacks a track chunk.")
        }
        var offset = 22
        let trackEnd = offset + Int(uint32BE(data, 18))
        guard trackEnd <= data.count else { throw WorkflowIssue("Test MIDI track length is invalid.") }

        func readVLQ() throws -> Int {
            var value = 0
            var count = 0
            while true {
                guard offset < trackEnd, count < 4 else { throw WorkflowIssue("Test MIDI VLQ is invalid.") }
                let byte = data[offset]
                offset += 1
                value = (value << 7) | Int(byte & 0x7F)
                count += 1
                if byte & 0x80 == 0 { return value }
            }
        }

        var tick = 0
        var events: [(tick: Int, status: UInt8, pitch: UInt8, velocity: UInt8)] = []
        while offset < trackEnd {
            tick += try readVLQ()
            guard offset < trackEnd else { throw WorkflowIssue("Test MIDI event is truncated.") }
            let status = data[offset]
            offset += 1
            if status == 0xFF {
                guard offset < trackEnd else { throw WorkflowIssue("Test MIDI meta event is truncated.") }
                offset += 1 // meta type
                let length = try readVLQ()
                guard length >= 0, offset <= trackEnd - length else {
                    throw WorkflowIssue("Test MIDI meta event length is invalid.")
                }
                offset += length
            } else {
                guard status & 0xF0 == 0x80 || status & 0xF0 == 0x90,
                      offset <= trackEnd - 2 else {
                    throw WorkflowIssue("Test MIDI contains an unsupported channel event.")
                }
                events.append((tick, status & 0xF0, data[offset], data[offset + 1]))
                offset += 2
            }
        }
        return events
    }

    private func containsBytes(_ data: Data, _ bytes: [UInt8]) -> Bool {
        guard !bytes.isEmpty, data.count >= bytes.count else { return false }
        return (0...(data.count - bytes.count)).contains { start in
            data[start..<(start + bytes.count)].elementsEqual(bytes)
        }
    }
}
