import DInference
import DRuntime
import Foundation
import Testing

@Suite("Background admission", .timeLimit(.minutes(1)))
struct AdmissionPriorityTests {
    private func background() -> InferenceRequest {
        let original = request()
        return .init(id: original.id, model: original.model, input: original.input, priority: .background)
    }
    @Test func legacyRequestRoundTripsWithoutInventingExplicitPriority() throws {
        let old = request(), data = try JSONEncoder().encode(old)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["priority"] == nil)
        let restored = try JSONDecoder().decode(InferenceRequest.self, from: data)
        #expect(restored == old && restored.priority == nil)
        let low = background()
        #expect(try JSONDecoder().decode(InferenceRequest.self, from: JSONEncoder().encode(low)) == low)
    }
    @Test func interactiveQueuedWorkPrecedesBackgroundWithoutPreemptionOrEarlyRelease() async throws {
        let active = background(), low1 = background(), normal1 = request(), low2 = background(), normal2 = request()
        let gate = TestGate(), release = TestGate()
        let backend = ControlledBackend(plans: [active.id: TestPlan(executeGate: gate, releaseGate: release)])
        let engine = try runtime([backend]); let run = try await engine.submit(active, backendID: "controlled")
        await gate.waitForArrival()
        var runs: [InferenceRun] = []
        for input in [low1, normal1, low2, normal2] { runs.append(try await engine.submit(input, backendID: "controlled")) }
        #expect(await engine.snapshot().activeRunID == active.id)
        #expect(await engine.snapshot().queuedRunIDs == [normal1.id, normal2.id, low1.id, low2.id])
        await gate.open(); await release.waitForArrival()
        #expect(await backend.observations().calls.filter { if case .executeStarted = $0 { true } else { false } } == [.executeStarted(active.id)])
        await release.open(); await expectCompleted(run)
        for item in runs { await expectCompleted(item) }
        let observed = await backend.observations()
        #expect(observed.maximumConcurrentExecutions == 1)
        #expect(observed.calls.filter { if case .executeStarted = $0 { true } else { false } } == [active, normal1, normal2, low1, low2].map { .executeStarted($0.id) })
    }
    @Test func backgroundCancellationAndCapacityKeepExistingContract() async throws {
        let active = request(), low = background(), gate = TestGate()
        let backend = ControlledBackend(plans: [active.id: TestPlan(executeGate: gate)])
        let engine = try runtime([backend], queueCapacity: 1)
        let run = try await engine.submit(active, backendID: "controlled"); await gate.waitForArrival()
        let queued = try await engine.submit(low, backendID: "controlled")
        await expectSubmissionFailure(engine, request(), expected: .queueFull)
        await queued.cancel(); #expect(await queued.outcome() == .cancelled)
        let normal = try await engine.submit(request(), backendID: "controlled")
        await gate.open(); await expectCompleted(run); await expectCompleted(normal)
        #expect(!(await backend.observations().calls).contains(.estimate(low.id)))
    }
}
