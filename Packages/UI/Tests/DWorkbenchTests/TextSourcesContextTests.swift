import DInference
import Foundation
import Testing
@testable import DWorkbench

struct TextSourcesContextTests {
    private func fixture() throws -> (TextSourcesNotebook, TextDraftDocument) {
        let source = try TextSourceSnapshot(displayName: "notes-👩‍💻.md", bytes: Data("alpha\r\nbeta".utf8))
        let excerpt = try TextSourceExcerpt(source: source, range: NSRange(location: 0, length: 5))
        let notebook = TextSourcesNotebook(question: "What is present?", sources: [source], excerpts: [excerpt])
        let settings = TextGenerationSettings(maximumPromptTokens: 512, maximumOutputTokens: 64,
                                              profile: TextExecutionCapability.qwen2Profile)
        return (notebook, try TextDraftDocument(text: "draft", generationSettings: settings))
    }

    @Test func submissionFreezesInputRevisionAndBuildsCitedPrompt() throws {
        let (notebook, target) = try fixture()
        let submission = try TextSourcesContext.makeSubmission(notebook: notebook, target: target,
                                                                modelID: "local-qwen", modelRevision: "r1")
        #expect(submission.notebookRevision == notebook.inputRevision)
        #expect(submission.request.temperature == 0.2)
        #expect(submission.request.topP == 0.95)
        #expect(submission.request.prompt.contains("[S1]"))
        #expect(submission.request.prompt.contains("alpha"))
    }

    @Test func citationsDistinguishKnownUnknownAndAbsentLabels() throws {
        let (notebook, target) = try fixture()
        let submission = try TextSourcesContext.makeSubmission(notebook: notebook, target: target,
                                                                modelID: "local-qwen", modelRevision: nil)
        let mixed = TextSourcesContext.citations(in: "yes [S1], no [S2]", submission: submission)
        #expect(mixed.validLabels == ["[S1]"])
        #expect(mixed.invalidLabels == ["[S2]"])
        let absent = TextSourcesContext.citations(in: "no citation", submission: submission)
        #expect(absent.summary.contains("未验证"))
    }

    @Test func archiveRoundTripsAndRejectsBooleanSchemaVersion() throws {
        let (notebook, target) = try fixture()
        let submission = try TextSourcesContext.makeSubmission(notebook: notebook, target: target,
                                                                modelID: "local-qwen", modelRevision: "r1")
        var stored = notebook
        stored.records = [TextSourceAnswerRecord(submission: submission, answer: "alpha [S1]")]
        let encoded = try TextSourcesArchive.encode(stored)
        #expect(try TextSourcesArchive.decode(encoded) == stored)
        let invalid = Data("{\"schema_version\":true,\"notebook\":{}}".utf8)
        #expect(throws: TextSourcesError.self) { try TextSourcesArchive.decode(invalid) }
    }

    @Test func archiveRejectsPromptTamperingAndMissingSource() throws {
        let (notebook, target) = try fixture()
        let submission = try TextSourcesContext.makeSubmission(notebook: notebook, target: target,
                                                                modelID: "local-qwen", modelRevision: "r1")
        let changedRequest = TextRequest(prompt: "different", maxTokens: submission.request.maxTokens,
                                         temperature: 0.2, topP: 0.95, execution: submission.request.execution)
        let changed = TextSourcesSubmission(notebookRevision: submission.notebookRevision,
                                             targetDocumentID: submission.targetDocumentID,
                                             targetDocumentRevision: submission.targetDocumentRevision,
                                             question: submission.question, sources: submission.sources,
                                             excerpts: submission.excerpts, request: changedRequest,
                                             modelID: submission.modelID, modelRevision: submission.modelRevision)
        var stored = notebook
        stored.records = [TextSourceAnswerRecord(submission: changed, answer: "answer")]
        #expect(throws: TextSourcesError.self) { try TextSourcesArchive.validate(stored) }
        stored.records = []
        stored.excerpts = [try TextSourceExcerpt(source: submission.sources[0], range: NSRange(location: 0, length: 5))]
        stored.sources = []
        #expect(throws: TextSourcesError.self) { try TextSourcesArchive.validate(stored) }
    }

    @Test func citationsRejectMalformedLabelsAndHandleEmptySubmission() throws {
        let (notebook, target) = try fixture()
        let submission = try TextSourcesContext.makeSubmission(notebook: notebook, target: target,
                                                                modelID: "local-qwen", modelRevision: nil)
        let checked = TextSourcesContext.citations(in: "[S1] [S01] [Sbad] [S0] [S]", submission: submission)
        #expect(checked.validLabels == ["[S1]"])
        #expect(checked.invalidLabels == ["[S01]", "[Sbad]", "[S0]", "[S]"])
        let empty = TextSourcesSubmission(notebookRevision: UUID(), targetDocumentID: UUID(),
                                          targetDocumentRevision: UUID(), question: "", sources: [], excerpts: [],
                                          request: TextRequest(prompt: "", maxTokens: 1), modelID: "model", modelRevision: nil)
        let emptyResult = TextSourcesContext.citations(in: "[S1]", submission: empty)
        #expect(emptyResult.validLabels.isEmpty)
        #expect(emptyResult.invalidLabels == ["[S1]"])
    }

    @Test func archiveRejectsHistoricalCorruptionMetricsAndWholeNotebookOverflow() throws {
        var (notebook, target) = try fixture()
        let submission = try TextSourcesContext.makeSubmission(notebook: notebook, target: target,
                                                                modelID: "local-qwen", modelRevision: "r1")
        notebook.records = [.init(submission: submission, answer: "answer", metrics: ["unknown": "value"])]
        #expect(throws: TextSourcesError.self) { try TextSourcesArchive.validate(notebook) }

        let altered = try TextSourceSnapshot(id: submission.sources[0].id, revision: UUID(),
                                              displayName: submission.sources[0].displayName,
                                              bytes: submission.sources[0].bytes)
        let corrupt = TextSourcesSubmission(notebookRevision: submission.notebookRevision,
                                             targetDocumentID: submission.targetDocumentID,
                                             targetDocumentRevision: submission.targetDocumentRevision,
                                             question: submission.question, sources: [altered], excerpts: submission.excerpts,
                                             request: submission.request, modelID: submission.modelID,
                                             modelRevision: submission.modelRevision)
        notebook.records = [.init(submission: corrupt, answer: "answer")]
        #expect(throws: TextSourcesError.self) { try TextSourcesArchive.validate(notebook) }

        notebook.records = Array(repeating: TextSourceAnswerRecord(submission: submission, answer: "answer"),
                                 count: TextSourcesLimits.records + 1)
        #expect(throws: TextSourcesError.self) { try TextSourcesArchive.validate(notebook) }

        let submissions = try (0..<TextSourcesLimits.records).map { _ in
            try TextSourcesContext.makeSubmission(notebook: TextSourcesNotebook(question: notebook.question,
                                                                                  sources: notebook.sources,
                                                                                  excerpts: notebook.excerpts),
                                                   target: target, modelID: "local-qwen", modelRevision: "r1")
        }
        notebook.records = submissions.map { .init(submission: $0, answer: String(repeating: "x", count: 600_000)) }
        #expect(throws: TextSourcesError.self) { try TextSourcesArchive.validate(notebook) }
    }

    @Test func rejectsWhitespaceSubmissionAndHistoricalSourceCountOverflow() throws {
        var (notebook, target) = try fixture()
        notebook.question = " \n\t"
        #expect(throws: TextSourcesError.self) {
            try TextSourcesContext.makeSubmission(notebook: notebook, target: target, modelID: "local-qwen", modelRevision: nil)
        }

        let sources = try (0..<TextSourcesLimits.sources + 1).map {
            try TextSourceSnapshot(displayName: "\($0).txt", bytes: Data("x".utf8))
        }
        let excerpt = try TextSourceExcerpt(source: sources[0], range: NSRange(location: 0, length: 1))
        let prompt = try TextSourcesContext.makePrompt(question: "q", sources: sources, excerpts: [excerpt])
        let historical = TextSourcesSubmission(notebookRevision: UUID(), targetDocumentID: UUID(),
                                               targetDocumentRevision: UUID(), question: "q", sources: sources,
                                               excerpts: [excerpt], request: TextRequest(prompt: prompt, maxTokens: 1,
                                               temperature: 0.2, topP: 0.95,
                                               execution: .init(profile: TextExecutionCapability.qwen2Profile,
                                                                maximumPromptTokens: 1)),
                                               modelID: "local-qwen", modelRevision: nil)
        #expect(throws: TextSourcesError.self) {
            try TextSourcesArchive.validate(TextSourcesNotebook(records: [.init(submission: historical, answer: "x")]))
        }
    }

    @Test func citationScannerDoesNotTreatUnclosedOrRepeatedMalformedInputAsValid() throws {
        let empty = TextSourcesSubmission(notebookRevision: UUID(), targetDocumentID: UUID(),
                                          targetDocumentRevision: UUID(), question: "", sources: [], excerpts: [],
                                          request: TextRequest(prompt: "", maxTokens: 1), modelID: "model", modelRevision: nil)
        let result = TextSourcesContext.citations(in: String(repeating: "[S", count: 2_048), submission: empty)
        #expect(result.validLabels.isEmpty)
        #expect(result.invalidLabels.isEmpty)
    }
}
