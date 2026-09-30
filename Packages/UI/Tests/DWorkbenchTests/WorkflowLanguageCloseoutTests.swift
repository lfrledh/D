import Foundation
import DInference
import Testing
@testable import DWorkbench

@Suite("VLM shared form and response closeout")
struct WorkflowLanguageCloseoutTests {
    @Test func orderedMediaAndRoleFormPreservesMeaningAndRejectsUnusedInputs() throws {
        let image = TextImageReference(url: URL(fileURLWithPath: "/fixture/a.png"), width: 1, height: 1,
                                      byteCount: 3, contentSHA256: String(repeating: "a", count: 64))
        let json = #"[{"role":"system","parts":[{"type":"text","text":"Keep roles"}]},{"role":"user","parts":[{"type":"text","text":"before"},{"type":"image","index":0},{"type":"text","text":"after"}]}]"#
        let messages = try #require(WorkflowLanguageMessageForm.messages(json, images: [image], videos: []))
        #expect(messages.map(\.role) == [.system, .user])
        #expect(messages[1].parts == [.text("before"), .image(image), .text("after")])
        #expect(throws: (any Error).self) { try WorkflowLanguageMessageForm.messages(json, images: [], videos: []) }
        #expect(throws: (any Error).self) { try WorkflowLanguageMessageForm.messages(#"[{"role":"user","parts":[{"type":"text","text":"missing"}]}]"#, images: [image], videos: []) }
        #expect(throws: (any Error).self) { try WorkflowLanguageMessageForm.messages(#"[{"role":"user","content":"silently lost","parts":[{"type":"text","text":"known"}]}]"#, images: [], videos: []) }
    }
    @Test func optionalFormsDoNotMutateOldNodeAndSeedIsLossless() throws {
        let registry = WorkflowRegistry.standard
        var node = try #require(registry.operation(WorkflowModelRoutes.qwen35)?.definition.makeNode())
        for key in WorkflowLanguageMessageForm.optionalFields { node.parameters.removeValue(forKey: key) }
        let before = node
        try registry.validate(node)
        #expect(node == before)
        #expect(try WorkflowLanguageMessageForm.seed(["seed": .text(String(UInt64.max))]) == UInt64.max)
        #expect(throws: (any Error).self) { try WorkflowLanguageMessageForm.seed(["seed": .text("1e3")]) }
        #expect(try WorkflowLanguageMessageForm.thinking([:]) == nil)
        #expect(try WorkflowLanguageMessageForm.thinking(["thinking": .text("off")])?.enableThinking == false)
    }
    @Test @MainActor func explicitDirectoryReplacesOnlyItsInstallationBinding() throws {
        let suite = "D-closeout-model-binding-" + UUID().uuidString
        let settings = try #require(UserDefaults(suiteName: suite))
        defer { settings.removePersistentDomain(forName: suite) }
        let store = WorkflowModelBookmarks(settings: settings)
        let first = ModelID(rawValue: UUID()), second = ModelID(rawValue: UUID())
        try store.rememberInstallation(identity: "image:first", id: first)
        try store.rememberInstallation(identity: "text:second", id: second)
        try store.remember(identity: "image:first", kind: .image, name: "Explicit", bookmark: Data([1, 2, 3]))
        #expect(try store.installation(for: "image:first") == nil)
        #expect(try store.installation(for: "text:second") == second)
        #expect(try WorkflowModelBookmarks(settings: settings).entries().first?.name == "Explicit")
    }
}

private actor CloseoutResponseEngine: InferenceEngine {
    let response: TextResponse
    var calls = 0
    var action: (@Sendable () async throws -> Void)?
    init(_ response: TextResponse) { self.response = response }
    func beforeReturn(_ value: @escaping @Sendable () async throws -> Void) { action = value }
    func submit(_ request: InferenceRequest, backendID: String) async throws -> InferenceRun {
        calls += 1; try await action?()
        let response = response
        return .init(id: request.id, events: AsyncThrowingStream { stream in
            if let text = response.finalText { stream.yield(.textDelta(text)) }; stream.finish()
        }, cancel: {}, outcome: { .completed(.init(textResponse: response)) })
    }
}

@MainActor extension WorkflowLanguageCloseoutTests {
    @Test func longResponsePublishesOnceSurvivesOutputFailureReopenAndCopy() async throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"]))
            .appendingPathComponent("response-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await ProjectStore.create(at: root.appendingPathComponent("original.dproject"), name: "response")
        let long = String(repeating: "思考\"\n", count: 270_000)
        let response = TextResponse(rawText: long + "ok", reasoningText: long, finalText: "ok", finishReason: .stop)
        let engine = CloseoutResponseEngine(response)
        let session = WorkbenchSession(engine: engine, backendID: "fixture", status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) }, shutdown: {}, cleanup: {}, validateModel: { _ in })
        let service = WorkflowServices(store: store, session: session) { _, identity in
            .init(identity: identity, reference: .init(directory: root), backendID: "fixture", operationID: WorkflowModelRoutes.qwen35,
                  textCapability: .init(maximumPromptTokens: 2048, maximumOutputTokens: 256, profile: .qwen35VLMProfile))
        }
        var node = try #require(WorkflowRegistry.standard.operation(WorkflowModelRoutes.qwen35)?.definition.makeNode())
        node.parameters["modelID"] = .text("text:fixture"); node.parameters["outputMode"] = .text("response")
        try service.beginPlan()
        var retained: WorkflowAssetReference?
        do { _ = try await service.executeCall(.init(node: node, stepID: UUID(), inputs: [:])); Issue.record("Long reasoning must fail datum budget after durable publication") }
        catch let failure as WorkflowOutputValidationFailure { retained = failure.raw }
        let ref = try #require(retained)
        #expect(!service.hasPendingSaves)
        #expect(await engine.calls == 1)
        #expect(try await service.readLanguageResponse(ref) == response)
        #expect(try await service.readText(ref) == response.rawText)
        let bytes = try await store.workflowData(ref)
        #expect(bytes.count > 1_048_576)
        let snapshot = try #require(try await store.workflowState().archive)
        #expect(snapshot.assets.first?.metadata["textResponse.v1"] == nil)
        #expect(try JSONEncoder().encode(snapshot).count < 64 * 1024)
        node.parameters["outputMode"] = .text("text")
        #expect(try await WorkflowLanguageOperations.outputs(raw: ref, node: node, services: service)["output"] == .data(.text("ok")))
        try await store.close()
        let reopened = try await ProjectStore.open(at: store.rootURL)
        #expect(try await reopened.workflowData(ref) == bytes)
        #expect(try await reopened.workflowText(ref) == response.rawText)
        let destination = try await ProjectStore.create(at: root.appendingPathComponent("copy.dproject"), name: "copy")
        let copied = try await destination.copyWorkflowAsset(ref, from: reopened)
        #expect(try await destination.workflowData(copied) == bytes)
        #expect(try await destination.workflowTextResponse(copied) == response)
        try await destination.close(); try await reopened.close()
    }
    @Test func legacyMetadataResponseStillReadsAndDoesNotExecuteTools() async throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"]))
            .appendingPathComponent("old-response-" + UUID().uuidString + ".dproject")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await ProjectStore.create(at: root, name: "legacy response")
        let response = TextResponse(rawText: "preamble<tool_call>untrusted</tool_call>", finalText: "preamble", toolCalls: [.init(id: "call_1", name: "no_execute", arguments: [:])], finishReason: .toolCalls)
        let ref = try await store.publishWorkflowAsset(data: Data(response.rawText.utf8), mediaType: "text/plain", name: "old", operationID: "fixture",
            details: ["textResponse.v1": String(decoding: JSONEncoder().encode(response), as: UTF8.self)]).record.reference
        let engine = CloseoutResponseEngine(response)
        let session = WorkbenchSession(engine: engine, backendID: "fixture", status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) }, shutdown: {}, cleanup: {}, validateModel: { _ in })
        let service = WorkflowServices(store: store, session: session) { _, _ in throw WorkflowIssue("No loading") }
        var node = try #require(WorkflowRegistry.standard.operation(WorkflowModelRoutes.qwen35)?.definition.makeNode())
        do { _ = try await WorkflowLanguageOperations.outputs(raw: ref, node: node, services: service); Issue.record("Tool preamble cannot become final text") }
        catch let error as WorkflowOutputValidationFailure { #expect(error.raw == ref) }
        node.parameters["outputMode"] = .text("response")
        let result = try await WorkflowLanguageOperations.outputs(raw: ref, node: node, services: service)
        #expect(result["raw"] == .asset(ref))
        #expect(await engine.calls == 0)
        try await store.close()
    }
}
