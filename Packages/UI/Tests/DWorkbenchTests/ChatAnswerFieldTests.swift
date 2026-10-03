import DInference
import Foundation
import Testing
@testable import DWorkbench

private actor FieldNoInference: InferenceEngine {
    private(set) var calls = 0
    func submit(_ request: InferenceRequest, backendID: String) async throws -> InferenceRun {
        calls += 1; throw WorkflowIssue("Field handoff cannot invoke a model")
    }
}
@Suite("Adopted structured answer handoff", .serialized) @MainActor
struct ChatAnswerFieldTests {
    @Test func fieldUsesAdoptedVersionAndKeepsTypedProvenanceAcrossCanvasAndBackup() async throws {
        let (root, store, chat, messageID) = try await fixture()
        let sessionID = try #require(chat.selectedSession?.id)
        let old = try ChatAnswerField(session: #require(chat.selectedSession), messageID: messageID, path: ["amount"])
        let first = try await chat.saveAnswerField(old)
        let firstRef = try #require(first.fields?["source"]?.assetReferences.first)
        #expect(first.fields?["value"] == .number(2, unit: "m"))
        let revision = try chat.adoptAnswer(messageID, text: #"{"amount":3,"enabled":false,"a.b":"新 é 🎨"}"#, sessionID: sessionID)
        let beforeStale = await store.snapshot()
        await #expect(throws: (any Error).self) { _ = try await chat.saveAnswerField(old) }
        #expect(await store.snapshot() == beforeStale)
        let field = try ChatAnswerField(session: #require(chat.selectedSession), messageID: messageID, path: ["a.b"])
        let id = UUID(), value = try await chat.saveAnswerField(field, assetID: id)
        #expect(value.fields?["value"] == .text("新 é 🎨"))
        #expect(try await chat.saveAnswerField(field, assetID: id) == value)
        let archive = try #require(try await store.workflowState().archive)
        let fieldRecord = try #require(archive.assets.first { $0.reference.assetID == id })
        #expect(fieldRecord.parents.first?.assetID == revision)
        #expect(fieldRecord.metadata["fieldPathJSON"] == #"["a.b"]"#)
        #expect(try await JSONDecoder().decode(WorkflowDatum.self, from: store.workflowData(firstRef)) == .number(2, unit: "m"))
        let engine = FieldNoInference()
        let runtime = WorkbenchSession(engine: engine, backendID: "fixture", status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) }, shutdown: {}, cleanup: {}, validateModel: { _ in })
        let canvas = WorkflowController(services: WorkflowServices(store: store, session: runtime, resolveModel: { _, _ in throw WorkflowIssue("No model") }))
        await canvas.load(); canvas.addBlankGraph()
        try await canvas.insertQuickValue(value, target: #require(canvas.canvasInsertionTarget()))
        #expect(canvas.graph?.nodes.last?.dataConfiguration?.value == value)
        #expect(await engine.calls == 0)
        try await canvas.close(); try await chat.prepareForBackup()
        let backup = root.appendingPathComponent("Fields.dbackup")
        _ = try await store.createBackup(at: backup)
        let restored = root.appendingPathComponent("Restored.dproject")
        _ = try await ProjectStore.restoreBackup(at: backup, to: restored)
        let copy = try await ProjectStore.open(at: restored)
        #expect(try await copy.workflowState().archive?.graphs.first?.nodes.last?.dataConfiguration?.value == value)
        #expect(try await copy.workflowData(firstRef) == store.workflowData(firstRef))
        let plan = try await chat.sessionBackupPlan(sessionID: sessionID)
        let projected = try #require(plan.files.first { $0.relativePath.hasPrefix("Workflows/") }?.data)
        #expect(try JSONDecoder().decode(WorkflowArchive.self, from: projected).assets.contains { $0.reference == firstRef })
        try await copy.close(); try await store.close()
    }
    @Test func cancelledHandoffDoesNotInsertEitherValueOrAsset() async throws {
        let (_, store, chat, messageID) = try await fixture()
        let field = try ChatAnswerField(session: #require(chat.selectedSession), messageID: messageID, path: ["amount"])
        let value = try await chat.saveAnswerField(field)
        let ref = try #require(value.fields?["source"]?.assetReferences.first)
        let engine = FieldNoInference()
        let runtime = WorkbenchSession(engine: engine, backendID: "fixture", status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) }, shutdown: {}, cleanup: {}, validateModel: { _ in })
        let canvas = WorkflowController(services: WorkflowServices(store: store, session: runtime, resolveModel: { _, _ in throw WorkflowIssue("No model") }))
        await canvas.load(); canvas.addBlankGraph()
        let target = try #require(canvas.canvasInsertionTarget()), before = canvas.graph
        for isValue in [true, false] {
            let task = Task { @MainActor in
                withUnsafeCurrentTask { $0?.cancel() }
                if isValue { try await canvas.insertQuickValue(value, target: target) }
                else { try await canvas.insertQuickResult(ref, target: target) }
            }
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(canvas.graph == before)
        }
        #expect(await engine.calls == 0)
        try await canvas.close(); try await store.close()
    }
    @Test func invalidAdoptionAndMissingFieldNeverUseOldReportOrPublish() async throws {
        let (_, store, chat, messageID) = try await fixture()
        let id = try #require(chat.selectedSession?.id)
        let before = await store.snapshot()
        #expect(throws: (any Error).self) { _ = try ChatAnswerField(session: #require(chat.selectedSession), messageID: messageID, path: ["missing"]) }
        _ = try chat.adoptAnswer(messageID, text: #"{"amount":"wrong","enabled":true,"a.b":"x"}"#, sessionID: id)
        #expect(throws: (any Error).self) { _ = try ChatAnswerField(session: #require(chat.selectedSession), messageID: messageID, path: ["amount"]) }
        #expect(await store.snapshot() == before)
        var session = try #require(chat.selectedSession)
        session.contextChoices = nil; session.attempts[0].outputFormat = .init(kind: .json)
        #expect(throws: (any Error).self) { _ = try ChatAnswerField(session: session, messageID: messageID, path: []) }
        try await store.close()
    }
    @Test func completeEnvelopeBudgetRejectsBeforePublishing() async throws {
        let (_, store, chat, messageID) = try await fixture()
        var schema = WorkflowDataSchema.text, text = "\"leaf\""
        for _ in 0..<24 { schema = .record([.init("x", schema)]); text = "{\"x\":" + text + "}" }
        let format = ChatOutputFormat(kind: .schema, schema: schema)
        #expect(format.check(text).status == .valid)
        var state = chat.state
        state.sessions[0].attempts[0].outputFormat = format
        state.sessions[0].attempts[0].rawText = text
        state.sessions[0].attempts[0].response = .init(rawText: text, finalText: text, finishReason: .stop)
        _ = try await store.saveChatState(state, expectedRevision: state.revision)
        let loaded = ChatController(store: store) { throw WorkflowIssue("No inference") }; await loaded.load()
        let field = try ChatAnswerField(session: #require(loaded.selectedSession), messageID: messageID, path: [])
        let before = await store.snapshot()
        await #expect(throws: (any Error).self) { _ = try await loaded.saveAnswerField(field) }
        #expect(await store.snapshot() == before)
        try await store.close()
    }
    @Test func selectionSavedForWorkflowKeepsCharacterRangeAndSourceVersion() async throws {
        let (_, store, chat, messageID) = try await fixture()
        let id = try #require(chat.selectedSession?.id)
        _ = try chat.adoptAnswer(messageID, text: "前 e\u{301} 👩🏽‍🎨 后", sessionID: id)
        let source = try chat.quoteSource(kind: .message, id: messageID, sessionID: id)
        let range = (source.text as NSString).range(of: "e\u{301} 👩🏽‍🎨")
        let quote = try ChatQuoteSelection(source: source, range: range)
        let saved = try await chat.saveQuote(quote, sessionID: id)
        #expect(try await store.workflowText(saved) == quote.text)
        let record = try #require(try await store.workflowState().archive?.assets.first { $0.reference == saved })
        #expect(record.metadata["sourceVersion"] == source.version && record.metadata["utf16Location"] == String(range.location))
        _ = try chat.adoptAnswer(messageID, text: "changed", sessionID: id)
        await #expect(throws: (any Error).self) { _ = try await chat.saveQuote(quote, sessionID: id) }
        #expect(try await store.workflowText(saved) == quote.text)
        try await store.close()
    }
    private func fixture() async throws -> (URL, ProjectStore, ChatController, UUID) {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory()).appendingPathComponent("AnswerField-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try await ProjectStore.create(at: root.appendingPathComponent("Original.dproject"), name: "Fields")
        var session = ChatSession(title: "Structured")
        let user = ChatMessage(parentID: nil, role: .user, text: "return typed record")
        let answer = ChatMessage(parentID: user.id, role: .assistant, text: "", attemptID: UUID())
        let text = #"{"amount":2,"enabled":true,"a.b":"original"}"#
        let output = try await store.publishWorkflowAsset(data: Data(text.utf8), mediaType: "text/plain", name: "fixture response", operationID: "fixture").record.reference
        var node = try #require(WorkflowRegistry.standard.operation(WorkflowModelRoutes.qwen35)?.definition.makeNode())
        node.parameters["modelID"] = .text("text:fixture")
        node.parameters["messagesJSON"] = .text("[]")
        var attempt = ChatAttempt(id: try #require(answer.attemptID), sessionID: session.id, userMessageID: user.id, assistantMessageID: answer.id,
            node: node, messagesJSON: "[]", inputs: [:], systemPrompt: "", status: .completed)
        attempt.rawText = text; attempt.output = output
        attempt.response = .init(rawText: text, finalText: text, finishReason: .stop)
        attempt.outputFormat = .init(kind: .schema, schema: .record([.init("amount", .number(unit: "m")), .init("enabled", .boolean), .init("a.b", .text)]))
        session.messages = [user, answer]; session.attempts = [attempt]; session.selectedLeafID = answer.id
        var state = ChatState(); state.sessions = [session]; state.selectedSessionID = session.id
        _ = try await store.saveChatState(state, expectedRevision: 0)
        let chat = ChatController(store: store) { throw WorkflowIssue("No model") }; await chat.load()
        return (root, store, chat, answer.id)
    }
}
