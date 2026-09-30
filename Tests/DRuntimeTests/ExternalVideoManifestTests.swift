import DInference
import Foundation
import Testing

@Suite("External video pack identity")
struct ExternalVideoManifestTests {
    @Test func manifestRoundTripAndCrossCheck() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let resources = root.appendingPathComponent("Backends/Video/Adapters/Resources")
        for (profile, model, text) in [
            (ExternalVideoExecutionProfile.h3BF16Full, "h3-fl2va-bf16", Optional<String>.none),
            (.ltx23BF16Full, "ltx23-bf16", "gemma3-bf16"),
            (.ltx23Q8GemmaQ4, "ltx23-q8-test", "gemma3-q4-test"),
        ] {
            let value = ExternalVideoModelManifest(profile: profile)
            try value.validate()
            #expect(try JSONDecoder().decode(ExternalVideoModelManifest.self, from: JSONEncoder().encode(value)) == value)
            let inventory = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: resources.appendingPathComponent(model + ".json"))) as? [String: Any])
            #expect(inventory["revision"] as? String == value.modelRevision)
            #expect(inventory["profile"] as? String == (profile == .h3BF16Full ? profile.rawValue : model))
            if let text {
                let encoder = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: resources.appendingPathComponent(text + ".json"))) as? [String: Any])
                #expect(encoder["revision"] as? String == value.textEncoderRevision)
            }
            var changed = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
            changed["modelRevision"] = "wrong"
            let invalid = try JSONDecoder().decode(ExternalVideoModelManifest.self, from: JSONSerialization.data(withJSONObject: changed))
            #expect(throws: InferenceFailure.self) { try invalid.validate() }
        }
        #expect(Set(ExternalVideoExecutionProfile.allCases.map(\.modelIdentity)).count == ExternalVideoExecutionProfile.allCases.count)
    }
}
