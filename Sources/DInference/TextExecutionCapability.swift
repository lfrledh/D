import Foundation

/// The currently adapted local Qwen2 text execution contract.
/// Model installation and machine admission remain separate host concerns.
public struct TextExecutionCapability: Codable, Equatable, Sendable {
    public static let qwen2Profile = ExecutionProfileReference(identifier: "qwen2-text", revision: 1)
    public static let qwen35VLMProfile = ExecutionProfileReference(identifier: "qwen35-vlm", revision: 1)

    public let profile: ExecutionProfileReference
    public let maximumPromptTokens: Int
    public let maximumOutputTokens: Int
    public let contract: ExecutionContractDescription

    public init(maximumPromptTokens: Int, maximumOutputTokens: Int,
                profile: ExecutionProfileReference = Self.qwen2Profile) {
        self.profile = profile
        self.maximumPromptTokens = maximumPromptTokens
        self.maximumOutputTokens = maximumOutputTokens
        contract = ExecutionContractDescription(
            operationID: "text.generate",
            inputRoles: profile == Self.qwen35VLMProfile ? [.prompt, .image, .video] : [.prompt],
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
        try request.validateConversation()
        guard profile == Self.qwen2Profile || profile == Self.qwen35VLMProfile else {
            throw InferenceFailure.invalidRequest("Unsupported text execution capability profile.")
        }
        let ceiling = profile == Self.qwen35VLMProfile ? 262_144 : 32_768
        let outputCeiling = profile == Self.qwen35VLMProfile ? 262_144 : 8_192
        guard (1...ceiling).contains(maximumPromptTokens),
              (1...outputCeiling).contains(maximumOutputTokens) else {
            throw InferenceFailure.invalidRequest("Invalid text execution capability limits.")
        }
        if profile == Self.qwen2Profile &&
            (request.hasVisualInput || request.messages != nil || request.tools != nil ||
             request.thinking != nil || request.seed != nil || request.loadingStrategy == .ssdLayered) {
            throw InferenceFailure.invalidRequest("The selected text profile does not accept conversation, visual or Qwen controls.")
        }
        if profile == Self.qwen35VLMProfile {
            if request.visualProcessing != nil, request.allImages.isEmpty, request.allVideos.isEmpty {
                throw InferenceFailure.invalidRequest("Visual processing requires an image or video source.")
            }
            if request.images != nil && request.images!.isEmpty {
                throw InferenceFailure.invalidRequest("Supplied images cannot be empty.")
            }
            for image in request.allImages { try image.validate() }
            for video in request.allVideos { try video.validate() }
            try request.visualProcessing?.validate()
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
