import CryptoKit
import DInference
import Foundation
import Testing
@testable import DWorkbench

@Suite("Text sources immutable prompt history")
struct TextSourcesPromptVersionTests {
    @Test("A fixed archive from the previous implementation opens without rebuilding its fixture")
    func frozenLegacyArchive() throws {
        let note = try TextSourcesArchive.decode(TextSourcesLegacyFixture.archive)
        #expect(note.records.count == 1)
        let record = try #require(note.records.first)
        #expect(record.submission.promptTemplate == .v1)
        #expect(record.submission.request.prompt.hasPrefix("请仅根据下列资料片段回答问题。"))
        #expect(record.submission.request.prompt.contains("[S序号]"))
        #expect(try note.sources.first?.validatedText() == "项目代号是蓝桉。会议地点是京都。资料没有说明预算、参与人数或日期。")
        let encoded = try TextSourcesArchive.encode(note)
        let submissionJSON = try JSONEncoder().encode(record.submission)
        let object = try #require(JSONSerialization.jsonObject(with: submissionJSON) as? [String: Any])
        #expect(object["promptTemplate"] == nil)
        let reopened = try TextSourcesArchive.decode(encoded)
        #expect(reopened == note)
        #expect(Array(reopened.records[0].submission.request.prompt.utf8) == Array(record.submission.request.prompt.utf8))
    }

    @Test("A real previously saved project opens without changing original manifest bytes")
    func frozenLegacyProject() async throws {
        try await withLegacyProject { root in
            let original = try Data(contentsOf: root.appendingPathComponent("project.json"))
            let store = try await ProjectStore.open(at: root)
            let current = await store.snapshot()
            #expect(current.schemaVersion == 10)
            #expect(current.activeDocument?.textSources?.records.count == 1)
            try await store.close()
            #expect(try Data(contentsOf: root.appendingPathComponent("project.json")) == original)
        }
    }

    @Test("Production v2 matches every prompt frozen before the real model evaluation")
    func evaluatedPromptsAreExact() throws {
        for item in try JSONDecoder().decode([EvaluatedCase].self, from: TextSourcesLegacyFixture.evaluatedCases) {
            let (note, draft) = try evaluatedInput(item)
            let submission = try TextSourcesContext.makeSubmission(notebook: note, target: draft,
                modelID: "local-qwen", modelRevision: "r1")
            #expect(submission.promptTemplate == .v2)
            let digest = SHA256.hash(data: Data(submission.request.prompt.utf8)).map { String(format: "%02x", $0) }.joined()
            #expect(digest == item.prompt_sha256, "Frozen evaluation case: \(item.id)")
            for (source, input) in zip(submission.sources, item.sources) {
                #expect(source.bytes == Data(input[1].utf8))
            }
        }
    }

    @Test("Citation labels enumerate excerpts, including several excerpts from one source")
    func sameSourceDifferentExcerpts() throws {
        let source = try TextSourceSnapshot(displayName: "作品.md", bytes: Data("中文👩‍💻\r\ne\u{0301}".utf8))
        let text = try source.validatedText()
        let first = try TextSourceExcerpt(source: source, range: (text as NSString).range(of: "中文👩‍💻"))
        let second = try TextSourceExcerpt(source: source, range: (text as NSString).range(of: "e\u{0301}"))
        let note = TextSourcesNotebook(question: "比较片段", sources: [source], excerpts: [second, first])
        let submission = try TextSourcesContext.makeSubmission(notebook: note, target: TextDraftDocument(text: "原稿"),
            modelID: "model", modelRevision: nil)
        #expect(submission.request.prompt.contains("本次可用标签：[S1]、[S2]。"))
        #expect(submission.request.prompt.contains("[S1] 资料名称：作品.md\n---资料片段开始---\ne\u{0301}\n"))
        #expect(submission.request.prompt.contains("[S2] 资料名称：作品.md\n---资料片段开始---\n中文👩‍💻\n"))
        #expect(submission.sources[0].bytes == source.bytes)
        #expect(TextSourcesContext.citations(in: "比较[S2]", submission: submission).validLabels == ["[S2]"])
    }

    @Test("Missing means legacy; null, wrong types, unknown versions and template mismatches are rejected")
    func invalidTemplateVersions() throws {
        let values: [Any] = [NSNull(), true, 2, "sources.v3", "sources.v2"]
        for value in values {
            let data = try changedLegacyTemplate(value)
            #expect(throws: TextSourcesError.self) { try TextSourcesArchive.decode(data) }
        }
        let explicit = try TextSourcesArchive.decode(changedLegacyTemplate("sources.v1"))
        #expect(explicit.records[0].submission.promptTemplate == .v1)
    }

    @Test("A legacy archive at the byte budget does not grow just because its template is now versioned")
    func legacyByteBudget() throws {
        var note = try TextSourcesArchive.decode(TextSourcesLegacyFixture.archive)
        let record = note.records[0]
        note.records[0] = .init(submission: record.submission, answer: "", completedAt: record.completedAt,
                                metrics: record.metrics, disposition: record.disposition)
        let overhead = try TextSourcesArchive.encode(note).count
        note.records[0] = .init(submission: record.submission,
                                answer: String(repeating: "a", count: TextSourcesLimits.archiveBytes - overhead),
                                completedAt: record.completedAt, metrics: record.metrics, disposition: record.disposition)
        let exact = try TextSourcesArchive.encode(note)
        #expect(exact.count == TextSourcesLimits.archiveBytes)
        let object = try #require(JSONSerialization.jsonObject(with: exact) as? [String: Any])
        let notebook = try #require(object["notebook"] as? [String: Any])
        let records = try #require(notebook["records"] as? [[String: Any]])
        let submission = try #require(records[0]["submission"] as? [String: Any])
        #expect(submission["promptTemplate"] == nil)
        #expect(try TextSourcesArchive.decode(exact) == note)
    }

    @Test("Legacy and v2 answers coexist through production save and cold reopen")
    func mixedHistoryProject() async throws {
        try await withLegacyProject { root in
            let store = try await ProjectStore.open(at: root)
            let snapshot = await store.snapshot()
            let draft = try #require(snapshot.activeDocument?.textDraft)
            var note = try #require(snapshot.activeDocument?.textSources)
            let legacy = try #require(note.records.first)
            let oldRevision = note.revision
            note.revision = UUID()
            let submission = try TextSourcesContext.makeSubmission(notebook: note, target: draft,
                modelID: legacy.submission.modelID, modelRevision: legacy.submission.modelRevision)
            note.records.append(.init(submission: submission, answer: "蓝桉、京都。[S1]"))
            _ = try await store.saveTextSources(note, documentID: draft.id, expectedRevision: oldRevision,
                expectedDocumentRevision: draft.revision)
            try await store.close()
            let reopened = try await ProjectStore.open(at: root)
            let actual = try #require(await reopened.snapshot().activeDocument?.textSources)
            #expect(actual == note)
            #expect(actual.records.map(\.submission.promptTemplate) == [.v1, .v2])
            #expect(actual.records[0] == legacy)
            #expect(actual.records[0].submission.request.prompt.utf8.elementsEqual(legacy.submission.request.prompt.utf8))
            #expect(await reopened.snapshot().activeDocument?.textDraft == draft)
            try await reopened.close()
        }
    }

    @Test("Unknown template in a project is rejected without touching its original manifest")
    func unreadableProjectProtected() async throws {
        try await withLegacyProject { root in
            var object = try #require(JSONSerialization.jsonObject(with: TextSourcesLegacyFixture.project) as? [String: Any])
            var documents = try #require(object["documents"] as? [[String: Any]])
            let index = try #require(documents.firstIndex { $0["textSources"] != nil })
            var note = try #require(documents[index]["textSources"] as? [String: Any])
            var records = try #require(note["records"] as? [[String: Any]])
            var submission = try #require(records[0]["submission"] as? [String: Any])
            submission["promptTemplate"] = "sources.future"
            records[0]["submission"] = submission; note["records"] = records
            documents[index]["textSources"] = note; object["documents"] = documents
            let damaged = try JSONSerialization.data(withJSONObject: object)
            let manifest = root.appendingPathComponent("project.json")
            try damaged.write(to: manifest)
            await #expect(throws: (any Error).self) { _ = try await ProjectStore.open(at: root) }
            #expect(try Data(contentsOf: manifest) == damaged)
        }
    }

    private struct EvaluatedCase: Decodable {
        let id: String
        let sources: [[String]]
        let question: String
        let prompt_sha256: String
    }

    private func evaluatedInput(_ item: EvaluatedCase) throws -> (TextSourcesNotebook, TextDraftDocument) {
        let sources = try item.sources.map { try TextSourceSnapshot(displayName: $0[0], bytes: Data($0[1].utf8)) }
        let excerpts = try sources.map { try TextSourceReader.excerpt(from: $0) }
        return (TextSourcesNotebook(question: item.question, sources: sources, excerpts: excerpts),
                try TextDraftDocument(text: "原稿", generationSettings: .init(maximumPromptTokens: 2048, maximumOutputTokens: 128)))
    }

    private func changedLegacyTemplate(_ value: Any) throws -> Data {
        var object = try #require(JSONSerialization.jsonObject(with: TextSourcesLegacyFixture.archive) as? [String: Any])
        var note = try #require(object["notebook"] as? [String: Any])
        var records = try #require(note["records"] as? [[String: Any]])
        var submission = try #require(records[0]["submission"] as? [String: Any])
        submission["promptTemplate"] = value
        records[0]["submission"] = submission; note["records"] = records; object["notebook"] = note
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func withLegacyProject(_ body: (URL) async throws -> Void) async throws {
        let base = ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        let root = base.appendingPathComponent("sources-legacy-\(UUID()).dproject")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["Tasks", "Audio"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try TextSourcesLegacyFixture.project.write(to: root.appendingPathComponent("project.json"), options: .withoutOverwriting)
        try await body(root)
    }
}
