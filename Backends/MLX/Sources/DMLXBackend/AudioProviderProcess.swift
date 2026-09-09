import CryptoKit
import Darwin
import DInference
import Foundation

struct AudioProviderArtifact: Sendable, Equatable {
    let path: String
    let sha256: String
    let byteCount: UInt64
    let frameCount: Int64
    let sampleRate: Int
    let channels: Int
    let encoding: String
}

struct AudioProviderResult: Sendable, Equatable {
    let artifact: AudioProviderArtifact
    let snapshot: AudioJSONValue
}

struct AudioProviderProcess: Sendable {
    let executable: URL
    let arguments: [String]
    let environment: [String: String]
    let currentDirectory: URL
    let timeoutSeconds: Double
    let cancellationGraceSeconds: Double

    func run(runID: UUID,
             emit: @escaping @Sendable (InferenceOutput) async throws -> Void) async throws -> AudioProviderResult {
        try Task.checkCancellation()
        let process = Process()
        let stdout = Pipe(), stderr = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = currentDirectory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr

        let exit = AudioProcessExit()
        let control = AudioOwnedProcessControl(graceSeconds: cancellationGraceSeconds)
        process.terminationHandler = { process in
            exit.finish(process.terminationStatus)
            control.markExited()
        }
        do {
            try process.run()
            control.attach(process)
        } catch {
            stdout.fileHandleForWriting.closeFile()
            stderr.fileHandleForWriting.closeFile()
            stdout.fileHandleForReading.closeFile()
            stderr.fileHandleForReading.closeFile()
            throw InferenceFailure.backendFailed("Cannot launch the owned audio provider: \(error.localizedDescription)")
        }
        stdout.fileHandleForWriting.closeFile()
        stderr.fileHandleForWriting.closeFile()
        control.scheduleTimeout(after: timeoutSeconds)

        // Detached readers do not inherit cancellation and therefore continue draining both
        // pipes until the owned child really exits. They are retained and awaited below.
        let stdoutTask = Task.detached(priority: .userInitiated) {
            await AudioProviderProtocol.readStdout(stdout.fileHandleForReading, runID: runID,
                                                   control: control, emit: emit)
        }
        let stderrTask = Task.detached(priority: .utility) {
            await Self.readStderr(stderr.fileHandleForReading)
        }

        let status = await withTaskCancellationHandler {
            await exit.wait()
        } onCancel: {
            control.requestStop(.cancelled)
        }
        control.markExited()
        let stdoutResult = await stdoutTask.value
        let retainedStderr = await stderrTask.value
        stdout.fileHandleForReading.closeFile()
        stderr.fileHandleForReading.closeFile()

        if let reason = control.stopReason {
            switch reason {
            case .cancelled:
                throw CancellationError()
            case .timeout:
                throw InferenceFailure.backendFailed(
                    "Audio provider timed out after \(timeoutSeconds) seconds; the owned child exited and pipes drained.")
            case .protocolFailure(let message):
                throw InferenceFailure.backendFailed(message + Self.stderrSuffix(retainedStderr))
            }
        }
        if let failure = stdoutResult.failure {
            throw InferenceFailure.backendFailed(failure + Self.stderrSuffix(retainedStderr))
        }
        guard status == 0 else {
            throw InferenceFailure.backendFailed(
                "Audio provider exited with status \(status)." + Self.stderrSuffix(retainedStderr))
        }
        guard let terminal = stdoutResult.terminal else {
            throw InferenceFailure.backendFailed("Audio provider exited without one result terminal event.")
        }
        switch terminal {
        case .result(let result): return result
        case .error(let kind, let message):
            throw InferenceFailure.backendFailed("Audio provider reported \(kind): \(message)")
        }
    }

    private static func readStderr(_ handle: FileHandle) async -> Data {
        var retained = Data()
        do {
            for try await byte in handle.bytes {
                if retained.count < 1_048_576 { retained.append(byte) }
            }
        } catch {
            if retained.count < 1_048_576 {
                retained.append(contentsOf: Data("\n[stderr drain failed: \(error.localizedDescription)]".utf8)
                    .prefix(1_048_576 - retained.count))
            }
        }
        return retained
    }

    private static func stderrSuffix(_ data: Data) -> String {
        guard !data.isEmpty else { return "" }
        let text = String(decoding: data, as: UTF8.self)
        return " Stderr: " + text
    }
}

private final class AudioProcessExit: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?
    private var waiters: [CheckedContinuation<Int32, Never>] = []

    func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let status {
                lock.unlock()
                continuation.resume(returning: status)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func finish(_ status: Int32) {
        lock.lock()
        guard self.status == nil else { lock.unlock(); return }
        self.status = status
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        for waiter in pending { waiter.resume(returning: status) }
    }
}

private final class AudioOwnedProcessControl: @unchecked Sendable {
    enum StopReason: Sendable, Equatable {
        case cancelled
        case timeout
        case protocolFailure(String)
    }

    private let lock = NSLock()
    private let graceSeconds: Double
    private var process: Process?
    private var exited = false
    private var reason: StopReason?
    private var timeoutItem: DispatchWorkItem?
    private var killItem: DispatchWorkItem?

    init(graceSeconds: Double) { self.graceSeconds = graceSeconds }

    var stopReason: StopReason? {
        lock.withLock { reason }
    }

    func attach(_ process: Process) {
        let shouldTerminate = lock.withLock { () -> Bool in
            self.process = process
            return reason != nil && !exited
        }
        if shouldTerminate { process.terminate() }
    }

    func scheduleTimeout(after seconds: Double) {
        let item = DispatchWorkItem { [weak self] in self?.requestStop(.timeout) }
        lock.withLock {
            guard !exited, reason == nil else { return }
            timeoutItem = item
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds, execute: item)
        }
    }

    func requestStop(_ requested: StopReason) {
        var target: Process?
        var escalation: DispatchWorkItem?
        lock.lock()
        if reason == nil { reason = requested }
        timeoutItem?.cancel()
        timeoutItem = nil
        if !exited, killItem == nil {
            target = process
            let item = DispatchWorkItem { [weak self] in self?.forceKillIfRunning() }
            killItem = item
            escalation = item
        }
        lock.unlock()
        target?.terminate()
        if let escalation {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + graceSeconds,
                                                           execute: escalation)
        }
    }

    func markExited() {
        lock.withLock {
            exited = true
            timeoutItem?.cancel()
            killItem?.cancel()
            timeoutItem = nil
            killItem = nil
            process = nil
        }
    }

    private func forceKillIfRunning() {
        let pid: Int32? = lock.withLock {
            guard !exited, let process, process.isRunning else { return nil }
            return process.processIdentifier
        }
        if let pid { _ = Darwin.kill(pid, SIGKILL) }
    }
}

private enum AudioProviderTerminal: Sendable, Equatable {
    case result(AudioProviderResult)
    case error(kind: String, message: String)
}

private struct AudioStdoutResult: Sendable {
    var terminal: AudioProviderTerminal?
    var failure: String?
}

enum AudioProviderProtocol {
    private static let phases: Set<String> = [
        "validating", "encodingText", "encodingSource", "denoising",
        "decoding", "publishing", "cleanup",
    ]

    static func readStdout(
        _ handle: FileHandle,
        runID: UUID,
        control: AudioOwnedProcessControl,
        emit: @escaping @Sendable (InferenceOutput) async throws -> Void
    ) async -> AudioStdoutResult {
        var result = AudioStdoutResult()
        var line = Data()
        var totalBytes = 0
        do {
            for try await byte in handle.bytes {
                totalBytes += 1
                if totalBytes > 16 * 1024 * 1024 {
                    fail(&result, "Audio provider stdout exceeded 16 MiB.", control: control)
                    continue
                }
                if result.failure != nil { continue }
                if byte == 0x0A {
                    await processLine(line, runID: runID, result: &result, control: control, emit: emit)
                    line.removeAll(keepingCapacity: true)
                } else {
                    line.append(byte)
                    if line.count > 2 * 1024 * 1024 {
                        fail(&result, "Audio provider emitted a JSON line larger than 2 MiB.", control: control)
                    }
                }
            }
            if result.failure == nil, !line.isEmpty {
                await processLine(line, runID: runID, result: &result, control: control, emit: emit)
            }
        } catch {
            fail(&result, "Cannot drain audio provider stdout: \(error.localizedDescription)", control: control)
        }
        return result
    }

    static func parseResultSnapshot(_ data: Data, runID: UUID) throws -> AudioProviderResult {
        var parser = AudioJSONParser(data: data, maximumDepth: 32)
        let value = try parser.parse()
        let terminal = try parseEvent(value, runID: runID)
        guard case .result(let result) = terminal else {
            throw InferenceFailure.backendFailed("result.json does not contain the result terminal object.")
        }
        return result
    }

    private static func processLine(
        _ line: Data,
        runID: UUID,
        result: inout AudioStdoutResult,
        control: AudioOwnedProcessControl,
        emit: @escaping @Sendable (InferenceOutput) async throws -> Void
    ) async {
        guard !line.isEmpty else {
            fail(&result, "Audio provider emitted an empty stdout line.", control: control)
            return
        }
        do {
            var parser = AudioJSONParser(data: line, maximumDepth: 32)
            let value = try parser.parse()
            let object = try value.objectAny(context: "provider event")
            let type = try object["type"]?.requiredString(context: "provider event type")
            if type == "progress" {
                guard result.terminal == nil else {
                    throw InferenceFailure.backendFailed("Audio provider emitted progress after its terminal event.")
                }
                let progress = try parseProgress(value, runID: runID)
                try await emit(.progress(completed: progress.completed, total: progress.total))
            } else {
                guard result.terminal == nil else {
                    throw InferenceFailure.backendFailed("Audio provider emitted more than one terminal event.")
                }
                result.terminal = try parseEvent(value, runID: runID)
            }
        } catch {
            fail(&result, "Invalid audio provider stdout: \(error.localizedDescription)", control: control)
        }
    }

    private static func parseProgress(_ value: AudioJSONValue, runID: UUID) throws -> (completed: Int, total: Int) {
        let object = try value.object(
            exactKeys: ["schemaVersion", "type", "runID", "phase", "completed", "total"],
            context: "progress event")
        try validateHeader(object, type: "progress", runID: runID)
        let phase = try object["phase"]!.requiredString(context: "progress phase")
        let completed = try object["completed"]!.requiredInteger(context: "progress completed")
        let total = try object["total"]!.requiredInteger(context: "progress total")
        guard phases.contains(phase), completed >= 0, total > 0, completed <= total,
              completed <= Int64(Int.max), total <= Int64(Int.max) else {
            throw InferenceFailure.backendFailed("Invalid audio progress values.")
        }
        return (Int(completed), Int(total))
    }

    private static func parseEvent(_ value: AudioJSONValue, runID: UUID) throws -> AudioProviderTerminal {
        let any = try value.objectAny(context: "terminal event")
        let type = try any["type"]?.requiredString(context: "terminal type")
        switch type {
        case "result":
            let object = try value.object(
                exactKeys: ["schemaVersion", "type", "runID", "artifact", "metadata"],
                context: "result event")
            try validateHeader(object, type: "result", runID: runID)
            _ = try object["metadata"]!.objectAny(context: "result metadata")
            let artifactObject = try object["artifact"]!.object(
                exactKeys: ["path", "sha256", "byteCount", "frameCount", "sampleRate", "channels", "encoding"],
                context: "result artifact")
            let byteCount = try artifactObject["byteCount"]!.requiredInteger(context: "artifact byteCount")
            let frameCount = try artifactObject["frameCount"]!.requiredInteger(context: "artifact frameCount")
            let sampleRate = try artifactObject["sampleRate"]!.requiredInteger(context: "artifact sampleRate")
            let channels = try artifactObject["channels"]!.requiredInteger(context: "artifact channels")
            guard byteCount > 0, sampleRate > 0, sampleRate <= Int64(Int.max),
                  channels > 0, channels <= Int64(Int.max) else {
                throw InferenceFailure.backendFailed("Invalid numerical result artifact metadata.")
            }
            let artifact = AudioProviderArtifact(
                path: try artifactObject["path"]!.requiredString(context: "artifact path"),
                sha256: try artifactObject["sha256"]!.requiredString(context: "artifact SHA-256"),
                byteCount: UInt64(byteCount), frameCount: frameCount,
                sampleRate: Int(sampleRate), channels: Int(channels),
                encoding: try artifactObject["encoding"]!.requiredString(context: "artifact encoding"))
            return .result(AudioProviderResult(artifact: artifact, snapshot: value))
        case "error":
            let object = try value.object(
                exactKeys: ["schemaVersion", "type", "runID", "kind", "message"], context: "error event")
            try validateHeader(object, type: "error", runID: runID)
            let kind = try object["kind"]!.requiredString(context: "error kind")
            let message = try object["message"]!.requiredString(context: "error message")
            guard ["invalidRequest", "configuration", "output", "engine", "cancelled"].contains(kind),
                  !message.isEmpty else {
                throw InferenceFailure.backendFailed("Invalid provider error terminal event.")
            }
            return .error(kind: kind, message: message)
        default:
            throw InferenceFailure.backendFailed("Unknown audio provider terminal event type.")
        }
    }

    private static func validateHeader(_ object: [String: AudioJSONValue], type: String,
                                       runID: UUID) throws {
        let schema = try object["schemaVersion"]!.requiredInteger(context: "event schemaVersion")
        let actualType = try object["type"]!.requiredString(context: "event type")
        let actualRunID = try object["runID"]!.requiredString(context: "event runID")
        guard schema == 1, actualType == type,
              UUID(uuidString: actualRunID)?.uuidString.lowercased() == runID.uuidString.lowercased(),
              actualRunID == actualRunID.lowercased() else {
            throw InferenceFailure.backendFailed("Wrong schema, type, or canonical runID in provider event.")
        }
    }

    private static func fail(_ result: inout AudioStdoutResult, _ message: String,
                             control: AudioOwnedProcessControl) {
        if result.failure == nil {
            result.failure = message
            control.requestStop(.protocolFailure(message))
        }
    }
}

extension AudioJSONValue {
    func objectAny(context: String) throws -> [String: AudioJSONValue] {
        guard case .object(let object) = self else {
            throw InferenceFailure.backendFailed("\(context) must be an object.")
        }
        return object
    }
}

enum AudioWAV {
    struct SourceInfo: Sendable {
        let sampleEncoding: String
        let sha256: String
    }

    static func validateSource(_ url: URL, reference: AudioSourceReference) throws -> SourceInfo {
        let (data, _) = try AudioFileSystem.readRegularFile(
            url, label: "Audio source", maximumBytes: 512 * 1024 * 1024)
        let parsed = try parse(data, outputOnly: false)
        guard parsed.sampleRate == reference.sampleRate, parsed.channels == reference.channels,
              parsed.frameCount == reference.frameCount else {
            throw InferenceFailure.invalidRequest("Audio source WAV metadata does not match its frozen reference.")
        }
        let digest = sha256(data)
        guard digest == reference.sha256 else {
            throw InferenceFailure.invalidRequest("Audio source SHA-256 does not match its frozen reference.")
        }
        return SourceInfo(sampleEncoding: parsed.encoding, sha256: digest)
    }

    static func validateOutput(_ url: URL, claim: AudioProviderArtifact,
                               expectedFrames: Int64) throws -> ArtifactReference {
        let expectedPCM = UInt64(expectedFrames).multipliedReportingOverflow(by: 8)
        guard expectedFrames > 0, !expectedPCM.overflow,
              expectedPCM.partialValue <= UInt64.max - 1_048_576 else {
            throw InferenceFailure.backendFailed("Expected audio output size is not representable.")
        }
        let maximum = expectedPCM.partialValue + 1_048_576
        let (data, _) = try AudioFileSystem.readRegularFile(url, label: "Generated audio WAV",
                                                            maximumBytes: maximum)
        let parsed = try parse(data, outputOnly: true)
        let digest = sha256(data)
        guard claim.path == url.path, claim.sha256 == digest,
              claim.byteCount == UInt64(data.count), claim.frameCount == expectedFrames,
              claim.sampleRate == 44_100, claim.channels == 2, claim.encoding == "float32",
              parsed.frameCount == expectedFrames, parsed.sampleRate == 44_100,
              parsed.channels == 2, parsed.encoding == "float32" else {
            throw InferenceFailure.backendFailed("Generated WAV or provider artifact metadata failed independent validation.")
        }
        return ArtifactReference(url: url, mediaType: "audio/wav")
    }

    private struct Parsed {
        let sampleRate: Int
        let channels: Int
        let frameCount: Int64
        let encoding: String
    }

    private static func parse(_ data: Data, outputOnly: Bool) throws -> Parsed {
        guard data.count >= 12, data.prefix(4) == Data("RIFF".utf8),
              data[8..<12] == Data("WAVE".utf8),
              UInt64(u32(data, 4)) + 8 == UInt64(data.count) else {
            throw InferenceFailure.backendFailed("Invalid or truncated RIFF/WAVE container.")
        }
        var offset = 12
        var format: (code: UInt16, channels: UInt16, rate: UInt32, align: UInt16, bits: UInt16)?
        var pcmRange: Range<Int>?
        while offset < data.count {
            guard offset + 8 <= data.count else { throw InferenceFailure.backendFailed("Truncated WAV chunk header.") }
            let id = data[offset..<(offset + 4)]
            let length = Int(u32(data, offset + 4))
            let body = offset + 8
            guard length >= 0, body <= data.count, length <= data.count - body else {
                throw InferenceFailure.backendFailed("WAV chunk length exceeds the container.")
            }
            if id == Data("fmt ".utf8) {
                guard format == nil, length >= 16 else {
                    throw InferenceFailure.backendFailed("Missing or duplicate WAV format chunk.")
                }
                format = (u16(data, body), u16(data, body + 2), u32(data, body + 4),
                          u16(data, body + 12), u16(data, body + 14))
            } else if id == Data("data".utf8) {
                guard pcmRange == nil else { throw InferenceFailure.backendFailed("Duplicate WAV data chunk.") }
                pcmRange = body..<(body + length)
            }
            let padded = length + (length & 1)
            guard padded <= data.count - body else { throw InferenceFailure.backendFailed("Truncated WAV chunk padding.") }
            offset = body + padded
        }
        guard offset == data.count, let format, let pcmRange,
              format.channels == 2, format.rate == 44_100 else {
            throw InferenceFailure.backendFailed("WAV must contain one stereo 44100 Hz PCM stream.")
        }
        let bytesPerSample = Int(format.bits / 8)
        guard format.bits.isMultiple(of: 8), bytesPerSample > 0,
              Int(format.align) == Int(format.channels) * bytesPerSample,
              pcmRange.count.isMultiple(of: Int(format.align)) else {
            throw InferenceFailure.backendFailed("WAV block alignment or sample width is invalid.")
        }
        let encoding: String
        if format.code == 3, format.bits == 32 {
            encoding = "float32"
            var sample = pcmRange.lowerBound
            while sample < pcmRange.upperBound {
                guard Float(bitPattern: u32(data, sample)).isFinite else {
                    throw InferenceFailure.backendFailed("WAV contains a nonfinite float32 sample.")
                }
                sample += 4
            }
        } else if !outputOnly, format.code == 1, [16, 24, 32].contains(Int(format.bits)) {
            encoding = "int\(format.bits)"
        } else {
            throw InferenceFailure.backendFailed("Unsupported WAV sample encoding.")
        }
        return Parsed(sampleRate: Int(format.rate), channels: Int(format.channels),
                      frameCount: Int64(pcmRange.count / Int(format.align)), encoding: encoding)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset]) | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}
