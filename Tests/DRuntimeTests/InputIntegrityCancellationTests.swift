import DInference
import DRuntime
import Foundation
import Testing

@Suite("Input protection and cancellation", .serialized)
struct InputIntegrityCancellationTests {
    @Test("Unknown process cleanup closes admission without starting queued work")
    func uncertainCleanupQuarantinesRuntime() async throws {
        let first = request(), second = request(), execute = TestGate()
        let failure = InferenceFailure.resourceCleanupUnconfirmed("owned group still uncertain")
        let backend = ControlledBackend(plans: [first.id: TestPlan(executeGate: execute, failure: failure)])
        let engine = try runtime([backend])
        let run = try await engine.submit(first, backendID: "controlled")
        await execute.waitForArrival()
        let queued = try await engine.submit(second, backendID: "controlled")
        await run.cancel(); await execute.open()
        #expect(await run.outcome() == .failed(failure))
        #expect(await queued.outcome() == .failed(.runtimeClosed))
        #expect(!(await backend.observations().calls).contains(.executeStarted(second.id)))
        do {
            _ = try await engine.submit(request(), backendID: "controlled")
            Issue.record("Quarantined runtime accepted another request")
        } catch let value as InferenceFailure { #expect(value == .runtimeClosed) }
        await engine.shutdown()
    }
    @Test("Verified mutation survives cancellation during execution and release")
    func integrityWins() async throws {
        for cancelDuringRelease in [false, true] {
            let first = request(), second = request()
            let execute = TestGate(), release = TestGate()
            let expected = InferenceFailure.inputIntegrityChanged("request changed; original context: cancelled")
            let backend = ControlledBackend(plans: [first.id: TestPlan(
                executeGate: execute, releaseGate: release, failure: expected)])
            let engine = try runtime([backend])
            let run = try await engine.submit(first, backendID: "controlled")
            await execute.waitForArrival()
            let next = try await engine.submit(second, backendID: "controlled")
            if !cancelDuringRelease { await run.cancel() }
            await execute.open(); await release.waitForArrival()
            if cancelDuringRelease { await run.cancel() }
            let calls = await backend.observations().calls
            #expect(!calls.contains(.executeStarted(second.id)))
            await release.open()
            #expect(await run.outcome() == .failed(expected))
            do {
                for try await _ in run.events {}
                Issue.record("Expected the protected-input failure in event stream")
            } catch let value as InferenceFailure { #expect(value == expected) }
            await expectCompleted(next)
            await engine.shutdown()
        }
    }

    @Test("Ordinary backend errors retain the existing cancelled outcome")
    func ordinaryFailureStillCancelled() async throws {
        let job = request(), execute = TestGate()
        let backend = ControlledBackend(plans: [job.id: TestPlan(
            executeGate: execute, failure: .backendFailed("ordinary"))])
        let engine = try runtime([backend]); let run = try await engine.submit(job, backendID: "controlled")
        await execute.waitForArrival(); await run.cancel(); await execute.open()
        #expect(await run.outcome() == .cancelled)
        await engine.shutdown()
    }
}
