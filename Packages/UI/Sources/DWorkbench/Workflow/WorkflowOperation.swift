import DInference
import Foundation

public enum WorkflowOperationResult: Sendable, Equatable {
    case outputs([String: WorkflowValue])
    case reviewText(WorkflowAssetReference)
    case choose([WorkflowCandidate])
    case humanTask(WorkflowHumanTask)
}
public struct WorkflowExecutionContext: Sendable {
    public let address: WorkflowExecutionAddress?
    public let graphID: UUID?
    public let node: WorkflowNode
    public let stepID: UUID
    public let inputs: [String: WorkflowValue]
    public let retryCandidates: [WorkflowCandidate]?
    public init(node: WorkflowNode, stepID: UUID, inputs: [String: WorkflowValue], retryCandidates: [WorkflowCandidate]? = nil, address: WorkflowExecutionAddress? = nil, graphID: UUID? = nil) {
        self.address = address; self.graphID = graphID
        self.node = node; self.stepID = stepID; self.inputs = inputs; self.retryCandidates = retryCandidates
    }
}

/// Explicit application services supplied by the project owner; no View or global current page.
@MainActor public protocol WorkflowOperationServices: AnyObject {
    func readData(_ reference: WorkflowAssetReference) async throws -> Data
    func generateLanguage(task: String, content: String?, context: WorkflowExecutionContext) async throws -> WorkflowAssetReference
    func generateMusic(_ request: AudioRequest, parents: [WorkflowAssetReference], context: WorkflowExecutionContext) async throws -> WorkflowAssetReference
    func generateVideo(context: WorkflowExecutionContext) async throws -> WorkflowAssetReference
    func analyzePitch(_ reference: WorkflowAssetReference, context: WorkflowExecutionContext) async throws -> WorkflowAssetReference
    func publishMedia(_ data: Data, mediaType: String, parents: [WorkflowAssetReference], context: WorkflowExecutionContext) async throws -> WorkflowAssetReference
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

/// Older test/host implementations remain explicit about unsupported new services.
extension WorkflowOperationServices {
    public func readData(_ reference: WorkflowAssetReference) async throws -> Data { throw WorkflowIssue("此入口尚未提供媒体读取。") }
    public func generateLanguage(task: String, content: String?, context: WorkflowExecutionContext) async throws -> WorkflowAssetReference { throw WorkflowIssue("此入口尚未提供语言生成。") }
    public func generateMusic(_ request: AudioRequest, parents: [WorkflowAssetReference], context: WorkflowExecutionContext) async throws -> WorkflowAssetReference { throw WorkflowIssue("此入口尚未提供受控音乐生成。") }
    public func generateVideo(context: WorkflowExecutionContext) async throws -> WorkflowAssetReference { throw WorkflowIssue("此入口尚未提供 T2V。") }
    public func analyzePitch(_ reference: WorkflowAssetReference, context: WorkflowExecutionContext) async throws -> WorkflowAssetReference { throw WorkflowIssue("此入口尚未提供音高识别。") }
    public func publishMedia(_ data: Data, mediaType: String, parents: [WorkflowAssetReference], context: WorkflowExecutionContext) async throws -> WorkflowAssetReference { throw WorkflowIssue("此入口尚未提供媒体发布。") }
}
