import Foundation

public struct WorkflowNamedOutput: Codable, Sendable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    public var nodeID: UUID
    public var port: String
    public var schema: WorkflowDataSchema
    public init(name: String, nodeID: UUID, port: String = "output", schema: WorkflowDataSchema) {
        self.name = name; self.nodeID = nodeID; self.port = port; self.schema = schema
    }
}
public struct WorkflowGraphInterface: Codable, Sendable, Equatable {
    public var inputs: [WorkflowRecordField]
    public var outputs: [WorkflowNamedOutput]
    public init(inputs: [WorkflowRecordField] = [], outputs: [WorkflowNamedOutput] = []) { self.inputs = inputs; self.outputs = outputs }
}
public struct WorkflowToolReference: Codable, Sendable, Equatable, Hashable {
    public var id: UUID
    public var version: Int
    public var digest: String
    public init(id: UUID, version: Int, digest: String) { self.id = id; self.version = version; self.digest = digest }
}
public struct WorkflowToolDefinition: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var version: Int
    public var name: String
    public var graph: WorkflowGraph
    public var isOfficial: Bool
    public init(id: UUID = UUID(), version: Int = 1, name: String, graph: WorkflowGraph, isOfficial: Bool = false) {
        self.id = id; self.version = version; self.name = name; self.graph = graph; self.isOfficial = isOfficial
    }
}
public indirect enum WorkflowControlBlock: Codable, Sendable, Equatable {
    case branch(predicate: WorkflowDataRule, then: WorkflowGraph, otherwise: WorkflowGraph)
    case map(body: WorkflowGraph, continueOnFailure: Bool)
    case loop(body: WorkflowGraph, stateSchema: WorkflowDataSchema, maximumIterations: Int, until: WorkflowDataRule)
    case invoke(WorkflowToolReference)
}

public enum WorkflowEffect: String, Codable, Sendable { case pure, assetPublication, inference, human, externalExport }
public struct WorkflowPlanInput: Codable, Sendable, Equatable {
    public var port: String
    public var sourceNode: UUID
    public var sourcePort: String
    public init(port: String, sourceNode: UUID, sourcePort: String = "output") {
        self.port = port; self.sourceNode = sourceNode; self.sourcePort = sourcePort
    }
}
public indirect enum WorkflowPlanStepKind: Codable, Sendable, Equatable {
    case call
    case branch(predicate: WorkflowDataRule, then: WorkflowPlan, otherwise: WorkflowPlan)
    case map(body: WorkflowPlan, continueOnFailure: Bool)
    case loop(body: WorkflowPlan, stateSchema: WorkflowDataSchema, maximumIterations: Int, until: WorkflowDataRule)
    case invoke(reference: WorkflowToolReference, body: WorkflowPlan)
}
public struct WorkflowPlannedStep: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID { node.id }
    public var node: WorkflowNode
    public var inputs: [WorkflowPlanInput]
    public var kind: WorkflowPlanStepKind
    public var effect: WorkflowEffect
    public init(node: WorkflowNode, inputs: [WorkflowPlanInput], kind: WorkflowPlanStepKind = .call, effect: WorkflowEffect = .pure) {
        self.node = node; self.inputs = inputs; self.kind = kind; self.effect = effect
    }
}
/// Frozen data-only IR; App and headless entry use this exact representation/interpreter.
public struct WorkflowPlan: Codable, Sendable, Equatable {
    public var version: Int = 1
    public var graphID: UUID
    public var graphRevision: UUID
    public var steps: [WorkflowPlannedStep]
    public var interface: WorkflowGraphInterface
    public init(graphID: UUID, graphRevision: UUID, steps: [WorkflowPlannedStep], interface: WorkflowGraphInterface = .init()) {
        self.graphID = graphID; self.graphRevision = graphRevision; self.steps = steps; self.interface = interface
    }
}
public enum WorkflowAddressComponent: Codable, Sendable, Equatable, Hashable {
    case node(UUID), branch(Bool), item(String), iteration(Int), tool(WorkflowToolReference)
}
public struct WorkflowExecutionAddress: Codable, Sendable, Equatable, Hashable {
    public var runID: UUID
    public var path: [WorkflowAddressComponent]
    public init(runID: UUID, path: [WorkflowAddressComponent] = []) { self.runID = runID; self.path = path }
    public func appending(_ component: WorkflowAddressComponent) -> Self { .init(runID: runID, path: path + [component]) }
}
public enum WorkflowLoopExit: String, Codable, Sendable { case conditionMet, iterationLimit, failed, cancelled }
public struct WorkflowPlanCallRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID { step.id }
    public var address: WorkflowExecutionAddress
    public var step: WorkflowStepRun
    public var loopExit: WorkflowLoopExit?
    public init(address: WorkflowExecutionAddress, step: WorkflowStepRun, loopExit: WorkflowLoopExit? = nil) {
        self.address = address; self.step = step; self.loopExit = loopExit
    }
}
public enum WorkflowPlanState: String, Codable, Sendable { case ready, running, paused, waiting, completed, failed, cancelled, saving, interrupted }
public struct WorkflowPlanCheckpoint: Codable, Sendable, Equatable {
    public var runID: UUID
    public var plan: WorkflowPlan
    public var arguments: [String: WorkflowDatum]
    public var records: [WorkflowPlanCallRecord]
    public var state: WorkflowPlanState
    public var outputs: [String: WorkflowValue]
    public var externalInputs: [UUID: [String: WorkflowValue]] = [:]
    public var error: String?
    public init(runID: UUID = UUID(), plan: WorkflowPlan, arguments: [String: WorkflowDatum] = [:], records: [WorkflowPlanCallRecord] = [],
                state: WorkflowPlanState = .ready, outputs: [String: WorkflowValue] = [:]) {
        self.runID = runID; self.plan = plan; self.arguments = arguments; self.records = records; self.state = state; self.outputs = outputs
    }
}
public enum WorkflowHumanTaskKind: String, Codable, Sendable, CaseIterable { case editText, singleChoice, multipleChoice, approve, editMusic }
public struct WorkflowHumanTask: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var kind: WorkflowHumanTaskKind
    public var title: String
    public var materials: WorkflowDatum
    public var resultSchema: WorkflowDataSchema
    public var draft: WorkflowDatum?
    public var decision: WorkflowDatum?
    public var rejected: Bool
    public init(id: UUID, kind: WorkflowHumanTaskKind, title: String, materials: WorkflowDatum, resultSchema: WorkflowDataSchema) {
        self.id = id; self.kind = kind; self.title = title; self.materials = materials; self.resultSchema = resultSchema; self.rejected = false
    }
}
