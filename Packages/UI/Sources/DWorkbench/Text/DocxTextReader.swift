import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import ZIPFoundation

/// Reads only the package's main document part. Never extracts files or follows relationships.
enum DocxTextReader {
    static func validateOriginal(_ data: Data) throws {
        let parts = try readParts(data, xmlLimit: 16 * 1_024 * 1_024)
        let root = PackageReader(kind: .document)
        try parse(parts["word/document.xml"]!, using: root)
        guard root.matches == 1, root.hasBody else { throw WorkflowIssue("DOCX 主正文结构无效。") }
    }

    static func extract(_ data: Data, outputLimit: Int) throws -> String {
        let xmlLimit = min(16 * 1_024 * 1_024, outputLimit.multipliedReportingOverflow(by: 8).overflow
            ? Int.max : outputLimit * 8)
        let parts = try readParts(data, xmlLimit: xmlLimit)
        let reader = BodyReader(limit: outputLimit)
        try parse(parts["word/document.xml"]!, using: reader)
        if let error = reader.error { throw error }
        guard reader.hasDocument, reader.hasBody else { throw WorkflowIssue("DOCX 主正文 XML 损坏或命名空间不支持。") }
        try Task.checkCancellation()
        return reader.text
    }

    private static func readParts(_ data: Data, xmlLimit: Int) throws -> [String: Data] {
        try validateZIP32(data)
        let archive = try Archive(data: data, accessMode: .read)
        let required = Set(["word/document.xml", "[Content_Types].xml", "_rels/.rels"])
        var parts: [String: Data] = [:], count = 0
        for entry in archive {
            try Task.checkCancellation(); count += 1
            guard count <= 2048 else { throw WorkflowIssue("DOCX 条目超过读取预算。") }
            guard required.contains(entry.path) else { continue }
            guard parts[entry.path] == nil, entry.type == .file else { throw WorkflowIssue("DOCX 必需部件重复或不是普通条目。") }
            let limit = entry.path == "word/document.xml" ? xmlLimit : 1_048_576
            guard entry.uncompressedSize <= UInt64(limit) else { throw DocumentTextExtractionError.outputTooLarge }
            var xml = Data()
            let crc = try archive.extract(entry, bufferSize: 32 * 1024, skipCRC32: false) { bytes in
                try Task.checkCancellation()
                guard bytes.count <= limit - xml.count else { throw DocumentTextExtractionError.outputTooLarge }
                xml.append(bytes)
            }
            guard UInt64(xml.count) == entry.uncompressedSize, crc == entry.checksum else {
                throw WorkflowIssue("DOCX 部件长度或校验和不匹配。")
            }
            parts[entry.path] = xml
        }
        guard Set(parts.keys) == required else { throw WorkflowIssue("DOCX 缺少正文、内容类型或根关系；普通ZIP不能冒充文档。") }
        let types = PackageReader(kind: .types), relationships = PackageReader(kind: .relationships)
        try parse(parts["[Content_Types].xml"]!, using: types)
        try parse(parts["_rels/.rels"]!, using: relationships)
        guard types.matches == 1, relationships.matches == 1 else {
            throw WorkflowIssue("DOCX 主正文声明/关系不支持；本读取器只读取标准word/document.xml内部部件。")
        }
        return parts
    }

    private static func parse(_ xml: Data, using delegate: any XMLParserDelegate) throws {
        let source: String?
        if xml.starts(with: [0xFF, 0xFE]) || xml.starts(with: [0xFE, 0xFF]) { source = String(data: xml, encoding: .utf16) }
        else { source = String(data: xml, encoding: .utf8) }
        guard let source, !source.contains("\0"),
              !source.localizedCaseInsensitiveContains("<!DOCTYPE"), !source.localizedCaseInsensitiveContains("<!ENTITY") else {
            throw WorkflowIssue("DOCX XML 编码不支持或包含不允许的实体声明。")
        }
        let parser = XMLParser(data: xml)
        parser.shouldProcessNamespaces = true; parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never; parser.delegate = delegate
        let parsed = parser.parse()
        if let body = delegate as? BodyReader, let error = body.error { throw error }
        guard parsed else { throw WorkflowIssue("DOCX XML损坏或超过读取预算。") }
    }

    private final class PackageReader: NSObject, XMLParserDelegate {
        enum Kind { case types, relationships, document }
        let kind: Kind
        var matches = 0, depth = 0, hasBody = false
        init(kind: Kind) { self.kind = kind }
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI ns: String?,
                    qualifiedName: String?, attributes: [String: String]) {
            depth += 1
            guard depth <= 128, !Task.isCancelled else { parser.abortParsing(); return }
            switch kind {
            case .types:
                if depth == 1, name != "Types" || ns != "http://schemas.openxmlformats.org/package/2006/content-types" { parser.abortParsing(); return }
                if depth == 2, name == "Override", ns == "http://schemas.openxmlformats.org/package/2006/content-types",
                   attributes["PartName"] == "/word/document.xml" {
                    guard attributes["ContentType"] == "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml" else { parser.abortParsing(); return }
                    matches += 1
                }
            case .relationships:
                if depth == 1, name != "Relationships" || ns != "http://schemas.openxmlformats.org/package/2006/relationships" { parser.abortParsing(); return }
                if depth == 2, name == "Relationship", ns == "http://schemas.openxmlformats.org/package/2006/relationships",
                   ["http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument",
                    "http://purl.oclc.org/ooxml/officeDocument/relationships/officeDocument"].contains(attributes["Type"] ?? "") {
                    guard ["word/document.xml", "/word/document.xml"].contains(attributes["Target"] ?? ""),
                          attributes["TargetMode"] == nil || attributes["TargetMode"] == "Internal" else { parser.abortParsing(); return }
                    matches += 1
                }
            case .document:
                if ["http://schemas.openxmlformats.org/wordprocessingml/2006/main", "http://purl.oclc.org/ooxml/wordprocessingml/main"].contains(ns ?? "") {
                    if depth == 1, name == "document" { matches += 1 }
                    if depth == 2, name == "body", matches == 1 { hasBody = true }
                }
            }
        }
        func parser(_ parser: XMLParser, didEndElement: String, namespaceURI: String?, qualifiedName: String?) { depth -= 1 }
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
