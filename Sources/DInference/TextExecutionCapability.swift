import Foundation

/// The currently adapted local Qwen2 text execution contract.
/// Model installation and machine admission remain separate host concerns.
public struct TextExecutionCapability: Codable, Equatable, Sendable {
    public static let qwen2Profile = ExecutionProfileReference(identifier: "qwen2-text", revision: 1)

    public let profile: ExecutionProfileReference
    public let maximumPromptTokens: Int
    public let maximumOutputTokens: Int
    public let contract: ExecutionContractDescription

    public init(maximumPromptTokens: Int, maximumOutputTokens: Int) {
        profile = Self.qwen2Profile
        self.maximumPromptTokens = maximumPromptTokens
        self.maximumOutputTokens = maximumOutputTokens
        contract = ExecutionContractDescription(
            operationID: "text.generate",
            inputRoles: [.prompt],
            outputRole: .text,
            controlFidelity: .approximate)
    }

    public func validate(_ request: TextRequest) throws {
        _ = try resolve(request)
    }

    /// Resolves the immutable per-request prompt budget. Legacy requests without a
    /// selection retain the capability's host-configured prompt limit.
    public func resolvedPromptTokens(for request: TextRequest) throws -> Int {
        try resolve(request)
    }

    private func resolve(_ request: TextRequest) throws -> Int {
        guard (1...32768).contains(maximumPromptTokens),
              (1...8192).contains(maximumOutputTokens) else {
            throw InferenceFailure.invalidRequest("Invalid text execution capability limits.")
        }
        guard request.maxTokens > 0, request.maxTokens <= maximumOutputTokens,
              request.temperature.isFinite, request.temperature >= 0,
              request.topP.isFinite, request.topP > 0, request.topP <= 1 else {
            throw InferenceFailure.invalidRequest("Text request exceeds the selected execution capability.")
        }
        guard let selection = request.execution else { return maximumPromptTokens }
        guard selection.profile == profile else {
            throw InferenceFailure.invalidRequest(
                "Unsupported text execution profile \(selection.profile.identifier) revision \(selection.profile.revision).")
        }
        guard selection.maximumPromptTokens > 0,
              selection.maximumPromptTokens <= maximumPromptTokens else {
            throw InferenceFailure.invalidRequest("Invalid per-request prompt token limit.")
        }
        return selection.maximumPromptTokens
    }
}
