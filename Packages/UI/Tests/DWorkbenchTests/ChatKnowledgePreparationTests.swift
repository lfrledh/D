import Foundation
import Testing
@testable import DWorkbench

@Suite("Explicit knowledge directory and frozen reranking")
struct ChatKnowledgeDirectoryInventoryTests {
    private func fixture() throws -> URL {
        let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory(),
                       isDirectory: true).resolvingSymlinksInPath()
        let root = base.appendingPathComponent("ChatKnowledge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ text: String, named name: String, in root: URL) throws -> URL {
        let file = root.appendingPathComponent(name)
        try Data(text.utf8).write(to: file)
        return file
    }

    @Test func inspectsOnlyDirectSupportedFilesAndLeavesSourcesUntouched() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let unicode = try write("月光 🌙", named: "資料 🌙.md", in: root)
        _ = try write("pdf fixture", named: "pages.PDF", in: root)
        _ = try write("docx fixture", named: "draft.docx", in: root)
        _ = try write("unsupported", named: "movie.mp4", in: root)
        let child = root.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
        _ = try write("hidden", named: "nested.txt", in: child)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("shortcut.txt"),
                                                   withDestinationURL: unicode)
        let original = try Data(contentsOf: unicode)

        let inventory = try ChatKnowledgeDirectoryInventory.inspect(root)
        #expect(inventory.entries.map(\.name) == ["draft.docx", "pages.PDF", "資料 🌙.md"])
        #expect(inventory.entries.map(\.id) == inventory.entries.map(\.url))
        #expect(inventory.entries.last?.byteCount == Int64(original.count))
        #expect(inventory.excluded.contains { $0.contains("folder: directory or package") })
        #expect(inventory.excluded.contains { $0.contains("shortcut.txt: symbolic link") })
        #expect(inventory.excluded.contains { $0.contains("movie.mp4: unsupported file type") })
        for entry in inventory.entries { try entry.validateUnchanged() }
        #expect(try Data(contentsOf: unicode) == original)
    }

    @Test func rejectsLinksReplacementChangesMissingFilesAndOversizedListings() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try write("old", named: "a.txt", in: root)
        let entry = try #require(ChatKnowledgeDirectoryInventory.inspect(root).entries.first)
        let replacement = try write("new", named: "replacement.txt", in: root)
        try FileManager.default.removeItem(at: first)
        try FileManager.default.moveItem(at: replacement, to: first) // same length, distinct existing inode
        #expect(throws: ChatKnowledgeDirectoryInventory.InventoryError.entryChanged("a.txt")) {
            try entry.validateUnchanged()
        }

        let changed = try #require(ChatKnowledgeDirectoryInventory.inspect(root).entries.first)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-120)], ofItemAtPath: first.path)
        #expect(throws: ChatKnowledgeDirectoryInventory.InventoryError.entryChanged("a.txt")) {
            try changed.validateUnchanged()
        }
        let resized = try #require(ChatKnowledgeDirectoryInventory.inspect(root).entries.first)
        try Data("larger file".utf8).write(to: first)
        #expect(throws: ChatKnowledgeDirectoryInventory.InventoryError.entryChanged("a.txt")) {
            try resized.validateUnchanged()
        }
        let missing = try #require(ChatKnowledgeDirectoryInventory.inspect(root).entries.first)
        try FileManager.default.removeItem(at: first)
        #expect(throws: ChatKnowledgeDirectoryInventory.InventoryError.entryUnavailable("a.txt")) {
            try missing.validateUnchanged()
        }

        _ = try write("1", named: "one.txt", in: root)
        try FileManager.default.createSymbolicLink(at: first, withDestinationURL: root.appendingPathComponent("one.txt"))
        #expect(throws: ChatKnowledgeDirectoryInventory.InventoryError.entryChanged("a.txt")) {
            try missing.validateUnchanged()
        }
        try FileManager.default.removeItem(at: first)
        _ = try write("2", named: "two.mp4", in: root)
        #expect(throws: ChatKnowledgeDirectoryInventory.InventoryError.tooManyEntries(1)) {
            try ChatKnowledgeDirectoryInventory.inspect(root, maximumEntries: 1)
        }
        #expect(throws: ChatKnowledgeDirectoryInventory.InventoryError.invalidMaximumEntries) {
            try ChatKnowledgeDirectoryInventory.inspect(root, maximumEntries: 0)
        }
        let linkedRoot = root.deletingLastPathComponent().appendingPathComponent("ChatKnowledge-link-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: linkedRoot) }
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: root)
        #expect(throws: (any Error).self) { try ChatKnowledgeDirectoryInventory.inspect(linkedRoot) }
        #expect(throws: (any Error).self) {
            try ChatKnowledgeDirectoryInventory.inspect(root.appendingPathComponent("absent"))
        }
    }

    @Test func replacedDirectoryCannotValidateAnOldEntry() throws {
        let parent = try fixture()
        defer { try? FileManager.default.removeItem(at: parent) }
        let selected = parent.appendingPathComponent("selected", isDirectory: true)
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: false)
        _ = try write("same", named: "note.txt", in: selected)
        let old = try #require(ChatKnowledgeDirectoryInventory.inspect(selected).entries.first)
        try FileManager.default.moveItem(at: selected, to: parent.appendingPathComponent("former"))
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: false)
        _ = try write("same", named: "note.txt", in: selected)
        #expect(throws: ChatKnowledgeDirectoryInventory.InventoryError.directoryChanged) {
            try old.validateUnchanged()
        }
    }

    @Test func refusesTruncatedAndRemoteDirectoryURLs() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let selected = root.appendingPathComponent("selected", isDirectory: true)
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: false)
        _ = try write("fixture", named: "note.txt", in: selected)

        let nulURL = try #require(URL(string: root.absoluteString + "selected%00suffix"))
        let encodedPath = try #require(URLComponents(url: nulURL, resolvingAgainstBaseURL: false)?.percentEncodedPath)
        #expect(encodedPath.hasSuffix("selected%00suffix"))
        #expect(throws: ChatKnowledgeDirectoryInventory.InventoryError.invalidDirectory) {
            try ChatKnowledgeDirectoryInventory.inspect(nulURL)
        }

        var remote = try #require(URLComponents(url: selected, resolvingAgainstBaseURL: false))
        remote.host = "remote-host"
        let remoteURL = try #require(remote.url)
        #expect(remoteURL.host == "remote-host")
        #expect(throws: ChatKnowledgeDirectoryInventory.InventoryError.invalidDirectory) {
            try ChatKnowledgeDirectoryInventory.inspect(remoteURL)
        }
    }

    private func excerpt(_ id: String, text: String, asset: String) -> ChatKnowledgeExcerpt {
        let source = WorkflowAssetReference(
            projectID: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            assetID: UUID(uuidString: asset)!,
            version: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
            kind: .text, sha256: String(repeating: "a", count: 64))
        return .init(id: UUID(uuidString: id)!, source: source, name: "資料.md", text: text,
                     utf16Offset: 7, utf16Length: text.utf16.count, page: nil, line: 2)
    }

    @Test func promptRetainsExactUnicodeAndParseReturnsOriginalFrozenValues() throws {
        let a = excerpt("30000000-0000-0000-0000-000000000003", text: "月光 \"🌙\"", asset: "40000000-0000-0000-0000-000000000004")
        let b = excerpt("50000000-0000-0000-0000-000000000005", text: "second\nline", asset: "60000000-0000-0000-0000-000000000006")
        let query = "哪一句是月光？"
        let prepared = try ChatKnowledgeReranking.prepare(query: query, excerpts: [a, b])
        let body = try #require(JSONSerialization.jsonObject(with: Data(prepared.utf8)) as? [String: Any])
        #expect(body["query"] as? String == query)
        let records = try #require(body["excerpts"] as? [[String: Any]])
        #expect(records.compactMap { $0["id"] as? String } == [a.id.uuidString, b.id.uuidString])
        #expect(records.compactMap { $0["text"] as? String } == [a.text, b.text])
        #expect(records[0]["sourceID"] as? String == a.source.assetID.uuidString)
        #expect(records[0]["version"] as? String == a.source.version.uuidString)
        #expect(records[0]["utf16Offset"] as? Int == a.utf16Offset)
        #expect(records[0]["line"] as? Int == a.line)
        let order = "{\"order\":[\"\(b.id.uuidString)\",\"\(a.id.uuidString)\"]}"
        #expect(try ChatKnowledgeReranking.parse(order, excerpts: [a, b]) == [b, a])
        #expect(try ChatKnowledgeReranking.parse("{\"order\":[]}", excerpts: []).isEmpty)
        #expect(try ChatKnowledgeReranking.parse("{\"order\":[\"\(a.id.uuidString)\"]}", excerpts: [a]) == [a])
    }

    @Test func malformedOrForgedOrderingIsRefusedWithoutChangingExcerpts() throws {
        let a = excerpt("30000000-0000-0000-0000-000000000003", text: "月光", asset: "40000000-0000-0000-0000-000000000004")
        let b = excerpt("50000000-0000-0000-0000-000000000005", text: "海", asset: "60000000-0000-0000-0000-000000000006")
        let frozen = [a, b]
        let invalid = [
            "{\"order\":[\"\(a.id.uuidString)\",\"\(a.id.uuidString)\"]}",
            "{\"order\":[\"\(a.id.uuidString)\"]}",
            "{\"order\":[\"\(a.id.uuidString)\",\"70000000-0000-0000-0000-000000000007\"]}",
            "{\"order\":[\"\(a.id.uuidString)\",\"\(b.id.uuidString)\"]} trailing",
            "{\"order\":[true,false]}",
            "{\"order\":[\"\(a.id.uuidString)\",\"\(b.id.uuidString)\"],\"extra\":0}",
            "{\"order\":[],\"order\":[]}",
            "```json\n{\"order\":[]}\n```",
            "[]"
        ]
        for value in invalid {
            #expect(throws: (any Error).self) { try ChatKnowledgeReranking.parse(value, excerpts: frozen) }
        }
        #expect(frozen == [a, b])
        #expect(throws: ChatKnowledgeReranking.RerankingError.duplicateExcerptID) {
            try ChatKnowledgeReranking.prepare(query: "q", excerpts: [a, a])
        }
        #expect(throws: ChatKnowledgeReranking.RerankingError.queryTooLarge) {
            try ChatKnowledgeReranking.prepare(query: String(repeating: "é", count: 2_049), excerpts: [a])
        }
        #expect(throws: ChatKnowledgeReranking.RerankingError.tooManyExcerpts) {
            try ChatKnowledgeReranking.prepare(query: "q", excerpts: Array(repeating: a, count: 17))
        }
        let large = excerpt("80000000-0000-0000-0000-000000000008", text: String(repeating: "\\", count: 65_536),
                            asset: "90000000-0000-0000-0000-000000000009")
        let many = (0..<4).map { index in
            excerpt(String(format: "A0000000-0000-0000-0000-%012d", index), text: large.text,
                    asset: String(format: "B0000000-0000-0000-0000-%012d", index))
        }
        #expect(throws: ChatKnowledgeReranking.RerankingError.inputTooLarge) {
            try ChatKnowledgeReranking.prepare(query: "q", excerpts: many)
        }
    }
}
