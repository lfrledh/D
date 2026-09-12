import Darwin
import DInference
import DMLXBackend
import Foundation

enum CLICapability: String, Sendable, Codable { case text, image, audio }
enum CLIImageProfile: String, Sendable, Codable { case verified512, scalableKlein4B }

struct CLIOptions: Sendable, Codable {
    var model: String
    var prompt: String
    var promptFile: String?
    var capability: CLICapability = .text
    var maxTokens = 64
    var maxPromptTokens = 2048
    var maxOutputTokens = 1024
    var cacheLimitMiB = 64
    var temperature: Float = 0
    var topP: Float = 0.95
    var memoryBudgetMiB: UInt64 = 2048
    var imageMemoryLimitMiB: UInt64?
    var revision: String?
    var report: String?
    var inspect = false
    var cancelAfterChunks: Int?
    var repeatCount = 1
    var width = 512
    var height = 512
    var steps = 4
    var guidance: Float = 1
    var seed: UInt64 = 42
    var artifacts: String?
    var cancelAfterSteps: Int?
    var imageProfile: CLIImageProfile = .verified512
    var audioOperation: AudioOperation = .generate
    var durationSeconds: Double = 6
    var audioSource: String?
    var audioSourceSHA256: String?
    var audioSourceFrames: Int64?
    var audioEditStartFrame: Int64?
    var audioEditEndFrame: Int64?
    var audioStrength: Float = 1
    var audioProfile: AudioBackendProfile?
    var audioPython: String?
    var audioScript: String?
    var audioVendor: String?
    var audioManifest: String?
    var audioLicenseAcknowledged = false
    var timeoutSeconds: Double = 600

    var memoryBudgetBytes: UInt64 { memoryBudgetMiB * 1024 * 1024 }
    var cacheLimitBytes: Int { cacheLimitMiB * 1024 * 1024 }
    var imageMemoryLimitBytes: Int? {
        imageMemoryLimitMiB.map { Int($0 * 1024 * 1024) }
    }
    var backendID: String {
        switch capability {
        case .text: "mlx.text"
        case .image: "mlx.image.flux2-klein"
        case .audio: "mlx.audio.sa3"
        }
    }
    var selectedImageProfile: ImageExecutionProfile {
        imageProfile == .verified512 ? .verified512 : .scalableKlein4B
    }

    static let usage = """
    Usage: d-infer --model ABSOLUTE_PATH (--prompt TEXT | --prompt-file ABSOLUTE_PATH) [options]

    Runs a local model; does not download models.
      --model PATH                 Absolute local model directory (required)
      --prompt TEXT                Prompt, including an empty string
      --prompt-file PATH           Read a UTF-8 prompt from a regular file (maximum: 1 MiB)
      --capability text|image|audio
      --memory-budget-mib N        Admission budget (default: text 2048, image/audio 8192)
      --inspect                    Estimate resources without running inference
      --revision STRING            Required pinned revision for audio
      --report PATH                Atomically write a JSON execution report
      --repeat N                   Sequential runs in this process (default: 1)
      --max-tokens N --temperature FLOAT --top-p FLOAT --cancel-after-chunks N
                                   Text-only generation controls
      --max-prompt-tokens N        Text prompt token limit (1...32768, default: 2048)
      --max-output-tokens N        Text output token limit (1...8192, default: 1024)
      --cache-limit-mib N          Text MLX cache limit (0...1024, default: 64)
      --width N --height N         Image dimensions (default: 512 x 512)
      --image-profile verified512|scalableKlein4B
                                   Image-only execution envelope (default: verified512)
      --image-memory-limit-mib N   Image allocator limit, at most the admission budget
      --steps N --guidance FLOAT --seed N --artifacts PATH
                                   Image/audio controls; artifacts is required for both
      --cancel-after-steps N       Image-only cancellation control
      --audio-operation generate|variation|inpaint
      --duration-seconds FLOAT     Audio duration (default: 6)
      --audio-source PATH --audio-source-sha256 HEX --audio-source-frames N
      --audio-edit-start-frame N --audio-edit-end-frame N --audio-strength FLOAT
      --audio-profile sm-music|sm-sfx|medium
      --audio-python PATH --audio-script PATH --audio-vendor PATH --audio-manifest PATH
      --audio-license-acknowledged true
                                   Caller explicitly confirms it already has model rights
      --timeout-seconds FLOAT      Audio child timeout (default: 600)
      --help, -h

    Text writes generated text to stdout. Image/audio write artifact JSON lines to stdout;
    progress and diagnostics go to stderr. Exit status: 0 completed, 1 execution/report
    failure, 2 invalid arguments, 130 cancelled.
    """

    static func parse(_ arguments: [String]) throws -> Self? {
        let valueOptions: Set<String> = [
            "--model", "--prompt", "--prompt-file", "--max-tokens", "--temperature", "--top-p",
            "--max-prompt-tokens", "--max-output-tokens", "--cache-limit-mib",
            "--memory-budget-mib", "--revision", "--report", "--cancel-after-chunks", "--repeat",
            "--capability", "--width", "--height", "--steps", "--guidance", "--seed",
            "--artifacts", "--cancel-after-steps", "--image-profile", "--image-memory-limit-mib",
            "--audio-operation",
            "--duration-seconds", "--audio-source", "--audio-source-sha256", "--audio-source-frames",
            "--audio-edit-start-frame", "--audio-edit-end-frame", "--audio-strength", "--audio-profile",
            "--audio-python", "--audio-script", "--audio-vendor", "--audio-manifest",
            "--audio-license-acknowledged", "--timeout-seconds",
        ]
        let switches: Set<String> = ["--inspect"]
        var values: [String: String] = [:]
        var enabledSwitches: Set<String> = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--help" || argument == "-h" { return nil }
            let components = argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(components[0])
            guard valueOptions.contains(key) || switches.contains(key) else {
                throw CLIArgumentError("Unknown option: \(argument)")
            }
            if switches.contains(key) {
                guard components.count == 1 else { throw CLIArgumentError("\(key) does not take a value.") }
                guard enabledSwitches.insert(key).inserted else { throw CLIArgumentError("Repeated option: \(key)") }
                index += 1
                continue
            }
            guard values[key] == nil else { throw CLIArgumentError("Repeated option: \(key)") }
            if components.count == 2 { values[key] = String(components[1]) }
            else {
                index += 1
                guard index < arguments.count else { throw CLIArgumentError("Missing value for \(key)") }
                values[key] = arguments[index]
            }
            index += 1
        }
        guard let model = absolute(values["--model"]) else {
            throw CLIArgumentError("--model must name an absolute local directory.")
        }
        let directPrompt = values["--prompt"]
        let promptPath = values["--prompt-file"]
        guard (directPrompt != nil) != (promptPath != nil) else {
            throw CLIArgumentError("Exactly one of --prompt and --prompt-file is required.")
        }
        let promptFile: String?
        let prompt: String
        if let directPrompt {
            prompt = directPrompt
            promptFile = nil
        } else {
            guard let path = absolute(promptPath) else {
                throw CLIArgumentError("--prompt-file must name an absolute local file.")
            }
            prompt = try readPromptFile(path)
            promptFile = path
        }
        guard let capability = CLICapability(rawValue: values["--capability"] ?? "text") else {
            throw CLIArgumentError("--capability must be text, image, or audio.")
        }
        var options = Self(model: model, prompt: prompt)
        options.promptFile = promptFile
        options.capability = capability
        options.inspect = enabledSwitches.contains("--inspect")
        options.repeatCount = try positiveInt(values, "--repeat", fallback: 1)

        let textFlags = [
            "--max-tokens", "--temperature", "--top-p", "--cancel-after-chunks",
            "--max-prompt-tokens", "--max-output-tokens", "--cache-limit-mib",
        ]
        let imageOnly = [
            "--width", "--height", "--image-profile", "--cancel-after-steps",
            "--image-memory-limit-mib",
        ]
        let sharedMedia = ["--steps", "--guidance", "--seed", "--artifacts"]
        let audioOnly = [
            "--audio-operation", "--duration-seconds", "--audio-source", "--audio-source-sha256",
            "--audio-source-frames", "--audio-edit-start-frame", "--audio-edit-end-frame",
            "--audio-strength", "--audio-profile", "--audio-python", "--audio-script",
            "--audio-vendor", "--audio-manifest", "--audio-license-acknowledged", "--timeout-seconds",
        ]
        let forbidden: [String]
        switch capability {
        case .text: forbidden = imageOnly + sharedMedia + audioOnly
        case .image: forbidden = textFlags + audioOnly
        case .audio: forbidden = textFlags + imageOnly
        }
        if let key = forbidden.first(where: { values[$0] != nil }) {
            throw CLIArgumentError("\(key) cannot be used with --capability \(capability.rawValue).")
        }

        options.maxPromptTokens = try boundedInt(values, "--max-prompt-tokens", fallback: options.maxPromptTokens,
                                                 range: 1...32768)
        options.maxOutputTokens = try boundedInt(values, "--max-output-tokens", fallback: options.maxOutputTokens,
                                                 range: 1...8192)
        options.cacheLimitMiB = try boundedInt(values, "--cache-limit-mib", fallback: options.cacheLimitMiB,
                                               range: 0...1024)
        options.maxTokens = try positiveInt(values, "--max-tokens", fallback: options.maxTokens)
        if capability == .text, options.maxTokens > options.maxOutputTokens {
            throw CLIArgumentError("--max-tokens must not exceed --max-output-tokens.")
        }
        options.width = try positiveInt(values, "--width", fallback: options.width)
        options.height = try positiveInt(values, "--height", fallback: options.height)
        options.steps = try positiveInt(values, "--steps", fallback: capability == .audio ? 8 : options.steps)
        if values["--cancel-after-chunks"] != nil {
            options.cancelAfterChunks = try positiveInt(values, "--cancel-after-chunks", fallback: 1)
        }
        if values["--cancel-after-steps"] != nil {
            options.cancelAfterSteps = try positiveInt(values, "--cancel-after-steps", fallback: 1)
        }
        options.temperature = try finiteFloat(values, "--temperature", fallback: options.temperature,
                                              where: { $0 >= 0 }, description: "finite and >= 0")
        options.topP = try finiteFloat(values, "--top-p", fallback: options.topP,
                                      where: { $0 > 0 && $0 <= 1 }, description: "finite, > 0, and <= 1")
        options.guidance = try finiteFloat(values, "--guidance", fallback: options.guidance,
                                          where: { $0 >= 0 }, description: "finite and >= 0")
        if let raw = values["--seed"] {
            guard let seed = UInt64(raw) else { throw CLIArgumentError("--seed must be an unsigned 64-bit integer.") }
            options.seed = seed
        }
        if let raw = values["--memory-budget-mib"] {
            guard let value = UInt64(raw), value > 0, value <= UInt64.max / (1024 * 1024) else {
                throw CLIArgumentError("--memory-budget-mib must be a positive, representable MiB value.")
            }
            options.memoryBudgetMiB = value
        } else if capability != .text { options.memoryBudgetMiB = 8192 }
        options.revision = values["--revision"]
        options.report = values["--report"]
        if let report = options.report, report.isEmpty || report.contains("\0") {
            throw CLIArgumentError("--report cannot be empty or contain a NUL byte.")
        }

        if capability == .image {
            guard let profile = CLIImageProfile(rawValue: values["--image-profile"] ?? "verified512") else {
                throw CLIArgumentError("--image-profile must be verified512 or scalableKlein4B.")
            }
            options.imageProfile = profile
            if let raw = values["--image-memory-limit-mib"] {
                guard let value = UInt64(raw), value > 0,
                      value <= UInt64(Int.max) / (1024 * 1024), value <= options.memoryBudgetMiB else {
                    throw CLIArgumentError(
                        "--image-memory-limit-mib must be positive, representable, and no greater than the admission budget.")
                }
                options.imageMemoryLimitMiB = value
            }
        }
        if capability == .image || capability == .audio {
            guard let path = absolute(values["--artifacts"]) else {
                throw CLIArgumentError("\(capability.rawValue.capitalized) mode requires --artifacts as an absolute task directory.")
            }
            options.artifacts = path
        }
        if capability == .audio { try parseAudio(values, into: &options) }
        try validateDestinations(options)
        return options
    }

    private static func parseAudio(_ values: [String: String], into options: inout Self) throws {
        guard let operation = AudioOperation(rawValue: values["--audio-operation"] ?? "generate") else {
            throw CLIArgumentError("--audio-operation must be generate, variation, or inpaint.")
        }
        options.audioOperation = operation
        if let raw = values["--duration-seconds"] {
            guard let value = Double(raw), value.isFinite, value > 0 else {
                throw CLIArgumentError("--duration-seconds must be finite and positive.")
            }
            options.durationSeconds = value
        }
        options.audioStrength = try finiteFloat(values, "--audio-strength", fallback: 1,
                                                where: { $0 > 0 && $0 <= 1 }, description: "finite, > 0, and <= 1")
        if operation == .generate, options.audioStrength != 1 {
            throw CLIArgumentError("Audio generation requires --audio-strength 1.")
        }
        guard let profileRaw = values["--audio-profile"],
              let profile = AudioBackendProfile(rawValue: profileRaw) else {
            throw CLIArgumentError("Audio mode requires --audio-profile sm-music, sm-sfx, or medium.")
        }
        options.audioProfile = profile
        guard let python = absolute(values["--audio-python"]),
              let script = absolute(values["--audio-script"]),
              let vendor = absolute(values["--audio-vendor"]),
              let manifest = absolute(values["--audio-manifest"]) else {
            throw CLIArgumentError("Audio mode requires absolute --audio-python, --audio-script, --audio-vendor, and --audio-manifest paths.")
        }
        options.audioPython = python
        options.audioScript = script
        options.audioVendor = vendor
        options.audioManifest = manifest
        guard values["--audio-license-acknowledged"] == "true" else {
            throw CLIArgumentError("Audio mode requires --audio-license-acknowledged true from a caller that already has rights.")
        }
        options.audioLicenseAcknowledged = true
        if let raw = values["--timeout-seconds"] {
            guard let value = Double(raw), value.isFinite, value > 0 else {
                throw CLIArgumentError("--timeout-seconds must be finite and positive.")
            }
            options.timeoutSeconds = value
        }
        guard options.revision == AudioBackendConfiguration.registeredModelRevision else {
            throw CLIArgumentError("Audio mode requires --revision \(AudioBackendConfiguration.registeredModelRevision).")
        }
        let sourceKeys = ["--audio-source", "--audio-source-sha256", "--audio-source-frames"]
        if operation == .generate {
            if let key = (sourceKeys + ["--audio-edit-start-frame", "--audio-edit-end-frame"]).first(where: { values[$0] != nil }) {
                throw CLIArgumentError("\(key) is not valid for audio generation.")
            }
            return
        }
        guard let source = absolute(values["--audio-source"]),
              let sha = values["--audio-source-sha256"], sha.utf8.count == 64,
              sha.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              let framesRaw = values["--audio-source-frames"], let frames = Int64(framesRaw), frames > 0 else {
            throw CLIArgumentError("Audio edit operations require source path, lowercase SHA-256, and positive frame count.")
        }
        options.audioSource = source
        options.audioSourceSHA256 = sha
        options.audioSourceFrames = frames
        if operation == .variation {
            guard values["--audio-edit-start-frame"] == nil, values["--audio-edit-end-frame"] == nil else {
                throw CLIArgumentError("Audio variation does not accept edit frame bounds.")
            }
        } else {
            guard let startRaw = values["--audio-edit-start-frame"], let start = Int64(startRaw), start >= 0,
                  let endRaw = values["--audio-edit-end-frame"], let end = Int64(endRaw), end > start,
                  end <= frames else {
                throw CLIArgumentError("Audio inpaint requires a nonempty half-open edit frame interval within the source.")
            }
            options.audioEditStartFrame = start
            options.audioEditEndFrame = end
        }
    }

    private static func validateDestinations(_ options: Self) throws {
        guard options.capability != .text else { return }
        let protectedDirectories = [options.model, options.audioVendor].compactMap { $0 }.map {
            URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath()
        }
        if let artifacts = options.artifacts {
            let output = URL(fileURLWithPath: artifacts).standardizedFileURL.resolvingSymlinksInPath()
            guard protectedDirectories.allSatisfy({ !overlaps($0, output) }) else {
                throw CLIArgumentError("--artifacts must be separate from model and vendor directories.")
            }
            if let source = options.audioSource {
                let input = URL(fileURLWithPath: source).standardizedFileURL.resolvingSymlinksInPath()
                guard !overlaps(output, input) else { throw CLIArgumentError("--artifacts must be separate from audio input.") }
            }
        }
        if let report = options.report {
            let output = URL(fileURLWithPath: report).standardizedFileURL.resolvingSymlinksInPath()
            guard protectedDirectories.allSatisfy({ !contains($0, output) }),
                  [options.audioSource, options.audioManifest, options.audioScript].compactMap({ $0 }).allSatisfy({
                      URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath() != output
                  }) else {
                throw CLIArgumentError("--report must not target model, vendor, or audio input.")
            }
        }
    }

    static func reportDestination(in arguments: [String]) -> String? {
        func raw(_ key: String) -> String? {
            for (index, argument) in arguments.enumerated() {
                if argument.hasPrefix(key + "=") { return String(argument.dropFirst(key.count + 1)) }
                if argument == key, arguments.indices.contains(index + 1) { return arguments[index + 1] }
            }
            return nil
        }
        guard let destination = raw("--report"), !destination.isEmpty, !destination.contains("\0") else { return nil }
        let capability = raw("--capability") ?? "text"
        guard capability == "image" || capability == "audio" else { return destination }
        let output = URL(fileURLWithPath: destination).standardizedFileURL.resolvingSymlinksInPath()
        for key in ["--model", "--audio-vendor"] {
            if let path = raw(key), contains(URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath(), output) {
                return nil
            }
        }
        for key in ["--audio-source", "--audio-manifest", "--audio-script"] {
            if let input = raw(key),
               URL(fileURLWithPath: input).standardizedFileURL.resolvingSymlinksInPath() == output { return nil }
        }
        return destination
    }

    private static func positiveInt(_ values: [String: String], _ key: String, fallback: Int) throws -> Int {
        guard let raw = values[key] else { return fallback }
        guard let value = Int(raw), value > 0 else { throw CLIArgumentError("\(key) must be a positive integer.") }
        return value
    }

    private static func boundedInt(_ values: [String: String], _ key: String, fallback: Int,
                                   range: ClosedRange<Int>) throws -> Int {
        guard let raw = values[key] else { return fallback }
        guard let value = Int(raw), range.contains(value) else {
            throw CLIArgumentError("\(key) must be an integer in \(range.lowerBound)...\(range.upperBound).")
        }
        return value
    }

    private static func readPromptFile(_ path: String) throws -> String {
        let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw CLIArgumentError("--prompt-file must be a readable regular file and not a symbolic link.")
        }
        defer { Darwin.close(descriptor) }

        var identity = stat()
        guard Darwin.fstat(descriptor, &identity) == 0,
              identity.st_mode & S_IFMT == S_IFREG,
              identity.st_size >= 0,
              UInt64(identity.st_size) <= 1_048_576 else {
            throw CLIArgumentError("--prompt-file must be a regular file no larger than 1 MiB.")
        }

        let expectedSize = Int(identity.st_size)
        var data = Data()
        data.reserveCapacity(expectedSize)
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count < expectedSize {
            let requested = min(buffer.count, expectedSize - data.count)
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, requested)
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw CLIArgumentError("Cannot read the complete --prompt-file.") }
            data.append(contentsOf: buffer.prefix(count))
        }
        var extra: UInt8 = 0
        var trailing: Int
        repeat { trailing = Darwin.read(descriptor, &extra, 1) } while trailing < 0 && errno == EINTR
        guard trailing == 0 else { throw CLIArgumentError("--prompt-file exceeds 1 MiB or changed while being read.") }

        var finalIdentity = stat()
        guard Darwin.fstat(descriptor, &finalIdentity) == 0,
              finalIdentity.st_dev == identity.st_dev,
              finalIdentity.st_ino == identity.st_ino,
              finalIdentity.st_mode == identity.st_mode,
              finalIdentity.st_size == identity.st_size,
              finalIdentity.st_mtimespec.tv_sec == identity.st_mtimespec.tv_sec,
              finalIdentity.st_mtimespec.tv_nsec == identity.st_mtimespec.tv_nsec,
              finalIdentity.st_ctimespec.tv_sec == identity.st_ctimespec.tv_sec,
              finalIdentity.st_ctimespec.tv_nsec == identity.st_ctimespec.tv_nsec else {
            throw CLIArgumentError("--prompt-file changed while being read.")
        }
        guard let prompt = String(data: data, encoding: .utf8) else {
            throw CLIArgumentError("--prompt-file must contain valid UTF-8.")
        }
        return prompt
    }

    private static func finiteFloat(_ values: [String: String], _ key: String, fallback: Float,
                                    where predicate: (Float) -> Bool, description: String) throws -> Float {
        guard let raw = values[key] else { return fallback }
        guard let value = Float(raw), value.isFinite, predicate(value) else {
            throw CLIArgumentError("\(key) must be \(description).")
        }
        return value
    }

    private static func absolute(_ raw: String?) -> String? {
        guard let raw, raw.hasPrefix("/"), !raw.contains("\0"), !raw.isEmpty,
              !raw.split(separator: "/", omittingEmptySubsequences: false).contains("..") else { return nil }
        return raw
    }

    private static func contains(_ directory: URL, _ item: URL) -> Bool {
        item.path == directory.path || item.path.hasPrefix(directory.path + "/")
    }
    private static func overlaps(_ lhs: URL, _ rhs: URL) -> Bool { contains(lhs, rhs) || contains(rhs, lhs) }
}

struct CLIArgumentError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
