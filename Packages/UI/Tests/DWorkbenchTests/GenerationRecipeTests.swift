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
        try rejects(try replacing(archive, "\"schema_version\":1", with: "\"schema_version\":true"))
        try rejects(try replacing(archive, "\"schema_version\":1", with: "\"schema_version\":1.0"))
        try rejects(try replacing(archive, "\"schema_version\":1", with: "\"schema_version\":1e0"))
        try rejects(try replacing(archive, "\"value\":4", with: "\"value\":true"))
        try rejects(try replacing(archive, "\"value\":\"42\"", with: "\"value\":\"01\""))
        try rejects(try replacing(archive, "\"value\":\"42\"", with: "\"value\":\"18446744073709551616\""))
        try rejects(try replacing(archive, "\"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\"", with: "\"١١١١١١١١١١١١١١١١١١١١١١١١١١١١١١١١١١١١١١١١١١١١١١١١١١١١١١١١١١\""))
        try rejects(try replacing(archive, "owner\\/repository", with: "file:\\/\\/secret"))
        try rejects(Data("{\"namespace\":\"org.d.generation-recipe\",\"namespace\":\"org.d.generation-recipe\",\"schema_version\":1,\"recipe\":{}}".utf8))
        try rejects(Data("{\"namespace\":\"org.d.generation-recipe\",\"schema_version\":1,\"recipe\":{},\"extra\":0}".utf8))
    }

    @Test func rejectsConflictingAndUnknownFieldStateShapes() throws {
        let archive = try GenerationRecipeCodec.encode(fixture(), disclosure: .privateArchive)
        try rejects(try replacing(archive, "\"state\":\"value\",\"value\":4", with: "\"state\":\"unknown\",\"value\":4"))
        try rejects(try replacing(archive, "\"state\":\"value\",\"value\":4", with: "\"state\":\"invalid\""))
        try rejects(try replacing(archive, "\"state\":\"value\",\"value\":4", with: "\"state\":\"SECRET_EXAMPLE_NEVER_ECHO\",\"value\":4"))
        try rejects(try replacing(archive, "\"state\":\"value\",\"value\":4", with: "\"state\":\"value\",\"value\":4,\"extra\":0"))
    }

    @Test func boundedParserAcceptsBracesInTextAndRejectsExcess() throws {
        let recipe = fixture(prompt: "literal { braces } and \\\"quotes\\\"")
        #expect(try GenerationRecipeCodec.decode(GenerationRecipeCodec.encode(recipe, disclosure: .privateArchive)).prompt == recipe.prompt)
        try rejects(Data(repeating: 123, count: 17) + Data("0".utf8) + Data(repeating: 125, count: 17))
        try rejects(Data(repeating: 32, count: 128 * 1024 + 1))
    }

    @Test func acceptsDocumentedParentAndPromptBoundaries() throws {
        var recipe = fixture(prompt: String(repeating: "a", count: 64 * 1024))
        recipe.guidance = .value(1.25)
        recipe.parents = (0..<32).map { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", $0 + 10))! }
        let decoded = try GenerationRecipeCodec.decode(GenerationRecipeCodec.encode(recipe, disclosure: .privateArchive))
        #expect(decoded.parents.count == 32)
        #expect(decoded.guidance == .value(1.25))
        recipe.parents.append(UUID())
        #expect(throws: Error.self) { try GenerationRecipeCodec.encode(recipe, disclosure: .privateArchive) }
    }

    @Test func rejectsNonFiniteGuidance() throws {
        var recipe = fixture(); recipe.guidance = .value(.infinity)
        #expect(throws: Error.self) { try GenerationRecipeCodec.encode(recipe, disclosure: .privateArchive) }
    }

    @Test func validJSONAtDepthLimitIsNotReportedAsDepthExceeded() throws {
        let depthLimitJSON = Data((String(repeating: "[", count: 16) + "0" + String(repeating: "]", count: 16)).utf8)
        do {
            _ = try GenerationRecipeCodec.decode(depthLimitJSON)
            Issue.record("A non-envelope must not decode as a recipe")
        } catch let error as GenerationRecipeError {
            #expect(error == .invalidStructure)
        }
    }

    @Test func validJSONAtInputSizeLimitIsNotReportedAsSizeExceeded() throws {
        let data = Data("0".utf8) + Data(repeating: 32, count: 128 * 1024 - 1)
        do {
            _ = try GenerationRecipeCodec.decode(data)
            Issue.record("A scalar must not decode as a recipe")
        } catch let error as GenerationRecipeError {
            #expect(error == .invalidStructure)
        }
    }

    private func rejects(_ data: Data) throws {
        #expect(throws: Error.self) { try GenerationRecipeCodec.decode(data) }
    }

    private func replacing(_ data: Data, _ old: String, with replacement: String) throws -> Data {
        let input = String(decoding: data, as: UTF8.self)
        guard input.contains(old) else { throw FixtureMutationError.missingNeedle }
        let output = input.replacingOccurrences(of: old, with: replacement)
        #expect(output != input)
        return Data(output.utf8)
    }

    private func fixture(prompt: String = "private prompt", seed: RecipeField<String> = .value("42")) -> GenerationRecipe {
        GenerationRecipe(assetID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, assetVersion: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, runID: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, modelSource: .value("owner/repository"), modelRevision: .value("rev.1"), weightsManifestSHA256: .value("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"), prompt: .value(prompt), structuredInputRevision: .value("input.1"), seed: seed, steps: .value(4), guidance: .value(1), width: .value(512), height: .value(512), scheduler: .value("flow"), computePrecision: .value("bf16"), quantization: .unknown, implementationVersion: .value("v1"), mediaPayloadSHA256: .unknown, parents: [UUID(uuidString: "00000000-0000-0000-0000-000000000004")!], claim: .captured)
    }

    private enum FixtureMutationError: Error { case missingNeedle }
}
