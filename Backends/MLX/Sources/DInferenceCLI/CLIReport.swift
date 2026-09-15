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
    var inspection: CLIInspection?
    var runs: [CLIRunReport] = []
    var failure: String?
    var artifactCleanupError: String?
    var terminationSignal: Int32?
    var exitCode: Int32 = 0
    var elapsedSeconds: Double = 0

    var hasInputIntegrityFailure: Bool {
        runs.contains { report in
            guard let failure = report.failure else { return false }
            if case .inputIntegrityChanged = failure { return true }
            return false
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, tool, startedAt, system, backend, options, inspection, runs, failure
        case artifactCleanupError, terminationSignal, exitCode, elapsedSeconds
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion); try c.encode(tool, forKey: .tool)
        try c.encode(startedAt, forKey: .startedAt); try c.encode(system, forKey: .system)
        try c.encodeIfPresent(backend, forKey: .backend)
        if let options, options.capability == .singing {
            try c.encode(SingingCLIOptionsReport(options), forKey: .options)
        } else { try c.encodeIfPresent(options, forKey: .options) }
        try c.encodeIfPresent(inspection, forKey: .inspection); try c.encode(runs, forKey: .runs)
        try c.encodeIfPresent(failure, forKey: .failure); try c.encodeIfPresent(artifactCleanupError, forKey: .artifactCleanupError)
        try c.encodeIfPresent(terminationSignal, forKey: .terminationSignal)
        try c.encode(exitCode, forKey: .exitCode); try c.encode(elapsedSeconds, forKey: .elapsedSeconds)
    }

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

private struct SingingCLIOptionsReport: Encodable {
    let capability: CLICapability
    let model: String
    let revision: String?
    let memoryBudgetMiB: UInt64
    let timeoutSeconds: Double
    let report: String?
    let inspect: Bool
    let repeatCount: Int
    let artifacts: String?
    let singingRequest: String?
    let singingPython: String?
    let singingScript: String?
    let singingVendor: String?
    let singingProfile: String?
    let singingVocoder: String?

    init(_ options: CLIOptions) {
        capability = options.capability; model = options.model; revision = options.revision
        memoryBudgetMiB = options.memoryBudgetMiB; timeoutSeconds = options.timeoutSeconds
        report = options.report; inspect = options.inspect; repeatCount = options.repeatCount
        artifacts = options.artifacts; singingRequest = options.singingRequest; singingPython = options.singingPython
        singingScript = options.singingScript; singingVendor = options.singingVendor
        singingProfile = options.singingProfile; singingVocoder = options.singingVocoder
    }
}

struct CLIInspection: Codable {
    let estimate: ResourceEstimate
    let withinBudget: Bool
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
    var request: InferenceRequest?
    var text = ""
    var chunkCount = 0
    var outcome = "failed"
    var failure: InferenceFailure?
    var errorMessage: String?
    var outputError: String?
    var streamError: String?
    var artifactCleanupError: String?
    var result: InferenceResult?
    var artifacts: [ArtifactReference] = []
    var progress: [CLIProgress] = []
    var elapsedSeconds: Double = 0
    var firstChunkSeconds: Double?
    var firstProgressSeconds: Double?
    var firstArtifactSeconds: Double?
    var cancellationRequestedSeconds: Double?
    var cancellationLatencySeconds: Double?
    var lifecycle: [MLXLifecycleEvent] = []
}

struct CLIProgress: Codable {
    let completed: Int
    let total: Int
    let elapsedSeconds: Double
}

private struct CLIArtifactLine: Encodable {
    let type = "artifact"
    let runID: UUID
    let artifact: ArtifactReference
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

    static func artifact(_ artifact: ArtifactReference, runID: UUID) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(CLIArtifactLine(runID: runID, artifact: artifact))
        data.append(0x0A)
        try FileHandle.standardOutput.write(contentsOf: data)
    }

    static func diagnostic(_ value: String) {
        // Diagnostics must not interrupt cleanup or prevent the JSON report being written.
        try? FileHandle.standardError.write(contentsOf: Data((value + "\n").utf8))
    }
}
