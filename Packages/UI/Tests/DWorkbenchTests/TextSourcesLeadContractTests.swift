import DInference
import Foundation
import Testing
@testable import DWorkbench

struct TextSourcesLeadContractTests {
    @Test func historicalCountLimitsAlsoApplyAfterCurrentSourcesAreRemoved() throws {
        let sources = try (0..<9).map { try TextSourceSnapshot(displayName: "\($0).txt", bytes: Data("x".utf8)) }
        let excerpts = try [TextSourceReader.excerpt(from: sources[0])]
        let prompt = try TextSourcesContext.makePrompt(question: "question", sources: sources, excerpts: excerpts)
        let submission = TextSourcesSubmission(notebookRevision: UUID(), targetDocumentID: UUID(), targetDocumentRevision: UUID(),
            question: "question", sources: sources, excerpts: excerpts,
            request: TextRequest(prompt: prompt, maxTokens: 64, temperature: 0.2, topP: 0.95,
                execution: .init(profile: TextExecutionCapability.qwen2Profile, maximumPromptTokens: 2048)), modelID: "qwen", modelRevision: nil)
        let note = TextSourcesNotebook(records: [.init(submission: submission, answer: "x [S1]")])
        #expect(throws: (any Error).self) { try TextSourcesArchive.validate(note) }
    }

    @Test func whitespaceQuestionCannotBeSubmitted() throws {
        var (note, target) = try fixture(); note.question = " \n\t"
        #expect(throws: (any Error).self) {
            try TextSourcesContext.makeSubmission(notebook: note, target: target, modelID: "qwen", modelRevision: nil)
        }
    }

    private func fixture() throws -> (TextSourcesNotebook, TextDraftDocument) {
        let source = try TextSourceSnapshot(displayName: "资料👩‍💻.md", bytes: Data("代号蓝桉\r\ne\u{301}🎹".utf8))
        let excerpt = try TextSourceExcerpt(source: source, range: NSRange(location: 0, length: try source.validatedText().utf16.count))
        return (.init(question: "代号是什么？", sources: [source], excerpts: [excerpt]), try .init(text: "原文"))
    }

    @Test func historyMetricsAreValidatedAtProductionSaveBoundary() throws {
        var (note, target) = try fixture()
        let submission = try TextSourcesContext.makeSubmission(notebook: note, target: target, modelID: "qwen", modelRevision: "r1")
        for metrics in [["absolutePath": "/private/secret"], ["stopReason": String(repeating: "x", count: 513)]] {
            note.records = [.init(submission: submission, answer: "蓝桉 [S1]", metrics: metrics)]
            #expect(throws: (any Error).self) { try TextSourcesArchive.validate(note) }
        }
    }

    @Test func historicalDuplicateSourceAndExcerptIDsAreRejected() throws {
        var (note, target) = try fixture()
        let s = try TextSourcesContext.makeSubmission(notebook: note, target: target, modelID: "qwen", modelRevision: nil)
        for duplicates in [true, false] {
            let bad = TextSourcesSubmission(notebookRevision: s.notebookRevision, targetDocumentID: s.targetDocumentID,
                targetDocumentRevision: s.targetDocumentRevision, question: s.question,
                sources: duplicates ? s.sources + s.sources : s.sources,
                excerpts: duplicates ? s.excerpts : s.excerpts + s.excerpts, request: s.request,
                modelID: s.modelID, modelRevision: s.modelRevision)
            note.records = [.init(submission: bad, answer: "蓝桉 [S1]")]
            #expect(throws: (any Error).self) { try TextSourcesArchive.validate(note) }
        }
    }

    @Test func wholeNotebookBudgetAppliesToValidateNotOnlyEnvelopeEncode() throws {
        var (note, target) = try fixture()
        for _ in 0..<16 {
            let submission = try TextSourcesContext.makeSubmission(notebook: TextSourcesNotebook(question: note.question, sources: note.sources, excerpts: note.excerpts),
                target: target, modelID: "qwen", modelRevision: nil)
            note.records.append(.init(submission: submission, answer: String(repeating: "x", count: 600_000) + "[S1]"))
        }
        #expect(throws: (any Error).self) { try TextSourcesArchive.validate(note) }
    }

    @Test func onlyExactProvidedCitationLabelsAreRecognized() throws {
        let (note, target) = try fixture()
        let s = try TextSourcesContext.makeSubmission(notebook: note, target: target, modelID: "qwen", modelRevision: nil)
        for malformed in ["[S01]", "[Sbad]", "[S0]", "[S999999999999999999999999999999]"] {
            let result = TextSourcesContext.citations(in: "已知 [S1] 未知 " + malformed, submission: s)
            #expect(result.validLabels == ["[S1]"])
            #expect(result.invalidLabels.contains(malformed))
        }
    }

    @Test func floatSchemaCannotMasqueradeAsInteger() throws {
        let (note, _) = try fixture()
        let data = try TextSourcesArchive.encode(note)
        let string = try #require(String(data: data, encoding: .utf8))
        let bad = string.replacingOccurrences(of: "\"schema_version\":1", with: "\"schema_version\":1.0")
        #expect(bad != string)
        #expect(throws: (any Error).self) { try TextSourcesArchive.decode(Data(bad.utf8)) }
    }
}
