import DInference
import DRuntime
import Foundation
import Testing

@Suite("Backend extension contracts", .timeLimit(.minutes(1)))
struct BackendExtensionTests {
    @Test("Explicit backend selection calls only its selected implementation")
    func explicitSelectionUsesOnlySelectedBackend() async throws {
        let selectedByA = request()
        let selectedByB = request()
        let backendA = ControlledBackend(id: "A", plans: [
            selectedByA.id: TestPlan(outputs: [.textDelta("from-A")])
        ])
        let backendB = ControlledBackend(id: "B", plans: [
            selectedByB.id: TestPlan(outputs: [.textDelta("from-B")])
        ])
        let engine = try runtime([backendA, backendB])

        let runA = try await engine.submit(selectedByA, backendID: "A")
        await expectCompleted(runA)
        #expect(try await outputs(from: runA) == [.textDelta("from-A")])
        #expect((await backendB.observations()).calls.isEmpty)

        let runB = try await engine.submit(selectedByB, backendID: "B")
        await expectCompleted(runB)
        #expect(try await outputs(from: runB) == [.textDelta("from-B")])
        #expect((await backendA.observations()).calls.map(requestID) == [selectedByA.id, selectedByA.id,
                                                                            selectedByA.id, selectedByA.id,
                                                                            selectedByA.id])
        #expect((await backendB.observations()).calls.map(requestID) == [selectedByB.id, selectedByB.id,
                                                                            selectedByB.id, selectedByB.id,
                                                                            selectedByB.id])
    }

    @Test("Submission and selected-backend rejections never fall back")
    func rejectionsDoNotFallback() async throws {
        let backendA = ControlledBackend(id: "A", capabilities: [.textGeneration])
        let backendB = ControlledBackend(id: "B", capabilities: [.textGeneration, .imageGeneration])
        let engine = try runtime([backendA, backendB])

        await expectSubmissionFailure(engine, request(), backendID: "missing", expected: .unknownBackend("missing"))
        let image = request(input: .image(ImageRequest(prompt: "image", width: 64, height: 64,
                                                        steps: 1, guidanceScale: 1, seed: 0)))
        await expectSubmissionFailure(engine, image, backendID: "A", expected: .unsupportedCapability(.imageGeneration))
        await expectInvalidSubmission(engine, request(input: .text(TextRequest(prompt: "bad", maxTokens: 0))),
                                      backendID: "A")
        #expect((await backendA.observations()).calls.isEmpty)
        #expect((await backendB.observations()).calls.isEmpty)

        let restricted = request(input: .text(TextRequest(prompt: "restricted", maxTokens: 9)))
        let limitingBase = ControlledBackend(id: "limit-base")
        let limitingA = MaximumTokensBackend(id: "A", maximumOutputTokens: 8, wrapped: limitingBase)
        let capableB = ControlledBackend(id: "B")
        let restrictedEngine = try runtime([limitingA, capableB])
        let rejectedRun = try await restrictedEngine.submit(restricted, backendID: "A")
        #expect(await rejectedRun.outcome() == .failed(
            .invalidRequest("Text request exceeds the selected execution capability.")))
        #expect(await limitingA.rejectionAndReleaseCounts() == (1, 1))
        #expect((await limitingBase.observations()).calls.isEmpty)
        #expect((await capableB.observations()).calls.isEmpty)
        #expect(await restrictedEngine.snapshot().reservedBytes == 0)
    }

    @Test("Cancellation retains the global lease across selected implementations")
    func cancellationDoesNotHandOffBeforeDrainAndRelease() async throws {
        let activeA = request()
        let cancelledB = request()
        let survivingB = request()
        let executeGate = TestGate()
        let releaseGate = TestGate()
        let backendA = ControlledBackend(id: "A", plans: [
            activeA.id: TestPlan(executeGate: executeGate, releaseGate: releaseGate)
        ])
        let backendB = ControlledBackend(id: "B")
        let engine = try runtime([backendA, backendB])

        let activeRun = try await engine.submit(activeA, backendID: "A")
        guard await waitForBackendCall(.executeStarted(activeA.id), in: backendA) else {
            await cleanup(engine, opening: [executeGate, releaseGate])
            return
        }
        let cancelledRun = try await engine.submit(cancelledB, backendID: "B")
        let survivingRun = try await engine.submit(survivingB, backendID: "B")
        await cancelledRun.cancel()
        #expect(await cancelledRun.outcome() == .cancelled)
        await activeRun.cancel()
        #expect(await engine.snapshot().phase == .cancelling)
        #expect((await backendB.observations()).calls.isEmpty)

        await executeGate.open()
        guard await waitForBackendCall(.releaseStarted(activeA.id), in: backendA) else {
            await cleanup(engine, opening: [releaseGate])
            return
        }
        let releasing = await engine.snapshot()
        #expect(releasing.activeRunID == activeA.id)
        #expect(releasing.phase == .releasing)
        #expect(releasing.queuedRunIDs == [survivingB.id])
        #expect(releasing.reservedBytes == 64)
        #expect((await backendB.observations()).calls.isEmpty)

        await releaseGate.open()
        #expect(await activeRun.outcome() == .cancelled)
        await expectCompleted(survivingRun)
        let callsB = await backendB.observations().calls
        #expect(!callsB.contains(.estimate(cancelledB.id)))
        #expect(!callsB.contains(.executeStarted(cancelledB.id)))
        #expect(callsB == [.estimate(survivingB.id), .executeStarted(survivingB.id),
                           .executeDrained(survivingB.id), .releaseStarted(survivingB.id),
                           .releaseFinished(survivingB.id)])
        #expect(await engine.snapshot().reservedBytes == 0)
    }

    @Test("Selected backend failure remains failed until its release permits queued work")
    func ordinaryFailureDoesNotFallbackOrMixResults() async throws {
        let failingA = request()
        let queuedB = request()
        let releaseGate = TestGate()
        let backendA = ControlledBackend(id: "A", plans: [
            failingA.id: TestPlan(releaseGate: releaseGate, shouldFail: true)
        ])
        let backendB = ControlledBackend(id: "B", plans: [
            queuedB.id: TestPlan(outputs: [.textDelta("from-B")])
        ])
        let engine = try runtime([backendA, backendB])

        let failedRun = try await engine.submit(failingA, backendID: "A")
        guard await waitForBackendCall(.releaseStarted(failingA.id), in: backendA) else {
            await cleanup(engine, opening: [releaseGate])
            return
        }
        let queuedRun = try await engine.submit(queuedB, backendID: "B")
        #expect(await engine.snapshot().activeRunID == failingA.id)
        #expect(await engine.snapshot().queuedRunIDs == [queuedB.id])
        #expect((await backendB.observations()).calls.isEmpty)

        await releaseGate.open()
        #expect(await failedRun.outcome() == .failed(.backendFailed("Controlled backend failure")))
        await expectCompleted(queuedRun)
        #expect(try await outputs(from: queuedRun) == [.textDelta("from-B")])
        #expect((await backendA.observations()).calls.map(requestID).allSatisfy { $0 == failingA.id })
        #expect((await backendB.observations()).calls.map(requestID).allSatisfy { $0 == queuedB.id })
        #expect(await engine.snapshot().reservedBytes == 0)
    }

    private func outputs(from run: InferenceRun) async throws -> [InferenceOutput] {
        var received: [InferenceOutput] = []
        for try await output in run.events { received.append(output) }
        return received
    }

    private func requestID(_ call: BackendCall) -> UUID {
        switch call {
        case .estimate(let id), .executeStarted(let id), .executeDrained(let id),
             .releaseStarted(let id), .releaseFinished(let id):
            id
        }
    }

    private func expectInvalidSubmission(_ engine: InferenceRuntime, _ invalid: InferenceRequest,
                                         backendID: String) async {
        do {
            _ = try await engine.submit(invalid, backendID: backendID)
            Issue.record("Expected invalid request rejection")
        } catch let failure as InferenceFailure {
            guard case .invalidRequest = failure else {
                Issue.record("Unexpected failure: \(failure)")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    /// TestGate intentionally has no cancellation-aware observer. Poll a backend event with a
    /// finite yield budget instead, so a regression cannot leave this test waiting forever.
    private func waitForBackendCall(_ expected: BackendCall, in backend: ControlledBackend,
                                    sourceLocation: SourceLocation = #_sourceLocation) async -> Bool {
        for _ in 0..<10_000 {
            if (await backend.observations()).calls.contains(expected) { return true }
            await Task.yield()
        }
        Issue.record("Timed out observing backend call \(expected)", sourceLocation: sourceLocation)
        return false
    }

    private func cleanup(_ engine: InferenceRuntime, opening gates: [TestGate]) async {
        for gate in gates { await gate.open() }
        await engine.cancelAllAndWait()
    }
}

private actor MaximumTokensBackend: InferenceBackend {
    nonisolated let descriptor: BackendDescriptor
    private let maximumOutputTokens: Int
    private let wrapped: ControlledBackend
    private var rejectedCount = 0
    private var releaseCount = 0

    init(id: String, maximumOutputTokens: Int, wrapped: ControlledBackend) {
        descriptor = BackendDescriptor(id: id, version: "test", capabilities: [.textGeneration])
        self.maximumOutputTokens = maximumOutputTokens
        self.wrapped = wrapped
    }

    func estimate(_ request: InferenceRequest) async throws -> ResourceEstimate {
        if case .text(let text) = request.input, text.maxTokens > maximumOutputTokens {
            rejectedCount += 1
            throw InferenceFailure.invalidRequest("Text request exceeds the selected execution capability.")
        }
        return try await wrapped.estimate(request)
    }

    func execute(_ request: InferenceRequest,
                 emit: @escaping @Sendable (InferenceOutput) async throws -> Void) async throws -> InferenceResult {
        try await wrapped.execute(request, emit: emit)
    }

    func release() async {
        releaseCount += 1
        await wrapped.release()
    }

    func rejectionAndReleaseCounts() -> (Int, Int) { (rejectedCount, releaseCount) }
}
