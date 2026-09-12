import DInference
import Foundation
import Testing

struct AudioMusicRequestTests {
    let notes = [AudioNoteEvent(pitch: 60, startFrame: 0, endFrame: 25),
                 AudioNoteEvent(pitch: 64, startFrame: 25, endFrame: 50)]

    @Test func musicRoundTripHasNoDiffusionFields() throws {
        let value = AudioRequest(prompt: "钢琴 🎹", seed: UInt64(UInt32.max),
                                 noteSequence: .init(durationFrames: 100, notes: notes))
        try value.validate()
        let data = try JSONEncoder().encode(value)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["steps"] == nil && json["guidanceScale"] == nil && json["strength"] == nil)
        #expect(try JSONDecoder().decode(AudioRequest.self, from: data) == value)
        #expect(value.diffusion == nil && value.outputSampleRate == 48_000)
    }

    @Test func oldFlatSnapshotStaysFlat() throws {
        let data = Data(#"{"operation":"variation","prompt":"old","durationSeconds":1,"seed":42,"steps":8,"guidanceScale":1,"strength":0.5,"source":{"url":"file:///tmp/source.wav","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","frameCount":44100,"sampleRate":44100,"channels":2}}"#.utf8)
        let old = try JSONDecoder().decode(AudioRequest.self, from: data)
        let encoded = try JSONEncoder().encode(old)
        let actual = try #require(JSONSerialization.jsonObject(with: encoded) as? NSDictionary)
        #expect(actual == (try JSONSerialization.jsonObject(with: data) as? NSDictionary))
        #expect(old.diffusion?.strength == 0.5 && old.noteSequence == nil && old.outputSampleRate == 44_100)
    }

    @Test func absentAndEmptyRemainDifferent() throws {
        let absent = AudioNoteSequence(durationFrames: 100, notes: nil)
        let empty = AudioNoteSequence(durationFrames: 100, notes: [])
        #expect(absent != empty)
        for value in [absent, empty] {
            #expect(try JSONDecoder().decode(AudioNoteSequence.self, from: JSONEncoder().encode(value)) == value)
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(AudioNoteSequence.self,
                from: Data(#"{"schemaVersion":1,"frameRate":25,"durationFrames":100,"notes":null}"#.utf8))
        }
    }

    @Test func chordsAndAdjacentOnsetsAreValid() throws {
        let value = AudioNoteSequence(durationFrames: 50, notes: [
            .init(pitch: 60, startFrame: 0, endFrame: 25), .init(pitch: 60, startFrame: 25, endFrame: 50),
            .init(pitch: 64, startFrame: 0, endFrame: 50), .init(pitch: 67, startFrame: 0, endFrame: 50)])
        try value.validate()
        #expect(value.durationSeconds == 2)
    }

    @Test func invalidNotesAndProfileBoundaries() {
        let bad = [AudioNoteSequence(durationFrames: 401, notes: nil),
                   .init(frameRate: 50, durationFrames: 100, notes: nil),
                   .init(schemaVersion: 2, durationFrames: 100, notes: nil),
                   .init(durationFrames: 0, notes: nil),
                   .init(durationFrames: 10, notes: [.init(pitch: 128, startFrame: 0, endFrame: 1)]),
                   .init(durationFrames: 10, notes: [.init(pitch: 60, startFrame: -1, endFrame: 1)]),
                   .init(durationFrames: 10, notes: [.init(pitch: 60, startFrame: 1, endFrame: 1)]),
                   .init(durationFrames: 10, notes: [.init(pitch: 60, startFrame: 0, endFrame: 11)]),
                   .init(durationFrames: 10, notes: [.init(pitch: 60, startFrame: 0, endFrame: 5), .init(pitch: 60, startFrame: 4, endFrame: 6)]),
                   .init(durationFrames: 10, notes: Array(repeating: .init(pitch: 60, startFrame: 0, endFrame: 1), count: 513))]
        for value in bad { #expect(throws: (any Error).self) { try value.validate() } }
    }

    @Test func forgedRequestCannotMixClocksOrFamilies() throws {
        let request = AudioRequest(prompt: "piano", seed: 42, noteSequence: .init(durationFrames: 100, notes: notes))
        let base = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        for changes: [String: Any] in [ ["steps": 8], ["durationSeconds": 5], ["operation": "variation"],
                                      ["seed": UInt64(UInt32.max) + 1], ["seed": true], ["prompt": " "]] {
            let object = base.merging(changes) { _, new in new }
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode(AudioRequest.self, from: JSONSerialization.data(withJSONObject: object))
            }
        }
    }

    @Test func strictConditionFields() {
        for json in [#"{"schemaVersion":true,"frameRate":25,"durationFrames":100}"#,
                     #"{"schemaVersion":1,"frameRate":25,"durationFrames":100,"velocity":50}"#,
                     #"{"schemaVersion":1,"frameRate":25,"durationFrames":100,"notes":[{"pitch":60,"startFrame":0,"endFrame":25,"gain":1}]}"#] {
            #expect(throws: (any Error).self) { try JSONDecoder().decode(AudioNoteSequence.self, from: Data(json.utf8)) }
        }
    }

    @Test func legacyRequestCannotSilentlyDiscardNotes() {
        let json = #"{"operation":"generate","prompt":"piano","durationSeconds":1,"seed":42,"steps":8,"guidanceScale":1,"strength":1,"notes":[]}"#
        #expect(throws: (any Error).self) { try JSONDecoder().decode(AudioRequest.self, from: Data(json.utf8)) }
    }
}
