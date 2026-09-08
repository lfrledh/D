import CryptoKit
import Foundation

public struct PNGRecipeInspection: Sendable {
    public let recipe: GenerationRecipe?
    public let mediaPayloadSHA256: String
    public let width: Int
    public let height: Int
}

public enum PNGRecipeError: Error, Equatable {
    case invalidPNG, unsupportedPNG, sizeLimitExceeded, duplicateRecipe, unsupportedRecipe, invalidRecipe, privacyConflict
}

public enum PNGRecipeCodec {
    public static func inspect(_ png: Data) throws -> PNGRecipeInspection {
        let parsed = try PNG.parse(png)
        var recipe: GenerationRecipe?
        if let json = parsed.recipeJSON {
            do { recipe = try GenerationRecipeCodec.decode(json) }
            catch let error as GenerationRecipeError where error == .sizeLimitExceeded { throw PNGRecipeError.sizeLimitExceeded }
            catch { throw PNGRecipeError.invalidRecipe }
            guard let recipe else { throw PNGRecipeError.invalidRecipe }
            try PNG.verify(recipe, digest: parsed.digest, width: parsed.width, height: parsed.height)
        }
        return PNGRecipeInspection(recipe: recipe, mediaPayloadSHA256: parsed.digest, width: parsed.width, height: parsed.height)
    }

    public static func embedding(_ recipe: GenerationRecipe, in png: Data, disclosure: RecipeDisclosure = .publicShare) throws -> Data {
        let parsed = try PNG.parse(png)
        if parsed.recipeJSON != nil { _ = try inspect(png) }
        if disclosure == .publicShare && parsed.hasPrivateMetadata { throw PNGRecipeError.privacyConflict }
        try PNG.verify(recipe, digest: parsed.digest, width: parsed.width, height: parsed.height)
        var embedded = recipe
        embedded.mediaPayloadSHA256 = .value(parsed.digest)
        let json: Data
        do { json = try GenerationRecipeCodec.encode(embedded, disclosure: disclosure) }
        catch let error as GenerationRecipeError where error == .sizeLimitExceeded { throw PNGRecipeError.sizeLimitExceeded }
        catch { throw PNGRecipeError.invalidRecipe }
        let dChunk = try PNG.recipeChunk(json)
        var output = Data(PNG.signature)
        var replaced = false
        for chunk in parsed.chunks {
            if chunk.isRecipe {
                guard !replaced else { throw PNGRecipeError.duplicateRecipe }
                output.append(dChunk); replaced = true
            } else if chunk.type == "IEND" && !replaced {
                output.append(dChunk); output.append(chunk.raw); replaced = true
            } else {
                output.append(chunk.raw)
            }
        }
        guard output.count <= PNG.maxBytes else { throw PNGRecipeError.sizeLimitExceeded }
        let expectedRecipe: GenerationRecipe
        do { expectedRecipe = try GenerationRecipeCodec.decode(json) }
        catch { throw PNGRecipeError.invalidRecipe }
        let check = try inspect(output)
        guard check.recipe == expectedRecipe, check.mediaPayloadSHA256 == parsed.digest,
              check.width == parsed.width, check.height == parsed.height else { throw PNGRecipeError.invalidRecipe }
        return output
    }
}

private enum PNG {
    static let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
    static let maxBytes = 32 * 1024 * 1024
    static let maxChunks = 4096
    static let keyword = "org.d.generation-recipe"
    static let publicTypes: Set<String> = ["IHDR", "PLTE", "IDAT", "IEND", "tRNS", "cHRM", "gAMA", "iCCP", "sBIT", "sRGB", "cICP", "mDCV", "cLLI", "pHYs", "bKGD"]

    struct Chunk {
        let type: String
        let payload: Data
        let raw: Data
        let isRecipe: Bool
    }
    struct Parsed {
        let chunks: [Chunk], width: Int, height: Int, digest: String, recipeJSON: Data?, hasPrivateMetadata: Bool
    }

    static func parse(_ data: Data) throws -> Parsed {
        guard data.count <= maxBytes else { throw PNGRecipeError.sizeLimitExceeded }
        let input = Data(data)
        guard input.count >= signature.count, Array(input.prefix(8)) == signature else { throw PNGRecipeError.invalidPNG }
        var offset = 8, chunks: [Chunk] = [], width = 0, height = 0, colorType: UInt8 = 0, bitDepth: UInt8 = 0
        var seenIHDR = false, seenIEND = false, seenPLTE = false, sawIDAT = false, finishedIDAT = false, idatBytes = 0
        var recipeJSON: Data?, recipeCount = 0, hasPrivateMetadata = false
        var digestInput = Data(signature)
        while offset < input.count {
            guard chunks.count < maxChunks else { throw PNGRecipeError.sizeLimitExceeded }
            guard offset + 12 <= input.count else { throw PNGRecipeError.invalidPNG }
            let length = try u32(input, offset)
            guard length <= maxBytes else { throw PNGRecipeError.sizeLimitExceeded }
            guard offset <= input.count - 12 - Int(length) else { throw PNGRecipeError.invalidPNG }
            let typeBytes = Array(input[(offset + 4)..<(offset + 8)])
            guard typeBytes.allSatisfy(isASCIIAlpha), (typeBytes[2] & 0x20) == 0,
                  let type = String(bytes: typeBytes, encoding: .ascii) else { throw PNGRecipeError.invalidPNG }
            let payloadStart = offset + 8, payloadEnd = payloadStart + Int(length), crcStart = payloadEnd
            let payload = Data(input[payloadStart..<payloadEnd])
            let expected = try u32(input, crcStart)
            var crcInput = Data(typeBytes); crcInput.append(payload)
            guard crc32(crcInput) == expected else { throw PNGRecipeError.invalidPNG }
            let raw = Data(input[offset..<(crcStart + 4)])
            offset = crcStart + 4
            guard !seenIEND else { throw PNGRecipeError.invalidPNG }
            if type == "IHDR" {
                guard !seenIHDR, chunks.isEmpty, payload.count == 13 else { throw PNGRecipeError.invalidPNG }
                width = Int(try u32(payload, 0)); height = Int(try u32(payload, 4)); bitDepth = payload[8]; colorType = payload[9]
                guard width >= 1, height >= 1, width <= 8192, height <= 8192, width <= 16_777_216 / height,
                      legal(bitDepth, colorType), payload[10] == 0, payload[11] == 0, payload[12] <= 1 else { throw PNGRecipeError.invalidPNG }
                seenIHDR = true
            } else {
                guard seenIHDR else { throw PNGRecipeError.invalidPNG }
                switch type {
                case "PLTE":
                    guard !seenPLTE, !sawIDAT, colorType != 0, colorType != 4, payload.count >= 3, payload.count <= 768, payload.count % 3 == 0 else { throw PNGRecipeError.invalidPNG }
                    if colorType == 3 { guard payload.count / 3 <= (1 << Int(bitDepth)) else { throw PNGRecipeError.invalidPNG } }
                    seenPLTE = true
                case "IDAT":
                    guard !finishedIDAT else { throw PNGRecipeError.invalidPNG }; sawIDAT = true; idatBytes += payload.count
                case "IEND":
                    guard payload.isEmpty, sawIDAT, idatBytes > 0, offset == input.count else { throw PNGRecipeError.invalidPNG }; seenIEND = true
                case "acTL", "fcTL", "fdAT": throw PNGRecipeError.unsupportedPNG
                default:
                    if typeBytes[0] & 0x20 == 0 { throw PNGRecipeError.unsupportedPNG }
                }
                if sawIDAT && type != "IDAT" { finishedIDAT = true }
            }
            var isRecipe = false
            if type == "iTXt" || type == "tEXt" || type == "zTXt" {
                let textKeyword = try keyword(in: payload)
                if textKeyword == keyword {
                    recipeCount += 1
                    guard recipeCount == 1 else { throw PNGRecipeError.duplicateRecipe }
                    if type == "iTXt" { recipeJSON = try dRecipeJSON(payload); isRecipe = true }
                }
            }
            if type != "IHDR" && type != "IEND" && !isRecipe { if !publicTypes.contains(type) { hasPrivateMetadata = true } }
            if !isRecipe { digestInput.append(raw) }
            chunks.append(Chunk(type: type, payload: payload, raw: raw, isRecipe: isRecipe))
        }
        guard seenIHDR, seenIEND else { throw PNGRecipeError.invalidPNG }
        guard colorType != 3 || seenPLTE else { throw PNGRecipeError.invalidPNG }
        if recipeCount == 1 && recipeJSON == nil { throw PNGRecipeError.unsupportedRecipe }
        return Parsed(chunks: chunks, width: width, height: height, digest: SHA256.hash(data: digestInput).map { String(format: "%02x", $0) }.joined(), recipeJSON: recipeJSON, hasPrivateMetadata: hasPrivateMetadata)
    }

    static func verify(_ recipe: GenerationRecipe, digest: String, width: Int, height: Int) throws {
        if case .value(let value) = recipe.mediaPayloadSHA256, value != digest { throw PNGRecipeError.invalidRecipe }
        if case .value(let value) = recipe.width, value != width { throw PNGRecipeError.invalidRecipe }
        if case .value(let value) = recipe.height, value != height { throw PNGRecipeError.invalidRecipe }
    }

    static func recipeChunk(_ json: Data) throws -> Data {
        guard json.count <= 128 * 1024 else { throw PNGRecipeError.sizeLimitExceeded }
        var payload = Data(keyword.utf8); payload.append(0); payload.append(0); payload.append(0); payload.append(0); payload.append(0); payload.append(json)
        return chunk("iTXt", payload)
    }
    static func chunk(_ type: String, _ payload: Data) -> Data {
        var result = Data(); appendU32(UInt32(payload.count), to: &result); let typeData = Data(type.utf8); result.append(typeData); result.append(payload)
        var crcInput = typeData; crcInput.append(payload); appendU32(crc32(crcInput), to: &result); return result
    }
    static func keyword(in payload: Data) throws -> String {
        guard let first = payload.firstIndex(of: 0) else {
            if payload.starts(with: Data(keyword.utf8)) { throw PNGRecipeError.invalidRecipe }
            throw PNGRecipeError.invalidPNG
        }
        guard first > 0, let key = String(bytes: payload[..<first], encoding: .isoLatin1) else { throw PNGRecipeError.invalidPNG }
        return key
    }
    static func dRecipeJSON(_ payload: Data) throws -> Data {
        guard let first = payload.firstIndex(of: 0), String(bytes: payload[..<first], encoding: .isoLatin1) == keyword else { throw PNGRecipeError.invalidRecipe }
        let afterKey = first + 1
        guard afterKey + 2 <= payload.count else { throw PNGRecipeError.invalidRecipe }
        let flag = payload[afterKey], method = payload[afterKey + 1]
        guard flag == 0, method == 0 else { throw PNGRecipeError.unsupportedRecipe }
        let languageStart = afterKey + 2
        guard let languageEnd = payload[languageStart...].firstIndex(of: 0), languageEnd == languageStart else { throw PNGRecipeError.invalidRecipe }
        let translatedStart = languageEnd + 1
        guard let translatedEnd = payload[translatedStart...].firstIndex(of: 0), translatedEnd == translatedStart else { throw PNGRecipeError.invalidRecipe }
        return Data(payload[(translatedEnd + 1)...])
    }
    static func legal(_ depth: UInt8, _ color: UInt8) -> Bool {
        switch color { case 0: return [1, 2, 4, 8, 16].contains(depth); case 2, 4, 6: return [8, 16].contains(depth); case 3: return [1, 2, 4, 8].contains(depth); default: return false }
    }
    static func isASCIIAlpha(_ byte: UInt8) -> Bool { (65...90).contains(byte) || (97...122).contains(byte) }
    static func u32(_ data: Data, _ at: Int) throws -> UInt32 {
        guard at >= 0, at <= data.count - 4 else { throw PNGRecipeError.invalidPNG }
        return data[at..<(at + 4)].reduce(0) { ($0 << 8) | UInt32($1) }
    }
    static func appendU32(_ value: UInt32, to data: inout Data) { data.append(UInt8((value >> 24) & 255)); data.append(UInt8((value >> 16) & 255)); data.append(UInt8((value >> 8) & 255)); data.append(UInt8(value & 255)) }
    static func crc32(_ data: Data) -> UInt32 { var crc: UInt32 = 0xffff_ffff; for byte in data { crc ^= UInt32(byte); for _ in 0..<8 { crc = (crc & 1 == 1) ? (crc >> 1) ^ 0xedb8_8320 : crc >> 1 } }; return crc ^ 0xffff_ffff }
}
