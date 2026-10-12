import Foundation
import DInference

/// Finite, typed query fields. These are projections, never a second asset authority.
public struct SharedLibraryNumberRange: Codable, Sendable, Equatable {
    public var minimum: Int?
    public var maximum: Int?
    public init(minimum: Int? = nil, maximum: Int? = nil) { self.minimum = minimum; self.maximum = maximum }
    public func contains(_ value: Int?) -> Bool {
        guard let value, value > 0 else { return false }
        return (minimum.map { value >= $0 } ?? true) && (maximum.map { value <= $0 } ?? true)
    }
    public func validate() throws {
        guard minimum != nil || maximum != nil,
              minimum.map({ $0 > 0 }) ?? true, maximum.map({ $0 > 0 }) ?? true,
              (minimum == nil || maximum == nil || minimum! <= maximum!) else { throw SharedLibraryError.invalidProperty }
    }
}
public struct SharedLibraryDateRange: Codable, Sendable, Equatable {
    public var start: Date?
    public var end: Date?
    public init(start: Date? = nil, end: Date? = nil) { self.start = start; self.end = end }
    public func contains(_ value: Date?) -> Bool {
        guard let value else { return false }
        return (start.map { value >= $0 } ?? true) && (end.map { value <= $0 } ?? true)
    }
}
public struct SharedLibraryModelSource: Codable, Sendable, Equatable, Hashable {
    public enum Kind: String, Codable, Sendable { case recordedIdentity, localReference }
    public var kind: Kind
    public var value: String
    /// nil explicitly means all recorded revisions of this exact source.
    public var revision: String?
    public init(kind: Kind, value: String, revision: String? = nil) { self.kind = kind; self.value = value; self.revision = revision }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.kind == rhs.kind && lhs.value.utf8.elementsEqual(rhs.value.utf8)
            && lhs.revision.map { Data($0.utf8) } == rhs.revision.map { Data($0.utf8) }
    }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(kind); hasher.combine(Data(value.utf8)); hasher.combine(revision.map { Data($0.utf8) })
    }
    public func matches(_ other: Self?) -> Bool {
        guard let other, kind == other.kind, value.utf8.elementsEqual(other.value.utf8) else { return false }
        return revision.map { wanted in other.revision.map { wanted.utf8.elementsEqual($0.utf8) } ?? false } ?? true
    }
}
public struct SharedLibraryQueryScope: Codable, Sendable, Equatable {
    public enum Mode: String, Codable, Sendable { case currentProject, project, run }
    public var mode: Mode
    public var projectID: UUID?
    public var instanceID: UUID?
    public var runID: UUID?
    public var nodeID: UUID?
    public var stepID: UUID?
    public init(mode: Mode, projectID: UUID? = nil, instanceID: UUID? = nil, runID: UUID? = nil, nodeID: UUID? = nil, stepID: UUID? = nil) {
        self.mode = mode; self.projectID = projectID; self.instanceID = instanceID; self.runID = runID; self.nodeID = nodeID; self.stepID = stepID
    }
    public func validate() throws {
        switch mode {
        case .currentProject: guard projectID == nil, instanceID == nil, runID == nil, nodeID == nil, stepID == nil else { throw SharedLibraryError.invalidProperty }
        case .project: guard projectID != nil, runID == nil, nodeID == nil, stepID == nil else { throw SharedLibraryError.invalidProperty }
        case .run: guard projectID != nil, instanceID != nil, runID != nil, stepID == nil || nodeID != nil else { throw SharedLibraryError.invalidProperty }
        }
    }
}
public struct SharedLibraryQueryContext: Sendable {
    public var projectID: UUID?
    public var instanceID: UUID?
    public init(projectID: UUID? = nil, instanceID: UUID? = nil) { self.projectID = projectID; self.instanceID = instanceID }
}
public struct SharedLibraryPropertyQuery: Codable, Sendable, Equatable {
    public var favorite: Bool?
    public var width: SharedLibraryNumberRange?
    public var height: SharedLibraryNumberRange?
    public var registeredAt: SharedLibraryDateRange?
    public var model: SharedLibraryModelSource?
    public var directParent: WorkflowAssetReference?
    public init(favorite: Bool? = nil, width: SharedLibraryNumberRange? = nil, height: SharedLibraryNumberRange? = nil,
                registeredAt: SharedLibraryDateRange? = nil, model: SharedLibraryModelSource? = nil, directParent: WorkflowAssetReference? = nil) {
        self.favorite = favorite; self.width = width; self.height = height; self.registeredAt = registeredAt; self.model = model; self.directParent = directParent
    }
    public var isEmpty: Bool { favorite == nil && width == nil && height == nil && registeredAt == nil && model == nil && directParent == nil }
    public func validate() throws {
        try width?.validate(); try height?.validate()
        if let range = registeredAt {
            guard range.start != nil || range.end != nil,
                  range.start.map({ $0.timeIntervalSinceReferenceDate.isFinite }) ?? true,
                  range.end.map({ $0.timeIntervalSinceReferenceDate.isFinite }) ?? true,
                  range.start == nil || range.end == nil || range.start! <= range.end! else { throw SharedLibraryError.invalidProperty }
        }
        if let model {
            guard !model.value.isEmpty, model.value.utf8.count <= 4096,
                  model.revision.map({ !$0.isEmpty && $0.utf8.count <= 512 }) ?? true else { throw SharedLibraryError.invalidProperty }
        }
        if let directParent { guard directParent.sha256.count == 64, directParent.sha256.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { throw SharedLibraryError.invalidProperty } }
    }
}
public struct SharedLibraryAssetOccurrence: Sendable, Equatable {
    public let runID: UUID
    public let nodeID: UUID
    public let stepID: UUID
    public let address: WorkflowExecutionAddress?
    public init(runID: UUID, nodeID: UUID, stepID: UUID, address: WorkflowExecutionAddress? = nil) {
        self.runID = runID; self.nodeID = nodeID; self.stepID = stepID; self.address = address
    }
}
public struct SharedLibraryAssetFacts: Sendable, Equatable {
    public let projectID: UUID
    public let instanceID: UUID
    public let note: String
    public let favorite: Bool
    public let width: Int?
    public let height: Int?
    public let registeredAt: Date
    public let model: SharedLibraryModelSource?
    /// nil means ancestry not indexed/recorded, not an empty ancestry.
    public let parents: [WorkflowAssetReference]?
    public let occurrences: [SharedLibraryAssetOccurrence]?
    public init(projectID: UUID, instanceID: UUID, note: String = "", favorite: Bool = false,
                width: Int? = nil, height: Int? = nil, registeredAt: Date, model: SharedLibraryModelSource? = nil,
                parents: [WorkflowAssetReference]? = nil, occurrences: [SharedLibraryAssetOccurrence]? = nil) {
        self.projectID = projectID; self.instanceID = instanceID; self.note = note; self.favorite = favorite
        self.width = width; self.height = height; self.registeredAt = registeredAt; self.model = model; self.parents = parents; self.occurrences = occurrences
    }
    public func matches(scope: SharedLibraryQueryScope?, properties: SharedLibraryPropertyQuery?, context: SharedLibraryQueryContext) -> Bool {
        if let scope {
            switch scope.mode {
            case .currentProject:
                guard let current = context.projectID, projectID == current,
                      context.instanceID.map({ instanceID == $0 }) ?? true else { return false }
            case .project, .run:
                guard projectID == scope.projectID, scope.instanceID.map({ instanceID == $0 }) ?? true else { return false }
                if scope.mode == .run {
                    guard occurrences?.contains(where: { occurrence in
                        occurrence.runID == scope.runID && (scope.nodeID.map { occurrence.nodeID == $0 } ?? true)
                            && (scope.stepID.map { occurrence.stepID == $0 } ?? true)
                    }) == true else { return false }
                }
            }
        }
        guard let properties else { return true }
        return (properties.favorite.map { favorite == $0 } ?? true)
            && (properties.width.map { $0.contains(width) } ?? true)
            && (properties.height.map { $0.contains(height) } ?? true)
            && (properties.registeredAt.map { $0.contains(registeredAt) } ?? true)
            && (properties.model.map { $0.matches(model) } ?? true)
            && (properties.directParent.map { parents?.contains($0) == true } ?? true)
    }
    public func hasMissingFields(for query: SharedLibraryPropertyQuery) -> Bool {
        (query.width != nil && width == nil) || (query.height != nil && height == nil)
            || (query.model != nil && model == nil) || (query.directParent != nil && parents == nil)
    }
}

/// Read-only registered facts; no pin, import, media decode, or graph mutation.
public struct ProjectAssetMetadataSnapshot: Sendable, Equatable {
    public let projectID: UUID
    public let instanceID: UUID
    public let projectName: String
    public let asset: ProjectAsset
    public let record: WorkflowAssetRecord?
    public let job: ProjectJob?
    public let occurrences: [SharedLibraryAssetOccurrence]?
    public let sourceIssue: String?
    public var request: InferenceRequest? { record?.request ?? job?.request }
    public var requestedSeed: String? {
        guard let request else { return nil }
        switch request.input {
        case .text(let input): return input.seed.map(String.init)
        case .image(let input): return String(input.seed)
        case .audio(let input): return String(input.seed)
        case .video(let input): return String(input.seed)
        case .pitch, .singing: return nil
        }
    }
    public var facts: SharedLibraryAssetFacts {
        let identity = record?.metadata["modelIdentity"] ?? job?.resultMetadata["modelIdentity"]
        let source: SharedLibraryModelSource? = identity.map { .init(kind: .recordedIdentity, value: $0, revision: request?.model.revision) }
            ?? request.map { .init(kind: .localReference, value: $0.model.directory.path, revision: $0.model.revision) }
        return .init(projectID: projectID, instanceID: instanceID, note: asset.note, favorite: asset.isFavorite,
                     width: asset.metadata.width, height: asset.metadata.height, registeredAt: asset.createdAt,
                     model: source, parents: record?.parents, occurrences: occurrences)
    }
    public init(project: ProjectManifest, asset: ProjectAsset, record: WorkflowAssetRecord?, job: ProjectJob?, occurrences: [SharedLibraryAssetOccurrence]?, sourceIssue: String?) {
        projectID = project.id; instanceID = project.effectiveInstanceID; projectName = project.name; self.asset = asset
        self.record = record; self.job = job; self.occurrences = occurrences; self.sourceIssue = sourceIssue
    }
}
public struct ProjectAssetEditBaseline: Sendable {
    public let projectID: UUID
    public let instanceID: UUID
    public let assetID: UUID
    public let name: String
    public let note: String
    public let favorite: Bool
    public init(project: ProjectManifest, asset: ProjectAsset) {
        projectID = project.id; instanceID = project.effectiveInstanceID; assetID = asset.id
        name = asset.name; note = asset.note; favorite = asset.isFavorite
    }
    public init(snapshot: ProjectAssetMetadataSnapshot) {
        projectID = snapshot.projectID; instanceID = snapshot.instanceID; assetID = snapshot.asset.id
        name = snapshot.asset.name; note = snapshot.asset.note; favorite = snapshot.asset.isFavorite
    }
}

extension SharedLibraryPropertyQuery {
    public static func merging(_ original: Self?, _ addition: Self) -> Self {
        var value = original ?? .init()
        if let favorite = addition.favorite { value.favorite = favorite }
        if let width = addition.width { value.width = width }
        if let height = addition.height { value.height = height }
        if let date = addition.registeredAt { value.registeredAt = date }
        if let model = addition.model { value.model = model }
        if let parent = addition.directParent { value.directParent = parent }
        return value
    }
}
