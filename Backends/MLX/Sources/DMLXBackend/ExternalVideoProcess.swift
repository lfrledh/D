import Darwin
import Dispatch
import Foundation

/// An owned, trusted bundled tool and the processes it starts in its inherited process group.
/// The caller must keep its execution lease when `fullyDrained` is false.
struct ExternalVideoProcess: Sendable {
    let executable: URL
    let arguments: [String]
    let environment: [String: String]
    let currentDirectory: URL
    let timeoutSeconds: Double
    let cancellationGraceSeconds: Double

    init(executable: URL, arguments: [String], environment: [String: String],
         currentDirectory: URL, timeoutSeconds: Double, cancellationGraceSeconds: Double) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.currentDirectory = currentDirectory
        self.timeoutSeconds = timeoutSeconds
        self.cancellationGraceSeconds = cancellationGraceSeconds
    }

    func run() async throws -> ExternalVideoProcessResult {
        if Task.isCancelled { return Self.preCancelled }
        let cancellation = ExternalVideoCancellation()
        // This queue owns spawn, both pipe reads, waitpid, signals and the final group probe.
        // No blocking operation runs on a Swift cooperative executor; no detached timer can
        // signal a PID after this invocation has finished.
        let queue = DispatchQueue(label: "com.d.video.external-process.\(UUID().uuidString)", qos: .userInitiated)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do { continuation.resume(returning: try self.execute(cancellation: cancellation)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static var preCancelled: ExternalVideoProcessResult {
        .init(reason: .cancelled, exitCode: nil, processID: nil, fullyDrained: true,
              stdoutTail: "", stderrTail: "")
    }

    private func execute(cancellation: ExternalVideoCancellation) throws -> ExternalVideoProcessResult {
        if cancellation.isCancelled { return Self.preCancelled }
        try validate()
        if cancellation.isCancelled { return Self.preCancelled }

        var stdout = try Self.makePipe()
        defer { stdout.close() }
        if cancellation.isCancelled { return Self.preCancelled }
        var stderr = try Self.makePipe()
        defer { stderr.close() }
        if cancellation.isCancelled { return Self.preCancelled }

        var actions: posix_spawn_file_actions_t?
        try Self.check(posix_spawn_file_actions_init(&actions), "initialize spawn file actions")
        defer { _ = posix_spawn_file_actions_destroy(&actions) }
        var attributes: posix_spawnattr_t?
        try Self.check(posix_spawnattr_init(&attributes), "initialize spawn attributes")
        defer { _ = posix_spawnattr_destroy(&attributes) }

        try currentDirectory.path.withCString { path in
            try Self.check(posix_spawn_file_actions_addchdir_np(&actions, path), "set child directory")
        }
        try "/dev/null".withCString { path in
            try Self.check(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, path, O_RDONLY, 0),
                           "open child null stdin")
        }
        try Self.check(posix_spawn_file_actions_adddup2(&actions, stdout.writeFD, STDOUT_FILENO),
                       "connect child stdout")
        try Self.check(posix_spawn_file_actions_adddup2(&actions, stderr.writeFD, STDERR_FILENO),
                       "connect child stderr")
        for descriptor in [stdout.readFD, stdout.writeFD, stderr.readFD, stderr.writeFD] {
            try Self.check(posix_spawn_file_actions_addclose(&actions, descriptor), "close child pipe descriptor")
        }
        try Self.check(posix_spawnattr_setflags(&attributes,
                        Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)),
                       "set child process group flags")
        try Self.check(posix_spawnattr_setpgroup(&attributes, 0), "create child process group")

        // strdup is safe here because validate() rejects embedded NUL. These arrays live
        // only through the synchronous posix_spawn call on this queue.
        var argv = try Self.cStrings([executable.path] + arguments)
        defer { Self.freeCStrings(argv) }
        var env = try Self.cStrings(environment.keys.sorted().map { "\($0)=\(environment[$0]!)" })
        defer { Self.freeCStrings(env) }
        if cancellation.isCancelled { return Self.preCancelled }

        var pid: pid_t = 0
        let spawnCode = executable.path.withCString { path in
            argv.withUnsafeMutableBufferPointer { args in
                env.withUnsafeMutableBufferPointer { variables in
                    posix_spawn(&pid, path, &actions, &attributes,
                                args.baseAddress, variables.baseAddress)
                }
            }
        }
        try Self.check(spawnCode, "launch \(executable.path)")
        // A successful spawn always has one owned >0 PID; cancellation races from here
        // onward are handled by the loop, including a request made during posix_spawn.
        guard pid > 0 else {
            return .init(reason: .cleanupUnconfirmed, exitCode: nil, processID: nil,
                         fullyDrained: false, stdoutTail: "",
                         stderrTail: "[transport] successful spawn returned no owned PID")
        }
        stdout.closeWriter()
        stderr.closeWriter()
        return Self.monitor(pid: pid, stdout: stdout.readFD, stderr: stderr.readFD,
                            timeout: timeoutSeconds, grace: cancellationGraceSeconds,
                            cancellation: cancellation)
    }

    private func validate() throws {
        guard timeoutSeconds.isFinite && timeoutSeconds > 0,
              cancellationGraceSeconds.isFinite && cancellationGraceSeconds > 0 else {
            throw Self.error(EINVAL, "timeouts must be finite positive seconds")
        }
        guard executable.isFileURL, executable.path.hasPrefix("/"),
              currentDirectory.isFileURL, currentDirectory.path.hasPrefix("/") else {
            throw Self.error(EINVAL, "executable and child directory must be absolute file URLs")
        }
        let strings = [executable.path, currentDirectory.path] + arguments
        guard strings.allSatisfy({ !$0.utf8.contains(0) }),
              environment.allSatisfy({ key, value in
                  !key.isEmpty && !key.contains("=") && !key.utf8.contains(0) && !value.utf8.contains(0)
              }) else {
            throw Self.error(EINVAL, "argv or environment contains an invalid NUL or key")
        }
    }

    private static func makePipe() throws -> ExternalVideoPipe {
        var original: [Int32] = [-1, -1]
        // pipe2 is unavailable at the macOS 14 deployment target. pipe leaves a
        // brief inheritance window before F_DUPFD_CLOEXEC creates the final ends;
        // this invocation's spawn uses CLOEXEC_DEFAULT and closes originals first.
        guard Darwin.pipe(&original) == 0 else { throw error(errno, "create output pipe") }
        // Moving both ends above stdio makes addopen/adddup2/addclose unambiguous
        // even when the host launched with a closed standard descriptor.
        let readFD = fcntl(original[0], F_DUPFD_CLOEXEC, 3)
        let readError = errno
        let writeFD = fcntl(original[1], F_DUPFD_CLOEXEC, 3)
        let writeError = errno
        _ = Darwin.close(original[0]); _ = Darwin.close(original[1])
        guard readFD >= 0, writeFD >= 0 else {
            if readFD >= 0 { _ = Darwin.close(readFD) }
            if writeFD >= 0 { _ = Darwin.close(writeFD) }
            throw error(readFD < 0 ? readError : writeError, "set pipe close-on-exec")
        }
        let flags = fcntl(readFD, F_GETFL)
        guard flags >= 0, fcntl(readFD, F_SETFL, flags | O_NONBLOCK) == 0 else {
            let code = errno
            _ = Darwin.close(readFD); _ = Darwin.close(writeFD)
            throw error(code, "set nonblocking pipe read")
        }
        return ExternalVideoPipe(readFD: readFD, writeFD: writeFD)
    }

    private static func cStrings(_ strings: [String]) throws -> [UnsafeMutablePointer<CChar>?] {
        var result: [UnsafeMutablePointer<CChar>?] = []
        for string in strings {
            guard let pointer = strdup(string) else {
                freeCStrings(result)
                throw error(ENOMEM, "allocate spawn arguments")
            }
            result.append(pointer)
        }
        result.append(nil)
        return result
    }

    private static func freeCStrings(_ strings: [UnsafeMutablePointer<CChar>?]) {
        for pointer in strings { free(pointer) }
    }

    private static func check(_ code: Int32, _ operation: String) throws {
        if code != 0 { throw error(code, operation) }
    }

    private static func error(_ code: Int32, _ operation: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: "External video process: \(operation) (errno \(code): \(String(cString: strerror(code))))"])
    }

    private static func monitor(pid: pid_t, stdout: Int32, stderr: Int32,
                                timeout: Double, grace: Double,
                                cancellation: ExternalVideoCancellation) -> ExternalVideoProcessResult {
        let started = ProcessInfo.processInfo.systemUptime
        var out = ExternalVideoTail(), err = ExternalVideoTail()
        var outEOF = false, errEOF = false
        var readFailure = false
        var parentStatus: Int32?
        var waitUnknown = false
        var originalReason: ExternalVideoProcessResult.StopReason?
        var termAt: Double?
        var killAt: Double?
        var diagnostics: [String] = []

        while true {
            let now = ProcessInfo.processInfo.systemUptime
            drain(stdout, into: &out, eof: &outEOF, failed: &readFailure, diagnostics: &diagnostics)
            drain(stderr, into: &err, eof: &errEOF, failed: &readFailure, diagnostics: &diagnostics)

            if parentStatus == nil && !waitUnknown {
                var status: Int32 = 0
                let waited = Darwin.waitpid(pid, &status, WNOHANG)
                if waited == pid { parentStatus = status }
                else if waited == -1 && errno != EINTR {
                    waitUnknown = true
                    diagnostics.append("waitpid failed with errno \(errno); parent exit status is unknown")
                }
            }
            // Only ESRCH is proof that this process group has gone. EPERM is
            // unknown, including the Darwin zombie/reap race: waitpid above runs
            // before every probe and the loop probes again after any reap.
            let group = groupState(pid)

            if originalReason == nil && cancellation.isCancelled { originalReason = .cancelled }
            if parentStatus != nil && !waitUnknown && !readFailure && outEOF && errEOF && group == .absent {
                let reason = originalReason ?? .exited
                return result(reason: reason, status: parentStatus, pid: pid, drained: true,
                              out: out, err: err, diagnostics: diagnostics)
            }

            if originalReason == nil {
                if now - started >= timeout { originalReason = .timedOut }
                else if readFailure || waitUnknown || (parentStatus != nil && group != .absent) {
                    originalReason = .cleanupUnconfirmed
                    if parentStatus != nil && group != .absent {
                        diagnostics.append("root exited while its owned process group remained")
                    }
                }
            }

            if originalReason != nil && termAt == nil {
                termAt = now
                if group != .absent {
                    if Darwin.kill(-pid, SIGTERM) != 0 && errno != ESRCH {
                        diagnostics.append("process-group SIGTERM failed with errno \(errno)")
                    }
                }
            }
            if let termAt, killAt == nil, now - termAt >= grace {
                killAt = now
                if group != .absent {
                    if Darwin.kill(-pid, SIGKILL) != 0 && errno != ESRCH {
                        diagnostics.append("process-group SIGKILL failed with errno \(errno)")
                    }
                }
            }
            if let killAt, now - killAt >= 5 {
                if case .unknown(let code) = group {
                    diagnostics.append("process-group existence probe remained unknown (errno \(code))")
                }
                diagnostics.append("owned group, parent status, or both pipe EOFs unconfirmed 5 seconds after SIGKILL")
                return result(reason: .cleanupUnconfirmed, status: parentStatus, pid: pid,
                              drained: false, out: out, err: err,
                              diagnostics: ["original stop reason: \((originalReason ?? .cleanupUnconfirmed).rawValue)"] + diagnostics)
            }

            var descriptors = [pollfd(fd: outEOF ? -1 : stdout,
                                      events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0),
                               pollfd(fd: errEOF ? -1 : stderr,
                                      events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)]
            _ = descriptors.withUnsafeMutableBufferPointer { buffer in
                Darwin.poll(buffer.baseAddress, nfds_t(buffer.count), 20)
            }
        }
    }

    private enum GroupState: Equatable { case present, absent, unknown(Int32) }

    private static func groupState(_ pid: pid_t) -> GroupState {
        if Darwin.kill(-pid, 0) == 0 { return .present }
        let code = errno
        return code == ESRCH ? .absent : .unknown(code)
    }

    private static func drain(_ descriptor: Int32, into tail: inout ExternalVideoTail,
                              eof: inout Bool, failed: inout Bool,
                              diagnostics: inout [String]) {
        if eof { return }
        var bytes = [UInt8](repeating: 0, count: 8192)
        // Bound work on each pipe per pass so a chatty writer cannot starve the
        // other pipe, cancellation, timeout, waitpid or escalation.
        for _ in 0..<4 {
            let count = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 { tail.append(bytes.prefix(count)); continue }
            if count == 0 { eof = true; return }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { return }
            failed = true
            eof = true // The handle will close, but this is never a confirmed EOF.
            diagnostics.append("pipe read failed with errno \(errno)")
            return
        }
    }

    private static func result(reason: ExternalVideoProcessResult.StopReason, status: Int32?,
                               pid: pid_t, drained: Bool, out: ExternalVideoTail,
                               err: ExternalVideoTail, diagnostics: [String]) -> ExternalVideoProcessResult {
        let code: Int32? = status.map { raw in
            // Darwin wait status: 0...255 for normal exit, negative signal number
            // for signal termination. An unknown/unstopped parent stays nil.
            let signal = raw & 0x7f
            return signal == 0 ? (raw >> 8) & 0xff : -signal
        }
        let suffix = diagnostics.isEmpty ? "" : "\n[transport] " + diagnostics.joined(separator: "; ")
        var stderrBytes = err.data
        stderrBytes.append(contentsOf: suffix.utf8)
        return .init(reason: reason, exitCode: code, processID: pid, fullyDrained: drained,
                     stdoutTail: boundedString(out.data), stderrTail: boundedString(stderrBytes))
    }

    private static func boundedString(_ data: Data) -> String {
        let decoded = String(decoding: data.suffix(65_536), as: UTF8.self)
        var selected: [Character] = []
        var size = 0
        for character in decoded.reversed() {
            let count = String(character).utf8.count
            if size + count > 65_536 { break }
            selected.append(character)
            size += count
        }
        return String(selected.reversed())
    }
}

struct ExternalVideoProcessResult: Sendable {
    /// `cleanupUnconfirmed` also marks a root/descendant contract failure; in that
    /// case `fullyDrained` can be true after the owned group is terminated.
    enum StopReason: String, Sendable, Equatable { case exited, cancelled, timedOut, cleanupUnconfirmed }
    let reason: StopReason
    /// 0...255 for normal exit, negative signal number for signal death, nil if unknown.
    let exitCode: Int32?
    let processID: Int32?
    let fullyDrained: Bool
    let stdoutTail: String
    let stderrTail: String
}

// The only cross-thread mutable state is a boolean protected by this lock.
// onCancel only sets it; the single monitor queue owns every PID, fd and signal.
private final class ExternalVideoCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

private struct ExternalVideoPipe {
    var readFD: Int32
    var writeFD: Int32
    mutating func closeWriter() {
        if writeFD >= 0 { _ = Darwin.close(writeFD); writeFD = -1 }
    }
    mutating func close() {
        if readFD >= 0 { _ = Darwin.close(readFD); readFD = -1 }
        closeWriter()
    }
}

private struct ExternalVideoTail {
    private var bytes = Data()
    mutating func append(_ newBytes: ArraySlice<UInt8>) {
        bytes.append(contentsOf: newBytes)
        if bytes.count > 65_536 { bytes.removeFirst(bytes.count - 65_536) }
    }
    var data: Data { bytes }
}
