import Foundation
import Testing
@testable import DWorkbench

@Suite("Generation recipe privacy and strict codec")
struct GenerationRecipeTests {
    @Test func fieldsUnicodeAndMaximumSeedRoundTrip() throws {
        let recipe = fixture(prompt: "森の猫 🌊", seed: .value("18446744073709551615"))
        let decoded = try GenerationRecipeCodec.decode(GenerationRecipeCodec.encode(recipe, disclosure: .privateArchive))
        #expect(decoded.prompt == recipe.prompt)
        #expect(decoded.seed == recipe.seed)
        #expect(decoded.claim == .callerDeclared)
    }

    @Test func everyFieldStateHasDistinctJSONMeaning() throws {
        let fields: [RecipeField<String>] = [.value("fact"), .unknown, .notApplicable, .withheld, .invalid(reasonCode: "bad_input")]
        let encoded = try fields.map { try JSONEncoder().encode($0) }
        #expect(Set(encoded).count == 5)
        #expect(try encoded.map { try JSONDecoder().decode(RecipeField<String>.self, from: $0) } == fields)
    }

    @Test func publicProjectionRemovesPrivateMaterialWithoutMutatingSource() throws {
        let original = fixture()
        let publicRecipe = try GenerationRecipeCodec.decode(GenerationRecipeCodec.encode(original))
        #expect(publicRecipe.prompt == .withheld)
        #expect(publicRecipe.structuredInputRevision == .withheld)
        #expect(publicRecipe.parents.isEmpty)
        #expect(publicRecipe.claim == .callerDeclared)
        #expect(original.prompt == .value("private prompt"))
        #expect(original.parents.count == 1)
    }

    @Test func privateArchiveRetainsFactsButExternalClaimIsDowngraded() throws {
        let original = fixture()
        let decoded = try GenerationRecipeCodec.decode(GenerationRecipeCodec.encode(original, disclosure: .privateArchive))
        #expect(decoded.prompt == original.prompt)
        #expect(decoded.structuredInputRevision == original.structuredInputRevision)
        #expect(decoded.parents == original.parents)
        #expect(decoded.claim == .callerDeclared)
    }

    @Test func strictDecoderRejectsAmbiguityAndUnsafeValues() throws {
        let archive = try GenerationRecipeCodec.encode(fixture(), disclosure: .privateArchive)
        try rejects(replacing(archive, "\"schema_version\":1", with: "\"schema_version\":true"))
        try rejects(replacing(archive, "\"schema_version\":1", with: "\"schema_version\":1.0"))
        try rejects(replacing(archive, "\"value\":4", with: "\"value\":true"))
        try rejects(replacing(archive, "\"18446744073709551615\"", with: "\"01\""))
        try rejects(replacing(archive, "\"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\"", with: "\"ABCDEF\""))
        try rejects(replacing(archive, "\"owner/repository\"", with: "\"file:///secret\""))
        try rejects(Data("{\"namespace\":\"org.d.generation-recipe\",\"namespace\":\"org.d.generation-recipe\",\"schema_version\":1,\"recipe\":{}}".utf8))
        try rejects(Data("{\"namespace\":\"org.d.generation-recipe\",\"schema_version\":1,\"recipe\":{},\"extra\":0}".utf8))
    }

    @Test func boundedParserAcceptsBracesInTextAndRejectsExcess() throws {
        let recipe = fixture(prompt: "literal { braces } and \\\"quotes\\\"")
        #expect(try GenerationRecipeCodec.decode(GenerationRecipeCodec.encode(recipe, disclosure: .privateArchive)).prompt == recipe.prompt)
        try rejects(Data(repeating: 123, count: 17) + Data("0".utf8) + Data(repeating: 125, count: 17))
        try rejects(Data(repeating: 32, count: 128 * 1024 + 1))
    }

    private func rejects(_ data: Data) throws {
        #expect(throws: Error.self) { try GenerationRecipeCodec.decode(data) }
    }

    private func replacing(_ data: Data, _ old: String, with replacement: String) -> Data {
        Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: old, with: replacement).utf8)
    }

    private func fixture(prompt: String = "private prompt", seed: RecipeField<String> = .value("42")) -> GenerationRecipe {
        GenerationRecipe(assetID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, assetVersion: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, runID: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, modelSource: .value("owner/repository"), modelRevision: .value("rev.1"), weightsManifestSHA256: .value("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"), prompt: .value(prompt), structuredInputRevision: .value("input.1"), seed: seed, steps: .value(4), guidance: .value(1), width: .value(512), height: .value(512), scheduler: .value("flow"), computePrecision: .value("bf16"), quantization: .unknown, implementationVersion: .value("v1"), mediaPayloadSHA256: .unknown, parents: [UUID(uuidString: "00000000-0000-0000-0000-000000000004")!], claim: .captured)
    }
}
