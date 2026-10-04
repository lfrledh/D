import DInference
import DRuntime
import Foundation
import Testing
@testable import DWorkbench

private actor FastTextBackend: InferenceBackend {
    nonisolated let descriptor = BackendDescriptor(id: "fast-text", version: "fixture", capabilities: [.textGeneration])
    let deltas: [String]
    private(set) var released = false
    init(deltas: [String]) { self.deltas = deltas }
    func estimate(_ request: InferenceRequest) async throws -> ResourceEstimate { .init(peakBytes: 1) }
    func execute(_ request: InferenceRequest, emit: @escaping @Sendable (InferenceOutput) async throws -> Void) async throws -> InferenceResult {
        for delta in deltas { try await emit(.textDelta(delta)) }
        let text = deltas.joined()
        return .init(textResponse: .init(rawText: text, finalText: text, finishReason: .stop))
    }
    func release() async { released = true }
}

private actor StagedTextBackend: InferenceBackend {
    nonisolated let descriptor = BackendDescriptor(id: "staged-text", version: "fixture", capabilities: [.textGeneration])
    private var observed: Set<String> = []
    private(set) var released = false
    func saw(_ value: String) { observed.insert(value) }
    func estimate(_ request: InferenceRequest) async throws -> ResourceEstimate { .init(peakBytes: 1) }
    private func waitForDisplay(_ fragment: String) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !observed.contains(where: { $0.contains(fragment) }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    func execute(_ request: InferenceRequest, emit: @escaping @Sendable (InferenceOutput) async throws -> Void) async throws -> InferenceResult {
        // No token or progress has been produced yet: stage polling must still run.
        try await waitForDisplay("Loading fixture")
        try await emit(.progress(completed: 1, total: 30))
        try await waitForDisplay("1/30")
        try await emit(.progress(completed: 2, total: 30))
        try await waitForDisplay("2/30")
        try await emit(.textDelta("完整回答"))
        return .init(textResponse: .init(rawText: "完整回答", finalText: "完整回答", finishReason: .stop))
    }
    func release() async { released = true }
}

@Suite("Authoritative stream collector", .timeLimit(.minutes(1)))
struct WorkflowEventCollectorTests {
    @Test @MainActor func actualServiceCoalescesDisplayWithoutLosingUnicode() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent("Stream-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try await ProjectStore.create(at: root.appendingPathComponent("Stream.dproject"), name: "Stream")
        let deltas = (0..<2_048).map { "\($0):中e\u{301}👩🏽‍💻\n" }
        let backend = FastTextBackend(deltas: deltas)
        let runtime = try InferenceRuntime(backends: [backend], configuration: .init(memoryBudgetBytes: 1_024, eventBufferCapacity: 2))
        let session = WorkbenchSession(engine: runtime, backendID: "fast-text", status: {
            .init(activeRunID: nil, phase: nil, queuedRunIDs: [])
        }, shutdown: { await runtime.shutdown() }, cleanup: {}, validateModel: { _ in }, textBackendID: "fast-text")
        let service = WorkflowServices(store: store, session: session) { _, identity in
            .init(identity: identity, reference: .init(directory: root, revision: "fixture"),
                backendID: "fast-text", operationID: WorkflowModelRoutes.qwen35,
                textCapability: .init(maximumPromptTokens: 8_192, maximumOutputTokens: 4_096,
                    profile: TextExecutionCapability.qwen35VLMProfile))
        }
        var node = try #require(WorkflowRegistry.standard.operation(WorkflowModelRoutes.qwen35)?.definition.makeNode())
        node.parameters["modelID"] = .text("fixture"); node.parameters["task"] = .text("Full answer")
        let step = UUID()
        var publications = 0, latest = "", lastNonempty = ""
        service.languagePreviewChanged = { owner, text in
            #expect(owner == step)
            latest = text; publications += 1
            if !text.isEmpty { lastNonempty = text }
            // Real MainActor callback deliberately takes time; collector has its own actor.
            Thread.sleep(forTimeInterval: 0.03)
        }
        try service.beginPlan()
        let result = try await service.executeCall(.init(node: node, stepID: step, inputs: [:]))
        guard case .outputs(let outputs) = result, let reference = outputs["raw"]?.asset else {
            Issue.record("Missing published answer"); return
        }
        #expect(lastNonempty == deltas.joined())
        #expect(latest.isEmpty) // Published result replaces the transient preview.
        #expect(try await store.workflowText(reference) == deltas.joined())
        #expect(publications < deltas.count / 4)
        #expect(await backend.released)
        #expect(await runtime.snapshot().activeRunID == nil)
        print("S00 collector: deltas=\(deltas.count), display=\(publications), bytes=\(lastNonempty.utf8.count)")
        try await store.close()
    }

    @Test @MainActor func stageBeforeFirstDeltaAndNumericProgressBothReachTheActualService() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent("Stages-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try await ProjectStore.create(at: root.appendingPathComponent("Stages.dproject"), name: "Stages")
        let backend = StagedTextBackend()
        let runtime = try InferenceRuntime(backends: [backend], configuration: .init(memoryBudgetBytes: 1_024))
        let session = WorkbenchSession(engine: runtime, backendID: "staged-text", status: {
            let current = await runtime.snapshot()
            return .init(activeRunID: current.activeRunID, phase: "Loading fixture", queuedRunIDs: [])
        }, shutdown: { await runtime.shutdown() }, cleanup: {}, validateModel: { _ in }, textBackendID: "staged-text")
        let service = WorkflowServices(store: store, session: session) { _, identity in
            .init(identity: identity, reference: .init(directory: root, revision: "fixture"),
                backendID: "staged-text", operationID: WorkflowModelRoutes.qwen35,
                textCapability: .init(maximumPromptTokens: 8_192, maximumOutputTokens: 4_096,
                    profile: TextExecutionCapability.qwen35VLMProfile))
        }
        var seen: [String] = []
        service.progress = { value in seen.append(value); Task { await backend.saw(value) } }
        var node = try #require(WorkflowRegistry.standard.operation(WorkflowModelRoutes.qwen35)?.definition.makeNode())
        node.parameters["modelID"] = .text("fixture"); node.parameters["task"] = .text("Answer")
        try service.beginPlan()
        _ = try await service.executeCall(.init(node: node, stepID: UUID(), inputs: [:]))
        #expect(seen.contains("Loading fixture"))
        #expect(seen.contains { $0.contains("Loading fixture") && $0.contains("1/30") })
        #expect(seen.contains { $0.contains("Loading fixture") && $0.contains("2/30") })
        #expect(await backend.released)
        #expect(await runtime.snapshot().activeRunID == nil)
        try await store.close()
    }

    @Test func budgetFailurePreservesAcceptedPrefix() async throws {
        let stream = AsyncThrowingStream<InferenceOutput, Error> { continuation in
            continuation.yield(.textDelta("abc")); continuation.yield(.textDelta("too much")); continuation.finish()
        }
        let collector = WorkflowEventCollector(maximumBytes: 3)
        let run = InferenceRun(id: UUID(), events: stream, cancel: {}, outcome: { .cancelled })
        #expect(await collector.consume(run) != nil)
        #expect(await collector.snapshot().text == "abc")
        #expect(await collector.snapshot().byteCount == 3)
    }
}
