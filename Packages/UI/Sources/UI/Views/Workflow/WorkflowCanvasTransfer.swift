import CoreTransferable
import DWorkbench
import Foundation
import UniformTypeIdentifiers

struct WorkflowCanvasBodyLocation: Codable, Hashable, Sendable {
    let nodeID: UUID
    let slot: String

    init(nodeID: UUID, slot: String) {
        self.nodeID = nodeID
        self.slot = slot
    }

    init(_ location: WorkflowBodyLocation) {
        self.init(nodeID: location.nodeID, slot: location.slot)
    }
}

enum WorkflowCanvasTransfer: Codable, Transferable, Equatable, Sendable {
    case operation(id: String, modelID: String?)
    case asset(projectID: UUID, assetID: UUID)
    case assetInstance(projectID: UUID, instanceID: UUID, assetID: UUID)
    case tool(WorkflowToolReference)
    case output(
        rootGraphID: UUID,
        bodyPath: [WorkflowCanvasBodyLocation],
        graphID: UUID,
        revision: UUID,
        nodeID: UUID,
        port: String,
        projectID: UUID? = nil,
        instanceID: UUID? = nil
    )

    private static let maximumEncodedBytes = 8 * 1_024
    private static let maximumIdentifierCharacters = 256
    private static let maximumModelIdentifierCharacters = 2_048

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(contentType: .workflowCanvasItem) { value in
            try value.encoded()
        } importing: { data in
            return try decode(data)
        }
    }

    func validated() throws -> Self {
        switch self {
        case .operation(let id, let modelID):
            try Self.validate(id, maximum: Self.maximumIdentifierCharacters)
            if let modelID { try Self.validate(modelID, maximum: Self.maximumModelIdentifierCharacters) }
        case .asset, .assetInstance:
            break
        case .tool(let reference):
            guard reference.version > 0, reference.digest.count == 64,
                  reference.digest.allSatisfy({ $0.isHexDigit }) else { throw WorkflowCanvasTransferError.invalidIdentifier }
        case .output(_, let bodyPath, _, _, _, let port, _, _):
            guard bodyPath.count <= 16 else { throw WorkflowCanvasTransferError.invalidIdentifier }
            for location in bodyPath {
                try Self.validate(location.slot, maximum: Self.maximumIdentifierCharacters)
            }
            try Self.validate(port, maximum: Self.maximumIdentifierCharacters)
        }
        return self
    }

    func matchesOutputScope(_ scope: WorkflowCanvasScope) -> Bool {
        guard case .output(
            let rootGraphID,
            let bodyPath,
            let graphID,
            let revision,
            _, _, let projectID, let instanceID
        ) = self else { return false }
        return projectID == scope.projectID && instanceID == scope.instanceID
            && rootGraphID == scope.rootGraphID
            && bodyPath == scope.bodyPath.map(WorkflowCanvasBodyLocation.init)
            && graphID == scope.graphID
            && revision == scope.rootRevision
    }

    func encoded() throws -> Data {
        let data = try JSONEncoder().encode(validated())
        guard data.count <= Self.maximumEncodedBytes else { throw WorkflowCanvasTransferError.payloadTooLarge }
        return data
    }

    static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= maximumEncodedBytes else {
            throw WorkflowCanvasTransferError.payloadTooLarge
        }
        return try JSONDecoder().decode(Self.self, from: data).validated()
    }

    private static func validate(_ value: String, maximum: Int) throws {
        guard !value.isEmpty, value.count <= maximum,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw WorkflowCanvasTransferError.invalidIdentifier
        }
    }
}

extension UTType {
    static let workflowCanvasItem = UTType(
        exportedAs: "org.d-workbench.canvas-item",
        conformingTo: .data
    )
}

private enum WorkflowCanvasTransferError: Error {
    case payloadTooLarge
    case invalidIdentifier
}
