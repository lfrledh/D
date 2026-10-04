import CoreFoundation
import Darwin
import Foundation

public struct ChatPythonInput: Sendable {
    public let name: String
    public let data: Data

    public init(name: String, data: Data) {
        self.name = name
        self.data = data
    }
}

public struct ChatPythonOutput: Codable, Sendable, Equatable {
    public let name: String
    public let kind: ChatArtifactContent.Kind
    public let text: String

    public init(name: String, kind: ChatArtifactContent.Kind, text: String) {
        self.name = name
        self.kind = kind
        self.text = text
    }
}

public struct ChatPythonResult: Codable, Sendable, Equatable {
    public let stdout: String
    public let stderr: String
    public let outputs: [ChatPythonOutput]
    public let pythonVersion: String
    public let runtimeVersion: String
    public let engine: String
}

/// Bounded output from a child that did not complete the success protocol.
public struct ChatPythonDiagnostic: Sendable, Equatable {
    public let stdout: String
    public let stderr: String
    public let terminationStatus: Int32
    public let terminatedBySignal: Bool
    public let stdoutTruncated: Bool
    public let stderrTruncated: Bool

    fileprivate var summary: String {
        let status = terminatedBySignal ? "signal \(terminationStatus)" : "exit status \(terminationStatus)"
        var sections = [status]
        // The Controller stores only the first 2048 characters of localizedDescription.
        // Reserve space for both streams; also bound UTF-8 bytes because a single
        // composed Character can exceed the Store issue budget. Put the error stream first.
        let shownStderr = String(decoding: stderr.prefix(900).utf8.prefix(4096), as: UTF8.self)
        let shownStdout = String(decoding: stdout.prefix(600).utf8.prefix(4096), as: UTF8.self)
        if !shownStderr.isEmpty { sections.append("stderr:\n\(shownStderr)") }
        if stderrTruncated || stderr.count > 900 || stderr.utf8.count > 4096 { sections.append("[stderr truncated]") }
        if !shownStdout.isEmpty { sections.append("stdout:\n\(shownStdout)") }
        if stdoutTruncated || stdout.count > 600 || stdout.utf8.count > 4096 { sections.append("[stdout truncated]") }
        return sections.joined(separator: "\n")
    }
}

public enum ChatPythonError: Error, Equatable, LocalizedError, Sendable {
    case invalidCode, invalidInput, inputTooLarge, invalidOutput, outputTooLarge
    case unavailable, setupFailed, guestFailed, resourceLimit, timedOut, cancelled
    indirect case executionFailed(reason: ChatPythonError, diagnostic: ChatPythonDiagnostic)
    indirect case cleanupFailed(after: ChatPythonError?)

    public var errorDescription: String? {
        switch self {
        case .invalidCode: "Python code must be nonblank UTF-8, at most 64 KiB, without NUL."
        case .invalidInput: "Select up to eight uniquely named regular input files."
        case .inputTooLarge: "Selected inputs exceed the per-file or combined size limit."
        case .invalidOutput: "Python returned an invalid UTF-8 result or file declaration."
        case .outputTooLarge: "Python output exceeds the allowed size."
        case .unavailable: "The bundled Python WASI engine is unavailable or invalid."
        case .setupFailed: "The Python WASI engine could not start or prepare its inputs."
        case .guestFailed: "Python execution failed inside the WASI engine."
        case .resourceLimit: "Python execution exceeded an engine resource limit."
        case .timedOut: "Python execution timed out."
        case .cancelled: "Python execution was cancelled."
        case .executionFailed(let reason, let diagnostic):
            "\(reason.localizedDescription)\n\(diagnostic.summary)"
        case .cleanupFailed(let original):
            if let original {
                "Private Python files could not be fully removed after \(original.localizedDescription)"
            } else {
                "Private Python files could not be fully removed after execution."
            }
        }
    }
}

/// Runs only the packaged WASI helper. The returned files are untrusted text, not saved assets.
public struct ChatPythonClient: Sendable {
    private let packageURL: URL?

    public init(packageURL: URL? = nil) { self.packageURL = packageURL }

    public func run(code: String, inputs: [ChatPythonInput]) async throws -> ChatPythonResult {
        if Task.isCancelled { throw ChatPythonError.cancelled }
        try ChatPythonPolicy.validate(code: code, inputs: inputs)
        let package = try ChatPythonPolicy.package(at: packageURL)
        if Task.isCancelled { throw ChatPythonError.cancelled }
        let control = ChatPythonChildControl()
        do {
            let result = try await withTaskCancellationHandler {
                try await WorkflowCPU.run {
                    try Self.execute(code: code, inputs: inputs, package: package, control: control)
                }
            } onCancel: {
                control.stop(cancelled: true)
            }
            try Task.checkCancellation()
            return result
        } catch is CancellationError {
            throw ChatPythonError.cancelled
        }
    }

    private static func execute(code: String, inputs: [ChatPythonInput],
                                package: ChatPythonPackage, control: ChatPythonChildControl) throws -> ChatPythonResult {
        try control.checkCancellation()
        let directory = try ChatPythonPolicy.privateDirectory()
        let outcome = Result {
            try executeInDirectory(code: code, inputs: inputs, package: package,
                                   control: control, directory: directory)
        }
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            let original: ChatPythonError?
            switch outcome {
            case .success: original = nil
            case .failure(let error):
                if let error = error as? ChatPythonError {
                    original = error
                } else if error is CancellationError {
                    original = .cancelled
                } else {
                    original = .setupFailed
                }
            }
            throw ChatPythonError.cleanupFailed(after: original)
        }
        return try outcome.get()
    }

    private static func executeInDirectory(code: String, inputs: [ChatPythonInput],
                                           package: ChatPythonPackage, control: ChatPythonChildControl,
                                           directory: URL) throws -> ChatPythonResult {
        let inputDirectory = directory.appendingPathComponent("input", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: inputDirectory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            try ChatPythonPolicy.write(Data(code.utf8), to: inputDirectory.appendingPathComponent("program.py"))
            for input in inputs {
                try control.checkCancellation()
                try ChatPythonPolicy.write(input.data, to: inputDirectory.appendingPathComponent(input.name))
            }
        } catch is CancellationError {
            throw ChatPythonError.cancelled
        } catch let error as ChatPythonError {
            throw error
        } catch {
            throw ChatPythonError.setupFailed
        }
        let stdoutURL = directory.appendingPathComponent("stdout")
        let stderrURL = directory.appendingPathComponent("stderr")
        let stdout = try ChatPythonPolicy.outputFile(at: stdoutURL)
        defer { try? stdout.close() }
        let stderr = try ChatPythonPolicy.outputFile(at: stderrURL)
        defer { try? stderr.close() }
        let process = Process()
        process.executableURL = package.runner
        process.arguments = ["--runtime", package.runtime.path, "--inputs", inputDirectory.path]
        process.environment = ["LC_ALL": "C", "LANG": "C", "TMPDIR": directory.path]
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try control.start(process)
        } catch is CancellationError {
            throw ChatPythonError.cancelled
        } catch {
            throw ChatPythonError.setupFailed
        }
        // The worker owns the blocking wait. Cancellation and the watchdog only signal this child.
        process.waitUntilExit()
        control.exited()
        try? stdout.close()
        try? stderr.close()
        let terminationStatus = process.terminationStatus
        let terminatedBySignal = process.terminationReason != .exit
        let diagnostic = ChatPythonPolicy.readDiagnostic(stdoutURL, stderrURL,
            privateDirectory: directory, terminationStatus: terminationStatus,
            terminatedBySignal: terminatedBySignal)
        // Cancellation is intentionally surfaced as cancelled, never as a child crash or UI diagnostic.
        if control.wasCancelled { throw ChatPythonError.cancelled }
        let failure: ChatPythonError?
        if control.didTimeOut {
            failure = .timedOut
        } else if terminatedBySignal {
            failure = .guestFailed
        } else {
            switch terminationStatus {
            case 0: failure = nil
            case 2: failure = .setupFailed
            case 3: failure = .guestFailed
            case 4: failure = .resourceLimit
            case 5: failure = .timedOut
            case 6: throw ChatPythonError.cancelled
            default: failure = .guestFailed
            }
        }
        if let failure {
            throw ChatPythonError.executionFailed(reason: failure, diagnostic: diagnostic)
        }
        do {
            let out = try ChatPythonPolicy.readOutput(stdoutURL, stderrURL)
            return try ChatPythonPolicy.decode(stdout: out.0, stderr: out.1)
        } catch let error as ChatPythonError {
            throw ChatPythonError.executionFailed(reason: error, diagnostic: diagnostic)
        } catch {
            throw ChatPythonError.executionFailed(reason: .invalidOutput, diagnostic: diagnostic)
        }
    }
}

struct ChatPythonPackage: Sendable {
    let runner: URL
    let runtime: URL
}

/// Pure validation and protocol decoding are also exercised directly by fixture tests.
enum ChatPythonPolicy {
    static let maximumOutputBytes = 1_048_576
    private static let maximumDiagnosticBytesPerStream = 65_536
    // Matches the prepared engine inventory budget, not the user-code budget.
    static let maximumManifestBytes = 4 * 1_024 * 1_024
    private static let protocolPrefix = "D_CHAT_FILE_V1:"

    static func validate(code: String, inputs: [ChatPythonInput]) throws {
        guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              code.utf8.count <= 65_536, !code.contains("\0") else { throw ChatPythonError.invalidCode }
        guard inputs.count <= 8 else { throw ChatPythonError.invalidInput }
        var names = Set<String>()
        var total = 0
        for input in inputs {
            guard validName(input.name), names.insert(input.name).inserted else { throw ChatPythonError.invalidInput }
            guard input.data.count <= 2_097_152 else { throw ChatPythonError.inputTooLarge }
            total += input.data.count
            guard total <= 4_194_304 else { throw ChatPythonError.inputTooLarge }
        }
    }

    private static func validName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 128 && name.utf8.count <= 512 &&
        name != "." && name != ".." && name != "program.py" &&
        !name.unicodeScalars.contains(where: { scalar in
            scalar == "/" || scalar == "\\" || scalar.value <= 0x1f ||
            (0x7f...0x9f).contains(scalar.value)
        })
    }

    static func decode(stdout: Data, stderr: Data) throws -> ChatPythonResult {
        guard stdout.count + stderr.count <= maximumOutputBytes else { throw ChatPythonError.outputTooLarge }
        guard let rawOut = String(data: stdout, encoding: .utf8),
              let rawErr = String(data: stderr, encoding: .utf8) else { throw ChatPythonError.invalidOutput }
        var shown = ""
        var outputs: [ChatPythonOutput] = []
        var names = Set<String>()
        var total = 0
        let lines = rawOut.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            let value = String(line)
            if value.hasPrefix(protocolPrefix) {
                guard outputs.count < 8 else { throw ChatPythonError.outputTooLarge }
                let payload = Data(value.dropFirst(protocolPrefix.count).utf8)
                do {
                    try WorkflowStructuredText.validateJSONSyntax(String(value.dropFirst(protocolPrefix.count)))
                } catch {
                    throw ChatPythonError.invalidOutput
                }
                guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                      object.count == 3, let name = object["name"] as? String,
                      let kindName = object["kind"] as? String,
                      let text = object["text"] as? String,
                      validName(name), names.insert(name).inserted,
                      let kind = ChatArtifactContent.Kind(rawValue: kindName),
                      let suffix = suffix(for: kind),
                      name.hasSuffix(suffix), !text.contains("\0") else { throw ChatPythonError.invalidOutput }
                total += text.utf8.count
                guard total <= 262_144 else { throw ChatPythonError.outputTooLarge }
                outputs.append(.init(name: name, kind: kind, text: text))
            } else {
                shown += value
                if index < lines.count - 1 { shown += "\n" }
            }
        }
        return .init(stdout: shown, stderr: rawErr, outputs: outputs,
                     pythonVersion: "3.14.8", runtimeVersion: "49.0.2", engine: "pulley")
    }

    private static func suffix(for kind: ChatArtifactContent.Kind) -> String? {
        switch kind {
        case .plainText: ".txt"
        case .csv: ".csv"
        case .svg: ".svg"
        default: nil
        }
    }

    static func package(at injected: URL?) throws -> ChatPythonPackage {
        let root: URL
        if let injected {
            root = injected
        } else {
            guard let resources = Bundle.main.resourceURL else { throw ChatPythonError.unavailable }
            root = resources.appendingPathComponent("Engines/ChatPython.dengine", isDirectory: true)
        }
        let runner = root.appendingPathComponent("runner")
        let runtime = root.appendingPathComponent("runtime", isDirectory: true)
        let module = runtime.appendingPathComponent("python.wasm")
        let standardLibrary = runtime.appendingPathComponent("lib/python3.14", isDirectory: true)
        guard isPlain(root, directory: true), isPlain(runner, directory: false),
              FileManager.default.isExecutableFile(atPath: runner.path),
              isPlain(runtime, directory: true), isPlain(module, directory: false),
              isPlain(runtime.appendingPathComponent("lib"), directory: true),
              isPlain(standardLibrary, directory: true) else { throw ChatPythonError.unavailable }
        let manifest = root.appendingPathComponent("engine.json")
        guard isPlain(manifest, directory: false),
              let handle = try? FileHandle(forReadingFrom: manifest) else { throw ChatPythonError.unavailable }
        defer { try? handle.close() }
        var bytes = Data()
        do {
            while bytes.count <= maximumManifestBytes {
                guard let chunk = try handle.read(upToCount: maximumManifestBytes + 1 - bytes.count), !chunk.isEmpty else { break }
                bytes.append(chunk)
            }
        } catch {
            throw ChatPythonError.unavailable
        }
        guard bytes.count <= maximumManifestBytes,
              let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let schema = object["schemaVersion"] as? NSNumber,
              CFGetTypeID(schema) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: schema.objCType)), schema.intValue == 1,
              object["kind"] as? String == "d-chat-python-wasi",
              object["pythonVersion"] as? String == "3.14.8",
              object["wasmtimeVersion"] as? String == "49.0.2",
              object["engine"] as? String == "pulley64" else { throw ChatPythonError.unavailable }
        let dynamicLibrary = root.appendingPathComponent("libwasmtime.dylib")
        if FileManager.default.fileExists(atPath: dynamicLibrary.path) && !isPlain(dynamicLibrary, directory: false) {
            throw ChatPythonError.unavailable
        }
        return .init(runner: runner, runtime: runtime)
    }

    private static func isPlain(_ url: URL, directory: Bool) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return (info.st_mode & mode_t(S_IFMT)) == mode_t(directory ? S_IFDIR : S_IFREG)
    }

    static func privateDirectory() throws -> URL {
        let template = FileManager.default.temporaryDirectory.appendingPathComponent("d-python-XXXXXX").path
        var name = Array(template.utf8CString)
        guard name.withUnsafeMutableBufferPointer({ mkdtemp($0.baseAddress) }) != nil else {
            throw ChatPythonError.setupFailed
        }
        return URL(fileURLWithPath: String(cString: name), isDirectory: true)
    }

    static func write(_ data: Data, to url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw ChatPythonError.setupFailed }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        do { try file.write(contentsOf: data) } catch { throw ChatPythonError.setupFailed }
    }

    static func outputFile(at url: URL) throws -> FileHandle {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw ChatPythonError.setupFailed }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    static func readOutput(_ stdout: URL, _ stderr: URL) throws -> (Data, Data) {
        guard let outSize = (try? FileManager.default.attributesOfItem(atPath: stdout.path)[.size] as? NSNumber)?.intValue,
              let errSize = (try? FileManager.default.attributesOfItem(atPath: stderr.path)[.size] as? NSNumber)?.intValue
        else { throw ChatPythonError.invalidOutput }
        guard outSize <= maximumOutputBytes, errSize <= maximumOutputBytes,
              outSize + errSize <= maximumOutputBytes else { throw ChatPythonError.outputTooLarge }
        guard let out = try? Data(contentsOf: stdout), let err = try? Data(contentsOf: stderr) else {
            throw ChatPythonError.invalidOutput
        }
        guard out.count + err.count <= maximumOutputBytes else { throw ChatPythonError.outputTooLarge }
        return (out, err)
    }

    static func readDiagnostic(_ stdout: URL, _ stderr: URL, privateDirectory: URL,
                               terminationStatus: Int32, terminatedBySignal: Bool) -> ChatPythonDiagnostic {
        let out = diagnosticPrefix(at: stdout, privateDirectory: privateDirectory)
        let err = diagnosticPrefix(at: stderr, privateDirectory: privateDirectory)
        return .init(stdout: out.0, stderr: err.0, terminationStatus: terminationStatus,
                     terminatedBySignal: terminatedBySignal,
                     stdoutTruncated: out.1, stderrTruncated: err.1)
    }

    private static func diagnosticPrefix(at url: URL, privateDirectory: URL) -> (String, Bool) {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return ("[diagnostic output could not be read]", false) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            return ("[diagnostic output is not a regular file]", false)
        }
        do {
            var prefix = Data()
            while prefix.count <= maximumDiagnosticBytesPerStream {
                let remaining = maximumDiagnosticBytesPerStream + 1 - prefix.count
                guard let chunk = try handle.read(upToCount: remaining), !chunk.isEmpty else { break }
                prefix.append(chunk)
            }
            let truncated = prefix.count > maximumDiagnosticBytesPerStream
            let shown = prefix.prefix(maximumDiagnosticBytesPerStream)
            let text = String(decoding: shown, as: UTF8.self)
                .replacingOccurrences(of: privateDirectory.path, with: "<private Python directory>")
            return (text, truncated)
        } catch {
            return ("[diagnostic output could not be read]", false)
        }
    }
}

/// Synchronizes cancellation, launch and the single owned process. The delayed KILL is inert after exit.
private final class ChatPythonChildControl: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var finished = false
    private var cancelled = false
    private var timedOut = false
    private var stopped = false

    var wasCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    var didTimeOut: Bool { lock.lock(); defer { lock.unlock() }; return timedOut }

    func checkCancellation() throws {
        if wasCancelled { throw CancellationError() }
    }

    func start(_ child: Process) throws {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        try child.run()
        process = child
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 35) { [self] in
            stop(cancelled: false)
        }
    }

    func stop(cancelled isCancellation: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if finished { return }
        if isCancellation { cancelled = true }
        guard let process, process.isRunning else { return }
        if !isCancellation { timedOut = true }
        guard !stopped else { return }
        stopped = true
        process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [self] in
            lock.lock()
            defer { lock.unlock() }
            guard !finished, let ownedProcess = self.process, ownedProcess.isRunning else { return }
            _ = Darwin.kill(ownedProcess.processIdentifier, SIGKILL)
        }
    }

    func exited() {
        lock.lock(); finished = true; lock.unlock()
    }
}
