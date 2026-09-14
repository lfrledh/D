import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import zlib

public struct ImageReferencePixels: Sendable {
    public let width: Int
    public let height: Int
    public let rgb: Data
    public let sourceSHA256: String

    public static func decodePNG(_ data: Data) throws -> Self {
        let source = Data(data)
        let validated = try ReferencePNG.validate(source)
        let rgba = try ReferencePNG.decodeRGBA(validated)
        var rgb = Data(capacity: validated.width * validated.height * 3)
        for pixel in stride(from: 0, to: rgba.count, by: 4) {
            rgb.append(rgba[pixel])
            rgb.append(rgba[pixel + 1])
            rgb.append(rgba[pixel + 2])
        }
        let digest = SHA256.hash(data: source).map { String(format: "%02x", $0) }.joined()
        return Self(width: validated.width, height: validated.height, rgb: rgb,
                    sourceSHA256: digest)
    }
}

public enum ImageReferencePixelsError: Error, Equatable, LocalizedError, Sendable {
    case inputTooLarge
    case resourceLimitExceeded
    case invalidPNG
    case unsupportedFormat
    case unsupportedDimensions
    case unsupportedColor
    case unsupportedOrientation
    case decodeFailed

    public var errorDescription: String? {
        switch self {
        case .inputTooLarge: "参考 PNG 超过 64 MiB 读取限制。"
        case .resourceLimitExceeded: "参考 PNG 的压缩数据或元数据超过安全处理限制。"
        case .invalidPNG: "参考 PNG 已损坏或数据不完整。"
        case .unsupportedFormat: "仅支持单帧、8 位 RGB 或 RGBA PNG。"
        case .unsupportedDimensions: "参考 PNG 的宽高须为 256…2048 且为 32 的倍数。"
        case .unsupportedColor: "参考 PNG 缺少可确认的 RGB 色彩描述，或包含冲突的色彩声明。"
        case .unsupportedOrientation: "参考 PNG 的方向不是此版本支持的正常方向。"
        case .decodeFailed: "参考 PNG 像素无法完整解码。"
        }
    }
}

private enum ReferencePNG {
    static let signature = Data([137, 80, 78, 71, 13, 10, 26, 10])
    static let maximumInputBytes = 64 * 1_024 * 1_024
    static let maximumIDATBytes = 32 * 1_024 * 1_024
    static let maximumMetadataBytes = 2 * 1_024 * 1_024
    static let maximumInflatedMetadataBytes = 1 * 1_024 * 1_024
    static let maximumICCBytes = 4 * 1_024 * 1_024
    static let maximumChunks = 4_096

    struct Validated {
        let width: Int
        let height: Int
        let sanitized: Data
    }

    static func validate(_ input: Data) throws -> Validated {
        guard input.count <= maximumInputBytes else { throw ImageReferencePixelsError.inputTooLarge }
        guard input.count >= signature.count, input.starts(with: signature) else {
            throw ImageReferencePixelsError.invalidPNG
        }

        var offset = signature.count
        var chunkCount = 0
        var width = 0
        var height = 0
        var colorType: UInt8 = 0
        var interlace: UInt8 = 0
        var sawHeader = false
        var sawIDAT = false
        var finishedIDAT = false
        var sawEnd = false
        var sawTransparency = false
        var idat = Data()
        var idatBytes = 0
        var metadataBytes = 0
        var inflatedMetadataBytes = 0
        var headerRaw: Data?
        var idatRaw: [Data] = []
        var transparencyRaw: Data?
        var endRaw: Data?
        var srgbRaw: Data?
        var gammaRaw: Data?
        var chromaticitiesRaw: Data?
        var gammaPayload: Data?
        var chromaticitiesPayload: Data?
        var iccRaw: Data?
        var sawGamma = false
        var sawChromaticities = false

        while offset < input.count {
            guard chunkCount < maximumChunks else {
                throw ImageReferencePixelsError.resourceLimitExceeded
            }
            chunkCount += 1
            guard offset <= input.count - 12 else { throw ImageReferencePixelsError.invalidPNG }
            let length = Int(try readUInt32(input, at: offset))
            guard length <= maximumInputBytes, offset <= input.count - 12 - length else {
                throw ImageReferencePixelsError.invalidPNG
            }
            let typeBytes = Data(input[(offset + 4)..<(offset + 8)])
            guard typeBytes.count == 4,
                  typeBytes.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) }),
                  (typeBytes[2] & 0x20) == 0,
                  let type = String(data: typeBytes, encoding: .ascii) else {
                throw ImageReferencePixelsError.invalidPNG
            }
            let payloadStart = offset + 8
            let payloadEnd = payloadStart + length
            let payload = Data(input[payloadStart..<payloadEnd])
            var crcInput = typeBytes
            crcInput.append(payload)
            let expectedCRC = try readUInt32(input, at: payloadEnd)
            guard crc32Value(crcInput) == expectedCRC else {
                throw ImageReferencePixelsError.invalidPNG
            }
            let end = payloadEnd + 4
            let raw = Data(input[offset..<end])
            offset = end
            guard !sawEnd else { throw ImageReferencePixelsError.invalidPNG }

            if type == "IHDR" {
                guard !sawHeader, chunkCount == 1, payload.count == 13 else {
                    throw ImageReferencePixelsError.invalidPNG
                }
                width = Int(try readUInt32(payload, at: 0))
                height = Int(try readUInt32(payload, at: 4))
                guard width >= 256, width <= 2_048, height >= 256, height <= 2_048,
                      width.isMultiple(of: 32), height.isMultiple(of: 32) else {
                    throw ImageReferencePixelsError.unsupportedDimensions
                }
                guard payload[8] == 8, payload[9] == 2 || payload[9] == 6,
                      payload[10] == 0, payload[11] == 0, payload[12] <= 1 else {
                    throw ImageReferencePixelsError.unsupportedFormat
                }
                colorType = payload[9]
                interlace = payload[12]
                sawHeader = true
                headerRaw = raw
                continue
            }

            guard sawHeader else { throw ImageReferencePixelsError.invalidPNG }
            if sawIDAT, type != "IDAT", type != "IEND" { finishedIDAT = true }
            switch type {
            case "IDAT":
                guard !finishedIDAT, length > 0 else { throw ImageReferencePixelsError.invalidPNG }
                guard idatBytes <= maximumIDATBytes - length else {
                    throw ImageReferencePixelsError.resourceLimitExceeded
                }
                idatBytes += length
                idat.append(payload)
                idatRaw.append(raw)
                sawIDAT = true
            case "IEND":
                guard payload.isEmpty, sawIDAT, offset == input.count else {
                    throw ImageReferencePixelsError.invalidPNG
                }
                sawEnd = true
                endRaw = raw
            case "PLTE":
                guard !sawIDAT, colorType == 2 || colorType == 6,
                      payload.count >= 3, payload.count <= 768, payload.count.isMultiple(of: 3) else {
                    throw ImageReferencePixelsError.invalidPNG
                }
                try addMetadata(length, total: &metadataBytes)
            case "tRNS":
                guard !sawIDAT, !sawTransparency, colorType == 2, payload.count == 6 else {
                    throw ImageReferencePixelsError.unsupportedFormat
                }
                sawTransparency = true
                transparencyRaw = raw
            case "sRGB":
                guard !sawIDAT, srgbRaw == nil, iccRaw == nil,
                      payload.count == 1, payload[0] <= 3 else {
                    throw ImageReferencePixelsError.unsupportedColor
                }
                srgbRaw = raw
            case "gAMA":
                guard !sawIDAT, !sawGamma, payload.count == 4 else {
                    throw ImageReferencePixelsError.unsupportedColor
                }
                sawGamma = true
                gammaRaw = raw
                gammaPayload = payload
            case "cHRM":
                guard !sawIDAT, !sawChromaticities, payload.count == 32 else {
                    throw ImageReferencePixelsError.unsupportedColor
                }
                sawChromaticities = true
                chromaticitiesRaw = raw
                chromaticitiesPayload = payload
            case "iCCP":
                guard !sawIDAT, iccRaw == nil, srgbRaw == nil else {
                    throw ImageReferencePixelsError.unsupportedColor
                }
                try validateICC(payload)
                iccRaw = raw
            case "cICP", "mDCV", "cLLI":
                throw ImageReferencePixelsError.unsupportedColor
            case "acTL", "fcTL", "fdAT":
                throw ImageReferencePixelsError.unsupportedFormat
            case "eXIf":
                guard !sawIDAT else { throw ImageReferencePixelsError.invalidPNG }
                try addMetadata(length, total: &metadataBytes)
                try validateOrientation(payload)
            case "zTXt":
                try addMetadata(length, total: &metadataBytes)
                try addInflatedMetadata(try validateCompressedText(payload),
                                        total: &inflatedMetadataBytes)
            case "iTXt":
                try addMetadata(length, total: &metadataBytes)
                try addInflatedMetadata(try validateInternationalText(payload),
                                        total: &inflatedMetadataBytes)
            case "tEXt":
                try addMetadata(length, total: &metadataBytes)
                try validateKeyword(payload)
            default:
                if typeBytes[0] & 0x20 == 0 { throw ImageReferencePixelsError.unsupportedFormat }
                try addMetadata(length, total: &metadataBytes)
            }
        }

        guard sawHeader, sawIDAT, sawEnd, let headerRaw, let endRaw else {
            throw ImageReferencePixelsError.invalidPNG
        }
        try validateColor(srgb: srgbRaw != nil, icc: iccRaw != nil,
                          gamma: gammaPayload, chromaticities: chromaticitiesPayload)
        try validateScanlines(idat, width: width, height: height,
                              channels: colorType == 2 ? 3 : 4, interlace: interlace)

        var sanitized = signature
        sanitized.append(headerRaw)
        if let srgbRaw { sanitized.append(srgbRaw) }
        if let iccRaw { sanitized.append(iccRaw) }
        if let gammaRaw { sanitized.append(gammaRaw) }
        if let chromaticitiesRaw { sanitized.append(chromaticitiesRaw) }
        if let transparencyRaw { sanitized.append(transparencyRaw) }
        for raw in idatRaw { sanitized.append(raw) }
        sanitized.append(endRaw)
        return Validated(width: width, height: height, sanitized: sanitized)
    }

    static func decodeRGBA(_ png: Validated) throws -> [UInt8] {
        guard let source = CGImageSourceCreateWithData(png.sanitized as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetStatus(source) == .statusComplete,
              let image = CGImageSourceCreateImageAtIndex(
                source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              image.width == png.width, image.height == png.height,
              let srgb = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw ImageReferencePixelsError.decodeFailed
        }
        let byteCount = png.width * png.height * 4
        var rgba = [UInt8](repeating: 255, count: byteCount)
        let bitmap = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        let drawn = rgba.withUnsafeMutableBytes { storage -> Bool in
            guard let base = storage.baseAddress,
                  let context = CGContext(data: base, width: png.width, height: png.height,
                                          bitsPerComponent: 8, bytesPerRow: png.width * 4,
                                          space: srgb, bitmapInfo: bitmap) else { return false }
            context.setBlendMode(.normal)
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: png.width, height: png.height))
            return true
        }
        guard drawn else { throw ImageReferencePixelsError.decodeFailed }
        return rgba
    }

    static func validateColor(srgb: Bool, icc: Bool, gamma: Data?, chromaticities: Data?) throws {
        if icc {
            guard gamma == nil, chromaticities == nil else {
                throw ImageReferencePixelsError.unsupportedColor
            }
            return
        }
        if srgb {
            if let gamma, try readUInt32(gamma, at: 0) != 45_455 {
                throw ImageReferencePixelsError.unsupportedColor
            }
            if let chromaticities, !isCanonicalSRGB(chromaticities) {
                throw ImageReferencePixelsError.unsupportedColor
            }
            return
        }
        guard let gamma, let chromaticities,
              try readUInt32(gamma, at: 0) == 45_455,
              isCanonicalSRGB(chromaticities) else {
            throw ImageReferencePixelsError.unsupportedColor
        }
    }

    static func isCanonicalSRGB(_ data: Data) -> Bool {
        let expected: [UInt32] = [31_270, 32_900, 64_000, 33_000,
                                  30_000, 60_000, 15_000, 6_000]
        return expected.enumerated().allSatisfy { index, value in
            (try? readUInt32(data, at: index * 4)) == value
        }
    }

    static func validateICC(_ payload: Data) throws {
        guard payload.count <= maximumMetadataBytes,
              let separator = payload.firstIndex(of: 0), separator >= 1, separator <= 79,
              payload[..<separator].allSatisfy(validKeywordByte),
              separator + 2 <= payload.count, payload[separator + 1] == 0 else {
            throw ImageReferencePixelsError.unsupportedColor
        }
        let compressed = Data(payload[(separator + 2)...])
        guard !compressed.isEmpty else { throw ImageReferencePixelsError.invalidPNG }
        let profile = try inflate(compressed, maximumOutput: maximumICCBytes, exactOutput: nil,
                                  limitError: .resourceLimitExceeded)
        guard profile.count >= 128,
              let space = CGColorSpace(iccData: profile as CFData),
              space.model == .rgb, space.numberOfComponents == 3 else {
            throw ImageReferencePixelsError.unsupportedColor
        }
    }

    static func validateScanlines(_ compressed: Data, width: Int, height: Int,
                                  channels: Int, interlace: UInt8) throws {
        let passes: [(Int, Int, Int, Int)] = interlace == 0
            ? [(0, 0, 1, 1)]
            : [(0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4),
               (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)]
        var rowStarts = Set<Int>()
        var expected = 0
        for (x, y, dx, dy) in passes where width > x && height > y {
            let columns = (width - x + dx - 1) / dx
            let rows = (height - y + dy - 1) / dy
            let rowBytes = columns * channels + 1
            for _ in 0..<rows {
                rowStarts.insert(expected)
                expected += rowBytes
            }
        }
        let bytes = try inflate(compressed, maximumOutput: expected, exactOutput: expected,
                                limitError: .invalidPNG)
        guard rowStarts.allSatisfy({ bytes[$0] <= 4 }) else {
            throw ImageReferencePixelsError.invalidPNG
        }
    }

    static func validateCompressedText(_ payload: Data) throws -> Int {
        guard let separator = payload.firstIndex(of: 0), separator >= 1, separator <= 79,
              payload[..<separator].allSatisfy(validKeywordByte),
              separator + 2 <= payload.count, payload[separator + 1] == 0 else {
            throw ImageReferencePixelsError.invalidPNG
        }
        let compressed = Data(payload[(separator + 2)...])
        guard !compressed.isEmpty else { throw ImageReferencePixelsError.invalidPNG }
        return try inflate(compressed, maximumOutput: maximumInflatedMetadataBytes,
                           exactOutput: nil, limitError: .resourceLimitExceeded).count
    }

    static func validateInternationalText(_ payload: Data) throws -> Int {
        guard let keywordEnd = payload.firstIndex(of: 0), keywordEnd >= 1, keywordEnd <= 79,
              payload[..<keywordEnd].allSatisfy(validKeywordByte),
              keywordEnd + 3 <= payload.count else { throw ImageReferencePixelsError.invalidPNG }
        let flag = payload[keywordEnd + 1]
        guard flag <= 1, payload[keywordEnd + 2] == 0 else {
            throw ImageReferencePixelsError.invalidPNG
        }
        let languageStart = keywordEnd + 3
        guard let languageEnd = payload[languageStart...].firstIndex(of: 0) else {
            throw ImageReferencePixelsError.invalidPNG
        }
        let translatedStart = languageEnd + 1
        guard let translatedEnd = payload[translatedStart...].firstIndex(of: 0) else {
            throw ImageReferencePixelsError.invalidPNG
        }
        if flag == 1 {
            let compressed = Data(payload[(translatedEnd + 1)...])
            guard !compressed.isEmpty else { throw ImageReferencePixelsError.invalidPNG }
            return try inflate(compressed, maximumOutput: maximumInflatedMetadataBytes,
                               exactOutput: nil, limitError: .resourceLimitExceeded).count
        }
        return 0
    }

    static func validateKeyword(_ payload: Data) throws {
        guard let separator = payload.firstIndex(of: 0), separator >= 1, separator <= 79,
              payload[..<separator].allSatisfy(validKeywordByte) else {
            throw ImageReferencePixelsError.invalidPNG
        }
    }

    static func validateOrientation(_ payload: Data) throws {
        guard payload.count >= 8 else { throw ImageReferencePixelsError.invalidPNG }
        let littleEndian: Bool
        if payload[0] == 0x49, payload[1] == 0x49 { littleEndian = true }
        else if payload[0] == 0x4d, payload[1] == 0x4d { littleEndian = false }
        else { throw ImageReferencePixelsError.invalidPNG }
        guard try readTIFFUInt16(payload, at: 2, littleEndian: littleEndian) == 42 else {
            throw ImageReferencePixelsError.invalidPNG
        }
        let ifdOffset = Int(try readTIFFUInt32(payload, at: 4, littleEndian: littleEndian))
        guard ifdOffset <= payload.count - 2 else { throw ImageReferencePixelsError.invalidPNG }
        let count = Int(try readTIFFUInt16(payload, at: ifdOffset, littleEndian: littleEndian))
        guard count <= 4_096, ifdOffset + 2 <= payload.count - count * 12 - 4 else {
            throw ImageReferencePixelsError.invalidPNG
        }
        var found = false
        for index in 0..<count {
            let entry = ifdOffset + 2 + index * 12
            guard try readTIFFUInt16(payload, at: entry, littleEndian: littleEndian) == 0x0112 else {
                continue
            }
            guard !found,
                  try readTIFFUInt16(payload, at: entry + 2, littleEndian: littleEndian) == 3,
                  try readTIFFUInt32(payload, at: entry + 4, littleEndian: littleEndian) == 1 else {
                throw ImageReferencePixelsError.invalidPNG
            }
            found = true
            let orientation = try readTIFFUInt16(payload, at: entry + 8, littleEndian: littleEndian)
            guard orientation == 1 else { throw ImageReferencePixelsError.unsupportedOrientation }
        }
        let nextIFDOffset = ifdOffset + 2 + count * 12
        guard try readTIFFUInt32(payload, at: nextIFDOffset, littleEndian: littleEndian) == 0 else {
            throw ImageReferencePixelsError.unsupportedFormat
        }
    }

    static func addMetadata(_ count: Int, total: inout Int) throws {
        guard count <= maximumMetadataBytes, total <= maximumMetadataBytes - count else {
            throw ImageReferencePixelsError.resourceLimitExceeded
        }
        total += count
    }

    static func addInflatedMetadata(_ count: Int, total: inout Int) throws {
        guard count <= maximumInflatedMetadataBytes,
              total <= maximumInflatedMetadataBytes - count else {
            throw ImageReferencePixelsError.resourceLimitExceeded
        }
        total += count
    }

    static func inflate(_ compressed: Data, maximumOutput: Int, exactOutput: Int?,
                        limitError: ImageReferencePixelsError) throws -> Data {
        var stream = z_stream()
        guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw ImageReferencePixelsError.decodeFailed
        }
        defer { inflateEnd(&stream) }
        var result = Data()
        result.reserveCapacity(min(maximumOutput, 64 * 1_024))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        try compressed.withUnsafeBytes { input in
            guard let base = input.bindMemory(to: UInt8.self).baseAddress else {
                throw ImageReferencePixelsError.invalidPNG
            }
            stream.next_in = UnsafeMutablePointer(mutating: base)
            stream.avail_in = uInt(input.count)
            while true {
                let previousInput = stream.avail_in
                let status: Int32 = buffer.withUnsafeMutableBytes { output in
                    stream.next_out = output.bindMemory(to: UInt8.self).baseAddress
                    stream.avail_out = uInt(output.count)
                    return zlib.inflate(&stream, Z_NO_FLUSH)
                }
                let produced = buffer.count - Int(stream.avail_out)
                guard result.count <= maximumOutput - produced else { throw limitError }
                result.append(contentsOf: buffer.prefix(produced))
                if status == Z_STREAM_END {
                    guard stream.avail_in == 0,
                          exactOutput == nil || result.count == exactOutput else {
                        throw ImageReferencePixelsError.invalidPNG
                    }
                    return
                }
                guard status == Z_OK, produced > 0 || stream.avail_in < previousInput else {
                    throw ImageReferencePixelsError.invalidPNG
                }
            }
        }
        return result
    }

    static func readUInt32(_ data: Data, at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset <= data.count - 4 else { throw ImageReferencePixelsError.invalidPNG }
        return data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | UInt32($1) }
    }

    static func readTIFFUInt16(_ data: Data, at offset: Int, littleEndian: Bool) throws -> UInt16 {
        guard offset >= 0, offset <= data.count - 2 else { throw ImageReferencePixelsError.invalidPNG }
        return littleEndian
            ? UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
            : UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
    }

    static func readTIFFUInt32(_ data: Data, at offset: Int, littleEndian: Bool) throws -> UInt32 {
        guard offset >= 0, offset <= data.count - 4 else { throw ImageReferencePixelsError.invalidPNG }
        if littleEndian {
            return UInt32(data[offset]) | UInt32(data[offset + 1]) << 8
                | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
        }
        return UInt32(data[offset]) << 24 | UInt32(data[offset + 1]) << 16
            | UInt32(data[offset + 2]) << 8 | UInt32(data[offset + 3])
    }

    static func validKeywordByte(_ byte: UInt8) -> Bool {
        (32...126).contains(byte) || (161...255).contains(byte)
    }

    static func crc32Value(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = crc & 1 == 1 ? (crc >> 1) ^ 0xedb8_8320 : crc >> 1
            }
        }
        return crc ^ 0xffff_ffff
    }
}
