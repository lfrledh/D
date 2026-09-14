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
}
