import DInference
import Foundation
import Testing
@testable import DWorkbench

struct WorkflowLanguageMusicOperationTests {
    @Test func structuredSchemaIsRejectedBeforeAdmission() throws {
        var node = WorkflowLanguageOperations.language.definition.makeNode()
        node.parameters["outputMode"] = .text("json")
        #expect(throws: (any Error).self) { try WorkflowRegistry.standard.validate(node) }
        node.dataConfiguration = .init(schema: .record([.init("bad", .asset(.audio))]))
        #expect(throws: (any Error).self) { try WorkflowRegistry.standard.validate(node) }
        node.dataConfiguration = .init(schema: .record([.init("title", .text)]))
        try WorkflowRegistry.standard.validate(node)
    }
    @Test func mrtUsesNotesAndPreservesNoConditionVersusEmpty() throws {
        let unconditioned = try WorkflowMRT2Condition.make(notes: nil, chords: nil, durationFrames: 100)
        let empty = try WorkflowMRT2Condition.make(notes: .init(clock: .seconds, notes: [], duration: 4), chords: nil, durationFrames: 100)
        #expect(unconditioned.notes == nil); #expect(empty.notes == [])
        let input = WorkflowNoteSequence(clock: .seconds, notes: [.init(id: "音🙂", pitch: 64, start: 0.04, end: 1.04, velocity: 0.5)], duration: 4)
        let result = try WorkflowMRT2Condition.make(notes: input, chords: nil, durationFrames: 100)
        #expect(result.notes == [.init(pitch: 64, startFrame: 1, endFrame: 26)])
        #expect(input.notes[0].velocity == 0.5)
    }
    @Test func conditionRejectsImplicitTruncationOrCollapse() {
        for interval in [(0.0, 4.1), (0.001, 0.005), (-0.1, 0.5)] {
            let notes = WorkflowNoteSequence(clock: .seconds, notes: [.init(id: "a", pitch: 60, start: interval.0, end: interval.1, velocity: 1)], duration: 5)
            #expect(throws: (any Error).self) { try WorkflowMRT2Condition.make(notes: notes, chords: nil, durationFrames: 100) }
        }
    }
    @Test func conditionFiltersSilenceAndUsesSameTimeline() throws {
        let silent = WorkflowNoteSequence(clock: .seconds, notes: [.init(id: "mute", pitch: 60, start: 0, end: 1, velocity: 0)], duration: 4)
        #expect(try WorkflowMRT2Condition.make(notes: silent, chords: nil, durationFrames: 100).notes == [])
        let notes = WorkflowNoteSequence(clock: .quarterNotes, notes: [.init(id: "a", pitch: 60, start: 3, end: 4, velocity: 1)], duration: 4,
                                        tempo: .init(beatsPerMinute: 100, firstBeatSeconds: -1.8, numerator: 4, denominator: 4))
        #expect(throws: (any Error).self) { try WorkflowMRT2Condition.make(notes: notes, chords: nil, durationFrames: 100) }
    }
    @Test func overlappingVoicesPreserveEveryOnsetAndRest() throws {
        let cases: [[(Int, Int)]] = [[(0,100),(50,60)],[(0,50),(25,75)],[(0,25),(0,100)],[(0,50),(50,100)],[(0,25),(50,100)],[(0,100),(10,20),(30,40)]]
        for events in cases {
            let source = WorkflowNoteSequence(clock: .seconds, notes: events.enumerated().map { i, pair in
                .init(id: String(i), pitch: 60, start: Double(pair.0)/25, end: Double(pair.1)/25, velocity: 1)
            }, duration: 4)
            let result = try WorkflowMRT2Condition.make(notes: source, chords: nil, durationFrames: 100)
            var expected = [Int](repeating: 0, count: 100)
            for event in events { for frame in event.0..<event.1 { expected[frame] = 1 } }
            for event in events { expected[event.0] = 2 }
            var actual = [Int](repeating: 0, count: 100)
            for event in result.notes! {
                for frame in event.startFrame..<event.endFrame { actual[frame] = frame == event.startFrame ? 2 : 1 }
            }
            #expect(actual == expected)
        }
    }

}
