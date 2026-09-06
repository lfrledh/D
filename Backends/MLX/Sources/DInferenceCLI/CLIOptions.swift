import Foundation

enum CLICapability: String, Sendable, Codable {
    case text, image
}

struct CLIOptions: Sendable, Codable {
    var model: String
    var prompt: String
    var capability: CLICapability = .text
    var maxTokens: Int = 64
    var temperature: Float = 0
    var topP: Float = 0.95
    var memoryBudgetMiB: UInt64 = 2048
    var revision: String?
    var report: String?
    var cancelAfterChunks: Int?
    var repeatCount: Int = 1
    var width: Int = 512
    var height: Int = 512
    var steps: Int = 4
    var guidance: Float = 1
    var seed: UInt64 = 42
    var artifacts: String?
    var cancelAfterSteps: Int?

    var memoryBudgetBytes: UInt64 { memoryBudgetMiB * 1024 * 1024 }
    var backendID: String { capability == .text ? "mlx.text" : "mlx.image.flux2-klein" }

    static let usage = """
    Usage: d-infer --model ABSOLUTE_PATH --prompt TEXT [options]

    Runs a local MLX model; does not download models.
      --model PATH                 Absolute local model directory (required)
      --prompt TEXT                Prompt, including an empty string (required)
      --capability text|image      Inference mode (default: text)
      --max-tokens N               Maximum generated tokens (default: 64)
      --temperature FLOAT          Sampling temperature >= 0 (default: 0)
      --top-p FLOAT                Nucleus sampling, 0 < value <= 1 (default: 0.95)
      --memory-budget-mib N        Admission budget (default: text 2048, image 8192)
      --revision STRING           Model revision recorded as provenance
      --report PATH               Atomically write a JSON execution report
      --cancel-after-chunks N      Request cancellation after N text chunks
      --repeat N                  Sequential runs in this process (default: 1)
      --width N                   Image width (default: 512)
      --height N                  Image height (default: 512)
      --steps N                   Image denoising steps (default: 4)
      --guidance FLOAT            Image guidance scale (default: 1)
      --seed N                    Image seed, unsigned 64-bit (default: 42)
      --artifacts PATH            Absolute image task root (required for image)
      --cancel-after-steps N       Cancel after N completed image denoising steps
      --help, -h                  Show help without initializing the backend

    Text mode writes generated text to stdout. Image mode writes artifact JSON
    Lines to stdout; progress and diagnostics go to stderr. The image backend
    chooses unique per-run paths and preserves published images after release.
    Exit status: 0 completed; 1 execution/report failure; 2 invalid arguments;
    130 cancelled. The memory budget is an estimate-based admission limit.
    """

    /// A nil result means help was requested. Values may also use --option=value.
    static func parse(_ arguments: [String]) throws -> Self? {
        let recognized: Set<String> = [
            "--model", "--prompt", "--max-tokens", "--temperature", "--top-p",
            "--memory-budget-mib", "--revision", "--report", "--cancel-after-chunks", "--repeat",
            "--capability", "--width", "--height", "--steps", "--guidance", "--seed",
            "--artifacts", "--cancel-after-steps",
        ]
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--help" || argument == "-h" { return nil }
            let components = argument.split(separator: "=", maxSplits: 1,
                                            omittingEmptySubsequences: false)
            let key = String(components[0])
            guard recognized.contains(key) else { throw CLIArgumentError("Unknown option: \(argument)") }
            guard values[key] == nil else { throw CLIArgumentError("Repeated option: \(key)") }
            if components.count == 2 {
                values[key] = String(components[1])
            } else {
                index += 1
                guard index < arguments.count else { throw CLIArgumentError("Missing value for \(key)") }
                values[key] = arguments[index]
            }
            index += 1
        }
        guard let model = values["--model"], model.hasPrefix("/"), !model.contains("\0") else {
            throw CLIArgumentError("--model must name an absolute local directory.")
        }
        guard let prompt = values["--prompt"] else { throw CLIArgumentError("--prompt is required.") }
        var options = Self(model: model, prompt: prompt)
        guard let capability = CLICapability(rawValue: values["--capability"] ?? "text") else {
            throw CLIArgumentError("--capability must be text or image.")
        }
        options.capability = capability
        let imageFlags = ["--width", "--height", "--steps", "--guidance", "--seed", "--artifacts", "--cancel-after-steps"]
        let textFlags = ["--max-tokens", "--temperature", "--top-p", "--cancel-after-chunks"]
        let inappropriate = capability == .text ? imageFlags : textFlags
        if let key = inappropriate.first(where: { values[$0] != nil }) {
            throw CLIArgumentError("\(key) cannot be used with --capability \(capability.rawValue).")
        }
        if capability == .image { options.memoryBudgetMiB = 8192 }
        func positiveInteger(_ key: String, default fallback: Int) throws -> Int {
            guard let raw = values[key] else { return fallback }
            guard let value = Int(raw), value > 0 else {
                throw CLIArgumentError("\(key) must be a positive integer.")
            }
            return value
        }
        options.maxTokens = try positiveInteger("--max-tokens", default: options.maxTokens)
        options.repeatCount = try positiveInteger("--repeat", default: options.repeatCount)
        if values["--cancel-after-chunks"] != nil {
            options.cancelAfterChunks = try positiveInteger("--cancel-after-chunks", default: 1)
        }
        options.width = try positiveInteger("--width", default: options.width)
        options.height = try positiveInteger("--height", default: options.height)
        options.steps = try positiveInteger("--steps", default: options.steps)
        if values["--cancel-after-steps"] != nil {
            options.cancelAfterSteps = try positiveInteger("--cancel-after-steps", default: 1)
        }
        if let raw = values["--guidance"] {
            guard let value = Float(raw), value.isFinite, value >= 0 else {
                throw CLIArgumentError("--guidance must be finite and >= 0.")
            }
            options.guidance = value
        }
        if let raw = values["--seed"] {
            guard let seed = UInt64(raw) else {
                throw CLIArgumentError("--seed must be an unsigned 64-bit integer.")
            }
            options.seed = seed
        }
        if let raw = values["--temperature"] {
            guard let value = Float(raw), value.isFinite, value >= 0 else {
                throw CLIArgumentError("--temperature must be finite and >= 0.")
            }
            options.temperature = value
        }
        if let raw = values["--top-p"] {
            guard let value = Float(raw), value.isFinite, value > 0, value <= 1 else {
                throw CLIArgumentError("--top-p must be finite, > 0, and <= 1.")
            }
            options.topP = value
        }
        if let raw = values["--memory-budget-mib"] {
            guard let value = UInt64(raw), value > 0, value <= UInt64.max / (1024 * 1024) else {
                throw CLIArgumentError("--memory-budget-mib must be a positive, representable MiB value.")
            }
            options.memoryBudgetMiB = value
        }
        options.revision = values["--revision"]
        options.report = values["--report"]
        if let report = options.report, report.isEmpty || report.contains("\0") {
            throw CLIArgumentError("--report cannot be empty or contain a NUL byte.")
        }
        if capability == .image {
            guard let path = values["--artifacts"], path.hasPrefix("/"), !path.contains("\0") else {
                throw CLIArgumentError("Image mode requires --artifacts as an absolute task directory.")
            }
            let modelURL = URL(fileURLWithPath: model).standardizedFileURL.resolvingSymlinksInPath()
            let artifactURL = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
            guard !contains(modelURL, artifactURL) else {
                throw CLIArgumentError("--artifacts must be outside the read-only model directory.")
            }
            if let report = options.report {
                let reportURL = URL(fileURLWithPath: report).standardizedFileURL.resolvingSymlinksInPath()
                guard !contains(modelURL, reportURL) else {
                    throw CLIArgumentError("--report must be outside the read-only image model directory.")
                }
            }
            options.artifacts = artifactURL.path
        }
        return options
    }

    /// Preserve a requested report destination even when another option is invalid.
    static func reportDestination(in arguments: [String]) -> String? {
        func rawValue(_ key: String) -> String? {
            for (index, argument) in arguments.enumerated() {
                if argument.hasPrefix(key + "=") { return String(argument.dropFirst(key.count + 1)) }
                if argument == key, arguments.indices.contains(index + 1) {
                    return arguments[index + 1]
                }
            }
            return nil
        }
        guard let destination = rawValue("--report"), !destination.isEmpty,
              !destination.contains("\0") else { return nil }
        // Argument-error reports must obey the same read-only model boundary as valid runs.
        if rawValue("--capability") == "image", let model = rawValue("--model") {
            let modelURL = URL(fileURLWithPath: model).standardizedFileURL.resolvingSymlinksInPath()
            let reportURL = URL(fileURLWithPath: destination).standardizedFileURL.resolvingSymlinksInPath()
            if contains(modelURL, reportURL) { return nil }
        }
        return destination
    }

    private static func contains(_ directory: URL, _ item: URL) -> Bool {
        let prefix = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
        return item.path == directory.path || item.path.hasPrefix(prefix)
    }
}

struct CLIArgumentError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
