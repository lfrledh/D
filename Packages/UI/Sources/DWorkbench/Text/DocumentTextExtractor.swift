import CoreGraphics
import CryptoKit
import Foundation
import PDFKit
import Vision

public struct DocumentExtractionLimits: Sendable, Equatable {
    /// Budgets for supplied bytes, returned UTF-8 text, PDF pages, and the OCR bitmap target.
    /// PDFKit and Vision may use additional memory internally during synchronous calls.
    public var maxInputBytes: Int
    public var maxOutputBytes: Int
    public var maxPages: Int
    public var maxOCRPixelsPerPage: Int

    public init(maxInputBytes: Int = 16 * 1_024 * 1_024,
                maxOutputBytes: Int = 1_024 * 1_024,
                maxPages: Int = 100,
                maxOCRPixelsPerPage: Int = 4_000_000) {
        self.maxInputBytes = maxInputBytes
        self.maxOutputBytes = maxOutputBytes
        self.maxPages = maxPages
        self.maxOCRPixelsPerPage = maxOCRPixelsPerPage
    }
}

public struct DocumentTextLocation: Sendable, Equatable {
    public let page: Int?
    public let line: Int?
    /// A range in the returned text, measured in UTF-16 code units.
    public let range: NSRange

    public init(page: Int?, line: Int?, range: NSRange) {
        self.page = page
        self.line = line
        self.range = range
    }
}

public struct DocumentTextExtraction: Sendable, Equatable {
    public let text: String
    public let sourceSHA256: String
    public let format: String
    public let parserVersion: String
    public let locations: [DocumentTextLocation]
    public let warnings: [String]
}

public enum DocumentTextExtractionError: Error, LocalizedError, Sendable, Equatable {
    case invalidLimits
    case emptyInput
    case inputTooLarge
    case outputTooLarge
    case tooManyPages
    case ocrPageTooLarge(page: Int)
    case unsupportedFormat
    case formatMismatch
    case invalidUTF8
    case binaryText
    case invalidPDF
    case encryptedPDF
    case noText(page: Int)
    case docxUnavailable
    case ocrFailed(page: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidLimits: "文档提取预算必须为正数。"
        case .emptyInput: "文档为空。"
        case .inputTooLarge: "文档超过输入字节预算。"
        case .outputTooLarge: "提取文字超过输出字节预算。"
        case .tooManyPages: "PDF 超过页数预算。"
        case .ocrPageTooLarge(let page): "PDF 第\(page)页超过 OCR 像素预算。"
        case .unsupportedFormat: "尚不支持此文档格式。"
        case .formatMismatch: "文件内容与所提示格式不符。"
        case .invalidUTF8: "文字文件不是有效的 UTF-8。"
        case .binaryText: "文字文件含二进制内容。"
        case .invalidPDF: "PDF 内容损坏或没有可读取页面。"
        case .encryptedPDF: "加密 PDF 暂不能提取，请提供未加密原件。"
        case .noText(let page): "PDF 第\(page)页没有可提取文字；如为扫描页，请显式启用本地 OCR。"
        case .docxUnavailable: "DOCX 的安全正文解析尚未接线，当前不能声称已读取。"
        case .ocrFailed(let page): "PDF 第\(page)页本地 OCR 未能完成。"
        }
    }
}

public enum DocumentTextExtractor {
    /// Cancellation is checked between pages and around synchronous PDFKit/Vision calls.
    /// An in-progress framework call may finish before cancellation is observed.
    public static func extract(data: Data, fileName: String, ocr: Bool = false) async throws -> DocumentTextExtraction {
        try await extract(data: data, fileName: fileName, ocr: ocr, limits: .init())
    }

    public static func extract(data: Data, fileName: String, ocr: Bool = false,
                               limits: DocumentExtractionLimits) async throws -> DocumentTextExtraction {
        try Task.checkCancellation()
        guard limits.maxInputBytes > 0, limits.maxOutputBytes > 0,
              limits.maxPages > 0, limits.maxOCRPixelsPerPage > 0 else {
            throw DocumentTextExtractionError.invalidLimits
        }
        guard !data.isEmpty else { throw DocumentTextExtractionError.emptyInput }
        guard data.count <= limits.maxInputBytes else { throw DocumentTextExtractionError.inputTooLarge }

        let suffix = (fileName as NSString).pathExtension.lowercased()
        let isPDF = data.starts(with: [0x25, 0x50, 0x44, 0x46, 0x2D]) // %PDF-
        let isZIP = data.starts(with: [0x50, 0x4B, 0x03, 0x04])
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()

        if suffix == "pdf" {
            guard isPDF else { throw DocumentTextExtractionError.formatMismatch }
            return try extractPDF(data: data, digest: digest, ocr: ocr, limits: limits)
        }
        if suffix == "docx" {
            guard isZIP else { throw DocumentTextExtractionError.formatMismatch }
            throw DocumentTextExtractionError.docxUnavailable
        }
        guard plainTextExtensions.contains(suffix) else { throw DocumentTextExtractionError.unsupportedFormat }
        guard !isPDF, !isZIP else { throw DocumentTextExtractionError.formatMismatch }
        guard !data.contains(0) else { throw DocumentTextExtractionError.binaryText }
        let bytes = data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data[...]
        guard let value = String(bytes: bytes, encoding: .utf8) else {
            throw DocumentTextExtractionError.invalidUTF8
        }
        guard !value.isEmpty else { throw DocumentTextExtractionError.emptyInput }
        guard value.utf8.count <= limits.maxOutputBytes else { throw DocumentTextExtractionError.outputTooLarge }
        try Task.checkCancellation()
        return .init(text: value, sourceSHA256: digest, format: "plain-text",
                     parserVersion: "utf8-lines-v1", locations: lineLocations(in: value, page: nil, offset: 0),
                     warnings: [])
    }

    private static let plainTextExtensions: Set<String> = [
        "txt", "text", "md", "markdown", "csv", "tsv", "swift", "py", "js", "jsx", "ts", "tsx",
        "json", "yaml", "yml", "xml", "html", "htm", "css", "sh", "c", "h", "cpp", "hpp",
        "java", "kt", "rs", "go", "rb", "sql", "toml", "ini"
    ]

    private static func extractPDF(data: Data, digest: String, ocr: Bool,
                                   limits: DocumentExtractionLimits) throws -> DocumentTextExtraction {
        guard let document = PDFDocument(data: data) else {
            throw DocumentTextExtractionError.invalidPDF
        }
        guard !document.isEncrypted, !document.isLocked else {
            throw DocumentTextExtractionError.encryptedPDF
        }
        guard document.pageCount > 0 else { throw DocumentTextExtractionError.invalidPDF }
        guard document.pageCount <= limits.maxPages else { throw DocumentTextExtractionError.tooManyPages }

        var text = ""
        var locations: [DocumentTextLocation] = []
        var warnings: [String] = []
        var usedOCR = false
        var outputBytes = 0
        for pageIndex in 0..<document.pageCount {
            try Task.checkCancellation()
            let number = pageIndex + 1
            guard let page = document.page(at: pageIndex) else { throw DocumentTextExtractionError.invalidPDF }
            var pageText = page.string ?? ""
            if pageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard ocr else { throw DocumentTextExtractionError.noText(page: number) }
                pageText = try recognize(page: page, number: number, pixelLimit: limits.maxOCRPixelsPerPage)
                guard !pageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw DocumentTextExtractionError.noText(page: number)
                }
                usedOCR = true
                warnings.append("第\(number)页使用本地 OCR，文字可能有识别误差。")
            }
            let separator = pageIndex == 0 ? "" : "\n"
            let addedBytes = separator.utf8.count + pageText.utf8.count
            guard addedBytes <= limits.maxOutputBytes - outputBytes else {
                throw DocumentTextExtractionError.outputTooLarge
            }
            text += separator
            let offset = (text as NSString).length
            text += pageText
            locations += lineLocations(in: pageText, page: number, offset: offset)
            outputBytes += addedBytes
        }
        try Task.checkCancellation()
        return .init(text: text, sourceSHA256: digest, format: "pdf",
                     parserVersion: usedOCR ? "system-vision-v1" : "system-pdfkit-v1",
                     locations: locations, warnings: warnings)
    }

    private static func recognize(page: PDFPage, number: Int, pixelLimit: Int) throws -> String {
        try Task.checkCancellation()
        guard let pdfPage = page.pageRef else { throw DocumentTextExtractionError.invalidPDF }
        let mediaBox = pdfPage.getBoxRect(.mediaBox)
        let declaredCrop = pdfPage.getBoxRect(.cropBox)
        let cropBox = (declaredCrop.isNull ? mediaBox : declaredCrop).intersection(mediaBox)
        let rotation = ((pdfPage.rotationAngle % 360) + 360) % 360
        let quarterTurn = rotation == 90 || rotation == 270
        let widthValue = ((quarterTurn ? cropBox.height : cropBox.width) * 2).rounded(.up)
        let heightValue = ((quarterTurn ? cropBox.width : cropBox.height) * 2).rounded(.up)
        guard widthValue.isFinite, heightValue.isFinite,
              widthValue >= 1, heightValue >= 1,
              widthValue <= CGFloat(pixelLimit), heightValue <= CGFloat(pixelLimit),
              widthValue < CGFloat(Int.max), heightValue < CGFloat(Int.max) else {
            throw DocumentTextExtractionError.ocrPageTooLarge(page: number)
        }
        let width = Int(widthValue)
        let height = Int(heightValue)
        guard width <= pixelLimit / height else {
            throw DocumentTextExtractionError.ocrPageTooLarge(page: number)
        }
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw DocumentTextExtractionError.ocrFailed(page: number)
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let target = CGRect(x: 0, y: 0, width: width, height: height)
        context.concatenate(pdfPage.getDrawingTransform(.cropBox, rect: target,
                                                        rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(pdfPage)
        try Task.checkCancellation()
        guard let image = context.makeImage() else { throw DocumentTextExtractionError.ocrFailed(page: number) }
        try Task.checkCancellation()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            try Task.checkCancellation()
            throw DocumentTextExtractionError.ocrFailed(page: number)
        }
        try Task.checkCancellation()
        let observations = request.results ?? []
        return ocrReadingOrder(for: observations.map(\.boundingBox))
            .compactMap { observations[$0].topCandidates(1).first?.string }
            .joined(separator: "\n")
    }

    /// Lexicographic coordinates plus original observation index form a deterministic total order.
    /// A pairwise "same line" tolerance can create comparison cycles across three boxes.
    static func ocrReadingOrder(for boxes: [CGRect]) -> [Int] {
        func finite(_ value: CGFloat) -> CGFloat { value.isFinite ? value : -CGFloat.greatestFiniteMagnitude }
        return boxes.indices.sorted { left, right in
            let leftY = finite(boxes[left].midY)
            let rightY = finite(boxes[right].midY)
            if leftY != rightY { return leftY > rightY }
            let leftX = finite(boxes[left].minX)
            let rightX = finite(boxes[right].minX)
            if leftX != rightX { return leftX < rightX }
            return left < right
        }
    }

    private static func lineLocations(in value: String, page: Int?, offset: Int) -> [DocumentTextLocation] {
        let string = value as NSString
        var result: [DocumentTextLocation] = []
        var cursor = 0
        var number = 1
        while cursor < string.length {
            var start = 0
            var end = 0
            var contentEnd = 0
            string.getLineStart(&start, end: &end, contentsEnd: &contentEnd,
                                for: NSRange(location: cursor, length: 0))
            result.append(.init(page: page, line: number,
                                range: NSRange(location: offset + start, length: contentEnd - start)))
            cursor = end
            number += 1
        }
        if value.hasSuffix("\n") || value.hasSuffix("\r") {
            result.append(.init(page: page, line: number,
                                range: NSRange(location: offset + string.length, length: 0)))
        }
        return result
    }
}
