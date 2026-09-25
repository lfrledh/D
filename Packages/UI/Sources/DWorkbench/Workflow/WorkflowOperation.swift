import Foundation

public enum WorkflowOperationResult: Sendable, Equatable {
    case outputs([String: WorkflowValue])
    case reviewText(WorkflowAssetReference)
    case choose([WorkflowCandidate])
}
public struct WorkflowExecutionContext: Sendable {
    public let node: WorkflowNode
    public let stepID: UUID
    public let inputs: [String: WorkflowValue]
    public let retryCandidates: [WorkflowCandidate]?
    public init(node: WorkflowNode, stepID: UUID, inputs: [String: WorkflowValue], retryCandidates: [WorkflowCandidate]? = nil) {
        self.node = node; self.stepID = stepID; self.inputs = inputs; self.retryCandidates = retryCandidates
    }
}

/// Explicit application services supplied by the project owner; no View or global current page.
@MainActor public protocol WorkflowOperationServices: AnyObject {
    func readText(_ reference: WorkflowAssetReference) async throws -> String
    func verifyAsset(_ reference: WorkflowAssetReference) async throws
    func publishText(_ text: String, parents: [WorkflowAssetReference], context: WorkflowExecutionContext) async throws -> WorkflowAssetReference
    func rewriteText(_ text: String, parents: [WorkflowAssetReference], context: WorkflowExecutionContext) async throws -> WorkflowAssetReference
    func generateImages(prompt: String, reference: WorkflowAssetReference?, context: WorkflowExecutionContext) async throws -> [WorkflowCandidate]
    func transformImage(_ reference: WorkflowAssetReference, context: WorkflowExecutionContext) async throws -> WorkflowAssetReference
    func export(_ value: WorkflowValue, context: WorkflowExecutionContext) async throws -> WorkflowExportReceipt
}

public struct WorkflowOperation: Sendable {
    public let definition: WorkflowOperationDefinition
    public let validate: @Sendable (WorkflowNode) throws -> Void
    public let execute: @MainActor @Sendable (WorkflowExecutionContext, any WorkflowOperationServices) async throws -> WorkflowOperationResult
    public init(definition: WorkflowOperationDefinition,
                validate: @escaping @Sendable (WorkflowNode) throws -> Void = { _ in },
                execute: @escaping @MainActor @Sendable (WorkflowExecutionContext, any WorkflowOperationServices) async throws -> WorkflowOperationResult) {
        self.definition = definition; self.validate = validate; self.execute = execute
    }
}
