import DInference
import Foundation
import Testing
@testable import DWorkbench

/// Explicitly enabled offline fixture preparation; no model inference or downloads here.
struct TextSourcesRealEvidenceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["D_TS_REAL_OUTPUT"] != nil))
    func verifiedModelAndProductionContextForExistingCLI() async throws {
        let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["D_TS_REAL_OUTPUT"]))
        let model = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["D_TEST_TEXT_MODEL"]))
        let verified = try await TextModelProfiles.verify(at: model)
        let profile = try #require(try TextModelProfiles.profile(forRevision: verified.revision))
        #expect(verified.revision == profile.revision)
        let source = try TextSourceSnapshot(displayName: "研究记录 👩‍💻.md", bytes: Data("项目代号是蓝桉。会议地点是京都。资料没有说明预算、参与人数或日期。".utf8))
        let excerpt = try TextSourceReader.excerpt(from: source)
        let target = try TextDraftDocument(text: "原始研究草稿", generationSettings: .init(maximumPromptTokens: 2048, maximumOutputTokens: 128))
        for (name, question) in [("answered", "项目的代号和会议地点是什么？请引用资料。"), ("unsupported", "项目预算具体是多少日元？如果资料没说明，请明确说资料未提供，不要猜测。请标明引用。") ] {
            let dir = output.appendingPathComponent(name)
            #expect(!FileManager.default.fileExists(atPath: dir.path))
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let note = TextSourcesNotebook(question: question, sources: [source], excerpts: [excerpt])
            let submission = try TextSourcesContext.makeSubmission(notebook: note, target: target,
                modelID: "registered:" + profile.id.replacingOccurrences(of: "/", with: ":"), modelRevision: verified.revision)
            try source.bytes.write(to: dir.appendingPathComponent("source.md"), options: .withoutOverwriting)
            try Data(submission.request.prompt.utf8).write(to: dir.appendingPathComponent("prompt.txt"), options: .withoutOverwriting)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(submission).write(to: dir.appendingPathComponent("submission.json"), options: .withoutOverwriting)
            try encoder.encode(target).write(to: dir.appendingPathComponent("target.json"), options: .withoutOverwriting)
            try TextSourcesArchive.encode(note).write(to: dir.appendingPathComponent("notebook.json"), options: .withoutOverwriting)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["D_TS_REAL_REPORTS"] != nil))
    func actualCLIAnswersPersistWithExactSubmittedContext() async throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["D_TS_REAL_REPORTS"]))
        for name in ["answered", "unsupported"] {
            let dir = root.appendingPathComponent(name)
            let submission = try JSONDecoder().decode(TextSourcesSubmission.self, from: Data(contentsOf: dir.appendingPathComponent("submission.json")))
            let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("cli-report.json"))) as? [String: Any])
            let runs = try #require(object["runs"] as? [[String: Any]])
            #expect(runs.count == 1)
            let run = try #require(runs.first)
            #expect(run["outcome"] as? String == "completed")
            let requestObject = try #require(run["request"] as? [String: Any])
            let request = try JSONDecoder().decode(InferenceRequest.self, from: JSONSerialization.data(withJSONObject: requestObject))
            guard case .text(let actual) = request.input else { Issue.record("Expected actual CLI text input"); return }
            #expect(actual == submission.request)
            #expect(actual.prompt.utf8.elementsEqual(submission.request.prompt.utf8))
            #expect(request.model.revision == submission.modelRevision)
            let answer = try #require(run["text"] as? String)
            #expect(!answer.isEmpty)
            let check = TextSourcesContext.citations(in: answer, submission: submission)
            let summary: [String: Any] = ["valid": check.validLabels, "invalid": check.invalidLabels, "summary": check.summary,
                "semantic_quality": "manual review of actual answer required; citation syntax does not establish truth"]
            try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
                .write(to: dir.appendingPathComponent("citation-assessment.json"), options: .withoutOverwriting)
            let store = try await ProjectStore.create(at: dir.appendingPathComponent("actual-answer.dproject"), name: "真实回答记录")
            let manifest = try await store.createTextDocument(text: "原稿")
            let target = try #require(manifest.activeDocument?.textDraft)
            // This import binds the real CLI input/answer to a new project document; it is not a GUI generation claim.
            let rebound = TextSourcesSubmission(id: submission.id, notebookRevision: submission.notebookRevision,
                targetDocumentID: target.id, targetDocumentRevision: target.revision, question: submission.question,
                sources: submission.sources, excerpts: submission.excerpts, request: submission.request,
                modelID: submission.modelID, modelRevision: submission.modelRevision)
            let note = TextSourcesNotebook(inputRevision: submission.notebookRevision, question: submission.question,
                sources: submission.sources, excerpts: submission.excerpts, records: [.init(submission: rebound, answer: answer)])
            _ = try await store.saveTextSources(note, documentID: target.id,
                expectedRevision: try #require(manifest.activeDocument?.textSources?.revision), expectedDocumentRevision: target.revision)
            try await store.close()
            let reopened = try await ProjectStore.open(at: dir.appendingPathComponent("actual-answer.dproject"))
            #expect(await reopened.snapshot().activeDocument?.textSources == note)
            #expect(await reopened.snapshot().activeDocument?.textDraft == target)
            try await reopened.close()
        }
    }
}
