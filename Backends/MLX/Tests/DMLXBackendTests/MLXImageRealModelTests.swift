import CryptoKit
import Darwin
import DInference
import DMLXBackend
import DRuntime
import Foundation
import ImageIO
import Testing

extension MLXHardwareTests {
@Suite("Real pinned FLUX2 image backend", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["D_TEST_IMAGE_MODEL_DIR"] != nil))
struct MLXImageRealModelTests {
    private static let revision = "ef52ee019fd1d0e75ae4deb40476ba65989716d7"
    private static let prompt = "A red ceramic teapot on a wooden table beside a window, soft morning light, detailed studio photograph."
    private static let referencePNG = "05f0b80ac7d9d6e4ffa105af12a8805cdea4425a9448f9d35a1bd9d8f8dda553"

    @Test("Three runtime rounds reproduce the B1 image and release every allocation", .timeLimit(.minutes(3)))
    func repeatedGeneration() async throws {
        let directory = try Self.modelDirectory()
        let artifacts = try Self.artifactDirectory(model: directory)
        defer { artifacts.remove() }
        let trace = MLXTestTrace()
        let backend = try MLXImageBackend(configuration: .init(artifactDirectory: artifacts.url),
                                          observer: { await trace.lifecycle($0) })
        let wrapped = ImageTracedBackend(backend: backend, trace: trace)
        try await Self.withRuntime([wrapped]) { runtime in
            var hashes: [String] = []
            var urls: Set<URL> = []
            for round in 1...3 {
                let request = Self.request(directory: directory)
                let run = try await runtime.submit(request, backendID: backend.descriptor.id)
                let collected = await Self.collect(run, trace: trace)
                let result = try Self.completed(collected)
                let hash = try Self.validateImage(result, outputs: collected.outputs, root: artifacts.url)
                hashes.append(hash)
                urls.insert(try #require(result.artifacts.first).url)
                #expect(hash == Self.referencePNG, "The fixed prompt/seed must reproduce the reviewed B1 PNG")
                try await Self.expectReleased(trace, run: request.id, label: "normal-round-\(round)")
            }
            #expect(Set(hashes).count == 1)
            #expect(urls.count == 3, "Each run must publish its own artifact")
            try await backend.cleanupUnpublishedArtifacts()
            for url in urls { #expect(FileManager.default.fileExists(atPath: url.path)) }
            expectNoLateOutputs(await trace.entries())
        }
    }

    static let cancellationPhases: [MLXLifecycleEvent.Phase] = [
        .loadingTextEncoder, .textEncoderLoaded, .encoding, .encoded,
        .loadingTransformer, .transformerLoaded, .denoising, .loadingVAE,
        .vaeLoaded, .decoding, .decoded, .drained,
    ]

    @Test("Cancellation at an observed stage prevents subsequent stages and drains", .timeLimit(.minutes(3)),
          arguments: cancellationPhases)
    func cancellationAtStage(phase: MLXLifecycleEvent.Phase) async throws {
        let directory = try Self.modelDirectory()
        let artifacts = try Self.artifactDirectory(model: directory)
        defer { artifacts.remove() }
        let request = Self.request(directory: directory)
        let trace = MLXTestTrace()
        let gate = MLXTestGate()
        let backend = try MLXImageBackend(configuration: .init(artifactDirectory: artifacts.url), observer: { event in
            await trace.lifecycle(event)
            if event.runID == request.id && event.phase == phase { await gate.wait() }
        })
        let wrapped = ImageTracedBackend(backend: backend, trace: trace, blockedRun: request.id, gate: gate)
        try await Self.withRuntime([wrapped]) { runtime in
            let run = try await runtime.submit(request, backendID: backend.descriptor.id)
            let consumer = Task { await Self.collect(run, trace: trace) }
            do {
                try #require(await gate.waitForArrival(), "The backend must reach the selected real model stage")
                let phasesBeforeCancellation = await trace.events(for: run.id).map(\.phase)
                await run.cancel()
                await gate.open()
                let collected = await consumer.value
                #expect(collected.outcome == .cancelled)
                #expect(collected.streamFailed)
                let published = collected.outputs.compactMap { output -> ArtifactReference? in
                    if case .artifact(let artifact) = output { artifact } else { nil }
                }
                let events = await trace.events(for: run.id)
                let expectedSuffix: [MLXLifecycleEvent.Phase] = phase == .drained ? [.released] : [.drained, .released]
                #expect(events.map(\.phase) == phasesBeforeCancellation + expectedSuffix)
                try await Self.expectReleased(trace, run: run.id, label: "cancel-\(phase.rawValue)")
                expectNoLateOutputs(await trace.entries())
                try await backend.cleanupUnpublishedArtifacts()
                if phase == .drained {
                    #expect(published.count == 1, "Publication precedes the final drain checkpoint")
                    _ = try Self.checkPNG(try #require(published.first), root: artifacts.url)
                } else {
                    #expect(published.isEmpty)
                    #expect(try FileManager.default.contentsOfDirectory(atPath: artifacts.url.path).isEmpty)
                }
            } catch {
                await run.cancel()
                await gate.open()
                _ = await consumer.value
                throw error
            }
        }
    }

    @Test("Cancelled image releases before queued text and a subsequent image", .timeLimit(.minutes(3)))
    func imageTextImageQueue() async throws {
        let directory = try Self.modelDirectory()
        let textDirectory = try realModelDirectory()
        let artifacts = try Self.artifactDirectory(model: directory)
        defer { artifacts.remove() }
        let first = Self.request(directory: directory)
        let textRequest = mlxRequest(directory: textDirectory, maxTokens: 8)
        let last = Self.request(directory: directory)
        let trace = MLXTestTrace()
        let gate = MLXTestGate()
        let image = try MLXImageBackend(configuration: .init(artifactDirectory: artifacts.url), observer: { event in
            await trace.lifecycle(event)
            if event.runID == first.id && event.phase == .encoded { await gate.wait() }
        })
        let text = try MLXTextBackend(observer: { await trace.lifecycle($0) })
        let imageWrapper = ImageTracedBackend(backend: image, trace: trace, blockedRun: first.id, gate: gate)
        let textWrapper = TracedMLXBackend(backend: text, trace: trace)
        try await Self.withRuntime([imageWrapper, textWrapper]) { runtime in
            let initial = try await runtime.submit(first, backendID: image.descriptor.id)
            var consumers = [Task { await Self.collect(initial, trace: trace) }]
            do {
                try #require(await gate.waitForArrival())
                let middle = try await runtime.submit(textRequest, backendID: text.descriptor.id)
                consumers.append(Task { await Self.collect(middle, trace: trace) })
                let final = try await runtime.submit(last, backendID: image.descriptor.id)
                consumers.append(Task { await Self.collect(final, trace: trace) })
                let snapshot = await runtime.snapshot()
                #expect(snapshot.activeRunID == first.id)
                #expect(snapshot.queuedRunIDs == [textRequest.id, last.id])
                await initial.cancel()
                await gate.open()
                let cancelled = await consumers[0].value
                #expect(cancelled.outcome == .cancelled)
                let textOutput = await consumers[1].value
                _ = try Self.completed(textOutput)
                #expect(!textOutput.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                let imageOutput = await consumers[2].value
                let result = try Self.completed(imageOutput)
                _ = try Self.validateImage(result, outputs: imageOutput.outputs, root: artifacts.url)
                for request in [first, textRequest, last] {
                    try await Self.expectReleased(trace, run: request.id, label: "mixed-queue")
                }
                let entries = await trace.entries()
                try Self.expectBefore(entries, first: first.id, phase: .released, second: textRequest.id, next: .loading)
                try Self.expectBefore(entries, first: textRequest.id, phase: .released, second: last.id, next: .verifying)
                expectNoLateOutputs(entries)
                try await image.cleanupUnpublishedArtifacts()
            } catch {
                await gate.open()
                await runtime.cancelAllAndWait()
                for consumer in consumers { _ = await consumer.value }
                throw error
            }
        }
    }

    enum RejectedOutput: String, CaseIterable, Sendable { case progress, artifact }
    private enum ConsumerFailure: Error { case rejected }

    @Test("A throwing direct consumer drains, preserves published PNG, and permits recovery", .timeLimit(.minutes(3)),
          arguments: RejectedOutput.allCases)
    func throwingConsumer(kind: RejectedOutput) async throws {
        let directory = try Self.modelDirectory()
        let artifacts = try Self.artifactDirectory(model: directory)
        defer { artifacts.remove() }
        let request = Self.request(directory: directory)
        let trace = MLXTestTrace()
        let outputs = ImageOutputStore()
        let backend = try MLXImageBackend(configuration: .init(artifactDirectory: artifacts.url),
                                          observer: { await trace.lifecycle($0) })
        var rejected = false
        do {
            _ = try await backend.execute(request) { output in
                await trace.output(request.id)
                await outputs.append(output)
                switch (kind, output) {
                case (.progress, .progress), (.artifact, .artifact): throw ConsumerFailure.rejected
                default: break
                }
            }
        } catch ConsumerFailure.rejected {
            rejected = true
        } catch {
            await backend.release()
            try? await backend.cleanupUnpublishedArtifacts()
            throw error
        }
        await backend.release()
        await trace.terminal(request.id)
        #expect(rejected, "The selected consumer callback must actually throw")
        try await Self.expectReleased(trace, run: request.id, label: "consumer-\(kind.rawValue)")
        let observed = await outputs.values()
        let published = observed.compactMap { output -> ArtifactReference? in
            if case .artifact(let artifact) = output { artifact } else { nil }
        }
        if kind == .artifact {
            let artifact = try #require(published.first)
            #expect(published.count == 1)
            _ = try Self.checkPNG(artifact, root: artifacts.url)
            try await backend.cleanupUnpublishedArtifacts()
            #expect(FileManager.default.fileExists(atPath: artifact.url.path),
                    "Consumer failure must not roll back an already published image")
        } else {
            #expect(published.isEmpty)
            #expect(observed == [.progress(completed: 0, total: 4)])
        }
        expectNoLateOutputs(await trace.entries())
        // A real follow-up proves that release restored the process lease and backend state.
        let wrapped = ImageTracedBackend(backend: backend, trace: trace)
        try await Self.withRuntime([wrapped]) { runtime in
            let run = try await runtime.submit(Self.request(directory: directory), backendID: backend.descriptor.id)
            let collected = await Self.collect(run, trace: trace)
            let result = try Self.completed(collected)
            _ = try Self.validateImage(result, outputs: collected.outputs, root: artifacts.url)
            // The backend observer is the original trace for both executions.
            try await Self.expectReleased(trace, run: run.id, label: "consumer-recovery-\(kind.rawValue)")
            try await backend.cleanupUnpublishedArtifacts()
            expectNoLateOutputs(await trace.entries())
        }
    }

    @Test("A damaged COW copy of VAE weights fails verification before loading", .timeLimit(.minutes(3)))
    func damagedWeightVerification() async throws {
        let directory = try Self.modelDirectory()
        let copy = try Self.artifactDirectory(model: directory)
        let artifacts = try Self.artifactDirectory(model: directory)
        defer { copy.remove(); artifacts.remove() }
        try copy.copyModel(from: directory)
        let original = directory.appendingPathComponent("vae/diffusion_pytorch_model.safetensors")
        let damaged = copy.url.appendingPathComponent("vae/diffusion_pytorch_model.safetensors")
        // Remove only the test-owned hard link, then create an independent APFS COW clone.
        try FileManager.default.removeItem(at: damaged)
        let result = original.path.withCString { source in
            damaged.path.withCString { destination in Darwin.clonefile(source, destination, 0) }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let sourceInode = try FileManager.default.attributesOfItem(atPath: original.path)[.systemFileNumber] as? NSNumber
        let cloneInode = try FileManager.default.attributesOfItem(atPath: damaged.path)[.systemFileNumber] as? NSNumber
        try #require(sourceInode != nil && cloneInode != nil && sourceInode != cloneInode)
        let sourceByte = try Self.byte(at: original, offset: 65_536)
        let file = try FileHandle(forWritingTo: damaged)
        do {
            try file.seek(toOffset: 65_536)
            try file.write(contentsOf: Data([sourceByte ^ 0xFF]))
            try file.close()
        } catch { try? file.close(); throw error }
        #expect(try Self.byte(at: original, offset: 65_536) == sourceByte, "The original model must be unchanged")
        let trace = MLXTestTrace()
        let backend = try MLXImageBackend(configuration: .init(artifactDirectory: artifacts.url),
                                          observer: { await trace.lifecycle($0) })
        let wrapped = ImageTracedBackend(backend: backend, trace: trace)
        try await Self.withRuntime([wrapped]) { runtime in
            let run = try await runtime.submit(Self.request(directory: copy.url), backendID: backend.descriptor.id)
            let collected = await Self.collect(run, trace: trace)
            guard case .failed = collected.outcome else {
                Issue.record("Damaged weights must fail, received \(collected.outcome)")
                throw CocoaError(.coderInvalidValue)
            }
            #expect(collected.streamFailed)
            #expect(collected.outputs.isEmpty)
            #expect(await trace.events(for: run.id).map(\.phase) == [.verifying, .drained, .released])
            try await Self.expectReleased(trace, run: run.id, label: "damaged-vae-copy")
            expectNoLateOutputs(await trace.entries())
        }
    }

    @Test("A moved test-owned artifact root fails publication and still releases", .timeLimit(.minutes(3)))
    func artifactRootDisappears() async throws {
        let directory = try Self.modelDirectory()
        let artifacts = try Self.artifactDirectory(model: directory)
        let movedRoot = artifacts.url.appendingPathExtension("temporarily-unavailable")
        defer { artifacts.remove(); try? FileManager.default.removeItem(at: movedRoot) }
        let request = Self.request(directory: directory)
        let trace = MLXTestTrace()
        let gate = MLXTestGate()
        let backend = try MLXImageBackend(configuration: .init(artifactDirectory: artifacts.url), observer: { event in
            await trace.lifecycle(event)
            if event.runID == request.id && event.phase == .publishing { await gate.wait() }
        })
        let wrapped = ImageTracedBackend(backend: backend, trace: trace, blockedRun: request.id, gate: gate)
        try await Self.withRuntime([wrapped]) { runtime in
            let run = try await runtime.submit(request, backendID: backend.descriptor.id)
            let consumer = Task { await Self.collect(run, trace: trace) }
            do {
                try #require(await gate.waitForArrival())
                // This moves only our new random test directory; no volume or user directory is touched.
                try FileManager.default.moveItem(at: artifacts.url, to: movedRoot)
                await gate.open()
                let collected = await consumer.value
                guard case .failed = collected.outcome else {
                    Issue.record("Unavailable output root must fail publication, received \(collected.outcome)")
                    throw CocoaError(.coderInvalidValue)
                }
                #expect(collected.streamFailed)
                #expect(!collected.outputs.contains { if case .artifact = $0 { true } else { false } })
                #expect(await trace.events(for: run.id).map(\.phase).suffix(3) == [.publishing, .drained, .released])
                try await Self.expectReleased(trace, run: run.id, label: "artifact-root-moved")
                expectNoLateOutputs(await trace.entries())
                #expect(try FileManager.default.contentsOfDirectory(atPath: movedRoot.path).isEmpty)
                try await backend.cleanupUnpublishedArtifacts()
            } catch {
                await run.cancel()
                await gate.open()
                _ = await consumer.value
                throw error
            }
        }
    }

    @Test("A real overlong prompt is rejected before loading text-encoder weights", .timeLimit(.minutes(3)))
    func overlongPrompt() async throws {
        let directory = try Self.modelDirectory()
        let artifacts = try Self.artifactDirectory(model: directory)
        defer { artifacts.remove() }
        let trace = MLXTestTrace()
        let backend = try MLXImageBackend(configuration: .init(artifactDirectory: artifacts.url),
                                          observer: { await trace.lifecycle($0) })
        let wrapped = ImageTracedBackend(backend: backend, trace: trace)
        try await Self.withRuntime([wrapped]) { runtime in
            let request = Self.request(directory: directory, prompt: String(repeating: " orange", count: 600))
            let run = try await runtime.submit(request, backendID: backend.descriptor.id)
            let collected = await Self.collect(run, trace: trace)
            guard case .failed(let failure) = collected.outcome else {
                Issue.record("Expected overlong prompt failure, received \(collected.outcome)")
                throw CocoaError(.coderInvalidValue)
            }
            if case .invalidRequest = failure {} else { Issue.record("Unexpected failure: \(failure)") }
            #expect(collected.streamFailed)
            #expect(collected.outputs.isEmpty)
            let events = await trace.events(for: request.id)
            #expect(events.map(\.phase) == [.verifying, .tokenizing, .drained, .released])
            try await Self.expectReleased(trace, run: request.id, label: "overlong-prompt")
            expectNoLateOutputs(await trace.entries())
            try await backend.cleanupUnpublishedArtifacts()
        }
    }

    private static func request(directory: URL, prompt: String? = nil) -> InferenceRequest {
        InferenceRequest(model: ModelReference(directory: directory, revision: revision),
                         input: .image(ImageRequest(prompt: prompt ?? Self.prompt, width: 512, height: 512,
                                                   steps: 4, guidanceScale: 1, seed: 42)))
    }

    private static func byte(at url: URL, offset: UInt64) throws -> UInt8 {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        try file.seek(toOffset: offset)
        return try #require(file.read(upToCount: 1)?.first)
    }

    private static func modelDirectory() throws -> URL {
        let path = try #require(ProcessInfo.processInfo.environment["D_TEST_IMAGE_MODEL_DIR"])
        try #require(!path.isEmpty)
        let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        try #require(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue)
        return url
    }

    private static func artifactDirectory(model: URL) throws -> TemporaryModelDirectory {
        let base = ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? model.deletingLastPathComponent()
        return try TemporaryModelDirectory(parent: base)
    }

    private static func withRuntime<Value: Sendable>(_ backends: [any InferenceBackend],
                                                     operation: (InferenceRuntime) async throws -> Value) async throws -> Value {
        let runtime = try InferenceRuntime(backends: backends, configuration: .init(
            memoryBudgetBytes: 10 * 1024 * 1024 * 1024, maximumQueuedRuns: 2, eventBufferCapacity: 2048))
        do {
            let result = try await operation(runtime)
            await runtime.shutdown()
            return result
        } catch {
            await runtime.shutdown()
            throw error
        }
    }

    private struct Collected: Sendable {
        let outputs: [InferenceOutput]
        let outcome: RunOutcome
        let streamFailed: Bool
        var text: String {
            outputs.compactMap { if case .textDelta(let text) = $0 { text } else { nil } }.joined()
        }
    }

    private static func collect(_ run: InferenceRun, trace: MLXTestTrace) async -> Collected {
        var outputs: [InferenceOutput] = []
        var failed = false
        do { for try await output in run.events { outputs.append(output) } }
        catch { failed = true }
        let outcome = await run.outcome()
        await trace.terminal(run.id)
        return Collected(outputs: outputs, outcome: outcome, streamFailed: failed)
    }

    private static func completed(_ collected: Collected) throws -> InferenceResult {
        #expect(!collected.streamFailed)
        guard case .completed(let result) = collected.outcome else {
            Issue.record("Expected completed inference, received \(collected.outcome)")
            throw CocoaError(.coderInvalidValue)
        }
        return result
    }

    private static func validateImage(_ result: InferenceResult, outputs: [InferenceOutput], root: URL) throws -> String {
        #expect(result.artifacts.count == 1)
        let artifact = try #require(result.artifacts.first)
        let expected = (0...4).map { InferenceOutput.progress(completed: $0, total: 4) } + [.artifact(artifact)]
        #expect(outputs == expected)
        let hash = try checkPNG(artifact, root: root)
        for (key, value) in ["width": "512", "height": "512", "steps": "4", "seed": "42",
                             "guidanceScale": "1.0", "textSequenceLength": "512", "promptTruncated": "false",
                             "modelTimestepScale": "0.001", "pngDecodedAndValidated": "true",
                             "modelRepository": "mzbac/FLUX.2-klein-4B-q8", "modelRevision": revision,
                             "flux2SourceRevision": "959a4af7c0721c800851c84431ffd3fa1f353f1f"] {
            #expect(result.metadata[key] == value, "Image metadata \(key)")
        }
        #expect(try #require(result.metadata["weightBytes"].flatMap(UInt64.init)) > 0)
        #expect(result.metadata["estimatedPeakBytes"] == String(8 * 1024 * 1024 * 1024))
        #expect(result.metadata["pngBytes"].flatMap(Int.init) == (try Data(contentsOf: artifact.url).count))
        print("MLX image PNG: \(hash); metadata: \(result.metadata)")
        return hash
    }

    private static func checkPNG(_ artifact: ArtifactReference, root: URL) throws -> String {
        #expect(artifact.mediaType == "image/png")
        try #require(artifact.url.isFileURL && artifact.url.standardizedFileURL.path.hasPrefix(root.path + "/"))
        let data = try Data(contentsOf: artifact.url)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        #expect(CGImageSourceGetCount(source) == 1)
        #expect(CGImageSourceGetType(source) as String? == "public.png")
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == 512)
        #expect((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == 512)
        let decoded = try #require(CGImageSourceCreateImageAtIndex(
            source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary))
        #expect(decoded.width == 512 && decoded.height == 512)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func expectReleased(_ trace: MLXTestTrace, run: UUID, label: String) async throws {
        let events = await trace.events(for: run)
        #expect(events.map(\.phase).suffix(2) == [.drained, .released])
        #expect(events.filter { $0.phase == .drained }.count == 1)
        #expect(events.filter { $0.phase == .released }.count == 1)
        let drained = try #require(events.first { $0.phase == .drained })
        let released = try #require(events.last)
        #expect(released.memory.activeBytes == 0)
        #expect(released.memory.cacheBytes == 0)
        #expect(drained.uptimeSeconds <= released.uptimeSeconds)
        #expect(zip(events, events.dropFirst()).allSatisfy { $0.uptimeSeconds <= $1.uptimeSeconds })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        print("MLX image lifecycle \(label): \(String(decoding: try encoder.encode(events), as: UTF8.self))")
    }

    private static func expectBefore(_ entries: [MLXTraceEntry], first: UUID, phase: MLXLifecycleEvent.Phase,
                                     second: UUID, next: MLXLifecycleEvent.Phase) throws {
        let firstIndex = try #require(entries.firstIndex {
            if case .lifecycle(let event) = $0 { event.runID == first && event.phase == phase } else { false }
        })
        let secondIndex = try #require(entries.firstIndex {
            if case .lifecycle(let event) = $0 { event.runID == second && event.phase == next } else { false }
        })
        #expect(firstIndex < secondIndex, "The preceding backend must release before the next one loads")
    }

    private actor ImageOutputStore {
        private var outputs: [InferenceOutput] = []
        func append(_ output: InferenceOutput) { outputs.append(output) }
        func values() -> [InferenceOutput] { outputs }
    }

    private struct ImageTracedBackend: InferenceBackend {
        let backend: MLXImageBackend
        let trace: MLXTestTrace
        var blockedRun: UUID?
        var gate: MLXTestGate?
        var descriptor: BackendDescriptor { backend.descriptor }

        func estimate(_ request: InferenceRequest) async throws -> ResourceEstimate {
            do { return try await backend.estimate(request) }
            catch {
                if request.id == blockedRun { await gate?.executionFinished() }
                throw error
            }
        }

        func execute(_ request: InferenceRequest,
                     emit: @escaping @Sendable (InferenceOutput) async throws -> Void) async throws -> InferenceResult {
            do {
                let result = try await backend.execute(request) { output in
                    await trace.output(request.id)
                    try await emit(output)
                }
                if request.id == blockedRun { await gate?.executionFinished() }
                return result
            } catch {
                if request.id == blockedRun { await gate?.executionFinished() }
                throw error
            }
        }

        func release() async { await backend.release() }
    }
}
}
