import CoreTransferable
import Foundation
import UniformTypeIdentifiers

enum WorkflowCanvasTransfer: Codable, Transferable, Equatable {
    case operation(id: String, modelID: String?)
    case asset(projectID: UUID, assetID: UUID)
    case output(graphID: UUID, revision: UUID, nodeID: UUID, port: String)

    private static let maximumEncodedBytes = 8 * 1_024
    private static let maximumIdentifierCharacters = 256
    private static let maximumModelIdentifierCharacters = 2_048

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .workflowCanvasItem) { value in
            try value.encoded()
        } importing: { data in
            try decode(data)
        }
    }

    func validated() throws -> Self {
        switch self {
        case .operation(let id, let modelID):
            try Self.validate(id, maximum: Self.maximumIdentifierCharacters)
            if let modelID { try Self.validate(modelID, maximum: Self.maximumModelIdentifierCharacters) }
        case .asset:
            break
        case .output(_, _, _, let port):
            try Self.validate(port, maximum: Self.maximumIdentifierCharacters)
        }
        return self
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

private extension UTType {
    static let workflowCanvasItem = UTType(
        exportedAs: "org.d-workbench.canvas-item",
        conformingTo: .data
    )
}

private enum WorkflowCanvasTransferError: Error {
    case payloadTooLarge
    case invalidIdentifier
}
