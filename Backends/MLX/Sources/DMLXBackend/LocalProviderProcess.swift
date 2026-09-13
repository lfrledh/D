import Darwin
import DInference
import Foundation

// Shared owned-child transport, extracted without changing the validated audio
// cancellation/pipe-drain algorithm. Protocol parsing stays in each backend.
struct LocalProviderProcess: Sendable {
    let executable: URL
    let arguments: [String]
    let environment: [String: String]
    let currentDirectory: URL
    let timeoutSeconds: Double
    let cancellationGraceSeconds: Double
    let label: String

    func run<Output: Sendable>(
        consume: @escaping @Sendable (LocalDedicatedPipeReader, LocalOwnedProcessControl) async -> Output
    ) async throws -> Output {
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

        let exit = LocalProcessExit()
        let control = LocalOwnedProcessControl(graceSeconds: cancellationGraceSeconds)
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
            throw InferenceFailure.backendFailed("Cannot launch the owned \(label): \(error.localizedDescription)")
        }
        stdout.fileHandleForWriting.closeFile()
        stderr.fileHandleForWriting.closeFile()
        control.scheduleTimeout(after: timeoutSeconds)

        // Each blocking POSIX reader owns a dedicated serial queue. The detached consumers
        // only await bounded, acknowledged chunks, so neither pipe can block the other or a
        // Swift cooperative executor while the owned child is still alive.
        let stdoutReader = LocalDedicatedPipeReader(
            handle: stdout.fileHandleForReading, label: "\(label).stdout")
        let stderrReader = LocalDedicatedPipeReader(
            handle: stderr.fileHandleForReading, label: "\(label).stderr")
        stdoutReader.start()
        stderrReader.start()
        let stdoutTask = Task.detached(priority: .userInitiated) {
            await consume(stdoutReader, control)
        }
        let stderrTask = Task.detached(priority: .utility) {
            await Self.readStderr(stderrReader)
        }

        let status = await withTaskCancellationHandler {
            await exit.wait()
        } onCancel: {
            control.requestStop(.cancelled)
        }
        control.markExited()
        let stdoutResult = await stdoutTask.value
        let stderrResult = await stderrTask.value
        stdout.fileHandleForReading.closeFile()
        stderr.fileHandleForReading.closeFile()

        if let reason = control.stopReason {
            switch reason {
            case .cancelled:
                throw CancellationError()
            case .timeout:
                throw InferenceFailure.backendFailed(
                    "\(label) timed out after \(timeoutSeconds) seconds; the owned child exited and pipes drained.")
            case .protocolFailure(let message):
                throw InferenceFailure.backendFailed(message + Self.stderrSuffix(stderrResult.retained))
            }
        }
        if let failure = stderrResult.failure {
            throw InferenceFailure.backendFailed(
                "Cannot drain \(label) stderr: \(failure)." + Self.stderrSuffix(stderrResult.retained))
        }
        guard status == 0 else {
            throw InferenceFailure.backendFailed(
                "\(label) exited with status \(status)." + Self.stderrSuffix(stderrResult.retained))
        }
        return stdoutResult
    }

    private struct StderrResult: Sendable {
        var retained = Data()
        var failure: String?
    }

    private static func readStderr(_ reader: LocalDedicatedPipeReader) async -> StderrResult {
        var retained = Data()
        while true {
            switch await reader.next() {
            case .data(let data):
                let available = 1_048_576 - retained.count
                if available > 0 { retained.append(data.prefix(available)) }
                reader.acknowledge()
            case .end:
                return StderrResult(retained: retained)
            case .failure(let code, let message):
                return StderrResult(
                    retained: retained,
                    failure: "POSIX read failed with errno \(code): \(message)")
            }
        }
    }

    private static func stderrSuffix(_ data: Data) -> String {
        guard !data.isEmpty else { return "" }
        let text = String(decoding: data, as: UTF8.self)
        return " Stderr: " + text
    }
}

enum LocalPipeRead: Sendable {
    case data(Data)
    case end
    case failure(code: Int32, message: String)
}

// The lock protects the single-slot rendezvous; the queue is the sole POSIX reader.
// @unchecked is limited to this ownership bridge because DispatchQueue requires a
// Sendable capture while FileHandle itself does not model that ownership in Swift.
final class LocalDedicatedPipeReader: @unchecked Sendable {
    private let fileDescriptor: Int32
    private let queue: DispatchQueue
    private let lock = NSLock()
    private let consumed = DispatchSemaphore(value: 0)
    private var pending: LocalPipeRead?
    private var waiter: CheckedContinuation<LocalPipeRead, Never>?
    private var started = false

    init(handle: FileHandle, label: String) {
        fileDescriptor = handle.fileDescriptor
        queue = DispatchQueue(label: "com.d.audio.\(label).\(UUID().uuidString)", qos: .userInitiated)
    }

    func start() {
        let shouldStart = lock.withLock { () -> Bool in
            guard !started else { return false }
            started = true
            return true
        }
        guard shouldStart else { return }
        queue.async { [self] in drain() }
    }

    func next() async -> LocalPipeRead {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let pending {
                self.pending = nil
                lock.unlock()
                continuation.resume(returning: pending)
            } else {
                precondition(waiter == nil, "Audio pipe reader has more than one consumer")
                waiter = continuation
                lock.unlock()
            }
        }
    }

    func acknowledge() {
        consumed.signal()
    }

    private func drain() {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(fileDescriptor, bytes.baseAddress, bytes.count)
            }
            if count > 0 {
                offer(.data(Data(buffer.prefix(count))))
                consumed.wait()
            } else if count == 0 {
                offer(.end)
                return
            } else {
                let code = errno
                if code == EINTR { continue }
                offer(.failure(code: code, message: String(cString: strerror(code))))
                return
            }
        }
    }

    private func offer(_ value: LocalPipeRead) {
        lock.lock()
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(returning: value)
        } else {
            precondition(pending == nil, "Audio pipe reader exceeded its single-slot buffer")
            pending = value
            lock.unlock()
        }
    }
}

private final class LocalProcessExit: @unchecked Sendable {
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

final class LocalOwnedProcessControl: @unchecked Sendable {
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

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}
