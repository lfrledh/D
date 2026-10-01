import DInference
import Foundation
import Testing

@Suite("ACE 1.5 typed request contract")
struct ACERequestTests {
    private let reference = AudioSourceReference(
        url: URL(fileURLWithPath: "/tmp/ace-source.wav"),
        sha256: String(repeating: "a", count: 64), frameCount: 480_001,
        sampleRate: 48_000, channels: 2)

    @Test("Generation is on the official tenth-second grid; edits retain every source frame")
    func durationAndSourceCoordinates() throws {
        let exact = Double(reference.frameCount) / 48_000
        try AudioRequest(operation: .variation, prompt: "cover", durationSeconds: exact,
                         seed: 0, ace: ACERequest(editOptions: .cover(audioCoverStrength: 0.3,
                                                                       noiseStrength: 0.7)),
                         source: reference).validate()
        try AudioRequest(operation: .inpaint, prompt: "repaint", durationSeconds: exact,
                         seed: 0, ace: ACERequest(editOptions: .repaint(strength: 0.5)),
                         source: reference,
                         editRegion: .init(startFrame: 480_000, endFrame: 480_001)).validate()
        #expect(throws: (any Error).self) {
            try AudioRequest(operation: .generate, prompt: "x", durationSeconds: exact,
                             seed: 0, ace: ACERequest()).validate()
        }
        #expect(throws: (any Error).self) {
            try AudioRequest(operation: .inpaint, prompt: "x", durationSeconds: exact,
                             seed: 0, ace: ACERequest(editOptions: .repaint(strength: 0.5)),
                             source: reference,
                             editRegion: .init(startFrame: 480_001, endFrame: 480_002)).validate()
        }
    }

    @Test("Rounded ACE frames must fit Int64 before conversion")
    func extremeDurationThrows() {
        let extreme = 9_223_372_036_854_775_808.0 / 48_000
        let hugeSource = AudioSourceReference(url: reference.url, sha256: reference.sha256,
            frameCount: Int64.max, sampleRate: 48_000, channels: 2)
        #expect(throws: (any Error).self) {
            try AudioRequest(operation: .variation, prompt: "x", durationSeconds: extreme,
                seed: 0, ace: ACERequest(editOptions: .cover(audioCoverStrength: 0.5,
                    noiseStrength: 0.5)), source: hugeSource).validate()
        }
    }

    @Test("Malformed hashes, nonfinite controls and incompatible operations fail")
    func rejectInvalidFields() {
        let invalid = AudioSourceReference(url: reference.url, sha256: "ABC",
            frameCount: reference.frameCount, sampleRate: 48_000, channels: 2)
        #expect(throws: (any Error).self) { try ACERequest.validateReference(invalid) }
        for ace in [ACERequest(guidanceScale: .nan),
                    ACERequest(editOptions: .cover(audioCoverStrength: .infinity, noiseStrength: 0)),
                    ACERequest(editOptions: .repaint(strength: -0.1))] {
            #expect(throws: (any Error).self) { try ace.validate() }
        }
        #expect(throws: (any Error).self) {
            try AudioRequest(operation: .generate, prompt: "x", durationSeconds: 1,
                             seed: 0, ace: ACERequest(editOptions: .repaint(strength: 0.5))).validate()
        }
    }

    @Test("Full lyrics and reference survive encoding; unknown controls are rejected")
    func coding() throws {
        let original = AudioRequest(operation: .generate, prompt: "雨", durationSeconds: 1,
            seed: 42, ace: ACERequest(vocal: .lyrics(text: "全歌词", language: "zh"),
                                      referenceAudio: reference))
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(AudioRequest.self, from: data) == original)
        var value = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var parameters = try #require(value["parameters"] as? [String: Any])
        var ace = try #require(parameters["ace"] as? [String: Any])
        ace["ignoredControl"] = true
        parameters["ace"] = ace
        value["parameters"] = parameters
        let unknown = try JSONSerialization.data(withJSONObject: value)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(AudioRequest.self, from: unknown) }
    }
    @Test("Residency is explicit and backward compatible without changing precision or conditions")
    func loadingStrategy() throws {
        let layered = ACERequest(vocal: .lyrics(text: "保留全部歌词", language: "zh"),
            steps: 50, guidanceScale: 7, referenceAudio: reference, loadingStrategy: .ssdLayered)
        let bytes = try JSONEncoder().encode(layered)
        #expect(try JSONDecoder().decode(ACERequest.self, from: bytes) == layered)
        var old = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        old.removeValue(forKey: "loadingStrategy")
        let legacy = try JSONDecoder().decode(ACERequest.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(legacy.loadingStrategy == .resident)
        #expect(legacy.vocal == layered.vocal && legacy.referenceAudio == reference && legacy.steps == 50)
        old["loadingStrategy"] = "silently-quantize"
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ACERequest.self, from: JSONSerialization.data(withJSONObject: old))
        }
    }

}
