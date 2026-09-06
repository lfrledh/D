import DInference
import DMLXBackend
import Foundation

struct CLIReport: Encodable {
    let schemaVersion = 1
    let tool = "d-infer"
    let startedAt = Date()
    let system = SystemDescription()
    var backend: BackendDescriptor?
    var options: CLIOptions?
    var runs: [CLIRunReport] = []
    var failure: String?
    var terminationSignal: Int32?
    var exitCode: Int32 = 0
    var elapsedSeconds: Double = 0

    func write(to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let destination = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try encoder.encode(self).write(to: destination, options: .atomic)
    }
}

struct SystemDescription: Encodable {
    let operatingSystem = ProcessInfo.processInfo.operatingSystemVersionString
    let physicalMemoryBytes = ProcessInfo.processInfo.physicalMemory
    let processorCount = ProcessInfo.processInfo.processorCount
    let activeProcessorCount = ProcessInfo.processInfo.activeProcessorCount
    let architecture: String

    init() {
        #if arch(arm64)
        architecture = "arm64"
        #elseif arch(x86_64)
        architecture = "x86_64"
        #else
        architecture = "unknown"
        #endif
    }
}

struct CLIRunReport: Codable {
    let iteration: Int
    let runID: UUID
    let startedAt: Date
    var text = ""
    var chunkCount = 0
    var outcome = "failed"
    var failure: InferenceFailure?
    var errorMessage: String?
    var outputError: String?
    var streamError: String?
    var result: InferenceResult?
    var elapsedSeconds: Double = 0
    var firstChunkSeconds: Double?
    var cancellationRequestedSeconds: Double?
    var cancellationLatencySeconds: Double?
    var lifecycle: [MLXLifecycleEvent] = []
}

actor LifecycleRecorder {
    private var events: [UUID: [MLXLifecycleEvent]] = [:]

    func append(_ event: MLXLifecycleEvent) {
        events[event.runID, default: []].append(event)
        CLIOutput.diagnostic("[\(event.runID)] \(event.phase.rawValue) "
            + "active=\(event.memory.activeBytes) cache=\(event.memory.cacheBytes) "
            + "peak=\(event.memory.peakBytes) bytes")
    }

    func take(for runID: UUID) -> [MLXLifecycleEvent] {
        events.removeValue(forKey: runID) ?? []
    }
}

enum CLIOutput {
    static func text(_ value: String) throws {
        try FileHandle.standardOutput.write(contentsOf: Data(value.utf8))
    }

    static func diagnostic(_ value: String) {
        // Diagnostics must not interrupt cleanup or prevent the JSON report being written.
        try? FileHandle.standardError.write(contentsOf: Data((value + "\n").utf8))
    }
}
