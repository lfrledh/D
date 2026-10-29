import DInference
import DRuntime
import Foundation
import Testing

private actor PlanningBackend: InferenceExecutionPlanning {
    nonisolated let descriptor = BackendDescriptor(id: "planning", version: "1", capabilities: [.textGeneration])
    var seal = "weight-version-1"
    var executed: [InferenceRequest] = []
    var released = 0
    var plans = 0
    var preferred: UInt64 = 100
    var lower: UInt64 = 30
    func changeSeal() { seal = "weight-version-2" }
    func estimate(_ request: InferenceRequest) -> ResourceEstimate {
        .init(peakBytes: request.explicitLowMemoryMethod == nil ? preferred : lower)
    }
    func lowMemoryPlans(for request: InferenceRequest) throws -> [InferenceExecutionPlan] {
        plans += 1
        return [.init(request: try request.lowMemoryRequest(method: .layered), method: .layered,
                      strategyVersion: 1, modelIdentityToken: seal)]
    }
    func validate(_ plan: InferenceExecutionPlan, for original: InferenceRequest) throws {
        try plan.validateSemantics(original: original)
        guard plan.modelIdentityToken == seal else { throw InferenceFailure.inputIntegrityChanged("Changed checkpoint") }
    }
    func execute(_ plan: InferenceExecutionPlan, for original: InferenceRequest,
                 emit: @escaping @Sendable (InferenceOutput) async throws -> Void) async throws -> InferenceResult {
        try validate(plan, for: original)
        return try await execute(plan.request, emit: emit)
    }
    func execute(_ request: InferenceRequest,
                 emit: @escaping @Sendable (InferenceOutput) async throws -> Void) async throws -> InferenceResult {
        executed.append(request)
        return .init(metadata: ["sameWeights": seal])
    }
    func release() { released += 1 }
    func counts() -> (Int, Int, Int) { (plans, executed.count, released) }
}

@Suite("Explicit low-memory permission", .timeLimit(.minutes(1)))
struct LowMemoryConsentTests {
    private func request(automatic: Bool = true, layered: Bool = false, id: UUID = UUID()) -> InferenceRequest {
        .init(id: id, model: .init(directory: URL(fileURLWithPath: "/exact-q4"), revision: "checkpoint"),
              input: .text(.init(prompt: "unchanged input", loadingStrategy: layered ? .ssdLayered : .resident)),
              loadingSelection: automatic ? .automatic : nil)
    }
    private func engine(_ backend: PlanningBackend,
                        decision: (@Sendable (LowMemoryProposal) async throws -> LowMemoryDecision)? = nil) throws -> InferenceRuntime {
        try .init(backends: [backend], configuration: .init(memoryBudgetBytes: 50), decideLowMemory: decision)
    }
    @Test func noInteractiveOwnerNeverAssumesConsent() async throws {
        let backend = PlanningBackend()
        let actual = try engine(backend)
        let run = try await actual.submit(request(), backendID: "planning")
        #expect(await run.outcome() == .failed(.lowMemoryDecisionRequired))
        #expect(await backend.counts() == (1, 0, 1))
        #expect(await run.executionRecord()?.state == .failed)
        #expect(await run.executionRecord()?.decision == nil)
        await actual.shutdown()
    }
    @Test func waitingReservesNoWeightsAndApprovalChangesOnlyResidency() async throws {
        let backend = PlanningBackend(), gate = TestGate()
        let original = request()
        let runtime = try engine(backend) { proposal in
            #expect(proposal.original == original)
            #expect(proposal.plan.request.model == original.model)
            await gate.wait(); return .allowOnce
        }
        let run = try await runtime.submit(original, backendID: "planning")
        await gate.waitForArrival()
        let snapshot = await runtime.snapshot()
        #expect(snapshot.phase == .awaitingLowMemoryDecision && snapshot.reservedBytes == 0)
        #expect(await backend.counts() == (1, 0, 0))
        #expect(await run.executionRecord()?.state == .awaitingDecision)
        await gate.open()
        await expectCompleted(run)
        #expect(await backend.executed == [try original.lowMemoryRequest(method: .layered)])
        let record = try #require(await run.executionRecord())
        #expect(record.decision == .allowOnce && record.state == .completed && record.requestID == original.id)
        #expect(record.candidates.count == 1 && record.candidates[0].withinBudget)
        #expect(try JSONDecoder().decode(InferenceExecutionRecord.self, from: JSONEncoder().encode(record)) == record)
        await runtime.shutdown()
    }
    @Test(arguments: [LowMemoryDecision.userStopped, .denyByPreference])
    func refusalIsStoppedNotModelFailure(_ decision: LowMemoryDecision) async throws {
        let backend = PlanningBackend()
        let actual = try engine(backend) { _ in decision }
        let run = try await actual.submit(request(), backendID: "planning")
        #expect(await run.outcome() == .cancelled)
        #expect(await backend.counts() == (1, 0, 1))
        #expect(await run.executionRecord()?.state == .stopped)
        #expect(await run.executionRecord()?.decision == decision)
        await actual.shutdown()
    }
    @Test func changedApprovedFilesCannotLoad() async throws {
        let backend = PlanningBackend()
        let runtime = try engine(backend) { _ in await backend.changeSeal(); return .allowOnce }
        let run = try await runtime.submit(request(), backendID: "planning")
        #expect(await run.outcome() == .failed(.inputIntegrityChanged("Changed checkpoint")))
        #expect(await backend.counts() == (1, 0, 1))
        await runtime.shutdown()
    }
    @Test func fixedChoicesKeepMeaningAndFastBudgetNeverAsks() async throws {
        let backend = PlanningBackend()
        let runtime = try engine(backend) { _ in Issue.record("Fixed strategy asked"); return .allowedByPreference }
        let fixed = try await runtime.submit(request(automatic: false), backendID: "planning")
        #expect(await fixed.outcome() == .failed(.memoryBudgetExceeded(required: 100, limit: 50)))
        let explicit = try await runtime.submit(request(automatic: false, layered: true), backendID: "planning")
        await expectCompleted(explicit)
        #expect(await explicit.executionRecord()?.explicitlySelected == true)
        #expect(await explicit.executionRecord()?.decision == nil)
        #expect(await backend.counts() == (0, 1, 2))
        await runtime.shutdown()
        let fast = try InferenceRuntime(backends: [backend], configuration: .init(memoryBudgetBytes: 100),
            decideLowMemory: { _ in Issue.record("Within budget asked"); return .userStopped })
        await expectCompleted(try await fast.submit(request(), backendID: "planning"))
        #expect(await backend.counts() == (0, 2, 3))
        await fast.shutdown()
    }
    @Test func lateApprovalAfterCancellationNeverExecutesOrCancelsReusedID() async throws {
        let backend = PlanningBackend(), gate = TestGate(), id = UUID()
        let runtime = try engine(backend) { _ in await gate.wait(); return .allowOnce }
        let old = try await runtime.submit(request(id: id), backendID: "planning")
        await gate.waitForArrival()
        await old.cancel(); await gate.open()
        #expect(await old.outcome() == .cancelled)
        #expect(await backend.executed.isEmpty)
        let next = try await runtime.submit(request(id: id), backendID: "planning")
        await old.cancel()
        await expectCompleted(next)
        #expect(await backend.executed.count == 1)
        await runtime.shutdown()
    }
    @Test func plannerCannotModifyPromptModelOrSeed() throws {
        let original = request()
        for input in [TextRequest(prompt: "modified prompt", loadingStrategy: .ssdLayered),
                      TextRequest(prompt: "unchanged input", seed: 42, loadingStrategy: .ssdLayered)] {
            let changed = InferenceRequest(id: original.id, model: original.model, input: .text(input))
            #expect(throws: InferenceFailure.self) {
                try InferenceExecutionPlan(request: changed, method: .layered, strategyVersion: 1,
                    modelIdentityToken: "same").validateSemantics(original: original)
            }
        }
        let changedModel = InferenceRequest(id: original.id, model: .init(directory: URL(fileURLWithPath: "/smaller")),
            input: try original.lowMemoryRequest(method: .layered).input)
        #expect(throws: InferenceFailure.self) {
            try InferenceExecutionPlan(request: changedModel, method: .layered, strategyVersion: 1,
                modelIdentityToken: "same").validateSemantics(original: original)
        }
    }
}
