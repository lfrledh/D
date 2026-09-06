import Foundation

struct CLIOptions: Sendable, Codable {
    var model: String
    var prompt: String
    var maxTokens: Int = 64
    var temperature: Float = 0
    var topP: Float = 0.95
    var memoryBudgetMiB: UInt64 = 2048
    var revision: String?
    var report: String?
    var cancelAfterChunks: Int?
    var repeatCount: Int = 1

    var memoryBudgetBytes: UInt64 { memoryBudgetMiB * 1024 * 1024 }

    static let usage = """
    Usage: d-infer --model ABSOLUTE_PATH --prompt TEXT [options]

    Runs a local MLX text model; does not download models.
      --model PATH                 Absolute local model directory (required)
      --prompt TEXT                Prompt, including an empty string (required)
      --max-tokens N               Maximum generated tokens (default: 64)
      --temperature FLOAT          Sampling temperature >= 0 (default: 0)
      --top-p FLOAT                Nucleus sampling, 0 < value <= 1 (default: 0.95)
      --memory-budget-mib N        Runtime admission budget (default: 2048)
      --revision STRING           Model revision recorded as provenance
      --report PATH               Atomically write a JSON execution report
      --cancel-after-chunks N      Request cancellation after N text chunks
      --repeat N                  Sequential runs in this process (default: 1)
      --help, -h                  Show help without initializing the backend

    Generated text goes to stdout; diagnostics go to stderr.
    Exit status: 0 completed; 1 execution/report failure; 2 invalid arguments;
    130 cancelled. The memory budget is an estimate-based admission limit.
    """

    /// A nil result means help was requested. Values may also use --option=value.
    static func parse(_ arguments: [String]) throws -> Self? {
        let recognized: Set<String> = [
            "--model", "--prompt", "--max-tokens", "--temperature", "--top-p",
            "--memory-budget-mib", "--revision", "--report", "--cancel-after-chunks", "--repeat",
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
        guard let model = values["--model"], model.hasPrefix("/") else {
            throw CLIArgumentError("--model must name an absolute local directory.")
        }
        guard let prompt = values["--prompt"] else { throw CLIArgumentError("--prompt is required.") }
        var options = Self(model: model, prompt: prompt)
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
        if options.report?.isEmpty == true { throw CLIArgumentError("--report cannot be empty.") }
        return options
    }

    /// Preserve a requested report destination even when another option is invalid.
    static func reportDestination(in arguments: [String]) -> String? {
        for (index, argument) in arguments.enumerated() {
            if argument.hasPrefix("--report=") { return String(argument.dropFirst("--report=".count)) }
            if argument == "--report", arguments.indices.contains(index + 1) {
                return arguments[index + 1]
            }
        }
        return nil
    }
}

struct CLIArgumentError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
