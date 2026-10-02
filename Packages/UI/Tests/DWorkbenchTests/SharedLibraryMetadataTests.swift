import Foundation
import Testing
@testable import DWorkbench

@Suite("Shared library metadata", .serialized)
@MainActor
struct SharedLibraryMetadataTests {
    @Test func representativeIndexObservations() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("metadata.json")
        let store = try SharedLibraryStore(fileURL: file)
        let tags = try store.createTags(["index", "edited"])
        let entries = (0..<1_000).map { item("asset-\($0)", kind: .asset, contentKind: .image) }
        try store.addTags([tags[0]], to: Set(entries.map(\.key)))
        let start = Date()
        let opened = try SharedLibraryStore(fileURL: file)
        let openSeconds = Date().timeIntervalSince(start)
        let before = try Data(contentsOf: file)
        let queryStart = Date()
        for _ in 0..<20 {
            #expect(opened.filter(entries, query: .init(allTagIDs: [tags[0]])).count == entries.count)
        }
        let querySeconds = Date().timeIntervalSince(queryStart)
        #expect(try Data(contentsOf: file) == before)
        let saveStart = Date()
        try opened.addTags([tags[1]], to: Set(entries.prefix(100).map(\.key)))
        let saveSeconds = Date().timeIntervalSince(saveStart)
        let reopened = try SharedLibraryStore(fileURL: file)
        #expect(reopened.filter(entries, query: .init(allTagIDs: [tags[1]])).count == 100)
        print("D_INDEX_OBSERVATION entries", entries.count, "bytes", before.count,
              "open", openSeconds, "queries20", querySeconds, "tagSave100", saveSeconds)
    }

    private func item(_ key: String, kind: SharedLibraryItemKind = .model,
                      inputs: Set<WorkflowDataKind> = [], outputs: Set<WorkflowDataKind> = [],
                      contentKind: WorkflowDataKind? = nil,
                      readiness: SharedLibraryReadiness = .unknown,
                      compatible: Bool? = nil) -> SharedLibraryItem {
        SharedLibraryItem(key: key, title: key, detail: "detail", kind: kind,
                          role: "creator", inputs: inputs, outputs: outputs,
                          contentKind: contentKind, readiness: readiness, compatible: compatible)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SharedLibraryMetadata-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func directionAndDimensionSemantics() throws {
        let store = try SharedLibraryStore()
        let inputOnly = item("input-video", inputs: [.video], readiness: .available)
        let outputVideo = item("output-video", outputs: [.video], readiness: .available, compatible: true)
        let outputAudio = item("output-audio", outputs: [.audio], readiness: .unprepared)
        let unknown = item("unknown", outputs: [], readiness: .unknown)
        let asset = item("projectUUID:assetUUID", kind: .asset, contentKind: .video)
        var query = SharedLibraryQuery(outputs: [.video, .audio], readiness: [.available])
        #expect(store.filter([inputOnly, outputVideo, outputAudio, unknown, asset], query: query).map(\.key) == ["output-video"])
        query = SharedLibraryQuery(inputs: [.video], outputs: [.audio])
        #expect(store.filter([inputOnly, outputVideo, outputAudio], query: query).isEmpty)
        query = SharedLibraryQuery(contentKinds: [.video], compatibility: [.unknown])
        #expect(store.filter([asset, outputVideo], query: query).map(\.key) == [asset.key])
        query = SharedLibraryQuery(readiness: [.available], compatibility: [.unknown])
        #expect(store.filter([inputOnly, outputVideo, unknown], query: query).map(\.key) == [inputOnly.key])
    }

    @Test func tagsSearchAcrossKindsWithoutChangingSystemCapability() throws {
        let store = try SharedLibraryStore()
        let decomposed = "e\u{301}"
        let tag = try #require(store.createTags([decomposed]).first)
        try store.addTags([tag], to: ["model", "tool", "asset"])
        let entries = [item("model", outputs: [.text]), item("tool", kind: .tool),
                       item("asset", kind: .asset, contentKind: .video)]
        #expect(store.filter(entries, query: SharedLibraryQuery(allTagIDs: [tag])).count == 3)
        #expect(store.filter(entries, query: SharedLibraryQuery(text: "e\u{301} detail")).count == 3)
        #expect(store.filter(entries, query: SharedLibraryQuery(outputs: [.video])).isEmpty)
        #expect(Array(try #require(store.metadata.tags[tag]?.name).utf8) == Array(decomposed.utf8))
        #expect(throws: SharedLibraryError.duplicateName(decomposed)) { try store.createTags([decomposed]) }
    }

    @Test func batchUndoRedoAndStableQueryReference() throws {
        let store = try SharedLibraryStore()
        let ids = try store.createTags(["portrait", "studio"])
        try store.addTags(Set(ids), to: ["model", "asset"])
        #expect(store.metadata.tagAssignments.count == 2)
        try store.undo()
        #expect(store.metadata.tagAssignments.isEmpty)
        try store.redo()
        #expect(store.metadata.tagAssignments["asset"] == Set(ids))
        let queryID = try store.createSavedQuery(name: "selected", query: SharedLibraryQuery(allTagIDs: [ids[0]]))
        try store.renameTags([ids[0]: "renamed"])
        #expect(store.metadata.savedQueries[queryID]?.query.allTagIDs == [ids[0]])
        #expect(try store.filter([item("model")], savedQueryID: queryID).count == 1)
        #expect(throws: SharedLibraryError.tagInSavedQuery) { try store.deleteTags([ids[0]]) }
        try store.deleteSavedQuery(queryID)
        try store.deleteTags([ids[0]])
        #expect(store.metadata.tagAssignments["model"] == [ids[1]])
        try store.undo()
        #expect(store.metadata.tagAssignments["model"] == Set(ids))
    }

    @Test func foldersAllowMultipleMembershipAndRejectCyclesAndDepth() throws {
        let store = try SharedLibraryStore()
        let a = try store.createFolder(name: "a")
        let b = try store.createFolder(name: "b")
        try store.addMembers(["model"], to: a)
        try store.addMembers(["model"], to: b)
        try store.deleteFolder(a)
        #expect(store.metadata.folders[b]?.memberKeys == ["model"])
        #expect(store.metadata.folders[a] == nil)
        #expect(throws: SharedLibraryError.folderCycle) { try store.moveFolder(b, under: b) }
        let c = try store.createFolder(name: "c", parentID: b)
        let d = try store.createFolder(name: "d", parentID: c)
        let e = try store.createFolder(name: "e", parentID: d)
        #expect(throws: SharedLibraryError.folderDepth) { _ = try store.createFolder(name: "f", parentID: e) }
        #expect(throws: SharedLibraryError.invalidMembership) { try store.addMembers(["model"], to: UUID()) }
        #expect(store.metadata.folders[b]?.memberKeys == ["model"])
    }

    @Test func savedQueryIsDynamicAndCannotAcceptManualMembership() throws {
        let store = try SharedLibraryStore()
        let tag = try #require(store.createTags(["fresh"]).first)
        let smart = try store.createSavedQuery(name: "tagged", query: SharedLibraryQuery(allTagIDs: [tag]))
        let entries = [item("first"), item("second")]
        #expect(try store.filter(entries, savedQueryID: smart).isEmpty)
        try store.addTags([tag], to: ["second"])
        #expect(try store.filter(entries, savedQueryID: smart).map(\.key) == ["second"])
        #expect(throws: SharedLibraryError.invalidMembership) { try store.addMembers(["first"], to: smart) }
    }

    @Test func persistenceAndDamageNeverBecomeEditableEmpty() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("library.json")
        let store = try SharedLibraryStore(fileURL: file)
        let tag = try #require(store.createTags(["saved"]).first)
        try store.addTags([tag], to: ["projectUUID:assetUUID"])
        let reopened = try SharedLibraryStore(fileURL: file)
        #expect(reopened.metadata.tagAssignments["projectUUID:assetUUID"] == [tag])
        let good = try Data(contentsOf: file)

        try Data("broken".utf8).write(to: file)
        #expect(throws: SharedLibraryError.self) { _ = try SharedLibraryStore(fileURL: file) }
        #expect(try Data(contentsOf: file) == Data("broken".utf8))
        try Data(#"{"schema":2,"metadata":{}}"#.utf8).write(to: file)
        #expect(throws: SharedLibraryError.unsupportedSchema(2)) { _ = try SharedLibraryStore(fileURL: file) }
        try good.write(to: file)
        #expect(try SharedLibraryStore(fileURL: file).metadata.tags[tag]?.name == "saved")
        let directoryAsFile = directory.appendingPathComponent("not-a-file")
        try FileManager.default.createDirectory(at: directoryAsFile, withIntermediateDirectories: false)
        #expect(throws: Error.self) { _ = try SharedLibraryStore(fileURL: directoryAsFile) }
    }

    @Test func failedWriteKeepsMemoryHistoryAndPriorFile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = directory.appendingPathComponent("active")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let file = folder.appendingPathComponent("library.json")
        let store = try SharedLibraryStore(fileURL: file)
        _ = try store.createTags(["before"])
        let prior = store.metadata
        let priorFile = try Data(contentsOf: file)
        let moved = directory.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: folder, to: moved)
        #expect(throws: Error.self) { _ = try store.createTags(["after"]) }
        #expect(store.metadata == prior)
        #expect(try Data(contentsOf: moved.appendingPathComponent("library.json")) == priorFile)
        #expect(throws: Error.self) { try store.undo() }
        #expect(store.metadata == prior)
        try FileManager.default.moveItem(at: moved, to: folder)
        try store.undo()
        #expect(store.metadata.tags.isEmpty)
    }

    @Test func legacyImportIsOnceOnlyAndInvalidInputCannotOverwrite() throws {
        let store = try SharedLibraryStore()
        let key = "projectUUID:assetUUID"
        #expect(throws: SharedLibraryError.invalidName) {
            try store.importLegacyTags(["good", "  "], for: key)
        }
        #expect(store.metadata.tags.isEmpty)
        #expect(!store.metadata.importedLegacyKeys.contains(key))
        let original = "e\u{301}"
        try store.importLegacyTags([original], for: key)
        let id = try #require(store.metadata.tagAssignments[key]?.first)
        try store.removeTags([id], from: [key])
        try store.importLegacyTags([original], for: key)
        #expect(store.metadata.tagAssignments[key] == nil)
        #expect(Array(try #require(store.metadata.tags[id]?.name).utf8) == Array(original.utf8))
    }

    @Test func twoOpenStoresRejectNewFileAndExternalUpdates() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("shared.json")
        let first = try SharedLibraryStore(fileURL: file)
        let second = try SharedLibraryStore(fileURL: file)
        _ = try first.createTags(["first"])
        let firstBytes = try Data(contentsOf: file)
        #expect(throws: SharedLibraryError.externalChange) { _ = try second.createTags(["lost"]) }
        #expect(second.metadata.tags.isEmpty)
        #expect(!second.canUndo)
        #expect(try Data(contentsOf: file) == firstBytes)

        let refreshed = try SharedLibraryStore(fileURL: file)
        _ = try refreshed.createTags(["second"])
        let secondBytes = try Data(contentsOf: file)
        #expect(throws: SharedLibraryError.externalChange) { _ = try first.createTags(["stale"]) }
        #expect(first.metadata.tags.count == 1)
        #expect(try Data(contentsOf: file) == secondBytes)

        try Data("broken".utf8).write(to: file)
        #expect(throws: SharedLibraryError.externalChange) { try refreshed.undo() }
        #expect(refreshed.metadata.tags.count == 2)
        #expect(refreshed.canUndo)
        #expect(try Data(contentsOf: file) == Data("broken".utf8))
        try Data(#"{"schema":2,"metadata":{}}"#.utf8).write(to: file)
        #expect(throws: SharedLibraryError.externalChange) { _ = try refreshed.createTags(["still-stale"]) }
        #expect(try Data(contentsOf: file) == Data(#"{"schema":2,"metadata":{}}"#.utf8))
    }

    @Test func missingFileAfterOpenAndRedoFailureRetainHistory() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = directory.appendingPathComponent("active")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let file = folder.appendingPathComponent("library.json")
        let store = try SharedLibraryStore(fileURL: file)
        _ = try store.createTags(["before"])
        _ = try store.createTags(["after"])
        try store.undo()
        let beforeRedo = store.metadata
        let moved = directory.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: folder, to: moved)
        #expect(throws: SharedLibraryError.externalChange) { try store.redo() }
        #expect(store.metadata == beforeRedo)
        #expect(store.canRedo)
        try FileManager.default.moveItem(at: moved, to: folder)
        try store.redo()
        #expect(store.metadata.tags.count == 2)
        try FileManager.default.removeItem(at: file)
        #expect(throws: SharedLibraryError.externalChange) { try store.undo() }
        #expect(store.metadata.tags.count == 2)
        #expect(store.canUndo)
    }

    @Test func distinctUnicodeBytesSurviveRenameImportAndReopen() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("unicode.json")
        let store = try SharedLibraryStore(fileURL: file)
        let composed = "é"
        let decomposed = "e\u{301}"
        let identity = UUID()
        #expect(SharedLibraryTag(id: identity, name: composed) != SharedLibraryTag(id: identity, name: decomposed))
        let tag = try #require(store.createTags([composed]).first)
        try store.renameTags([tag: decomposed])
        #expect(Array(try #require(store.metadata.tags[tag]?.name).utf8) == Array(decomposed.utf8))
        try store.undo()
        #expect(Array(try #require(store.metadata.tags[tag]?.name).utf8) == Array(composed.utf8))
        try store.redo()
        let other = try #require(store.createTags([composed]).first)
        #expect(tag != other)
        try store.importLegacyTags([composed, decomposed], for: "projectUUID:assetUUID")
        #expect(store.metadata.tagAssignments["projectUUID:assetUUID"] == [tag, other])
        let query = try store.createSavedQuery(name: "café", query: SharedLibraryQuery(text: composed))
        try store.updateSavedQuery(query, name: "cafe\u{301}", query: SharedLibraryQuery(text: decomposed))
        let reopened = try SharedLibraryStore(fileURL: file)
        #expect(Array(try #require(reopened.metadata.tags[tag]?.name).utf8) == Array(decomposed.utf8))
        #expect(Array(try #require(reopened.metadata.tags[other]?.name).utf8) == Array(composed.utf8))
        #expect(Array(try #require(reopened.metadata.savedQueries[query]?.name).utf8) == Array("cafe\u{301}".utf8))
        #expect(Array(try #require(reopened.metadata.savedQueries[query]?.query.text).utf8) == Array(decomposed.utf8))
    }

    @Test func fileURLAndUnknownSchemaOneFieldsAreRejected() throws {
        let remote = try #require(URL(string: "https://example.invalid/library.json"))
        #expect(throws: SharedLibraryError.invalidFileURL) { _ = try SharedLibraryStore(fileURL: remote) }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("strict.json")
        let store = try SharedLibraryStore(fileURL: file)
        _ = try store.createTags(["saved"])
        let original = try Data(contentsOf: file)
        var root = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        var body = try #require(root["metadata"] as? [String: Any])
        body["futureField"] = "do not discard"
        root["metadata"] = body
        let unknown = try JSONSerialization.data(withJSONObject: root)
        try unknown.write(to: file)
        #expect(throws: SharedLibraryError.self) { _ = try SharedLibraryStore(fileURL: file) }
        #expect(try Data(contentsOf: file) == unknown)
        #expect(throws: SharedLibraryError.externalChange) { _ = try store.createTags(["later"]) }
        #expect(try Data(contentsOf: file) == unknown)
    }

    @Test func aggregateRelationsMemoryFileSizeAndHistoryAreBounded() throws {
        let store = try SharedLibraryStore()
        let folder = try store.createFolder(name: "many")
        let members = Set((0..<10_000).map { "key-\($0)" })
        #expect(throws: SharedLibraryError.self) { try store.addMembers(members, to: folder) }
        #expect(store.metadata.folders[folder]?.memberKeys.isEmpty == true)
        let roles = Set((0..<10_000).map { "role-\($0)" })
        #expect(throws: SharedLibraryError.self) {
            _ = try store.createSavedQuery(name: "huge", query: SharedLibraryQuery(roles: roles))
        }
        #expect(store.metadata.savedQueries.isEmpty)

        let fileSizeStore = try SharedLibraryStore()
        let tag = try #require(fileSizeStore.createTags(["size"]).first)
        let largeKeys = Set((0..<4_300).map { "k\($0)" + String(repeating: "😀", count: 506) })
        #expect(throws: SharedLibraryError.self) { try fileSizeStore.addTags([tag], to: largeKeys) }
        #expect(fileSizeStore.metadata.tagAssignments.isEmpty)
        for index in 0..<55 { _ = try store.createTags(["history-\(index)"]) }
        for _ in 0..<SharedLibraryStore.historyLimit { try store.undo() }
        #expect(!store.canUndo)
        #expect(store.metadata.tags.count == 5)
    }

    @Test func movingParentCannotMakeDescendantTooDeep() throws {
        let store = try SharedLibraryStore()
        let root = try store.createFolder(name: "root")
        let child = try store.createFolder(name: "child", parentID: root)
        let grandchild = try store.createFolder(name: "grandchild", parentID: child)
        let leaf = try store.createFolder(name: "leaf", parentID: grandchild)
        let anotherRoot = try store.createFolder(name: "another root")
        #expect(throws: SharedLibraryError.folderDepth) { try store.moveFolder(root, under: anotherRoot) }
        #expect(store.metadata.folders[root]?.parentID == nil)
        #expect(store.metadata.folders[leaf]?.parentID == grandchild)
    }
}
