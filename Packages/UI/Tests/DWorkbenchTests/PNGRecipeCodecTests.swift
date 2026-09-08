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
        #expect(inspected.mediaPayloadSHA256 == try PNGRecipeCodec.inspect(source).mediaPayloadSHA256)
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
        #expect(try PNGRecipeCodec.inspect(twice).recipe?.prompt == .value("replacement"))
        #expect(try PNGRecipeCodec.inspect(twice).mediaPayloadSHA256 == try PNGRecipeCodec.inspect(once).mediaPayloadSHA256)
    }

    @Test func rejectsRecipeDuplicatesAndUnsupportedTextForms() throws {
        let encoded = try PNGRecipeCodec.embedding(recipe(), in: png(), disclosure: .privateArchive)
        let duplicate = inserting(chunk("iTXt", recipeText(Data("{}".utf8))), beforeIENDIn: encoded)
        #expect(throws: PNGRecipeError.duplicateRecipe) { try PNGRecipeCodec.inspect(duplicate) }
        let text = inserting(chunk("tEXt", Data("org.d.generation-recipe\0not-json".utf8)), beforeIENDIn: png())
        #expect(throws: PNGRecipeError.unsupportedRecipe) { try PNGRecipeCodec.inspect(text) }
        let compressed = inserting(chunk("iTXt", Data("org.d.generation-recipe\0\1\0\0\0{}".utf8)), beforeIENDIn: png())
        #expect(throws: PNGRecipeError.unsupportedRecipe) { try PNGRecipeCodec.inspect(compressed) }
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
    private func append(_ value: UInt32, to data: inout Data) { data += Data([UInt8(value >> 24), UInt8(value >> 16), UInt8(value >> 8), UInt8(value)]) }
    private func crc(_ data: Data) -> UInt32 { var value: UInt32 = 0xffff_ffff; for byte in data { value ^= UInt32(byte); for _ in 0..<8 { value = value & 1 == 1 ? (value >> 1) ^ 0xedb8_8320 : value >> 1 } }; return value ^ 0xffff_ffff }
    private func inserting(_ chunk: Data, beforeIENDIn png: Data) -> Data { Data(png.dropLast(12)) + chunk + Data(png.suffix(12)) }
    private func chunkTypes(_ png: Data) -> [String] { var at = 8, result: [String] = []; while at + 12 <= png.count { let n = Int(png[at]) << 24 | Int(png[at + 1]) << 16 | Int(png[at + 2]) << 8 | Int(png[at + 3]); result.append(String(decoding: png[(at + 4)..<(at + 8)], as: UTF8.self)); at += 12 + n }; return result }
    private func nonRecipeBytes(_ png: Data) -> Data { var at = 8, output = Data(png.prefix(8)); while at + 12 <= png.count { let n = Int(png[at]) << 24 | Int(png[at + 1]) << 16 | Int(png[at + 2]) << 8 | Int(png[at + 3]); let end = at + 12 + n; let type = String(decoding: png[(at + 4)..<(at + 8)], as: UTF8.self); if type != "iTXt" { output += png[at..<end] }; at = end }; return output }
}
