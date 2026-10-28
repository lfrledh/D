import CryptoKit
import Foundation

/// A reference into retained frozen run content. It does not store a second copy
/// of the value, and its digest covers the complete output before item projection.
public struct WorkflowRuntimeAssetSource: Codable, Sendable, Equatable {
    public let call: WorkflowCallReference
    public let port: String
    public let itemID: String?
    public let outputDigest: String
    public let input: Bool?
    public let wholeValue: Bool?
    public init(call: WorkflowCallReference, port: String, value: WorkflowValue, itemID: String? = nil, input: Bool = false) throws {
        self.call = call; self.port = port; self.input = input ? true : nil
        switch value {
        case .collection, .data(.list): self.itemID = itemID; wholeValue = itemID == nil ? true : nil
        default:
            guard itemID == nil || itemID == "value" else { throw WorkflowIssue("Invalid scalar item identity.", code: "container.issue.sourceUnavailable") }
            self.itemID = nil; wholeValue = true
        }
        outputDigest = try Self.digest(value)
    }
    private init(base: Self, itemID: String?, wholeValue: Bool?) {
        call = base.call; port = base.port; input = base.input; outputDigest = base.outputDigest
        self.itemID = itemID; self.wholeValue = wholeValue
    }
    /// One full digest for a bounded projection; each member still resolves and
    /// validates that complete version before any durable mutation.
    public static func projectedItems(call: WorkflowCallReference, port: String, value: WorkflowValue, input: Bool = false) throws -> [(item: WorkflowAssetContainer.Item, source: Self)] {
        let base = try Self(call: call, port: port, value: value, input: input)
        let collection: Bool
        switch value { case .collection, .data(.list): collection = true; default: collection = false }
        return try WorkflowAssetContainer.items(in: value).map { item in
            (item, Self(base: base, itemID: collection ? item.id : nil, wholeValue: collection ? nil : true))
        }
    }
    public func annotationIdentity(owner: WorkflowAssetLibraryOwner, value: WorkflowValue) throws -> WorkflowValueIdentity {
        let member = wholeValue == true || itemID == nil ? nil : itemID
        return try WorkflowValueIdentity(projectID: owner.projectID, instanceID: owner.instanceID, call: call,
            port: input == true ? "preview" : port, value: value, itemID: member, sourceVersion: member == nil ? nil : outputDigest)
    }
    public static func capture(_ record: WorkflowPlanCallRecord, port: String, itemID: String? = nil) throws -> Self {
        // The complete original input survives acceptance and rejection. Do not
        // redirect an already collected preview to the later filtered output.
        let isInput = [WorkflowAssetContainer.filterID, "d.asset.choose", "d.text.confirm"].contains(record.step.node.operationID) && port == "preview"
        let key = isInput ? "input" : port
        guard let value = (isInput ? record.step.inputs : record.step.outputs)[key] else { throw WorkflowIssue("Output is unavailable.", code: "container.issue.sourceUnavailable") }
        return try .init(call: .init(address: record.address, stepID: record.id), port: key, value: value, itemID: itemID, input: isInput)
    }
    public static func digest(_ value: WorkflowValue) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
    }
    public func validateForCollection(in runs: [WorkflowRun]) throws {
        guard let record = runs.first(where: { $0.id == call.address.runID })?.planCheckpoint?.records.first(where: { $0.address == call.address && $0.id == call.stepID }),
              (input == true
                ? [WorkflowAssetContainer.filterID, "d.asset.choose", "d.text.confirm"].contains(record.step.node.operationID) && [.waiting, .completed, .partial, .rejected].contains(record.step.status)
                : [.completed, .partial].contains(record.step.status)) else {
            throw WorkflowIssue("Wait until this output has a stable saved version before collecting it.", code: "container.issue.sourceUnsettled")
        }
        _ = try resolve(in: runs)
    }
    public func resolve(in runs: [WorkflowRun]) throws -> WorkflowValue {
        guard let run = runs.first(where: { $0.id == call.address.runID }),
              let record = run.planCheckpoint?.records.first(where: { $0.address == call.address && $0.id == call.stepID }),
              let output = (input == true ? record.step.inputs : record.step.outputs)[port], try Self.digest(output) == outputDigest else {
            throw WorkflowIssue("The exact saved output is no longer available.", code: "container.issue.sourceUnavailable")
        }
        let expectedWhole: Bool?
        switch output {
        case .collection, .data(.list): expectedWhole = itemID == nil ? true : nil
        default:
            guard itemID == nil else { throw WorkflowIssue("Saved scalar member identity is inconsistent.", code: "container.issue.sourceUnavailable") }
            expectedWhole = true
        }
        guard wholeValue == expectedWhole, input != false else { throw WorkflowIssue("Saved output member identity is inconsistent.", code: "container.issue.sourceUnavailable") }
        if let itemID {
            guard let item = try WorkflowAssetContainer.items(in: output).first(where: { $0.id == itemID }),
                  item.selectable, let value = item.value else { throw WorkflowIssue("The selected output item is unavailable.", code: "container.issue.sourceUnavailable") }
            return value
        }
        return output
    }
}

public enum WorkflowLibrarySource: Codable, Sendable, Equatable {
    case asset(WorkflowAssetReference)
    case runtime(WorkflowRuntimeAssetSource)
    public var key: String {
        switch self {
        case .asset(let reference): return "asset:" + reference.assetID.uuidString
        case .runtime(let source):
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return "value:" + SHA256.hash(data: (try? encoder.encode(source)) ?? Data()).map { String(format: "%02x", $0) }.joined()
        }
    }
}

/// Project-owned organization, saved in the existing workflow archive. Initial
/// visibility is captured once; no mtime guess, directory scan or editable tag.
public struct WorkflowAssetCollection: Codable, Sendable, Equatable {
    public let legacyAssetIDs: Set<UUID>
    public let legacyRuntimeKeys: Set<String>
    public var included: [String: WorkflowLibrarySource] = [:]
    public var excluded: Set<String> = []
    public var retained: [String: WorkflowLibrarySource] = [:]
    public init(legacyAssetIDs: Set<UUID>, legacyRuntimeKeys: Set<String>) {
        self.legacyAssetIDs = legacyAssetIDs; self.legacyRuntimeKeys = legacyRuntimeKeys
    }
    public func contains(asset: ProjectAsset) -> Bool {
        let key = "asset:" + asset.id.uuidString
        return !excluded.contains(key) && (legacyAssetIDs.contains(asset.id) || asset.role == .original || included[key] != nil)
    }
    public func contains(_ source: WorkflowLibrarySource) -> Bool {
        // One exact key per lookup. Runtime keys encode and hash the full source;
        // reuse it only within this call, never as a stale write-validation cache.
        let key = source.key
        guard !excluded.contains(key) else { return false }
        if included[key] != nil { return true }
        switch source {
        case .asset(let reference): return legacyAssetIDs.contains(reference.assetID)
        case .runtime: return legacyRuntimeKeys.contains(key)
        }
    }
    public mutating func set(_ sources: [WorkflowLibrarySource], collected: Bool) throws {
        guard sources.count <= 4096, Set(sources.map(\.key)).count == sources.count else {
            throw WorkflowIssue("Invalid asset collection selection.", code: "container.issue.sourceUnavailable")
        }
        for source in sources {
            retained[source.key] = source
            if let existing = included[source.key], existing != source { throw WorkflowIssue("Asset identity changed before collection.", code: "container.issue.sourceUnavailable") }
            if collected { included[source.key] = source; excluded.remove(source.key) }
            else { included.removeValue(forKey: source.key); excluded.insert(source.key) }
        }
        guard retained.count <= 32768, included.count + excluded.count <= 32768 else { throw WorkflowIssue("Asset collection size limit reached.", code: "container.issue.collectionLimit") }
    }
}

public struct WorkflowAssetLibraryOwner: Sendable, Equatable, Codable {
    public let projectID: UUID
    public let instanceID: UUID
    public init(projectID: UUID, instanceID: UUID) { self.projectID = projectID; self.instanceID = instanceID }
}


public struct WorkflowAssetCollectionRule: Codable, Sendable, Equatable {
    public let id: UUID
    public let folderID: UUID?
    /// Nil preserves legacy folder rules without rewriting frozen history.
    public let tagIDs: Set<UUID>?
    public init(id: UUID = UUID(), folderID: UUID? = nil, tagIDs: Set<UUID>? = nil) {
        self.id = id; self.folderID = folderID; self.tagIDs = tagIDs
    }
    private enum CodingKeys: String, CodingKey { case id, folderID, tagIDs }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encodeIfPresent(folderID, forKey: .folderID)
        try c.encodeIfPresent(tagIDs?.sorted { $0.uuidString < $1.uuidString }, forKey: .tagIDs)
    }
}

/// An outbox for organization only, owned by the existing project archive.
/// Membership and local classification have different stores, so acknowledgement
/// follows both idempotent writes. Retrying can never dispatch a workflow.
public struct WorkflowAssetCollectionRequest: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let owner: WorkflowAssetLibraryOwner
    public let sources: [WorkflowLibrarySource]
    public let folderID: UUID?
    public let tagIDs: Set<UUID>?
    public let origin: WorkflowCallReference?
    public let manualID: UUID?
    public var completed = false
    public var error: String?
    public var errorCode: String?
    public init(trigger: String, owner: WorkflowAssetLibraryOwner, sources: [WorkflowLibrarySource], folderID: UUID?, tagIDs: Set<UUID>? = nil, origin: WorkflowCallReference? = nil, manualID: UUID? = nil) throws {
        guard !sources.isEmpty, sources.count <= 4096 else { throw WorkflowIssue("Invalid collection request size.", code: "container.issue.collectionLimit") }
        self.owner = owner; self.sources = sources; self.folderID = folderID; self.tagIDs = tagIDs; self.origin = origin; self.manualID = manualID
        id = SHA256.hash(data: Data(trigger.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private enum CodingKeys: String, CodingKey { case id, owner, sources, folderID, tagIDs, origin, manualID, completed, error, errorCode }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(owner, forKey: .owner); try c.encode(sources, forKey: .sources)
        try c.encodeIfPresent(folderID, forKey: .folderID)
        try c.encodeIfPresent(tagIDs?.sorted { $0.uuidString < $1.uuidString }, forKey: .tagIDs)
        try c.encodeIfPresent(origin, forKey: .origin); try c.encodeIfPresent(manualID, forKey: .manualID)
        try c.encode(completed, forKey: .completed); try c.encodeIfPresent(error, forKey: .error); try c.encodeIfPresent(errorCode, forKey: .errorCode)
    }
    public static func event(_ record: WorkflowPlanCallRecord, previous: WorkflowPlanCallRecord?, owner: WorkflowAssetLibraryOwner) throws -> Self? {
        guard let rule = record.step.node.collectionRule else { return nil }
        let value: WorkflowValue, ids: [String], input: Bool
        if record.step.node.operationID == WorkflowAssetContainer.filterID,
           record.step.decision?.accepted == true, previous?.step.decision == nil,
           let original = record.step.inputs["input"], let chosen = record.step.decision?.selectedItemIDs {
            value = original; ids = chosen; input = true
        } else if record.step.node.operationID == WorkflowAssetContainer.previewID,
                  record.step.status == .completed, previous?.step.status != .completed,
                  let output = record.step.outputs["output"] {
            value = output; ids = try WorkflowAssetContainer.items(in: value).filter(\.selectable).map(\.id); input = false
        } else { return nil }
        var seen = Set<String>()
        let sources = try WorkflowAssetContainer.items(in: value).filter { ids.contains($0.id) }.map { item -> WorkflowLibrarySource in
            if let asset = item.value?.asset { return .asset(asset) }
            return .runtime(try .init(call: .init(address: record.address, stepID: record.id), port: input ? "input" : "output", value: value, itemID: item.id, input: input))
        }.filter { seen.insert($0.key).inserted }
        guard !sources.isEmpty else { return nil }
        return try .init(trigger: rule.id.uuidString + ":" + record.id.uuidString,
            owner: owner, sources: sources, folderID: rule.folderID, tagIDs: rule.tagIDs, origin: .init(address: record.address, stepID: record.id))
    }
}

extension WorkflowLibrarySource {
    public func metadataKey(owner: WorkflowAssetLibraryOwner, runs: [WorkflowRun]) throws -> String {
        switch self {
        case .asset(let ref):
            guard ref.projectID == owner.projectID else { throw WorkflowIssue("Asset project differs from collection owner.", code: "container.issue.sourceUnavailable") }
            return "asset:" + ref.projectID.uuidString + ":" + ref.assetID.uuidString
        case .runtime(let ref):
            return try ref.annotationIdentity(owner: owner, value: ref.resolve(in: runs)).storageKey
        }
    }
}

/// Transient drag payload. Originals are verified read tokens, never fabricated
/// published references. They are registered only on the explicit drop command.
public enum WorkflowLibraryDropItem: Codable, Sendable, Equatable {
    case source(WorkflowLibrarySource)
    case original(ProjectReadOnlyAsset)
}
