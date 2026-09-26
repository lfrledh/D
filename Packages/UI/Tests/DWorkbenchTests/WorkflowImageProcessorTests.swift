import CoreGraphics
import CryptoKit
import DWorkbench
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@Suite("Workflow image processor")
struct WorkflowImageProcessorTests {
    @Test func transparentPNGConvertsToExplicitWhiteAndBlackJPEGBackgrounds() throws {
        let source = try ImageFixture.png(width: 64, height: 32) { x, _ in
            x < 32 ? (0, 0, 0, 0) : (220, 40, 20, 255)
        }

        let white = try WorkflowImageProcessor.process(
            source, operationID: "d.image.convert",
            parameters: ["format": .text("jpeg"), "quality": .decimal(1),
                         "background": .text("white")])
        let black = try WorkflowImageProcessor.process(
            source, operationID: "d.image.convert",
            parameters: ["format": .text("jpeg"), "quality": .decimal(1),
                         "background": .text("black")])

        #expect(white.mediaType == "image/jpeg")
        #expect(white.metadata.width == 64)
        #expect(white.metadata.height == 32)
        #expect(white.details["backgroundPolicy"] == "white")
        #expect(white.details["alpha"] == "removed")
        let whitePixel = try ImageFixture.pixel(white.data, x: 8, y: 16)
        #expect(whitePixel.red >= 240 && whitePixel.green >= 240 && whitePixel.blue >= 240)

        #expect(black.details["backgroundPolicy"] == "black")
        let blackPixel = try ImageFixture.pixel(black.data, x: 8, y: 16)
        #expect(blackPixel.red <= 15 && blackPixel.green <= 15 && blackPixel.blue <= 15)
    }

    @Test func PNGConversionPreservesAlphaAndNormalizedMetadata() throws {
        let source = try ImageFixture.png(width: 8, height: 8) { x, _ in
            x < 4 ? (0, 0, 0, 0) : (20, 100, 180, 255)
        }
        let result = try WorkflowImageProcessor.process(
            source, operationID: "d.image.convert", parameters: ["format": .text("png")])

        #expect(result.mediaType == "image/png")
        #expect(result.metadata == MediaMetadata(width: 8, height: 8, bitDepth: 8,
                                                 colorSpace: "sRGB"))
        #expect(result.details["originalFormat"] == "png")
        #expect(result.details["outputEncoding"] == "png")
        #expect(result.details["alpha"] == "preserved")
        #expect(try ImageFixture.pixel(result.data, x: 1, y: 4).alpha == 0)
        #expect(try ImageFixture.pixel(result.data, x: 6, y: 4).alpha == 255)
    }

    @Test func resizeFitCentersOnTransparentCanvas() throws {
        let source = try ImageFixture.png(width: 4, height: 2) { _, _ in (30, 200, 60, 255) }
        let result = try WorkflowImageProcessor.process(
            source, operationID: "d.image.resize",
            parameters: ["width": .integer(8), "height": .integer(8), "mode": .text("fit")])

        #expect(result.metadata.width == 8)
        #expect(result.metadata.height == 8)
        #expect(result.mediaType == "image/png")
        #expect(result.details["scalePolicy"] == "fit")
        #expect(result.details["backgroundPolicy"] == "transparent-canvas")
        #expect(try ImageFixture.pixel(result.data, x: 4, y: 0).alpha == 0)
        #expect(try ImageFixture.pixel(result.data, x: 4, y: 4).alpha >= 250)
    }

    @Test func resizeFillCropsAndCoversTheTarget() throws {
        let source = try ImageFixture.png(width: 8, height: 4) { x, _ in
            x < 4 ? (230, 20, 20, 255) : (20, 40, 230, 255)
        }
        let result = try WorkflowImageProcessor.process(
            source, operationID: "d.image.resize",
            parameters: ["width": .integer(4), "height": .integer(4), "mode": .text("fill")])

        #expect(result.metadata.width == 4)
        #expect(result.metadata.height == 4)
        #expect(result.details["scalePolicy"] == "fill")
        #expect(try ImageFixture.pixel(result.data, x: 0, y: 2).red > 150)
        #expect(try ImageFixture.pixel(result.data, x: 3, y: 2).blue > 150)
        #expect(try ImageFixture.pixel(result.data, x: 0, y: 0).alpha == 255)
    }

    @Test func resizeStretchUsesTheExactRequestedGeometry() throws {
        let source = try ImageFixture.png(width: 3, height: 2) { _, _ in (80, 120, 160, 255) }
        let result = try WorkflowImageProcessor.process(
            source, operationID: "d.image.resize",
            parameters: ["width": .integer(7), "height": .integer(5), "mode": .text("stretch")])

        #expect(result.metadata.width == 7)
        #expect(result.metadata.height == 5)
        #expect(result.details["scalePolicy"] == "stretch")
        #expect(try ImageFixture.dimensions(result.data) == ImageFixture.Size(width: 7, height: 5))
    }

    @Test func EXIFOrientationIsAppliedAndRemovedFromTheOutputGeometry() throws {
        let source = try ImageFixture.jpeg(width: 20, height: 30, orientation: 6) { x, _ in
            x < 10 ? (200, 30, 20, 255) : (20, 40, 200, 255)
        }
        let result = try WorkflowImageProcessor.process(
            source, operationID: "d.image.convert", parameters: ["format": .text("png")])

        #expect(result.metadata.width == 30)
        #expect(result.metadata.height == 20)
        #expect(result.details["originalOrientation"] == "6")
        #expect(try ImageFixture.dimensions(result.data) == ImageFixture.Size(width: 30, height: 20))
    }

    @Test func processingNeverMutatesTheSourceData() throws {
        let source = try ImageFixture.png(width: 9, height: 7) { x, y in
            (UInt8(x * 11), UInt8(y * 17), 90, 255)
        }
        let snapshot = source
        let digest = SHA256.hash(data: source)

        _ = try WorkflowImageProcessor.process(
            source, operationID: "d.image.resize",
            parameters: ["width": .integer(13), "height": .integer(11), "mode": .text("stretch")])

        #expect(source == snapshot)
        #expect(SHA256.hash(data: source) == digest)
    }

    @Test func damagedUnsupportedAndOversizedInputsAreRejectedBeforePublication() throws {
        let damaged = Data([137, 80, 78, 71, 13, 10, 26, 10, 0])
        #expect(throws: WorkflowImageProcessorError.corruptImage) {
            try WorkflowImageProcessor.process(
                damaged, operationID: "d.image.convert", parameters: ["format": .text("png")])
        }

        let unsupported = Data("not an image — 路径无关".utf8)
        #expect(throws: WorkflowImageProcessorError.unsupportedFormat) {
            try WorkflowImageProcessor.process(
                unsupported, operationID: "d.image.convert", parameters: ["format": .text("png")])
        }

        let oversizedBytes = Data(count: 64 * 1_024 * 1_024 + 1)
        #expect(throws: WorkflowImageProcessorError.inputTooLarge) {
            try WorkflowImageProcessor.process(
                oversizedBytes, operationID: "d.image.convert", parameters: ["format": .text("png")])
        }
    }

    @Test func disablingJPEGRejectsJPEGWithoutChangingPNGProcessing() throws {
        let pngCodec = try #require(ImageCodecRegistry.standard.codec(formatID: "png"))
        let pngOnly = try ImageCodecRegistry(codecs: [pngCodec])
        let png = try ImageFixture.png(width: 5, height: 3) { _, _ in (20, 40, 60, 255) }
        let pngResult = try WorkflowImageProcessor.process(
            png,
            operationID: "d.image.convert",
            parameters: ["format": .text("png")],
            codecs: pngOnly)

        #expect(pngResult.mediaType == "image/png")
        #expect(pngResult.metadata.width == 5)
        #expect(pngResult.metadata.height == 3)

        let jpeg = try ImageFixture.jpeg(width: 5, height: 3, orientation: 1) {
            _, _ in (20, 40, 60, 255)
        }
        #expect(throws: WorkflowImageProcessorError.unsupportedFormat) {
            try WorkflowImageProcessor.process(
                jpeg,
                operationID: "d.image.convert",
                parameters: ["format": .text("png")],
                codecs: pngOnly)
        }
        #expect(throws: WorkflowImageProcessorError.unsupportedFormat) {
            try WorkflowImageProcessor.process(
                png,
                operationID: "d.image.convert",
                parameters: ["format": .text("jpeg"), "quality": .decimal(0.8),
                             "background": .text("white")],
                codecs: pngOnly)
        }
    }

    @Test func injectedFixtureCodecRunsThroughTheProcessorWithoutAddingAProductionFormat() throws {
        let pngCodec = try #require(ImageCodecRegistry.standard.codec(formatID: "png"))
        let fixtureCodec = PNGFixtureCodec(base: pngCodec)
        let registry = try ImageCodecRegistry(codecs: [fixtureCodec])
        let source = try ImageFixture.png(width: 6, height: 4) { _, _ in (70, 80, 90, 255) }

        let result = try WorkflowImageProcessor.process(
            source,
            operationID: "d.image.convert",
            parameters: ["format": .text("fixture-png")],
            codecs: registry)

        #expect(result.mediaType == "image/png")
        #expect(result.details["originalFormat"] == "fixture-png")
        #expect(result.details["outputEncoding"] == "fixture-png")
        #expect(result.metadata.width == 6)
        #expect(result.metadata.height == 4)
    }

    @Test func ambiguousInjectedSignaturesAreRejectedBeforeDecode() throws {
        let pngCodec = try #require(ImageCodecRegistry.standard.codec(formatID: "png"))
        let codecs: [any ImageCodec] = [
            PNGFixtureCodec(base: pngCodec),
            AmbiguousPNGFixtureCodec(),
        ]
        let registry = try ImageCodecRegistry(codecs: codecs)
        let source = try ImageFixture.png(width: 2, height: 2) { _, _ in (1, 2, 3, 255) }

        #expect(throws: WorkflowImageProcessorError.ambiguousFormat) {
            try WorkflowImageProcessor.process(
                source,
                operationID: "d.image.convert",
                parameters: ["format": .text("fixture-png")],
                codecs: registry)
        }
    }

    @Test func registeredFixtureCodecStillRejectsMultipleFrames() throws {
        let tiff = try ImageFixture.multiFrameTIFF()
        var codecs: [any ImageCodec] = ImageCodecRegistry.standard.formatIDs.compactMap {
            ImageCodecRegistry.standard.codec(formatID: $0)
        }
        codecs.append(TIFFFixtureCodec())
        let registry = try ImageCodecRegistry(codecs: codecs)

        #expect(throws: WorkflowImageProcessorError.multipleImages) {
            try WorkflowImageProcessor.process(
                tiff,
                operationID: "d.image.convert",
                parameters: ["format": .text("png")],
                codecs: registry)
        }
    }

    @Test func dimensionsAreRejectedFromPropertiesBeforePixelDecode() throws {
        let source = try ImageFixture.png(width: 8_193, height: 1) { _, _ in (1, 2, 3, 255) }
        #expect(throws: WorkflowImageProcessorError.invalidDimensions) {
            try WorkflowImageProcessor.process(
                source, operationID: "d.image.convert", parameters: ["format": .text("png")])
        }
    }

    @Test func invalidOrImplicitParametersAreRejected() throws {
        let source = try ImageFixture.png(width: 4, height: 4) { _, _ in (1, 2, 3, 255) }
        let invalidResizeParameters: [[String: WorkflowScalar]] = [
            ["width": .integer(0), "height": .integer(4), "mode": .text("fit")],
            ["width": .integer(8_192), "height": .integer(4_097), "mode": .text("fit")],
            ["width": .integer(4), "height": .integer(4), "mode": .text("nearest")],
            ["width": .integer(4), "height": .integer(4), "mode": .text("fit"),
             "surprise": .flag(true)],
        ]
        for parameters in invalidResizeParameters {
            #expect(throws: WorkflowImageProcessorError.self) {
                try WorkflowImageProcessor.process(
                    source, operationID: "d.image.resize", parameters: parameters)
            }
        }

        let invalidJPEGParameters: [[String: WorkflowScalar]] = [
            ["format": .text("jpeg"), "background": .text("white")],
            ["format": .text("jpeg"), "quality": .decimal(1.1), "background": .text("white")],
            ["format": .text("jpeg"), "quality": .decimal(0.8), "background": .text("transparent")],
        ]
        for parameters in invalidJPEGParameters {
            #expect(throws: WorkflowImageProcessorError.self) {
                try WorkflowImageProcessor.process(
                    source, operationID: "d.image.convert", parameters: parameters)
            }
        }

        #expect(throws: WorkflowImageProcessorError.unsupportedOperation("d.image.upscale")) {
            try WorkflowImageProcessor.process(
                source, operationID: "d.image.upscale", parameters: [:])
        }
    }
}

private enum ImageFixture {
    struct Size: Equatable {
        let width: Int
        let height: Int
    }

    struct Pixel {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
        let alpha: UInt8
    }

    enum FixtureError: Error {
        case imageCreation
        case encoding
        case decoding
    }

    static func png(width: Int, height: Int,
                    pixels: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) throws -> Data {
        try encode(image(width: width, height: height, pixels: pixels), type: .png,
                   orientation: nil)
    }

    static func jpeg(width: Int, height: Int, orientation: Int,
                     pixels: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) throws -> Data {
        try encode(image(width: width, height: height, pixels: pixels), type: .jpeg,
                   orientation: orientation)
    }

    static func multiFrameTIFF() throws -> Data {
        let first = try image(width: 3, height: 2) { _, _ in (10, 20, 30, 255) }
        let second = try image(width: 3, height: 2) { _, _ in (40, 50, 60, 255) }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.tiff.identifier as CFString, 2, nil) else {
            throw FixtureError.encoding
        }
        CGImageDestinationAddImage(destination, first, nil)
        CGImageDestinationAddImage(destination, second, nil)
        guard CGImageDestinationFinalize(destination) else { throw FixtureError.encoding }
        return output as Data
    }

    static func image(width: Int, height: Int,
                      pixels: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) throws -> CGImage {
        var bytes = [UInt8]()
        bytes.reserveCapacity(width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let pixel = pixels(x, y)
                bytes.append(pixel.0)
                bytes.append(pixel.1)
                bytes.append(pixel.2)
                bytes.append(pixel.3)
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue
                    | CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false,
                intent: .defaultIntent) else {
            throw FixtureError.imageCreation
        }
        return image
    }

    static func encode(_ image: CGImage, type: UTType, orientation: Int?) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, type.identifier as CFString, 1, nil) else {
            throw FixtureError.encoding
        }
        var properties: [CFString: Any] = [:]
        if let orientation { properties[kCGImagePropertyOrientation] = orientation }
        if type == .jpeg { properties[kCGImageDestinationLossyCompressionQuality] = 1.0 }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw FixtureError.encoding }
        return output as Data
    }

    static func dimensions(_ data: Data) throws -> Size {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = (properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue else {
            throw FixtureError.decoding
        }
        return Size(width: width, height: height)
    }

    static func pixel(_ data: Data, x: Int, y: Int) throws -> Pixel {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              x >= 0, y >= 0, x < image.width, y < image.height,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw FixtureError.decoding
        }
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        let rendered = bytes.withUnsafeMutableBytes { storage -> Bool in
            guard let baseAddress = storage.baseAddress,
                  let context = CGContext(data: baseAddress, width: image.width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                          space: colorSpace, bitmapInfo: bitmapInfo) else {
                return false
            }
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0,
                                          width: image.width, height: image.height))
            return true
        }
        guard rendered else { throw FixtureError.decoding }
        let offset = (y * image.width + x) * 4
        return Pixel(red: bytes[offset], green: bytes[offset + 1],
                     blue: bytes[offset + 2], alpha: bytes[offset + 3])
    }
}

private struct TIFFFixtureCodec: ImageCodec {
    let formatID = "fixture-tiff"
    let mediaType = "image/tiff"
    let typeIdentifier = UTType.tiff.identifier
    let alphaPolicy = ImageCodecAlphaPolicy.preserve

    func matchesSignature(_ data: Data) -> Bool {
        data.starts(with: [0x49, 0x49, 0x2a, 0x00])
            || data.starts(with: [0x4d, 0x4d, 0x00, 0x2a])
    }

    func encodingOptions(
        quality: WorkflowScalar?,
        background: WorkflowScalar?
    ) throws -> ImageCodecEncodingOptions {
        ImageCodecEncodingOptions(quality: nil, background: nil)
    }

    func encode(_ image: CGImage, options: ImageCodecEncodingOptions) throws -> Data {
        throw TIFFFixtureError.encodingIsNotPartOfThisFixture
    }

    private enum TIFFFixtureError: Error {
        case encodingIsNotPartOfThisFixture
    }
}

private struct PNGFixtureCodec: ImageCodec {
    let formatID = "fixture-png"
    let base: any ImageCodec

    var mediaType: String { base.mediaType }
    var typeIdentifier: String { base.typeIdentifier }
    var alphaPolicy: ImageCodecAlphaPolicy { base.alphaPolicy }

    func matchesSignature(_ data: Data) -> Bool {
        base.matchesSignature(data)
    }

    func encodingOptions(
        quality: WorkflowScalar?,
        background: WorkflowScalar?
    ) throws -> ImageCodecEncodingOptions {
        try base.encodingOptions(quality: quality, background: background)
    }

    func encode(_ image: CGImage, options: ImageCodecEncodingOptions) throws -> Data {
        try base.encode(image, options: options)
    }
}

private struct AmbiguousPNGFixtureCodec: ImageCodec {
    let formatID = "fixture-png-conflict"
    let mediaType = "application/x-fixture-png-conflict"
    let typeIdentifier = "org.example.fixture-png-conflict"
    let alphaPolicy = ImageCodecAlphaPolicy.preserve

    func matchesSignature(_ data: Data) -> Bool {
        data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10])
    }

    func encodingOptions(
        quality: WorkflowScalar?,
        background: WorkflowScalar?
    ) throws -> ImageCodecEncodingOptions {
        ImageCodecEncodingOptions(quality: nil, background: nil)
    }

    func encode(_ image: CGImage, options: ImageCodecEncodingOptions) throws -> Data {
        throw AmbiguousFixtureError.encodingIsNotPartOfThisFixture
    }

    private enum AmbiguousFixtureError: Error {
        case encodingIsNotPartOfThisFixture
    }
}
