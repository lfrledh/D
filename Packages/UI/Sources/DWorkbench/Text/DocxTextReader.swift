import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import ZIPFoundation

/// Reads only the package's main document part. Never extracts files or follows relationships.
enum DocxTextReader {
    static func extract(_ data: Data, outputLimit: Int) throws -> String {
        try validateZIP32(data)
        let archive = try Archive(data: data, accessMode: .read)
        var document: Entry?, count = 0
        for entry in archive {
            try Task.checkCancellation()
            count += 1
            guard count <= 2048 else { throw WorkflowIssue("DOCX 条目超过读取预算。") }
            if entry.path == "word/document.xml" {
                guard document == nil, entry.type == .file else { throw WorkflowIssue("DOCX 主正文重复或不是普通条目。") }
                document = entry
            }
        }
        guard let document else { throw WorkflowIssue("DOCX 缺少主正文。") }
        let xmlLimit = min(16 * 1_024 * 1_024, outputLimit.multipliedReportingOverflow(by: 8).overflow
            ? Int.max : outputLimit * 8)
        guard document.uncompressedSize <= UInt64(xmlLimit) else { throw DocumentTextExtractionError.outputTooLarge }
        var xml = Data()
        let crc = try archive.extract(document, bufferSize: 32 * 1024, skipCRC32: false) { bytes in
            try Task.checkCancellation()
            guard bytes.count <= xmlLimit - xml.count else { throw DocumentTextExtractionError.outputTooLarge }
            xml.append(bytes)
        }
        guard UInt64(xml.count) == document.uncompressedSize, crc == document.checksum else {
            throw WorkflowIssue("DOCX 主正文长度或校验和不匹配。")
        }
        // Normalize only declared UTF-8/UTF-16 XML so the DTD check cannot be bypassed
        // by embedded NULs or a different byte encoding. XMLParser still validates markup.
        let source: String?
        if xml.starts(with: [0xFF, 0xFE]) || xml.starts(with: [0xFE, 0xFF]) {
            source = String(data: xml, encoding: .utf16)
        } else { source = String(data: xml, encoding: .utf8) }
        guard let source, !source.contains("\0"),
              !source.localizedCaseInsensitiveContains("<!DOCTYPE"),
              !source.localizedCaseInsensitiveContains("<!ENTITY") else {
            throw WorkflowIssue("DOCX XML 编码不支持或包含不允许的实体声明。")
        }
        let reader = BodyReader(limit: outputLimit)
        let parser = XMLParser(data: xml)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.delegate = reader
        let parsed = parser.parse()
        if let error = reader.error { throw error }
        guard parsed, reader.hasDocument, reader.hasBody else { throw WorkflowIssue("DOCX 主正文 XML 损坏或命名空间不支持。") }
        try Task.checkCancellation()
        return reader.text
    }

    /// Admission bounds for ZIPFoundation 0.9.20's in-memory seek/conversion paths.
    /// Decompression/CRC remain in the library. This reader accepts ZIP32 store/deflate,
    /// not ZIP64, multipart, encrypted, or ambiguous/trailing packages.
    private static func validateZIP32(_ data: Data) throws {
        let bytes = Array(data)
        func fail() -> WorkflowIssue { WorkflowIssue("DOCX 压缩目录损坏，或使用了未支持的ZIP64、分卷、加密格式。") }
        func fits(_ p: Int, _ n: Int, before end: Int? = nil) -> Bool {
            let end = end ?? bytes.count
            return p >= 0 && n >= 0 && p <= end && n <= end - p
        }
        func u16(_ p: Int) -> Int { Int(bytes[p]) | Int(bytes[p + 1]) << 8 }
        func u32(_ p: Int) -> Int { u16(p) | u16(p + 2) << 16 }
        func extra(_ p: Int, _ n: Int) throws {
            var i = p
            while i < p + n {
                guard fits(i, 4, before: p + n) else { throw fail() }
                let length = u16(i + 2)
                guard u16(i) != 1, fits(i + 4, length, before: p + n) else { throw fail() }
                i += 4 + length
            }
        }
        guard bytes.count >= 22 else { throw fail() }
        let end = stride(from: bytes.count - 22, through: max(0, bytes.count - 66_000), by: -1)
            .first { u32($0) == 0x06054b50 }
        guard let end, end >= 30, fits(end, 22), end + 22 + u16(end + 20) == bytes.count,
              u16(end + 4) == 0, u16(end + 6) == 0,
              u16(end + 8) == u16(end + 10), (1...2048).contains(u16(end + 10)),
              u32(end - 20) != 0x07064b50 else { throw fail() }
        let start = u32(end + 16), size = u32(end + 12)
        guard start >= 30, fits(start, size, before: end), start + size == end else { throw fail() }
        var position = start
        for _ in 0..<u16(end + 10) {
            try Task.checkCancellation()
            guard fits(position, 46, before: end), u32(position) == 0x02014b50,
                  u16(position + 6) <= 20, u16(position + 34) == 0 else { throw fail() }
            let flags = u16(position + 8), method = u16(position + 10)
            let compressed = u32(position + 20), expanded = u32(position + 24)
            let name = u16(position + 28), extraCount = u16(position + 30), comment = u16(position + 32)
            guard flags & 0x2041 == 0, [0, 8].contains(method),
                  compressed != 0xffffffff, expanded != 0xffffffff,
                  method != 0 || compressed == expanded,
                  fits(position + 46, name + extraCount + comment, before: end) else { throw fail() }
            try extra(position + 46 + name, extraCount)
            let local = u32(position + 42)
            guard fits(local, 30, before: start), u32(local) == 0x04034b50,
                  u16(local + 4) <= 20, u16(local + 6) == flags, u16(local + 8) == method else { throw fail() }
            let localName = u16(local + 26), localExtra = u16(local + 28)
            guard fits(local + 30, localName + localExtra, before: start) else { throw fail() }
            try extra(local + 30 + localName, localExtra)
            let payload = local + 30 + localName + localExtra
            guard fits(payload, compressed, before: start) else { throw fail() }
            if flags & 8 != 0 {
                // The dependency reads its fixed 16-byte descriptor before checking
                // whether the optional signature is present. Keep that read in-bounds.
                guard fits(payload + compressed, 16) else { throw fail() }
                let descriptor = payload + compressed
                let fields = u32(descriptor) == 0x08074b50 ? descriptor + 4 : descriptor
                guard u32(fields) == u32(position + 16), u32(fields + 4) == compressed,
                      u32(fields + 8) == expanded else { throw fail() }
            } else {
                guard u32(local + 18) == compressed, u32(local + 22) == expanded else { throw fail() }
            }
            position += 46 + name + extraCount + comment
        }
        guard position == end else { throw fail() }
    }

    private final class BodyReader: NSObject, XMLParserDelegate {
        let limit: Int
        var text = "", byteCount = 0, depth = 0, bodyDepth: Int?, textDepth: Int?
        var hasDocument = false, hasBody = false
        var error: (any Error)?
        let namespaces = ["http://schemas.openxmlformats.org/wordprocessingml/2006/main",
                          "http://purl.oclc.org/ooxml/wordprocessingml/main"]
        init(limit: Int) { self.limit = limit }
        func append(_ value: String, parser: XMLParser) {
            guard error == nil else { return }
            guard value.utf8.count <= limit - byteCount else {
                error = DocumentTextExtractionError.outputTooLarge; parser.abortParsing(); return
            }
            text += value; byteCount += value.utf8.count
        }
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String]) {
            depth += 1
            do { try Task.checkCancellation() } catch { self.error = error; parser.abortParsing(); return }
            guard depth <= 128 else { error = WorkflowIssue("DOCX XML 嵌套超过预算。"); parser.abortParsing(); return }
            if namespaceURI == "http://schemas.openxmlformats.org/markup-compatibility/2006", name == "AlternateContent" {
                error = WorkflowIssue("DOCX 包含互斥兼容内容；请先导出PDF或纯文本，避免重复或遗漏正文。")
                parser.abortParsing(); return
            }
            guard namespaces.contains(namespaceURI ?? "") else { return }
            if name == "document", depth == 1 { hasDocument = true }
            if name == "body", hasDocument, depth == 2 { bodyDepth = depth; hasBody = true }
            guard bodyDepth != nil else { return }
            if name == "t" { textDepth = depth }
            if name == "tab" { append("\t", parser: parser) }
            if name == "br" || name == "cr" { append("\n", parser: parser) }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if textDepth != nil { append(string, parser: parser) }
        }
        func parser(_ parser: XMLParser, foundCDATA data: Data) {
            guard textDepth != nil else { return }
            guard let string = String(data: data, encoding: .utf8) else {
                error = WorkflowIssue("DOCX CDATA编码无效。"); parser.abortParsing(); return
            }
            append(string, parser: parser)
        }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if namespaces.contains(namespaceURI ?? ""), bodyDepth != nil {
                if name == "p" { append("\n", parser: parser) }
                if name == "tc" { append("\t", parser: parser) }
            }
            if textDepth == depth { textDepth = nil }
            if bodyDepth == depth { bodyDepth = nil }
            depth -= 1
        }
        func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? {
            error = WorkflowIssue("DOCX 外部实体不允许读取。"); parser.abortParsing(); return nil
        }
    }
}
