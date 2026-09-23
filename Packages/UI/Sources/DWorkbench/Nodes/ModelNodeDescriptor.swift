import Foundation

/// Descriptive UI projection of reviewed adapter contracts, not an executable registry.
/// These strings must never be parsed to validate or submit inference requests.
public struct ModelNodeDescriptor: Identifiable, Equatable, Sendable {
    public let id: String
    public let modality: CreatorMode
    public let title: String
    public let summary: String
    public let modelIdentity: String
    public let revision: String
    public let engine: String
    public let device: String
    public let precision: String
    public let availability: ModelNodeAvailability
    public let deploymentNote: String
    public let operations: [ModelNodeOperation]
    public let notes: [String]
    public let evidencePaths: [String]
    public init(id: String, modality: CreatorMode, title: String, summary: String,
                modelIdentity: String, revision: String, engine: String, device: String,
                precision: String, availability: ModelNodeAvailability, deploymentNote: String,
                operations: [ModelNodeOperation], notes: [String], evidencePaths: [String]) {
        self.id = id; self.modality = modality; self.title = title; self.summary = summary
        self.modelIdentity = modelIdentity; self.revision = revision; self.engine = engine
        self.device = device; self.precision = precision; self.availability = availability
        self.deploymentNote = deploymentNote; self.operations = operations; self.notes = notes
        self.evidencePaths = evidencePaths
    }
}
public enum ModelNodeAvailability: String, Equatable, Sendable {
    case workbench, backend, evaluation
    public var title: String {
        switch self { case .workbench: "已有工作台入口"; case .backend: "后端／命令行"; case .evaluation: "适配待完整验证" }
    }
}
public struct ModelNodeOperation: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let summary: String
    public let inputs: [ModelNodePort]
    public let outputs: [ModelNodePort]
    public let parameters: [ModelNodeParameter]
    public init(id: String, title: String, summary: String, inputs: [ModelNodePort],
                outputs: [ModelNodePort], parameters: [ModelNodeParameter]) {
        self.id = id; self.title = title; self.summary = summary
        self.inputs = inputs; self.outputs = outputs; self.parameters = parameters
    }
}
public enum ModelNodePortRequirement: Equatable, Sendable {
    case required, optional, conditional(String)
    public var title: String {
        switch self { case .required: "必选"; case .optional: "可选"; case .conditional: "条件必选" }
    }
    public var condition: String? {
        if case .conditional(let value) = self { return value }; return nil
    }
}
public struct ModelNodePort: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let dataType: String
    public let requirement: ModelNodePortRequirement
    public let detail: String
    public init(id: String, title: String, dataType: String, requirement: ModelNodePortRequirement, detail: String) {
        self.id = id; self.title = title; self.dataType = dataType; self.requirement = requirement; self.detail = detail
    }
}
public struct ModelNodeParameter: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let defaultValue: String
    public let acceptedValues: String
    public let detail: String
    public let isAdjustable: Bool
    public init(id: String, title: String, defaultValue: String, acceptedValues: String,
                detail: String, isAdjustable: Bool) {
        self.id = id; self.title = title; self.defaultValue = defaultValue
        self.acceptedValues = acceptedValues; self.detail = detail; self.isAdjustable = isAdjustable
    }
}
