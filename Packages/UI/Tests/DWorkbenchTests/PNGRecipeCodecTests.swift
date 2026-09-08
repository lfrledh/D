import Foundation
import Testing
@testable import DWorkbench

@Suite("PNG recipe codec")
struct PNGRecipeCodecTests {
    @Test func noRecipeIsDistinctFromError() throws {
        let inspection = try PNGRecipeCodec.inspect(png())
        #expect(inspection.recipe == nil)
        #expect(inspection.width == 1 && inspection.height == 1)
        #expect(inspection.mediaPayloadSHA256.count == 64)
    }

    @Test func privateRoundTripPreservesUnicodeAndMaximumSeed() throws {
        let source = png(extra: [chunk("eXIf", Data([1, 2, 3])), chunk("iCCP", Data([4]))])
        let output = try PNGRecipeCodec.embedding(recipe(), in: source, disclosure: .privateArchive)
        let inspected = try PNGRecipeCodec.inspect(output)
        #expect(inspected.recipe?.prompt == .value("森の猫 🌊"))
        #expect(inspected.recipe?.seed == .value("18446744073709551615"))
        #expect(inspected.recipe?.claim == .callerDeclared)
        #expect(nonRecipeBytes(output) == nonRecipeBytes(source))
        let original = try PNGRecipeCodec.inspect(source)
        #expect(inspected.mediaPayloadSHA256 == original.mediaPayloadSHA256)
    }

    @Test func publicProjectionAndPrivateMetadataRefusal() throws {
        let source = png(extra: [chunk("eXIf", Data([1]))])
        #expect(throws: PNGRecipeError.privacyConflict) { try PNGRecipeCodec.embedding(recipe(), in: source) }
        let safe = try PNGRecipeCodec.embedding(recipe(), in: png(), disclosure: .publicShare)
        let publicRecipe = try #require(PNGRecipeCodec.inspect(safe).recipe)
        #expect(publicRecipe.prompt == .withheld)
        #expect(publicRecipe.structuredInputRevision == .withheld)
        #expect(publicRecipe.parents.isEmpty)
    }

    @Test func replacesOneRecipeWithoutChangingDigest() throws {
        let once = try PNGRecipeCodec.embedding(recipe(), in: png(), disclosure: .privateArchive)
        var replacement = recipe(); replacement.prompt = .value("replacement")
        let twice = try PNGRecipeCodec.embedding(replacement, in: once, disclosure: .privateArchive)
        #expect(chunkTypes(twice).filter { $0 == "iTXt" }.count == 1)
        let secondInspection = try PNGRecipeCodec.inspect(twice)
        let firstInspection = try PNGRecipeCodec.inspect(once)
        #expect(secondInspection.recipe?.prompt == .value("replacement"))
        #expect(secondInspection.mediaPayloadSHA256 == firstInspection.mediaPayloadSHA256)
    }

    @Test func rejectsRecipeDuplicatesAndUnsupportedTextForms() throws {
        let encoded = try PNGRecipeCodec.embedding(recipe(), in: png(), disclosure: .privateArchive)
        let duplicate = inserting(chunk("iTXt", recipeText(Data("{}".utf8))), beforeIENDIn: encoded)
        #expect(throws: PNGRecipeError.duplicateRecipe) { try PNGRecipeCodec.inspect(duplicate) }
        let text = inserting(chunk("tEXt", Data("org.d.generation-recipe\0not-json".utf8)), beforeIENDIn: png())
        #expect(throws: PNGRecipeError.unsupportedRecipe) { try PNGRecipeCodec.inspect(text) }
        let compressed = inserting(chunk("iTXt", Data("org.d.generation-recipe\0".utf8) + Data([1, 0, 0, 0]) + Data("{}".utf8)), beforeIENDIn: png())
        #expect(throws: PNGRecipeError.unsupportedRecipe) { try PNGRecipeCodec.inspect(compressed) }
        let textFirst = png(chunks: [chunk("tEXt", Data("org.d.generation-recipe\0x".utf8)), chunk("iTXt", recipeText(Data("{}".utf8))), chunk("IDAT", Data([0]))])
        #expect(throws: PNGRecipeError.duplicateRecipe) { try PNGRecipeCodec.inspect(textFirst) }
    }

    @Test func rejectsDamagedAndStructurallyInvalidInputs() throws {
        var badCRC = png(); badCRC[badCRC.count - 1] ^= 1
        #expect(throws: PNGRecipeError.invalidPNG) { try PNGRecipeCodec.inspect(badCRC) }
        #expect(throws: PNGRecipeError.invalidPNG) { try PNGRecipeCodec.inspect(Data(png().dropLast())) }
        #expect(throws: PNGRecipeError.invalidPNG) { try PNGRecipeCodec.inspect(png() + Data([0])) }
        #expect(throws: PNGRecipeError.invalidPNG) { try PNGRecipeCodec.inspect(png(idat: Data())) }
        let split = Data([1]); let separated = png(chunks: [chunk("IDAT", split), chunk("tIME", Data(repeating: 0, count: 7)), chunk("IDAT", split)])
        #expect(throws: PNGRecipeError.invalidPNG) { try PNGRecipeCodec.inspect(separated) }
        #expect(throws: PNGRecipeError.unsupportedPNG) { try PNGRecipeCodec.inspect(png(extra: [chunk("acTL", Data(repeating: 0, count: 8))])) }
        #expect(throws: PNGRecipeError.unsupportedPNG) { try PNGRecipeCodec.inspect(png(extra: [chunk("ABCD", Data())])) }
    }

    @Test func rejectsIHDRPaletteAndDimensionFailures() throws {
        var invalidIHDR = Data([0, 0, 0, 1, 0, 0, 0, 1, 3, 2, 0, 0, 0])
        #expect(throws: PNGRecipeError.invalidPNG) { try PNGRecipeCodec.inspect(png(ihdr: invalidIHDR)) }
        invalidIHDR = Data([0, 0, 32, 1, 0, 0, 32, 1, 8, 0, 0, 0, 0])
        #expect(throws: PNGRecipeError.invalidPNG) { try PNGRecipeCodec.inspect(png(ihdr: invalidIHDR)) }
        let indexed = Data([0, 0, 0, 1, 0, 0, 0, 1, 1, 3, 0, 0, 0])
        #expect(throws: PNGRecipeError.invalidPNG) { try PNGRecipeCodec.inspect(png(ihdr: indexed)) }
        let badPalette = png(ihdr: indexed, chunks: [chunk("PLTE", Data([1, 2, 3, 4, 5, 6, 7, 8, 9])), chunk("IDAT", Data([0]))])
        #expect(throws: PNGRecipeError.invalidPNG) { try PNGRecipeCodec.inspect(badPalette) }
    }

    @Test func rejectsMismatchedRecipeFactsAndInvalidEnvelope() throws {
        var mismatch = recipe(); mismatch.width = .value(2)
        #expect(throws: PNGRecipeError.invalidRecipe) { try PNGRecipeCodec.embedding(mismatch, in: png(), disclosure: .privateArchive) }
        let invalid = inserting(chunk("iTXt", recipeText(Data("{}".utf8))), beforeIENDIn: png())
        #expect(throws: PNGRecipeError.invalidRecipe) { try PNGRecipeCodec.inspect(invalid) }
    }

    @Test func preservesUnknownDimensionsAndRejectsExistingTampering() throws {
        let source = png()
        let output = try PNGRecipeCodec.embedding(recipe(), in: source, disclosure: .privateArchive)
        let restored = try #require(PNGRecipeCodec.inspect(output).recipe)
        #expect(restored.width == .unknown && restored.height == .unknown)
        let malformed = inserting(chunk("iTXt", recipeText(Data("{}".utf8))), beforeIENDIn: source)
        #expect(throws: PNGRecipeError.invalidRecipe) { try PNGRecipeCodec.embedding(recipe(), in: malformed, disclosure: .privateArchive) }
        var known = recipe(); let digest = try PNGRecipeCodec.inspect(source).mediaPayloadSHA256
        known.mediaPayloadSHA256 = .value(digest); known.width = .value(1); known.height = .value(1)
        let validJSON = try GenerationRecipeCodec.encode(known, disclosure: .privateArchive)
        let corrupted = Data(String(decoding: validJSON, as: UTF8.self).replacingOccurrences(of: digest, with: String(repeating: "0", count: 64)).utf8)
        let tampered = inserting(chunk("iTXt", recipeText(corrupted)), beforeIENDIn: source)
        #expect(throws: PNGRecipeError.invalidRecipe) { try PNGRecipeCodec.inspect(tampered) }
        let wrongVersion = Data(String(decoding: validJSON, as: UTF8.self).replacingOccurrences(of: "\"schema_version\":1", with: "\"schema_version\":2").utf8)
        #expect(throws: PNGRecipeError.invalidRecipe) { try PNGRecipeCodec.inspect(inserting(chunk("iTXt", recipeText(wrongVersion)), beforeIENDIn: source)) }
    }

    @Test func textPrivacyAndResourceLimitsAreExplicit() throws {
        let unrelatedCompressed = chunk("iTXt", Data("local\0".utf8) + Data([1, 0]) + Data("en\0title\0opaque".utf8))
        let privateSource = png(extra: [unrelatedCompressed, chunk("tEXt", Data("note\0secret".utf8))])
        let privateOutput = try PNGRecipeCodec.embedding(recipe(), in: privateSource, disclosure: .privateArchive)
        #expect(nonRecipeBytes(privateOutput) == nonRecipeBytes(privateSource))
        #expect(throws: PNGRecipeError.privacyConflict) { try PNGRecipeCodec.embedding(recipe(), in: privateSource, disclosure: .publicShare) }
        let colorOnly = png(extra: [chunk("iCCP", Data([1, 2]))])
        _ = try PNGRecipeCodec.embedding(recipe(), in: colorOnly, disclosure: .publicShare)
        #expect(throws: PNGRecipeError.sizeLimitExceeded) { try PNGRecipeCodec.inspect(Data(repeating: 0, count: 32 * 1024 * 1024 + 1)) }
        let many = png(chunks: Array(repeating: chunk("tIME", Data(repeating: 0, count: 7)), count: 4096) + [chunk("IDAT", Data([0]))])
        #expect(throws: PNGRecipeError.sizeLimitExceeded) { try PNGRecipeCodec.inspect(many) }
    }

    @Test func acceptsAValidDataSliceWithoutAssumingZeroIndex() throws {
        let prefixed = Data([0]) + png()
        let sliced: Data = prefixed.dropFirst()
        let inspection = try PNGRecipeCodec.inspect(sliced)
        #expect(inspection.recipe == nil)
    }

    private func recipe() -> GenerationRecipe {
        GenerationRecipe(assetID: UUID(), assetVersion: UUID(), runID: UUID(), modelSource: .value("owner/model"), modelRevision: .unknown, weightsManifestSHA256: .unknown, prompt: .value("森の猫 🌊"), structuredInputRevision: .value("input"), seed: .value("18446744073709551615"), steps: .value(4), guidance: .value(1), width: .unknown, height: .unknown, scheduler: .unknown, computePrecision: .unknown, quantization: .unknown, implementationVersion: .unknown, mediaPayloadSHA256: .unknown, parents: [UUID()], claim: .captured)
    }
    private func png(ihdr: Data = Data([0, 0, 0, 1, 0, 0, 0, 1, 8, 0, 0, 0, 0]), idat: Data = Data([0]), extra: [Data] = [], chunks middle: [Data]? = nil) -> Data {
        png(ihdr: ihdr, chunks: middle ?? [chunk("IDAT", idat)] + extra)
    }
    private func png(ihdr: Data, chunks: [Data]) -> Data {
        Data([137, 80, 78, 71, 13, 10, 26, 10]) + chunk("IHDR", ihdr) + chunks.reduce(Data(), +) + chunk("IEND", Data())
    }
    private func chunk(_ type: String, _ payload: Data) -> Data {
        var data = Data(); append(UInt32(payload.count), to: &data); let name = Data(type.utf8); data += name; data += payload
        append(crc(name + payload), to: &data); return data
    }
    private func recipeText(_ json: Data) -> Data { Data("org.d.generation-recipe\0\0\0\0\0".utf8) + json }
    private func append(_ value: UInt32, to data: inout Data) { data += Data([UInt8((value >> 24) & 255), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)]) }
    private func crc(_ data: Data) -> UInt32 { var value: UInt32 = 0xffff_ffff; for byte in data { value ^= UInt32(byte); for _ in 0..<8 { value = value & 1 == 1 ? (value >> 1) ^ 0xedb8_8320 : value >> 1 } }; return value ^ 0xffff_ffff }
    private func inserting(_ chunk: Data, beforeIENDIn png: Data) -> Data { Data(png.dropLast(12)) + chunk + Data(png.suffix(12)) }
    private func chunkTypes(_ png: Data) -> [String] { var at = 8, result: [String] = []; while at + 12 <= png.count { let n = Int(png[at]) << 24 | Int(png[at + 1]) << 16 | Int(png[at + 2]) << 8 | Int(png[at + 3]); result.append(String(decoding: png[(at + 4)..<(at + 8)], as: UTF8.self)); at += 12 + n }; return result }
    private func nonRecipeBytes(_ png: Data) -> Data { var at = 8, output = Data(png.prefix(8)); while at + 12 <= png.count { let n = Int(png[at]) << 24 | Int(png[at + 1]) << 16 | Int(png[at + 2]) << 8 | Int(png[at + 3]); let end = at + 12 + n; let type = String(decoding: png[(at + 4)..<(at + 8)], as: UTF8.self); if type != "iTXt" { output += png[at..<end] }; at = end }; return output }
}
