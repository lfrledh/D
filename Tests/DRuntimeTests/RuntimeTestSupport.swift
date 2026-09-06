import DInference
import DRuntime
import Foundation
import Testing

/// A deterministic latch: tests coordinate suspension points without sleeping.
actor TestGate {
    private var isOpen = false
    private var hasArrived = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        hasArrived = true
        let arrivals = arrivalWaiters
        arrivalWaiters.removeAll()
        for continuation in arrivals { continuation.resume() }
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func waitForArrival() async {
        if hasArrived { return }
        await withCheckedContinuation { arrivalWaiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for continuation in pending { continuation.resume() }
    }
}

enum TestBackendError: Error, LocalizedError {
    case controlledFailure
    var errorDescription: String? { "Controlled backend failure" }
}

struct TestPlan: Sendable {
    var estimate: UInt64 = 64
    var estimateGate: TestGate?
    var executeGate: TestGate?
    var cancellationObserved: TestGate?
    var releaseGate: TestGate?
    var shouldFail = false
    var outputs: [InferenceOutput] = []
}

enum BackendCall: Sendable, Equatable {
    case estimate(UUID)
    case executeStarted(UUID)
    case executeDrained(UUID)
    case releaseStarted(UUID)
    case releaseFinished(UUID)
}

struct BackendObservations: Sendable {
    let calls: [BackendCall]
    let maximumConcurrentExecutions: Int
}

/// Deliberately reentrant: only the runtime, not this fake's actor, can serialize execute.
actor ControlledBackend: InferenceBackend {
    nonisolated let descriptor: BackendDescriptor
    private let plans: [UUID: TestPlan]
    private var calls: [BackendCall] = []
    private var awaitingRelease: [UUID] = []
    private var executing = 0
    private var maximumConcurrentExecutions = 0

    init(id: String = "controlled", capabilities: Set<InferenceCapability> = [.textGeneration],
         plans: [UUID: TestPlan] = [:]) {
        descriptor = BackendDescriptor(id: id, version: "test", capabilities: capabilities)
        self.plans = plans
    }

    func estimate(_ request: InferenceRequest) async throws -> ResourceEstimate {
        calls.append(.estimate(request.id))
        awaitingRelease.append(request.id)
        let plan = plans[request.id] ?? TestPlan()
        if let gate = plan.estimateGate { await gate.wait() }
        return ResourceEstimate(peakBytes: plan.estimate)
    }

    func execute(_ request: InferenceRequest,
                 emit: @escaping @Sendable (InferenceOutput) async throws -> Void) async throws -> InferenceResult {
        calls.append(.executeStarted(request.id))
        executing += 1
        maximumConcurrentExecutions = max(maximumConcurrentExecutions, executing)
        defer {
            executing -= 1
            calls.append(.executeDrained(request.id))
        }
        let plan = plans[request.id] ?? TestPlan()
        if let gate = plan.executeGate {
            await withTaskCancellationHandler {
                await gate.wait()
            } onCancel: {
                if let observed = plan.cancellationObserved {
                    Task { await observed.open() }
                }
            }
        }
        if plan.shouldFail { throw TestBackendError.controlledFailure }
        for output in plan.outputs { try await emit(output) }
        return InferenceResult(metadata: ["requestID": request.id.uuidString])
    }

    func release() async {
        // A pre-estimate cancellation legitimately requires idempotent cleanup too.
        guard !awaitingRelease.isEmpty else { return }
        let id = awaitingRelease.removeFirst()
        calls.append(.releaseStarted(id))
        if let gate = plans[id]?.releaseGate { await gate.wait() }
        calls.append(.releaseFinished(id))
    }

    func observations() -> BackendObservations {
        BackendObservations(calls: calls, maximumConcurrentExecutions: maximumConcurrentExecutions)
    }
}

func request(id: UUID = UUID(), input: InferenceInput = .text(TextRequest(prompt: "test"))) -> InferenceRequest {
    InferenceRequest(id: id, model: ModelReference(directory: URL(fileURLWithPath: "/test-model")), input: input)
}

func runtime(_ backends: [any InferenceBackend], budget: UInt64 = 1_024,
             queueCapacity: Int = 8, bufferCapacity: Int = 256) throws -> InferenceRuntime {
    try InferenceRuntime(backends: backends, configuration: RuntimeConfiguration(
        memoryBudgetBytes: budget, maximumQueuedRuns: queueCapacity, eventBufferCapacity: bufferCapacity))
}

func expectCompleted(_ run: InferenceRun, sourceLocation: SourceLocation = #_sourceLocation) async {
    let result = await run.outcome()
    if case .completed = result { return }
    Issue.record("Expected completion, received \(result)", sourceLocation: sourceLocation)
}

func expectSubmissionFailure(_ engine: InferenceRuntime, _ request: InferenceRequest,
                             backendID: String = "controlled", expected: InferenceFailure,
                             sourceLocation: SourceLocation = #_sourceLocation) async {
    do {
        _ = try await engine.submit(request, backendID: backendID)
        Issue.record("Expected submission failure \(expected)", sourceLocation: sourceLocation)
    } catch let failure as InferenceFailure {
        #expect(failure == expected, sourceLocation: sourceLocation)
    } catch {
        Issue.record("Unexpected error: \(error)", sourceLocation: sourceLocation)
    }
}
