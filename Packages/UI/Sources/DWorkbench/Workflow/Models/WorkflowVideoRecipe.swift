import DInference
import Foundation

/// A frozen adapter recipe, not a display-card parser or the visible page's state.
public struct WorkflowVideoRecipe: Sendable {
    public let profile: ExternalVideoExecutionProfile
    public var operationID: String { "d.video." + profile.rawValue }
    public init(profile: ExternalVideoExecutionProfile) { self.profile = profile }

    public func request(node: WorkflowNode, prompt: String, seed: UInt64) throws -> VideoRequest {
        let p = node.parameters
        guard let width = p["width"]?.integer, let height = p["height"]?.integer,
              let frames = p["frameCount"]?.integer, let steps = p["steps"]?.integer,
              let fps = p["frameRate"]?.integer, let numerator = Int32(exactly: fps),
              let stream = p["streamWeights"]?.flag,
              let guidance = p["guidance"]?.decimal else {
            throw WorkflowIssue("视频节点缺少此模型的明确参数；不会改用另一配方。")
        }
        let options: VideoAdapterOptions
        if profile == .h3BF16Full {
            options = .h3(streamWeights: stream)
        } else {
            guard let stg = p["stg"]?.decimal else { throw WorkflowIssue("LTX 缺少 STG 参数。") }
            options = .ltx(streamWeights: stream, spatiotemporalGuidance: Float(stg))
        }
        let request = VideoRequest(prompt: prompt, negativePrompt: p["negativePrompt"]?.string ?? "",
            width: width, height: height, frameCount: frames, frameRate: .init(numerator: numerator),
            steps: steps, guidanceScale: Float(guidance), scheduleShift: 1, seed: seed,
            executionProfile: profile.reference, adapterOptions: options)
        try profile.validate(request)
        return request
    }
}

/// Static App registration of an existing operation implementation. Registration
/// does not load weights; a retained model-location lease covers the complete pack.
public struct WorkflowVideoAdapter: Sendable {
    public let profile: ExternalVideoExecutionProfile
    public let backendID: String
    public let modelIdentity: String
    public let validateModel: @Sendable (URL) async throws -> ModelReference
    public init(profile: ExternalVideoExecutionProfile, backendID: String, modelIdentity: String,
                validateModel: @escaping @Sendable (URL) async throws -> ModelReference) {
        self.profile = profile; self.backendID = backendID; self.modelIdentity = modelIdentity
        self.validateModel = validateModel
    }
}
