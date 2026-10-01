import DInference
import Foundation

/// Application model selection, not a graph node identity or a model installation.
public enum WorkflowModelKind: String, Sendable, Codable, CaseIterable { case text, image, music, video, pitch }
public struct WorkflowModelChoice: Identifiable, Sendable, Equatable {
    public let id: String
    public let kind: WorkflowModelKind
    public let displayName: String
    public init(id: String, kind: WorkflowModelKind, displayName: String) {
        self.id = id; self.kind = kind; self.displayName = displayName
    }
}

/// The selected adapter supplies its request recipe. Generic services do not guess a
/// reference profile from a visible page or another model's capability.
public struct WorkflowImageRecipe: Sendable {
    private let make: @Sendable (WorkflowNode, String, UInt64, [ImageReference]) throws -> ImageRequest
    /// Compatibility for existing one-image adapters. Never silently drops extra references.
    public init(make: @escaping @Sendable (WorkflowNode, String, UInt64, ImageReference?) throws -> ImageRequest) {
        self.make = { node, prompt, seed, references in
            guard references.count <= 1 else { throw WorkflowIssue("此旧实现只接受单张参考图；不会丢弃其余输入。") }
            return try make(node, prompt, seed, references.first)
        }
    }
    public init(ordered: @escaping @Sendable (WorkflowNode, String, UInt64, [ImageReference]) throws -> ImageRequest) { make = ordered }
    public func request(node: WorkflowNode, prompt: String, seed: UInt64, reference: ImageReference?) throws -> ImageRequest {
        try make(node, prompt, seed, reference.map { [$0] } ?? [])
    }
    public func request(node: WorkflowNode, prompt: String, seed: UInt64, references: [ImageReference]) throws -> ImageRequest {
        try make(node, prompt, seed, references)
    }
    public static func klein(capability: ImageExecutionCapability) -> Self { flux(capability: capability, dev: false) }
    public static func fluxDev(capability: ImageExecutionCapability) -> Self { flux(capability: capability, dev: true) }
    private static func flux(capability: ImageExecutionCapability, dev: Bool) -> Self {
        Self(ordered: { node, prompt, seed, references in
            let p = node.parameters
            let rawLoading = p["loadingStrategy"]?.string ?? "staged"
            guard let loading = ImageLoadingStrategy(rawValue: rawLoading), !dev || loading == .staged else {
                throw WorkflowIssue("所选图像实现不支持此加载方式。")
            }
            let value = ImageRequest(prompt: prompt, width: p["width"]?.integer ?? 512,
                height: p["height"]?.integer ?? 512, steps: p["steps"]?.integer ?? (dev ? 50 : 4),
                guidanceScale: Float(p["guidance"]?.decimal ?? (dev ? 4 : 1)), seed: seed,
                executionProfile: dev || references.isEmpty ? capability.profile : ImageExecutionCapability.referenceKlein4B.profile,
                referenceImages: references.isEmpty ? nil : references, loadingStrategy: loading)
            try capability.validate(value)
            return value
        })
    }
}

/// Static App injection for installed implementations. No discovery, download or model load.
/// Identity is a fixed model-resource revision, operationID is the shared Quick/Canvas contract.
public struct WorkflowModelAdapter: Sendable {
    public let kind: WorkflowModelKind
    public let modelRevision: String
    public var identity: String { kind.rawValue + ":" + modelRevision }
    public let operationID: String
    public let title: String
    public let backendID: String
    public let textCapability: TextExecutionCapability?
    public let imageRecipe: WorkflowImageRecipe?
    public let validateModel: @Sendable (URL) async throws -> ModelReference
    public init(kind: WorkflowModelKind, modelRevision: String, operationID: String, title: String,
                backendID: String, textCapability: TextExecutionCapability? = nil, imageRecipe: WorkflowImageRecipe? = nil,
                validateModel: @escaping @Sendable (URL) async throws -> ModelReference) {
        self.kind = kind; self.modelRevision = modelRevision; self.operationID = operationID
        self.title = title; self.backendID = backendID; self.textCapability = textCapability
        self.imageRecipe = imageRecipe; self.validateModel = validateModel
    }
}

@MainActor public struct WorkflowModelBinding {
    public let identity: String
    public let reference: ModelReference
    public let backendID: String
    public let operationID: String?
    public let textCapability: TextExecutionCapability?
    public let imageRecipe: WorkflowImageRecipe?
    public let videoRecipe: WorkflowVideoRecipe?
    public let release: @MainActor () async -> Void
    public init(identity: String, reference: ModelReference, backendID: String,
                operationID: String? = nil, textCapability: TextExecutionCapability? = nil,
                imageRecipe: WorkflowImageRecipe? = nil,
                videoRecipe: WorkflowVideoRecipe? = nil,
                release: @escaping @MainActor () async -> Void = {}) {
        self.identity = identity; self.reference = reference; self.backendID = backendID
        self.operationID = operationID; self.textCapability = textCapability
        self.imageRecipe = imageRecipe; self.videoRecipe = videoRecipe; self.release = release
    }
}
