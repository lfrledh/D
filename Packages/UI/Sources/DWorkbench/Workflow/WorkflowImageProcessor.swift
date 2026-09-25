import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct WorkflowImageProduct: Sendable, Equatable {
    public let data: Data
    public let mediaType: String
    public let metadata: MediaMetadata
    public let details: [String: String]

    public init(data: Data, mediaType: String, metadata: MediaMetadata,
                details: [String: String]) {
        self.data = data
        self.mediaType = mediaType
        self.metadata = metadata
        self.details = details
    }
}

public enum WorkflowImageProcessorError: Error, LocalizedError, Sendable, Equatable {
    case unsupportedOperation(String)
    case invalidParameters(String)
    case inputTooLarge
    case unsupportedFormat
    case corruptImage
    case multipleImages
    case invalidDimensions
    case decodeFailed
    case encodeFailed
    case outputVerificationFailed

    public var errorDescription: String? {
        switch self {
        case .unsupportedOperation(let id): "不支持的图片操作：\(id)"
        case .invalidParameters(let reason): "图片操作参数无效：\(reason)"
        case .inputTooLarge: "图片数据超过 64 MiB 限制。"
        case .unsupportedFormat: "仅支持普通单帧 PNG 或 JPEG 图片。"
        case .corruptImage: "图片已损坏或数据不完整。"
        case .multipleImages: "不支持多页或多帧图片。"
        case .invalidDimensions: "图片尺寸须为正数，单边不超过 8192，且总像素不超过 32 Mi。"
        case .decodeFailed: "图片像素无法完整解码。"
        case .encodeFailed: "图片无法编码。"
        case .outputVerificationFailed: "编码后的图片格式或尺寸校验失败。"
        }
    }
}

public enum WorkflowImageProcessor {
    private static let maximumInputBytes = 64 * 1_024 * 1_024
    private static let maximumSide = 8_192
    private static let maximumPixels = 32 * 1_024 * 1_024

    public static func process(_ data: Data, operationID: String,
                               parameters: [String: WorkflowScalar]) throws -> WorkflowImageProduct {
        switch operationID {
        case "d.image.resize":
            return try resize(decode(data), parameters: parameters)
        case "d.image.convert":
            return try convert(decode(data), parameters: parameters)
        default:
            throw WorkflowImageProcessorError.unsupportedOperation(operationID)
        }
    }
}

private extension WorkflowImageProcessor {
    enum EncodedFormat: String {
        case png
        case jpeg

        var mediaType: String {
            switch self {
            case .png: "image/png"
            case .jpeg: "image/jpeg"
            }
        }

        var typeIdentifier: CFString {
            switch self {
            case .png: UTType.png.identifier as CFString
            case .jpeg: UTType.jpeg.identifier as CFString
            }
        }
    }

    enum ResizeMode: String {
        case fit
        case fill
        case stretch
    }

    struct DecodedImage {
        let image: CGImage
        let format: EncodedFormat
        let originalOrientation: String
        let originalColorSpace: String
        let hadAlpha: Bool
    }

    struct EncodedInspection {
        let format: EncodedFormat
        let width: Int
        let height: Int
        let bitDepth: Int?
    }

    static func decode(_ data: Data) throws -> DecodedImage {
        guard data.count <= maximumInputBytes else {
            throw WorkflowImageProcessorError.inputTooLarge
        }
        let detectedFormat = try detectFormat(data)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw WorkflowImageProcessorError.corruptImage
        }
        let count = CGImageSourceGetCount(source)
        guard count == 1 else {
            if count > 1 { throw WorkflowImageProcessorError.multipleImages }
            throw WorkflowImageProcessorError.corruptImage
        }
        guard CGImageSourceGetStatus(source) == .statusComplete else {
            throw WorkflowImageProcessorError.corruptImage
        }
        guard let actualType = CGImageSourceGetType(source),
              actualType as String == detectedFormat.typeIdentifier as String else {
            throw WorkflowImageProcessorError.unsupportedFormat
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = integerProperty(properties[kCGImagePropertyPixelWidth as String]),
              let height = integerProperty(properties[kCGImagePropertyPixelHeight as String]) else {
            throw WorkflowImageProcessorError.corruptImage
        }
        try validateDimensions(width: width, height: height)

        let rawOrientation = integerProperty(properties[kCGImagePropertyOrientation as String])
        if let rawOrientation, !(1...8).contains(rawOrientation) {
            throw WorkflowImageProcessorError.corruptImage
        }
        let expectedWidth = (rawOrientation ?? 1) >= 5 ? height : width
        let expectedHeight = (rawOrientation ?? 1) >= 5 ? width : height
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let oriented = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              oriented.width == expectedWidth, oriented.height == expectedHeight else {
            throw WorkflowImageProcessorError.decodeFailed
        }
        let originalColorSpace = colorSpaceName(properties: properties, image: oriented)
        let originalAlpha = hasAlpha(oriented)
        let normalized = try render(width: expectedWidth, height: expectedHeight) { context in
            context.interpolationQuality = .high
            context.setBlendMode(.copy)
            context.draw(oriented, in: CGRect(x: 0, y: 0,
                                              width: expectedWidth, height: expectedHeight))
        }
        return DecodedImage(image: normalized, format: detectedFormat,
                            originalOrientation: rawOrientation.map { String($0) } ?? "unknown",
                            originalColorSpace: originalColorSpace, hadAlpha: originalAlpha)
    }

    static func resize(_ input: DecodedImage,
                       parameters: [String: WorkflowScalar]) throws -> WorkflowImageProduct {
        try rejectUnknownParameters(parameters, allowed: ["width", "height", "mode"])
        guard let width = parameters["width"]?.integer,
              let height = parameters["height"]?.integer,
              let modeValue = parameters["mode"]?.string,
              let mode = ResizeMode(rawValue: modeValue) else {
            throw WorkflowImageProcessorError.invalidParameters("resize 需要整数 width/height 和 fit、fill 或 stretch 模式。")
        }
        do {
            try validateDimensions(width: width, height: height)
        } catch {
            throw WorkflowImageProcessorError.invalidParameters("width/height 超出允许范围。")
        }

        let sourceWidth = CGFloat(input.image.width)
        let sourceHeight = CGFloat(input.image.height)
        let targetWidth = CGFloat(width)
        let targetHeight = CGFloat(height)
        let drawRect: CGRect
        let scaleDescription: String
        switch mode {
        case .stretch:
            drawRect = CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight)
            scaleDescription = "stretch"
        case .fit, .fill:
            let widthScale = targetWidth / sourceWidth
            let heightScale = targetHeight / sourceHeight
            let scale = mode == .fit ? min(widthScale, heightScale) : max(widthScale, heightScale)
            let scaledWidth = sourceWidth * scale
            let scaledHeight = sourceHeight * scale
            drawRect = CGRect(x: (targetWidth - scaledWidth) / 2,
                              y: (targetHeight - scaledHeight) / 2,
                              width: scaledWidth, height: scaledHeight)
            scaleDescription = String(Double(scale))
        }
        let resized = try render(width: width, height: height) { context in
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
            context.interpolationQuality = .high
            context.setBlendMode(.normal)
            context.draw(input.image, in: drawRect)
        }
        let encoded = try encode(resized, format: .png, quality: nil, background: nil)
        let inspection = try verify(encoded, expectedFormat: .png,
                                    expectedWidth: width, expectedHeight: height)
        var details = commonDetails(input: input, output: .png)
        details["alpha"] = input.hadAlpha ? "preserved" : (mode == .fit ? "transparent-canvas" : "opaque")
        details["scalePolicy"] = mode.rawValue
        details["scale"] = scaleDescription
        details["backgroundPolicy"] = mode == .fit ? "transparent-canvas" : "none"
        return product(encoded, inspection: inspection, details: details)
    }

    static func convert(_ input: DecodedImage,
                        parameters: [String: WorkflowScalar]) throws -> WorkflowImageProduct {
        try rejectUnknownParameters(parameters, allowed: ["format", "quality", "background"])
        guard let formatValue = parameters["format"]?.string,
              let format = EncodedFormat(rawValue: formatValue) else {
            throw WorkflowImageProcessorError.invalidParameters("format 必须为 png 或 jpeg。")
        }

        let quality: Double?
        let background: String?
        if format == .jpeg {
            guard let suppliedQuality = parameters["quality"]?.decimal,
                  suppliedQuality.isFinite, (0...1).contains(suppliedQuality) else {
                throw WorkflowImageProcessorError.invalidParameters("JPEG quality 必须为 0...1 的有限小数。")
            }
            guard let suppliedBackground = parameters["background"]?.string,
                  suppliedBackground == "white" || suppliedBackground == "black" else {
                throw WorkflowImageProcessorError.invalidParameters("JPEG background 必须显式为 white 或 black。")
            }
            quality = suppliedQuality
            background = suppliedBackground
        } else {
            if let suppliedQuality = parameters["quality"] {
                guard let value = suppliedQuality.decimal, value.isFinite, (0...1).contains(value) else {
                    throw WorkflowImageProcessorError.invalidParameters("quality 必须为 0...1 的有限小数。")
                }
            }
            if let suppliedBackground = parameters["background"] {
                guard let value = suppliedBackground.string, value == "white" || value == "black" else {
                    throw WorkflowImageProcessorError.invalidParameters("background 必须为 white 或 black。")
                }
            }
            quality = nil
            background = nil
        }

        let encoded = try encode(input.image, format: format,
                                 quality: quality, background: background)
        let inspection = try verify(encoded, expectedFormat: format,
                                    expectedWidth: input.image.width,
                                    expectedHeight: input.image.height)
        var details = commonDetails(input: input, output: format)
        details["alpha"] = format == .png ? (input.hadAlpha ? "preserved" : "opaque") : "removed"
        details["scalePolicy"] = "unchanged"
        details["backgroundPolicy"] = background ?? (format == .png ? "preserve-alpha" : "unknown")
        details["quality"] = quality.map { String($0) } ?? "not-applicable"
        return product(encoded, inspection: inspection, details: details)
    }

    static func detectFormat(_ data: Data) throws -> EncodedFormat {
        let pngSignature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        if data.starts(with: pngSignature) { return .png }
        if data.count >= 3, data[data.startIndex] == 0xff,
           data[data.index(after: data.startIndex)] == 0xd8,
           data[data.index(data.startIndex, offsetBy: 2)] == 0xff {
            return .jpeg
        }
        throw WorkflowImageProcessorError.unsupportedFormat
    }

    static func validateDimensions(width: Int, height: Int) throws {
        guard width > 0, height > 0, width <= maximumSide, height <= maximumSide else {
            throw WorkflowImageProcessorError.invalidDimensions
        }
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixels <= maximumPixels else {
            throw WorkflowImageProcessorError.invalidDimensions
        }
    }

    static func rejectUnknownParameters(_ parameters: [String: WorkflowScalar],
                                        allowed: Set<String>) throws {
        let unknown = Set(parameters.keys).subtracting(allowed)
        guard unknown.isEmpty else {
            throw WorkflowImageProcessorError.invalidParameters(
                "包含未知字段：\(unknown.sorted().joined(separator: ", "))")
        }
    }

    static func integerProperty(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    static func colorSpaceName(properties: [String: Any], image: CGImage) -> String {
        if let profile = properties[kCGImagePropertyProfileName as String] as? String,
           !profile.isEmpty {
            return profile
        }
        if let name = image.colorSpace?.name { return name as String }
        return "unknown"
    }

    static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly: true
        case .none, .noneSkipFirst, .noneSkipLast: false
        @unknown default: false
        }
    }

    static func render(width: Int, height: Int,
                       drawing: (CGContext) -> Void) throws -> CGImage {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw WorkflowImageProcessorError.decodeFailed
        }
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: colorSpace, bitmapInfo: bitmapInfo) else {
            throw WorkflowImageProcessorError.decodeFailed
        }
        drawing(context)
        guard let image = context.makeImage() else {
            throw WorkflowImageProcessorError.decodeFailed
        }
        return image
    }

    static func encode(_ image: CGImage, format: EncodedFormat,
                       quality: Double?, background: String?) throws -> Data {
        let imageToEncode: CGImage
        if format == .jpeg {
            guard let background else {
                throw WorkflowImageProcessorError.invalidParameters("JPEG 必须指定背景。")
            }
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
                throw WorkflowImageProcessorError.encodeFailed
            }
            let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
                | CGImageAlphaInfo.noneSkipLast.rawValue
            guard let context = CGContext(data: nil, width: image.width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                          space: colorSpace, bitmapInfo: bitmapInfo) else {
                throw WorkflowImageProcessorError.encodeFailed
            }
            let component: CGFloat = background == "white" ? 1 : 0
            context.setFillColor(CGColor(srgbRed: component, green: component,
                                         blue: component, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            context.interpolationQuality = .none
            context.setBlendMode(.normal)
            context.draw(image, in: CGRect(x: 0, y: 0,
                                          width: image.width, height: image.height))
            guard let flattened = context.makeImage() else {
                throw WorkflowImageProcessorError.encodeFailed
            }
            imageToEncode = flattened
        } else {
            imageToEncode = image
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, format.typeIdentifier, 1, nil) else {
            throw WorkflowImageProcessorError.encodeFailed
        }
        let properties: CFDictionary?
        if let quality {
            properties = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        } else {
            properties = nil
        }
        CGImageDestinationAddImage(destination, imageToEncode, properties)
        guard CGImageDestinationFinalize(destination) else {
            throw WorkflowImageProcessorError.encodeFailed
        }
        return output as Data
    }

    static func verify(_ data: Data, expectedFormat: EncodedFormat,
                       expectedWidth: Int, expectedHeight: Int) throws -> EncodedInspection {
        guard (try? detectFormat(data)) == expectedFormat,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetStatus(source) == .statusComplete,
              let actualType = CGImageSourceGetType(source),
              actualType as String == expectedFormat.typeIdentifier as String,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = integerProperty(properties[kCGImagePropertyPixelWidth as String]),
              let height = integerProperty(properties[kCGImagePropertyPixelHeight as String]),
              width == expectedWidth, height == expectedHeight,
              let image = CGImageSourceCreateImageAtIndex(
                source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              image.width == expectedWidth, image.height == expectedHeight else {
            throw WorkflowImageProcessorError.outputVerificationFailed
        }
        return EncodedInspection(format: expectedFormat, width: width, height: height,
                                 bitDepth: integerProperty(properties[kCGImagePropertyDepth as String]))
    }

    static func commonDetails(input: DecodedImage,
                              output: EncodedFormat) -> [String: String] {
        [
            "originalFormat": input.format.rawValue,
            "originalOrientation": input.originalOrientation,
            "originalColorSpace": input.originalColorSpace,
            "colorConversion": "\(input.originalColorSpace)-to-sRGB-8-bit",
            "normalizedOrientation": "1",
            "normalizedColorSpace": "sRGB-8-bit",
            "outputEncoding": output.rawValue,
            "processor": "CPU-CoreGraphics",
        ]
    }

    static func product(_ data: Data, inspection: EncodedInspection,
                        details: [String: String]) -> WorkflowImageProduct {
        WorkflowImageProduct(
            data: data,
            mediaType: inspection.format.mediaType,
            metadata: MediaMetadata(width: inspection.width, height: inspection.height,
                                    bitDepth: inspection.bitDepth ?? 8, colorSpace: "sRGB"),
            details: details)
    }
}
