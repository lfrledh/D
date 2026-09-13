import Foundation

/// Identifies an implemented execution contract, independently of model revision or installation.
/// Unknown identities remain decodable for history; execution must reject unsupported versions.
public struct ExecutionProfileReference: Codable, Hashable, Sendable {
    public let identifier: String
    public let revision: Int
    public init(identifier: String, revision: Int = 1) {
        self.identifier = identifier
        self.revision = revision
    }
}

/// Per-request input budget. Output budget remains TextRequest.maxTokens.
/// A nil selection in a legacy request retains that caller's immutable host configuration.
public struct TextExecutionSelection: Codable, Equatable, Sendable {
    public let profile: ExecutionProfileReference
    public let maximumPromptTokens: Int
    public init(profile: ExecutionProfileReference, maximumPromptTokens: Int) {
        self.profile = profile
        self.maximumPromptTokens = maximumPromptTokens
    }
}

/// Describes control semantics, not a promise of aesthetic quality or model accuracy.
public enum ExecutionControlFidelity: String, Codable, Sendable {
    case exact, approximate, unsupported, unknown
}

public enum ExecutionDataRole: String, Codable, Sendable {
    case prompt, referenceAudio, noteSequence, text, image, audio
}

/// Small semantic descriptor shared by native presentations and adapters.
/// Range/combination rules remain modality-specific typed values.
public struct ExecutionContractDescription: Codable, Equatable, Sendable {
    public let operationID: String
    public let revision: Int
    public let inputRoles: [ExecutionDataRole]
    public let outputRole: ExecutionDataRole
    public let controlFidelity: ExecutionControlFidelity
    public let cancellation: Cancellation
    public enum Cancellation: String, Codable, Sendable { case drainBeforeRelease }
    public init(operationID: String, revision: Int = 1, inputRoles: [ExecutionDataRole],
                outputRole: ExecutionDataRole, controlFidelity: ExecutionControlFidelity,
                cancellation: Cancellation = .drainBeforeRelease) {
        self.operationID = operationID
        self.revision = revision
        self.inputRoles = inputRoles
        self.outputRole = outputRole
        self.controlFidelity = controlFidelity
        self.cancellation = cancellation
    }
}
