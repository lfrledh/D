import Foundation
import Observation

/// Presentation metadata only. Callers supply stable keys and actual capabilities/readiness.
public enum SharedLibraryItemKind: String, Codable, Sendable, CaseIterable {
    case model, component, program, tool, asset
}

public enum SharedLibraryReadiness: String, Codable, Sendable, CaseIterable {
    case available, unprepared, unavailable, unsupported, unknown
}

public enum SharedLibraryCompatibility: String, Codable, Sendable, CaseIterable {
    case compatible, incompatible, unknown

    public init(_ value: Bool?) {
        switch value {
        case true: self = .compatible
        case false: self = .incompatible
        case nil: self = .unknown
        }
    }
}

public struct SharedLibraryItem: Sendable, Equatable, Identifiable {
    /// The caller owns identity. Asset keys must include their project UUID; node-instance keys
    /// must be distinct from model keys. This service never interprets a key as a path.
    public let key: String
    public var id: String { key }
    public let title: String
    public let detail: String
    public let kind: SharedLibraryItemKind
    public let role: String
    public let inputs: Set<WorkflowDataKind>
    public let outputs: Set<WorkflowDataKind>
    public let contentKind: WorkflowDataKind?
    public let readiness: SharedLibraryReadiness
    public let compatible: Bool?

    public init(key: String, title: String, detail: String = "", kind: SharedLibraryItemKind,
                role: String = "", inputs: Set<WorkflowDataKind> = [],
                outputs: Set<WorkflowDataKind> = [], contentKind: WorkflowDataKind? = nil,
                readiness: SharedLibraryReadiness = .unknown, compatible: Bool? = nil) {
        self.key = key; self.title = title; self.detail = detail; self.kind = kind
        self.role = role; self.inputs = inputs; self.outputs = outputs
        self.contentKind = contentKind; self.readiness = readiness; self.compatible = compatible
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.key.utf8.elementsEqual(rhs.key.utf8)
            && lhs.title.utf8.elementsEqual(rhs.title.utf8)
            && lhs.detail.utf8.elementsEqual(rhs.detail.utf8)
            && lhs.role.utf8.elementsEqual(rhs.role.utf8)
            && lhs.kind == rhs.kind && lhs.inputs == rhs.inputs && lhs.outputs == rhs.outputs
            && lhs.contentKind == rhs.contentKind && lhs.readiness == rhs.readiness
            && lhs.compatible == rhs.compatible
    }
}

public struct SharedLibraryQuery: Codable, Sendable, Equatable {
    public var text: String
    public var kinds: Set<SharedLibraryItemKind>
    public var roles: Set<String>
    public var inputs: Set<WorkflowDataKind>
    public var outputs: Set<WorkflowDataKind>
    public var contentKinds: Set<WorkflowDataKind>
    public var readiness: Set<SharedLibraryReadiness>
    public var compatibility: Set<SharedLibraryCompatibility>
    public var allTagIDs: Set<UUID>
    public var anyTagIDs: Set<UUID>

    public init(text: String = "", kinds: Set<SharedLibraryItemKind> = [], roles: Set<String> = [],
                inputs: Set<WorkflowDataKind> = [], outputs: Set<WorkflowDataKind> = [],
                contentKinds: Set<WorkflowDataKind> = [], readiness: Set<SharedLibraryReadiness> = [],
                compatibility: Set<SharedLibraryCompatibility> = [], allTagIDs: Set<UUID> = [],
                anyTagIDs: Set<UUID> = []) {
        self.text = text; self.kinds = kinds; self.roles = roles; self.inputs = inputs
        self.outputs = outputs; self.contentKinds = contentKinds; self.readiness = readiness
        self.compatibility = compatibility; self.allTagIDs = allTagIDs; self.anyTagIDs = anyTagIDs
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text.utf8.elementsEqual(rhs.text.utf8)
            && Set(lhs.roles.map { Data($0.utf8) }) == Set(rhs.roles.map { Data($0.utf8) })
            && lhs.kinds == rhs.kinds && lhs.inputs == rhs.inputs && lhs.outputs == rhs.outputs
            && lhs.contentKinds == rhs.contentKinds && lhs.readiness == rhs.readiness
            && lhs.compatibility == rhs.compatibility && lhs.allTagIDs == rhs.allTagIDs
            && lhs.anyTagIDs == rhs.anyTagIDs
    }
}

public struct SharedLibraryTag: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var name: String
    public init(id: UUID = UUID(), name: String) { self.id = id; self.name = name }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.name.utf8.elementsEqual(rhs.name.utf8)
    }
}

public struct SharedLibraryFolder: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var name: String
    public var parentID: UUID?
    public var memberKeys: Set<String>
    public init(id: UUID = UUID(), name: String, parentID: UUID? = nil, memberKeys: Set<String> = []) {
        self.id = id; self.name = name; self.parentID = parentID; self.memberKeys = memberKeys
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.name.utf8.elementsEqual(rhs.name.utf8)
            && lhs.parentID == rhs.parentID && lhs.memberKeys == rhs.memberKeys
    }
}

public struct SharedLibrarySavedQuery: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var name: String
    public var query: SharedLibraryQuery
    public init(id: UUID = UUID(), name: String, query: SharedLibraryQuery) {
        self.id = id; self.name = name; self.query = query
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.name.utf8.elementsEqual(rhs.name.utf8) && lhs.query == rhs.query
    }
}

public struct SharedLibraryMetadata: Codable, Sendable, Equatable {
    public var tags: [UUID: SharedLibraryTag] = [:]
    public var folders: [UUID: SharedLibraryFolder] = [:]
    public var savedQueries: [UUID: SharedLibrarySavedQuery] = [:]
    public var tagAssignments: [String: Set<UUID>] = [:]
    public var importedLegacyKeys: Set<String> = []
    public init() {}
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.tags == rhs.tags && lhs.folders == rhs.folders
            && lhs.savedQueries == rhs.savedQueries && lhs.tagAssignments == rhs.tagAssignments
            && lhs.importedLegacyKeys == rhs.importedLegacyKeys
    }
}

public enum SharedLibraryError: Error, LocalizedError, Equatable {
    case invalidName, duplicateName(String), missingTag, missingFolder, missingQuery
    case invalidKey, invalidReference, folderCycle, folderDepth, invalidMembership, tagInSavedQuery
    case limitExceeded(String), unsupportedSchema(Int), corruptedMetadata(String)
    case invalidFileURL, externalChange

    public var errorDescription: String? {
        switch self {
        case .invalidName: "Name is empty or exceeds its length limit."
        case .duplicateName(let name): "Name already exists: \(name)"
        case .missingTag: "Tag no longer exists."
        case .missingFolder: "Folder no longer exists."
        case .missingQuery: "Saved query no longer exists."
        case .invalidKey: "Entry key is empty or too long."
        case .invalidReference: "Metadata refers to a missing tag or folder."
        case .folderCycle: "Folder ancestry contains a cycle."
        case .folderDepth: "Folders can be at most four levels deep."
        case .invalidMembership: "Only manual folders accept members."
        case .tagInSavedQuery: "Edit saved queries that reference this tag before deleting it."
        case .limitExceeded(let detail): "Metadata limit exceeded: \(detail)"
        case .unsupportedSchema(let version): "Unsupported library metadata schema \(version). Restore or upgrade the file before editing."
        case .corruptedMetadata(let detail): "Library metadata needs recovery: \(detail)"
        case .invalidFileURL: "Library metadata requires a local file URL."
        case .externalChange: "Library metadata changed on disk. Reopen or recover before editing."
        }
    }
}

private struct SharedLibraryEnvelope: Codable {
    var schema: Int
    var metadata: SharedLibraryMetadata
}

private struct SharedLibraryHeader: Decodable { let schema: Int }

@MainActor @Observable
public final class SharedLibraryStore {
    public private(set) var metadata: SharedLibraryMetadata
    @ObservationIgnored private let fileURL: URL?
    /// Exact bytes read at open or written by this instance; nil means the file was absent.
    @ObservationIgnored private var diskBaseline: Data?
    private var undoStack: [SharedLibraryMetadata] = []
    private var redoStack: [SharedLibraryMetadata] = []
    /// Retains at most 50 metadata snapshots, independent of the number of models or assets.
    public static let historyLimit = 50

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// A missing file starts empty. All other read/decode/validation errors are surfaced; no
    /// editable empty substitute is returned for a damaged or inaccessible existing file.
    public init(fileURL: URL? = nil) throws {
        self.fileURL = fileURL
        guard let fileURL else { metadata = SharedLibraryMetadata(); diskBaseline = nil; return }
        guard fileURL.isFileURL else { throw SharedLibraryError.invalidFileURL }
        guard let data = try Self.readDisk(fileURL) else {
            metadata = SharedLibraryMetadata(); diskBaseline = nil; return
        }
        let header: SharedLibraryHeader
        do { header = try JSONDecoder().decode(SharedLibraryHeader.self, from: data) }
        catch { throw SharedLibraryError.corruptedMetadata(error.localizedDescription) }
        guard header.schema == 1 else { throw SharedLibraryError.unsupportedSchema(header.schema) }
        try Self.rejectUnknownFields(data)
        let envelope: SharedLibraryEnvelope
        do { envelope = try JSONDecoder().decode(SharedLibraryEnvelope.self, from: data) }
        catch { throw SharedLibraryError.corruptedMetadata(error.localizedDescription) }
        try Self.validate(envelope.metadata)
        metadata = envelope.metadata
        diskBaseline = data
    }

    /// Empty sets mean no constraint. Values within one dimension are OR; dimensions are AND.
    /// Text words must all match title, detail, or current user-tag names.
    public func matches(_ item: SharedLibraryItem, query: SharedLibraryQuery) -> Bool {
        let ids = metadata.tagAssignments[item.key] ?? []
        if !query.kinds.isEmpty && !query.kinds.contains(item.kind) { return false }
        if !query.roles.isEmpty && !query.roles.contains(item.role) { return false }
        if !query.inputs.isEmpty && query.inputs.isDisjoint(with: item.inputs) { return false }
        if !query.outputs.isEmpty && query.outputs.isDisjoint(with: item.outputs) { return false }
        if !query.contentKinds.isEmpty && (item.contentKind.map { !query.contentKinds.contains($0) } ?? true) { return false }
        if !query.readiness.isEmpty && !query.readiness.contains(item.readiness) { return false }
        if !query.compatibility.isEmpty && !query.compatibility.contains(SharedLibraryCompatibility(item.compatible)) { return false }
        if !query.allTagIDs.isSubset(of: ids) { return false }
        if !query.anyTagIDs.isEmpty && query.anyTagIDs.isDisjoint(with: ids) { return false }
        let haystack = ([item.title, item.detail] + ids.compactMap { metadata.tags[$0]?.name }).joined(separator: " ")
        return query.text.split(whereSeparator: \.isWhitespace).allSatisfy {
            haystack.localizedStandardContains(String($0))
        }
    }

    public func filter(_ items: [SharedLibraryItem], query: SharedLibraryQuery) -> [SharedLibraryItem] {
        items.filter { matches($0, query: query) }
    }

    public func filter(_ items: [SharedLibraryItem], savedQueryID: UUID) throws -> [SharedLibraryItem] {
        guard let query = metadata.savedQueries[savedQueryID]?.query else { throw SharedLibraryError.missingQuery }
        return filter(items, query: query)
    }

    public func createTags(_ names: [String]) throws -> [UUID] {
        let ids = names.map { _ in UUID() }
        try change { value in
            for (id, raw) in zip(ids, names) {
                let name = try Self.name(raw, maximum: 32)
                guard !value.tags.values.contains(where: { Self.sameBytes($0.name, name) }) else {
                    throw SharedLibraryError.duplicateName(name)
                }
                value.tags[id] = SharedLibraryTag(id: id, name: name)
            }
        }
        return ids
    }

    public func renameTags(_ names: [UUID: String]) throws {
        try change { value in
            for (id, raw) in names {
                guard var tag = value.tags[id] else { throw SharedLibraryError.missingTag }
                tag.name = try Self.name(raw, maximum: 32)
                value.tags[id] = tag
            }
        }
    }

    public func deleteTags(_ ids: Set<UUID>) throws {
        try change { value in
            guard ids.allSatisfy({ value.tags[$0] != nil }) else { throw SharedLibraryError.missingTag }
            for saved in value.savedQueries.values {
                if !ids.isDisjoint(with: saved.query.allTagIDs.union(saved.query.anyTagIDs)) {
                    throw SharedLibraryError.tagInSavedQuery
                }
            }
            for id in ids { value.tags.removeValue(forKey: id) }
            for key in value.tagAssignments.keys {
                value.tagAssignments[key]?.subtract(ids)
                if value.tagAssignments[key]?.isEmpty == true { value.tagAssignments.removeValue(forKey: key) }
            }
        }
    }

    public func addTags(_ ids: Set<UUID>, to keys: Set<String>) throws {
        try change { value in
            guard ids.allSatisfy({ value.tags[$0] != nil }) else { throw SharedLibraryError.missingTag }
            for key in keys { value.tagAssignments[key, default: []].formUnion(ids) }
        }
    }

    public func removeTags(_ ids: Set<UUID>, from keys: Set<String>) throws {
        try change { value in
            guard ids.allSatisfy({ value.tags[$0] != nil }) else { throw SharedLibraryError.missingTag }
            for key in keys {
                value.tagAssignments[key]?.subtract(ids)
                if value.tagAssignments[key]?.isEmpty == true { value.tagAssignments.removeValue(forKey: key) }
            }
        }
    }

    /// Explicit one-time import. Exact, case-sensitive names are reused; Unicode is trimmed
    /// without normalization. Invalid input fails the entire batch and leaves the key unmarked.
    public func importLegacyTags(_ names: [String], for key: String) throws {
        guard !metadata.importedLegacyKeys.contains(key) else { return }
        try change { value in
            var seen: Set<Data> = []
            for raw in names {
                let name = try Self.name(raw, maximum: 32)
                guard seen.insert(Data(name.utf8)).inserted else { throw SharedLibraryError.duplicateName(name) }
                let id: UUID
                if let existing = value.tags.values.first(where: { Self.sameBytes($0.name, name) }) { id = existing.id }
                else {
                    id = UUID()
                    value.tags[id] = SharedLibraryTag(id: id, name: name)
                }
                value.tagAssignments[key, default: []].insert(id)
            }
            value.importedLegacyKeys.insert(key)
        }
    }

    public func createFolder(name: String, parentID: UUID? = nil) throws -> UUID {
        let id = UUID()
        try change { value in
            value.folders[id] = SharedLibraryFolder(id: id, name: try Self.name(name, maximum: 80), parentID: parentID)
        }
        return id
    }

    public func renameFolder(_ id: UUID, to name: String) throws {
        try change { value in
            guard var folder = value.folders[id] else { throw SharedLibraryError.missingFolder }
            folder.name = try Self.name(name, maximum: 80)
            value.folders[id] = folder
        }
    }

    public func moveFolder(_ id: UUID, under parentID: UUID?) throws {
        try change { value in
            guard var folder = value.folders[id] else { throw SharedLibraryError.missingFolder }
            folder.parentID = parentID
            value.folders[id] = folder
        }
    }

    /// Deletes a folder and its descendants as organization only; entries and files remain.
    public func deleteFolder(_ id: UUID) throws {
        try change { value in
            guard value.folders[id] != nil else { throw SharedLibraryError.missingFolder }
            var removed: Set<UUID> = [id]
            var changed = true
            while changed {
                changed = false
                for folder in value.folders.values where !removed.contains(folder.id) {
                    if let parent = folder.parentID, removed.contains(parent) {
                        removed.insert(folder.id); changed = true
                    }
                }
            }
            for folderID in removed { value.folders.removeValue(forKey: folderID) }
        }
    }

    public func addMembers(_ keys: Set<String>, to folderID: UUID) throws {
        try change { value in
            guard value.folders[folderID] != nil else { throw SharedLibraryError.invalidMembership }
            value.folders[folderID]?.memberKeys.formUnion(keys)
        }
    }

    public func removeMembers(_ keys: Set<String>, from folderID: UUID) throws {
        try change { value in
            guard value.folders[folderID] != nil else { throw SharedLibraryError.invalidMembership }
            value.folders[folderID]?.memberKeys.subtract(keys)
        }
    }

    public func createSavedQuery(name: String, query: SharedLibraryQuery) throws -> UUID {
        let id = UUID()
        try change { value in
            value.savedQueries[id] = SharedLibrarySavedQuery(id: id, name: try Self.name(name, maximum: 80), query: query)
        }
        return id
    }

    public func updateSavedQuery(_ id: UUID, name: String, query: SharedLibraryQuery) throws {
        try change { value in
            guard var saved = value.savedQueries[id] else { throw SharedLibraryError.missingQuery }
            saved.name = try Self.name(name, maximum: 80)
            saved.query = query
            value.savedQueries[id] = saved
        }
    }

    public func deleteSavedQuery(_ id: UUID) throws {
        try change { value in
            guard value.savedQueries.removeValue(forKey: id) != nil else { throw SharedLibraryError.missingQuery }
        }
    }

    public func undo() throws {
        guard let prior = undoStack.last else { return }
        try persist(prior)
        undoStack.removeLast(); redoStack.append(metadata)
        if redoStack.count > Self.historyLimit { redoStack.removeFirst() }
        metadata = prior
    }

    public func redo() throws {
        guard let next = redoStack.last else { return }
        try persist(next)
        redoStack.removeLast(); undoStack.append(metadata)
        if undoStack.count > Self.historyLimit { undoStack.removeFirst() }
        metadata = next
    }

    private func change(_ body: (inout SharedLibraryMetadata) throws -> Void) throws {
        var next = metadata
        try body(&next)
        try Self.validate(next)
        guard next != metadata else { return }
        try persist(next)
        undoStack.append(metadata)
        if undoStack.count > Self.historyLimit { undoStack.removeFirst() }
        redoStack.removeAll()
        metadata = next
    }

    private func persist(_ value: SharedLibraryMetadata) throws {
        let data = try JSONEncoder().encode(SharedLibraryEnvelope(schema: 1, metadata: value))
        guard data.count <= 8 * 1_024 * 1_024 else {
            throw SharedLibraryError.limitExceeded("file exceeds 8 MiB")
        }
        guard let fileURL else { return }
        let current = try Self.readDisk(fileURL)
        guard current == diskBaseline else { throw SharedLibraryError.externalChange }
        try data.write(to: fileURL, options: .atomic)
        diskBaseline = data
    }

    private static func readDisk(_ fileURL: URL) throws -> Data? {
        guard fileURL.isFileURL else { throw SharedLibraryError.invalidFileURL }
        do {
            let size = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber
            if let size, size.intValue > 8 * 1_024 * 1_024 {
                throw SharedLibraryError.limitExceeded("file exceeds 8 MiB")
            }
            let data = try Data(contentsOf: fileURL)
            guard data.count <= 8 * 1_024 * 1_024 else {
                throw SharedLibraryError.limitExceeded("file exceeds 8 MiB")
            }
            return data
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain
                && (nsError.code == NSFileReadNoSuchFileError || nsError.code == NSFileNoSuchFileError) {
                return nil
            }
            throw error
        }
    }

    /// Reject schema-1 fields we do not understand, so an edit cannot silently erase them.
    private static func rejectUnknownFields(_ data: Data) throws {
        let rootObject: Any
        do { rootObject = try JSONSerialization.jsonObject(with: data) }
        catch { throw SharedLibraryError.corruptedMetadata(error.localizedDescription) }
        guard let root = rootObject as? [String: Any], let body = root["metadata"] as? [String: Any] else {
            throw SharedLibraryError.corruptedMetadata("invalid envelope")
        }
        try checkFields(root, allowed: ["schema", "metadata"])
        try checkFields(body, allowed: ["tags", "folders", "savedQueries", "tagAssignments", "importedLegacyKeys"])
        if let tags = body["tags"] {
            for tag in try encodedValues(tags) {
                guard let fields = tag as? [String: Any] else { throw SharedLibraryError.corruptedMetadata("invalid tag") }
                try checkFields(fields, allowed: ["id", "name"])
            }
        }
        if let folders = body["folders"] {
            for folder in try encodedValues(folders) {
                guard let fields = folder as? [String: Any] else { throw SharedLibraryError.corruptedMetadata("invalid folder") }
                try checkFields(fields, allowed: ["id", "name", "parentID", "memberKeys"])
            }
        }
        if let savedQueries = body["savedQueries"] {
            for saved in try encodedValues(savedQueries) {
                guard let fields = saved as? [String: Any], let query = fields["query"] as? [String: Any] else {
                    throw SharedLibraryError.corruptedMetadata("invalid saved query")
                }
                try checkFields(fields, allowed: ["id", "name", "query"])
                try checkFields(query, allowed: ["text", "kinds", "roles", "inputs", "outputs",
                                                 "contentKinds", "readiness", "compatibility", "allTagIDs", "anyTagIDs"])
            }
        }
    }

    private static func checkFields(_ object: [String: Any], allowed: Set<String>) throws {
        let unknown = Set(object.keys).subtracting(allowed)
        guard unknown.isEmpty else {
            throw SharedLibraryError.corruptedMetadata("unknown field: \(unknown.sorted().joined(separator: ", "))")
        }
    }

    private static func encodedValues(_ object: Any) throws -> [Any] {
        if let dictionary = object as? [String: Any] { return Array(dictionary.values) }
        if let array = object as? [Any], array.count.isMultiple(of: 2) {
            return stride(from: 1, to: array.count, by: 2).map { array[$0] }
        }
        throw SharedLibraryError.corruptedMetadata("invalid dictionary encoding")
    }

    private static func sameBytes(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.elementsEqual(rhs.utf8)
    }

    private static func name(_ raw: String, maximum: Int) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty && value.count <= maximum else { throw SharedLibraryError.invalidName }
        return value
    }

    private static func validKey(_ key: String) -> Bool {
        !key.isEmpty && key.count <= 512
    }

    private static func validate(_ value: SharedLibraryMetadata) throws {
        var objects = value.tags.count + value.folders.count + value.savedQueries.count
            + value.tagAssignments.count + value.importedLegacyKeys.count
        for ids in value.tagAssignments.values { objects += ids.count }
        for folder in value.folders.values { objects += folder.memberKeys.count }
        for saved in value.savedQueries.values {
            let query = saved.query
            objects += query.kinds.count + query.roles.count + query.inputs.count + query.outputs.count
                + query.contentKinds.count + query.readiness.count + query.compatibility.count
                + query.allTagIDs.count + query.anyTagIDs.count
        }
        guard objects <= 10_000 else { throw SharedLibraryError.limitExceeded("10,000 metadata objects and relations") }
        var tagNames: Set<Data> = []
        for (id, tag) in value.tags {
            guard id == tag.id else { throw SharedLibraryError.corruptedMetadata("tag ID mismatch") }
            guard try sameBytes(name(tag.name, maximum: 32), tag.name) else { throw SharedLibraryError.invalidName }
            guard tagNames.insert(Data(tag.name.utf8)).inserted else { throw SharedLibraryError.duplicateName(tag.name) }
        }
        for (key, ids) in value.tagAssignments {
            guard validKey(key) else { throw SharedLibraryError.invalidKey }
            guard ids.allSatisfy({ value.tags[$0] != nil }) else { throw SharedLibraryError.invalidReference }
        }
        guard value.importedLegacyKeys.allSatisfy(validKey) else { throw SharedLibraryError.invalidKey }
        var folderNames: [UUID?: Set<Data>] = [:]
        for (id, folder) in value.folders {
            guard id == folder.id else { throw SharedLibraryError.corruptedMetadata("folder ID mismatch") }
            guard try sameBytes(name(folder.name, maximum: 80), folder.name) else { throw SharedLibraryError.invalidName }
            // Names are unique within each parent, not across the entire folder tree.
            guard folderNames[folder.parentID, default: []].insert(Data(folder.name.utf8)).inserted else {
                throw SharedLibraryError.duplicateName(folder.name)
            }
            guard folder.memberKeys.allSatisfy(validKey) else { throw SharedLibraryError.invalidKey }
            var ancestor = folder.parentID
            var seen: Set<UUID> = [id]
            var depth = 1
            while let current = ancestor {
                guard seen.insert(current).inserted else { throw SharedLibraryError.folderCycle }
                guard let parent = value.folders[current] else { throw SharedLibraryError.invalidReference }
                depth += 1
                guard depth <= 4 else { throw SharedLibraryError.folderDepth }
                ancestor = parent.parentID
            }
        }
        var queryNames: Set<Data> = []
        for (id, saved) in value.savedQueries {
            guard id == saved.id else { throw SharedLibraryError.corruptedMetadata("query ID mismatch") }
            guard try sameBytes(name(saved.name, maximum: 80), saved.name) else { throw SharedLibraryError.invalidName }
            guard queryNames.insert(Data(saved.name.utf8)).inserted else { throw SharedLibraryError.duplicateName(saved.name) }
            guard saved.query.text.count <= 256 else { throw SharedLibraryError.limitExceeded("query text") }
            let ids = saved.query.allTagIDs.union(saved.query.anyTagIDs)
            guard ids.allSatisfy({ value.tags[$0] != nil }) else { throw SharedLibraryError.invalidReference }
        }
    }
}
