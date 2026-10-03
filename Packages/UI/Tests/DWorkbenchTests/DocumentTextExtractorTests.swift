import CoreGraphics
import CoreText
import CryptoKit
import Foundation
import PDFKit
import Testing
@testable import DWorkbench

@Suite("Bounded document text extraction")
struct DocumentTextExtractorTests {
    @Test func utf8CSVAndUnicodeLocations() async throws {
        let source = "👩‍💻,值\r\n第二行,e\u{301}\n"
        let data = Data(source.utf8)
        let result = try await DocumentTextExtractor.extract(data: data, fileName: "table.CSV")
        #expect(result.text == source)
        #expect(result.format == "plain-text")
        #expect(result.parserVersion == "utf8-lines-v1")
        #expect(result.sourceSHA256 == SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        #expect(result.locations.map(\.line) == [1, 2, 3])
        #expect(result.locations.allSatisfy { $0.page == nil })
        let ns = result.text as NSString
        #expect(ns.substring(with: result.locations[0].range) == "👩‍💻,值")
        #expect(ns.substring(with: result.locations[1].range) == "第二行,e\u{301}")
        #expect(result.locations[1].range.location == ("👩‍💻,值\r\n" as NSString).length)
        #expect(result.locations[2].range.location == ns.length)
        #expect(result.locations[2].range.length == 0)
        #expect(result.warnings.isEmpty)
    }

    @Test func exactLimitsAndInvalidText() async throws {
        let data = Data("abc".utf8)
        let exact = DocumentExtractionLimits(maxInputBytes: 3, maxOutputBytes: 3)
        #expect(try await DocumentTextExtractor.extract(data: data, fileName: "note.md", limits: exact).text == "abc")
        await expectError(.inputTooLarge, data: data, name: "note.md",
                          limits: .init(maxInputBytes: 2))
        await expectError(.outputTooLarge, data: data, name: "note.md",
                          limits: .init(maxOutputBytes: 2))
        await expectError(.invalidLimits, data: data, name: "note.md",
                          limits: .init(maxPages: 0))
        await expectError(.emptyInput, data: Data(), name: "note.md")
        await expectError(.invalidUTF8, data: Data([0xC3, 0x28]), name: "note.md")
        await expectError(.binaryText, data: Data([0x61, 0, 0x62]), name: "note.md")
        await expectError(.emptyInput, data: Data([0xEF, 0xBB, 0xBF]), name: "note.md")
    }

    @Test func contentMustAgreeWithSupportedSuffix() async throws {
        let pdf = makePDF(pageTexts: ["Hello PDF"])
        await expectError(.formatMismatch, data: pdf, name: "impostor.txt")
        await expectError(.formatMismatch, data: Data("plain".utf8), name: "impostor.pdf")
        await expectError(.invalidPDF, data: Data("%PDF-broken".utf8), name: "broken.pdf")
        await expectError(.formatMismatch, data: Data("plain".utf8), name: "impostor.docx")
        await expectError(.docxUnavailable, data: Data([0x50, 0x4B, 0x03, 0x04]), name: "file.docx")
        await expectError(.unsupportedFormat, data: Data("plain".utf8), name: "file.rtf")
    }

    @Test func pdfKitExtractsTextAndPagePositions() async throws {
        let data = makePDF(pageTexts: ["First page", "Second page"])
        let result = try await DocumentTextExtractor.extract(data: data, fileName: "pages.pdf")
        #expect(result.format == "pdf")
        #expect(result.parserVersion == "system-pdfkit-v1")
        #expect(result.text.contains("First page"))
        #expect(result.text.contains("Second page"))
        #expect(result.locations.contains { $0.page == 1 &&
            (result.text as NSString).substring(with: $0.range).contains("First page") })
        #expect(result.locations.contains { $0.page == 2 &&
            (result.text as NSString).substring(with: $0.range).contains("Second page") })
        #expect(result.locations.allSatisfy {
            $0.range.location >= 0 && $0.range.length >= 0 &&
            $0.range.location + $0.range.length <= (result.text as NSString).length
        })
        await expectError(.outputTooLarge, data: data, name: "pages.pdf",
                          limits: .init(maxOutputBytes: 5))
    }

    @Test func pdfDoesNotDropPagesOrRunImplicitOCR() async throws {
        let data = makePDF(pageTexts: ["Read me", nil])
        await expectError(.noText(page: 2), data: data, name: "mixed.pdf")
        await expectError(.tooManyPages, data: data, name: "mixed.pdf",
                          limits: .init(maxPages: 1))
        let scanned = makePDF(pageTexts: [nil], pageSize: 1_000)
        await expectError(.noText(page: 1), data: scanned, name: "scan.pdf")
        await expectError(.ocrPageTooLarge(page: 1), data: scanned, name: "scan.pdf",
                          ocr: true, limits: .init(maxOCRPixelsPerPage: 1_000))
    }

    @Test func cancellationStopsBeforeParsing() async throws {
        let data = makePDF(pageTexts: ["Hello PDF"])
        let operation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await DocumentTextExtractor.extract(data: data, fileName: "cancel.pdf")
        }
        do {
            _ = try await operation.value
            Issue.record("Cancelled extraction unexpectedly succeeded")
        } catch is CancellationError {
            // Expected before PDFKit is entered.
        }
    }

    @Test func ocrBoxesHaveAStableTransitiveOrder() {
        // Old tolerance comparator: B < A, C < B, but A < C (a cycle).
        let a = CGRect(x: 0.3, y: 0.900, width: 0, height: 0)
        let b = CGRect(x: 0.2, y: 0.894, width: 0, height: 0)
        let c = CGRect(x: 0.1, y: 0.888, width: 0, height: 0)
        #expect(DocumentTextExtractor.ocrReadingOrder(for: [a, b, c]) == [0, 1, 2])
        #expect(DocumentTextExtractor.ocrReadingOrder(for: [c, a, b]) == [1, 2, 0])
        #expect(DocumentTextExtractor.ocrReadingOrder(for: [a, a]) == [0, 1])
    }

    @Test(arguments: [0, 90, 270])
    func rotatedRasterPDFKeepsHorizontalWord(rotation: Int) async throws {
        let word = "HORIZONTAL"
        let data = makeRotatedRasterPDF(rotation: rotation, word: word)
        let page = PDFDocument(data: data)?.page(at: 0)
        #expect(Int(page?.pageRef?.rotationAngle ?? -1) == rotation)
        #expect(page?.pageRef?.getBoxRect(.mediaBox).size == CGSize(width: 200, height: 400))
        let result = try await DocumentTextExtractor.extract(data: data, fileName: "rotated.pdf", ocr: true)
        #expect(result.parserVersion == "system-vision-v1")
        #expect(result.text.uppercased().contains(word))
        #expect(result.locations.contains { $0.page == 1 &&
            (result.text as NSString).substring(with: $0.range).uppercased().contains(word) })
    }

    private func expectError(_ expected: DocumentTextExtractionError, data: Data, name: String,
                             ocr: Bool = false, limits: DocumentExtractionLimits = .init()) async {
        do {
            _ = try await DocumentTextExtractor.extract(data: data, fileName: name,
                                                         ocr: ocr, limits: limits)
            Issue.record("Expected \(expected) for \(name)")
        } catch let error as DocumentTextExtractionError {
            #expect(error == expected)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    /// Builds a small real PDF with text operators and a correct xref, without files or GUI state.
    private func makePDF(pageTexts: [String?], pageSize: Int = 200) -> Data {
        var objects: [String] = []
        let pageIDs = pageTexts.indices.map { 3 + $0 * 2 }
        objects.append("<< /Type /Catalog /Pages 2 0 R >>")
        objects.append("<< /Type /Pages /Kids [\(pageIDs.map { "\($0) 0 R" }.joined(separator: " "))] /Count \(pageIDs.count) >>")
        for (index, text) in pageTexts.enumerated() {
            let stream = text.map { "BT /F1 12 Tf 20 100 Td (\($0)) Tj ET" } ?? ""
            objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(pageSize) \(pageSize)] /Resources << /Font << /F1 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> >> >> /Contents \(pageIDs[index] + 1) 0 R >>")
            objects.append("<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream")
        }
        return serializePDF(objects: objects)
    }

    /// Native 200 x 400 page; quarter turns display it as 400 x 200. The image
    /// placement keeps the upright word horizontal in each display rotation.
    private func makeRotatedRasterPDF(rotation: Int, word: String) -> Data {
        let width = 320
        let height = 64
        let bitmap = CGContext(data: nil, width: width, height: height,
                               bitsPerComponent: 8, bytesPerRow: width,
                               space: CGColorSpaceCreateDeviceGray(),
                               bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
        bitmap.setFillColor(CGColor(gray: 0, alpha: 1))
        // CoreText draws upright in the bitmap's default coordinates. Flipping
        // here turns the embedded PDF image upside down on every page rotation.
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 38, nil)
        let attributed = NSAttributedString(string: word, attributes: [
            NSAttributedString.Key(rawValue: kCTFontAttributeName as String): font
        ])
        bitmap.textPosition = CGPoint(x: 7, y: 12)
        CTLineDraw(CTLineCreateWithAttributedString(attributed), bitmap)
        bitmap.flush()
        let pixels = Data(bytes: bitmap.data!, count: width * height)
        let hex = pixels.map { String(format: "%02X", $0) }.joined() + ">"
        let placement = rotation == 0 ? "180 0 0 36 10 150" :
            (rotation == 90 ? "0 320 -64 0 132 40" : "0 -320 64 0 68 360")
        let content = "q \(placement) cm /Im0 Do Q"
        return serializePDF(objects: [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 400] /Rotate \(rotation) /Resources << /XObject << /Im0 5 0 R >> >> /Contents 4 0 R >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
            "<< /Type /XObject /Subtype /Image /Width \(width) /Height \(height) /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /ASCIIHexDecode /Length \(hex.utf8.count) >>\nstream\n\(hex)\nendstream"
        ])
    }

    private func serializePDF(objects: [String]) -> Data {
        var pdf = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(pdf.utf8.count)
            pdf += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xref = pdf.utf8.count
        pdf += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets {
            pdf += String(format: "%010d 00000 n \n", offset)
        }
        pdf += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(pdf.utf8)
    }
}
