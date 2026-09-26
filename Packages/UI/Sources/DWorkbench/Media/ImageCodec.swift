import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageCodecAlphaPolicy: Sendable, Equatable {
    case preserve
    case remove
}

public enum ImageCodecBackground: String, Sendable, Equatable {
    case white
    case black
}

public struct ImageCodecEncodingOptions: Sendable, Equatable {
    public let quality: Double?
    public let background: ImageCodecBackground?

    public init(quality: Double?, background: ImageCodecBackground?) {
        self.quality = quality
        self.background = background
    }
}

public protocol ImageCodec: Sendable {
    var formatID: String { get }
    var mediaType: String { get }
    var typeIdentifier: String { get }
    var alphaPolicy: ImageCodecAlphaPolicy { get }

    func matchesSignature(_ data: Data) -> Bool
    func encodingOptions(
        quality: WorkflowScalar?,
        background: WorkflowScalar?
    ) throws -> ImageCodecEncodingOptions
    func encode(_ image: CGImage, options: ImageCodecEncodingOptions) throws -> Data
}

struct PNGImageCodec: ImageCodec {
    let formatID = "png"
    let mediaType = "image/png"
    let typeIdentifier = UTType.png.identifier
    let alphaPolicy = ImageCodecAlphaPolicy.preserve

    func matchesSignature(_ data: Data) -> Bool {
        data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10])
    }

    func encodingOptions(
        quality: WorkflowScalar?,
        background: WorkflowScalar?
    ) throws -> ImageCodecEncodingOptions {
        if let quality {
            guard let value = quality.decimal, value.isFinite, (0...1).contains(value) else {
                throw WorkflowImageProcessorError.invalidParameters(
                    "quality 必须为 0...1 的有限小数。")
            }
        }
        if let background {
            guard let value = background.string,
                  ImageCodecBackground(rawValue: value) != nil else {
                throw WorkflowImageProcessorError.invalidParameters(
                    "background 必须为 white 或 black。")
            }
        }
        return ImageCodecEncodingOptions(quality: nil, background: nil)
    }

    func encode(_ image: CGImage, options: ImageCodecEncodingOptions) throws -> Data {
        try encodeImage(image, typeIdentifier: typeIdentifier, quality: nil)
    }
}

struct JPEGImageCodec: ImageCodec {
    let formatID = "jpeg"
    let mediaType = "image/jpeg"
    let typeIdentifier = UTType.jpeg.identifier
    let alphaPolicy = ImageCodecAlphaPolicy.remove

    func matchesSignature(_ data: Data) -> Bool {
        guard data.count >= 3 else { return false }
        return data[data.startIndex] == 0xff
            && data[data.index(after: data.startIndex)] == 0xd8
            && data[data.index(data.startIndex, offsetBy: 2)] == 0xff
    }

    func encodingOptions(
        quality: WorkflowScalar?,
        background: WorkflowScalar?
    ) throws -> ImageCodecEncodingOptions {
        guard let quality = quality?.decimal,
              quality.isFinite, (0...1).contains(quality) else {
            throw WorkflowImageProcessorError.invalidParameters(
                "JPEG quality 必须为 0...1 的有限小数。")
        }
        guard let backgroundValue = background?.string,
              let background = ImageCodecBackground(rawValue: backgroundValue) else {
            throw WorkflowImageProcessorError.invalidParameters(
                "JPEG background 必须显式为 white 或 black。")
        }
        return ImageCodecEncodingOptions(quality: quality, background: background)
    }

    func encode(_ image: CGImage, options: ImageCodecEncodingOptions) throws -> Data {
        guard let quality = options.quality,
              quality.isFinite, (0...1).contains(quality) else {
            throw WorkflowImageProcessorError.invalidParameters(
                "JPEG quality 必须为 0...1 的有限小数。")
        }
        guard let background = options.background else {
            throw WorkflowImageProcessorError.invalidParameters("JPEG 必须指定背景。")
        }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw WorkflowImageProcessorError.encodeFailed
        }
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.noneSkipLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw WorkflowImageProcessorError.encodeFailed
        }
        let component: CGFloat = background == .white ? 1 : 0
        context.setFillColor(CGColor(
            srgbRed: component,
            green: component,
            blue: component,
            alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.interpolationQuality = .none
        context.setBlendMode(.normal)
        context.draw(image, in: CGRect(x: 0, y: 0,
                                      width: image.width, height: image.height))
        guard let flattened = context.makeImage() else {
            throw WorkflowImageProcessorError.encodeFailed
        }
        return try encodeImage(
            flattened,
            typeIdentifier: typeIdentifier,
            quality: quality)
    }
}

private func encodeImage(
    _ image: CGImage,
    typeIdentifier: String,
    quality: Double?
) throws -> Data {
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
        output, typeIdentifier as CFString, 1, nil) else {
        throw WorkflowImageProcessorError.encodeFailed
    }
    let properties: CFDictionary?
    if let quality {
        properties = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
    } else {
        properties = nil
    }
    CGImageDestinationAddImage(destination, image, properties)
    guard CGImageDestinationFinalize(destination) else {
        throw WorkflowImageProcessorError.encodeFailed
    }
    return output as Data
}
