import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import zlib
@testable import DWorkbench

@Suite("Bounded in-memory reference PNG decoding")
struct ImageReferencePixelsTests {
    @Test("RGB rows remain top-to-bottom and the source digest covers original bytes")
    func rgbPixelsAndRowOrientation() throws {
        var scanlines = Data()
        for row in 0..<256 {
            scanlines.append(0)
            let color: [UInt8] = row < 80 ? [255, 0, 0] : (row < 176 ? [0, 255, 0] : [0, 0, 255])
            for _ in 0..<256 { scanlines.append(contentsOf: color) }
        }
        let png = try PNGFixture.png(scanlines: scanlines)
        let decoded = try ImageReferencePixels.decodePNG(png)

        #expect(decoded.width == 256)
        #expect(decoded.height == 256)
        #expect(decoded.rgb.count == 256 * 256 * 3)
        #expect(Array(decoded.rgb[0..<3]) == [255, 0, 0])
        #expect(Array(decoded.rgb[(100 * 256 * 3)..<(100 * 256 * 3 + 3)]) == [0, 255, 0])
        #expect(Array(decoded.rgb[(255 * 256 * 3)..<(255 * 256 * 3 + 3)]) == [0, 0, 255])
        let expectedHash = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
        #expect(decoded.sourceSHA256 == expectedHash)
    }

    @Test("RGBA is composited onto white, including partial alpha")
    func transparencyUsesWhiteBackground() throws {
        var scanlines = Data()
        for row in 0..<256 {
            scanlines.append(0)
            for column in 0..<256 {
                switch (row, column) {
                case (0, 0): scanlines.append(contentsOf: [255, 0, 0, 128])
                case (0, 1): scanlines.append(contentsOf: [0, 0, 255, 0])
                case (255, 0): scanlines.append(contentsOf: [0, 0, 255, 255])
                default: scanlines.append(contentsOf: [0, 255, 0, 255])
                }
            }
        }
        let decoded = try ImageReferencePixels.decodePNG(
            try PNGFixture.png(colorType: 6, scanlines: scanlines))

        let partial = Array(decoded.rgb[0..<3])
        #expect(partial[0] == 255)
        #expect((126...128).contains(partial[1]))
        #expect((126...128).contains(partial[2]))
        #expect(Array(decoded.rgb[3..<6]) == [255, 255, 255])
        #expect(Array(decoded.rgb[(255 * 256 * 3)..<(255 * 256 * 3 + 3)]) == [0, 0, 255])
    }

    @Test("Explicit sRGB variants, a bounded RGB ICC profile, and the existing encoder are accepted")
    func recognizedColorSourcesAndExistingEncoder() throws {
        _ = try ImageReferencePixels.decodePNG(try PNGFixture.png())

        let canonical = try PNGFixture.png(
            colorChunks: [PNGFixture.gamma(), PNGFixture.chromaticities()])
        _ = try ImageReferencePixels.decodePNG(canonical)

        let icc = try #require(CGColorSpace(name: CGColorSpace.sRGB)?.copyICCData()) as Data
        let profile = Data("fixture-srgb".utf8) + Data([0, 0]) + (try PNGFixture.compress(icc))
        _ = try ImageReferencePixels.decodePNG(
            try PNGFixture.png(colorChunks: [PNGFixture.chunk("iCCP", profile)]))

        // 128/255 in linear light encodes to about 188/255 in IEC sRGB. This fixed
        // transfer-function oracle proves the decoder converts rather than relabels ICC data.
        let linearICC = try #require(CGColorSpace(name: CGColorSpace.linearSRGB)?.copyICCData()) as Data
        let linearProfile = Data("fixture-linear-srgb".utf8) + Data([0, 0])
            + (try PNGFixture.compress(linearICC))
        let linearPixels = PNGFixture.solidScanlines([128, 128, 128])
        let converted = try ImageReferencePixels.decodePNG(try PNGFixture.png(
            colorChunks: [PNGFixture.chunk("iCCP", linearProfile)], scanlines: linearPixels))
        #expect((186...190).contains(converted.rgb[0]))
        #expect((186...190).contains(converted.rgb[1]))
        #expect((186...190).contains(converted.rgb[2]))

        let encoded = try PNGFixture.imageIOEncodedPNG()
        let decoded = try ImageReferencePixels.decodePNG(encoded)
        #expect(decoded.width == 256 && decoded.height == 256)
        #expect(Array(decoded.rgb.prefix(3)) == [12, 34, 56])
    }

    @Test("Unrelated text and recipe metadata are inert")
    func metadataIsNotAnInstruction() throws {
        let recipeLike = Data("org.d.generation-recipe\0\0\0\0\0{not-required-json}".utf8)
        let uri = Data("source\0https://example.invalid/fetch-me".utf8)
        let png = try PNGFixture.png(metadata: [
            PNGFixture.chunk("iTXt", recipeLike), PNGFixture.chunk("tEXt", uri)
        ])
        _ = try ImageReferencePixels.decodePNG(png)
    }

    @Test("Malformed containers, CRCs, streams, scanlines, and truncation are rejected")
    func damagedInputsAreRejected() throws {
        let valid = try PNGFixture.png()
        var badCRC = valid
        badCRC[badCRC.count - 1] ^= 1
        #expect(throws: ImageReferencePixelsError.self) {
            try ImageReferencePixels.decodePNG(badCRC)
        }
        #expect(throws: ImageReferencePixelsError.self) {
            try ImageReferencePixels.decodePNG(Data(valid.dropLast()))
        }

        let damagedStream = try PNGFixture.png(idat: Data([0x78, 0x9c, 0, 1, 2, 3]))
        #expect(throws: ImageReferencePixelsError.self) {
            try ImageReferencePixels.decodePNG(damagedStream)
        }

        var invalidFilters = PNGFixture.blankScanlines(channels: 3)
        invalidFilters[0] = 5
        #expect(throws: ImageReferencePixelsError.self) {
            try ImageReferencePixels.decodePNG(try PNGFixture.png(scanlines: invalidFilters))
        }

        let shortPixels = Data(PNGFixture.blankScanlines(channels: 3).dropLast())
        #expect(throws: ImageReferencePixelsError.self) {
            try ImageReferencePixels.decodePNG(try PNGFixture.png(scanlines: shortPixels))
        }
    }

    @Test("Geometry is rejected rather than clamped or rescaled")
    func invalidGeometryIsRejected() throws {
        for (width, height) in [(255, 256), (256, 255), (2_080, 256), (256, 2_080)] {
            #expect(throws: ImageReferencePixelsError.self) {
                try ImageReferencePixels.decodePNG(
                    try PNGFixture.png(width: width, height: height,
                                       scanlines: PNGFixture.blankScanlines(
                                        width: max(1, width), height: max(1, height), channels: 3)))
            }
        }
    }

    @Test("Animated, 16-bit, and rotated sources are explicitly unsupported")
    func unsupportedVariantsAreRejected() throws {
        #expect(throws: ImageReferencePixelsError.self) {
            try ImageReferencePixels.decodePNG(
                try PNGFixture.png(metadata: [PNGFixture.chunk("acTL", Data([0, 0, 0, 1, 0, 0, 0, 0]))]))
        }
        #expect(throws: ImageReferencePixelsError.self) {
            try ImageReferencePixels.decodePNG(try PNGFixture.png(bitDepth: 16))
        }
        #expect(throws: ImageReferencePixelsError.self) {
            try ImageReferencePixels.decodePNG(
                try PNGFixture.png(metadata: [PNGFixture.chunk("eXIf", PNGFixture.orientation(6))]))
        }
        _ = try ImageReferencePixels.decodePNG(
            try PNGFixture.png(metadata: [PNGFixture.chunk("eXIf", PNGFixture.orientation(1))]))

        let nonzeroNextIFD = Data([
            0x4d, 0x4d, 0x00, 0x2a, 0, 0, 0, 8, 0, 0, 0xff, 0xff, 0xff, 0xff
        ])
        #expect(throws: ImageReferencePixelsError.self) {
            try ImageReferencePixels.decodePNG(
                try PNGFixture.png(metadata: [PNGFixture.chunk("eXIf", nonzeroNextIFD)]))
        }
    }

    @Test("Input, metadata, and decompression budgets are enforced")
    func resourceBudgetsAreEnforced() throws {
        #expect(throws: ImageReferencePixelsError.self) {
            try ImageReferencePixels.decodePNG(Data(repeating: 0, count: 64 * 1_024 * 1_024 + 1))
        }

        let inflated = Data(repeating: 65, count: 1 * 1_024 * 1_024 + 1)
        let compressedText = Data("note".utf8) + Data([0, 0]) + (try PNGFixture.compress(inflated))
        #expect(throws: ImageReferencePixelsError.self) {
            try ImageReferencePixels.decodePNG(
                try PNGFixture.png(metadata: [PNGFixture.chunk("zTXt", compressedText)]))
        }

        var cumulativeCompressedText: [Data] = []
        for index in 0..<5 {
            let expanded = Data(repeating: UInt8(65 + index), count: 256 * 1_024)
            let payload = Data("note-\(index)".utf8) + Data([0, 0])
                + (try PNGFixture.compress(expanded))
            cumulativeCompressedText.append(PNGFixture.chunk("zTXt", payload))
        }
        #expect(throws: ImageReferencePixelsError.self) {
            try ImageReferencePixels.decodePNG(
                try PNGFixture.png(metadata: cumulativeCompressedText))
        }

        let directMetadata = Data("note\0".utf8) + Data(repeating: 0, count: 2 * 1_024 * 1_024)
        #expect(throws: ImageReferencePixelsError.self) {
            try ImageReferencePixels.decodePNG(
                try PNGFixture.png(metadata: [PNGFixture.chunk("tEXt", directMetadata)]))
        }
    }

    @Test("Unknown and conflicting color declarations are not called sRGB")
    func ambiguousColorIsRejected() throws {
        #expect(throws: ImageReferencePixelsError.self) {
            try ImageReferencePixels.decodePNG(try PNGFixture.png(colorChunks: []))
        }
        #expect(throws: ImageReferencePixelsError.self) {
            try ImageReferencePixels.decodePNG(
                try PNGFixture.png(colorChunks: [PNGFixture.chunk("gAMA", PNGFixture.word(100_000))]))
        }

        let icc = try #require(CGColorSpace(name: CGColorSpace.sRGB)?.copyICCData()) as Data
        let profile = Data("fixture-srgb".utf8) + Data([0, 0]) + (try PNGFixture.compress(icc))
        #expect(throws: ImageReferencePixelsError.self) {
            try ImageReferencePixels.decodePNG(try PNGFixture.png(colorChunks: [
                PNGFixture.chunk("sRGB", Data([0])), PNGFixture.chunk("iCCP", profile)
            ]))
        }
    }
}

private enum PNGFixture {
    static let signature = Data([137, 80, 78, 71, 13, 10, 26, 10])

    static func png(width: Int = 256, height: Int = 256, bitDepth: UInt8 = 8,
                    colorType: UInt8 = 2, colorChunks: [Data]? = nil,
                    metadata: [Data] = [], scanlines: Data? = nil, idat: Data? = nil) throws -> Data {
        var header = Data()
        header.append(word(UInt32(width)))
        header.append(word(UInt32(height)))
        header.append(contentsOf: [bitDepth, colorType, 0, 0, 0])
        let channels = colorType == 6 ? 4 : 3
        let stream = try idat ?? compress(scanlines ?? blankScanlines(
            width: width, height: height, channels: channels))
        var result = signature
        result.append(chunk("IHDR", header))
        for item in colorChunks ?? [chunk("sRGB", Data([0]))] { result.append(item) }
        for item in metadata { result.append(item) }
        result.append(chunk("IDAT", stream))
        result.append(chunk("IEND", Data()))
        return result
    }

    static func blankScanlines(width: Int = 256, height: Int = 256, channels: Int) -> Data {
        var result = Data(capacity: height * (width * channels + 1))
        for _ in 0..<height {
            result.append(0)
            result.append(Data(repeating: 0, count: width * channels))
        }
        return result
    }

    static func solidScanlines(_ rgb: [UInt8], width: Int = 256, height: Int = 256) -> Data {
        precondition(rgb.count == 3)
        var result = Data(capacity: height * (width * 3 + 1))
        for _ in 0..<height {
            result.append(0)
            for _ in 0..<width { result.append(contentsOf: rgb) }
        }
        return result
    }

    static func gamma() -> Data { chunk("gAMA", word(45_455)) }

    static func chromaticities() -> Data {
        var values = Data()
        for value: UInt32 in [31_270, 32_900, 64_000, 33_000, 30_000, 60_000, 15_000, 6_000] {
            values.append(word(value))
        }
        return chunk("cHRM", values)
    }

    static func orientation(_ value: UInt16) -> Data {
        var data = Data([0x4d, 0x4d, 0x00, 0x2a, 0, 0, 0, 8, 0, 1])
        data.append(contentsOf: [0x01, 0x12, 0, 3, 0, 0, 0, 1,
                                 UInt8(value >> 8), UInt8(value & 255), 0, 0,
                                 0, 0, 0, 0])
        return data
    }

    static func imageIOEncodedPNG() throws -> Data {
        var rgba = [UInt8](repeating: 255, count: 256 * 256 * 4)
        for pixel in 0..<(256 * 256) {
            rgba[pixel * 4] = 12
            rgba[pixel * 4 + 1] = 34
            rgba[pixel * 4 + 2] = 56
        }
        let provider = try #require(CGDataProvider(data: Data(rgba) as CFData))
        let image = try #require(CGImage(
            width: 256, height: 256, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 256 * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    static func compress(_ input: Data) throws -> Data {
        var capacity = compressBound(uLong(input.count))
        var output = Data(count: Int(capacity))
        let status: Int32 = input.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { target in
                compress2(target.bindMemory(to: UInt8.self).baseAddress, &capacity,
                          source.bindMemory(to: UInt8.self).baseAddress,
                          uLong(input.count), Z_BEST_SPEED)
            }
        }
        guard status == Z_OK else { throw FixtureError.compression }
        output.count = Int(capacity)
        return output
    }

    static func chunk(_ type: String, _ payload: Data) -> Data {
        let name = Data(type.utf8)
        var crc: uLong = zlib.crc32(0, nil, 0)
        name.withUnsafeBytes { crc = zlib.crc32(crc, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count)) }
        payload.withUnsafeBytes { crc = zlib.crc32(crc, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count)) }
        var result = word(UInt32(payload.count))
        result.append(name)
        result.append(payload)
        result.append(word(UInt32(crc)))
        return result
    }

    static func word(_ value: UInt32) -> Data {
        Data([UInt8((value >> 24) & 255), UInt8((value >> 16) & 255),
              UInt8((value >> 8) & 255), UInt8(value & 255)])
    }

    enum FixtureError: Error { case compression }
}
