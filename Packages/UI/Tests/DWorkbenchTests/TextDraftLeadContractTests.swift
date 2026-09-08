import DInference
import Foundation
import Testing
@testable import DWorkbench

private enum TextLeadFixtureError: Error { case failedStream }
private actor TextLeadFixtureEngine: InferenceEngine {
    private(set) var cancellations = 0
    func submit(_ request: InferenceRequest, backendID: String) async throws -> InferenceRun {
        let stream = AsyncThrowingStream<InferenceOutput, Error> { $0.finish(throwing: TextLeadFixtureError.failedStream) }
        return InferenceRun(id: request.id, events: stream, cancel: { await self.cancelled() }, outcome: { .completed(.init()) })
    }
    private func cancelled() { cancellations += 1 }
}

@Suite("TextDraft Lead contract", .serialized) @MainActor
struct TextDraftLeadContractTests {
    @Test(arguments: ["1.0", "1e0"])
    func fractionalAndExponentVersionsAreNotIntegerTokens(_ token: String) throws {
        let data = try TextDraftArchive.encode(TextDraftDocument(text: "original"))
        let original = String(decoding: data, as: UTF8.self)
        try #require(original.contains("\"schema_version\":1"))
        let malformed = Data(original.replacingOccurrences(of: "\"schema_version\":1", with: "\"schema_version\":" + token).utf8)
        #expect(throws: Error.self) { try TextDraftArchive.decode(malformed) }
    }
    @Test func visuallyEquivalentEditStillPreservesAuthorsActualUnicode() throws {
        let draft = try TextDraftDocument(text: "é")
        let session = TextDraftSession(document: draft, engine: TextLeadFixtureEngine(), backendID: "fixture")
        let edited = "e\u{301}"
        try session.editText(edited)
        #expect(Array(session.document.text.utf8) == Array(edited.utf8))
        #expect(session.document.revision != draft.revision)
    }
    @Test func streamFailureRequestsCancellationBeforeCompletion() async throws {
        let engine = TextLeadFixtureEngine()
        let session = TextDraftSession(document: try TextDraftDocument(text: "draft"), engine: engine, backendID: "fixture")
        await #expect(throws: Error.self) {
            try await session.requestRewrite(selection: session.selection(inUTF16: NSRange(location: 0, length: 5)), instruction: "revise", model: ModelReference(directory: URL(fileURLWithPath: "/declared/model")))
        }
        #expect(await engine.cancellations > 0)
        #expect(!session.isRunning)
        #expect(session.candidate == nil)
    }
    @Test func byteArchiveSavedInOwnedDirectoryReopensExactly() throws {
        let base = try #require(ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"])
        let directory = URL(fileURLWithPath: base).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("草稿.dtext.json")
        let original = try TextDraftDocument(text: "保留原声 e\u{301} 👩‍💻")
        try TextDraftArchive.encode(original).write(to: file, options: .withoutOverwriting)
        let reopened = try TextDraftArchive.decode(Data(contentsOf: file))
        #expect(reopened.id == original.id && reopened.revision == original.revision)
        #expect(Array(reopened.text.utf8) == Array(original.text.utf8))
    }
}
