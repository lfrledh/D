import DInference
import Foundation

/// Application model selection, not a graph node identity or a model installation.
public enum WorkflowModelKind: String, Sendable, Codable { case text, image }
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
    private let make: @Sendable (WorkflowNode, String, UInt64, ImageReference?) throws -> ImageRequest
    public init(make: @escaping @Sendable (WorkflowNode, String, UInt64, ImageReference?) throws -> ImageRequest) { self.make = make }
    public func request(node: WorkflowNode, prompt: String, seed: UInt64, reference: ImageReference?) throws -> ImageRequest {
        try make(node, prompt, seed, reference)
    }
    public static func klein(capability: ImageExecutionCapability) -> Self {
        Self { node, prompt, seed, reference in
            let p = node.parameters
            let value = ImageRequest(prompt: prompt, width: p["width"]?.integer ?? 512,
                height: p["height"]?.integer ?? 512, steps: p["steps"]?.integer ?? 4,
                guidanceScale: Float(p["guidance"]?.decimal ?? 1), seed: seed,
                executionProfile: reference == nil ? capability.profile : ImageExecutionCapability.referenceKlein4B.profile,
                referenceImage: reference)
            try capability.validate(value)
            return value
        }
    }
}

@MainActor public struct WorkflowModelBinding {
    public let identity: String
    public let reference: ModelReference
    public let backendID: String
    public let imageRecipe: WorkflowImageRecipe?
    public let release: @MainActor () async -> Void
    public init(identity: String, reference: ModelReference, backendID: String,
                imageRecipe: WorkflowImageRecipe? = nil,
                release: @escaping @MainActor () async -> Void = {}) {
        self.identity = identity; self.reference = reference; self.backendID = backendID
        self.imageRecipe = imageRecipe; self.release = release
    }
}
