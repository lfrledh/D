import DWorkbench
import Foundation

/// A stable identity for a project value. Media and documents deliberately occupy
/// separate identity spaces, even when their UUID values happen to be the same.
public enum ProjectResourceID: Hashable, Sendable {
    case media(UUID)
    case document(UUID)
}

public struct ProjectResourceItem: Identifiable, Equatable, Sendable {
    public let id: ProjectResourceID
    public let title: String
    public let mode: CreatorMode?
    public let mediaType: String
    public let originDocumentID: UUID?
    public let textPreview: String?

    public init(id: ProjectResourceID, title: String, mode: CreatorMode?, mediaType: String,
                originDocumentID: UUID? = nil, textPreview: String? = nil) {
        self.id = id
        self.title = title
        self.mode = mode
        self.mediaType = mediaType
        self.originDocumentID = originDocumentID
        self.textPreview = textPreview
    }
}

/// Read-only presentation projection. It makes no attempt to infer a media type
/// or ownership from paths, names, or the current active document.
public enum ProjectResourceCatalog {
    public static func items(in manifest: ProjectManifest, mode: CreatorMode,
                             includeOtherModes: Bool) -> [ProjectResourceItem] {
        let documents = Dictionary(uniqueKeysWithValues: manifest.documents.map { ($0.id, $0) })
        let jobs = Dictionary(uniqueKeysWithValues: manifest.jobs.map { ($0.id, $0) })

        var result = manifest.assets.map { asset in
            let originID = originDocumentID(for: asset, documents: documents, jobs: jobs)
            return ProjectResourceItem(id: .media(asset.id), title: asset.name, mode: mediaMode(asset.mediaType),
                                       mediaType: asset.mediaType, originDocumentID: originID)
        }

        // Image and audio documents are work records, not asset-like resources. A
        // saved text document is the one document type that has a real body to show.
        result += manifest.documents.compactMap { document in
            guard document.kind == .text, let text = document.textDraft?.text else { return nil }
            return ProjectResourceItem(id: .document(document.id), title: document.name, mode: .text,
                                       mediaType: "text/plain", textPreview: text)
        }

        guard !includeOtherModes else { return result }
        return result.filter { $0.mode == mode }
    }

    private static func mediaMode(_ mediaType: String) -> CreatorMode? {
        switch mediaType.lowercased() {
        case "image/png", "image/jpeg", "image/tiff": .image
        case "audio/wav", "audio/x-wav", "audio/wave", "audio/x-caf", "audio/mpeg", "audio/flac": .audio
        default: nil
        }
    }

    private static func originDocumentID(for asset: ProjectAsset,
                                         documents: [UUID: ProjectDocument],
                                         jobs: [UUID: ProjectJob]) -> UUID? {
        if let jobID = asset.jobID, let job = jobs[jobID], documents[job.documentID] != nil {
            return job.documentID
        }
        // A source reference is explicit project state. A recorded audio draft owns
        // its original asset in the same way; both are considered only if the
        // referenced document still exists.
        return documents.values.first(where: {
            $0.sourceAssetID == asset.id || $0.audioDraft?.assetID == asset.id
        })?.id
    }
}
