import DInference
import DRuntime
import Foundation
import Testing
@testable import DWorkbench

private actor MemoryRecordBackend: InferenceExecutionPlanning {
    nonisolated let descriptor = BackendDescriptor(id: "memory.fixture", version: "1", capabilities: [.textGeneration])
    var calls = 0
    var action: (@Sendable () async throws -> Void)?
    func setAction(_ value: @escaping @Sendable () async throws -> Void) { action = value }
    func estimate(_ request: InferenceRequest) -> ResourceEstimate { .init(peakBytes: request.explicitLowMemoryMethod == nil ? 100 : 30) }
    func lowMemoryPlans(for request: InferenceRequest) throws -> [InferenceExecutionPlan] {
        [.init(request: try request.lowMemoryRequest(method: .layered), method: .layered, strategyVersion: 1, modelIdentityToken: "fixture-fixed-weights")]
    }
    func validate(_ plan: InferenceExecutionPlan, for original: InferenceRequest) throws { try plan.validateSemantics(original: original) }
    func execute(_ plan: InferenceExecutionPlan, for original: InferenceRequest,
                 emit: @escaping @Sendable (InferenceOutput) async throws -> Void) async throws -> InferenceResult {
        try validate(plan, for: original); return try await execute(plan.request, emit: emit)
    }
    func execute(_ request: InferenceRequest, emit: @escaping @Sendable (InferenceOutput) async throws -> Void) async throws -> InferenceResult {
        calls += 1; try await action?()
        return .init(textResponse: .init(rawText: "fixture output", finalText: "fixture output", finishReason: .stop))
    }
    func release() {}
}

@Suite("Low-memory record through service, checkpoint and project reopen") @MainActor
struct LowMemoryWorkflowTests {
    @Test func runtimeCancellationDismissesPendingAndNextRequestGetsItsOwnDecision() async throws {
        let settings = try #require(UserDefaults(suiteName: "D.B5.Queue." + UUID().uuidString))
        let owner = LowMemoryDecisionStore(settings: settings), backend = MemoryRecordBackend()
        let runtime = try InferenceRuntime(backends: [backend], configuration: .init(memoryBudgetBytes: 50), decideLowMemory: { try await owner.decide($0) })
        let request = InferenceRequest(model: .init(directory: URL(fileURLWithPath: "/fixture")), input: .text(.init(prompt: "fixture")), loadingSelection: .automatic)
        let first = try await runtime.submit(request, backendID: "memory.fixture")
        for _ in 0..<500 where owner.pending == nil { try await Task.sleep(for: .milliseconds(1)) }
        let old = try #require(owner.pending)
        let second = try await runtime.submit(.init(model: request.model, input: request.input, loadingSelection: .automatic), backendID: "memory.fixture")
        await first.cancel()
        #expect(await first.outcome() == .cancelled)
        for _ in 0..<500 where owner.pending == nil || owner.pending?.id == old.id { try await Task.sleep(for: .milliseconds(1)) }
        let next = try #require(owner.pending)
        #expect(next.id != old.id && owner.preference == .ask)
        #expect(!owner.resolve(proposalID: old.id, entryToken: old.entryToken, allow: true, remember: true))
        #expect(await backend.calls == 0)
        #expect(owner.resolve(proposalID: next.id, entryToken: next.entryToken, allow: true))
        guard case .completed = await second.outcome() else { Issue.record("Next authorized request did not run"); await runtime.shutdown(); return }
        #expect(await backend.calls == 1)
        #expect(owner.pending == nil && owner.preference == .ask)
        await runtime.shutdown()
    }
    private func node() throws -> WorkflowNode {
        var value = try #require(WorkflowRegistry.standard.operation(WorkflowModelRoutes.qwen35)).definition.makeNode()
        value.parameters["modelID"] = .text("text:fixture")
        value.parameters["task"] = .text("Test")
        value.parameters["loadingStrategy"] = .text("automatic")
        return value
    }
    private func service(store: ProjectStore, runtime: InferenceRuntime) -> WorkflowServices {
        let session = WorkbenchSession(engine: runtime, backendID: "memory.fixture",
            status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) }, shutdown: {}, cleanup: {}, validateModel: { _ in })
        return WorkflowServices(store: store, session: session) { _, identity in
            .init(identity: identity, reference: .init(directory: store.rootURL, revision: "fixture"), backendID: "memory.fixture", operationID: WorkflowModelRoutes.qwen35,
                textCapability: .init(maximumPromptTokens: 8192, maximumOutputTokens: 1024, profile: TextExecutionCapability.qwen35VLMProfile))
        }
    }
    private func root() throws -> URL {
        let directory = try #require(ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"])
        return URL(fileURLWithPath: directory).appendingPathComponent("B5-memory-" + UUID().uuidString + ".dproject")
    }
    @Test func rejectedCallThenExplicitRetryKeepsBothDecisionsAcrossStoreReopen() async throws {
        let url = try root()
        var store = try await ProjectStore.create(at: url, name: "Memory fixture")
        let preferences = try #require(UserDefaults(suiteName: "D.B5.Workflow." + UUID().uuidString))
        let owner = LowMemoryDecisionStore(settings: preferences); owner.setPreference(.deny)
        let backend = MemoryRecordBackend()
        let runtime = try InferenceRuntime(backends: [backend], configuration: .init(memoryBudgetBytes: 50), decideLowMemory: { try await owner.decide($0) })
        var service = service(store: store, runtime: runtime)
        let graph = WorkflowGraph(nodes: [try node()])
        let plan = try WorkflowPlanCompiler().compile(graph, target: graph.nodes[0].id)
        let first = WorkflowPlanExecutor(executeCall: { try await service.executeCall($0) }, save: { _ in }, executionRecords: { service.executionRecords(for: $0) })
        try service.beginPlan()
        let denied = try await first.execute(.init(plan: plan))
        #expect(denied.state == .cancelled)
        #expect(await backend.calls == 0)
        let firstRecord = try #require(denied.records.first?.step.executionRecords?.first)
        #expect(firstRecord.decision == .denyByPreference && firstRecord.state == .stopped)
        var deniedRun = WorkflowRun(id: denied.runID, graph: graph, targetNodeID: graph.nodes[0].id, steps: denied.records.map(\.step), status: .cancelled)
        deniedRun.planCheckpoint = denied
        let deniedRevision = try #require(try await store.workflowState().archive?.revision)
        _ = try await store.saveWorkflow(graphs: [graph], runs: [deniedRun], expectedRevision: deniedRevision)
        try await store.close()
        store = try await ProjectStore.open(at: url)
        let recovered = try #require(try await store.workflowState().archive?.runs.first?.planCheckpoint)
        #expect(recovered == denied)
        service = self.service(store: store, runtime: runtime)
        // This controlled CPU test selects allow; it is not native human consent evidence.
        owner.setPreference(.allow)
        try service.beginPlan()
        let resumed = WorkflowPlanExecutor(executeCall: { try await service.executeCall($0) }, save: { _ in }, executionRecords: { service.executionRecords(for: $0) })
        let final = try await resumed.execute(WorkflowPlanExecutor.preparingRetry(recovered))
        #expect(final.state == .completed)
        #expect(await backend.calls == 1)
        let records = try #require(final.records.first?.step.executionRecords)
        #expect(records.count == 2 && records[0] == firstRecord && records[1].decision == .allowedByPreference)
        #expect(records[0].requestID == records[1].requestID && records[0].submissionID != records[1].submissionID)
        var run = WorkflowRun(id: final.runID, graph: graph, targetNodeID: graph.nodes[0].id, steps: final.records.map(\.step), status: .completed)
        run.planCheckpoint = final
        let revision = try #require(try await store.workflowState().archive?.revision)
        let saved = try await store.saveWorkflow(graphs: [graph], runs: [run], expectedRevision: revision)
        try await store.close()
        let reopened = try await ProjectStore.open(at: url)
        #expect(try await reopened.workflowState().archive == saved)
        #expect(try await reopened.workflowState().archive?.runs.first?.planCheckpoint?.records.first?.step.executionRecords == records)
        #expect(await backend.calls == 1)
        try await reopened.close(); await runtime.shutdown()
    }
    @Test func failedPublicationRetainsRecordAndSaveRetryDoesNotRunAgain() async throws {
        let url = try root(), store = try await ProjectStore.create(at: url, name: "Publication fixture")
        let moved = url.appendingPathExtension("temporarily-unavailable"), backend = MemoryRecordBackend()
        let runtime = try InferenceRuntime(backends: [backend], configuration: .init(memoryBudgetBytes: 50), decideLowMemory: { _ in .allowOnce })
        let service = service(store: store, runtime: runtime), context = WorkflowExecutionContext(node: try node(), stepID: UUID(), inputs: [:])
        await backend.setAction { try FileManager.default.moveItem(at: url, to: moved) }
        try service.beginPlan()
        do { _ = try await service.executeCall(context); Issue.record("Expected publication failure") }
        catch { #expect(error is WorkflowSaveFailure) }
        let records = service.executionRecords(for: context.stepID)
        #expect(service.hasPendingSaves && records.count == 1 && records[0].decision == .allowOnce)
        try FileManager.default.moveItem(at: moved, to: url)
        try service.beginPlan(); _ = try await service.executeCall(context)
        #expect(!service.hasPendingSaves && service.executionRecords(for: context.stepID) == records)
        #expect(await backend.calls == 1)
        try await store.close(); await runtime.shutdown()
    }
}
