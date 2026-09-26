import CoreGraphics
import Foundation
import ImageIO

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
    case ambiguousFormat
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
        case .unsupportedFormat: "图片格式未登记或不受支持。"
        case .ambiguousFormat: "图片签名同时匹配多个已登记格式。"
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

    public static func process(
        _ data: Data,
        operationID: String,
        parameters: [String: WorkflowScalar],
        codecs: ImageCodecRegistry = .standard
    ) throws -> WorkflowImageProduct {
        switch operationID {
        case "d.image.resize":
            return try resize(
                decode(data, codecs: codecs),
                parameters: parameters,
                codecs: codecs)
        case "d.image.convert":
            return try convert(
                decode(data, codecs: codecs),
                parameters: parameters,
                codecs: codecs)
        default:
            throw WorkflowImageProcessorError.unsupportedOperation(operationID)
        }
    }
}

private extension WorkflowImageProcessor {
    enum ResizeMode: String {
        case fit
        case fill
        case stretch
    }

    struct DecodedImage {
        let image: CGImage
        let codec: any ImageCodec
        let originalOrientation: String
        let originalColorSpace: String
        let hadAlpha: Bool
    }

    struct EncodedInspection {
        let mediaType: String
        let width: Int
        let height: Int
        let bitDepth: Int?
    }

    static func decode(_ data: Data, codecs: ImageCodecRegistry) throws -> DecodedImage {
        guard data.count <= maximumInputBytes else {
            throw WorkflowImageProcessorError.inputTooLarge
        }
        let detectedCodec: any ImageCodec
        do {
            detectedCodec = try codecs.codec(detecting: data)
        } catch let error as ImageCodecRegistryError {
            switch error {
            case .unsupportedFormat:
                throw WorkflowImageProcessorError.unsupportedFormat
            case .ambiguousSignature:
                throw WorkflowImageProcessorError.ambiguousFormat
            default:
                throw error
            }
        }
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
              actualType as String == detectedCodec.typeIdentifier else {
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
        return DecodedImage(image: normalized, codec: detectedCodec,
                            originalOrientation: rawOrientation.map { String($0) } ?? "unknown",
                            originalColorSpace: originalColorSpace, hadAlpha: originalAlpha)
    }

    static func resize(_ input: DecodedImage,
                       parameters: [String: WorkflowScalar],
                       codecs: ImageCodecRegistry) throws -> WorkflowImageProduct {
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
        guard let outputCodec = codecs.codec(formatID: "png") else {
            throw WorkflowImageProcessorError.unsupportedFormat
        }
        let options = try outputCodec.encodingOptions(quality: nil, background: nil)
        let encoded = try outputCodec.encode(resized, options: options)
        let inspection = try verify(encoded, expectedCodec: outputCodec,
                                    expectedWidth: width, expectedHeight: height)
        var details = commonDetails(input: input, output: outputCodec)
        details["alpha"] = outputCodec.alphaPolicy == .preserve
            ? (input.hadAlpha ? "preserved" : (mode == .fit ? "transparent-canvas" : "opaque"))
            : "removed"
        details["scalePolicy"] = mode.rawValue
        details["scale"] = scaleDescription
        details["backgroundPolicy"] = outputCodec.alphaPolicy == .preserve && mode == .fit
            ? "transparent-canvas"
            : "none"
        return product(encoded, inspection: inspection, details: details)
    }

    static func convert(_ input: DecodedImage,
                        parameters: [String: WorkflowScalar],
                        codecs: ImageCodecRegistry) throws -> WorkflowImageProduct {
        try rejectUnknownParameters(parameters, allowed: ["format", "quality", "background"])
        guard let formatValue = parameters["format"]?.string,
              !formatValue.isEmpty else {
            throw WorkflowImageProcessorError.invalidParameters("format 必须为已登记格式 ID。")
        }
        guard let outputCodec = codecs.codec(formatID: formatValue) else {
            throw WorkflowImageProcessorError.unsupportedFormat
        }
        let options = try outputCodec.encodingOptions(
            quality: parameters["quality"],
            background: parameters["background"])
        let encoded = try outputCodec.encode(input.image, options: options)
        let inspection = try verify(encoded, expectedCodec: outputCodec,
                                    expectedWidth: input.image.width,
                                    expectedHeight: input.image.height)
        var details = commonDetails(input: input, output: outputCodec)
        details["alpha"] = outputCodec.alphaPolicy == .preserve
            ? (input.hadAlpha ? "preserved" : "opaque")
            : "removed"
        details["scalePolicy"] = "unchanged"
        details["backgroundPolicy"] = options.background?.rawValue
            ?? (outputCodec.alphaPolicy == .preserve ? "preserve-alpha" : "unknown")
        details["quality"] = options.quality.map { String($0) } ?? "not-applicable"
        return product(encoded, inspection: inspection, details: details)
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

    static func verify(_ data: Data, expectedCodec: any ImageCodec,
                       expectedWidth: Int, expectedHeight: Int) throws -> EncodedInspection {
        guard expectedCodec.matchesSignature(data),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetStatus(source) == .statusComplete,
              let actualType = CGImageSourceGetType(source),
              actualType as String == expectedCodec.typeIdentifier,
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
        return EncodedInspection(
            mediaType: expectedCodec.mediaType,
            width: width,
            height: height,
            bitDepth: integerProperty(properties[kCGImagePropertyDepth as String]))
    }

    static func commonDetails(input: DecodedImage,
                              output: any ImageCodec) -> [String: String] {
        [
            "originalFormat": input.codec.formatID,
            "originalOrientation": input.originalOrientation,
            "originalColorSpace": input.originalColorSpace,
            "colorConversion": "\(input.originalColorSpace)-to-sRGB-8-bit",
            "normalizedOrientation": "1",
            "normalizedColorSpace": "sRGB-8-bit",
            "outputEncoding": output.formatID,
            "processor": "CPU-CoreGraphics",
        ]
    }

    static func product(_ data: Data, inspection: EncodedInspection,
                        details: [String: String]) -> WorkflowImageProduct {
        WorkflowImageProduct(
            data: data,
            mediaType: inspection.mediaType,
            metadata: MediaMetadata(width: inspection.width, height: inspection.height,
                                    bitDepth: inspection.bitDepth ?? 8, colorSpace: "sRGB"),
            details: details)
    }
}
