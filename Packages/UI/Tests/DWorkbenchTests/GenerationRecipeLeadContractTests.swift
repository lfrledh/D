import Foundation
import Testing
@testable import DWorkbench

@Suite("GenerationRecipe Lead contract")
struct GenerationRecipeLeadContractTests {
    private func fixture() -> GenerationRecipe {
        GenerationRecipe(assetID: UUID(), assetVersion: UUID(), runID: UUID(), modelSource: .value("owner/model"), modelRevision: .unknown, weightsManifestSHA256: .unknown, prompt: .value("private material"), structuredInputRevision: .unknown, seed: .value("18446744073709551615"), steps: .value(4), guidance: .value(1), width: .value(512), height: .value(512), scheduler: .unknown, computePrecision: .unknown, quantization: .unknown, implementationVersion: .unknown, mediaPayloadSHA256: .unknown, parents: [], claim: .captured)
    }
    @Test func shaMustUseASCIIHexDigits() throws {
        var recipe = fixture(); recipe.weightsManifestSHA256 = .value(String(repeating: "١", count: 64))
        #expect(throws: Error.self) { try GenerationRecipeCodec.encode(recipe, disclosure: .privateArchive) }
    }
    @Test func parseErrorsDoNotEchoExternalSecretValues() throws {
        let data = try GenerationRecipeCodec.encode(fixture(), disclosure: .privateArchive)
        var envelope = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var recipe = try #require(envelope["recipe"] as? [String: Any])
        recipe["prompt"] = ["state": "SECRET_EXAMPLE_NEVER_ECHO", "value": "content"]
        envelope["recipe"] = recipe
        do {
            _ = try GenerationRecipeCodec.decode(JSONSerialization.data(withJSONObject: envelope))
            Issue.record("Invalid field state accepted")
        } catch {
            #expect(!String(describing: error).contains("SECRET_EXAMPLE_NEVER_ECHO"))
        }
    }
    @Test(arguments: ["1.0", "1e0"])
    func strictVersionToken(_ token: String) throws {
        let data = try GenerationRecipeCodec.encode(fixture(), disclosure: .privateArchive)
        let original = String(decoding: data, as: UTF8.self)
        try #require(original.contains("\"schema_version\":1"))
        #expect(throws: Error.self) { try GenerationRecipeCodec.decode(Data(original.replacingOccurrences(of: "\"schema_version\":1", with: "\"schema_version\":" + token).utf8)) }
    }
    @Test func validJSONNestingHitsDepthBudgetBeforeDecoding() {
        let deep = String(repeating: "[", count: 17) + "0" + String(repeating: "]", count: 17)
        #expect(throws: GenerationRecipeError.depthLimitExceeded) { try GenerationRecipeCodec.decode(Data(deep.utf8)) }
    }
}
