import DInference
import DMLXBackend
import DRuntime
import Foundation
import Testing

struct TemporaryModelDirectory {
    let url: URL

    init(parent: URL? = nil) throws {
        let environment = ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"]
        let base = parent ?? environment.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        url = base.appendingPathComponent("d-mlx-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: url) }

    func writeMetadata(modelType: String = "qwen2") throws {
        let config: [String: Any] = [
            "model_type": modelType, "hidden_size": 896, "num_hidden_layers": 24,
            "num_attention_heads": 14, "num_key_value_heads": 2,
            "max_position_embeddings": 32768, "vocab_size": 151936, "intermediate_size": 4864,
        ]
        try JSONSerialization.data(withJSONObject: config).write(to: url.appendingPathComponent("config.json"))
        for name in ["tokenizer.json", "tokenizer_config.json"] {
            try Data("{}".utf8).write(to: url.appendingPathComponent(name))
        }
    }

    /// Deliberately invalid tensor bytes: estimate must inspect sizes without loading them.
    func writeFakeWeights() throws {
        try Data(repeating: 0xA5, count: 1024).write(to: url.appendingPathComponent("model.safetensors"))
    }

    /// Hard-link only weights. Every editable metadata file is an independent copy.
    func copyModel(from source: URL) throws {
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let enumerator = manager.enumerator(at: source, includingPropertiesForKeys: Array(keys)) else {
            throw CocoaError(.fileReadUnknown)
        }
        for case let input as URL in enumerator {
            let values = try input.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true else { throw CocoaError(.fileReadUnsupportedScheme) }
            let relative = String(input.path.dropFirst(source.path.count + 1))
            let output = url.appendingPathComponent(relative)
            if values.isDirectory == true {
                try manager.createDirectory(at: output, withIntermediateDirectories: true)
            } else if input.pathExtension == "safetensors" {
                try manager.linkItem(at: input, to: output)
            } else {
                try manager.copyItem(at: input, to: output)
            }
        }
    }
}

func mlxRequest(directory: URL, id: UUID = UUID(), maxTokens: Int = 16,
                prompt: String = "Answer in one short sentence: What is two plus two?") -> InferenceRequest {
    InferenceRequest(id: id, model: ModelReference(directory: directory, revision: "acceptance-fixture"),
                     input: .text(TextRequest(prompt: prompt, maxTokens: maxTokens, temperature: 0)))
}

func realModelDirectory() throws -> URL {
    let path = try #require(ProcessInfo.processInfo.environment["D_TEST_MODEL_DIR"])
    let directory = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    var isDirectory: ObjCBool = false
    try #require(FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory)
                 && isDirectory.boolValue, "D_TEST_MODEL_DIR must point to the downloaded model directory")
    return directory
}

actor MLXTestGate {
    private var opened = false
    private var arrived = false
    private var executionEnded = false
    private var arrivals: [CheckedContinuation<Bool, Never>] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        arrived = true
        let pending = arrivals
        arrivals.removeAll()
        for item in pending { item.resume(returning: true) }
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func waitForArrival() async -> Bool {
        if arrived { return true }
        if executionEnded { return false }
        return await withCheckedContinuation { arrivals.append($0) }
    }

    func executionFinished() {
        executionEnded = true
        let pending = arrivals
        arrivals.removeAll()
        for item in pending { item.resume(returning: arrived) }
    }

    func open() {
        opened = true
        let pending = waiters
        waiters.removeAll()
        for item in pending { item.resume() }
    }
}

enum MLXTraceEntry: Sendable {
    case lifecycle(MLXLifecycleEvent)
    /// An attempted callback, including one subsequently rejected by the runtime.
    case output(UUID)
    case terminal(UUID)
}

actor MLXTestTrace {
    private var values: [MLXTraceEntry] = []

    func lifecycle(_ event: MLXLifecycleEvent) { values.append(.lifecycle(event)) }
    func output(_ id: UUID) { values.append(.output(id)) }
    func terminal(_ id: UUID) { values.append(.terminal(id)) }
    func entries() -> [MLXTraceEntry] { values }

    func events(for id: UUID) -> [MLXLifecycleEvent] {
        values.compactMap {
            if case .lifecycle(let event) = $0, event.runID == id { return event }
            return nil
        }
    }
}

/// Observes the actual backend emit boundary. A gate after forwarding the first output
/// makes cancellation deterministic even if a tiny model could otherwise finish first.
struct TracedMLXBackend: InferenceBackend {
    let backend: MLXTextBackend
    let trace: MLXTestTrace
    var blockedRun: UUID?
    var outputGate: MLXTestGate?

    var descriptor: BackendDescriptor { backend.descriptor }
    func estimate(_ request: InferenceRequest) async throws -> ResourceEstimate {
        do { return try await backend.estimate(request) }
        catch {
            if request.id == blockedRun { await outputGate?.executionFinished() }
            throw error
        }
    }
    func execute(_ request: InferenceRequest,
                 emit: @escaping @Sendable (InferenceOutput) async throws -> Void) async throws -> InferenceResult {
        do {
            let result = try await backend.execute(request) { output in
                // Record before forwarding: the runtime correctly rejects late callbacks,
                // but that rejection must not hide a backend ownership violation in this trace.
                await trace.output(request.id)
                try await emit(output)
                if request.id == blockedRun, let outputGate { await outputGate.wait() }
            }
            if request.id == blockedRun { await outputGate?.executionFinished() }
            return result
        } catch {
            if request.id == blockedRun { await outputGate?.executionFinished() }
            throw error
        }
    }
    func release() async { await backend.release() }
}

func withMLXRuntime<T: Sendable>(_ backend: any InferenceBackend,
                               operation: (InferenceRuntime) async throws -> T) async throws -> T {
    let runtime = try InferenceRuntime(backends: [backend], configuration: .init(
        memoryBudgetBytes: 6 * 1024 * 1024 * 1024, maximumQueuedRuns: 2, eventBufferCapacity: 2048))
    do {
        let value = try await operation(runtime)
        await runtime.shutdown()
        return value
    } catch {
        await runtime.shutdown()
        throw error
    }
}

struct CollectedMLXRun: Sendable {
    let text: String
    let outcome: RunOutcome
    let streamFailed: Bool
}

func collectMLXRun(_ run: InferenceRun, trace: MLXTestTrace) async -> CollectedMLXRun {
    var text = ""
    var streamFailed = false
    do {
        for try await output in run.events {
            if case .textDelta(let chunk) = output { text += chunk }
        }
    } catch { streamFailed = true }
    let outcome = await run.outcome()
    await trace.terminal(run.id)
    return CollectedMLXRun(text: text, outcome: outcome, streamFailed: streamFailed)
}

func requireCompleted(_ collected: CollectedMLXRun,
                      sourceLocation: SourceLocation = #_sourceLocation) throws -> InferenceResult {
    #expect(!collected.streamFailed, sourceLocation: sourceLocation)
    #expect(!collected.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            sourceLocation: sourceLocation)
    guard case .completed(let result) = collected.outcome else {
        Issue.record("Expected completed generation, got \(collected.outcome)", sourceLocation: sourceLocation)
        throw CocoaError(.coderInvalidValue)
    }
    return result
}

func expectReleasedLifecycle(_ events: [MLXLifecycleEvent], completed: Bool = true,
                             sourceLocation: SourceLocation = #_sourceLocation) {
    let phases = events.map(\.phase)
    #expect(phases.first == .loading, sourceLocation: sourceLocation)
    #expect(phases.suffix(2) == [.drained, .released], sourceLocation: sourceLocation)
    if completed { #expect(phases == [.loading, .loaded, .generating, .drained, .released],
                           sourceLocation: sourceLocation) }
    #expect(zip(events, events.dropFirst()).allSatisfy { $0.uptimeSeconds <= $1.uptimeSeconds },
            sourceLocation: sourceLocation)
}

func expectNoLateOutputs(_ entries: [MLXTraceEntry], sourceLocation: SourceLocation = #_sourceLocation) {
    var terminals: Set<UUID> = []
    var drained: Set<UUID> = []
    for entry in entries {
        switch entry {
        case .terminal(let id): terminals.insert(id)
        case .output(let id):
            #expect(!drained.contains(id), "Backend attempted emit after declaring inference drained",
                    sourceLocation: sourceLocation)
            #expect(!terminals.contains(id), "Backend attempted emit after terminal outcome",
                    sourceLocation: sourceLocation)
        case .lifecycle(let event):
            if event.phase == .drained { drained.insert(event.runID) }
        }
    }
}

func expectAdmissionRejected(_ backend: MLXTextBackend, _ request: InferenceRequest,
                             sourceLocation: SourceLocation = #_sourceLocation) async {
    do {
        _ = try await backend.estimate(request)
        Issue.record("Invalid model/request unexpectedly passed admission", sourceLocation: sourceLocation)
    } catch InferenceFailure.invalidRequest {
        // Admission rejects malformed metadata before the upstream model initializer can trap.
    } catch {
        Issue.record("Expected invalidRequest, received \(error)", sourceLocation: sourceLocation)
    }
}
