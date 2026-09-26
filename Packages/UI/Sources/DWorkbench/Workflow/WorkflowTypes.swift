import DInference
import Foundation

public enum WorkflowDataKind: String, Codable, Sendable, CaseIterable { case text, image, images, receipt }
public enum WorkflowScalar: Codable, Sendable, Equatable {
    case text(String), integer(Int), decimal(Double), flag(Bool)
    public var string: String? { if case .text(let v) = self { v } else { nil } }
    public var integer: Int? { if case .integer(let v) = self { v } else { nil } }
    public var decimal: Double? { if case .decimal(let v) = self { v } else { nil } }
    public var flag: Bool? { if case .flag(let v) = self { v } else { nil } }
}

/// Immutable published content; locations remain owned and resolved by ProjectStore.
public struct WorkflowAssetReference: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var id: UUID { assetID }
    public let projectID: UUID
    public let assetID: UUID
    public let version: UUID
    public let kind: WorkflowDataKind
    public let sha256: String
    public init(projectID: UUID, assetID: UUID, version: UUID = UUID(), kind: WorkflowDataKind, sha256: String) {
        self.projectID = projectID; self.assetID = assetID; self.version = version; self.kind = kind; self.sha256 = sha256
    }
}

public struct WorkflowCandidate: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let attemptID: UUID
    public var asset: WorkflowAssetReference?
    public var error: String?
    public let seed: String
    public init(id: UUID = UUID(), attemptID: UUID = UUID(), asset: WorkflowAssetReference? = nil,
                error: String? = nil, seed: String) {
        self.id = id; self.attemptID = attemptID; self.asset = asset; self.error = error; self.seed = seed
    }
}
public struct WorkflowExportReceipt: Codable, Sendable, Equatable {
    public let id: UUID
    public let names: [String]
    public let hashes: [String]
    public let completedAt: Date
    public init(id: UUID, names: [String], hashes: [String], completedAt: Date = Date()) {
        self.id = id; self.names = names; self.hashes = hashes; self.completedAt = completedAt
    }
}
public enum WorkflowValue: Codable, Sendable, Equatable {
    case asset(WorkflowAssetReference), collection([WorkflowCandidate]), receipt(WorkflowExportReceipt)
    public var kind: WorkflowDataKind {
        switch self { case .asset(let a): a.kind; case .collection: .images; case .receipt: .receipt }
    }
    public var asset: WorkflowAssetReference? { if case .asset(let a) = self { a } else { nil } }
    public var candidates: [WorkflowCandidate] { if case .collection(let a) = self { a } else { [] } }
}

/// Values are restricted by the operation's versioned field schema; unknown operations stay read-only.
public struct WorkflowNode: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var operationID: String
    public var definitionVersion: Int
    public var title: String
    public var parameters: [String: WorkflowScalar]
    public var assetReference: WorkflowAssetReference?
    public init(id: UUID = UUID(), operationID: String, definitionVersion: Int = 1, title: String,
                parameters: [String: WorkflowScalar] = [:], assetReference: WorkflowAssetReference? = nil) {
        self.id = id; self.operationID = operationID; self.definitionVersion = definitionVersion
        self.title = title; self.parameters = parameters; self.assetReference = assetReference
    }
}
public struct WorkflowConnection: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var sourceNode: UUID
    public var sourcePort: String
    public var targetNode: UUID
    public var targetPort: String
    public init(id: UUID = UUID(), sourceNode: UUID, sourcePort: String = "output", targetNode: UUID, targetPort: String = "input") {
        self.id = id; self.sourceNode = sourceNode; self.sourcePort = sourcePort; self.targetNode = targetNode; self.targetPort = targetPort
    }
}
public struct WorkflowLayout: Codable, Sendable, Equatable {
    public var nodeID: UUID
    public var x: Double
    public var y: Double
    public var collapsed: Bool
    public init(nodeID: UUID, x: Double, y: Double, collapsed: Bool = false) {
        self.nodeID = nodeID; self.x = x; self.y = y; self.collapsed = collapsed
    }
}
public struct WorkflowGraph: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var revision: UUID
    public var name: String
    public var nodes: [WorkflowNode]
    public var connections: [WorkflowConnection]
    public var layout: [WorkflowLayout]
    public init(id: UUID = UUID(), revision: UUID = UUID(), name: String = "新流程", nodes: [WorkflowNode] = [],
                connections: [WorkflowConnection] = [], layout: [WorkflowLayout] = []) {
        self.id = id; self.revision = revision; self.name = name; self.nodes = nodes; self.connections = connections; self.layout = layout
    }
}
public enum WorkflowStepStatus: String, Codable, Sendable {
    case queued, running, waiting, completed, partial, failed, cancelling, cancelled, interrupted, rejected, saving
    public var title: String {
        switch self {
        case .queued: "等待输入"; case .running: "运行中"; case .waiting: "等待确认"; case .completed: "已完成"
        case .partial: "部分完成"; case .failed: "失败"; case .cancelling: "正在取消"; case .cancelled: "已取消"
        case .interrupted: "已中断"; case .rejected: "已拒绝"; case .saving: "等待保存恢复"
        }
    }
}
public struct WorkflowDecision: Codable, Sendable, Equatable {
    public let id: UUID
    public let waitingStepID: UUID
    public let accepted: Bool
    public let selectedCandidateID: UUID?
    public let output: WorkflowAssetReference?
    public init(id: UUID = UUID(), waitingStepID: UUID, accepted: Bool, selectedCandidateID: UUID? = nil, output: WorkflowAssetReference? = nil) {
        self.id = id; self.waitingStepID = waitingStepID; self.accepted = accepted
        self.selectedCandidateID = selectedCandidateID; self.output = output
    }
}
public struct WorkflowStepRun: Codable, Sendable, Equatable, Identifiable {
    /// Human edits at a waiting gate are durable drafts, never an implicit decision.
    public var reviewTextDraft: String?
    public var repeatRequested: Bool?
    public var inputsBound: Bool?
    public var id: UUID
    public var node: WorkflowNode
    public var signature: String
    public var inputs: [String: WorkflowValue]
    public var outputs: [String: WorkflowValue]
    public var status: WorkflowStepStatus
    public var error: String?
    public var decision: WorkflowDecision?
    public init(id: UUID = UUID(), node: WorkflowNode, signature: String, inputs: [String: WorkflowValue] = [:],
                outputs: [String: WorkflowValue] = [:], status: WorkflowStepStatus = .queued) {
        self.id = id; self.node = node; self.signature = signature; self.inputs = inputs; self.outputs = outputs; self.status = status
    }
}
public struct WorkflowRun: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var graph: WorkflowGraph
    public var targetNodeID: UUID
    public var steps: [WorkflowStepRun]
    public var status: WorkflowStepStatus
    public var createdAt: Date
    public init(id: UUID = UUID(), graph: WorkflowGraph, targetNodeID: UUID, steps: [WorkflowStepRun] = [], status: WorkflowStepStatus = .queued) {
        self.id = id; self.graph = graph; self.targetNodeID = targetNodeID; self.steps = steps; self.status = status; self.createdAt = Date()
    }
}
public struct WorkflowAssetRecord: Codable, Sendable, Equatable {
    public var reference: WorkflowAssetReference
    public var parents: [WorkflowAssetReference]
    public var operationID: String
    public var stepID: UUID?
    public var request: InferenceRequest?
    public var metadata: [String: String]
    public init(reference: WorkflowAssetReference, parents: [WorkflowAssetReference] = [], operationID: String,
                stepID: UUID? = nil, request: InferenceRequest? = nil, metadata: [String: String] = [:]) {
        self.reference = reference; self.parents = parents; self.operationID = operationID
        self.stepID = stepID; self.request = request; self.metadata = metadata
    }
}
public struct WorkflowArchive: Codable, Sendable, Equatable {
    public var version = 1
    public var revision: UUID
    public var graphs: [WorkflowGraph]
    public var runs: [WorkflowRun]
    public var assets: [WorkflowAssetRecord]
    public init(revision: UUID = UUID(), graphs: [WorkflowGraph] = [], runs: [WorkflowRun] = [], assets: [WorkflowAssetRecord] = []) {
        self.revision = revision; self.graphs = graphs; self.runs = runs; self.assets = assets
    }
}
public struct WorkflowSnapshotPointer: Codable, Sendable, Equatable {
    public let generation: UUID
    public let byteCount: Int
    public let sha256: String
    public var relativePath: String { "Workflows/\(generation.uuidString).json" }
    public init(generation: UUID, byteCount: Int, sha256: String) { self.generation = generation; self.byteCount = byteCount; self.sha256 = sha256 }
}
public struct WorkflowIssue: Error, LocalizedError, Codable, Sendable, Equatable {
    public var nodeID: UUID?
    public var port: String?
    public var reason: String
    public init(_ reason: String, nodeID: UUID? = nil, port: String? = nil) { self.reason = reason; self.nodeID = nodeID; self.port = port }
    public var errorDescription: String? { [port.map { "端口 \($0)" }, reason].compactMap { $0 }.joined(separator: "：") }
}

public struct WorkflowPortDefinition: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let kinds: [WorkflowDataKind]
    public let required: Bool
    public init(_ id: String, _ title: String, kinds: [WorkflowDataKind], required: Bool = true) {
        self.id = id; self.title = title; self.kinds = kinds; self.required = required
    }
}
public enum WorkflowFieldKind: Sendable, Equatable { case text(multiline: Bool), integer, decimal, flag, choice([String]) }
public struct WorkflowFieldDefinition: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let kind: WorkflowFieldKind
    public let defaultValue: WorkflowScalar
    public init(_ id: String, _ title: String, _ kind: WorkflowFieldKind, _ defaultValue: WorkflowScalar) {
        self.id = id; self.title = title; self.kind = kind; self.defaultValue = defaultValue
    }
}
public enum WorkflowInteraction: Sendable, Equatable { case none, assetInput, textReview, candidateReview }
public struct WorkflowOperationDefinition: Sendable, Equatable, Identifiable {
    public var id: String
    public var version: Int
    public var title: String
    public var detail: String
    public var inputs: [WorkflowPortDefinition]
    public var outputs: [WorkflowPortDefinition]
    public var fields: [WorkflowFieldDefinition]
    public var modelKind: WorkflowModelKind?
    public var interaction: WorkflowInteraction
    public init(id: String, version: Int = 1, title: String, detail: String, inputs: [WorkflowPortDefinition],
                outputs: [WorkflowPortDefinition], fields: [WorkflowFieldDefinition] = [], modelKind: WorkflowModelKind? = nil, interaction: WorkflowInteraction = .none) {
        self.id = id; self.version = version; self.title = title; self.detail = detail
        self.inputs = inputs; self.outputs = outputs; self.fields = fields; self.modelKind = modelKind; self.interaction = interaction
    }
    public func makeNode() -> WorkflowNode {
        WorkflowNode(operationID: id, definitionVersion: version, title: title,
                     parameters: Dictionary(uniqueKeysWithValues: fields.map { ($0.id, $0.defaultValue) }))
    }
}
