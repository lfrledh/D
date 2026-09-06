import DInference
import DRuntime
import Foundation
import Testing

@Suite("Runtime contract", .timeLimit(.minutes(1)))
struct InferenceRuntimeTests {
    @Test("FIFO lease survives suspension of a reentrant backend")
    func fifoAndReentrancy() async throws {
        let first = request(), second = request(), third = request()
        let executeGate = TestGate()
        let backend = ControlledBackend(plans: [first.id: TestPlan(executeGate: executeGate)])
        let engine = try runtime([backend])
        let firstRun = try await engine.submit(first, backendID: "controlled")
        await executeGate.waitForArrival()
        let secondRun = try await engine.submit(second, backendID: "controlled")
        let thirdRun = try await engine.submit(third, backendID: "controlled")

        let snapshot = await engine.snapshot()
        #expect(snapshot.activeRunID == first.id)
        #expect(snapshot.queuedRunIDs == [second.id, third.id])
        #expect(snapshot.reservedBytes == 64)
        #expect(await backend.observations().calls == [.estimate(first.id), .executeStarted(first.id)])

        await executeGate.open()
        await expectCompleted(firstRun)
        await expectCompleted(secondRun)
        await expectCompleted(thirdRun)
        let observed = await backend.observations()
        #expect(observed.maximumConcurrentExecutions == 1)
        #expect(observed.calls == [first, second, third].flatMap { request in
            [.estimate(request.id), .executeStarted(request.id), .executeDrained(request.id),
             .releaseStarted(request.id), .releaseFinished(request.id)] as [BackendCall]
        })
    }

    @Test("Cancellation retains its slot through execution drain and release")
    func cancellationDrainsAndReleases() async throws {
        let first = request(), second = request()
        let executeGate = TestGate(), releaseGate = TestGate(), cancellationObserved = TestGate()
        let backend = ControlledBackend(plans: [first.id: TestPlan(
            executeGate: executeGate, cancellationObserved: cancellationObserved, releaseGate: releaseGate)])
        let engine = try runtime([backend])
        let firstRun = try await engine.submit(first, backendID: "controlled")
        await executeGate.waitForArrival()
        let secondRun = try await engine.submit(second, backendID: "controlled")
        await firstRun.cancel()
        await cancellationObserved.wait()
        let cancelling = await engine.snapshot()
        #expect(cancelling.activeRunID == first.id)
        #expect(cancelling.phase == .cancelling)
        #expect(cancelling.queuedRunIDs == [second.id])
        #expect(cancelling.reservedBytes == 64)
        #expect(await backend.observations().calls == [.estimate(first.id), .executeStarted(first.id)])

        await executeGate.open()
        await releaseGate.waitForArrival()
        let releasing = await engine.snapshot()
        #expect(releasing.activeRunID == first.id)
        #expect(releasing.phase == .releasing)
        #expect(releasing.queuedRunIDs == [second.id])
        #expect(releasing.reservedBytes == 64)
        #expect(await backend.observations().calls == [
            .estimate(first.id), .executeStarted(first.id), .executeDrained(first.id), .releaseStarted(first.id)])
        await firstRun.cancel() // A repeated cancellation must not release the lease early.
        await releaseGate.open()
        #expect(await firstRun.outcome() == .cancelled)
        await expectCompleted(secondRun)
        let calls = await backend.observations().calls
        let released = try #require(calls.firstIndex(of: .releaseFinished(first.id)))
        let nextEstimated = try #require(calls.firstIndex(of: .estimate(second.id)))
        #expect(released < nextEstimated)
    }

    @Test("Cancelled queued work never enters the backend")
    func queuedCancellation() async throws {
        let first = request(), cancelled = request(), third = request()
        let gate = TestGate()
        let backend = ControlledBackend(plans: [first.id: TestPlan(executeGate: gate)])
        let engine = try runtime([backend])
        let firstRun = try await engine.submit(first, backendID: "controlled")
        await gate.waitForArrival()
        let cancelledRun = try await engine.submit(cancelled, backendID: "controlled")
        let thirdRun = try await engine.submit(third, backendID: "controlled")
        await cancelledRun.cancel()
        #expect(await cancelledRun.outcome() == .cancelled)
        #expect(await engine.snapshot().queuedRunIDs == [third.id])
        await gate.open()
        await expectCompleted(firstRun)
        await expectCompleted(thirdRun)
        let calls = await backend.observations().calls
        #expect(!calls.contains(.estimate(cancelled.id)))
        #expect(!calls.contains(.executeStarted(cancelled.id)))
    }

    @Test("Unknown backend and unsupported capability reject before execution")
    func unsupportedSubmission() async throws {
        let backend = ControlledBackend()
        let engine = try runtime([backend])
        await expectSubmissionFailure(engine, request(), backendID: "missing", expected: .unknownBackend("missing"))
        let image = request(input: .image(ImageRequest(prompt: "image", width: 64, height: 64,
                                                      steps: 1, guidanceScale: 1, seed: 0)))
        await expectSubmissionFailure(engine, image, expected: .unsupportedCapability(.imageGeneration))
        #expect(await backend.observations().calls.isEmpty)
    }

    @Test("Invalid local model and numerical parameters reject before queueing")
    func requestValidation() async throws {
        let backend = ControlledBackend(capabilities: [.textGeneration, .imageGeneration])
        let engine = try runtime([backend])
        let badModel = InferenceRequest(model: ModelReference(directory: URL(string: "https://example.com/model")!),
                                        input: .text(TextRequest(prompt: "test")))
        let invalidRequests = [
            badModel,
            request(input: .text(TextRequest(prompt: "test", maxTokens: 0))),
            request(input: .text(TextRequest(prompt: "test", temperature: .nan))),
            request(input: .text(TextRequest(prompt: "test", topP: 1.1))),
            request(input: .image(ImageRequest(prompt: "test", width: 0, height: 64,
                                               steps: 1, guidanceScale: 1, seed: 0))),
            request(input: .image(ImageRequest(prompt: "test", width: 64, height: 64,
                                               steps: 0, guidanceScale: 1, seed: 0))),
            request(input: .image(ImageRequest(prompt: "test", width: 64, height: 64,
                                               steps: 1, guidanceScale: .infinity, seed: 0)))
        ]
        for invalid in invalidRequests {
            do {
                _ = try await engine.submit(invalid, backendID: "controlled")
                Issue.record("Invalid request was accepted")
            } catch let failure as InferenceFailure {
                guard case .invalidRequest = failure else {
                    Issue.record("Unexpected failure: \(failure)")
                    continue
                }
            }
        }
        #expect(await backend.observations().calls.isEmpty)
        #expect(await engine.snapshot().activeRunID == nil)
    }

    @Test("A bounded queue rejects excess work and duplicate IDs")
    func queueLimitsAndDuplicates() async throws {
        let first = request(), second = request()
        let gate = TestGate()
        let backend = ControlledBackend(plans: [first.id: TestPlan(executeGate: gate)])
        let engine = try runtime([backend], queueCapacity: 1)
        let firstRun = try await engine.submit(first, backendID: "controlled")
        await gate.waitForArrival()
        let secondRun = try await engine.submit(second, backendID: "controlled")
        await expectSubmissionFailure(engine, request(), expected: .queueFull)
        await expectSubmissionFailure(engine, first, expected: .duplicateRun)
        await expectSubmissionFailure(engine, second, expected: .duplicateRun)
        #expect(await engine.snapshot().queuedRunIDs == [second.id])
        await gate.open()
        await expectCompleted(firstRun)
        await expectCompleted(secondRun)
    }

    @Test("Zero waiting capacity still permits one active run")
    func noWaitingQueue() async throws {
        let first = request(), gate = TestGate()
        let backend = ControlledBackend(plans: [first.id: TestPlan(executeGate: gate)])
        let engine = try runtime([backend], queueCapacity: 0)
        let run = try await engine.submit(first, backendID: "controlled")
        await gate.waitForArrival()
        await expectSubmissionFailure(engine, request(), expected: .queueFull)
        await gate.open()
        await expectCompleted(run)
    }

    @Test("Over-budget and absent estimates do not execute and still clean up")
    func resourceAdmission() async throws {
        let oversized = request(), invalid = request(), valid = request()
        let backend = ControlledBackend(plans: [
            oversized.id: TestPlan(estimate: 1_025), invalid.id: TestPlan(estimate: 0)])
        let engine = try runtime([backend])
        let oversizedRun = try await engine.submit(oversized, backendID: "controlled")
        let invalidRun = try await engine.submit(invalid, backendID: "controlled")
        let validRun = try await engine.submit(valid, backendID: "controlled")
        #expect(await oversizedRun.outcome() == .failed(.memoryBudgetExceeded(required: 1_025, limit: 1_024)))
        #expect(await invalidRun.outcome() == .failed(.invalidResourceEstimate))
        await expectCompleted(validRun)
        let calls = await backend.observations().calls
        for rejected in [oversized, invalid] {
            #expect(!calls.contains(.executeStarted(rejected.id)))
            #expect(calls.contains(.releaseFinished(rejected.id)))
        }
    }

    @Test("Backend failure cleans up before the next request can run")
    func failureCleanup() async throws {
        let failed = request(), next = request(), releaseGate = TestGate()
        let backend = ControlledBackend(plans: [failed.id: TestPlan(releaseGate: releaseGate, shouldFail: true)])
        let engine = try runtime([backend])
        let failedRun = try await engine.submit(failed, backendID: "controlled")
        await releaseGate.waitForArrival()
        let nextRun = try await engine.submit(next, backendID: "controlled")
        #expect(await engine.snapshot().activeRunID == failed.id)
        #expect(await engine.snapshot().queuedRunIDs == [next.id])
        #expect(!((await backend.observations()).calls.contains(.executeStarted(next.id))))
        await releaseGate.open()
        #expect(await failedRun.outcome() == .failed(.backendFailed("Controlled backend failure")))
        await expectCompleted(nextRun)
        let calls = await backend.observations().calls
        let released = try #require(calls.firstIndex(of: .releaseFinished(failed.id)))
        let nextEstimated = try #require(calls.firstIndex(of: .estimate(next.id)))
        #expect(released < nextEstimated)
    }

    @Test("Cancelling a stream consumer cancels inference and never reports success")
    func consumerCancellation() async throws {
        let first = request(), executeGate = TestGate(), cancellationObserved = TestGate()
        let consumerReady = TestGate()
        let backend = ControlledBackend(plans: [first.id: TestPlan(
            executeGate: executeGate, cancellationObserved: cancellationObserved)])
        let engine = try runtime([backend])
        let run = try await engine.submit(first, backendID: "controlled")
        await executeGate.waitForArrival()
        let consumer = Task {
            await consumerReady.open()
            do { for try await _ in run.events {} }
            catch is CancellationError {} // A cancelled iterator may also end normally.
            catch { Issue.record("Unexpected stream failure: \(error)") }
        }
        await consumerReady.wait()
        consumer.cancel()
        await consumer.value
        await cancellationObserved.wait()
        #expect(await engine.snapshot().activeRunID == first.id)
        await executeGate.open()
        #expect(await run.outcome() == .cancelled)
        #expect(await backend.observations().calls.contains(.releaseFinished(first.id)))
    }

    @Test("Overflow surfaces an explicit failure on both outcome and event stream")
    func consumerOverflow() async throws {
        let overflowing = request(), next = request()
        let backend = ControlledBackend(plans: [overflowing.id: TestPlan(
            outputs: [.textDelta("one"), .textDelta("two"), .textDelta("three")])])
        let engine = try runtime([backend], bufferCapacity: 1)
        let run = try await engine.submit(overflowing, backendID: "controlled")
        #expect(await run.outcome() == .failed(.consumerTooSlow))
        var received: [InferenceOutput] = []
        do {
            for try await output in run.events { received.append(output) }
            Issue.record("Overflowed stream completed without an error")
        } catch let failure as InferenceFailure {
            #expect(failure == .consumerTooSlow)
        }
        #expect(received == [.textDelta("one")])
        #expect(await backend.observations().calls.contains(.releaseFinished(overflowing.id)))
        let nextRun = try await engine.submit(next, backendID: "controlled")
        await expectCompleted(nextRun)
    }

    @Test("Batch cancellation drains active work, skips queued work, and permits later submissions")
    func cancelAllDrains() async throws {
        let active = request(), queued = request()
        let executeGate = TestGate(), cancellationObserved = TestGate(), releaseGate = TestGate()
        let backend = ControlledBackend(plans: [active.id: TestPlan(
            executeGate: executeGate, cancellationObserved: cancellationObserved, releaseGate: releaseGate)])
        let engine = try runtime([backend])
        let activeRun = try await engine.submit(active, backendID: "controlled")
        await executeGate.waitForArrival()
        let queuedRun = try await engine.submit(queued, backendID: "controlled")
        let shutdown = Task { await engine.cancelAllAndWait() }
        await cancellationObserved.wait()
        await executeGate.open()
        await releaseGate.waitForArrival()
        #expect(await engine.snapshot().activeRunID == active.id)
        await releaseGate.open()
        await shutdown.value
        #expect(await activeRun.outcome() == .cancelled)
        #expect(await queuedRun.outcome() == .cancelled)
        #expect(!((await backend.observations()).calls.contains(.executeStarted(queued.id))))
        let later = try await engine.submit(request(), backendID: "controlled")
        await expectCompleted(later)
    }

    @Test("Shutdown closes admission while cleanup is still suspended")
    func shutdownClosesAdmission() async throws {
        let active = request(), queued = request()
        let executeGate = TestGate(), cancellationObserved = TestGate(), releaseGate = TestGate()
        let backend = ControlledBackend(plans: [active.id: TestPlan(
            executeGate: executeGate, cancellationObserved: cancellationObserved, releaseGate: releaseGate)])
        let engine = try runtime([backend])
        let activeRun = try await engine.submit(active, backendID: "controlled")
        await executeGate.waitForArrival()
        let queuedRun = try await engine.submit(queued, backendID: "controlled")
        let shutdown = Task { await engine.shutdown() }
        await cancellationObserved.wait()
        await executeGate.open()
        await releaseGate.waitForArrival()
        await expectSubmissionFailure(engine, request(), expected: .runtimeClosed)
        #expect(await engine.snapshot().activeRunID == active.id)
        await releaseGate.open()
        await shutdown.value
        #expect(await activeRun.outcome() == .cancelled)
        #expect(await queuedRun.outcome() == .cancelled)
        await expectSubmissionFailure(engine, request(), expected: .runtimeClosed)
        #expect(!((await backend.observations()).calls.contains(.executeStarted(queued.id))))
    }

    @Test("A stale handle cannot cancel a newer run that reused its public ID")
    func staleHandleCancellation() async throws {
        let reused = request(), secondGate = TestGate()
        let firstBackend = ControlledBackend(id: "first")
        let secondBackend = ControlledBackend(id: "second", plans: [reused.id: TestPlan(executeGate: secondGate)])
        let engine = try runtime([firstBackend, secondBackend])
        let oldRun = try await engine.submit(reused, backendID: "first")
        await expectCompleted(oldRun)
        let newRun = try await engine.submit(reused, backendID: "second")
        await secondGate.waitForArrival()
        await oldRun.cancel()
        let snapshot = await engine.snapshot()
        #expect(snapshot.activeRunID == reused.id)
        #expect(snapshot.phase == .running)
        await secondGate.open()
        await expectCompleted(newRun)
        await expectCompleted(oldRun)
    }

    @Test("Cancellation while estimating never starts inference")
    func cancellationDuringEstimate() async throws {
        let first = request(), estimateGate = TestGate()
        let backend = ControlledBackend(plans: [first.id: TestPlan(estimateGate: estimateGate)])
        let engine = try runtime([backend])
        let run = try await engine.submit(first, backendID: "controlled")
        await estimateGate.waitForArrival()
        await run.cancel()
        #expect(await engine.snapshot().reservedBytes == 0)
        await estimateGate.open()
        #expect(await run.outcome() == .cancelled)
        let calls = await backend.observations().calls
        #expect(!calls.contains(.executeStarted(first.id)))
        #expect(calls.contains(.releaseFinished(first.id)))
    }

    @Test("Invalid runtime configuration and duplicate backend registration fail early")
    func configurationValidation() throws {
        #expect(throws: InferenceFailure.self) { try RuntimeConfiguration(memoryBudgetBytes: 0) }
        #expect(throws: InferenceFailure.self) {
            try RuntimeConfiguration(memoryBudgetBytes: 1, maximumQueuedRuns: -1)
        }
        #expect(throws: InferenceFailure.self) {
            try RuntimeConfiguration(memoryBudgetBytes: 1, eventBufferCapacity: 0)
        }
        #expect(throws: InferenceFailure.self) {
            try runtime([ControlledBackend(), ControlledBackend()])
        }
        #expect(throws: InferenceFailure.self) { try runtime([ControlledBackend(id: "")]) }
    }
}
