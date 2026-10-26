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
    case libraryItems(owner: WorkflowAssetLibraryOwner, items: [WorkflowLibraryDropItem])
    case library(owner: WorkflowAssetLibraryOwner, sources: [WorkflowLibrarySource])
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

    var libraryPayload: (owner: WorkflowAssetLibraryOwner, items: [WorkflowLibraryDropItem])? {
        switch self {
        case .library(let owner, let sources): return (owner, sources.map(WorkflowLibraryDropItem.source))
        case .libraryItems(let owner, let items): return (owner, items)
        default: return nil
        }
    }
    private static let maximumEncodedBytes = 64 * 1_024
    private static let maximumIdentifierCharacters = 256
    private static let maximumModelIdentifierCharacters = 2_048

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(contentType: .workflowCanvasItem) { value in
            try value.encoded()
        } importing: { data in
            return try decode(data)
        }
        // These are live references for this D process, not an external file export.
        .visibility(.ownProcess)
    }

    func validated() throws -> Self {
        switch self {
        case .operation(let id, let modelID):
            try Self.validate(id, maximum: Self.maximumIdentifierCharacters)
            if let modelID { try Self.validate(modelID, maximum: Self.maximumModelIdentifierCharacters) }
        case .asset, .assetInstance:
            break
        case .libraryItems(let owner, let items):
            guard !items.isEmpty, items.count <= 64 else { throw WorkflowCanvasTransferError.invalidIdentifier }
            for item in items {
                switch item {
                case .source(let source): _ = try WorkflowCanvasTransfer.library(owner: owner, sources: [source]).validated()
                case .original(let token):
                    guard token.projectID == owner.projectID, token.instanceID == owner.instanceID,
                          token.sha256.count == 64, token.sha256.allSatisfy({ $0.isHexDigit }), token.relativePath.utf8.count <= 4096 else { throw WorkflowCanvasTransferError.invalidIdentifier }
                }
            }
        case .library(_, let sources):
            guard !sources.isEmpty, sources.count <= 64, Set(sources.map(\.key)).count == sources.count else { throw WorkflowCanvasTransferError.invalidIdentifier }
            for source in sources {
                switch source {
                case .asset(let reference): guard reference.sha256.count == 64 else { throw WorkflowCanvasTransferError.invalidIdentifier }
                case .runtime(let reference):
                    guard reference.call.address.path.count <= 64, reference.outputDigest.count == 64, (reference.itemID?.utf8.count ?? 0) <= 256 else { throw WorkflowCanvasTransferError.invalidIdentifier }
                }
            }
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
