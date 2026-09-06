import DInference
import DMLXBackend
import DRuntime
import Foundation
import Testing

/// Intentionally opt-in: the acceptance script sets this variable in the XCTest process.
/// A skipped suite is never evidence that real inference was tested successfully.
@Suite("Real local MLX model", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["D_TEST_MODEL_DIR"] != nil))
struct MLXRealModelTests {
    @Test("Greedy generation streams text with bounded token count and provenance")
    func greedyGeneration() async throws {
        let directory = try realModelDirectory()
        let trace = MLXTestTrace()
        let backend = try MLXTextBackend(observer: { await trace.lifecycle($0) })
        let instrumented = TracedMLXBackend(backend: backend, trace: trace)
        let request = mlxRequest(directory: directory, maxTokens: 24)
        try await withMLXRuntime(instrumented) { runtime in
            let run = try await runtime.submit(request, backendID: backend.descriptor.id)
            let result = try requireCompleted(await collectMLXRun(run, trace: trace))
            let tokens = try #require(result.metadata["generationTokens"].flatMap(Int.init))
            #expect((1...24).contains(tokens))
            #expect(try #require(result.metadata["promptTokens"].flatMap(Int.init)) > 0)
            #expect(result.metadata["modelRevision"] == "acceptance-fixture")
            #expect(try #require(result.metadata["weightBytes"].flatMap(UInt64.init)) > 0)
            #expect(try #require(result.metadata["estimatedPeakBytes"].flatMap(UInt64.init)) > 0)
            #expect(try #require(result.metadata["generationSeconds"].flatMap(Double.init)) >= 0)
            #expect(!(result.metadata["stopReason"] ?? "").isEmpty)
            expectReleasedLifecycle(await trace.events(for: request.id))
            expectNoLateOutputs(await trace.entries())
        }
    }

    @Test("A one-token request stops at the explicit token limit instead of EOS")
    func exactTokenLimit() async throws {
        let directory = try realModelDirectory()
        let trace = MLXTestTrace()
        let backend = try MLXTextBackend(observer: { await trace.lifecycle($0) })
        let instrumented = TracedMLXBackend(backend: backend, trace: trace)
        let request = mlxRequest(directory: directory, maxTokens: 1,
                                 prompt: "List the integers from 1 to 20, in order, separated by commas.")
        try await withMLXRuntime(instrumented) { runtime in
            let run = try await runtime.submit(request, backendID: backend.descriptor.id)
            let result = try requireCompleted(await collectMLXRun(run, trace: trace))
            #expect(result.metadata["generationTokens"] == "1")
            #expect(result.metadata["stopReason"] == "length",
                    "The fixed counting prompt must produce a token and exercise the explicit length limit")
            expectReleasedLifecycle(await trace.events(for: request.id))
            expectNoLateOutputs(await trace.entries())
        }
    }

    @Test("Cancellation after loading skips generation, releases the model, and permits recovery")
    func cancellationAfterLoading() async throws {
        let directory = try realModelDirectory()
        let trace = MLXTestTrace()
        let loadedGate = MLXTestGate()
        let firstRequest = mlxRequest(directory: directory, maxTokens: 16)
        let backend = try MLXTextBackend(observer: { event in
            await trace.lifecycle(event)
            if event.runID == firstRequest.id, event.phase == .loaded { await loadedGate.wait() }
        })
        // The forwarding wrapper also signals failed execution, preventing waitForArrival
        // from hanging if model loading fails before the observer can reach .loaded.
        let instrumented = TracedMLXBackend(backend: backend, trace: trace,
                                          blockedRun: firstRequest.id, outputGate: loadedGate)
        try await withMLXRuntime(instrumented) { runtime in
            let first = try await runtime.submit(firstRequest, backendID: backend.descriptor.id)
            let firstConsumer = Task { await collectMLXRun(first, trace: trace) }
            do {
                try #require(await loadedGate.waitForArrival(), "Cancellation must follow a successful model load")
                let beforeCancellation = await trace.events(for: first.id)
                #expect(beforeCancellation.map(\.phase) == [.loading, .loaded])
                await first.cancel()
                await loadedGate.open()
                let cancelled = await firstConsumer.value
                #expect(cancelled.outcome == .cancelled)
                #expect(cancelled.streamFailed)
                #expect(cancelled.text.isEmpty)
                let events = await trace.events(for: first.id)
                #expect(events.map(\.phase) == [.loading, .loaded, .drained, .released])
                expectReleasedLifecycle(events, completed: false)
                let recovered = try await runtime.submit(mlxRequest(directory: directory, maxTokens: 8),
                                                         backendID: backend.descriptor.id)
                _ = try requireCompleted(await collectMLXRun(recovered, trace: trace))
                expectReleasedLifecycle(await trace.events(for: recovered.id))
                expectNoLateOutputs(await trace.entries())
            } catch {
                await loadedGate.open()
                await first.cancel()
                _ = await firstConsumer.value
                throw error
            }
        }
    }

    @Test("Cancellation after a real chunk drains and releases before queued generation loads")
    func cancellationAndQueue() async throws {
        let directory = try realModelDirectory()
        let trace = MLXTestTrace()
        let gate = MLXTestGate()
        let firstRequest = mlxRequest(directory: directory, maxTokens: 128,
                                      prompt: "List the integers from 1 to 100, in order, separated by commas.")
        let secondRequest = mlxRequest(directory: directory, maxTokens: 12)
        let backend = try MLXTextBackend(observer: { await trace.lifecycle($0) })
        let instrumented = TracedMLXBackend(backend: backend, trace: trace,
                                          blockedRun: firstRequest.id, outputGate: gate)
        try await withMLXRuntime(instrumented) { runtime in
            let first = try await runtime.submit(firstRequest, backendID: backend.descriptor.id)
            let firstConsumer = Task { await collectMLXRun(first, trace: trace) }
            do {
                let arrived = await gate.waitForArrival()
                try #require(arrived, "Model must emit a real chunk before cancellation is tested")
                let second = try await runtime.submit(secondRequest, backendID: backend.descriptor.id)
                let secondConsumer = Task { await collectMLXRun(second, trace: trace) }
                let snapshot = await runtime.snapshot()
                #expect(snapshot.activeRunID == first.id)
                #expect(snapshot.queuedRunIDs == [second.id])
                let cancellationStart = ProcessInfo.processInfo.systemUptime
                await first.cancel()
                await gate.open()
                let cancelled = await firstConsumer.value
                let cancellationSeconds = ProcessInfo.processInfo.systemUptime - cancellationStart
                #expect(cancelled.outcome == .cancelled)
                #expect(cancelled.streamFailed)
                #expect(!cancelled.text.isEmpty)
                _ = try requireCompleted(await secondConsumer.value)
                let firstEvents = await trace.events(for: first.id)
                let secondEvents = await trace.events(for: second.id)
                expectReleasedLifecycle(firstEvents)
                expectReleasedLifecycle(secondEvents)
                let released = try #require(firstEvents.last)
                let loading = try #require(secondEvents.first)
                #expect(released.uptimeSeconds < loading.uptimeSeconds)
                let entries = await trace.entries()
                let releaseIndex = try #require(entries.firstIndex {
                    if case .lifecycle(let event) = $0 { return event.runID == first.id && event.phase == .released }
                    return false
                })
                let loadIndex = try #require(entries.firstIndex {
                    if case .lifecycle(let event) = $0 { return event.runID == second.id && event.phase == .loading }
                    return false
                })
                #expect(releaseIndex < loadIndex)
                expectNoLateOutputs(entries)
                print("D_MLX_CANCELLATION seconds=\(cancellationSeconds)")
            } catch {
                // Opening the deterministic gate must precede runtime shutdown, including assertion failure.
                await gate.open()
                await first.cancel()
                _ = await firstConsumer.value
                throw error
            }
        }
    }

    @Test("Five complete load/generate/release cycles retain a bounded MLX allocation baseline")
    func repeatedRelease() async throws {
        let directory = try realModelDirectory()
        let trace = MLXTestTrace()
        let backend = try MLXTextBackend(observer: { await trace.lifecycle($0) })
        let instrumented = TracedMLXBackend(backend: backend, trace: trace)
        try await withMLXRuntime(instrumented) { runtime in
            var releaseSnapshots: [MLXMemorySnapshot] = []
            for index in 0..<5 {
                let request = mlxRequest(directory: directory, maxTokens: 8)
                let run = try await runtime.submit(request, backendID: backend.descriptor.id)
                _ = try requireCompleted(await collectMLXRun(run, trace: trace))
                let events = await trace.events(for: run.id)
                expectReleasedLifecycle(events)
                let loaded = try #require(events.first { $0.phase == .loaded })
                let released = try #require(events.last)
                #expect(loaded.memory.activeBytes > released.memory.activeBytes)
                releaseSnapshots.append(released.memory)
                print("D_MLX_RELEASE cycle=\(index + 1) activeBytes=\(released.memory.activeBytes) cacheBytes=\(released.memory.cacheBytes) peakBytes=\(released.memory.peakBytes)")
            }
            let baseline = try #require(releaseSnapshots.first)
            // The original 2720-byte/load leak must fail this short-run regression check.
            // A small bookkeeping allowance is separate from the C++ weak-reference lifetime tests;
            // neither measurement promises that process RSS falls to zero.
            for sample in releaseSnapshots.dropFirst() {
                #expect(sample.activeBytes <= baseline.activeBytes + 1024)
                #expect(sample.cacheBytes == 0)
            }
            expectNoLateOutputs(await trace.entries())
        }
    }

    @Test("Tokenizer failure during loading releases partial state and the same backend recovers")
    func partialLoadFailure() async throws {
        let directory = try realModelDirectory()
        let broken = try TemporaryModelDirectory(parent: directory.deletingLastPathComponent())
        defer { broken.remove() }
        try broken.copyModel(from: directory)
        let sourceTokenizer = directory.appendingPathComponent("tokenizer_config.json")
        let originalTokenizerBytes = try Data(contentsOf: sourceTokenizer)
        try Data("{ invalid-json".utf8).write(to: broken.url.appendingPathComponent("tokenizer_config.json"))
        #expect(try Data(contentsOf: sourceTokenizer) == originalTokenizerBytes)
        let trace = MLXTestTrace()
        let backend = try MLXTextBackend(observer: { await trace.lifecycle($0) })
        let instrumented = TracedMLXBackend(backend: backend, trace: trace)
        try await withMLXRuntime(instrumented) { runtime in
            let badRequest = mlxRequest(directory: broken.url, maxTokens: 8)
            // Prove that admission accepts the files; the failure must occur inside loading.
            #expect(try await backend.estimate(badRequest).peakBytes > 0)
            let failedRun = try await runtime.submit(badRequest, backendID: backend.descriptor.id)
            let failed = await collectMLXRun(failedRun, trace: trace)
            if case .failed = failed.outcome {} else {
                Issue.record("Corrupted tokenizer unexpectedly produced \(failed.outcome)")
            }
            #expect(failed.streamFailed)
            #expect(failed.text.isEmpty)
            let failureEvents = await trace.events(for: failedRun.id)
            expectReleasedLifecycle(failureEvents, completed: false)
            #expect(!failureEvents.contains { $0.phase == .loaded || $0.phase == .generating })
            #expect(try #require(failureEvents.last).memory.peakBytes > 0)
            let recovered = try await runtime.submit(mlxRequest(directory: directory, maxTokens: 8),
                                                     backendID: backend.descriptor.id)
            _ = try requireCompleted(await collectMLXRun(recovered, trace: trace))
            expectReleasedLifecycle(await trace.events(for: recovered.id))
            expectNoLateOutputs(await trace.entries())
        }
    }

    @Test("A throwing emit drains generation before execute throws and release permits reuse")
    func throwingConsumer() async throws {
        enum ConsumerClosed: Error { case intentionallyClosed }
        let directory = try realModelDirectory()
        let trace = MLXTestTrace()
        let backend = try MLXTextBackend(observer: { await trace.lifecycle($0) })
        let request = mlxRequest(directory: directory, maxTokens: 128)
        do {
            _ = try await backend.execute(request) { _ in
                await trace.output(request.id)
                throw ConsumerClosed.intentionallyClosed
            }
            Issue.record("The consumer failure was swallowed")
        } catch ConsumerClosed.intentionallyClosed {
            // The original error must propagate, after the owned generation task has drained.
        } catch {
            await backend.release()
            throw error
        }
        let beforeRelease = await trace.events(for: request.id)
        #expect(beforeRelease.last?.phase == .drained)
        await backend.release()
        await trace.terminal(request.id)
        await backend.release() // Cleanup is idempotent.
        expectReleasedLifecycle(await trace.events(for: request.id))
        try await withMLXRuntime(TracedMLXBackend(backend: backend, trace: trace)) { runtime in
            let run = try await runtime.submit(mlxRequest(directory: directory, maxTokens: 8),
                                               backendID: backend.descriptor.id)
            _ = try requireCompleted(await collectMLXRun(run, trace: trace))
            expectReleasedLifecycle(await trace.events(for: run.id))
            expectNoLateOutputs(await trace.entries())
        }
    }
}
