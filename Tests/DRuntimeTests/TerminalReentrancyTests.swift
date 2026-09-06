import DInference
import DRuntime
import Foundation
import Testing

@Suite("Runtime terminal reentrancy", .timeLimit(.minutes(1)))
struct TerminalReentrancyTests {
    @Test("A terminal ID can be reused and batch-cancelled without orphaning its outcome",
          arguments: [false, true])
    func reuseThenCancelBatch(shutdown: Bool) async throws {
        // Priority and repetition exercise the executor hop after stream termination.
        // The assertion checks the exact inconsistent state before invoking cancellation,
        // so the old implementation fails explicitly instead of waiting on its deadlock.
        for _ in 0..<64 {
            let reused = request()
            let releaseGate = TestGate(), replacementGate = TestGate(), waiterReady = TestGate()
            let firstBackend = ControlledBackend(id: "first", plans: [
                reused.id: TestPlan(releaseGate: releaseGate)])
            let replacementBackend = ControlledBackend(id: "replacement", plans: [
                reused.id: TestPlan(executeGate: replacementGate)])
            let engine = try runtime([firstBackend, replacementBackend])
            // Do not await this task until its worker has entered release: awaiting an
            // unfinished task could raise its priority and mask the resolution race.
            let submission = Task.detached(priority: .background) {
                try await engine.submit(reused, backendID: "first")
            }
            await releaseGate.waitForArrival()
            let original = try await submission.value
            let observer = Task(priority: .high) {
                await waiterReady.open()
                // Stream termination follows release, but can precede the outcome
                // actor's acknowledgement. Reenter during exactly that handoff.
                for try await _ in original.events {}
                return try await reuseAndCancel(engine, request: reused, shutdown: shutdown)
            }
            await waiterReady.wait()
            #expect(await engine.snapshot().activeRunID == reused.id,
                    "The old execution must retain its slot while release is suspended")
            await releaseGate.open()
            let (replacement, inconsistent) = try await observer.value
            await expectCompleted(original)

            if inconsistent {
                // Only the defective implementation reaches this path. Let its old
                // finalizer resume, then clean up without calling the known-deadlocking
                // batch operation while the new entry is mistaken for the old active run.
                await replacementGate.waitForArrival()
                await replacement.cancel()
                await replacementGate.open()
            }
            #expect(await replacement.outcome() == .cancelled)
            if inconsistent { await engine.shutdown() }

            let settled = await engine.snapshot()
            #expect(settled.activeRunID == nil)
            #expect(settled.phase == nil)
            #expect(settled.queuedRunIDs.isEmpty)
            #expect(settled.reservedBytes == 0)
            #expect(await firstBackend.observations().calls.last == .releaseFinished(reused.id))

            if shutdown || inconsistent {
                await expectSubmissionFailure(engine, request(), backendID: "replacement",
                                              expected: .runtimeClosed)
            } else {
                // Batch cancellation has snapshot semantics; it cannot cancel later work.
                let later = try await engine.submit(request(), backendID: "replacement")
                await expectCompleted(later)
                await engine.shutdown()
            }
        }
    }
}

private func reuseAndCancel(_ engine: isolated InferenceRuntime, request: InferenceRequest,
                            shutdown: Bool) async throws -> (InferenceRun, Bool) {
    // These synchronous actor calls are one transaction. No old finalizer can run
    // between the resubmission, identity check, and entry into batch cancellation.
    let replacement = try engine.submit(request, backendID: "replacement")
    let snapshot = engine.snapshot()
    let inconsistent = snapshot.activeRunID == request.id && snapshot.queuedRunIDs.contains(request.id)
    #expect(!inconsistent,
            "A reused ID is queued while the preceding run still owns the same active ID; batch cancellation would orphan it")
    if !inconsistent {
        if shutdown { await engine.shutdown() }
        else { await engine.cancelAllAndWait() }
    }
    return (replacement, inconsistent)
}
