import Foundation
import Testing
@testable import DWorkbench

@Suite("Typed library properties", .serialized) @MainActor
struct SharedLibraryPropertiesTests {
    private func directory() throws -> URL {
        let base = ProcessInfo.processInfo.environment["D_TEST_WORKBENCH_ROOT"] ?? ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? FileManager.default.temporaryDirectory.path
        let url = URL(fileURLWithPath: base).resolvingSymlinksInPath().appendingPathComponent("TypedLibrary-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    @Test func typedRangesScopesAndTagsIntersectWithoutGuessingUnknowns() throws {
        let store = try SharedLibraryStore(), project = UUID(), instance = UUID(), run = UUID(), node = UUID(), step = UUID()
        let tag = try #require(store.createTags(["choice"]).first)
        let parent = WorkflowAssetReference(projectID: project, assetID: UUID(), version: UUID(), kind: .image, sha256: String(repeating: "a", count: 64))
        let model = SharedLibraryModelSource(kind: .recordedIdentity, value: "actual-model", revision: "r1")
        let facts = SharedLibraryAssetFacts(projectID: project, instanceID: instance, note: "specific note", favorite: true,
            width: 2048, height: 1024, registeredAt: Date(timeIntervalSince1970: 100), model: model, parents: [parent],
            occurrences: [.init(runID: run, nodeID: node, stepID: step)])
        let item = SharedLibraryItem(key: "asset", title: "same", kind: .asset, assetFacts: facts)
        try store.addTags([tag], to: [item.key])
        var query = SharedLibraryQuery(text: "specific", allTagIDs: [tag], scope: .init(mode: .run, projectID: project, instanceID: instance, runID: run, nodeID: node, stepID: step),
            properties: .init(favorite: true, width: .init(minimum: 2000, maximum: 2048), height: .init(maximum: 1024), registeredAt: .init(start: Date(timeIntervalSince1970: 90), end: Date(timeIntervalSince1970: 110)), model: model, directParent: parent))
        #expect(store.matches(item, query: query))
        query.properties?.width?.maximum = 2047
        #expect(!store.matches(item, query: query))
        query.properties?.width?.maximum = 2048
        query.properties?.model?.revision = "r2"
        #expect(!store.matches(item, query: query))
        query.properties?.model?.revision = nil
        #expect(store.matches(item, query: query))
        query.scope = .init(mode: .currentProject)
        #expect(!store.matches(item, query: query))
        #expect(store.matches(item, query: query, context: .init(projectID: project, instanceID: instance)))
        #expect(!store.matches(item, query: query, context: .init(projectID: project, instanceID: UUID())))
        // Keep explicit argument types: the testing macro mis-infers nested .init here.
        let unknown = SharedLibraryItem(key: "unknown", title: "same", kind: .asset)
        let widthOnly = SharedLibraryQuery(properties: .init(width: .init(minimum: 1)))
        let unknownMatches = store.matches(unknown, query: widthOnly)
        #expect(unknownMatches == false)
        #expect(throws: SharedLibraryError.invalidProperty) { try SharedLibraryNumberRange(minimum: 0).validate() }
        #expect(throws: SharedLibraryError.invalidProperty) { try SharedLibraryNumberRange(minimum: 5, maximum: 3).validate() }
    }
    @Test func schemaOneUpgradesOnlyOnExplicitWriteWithExactBackupAndTypedColdRead() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("library.json")
        let store = try SharedLibraryStore(fileURL: file)
        let tag = try #require(store.createTags(["legacy"]).first)
        let id = try store.createSavedQuery(name: "old", query: .init(allTagIDs: [tag]))
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        object["schema"] = 1
        var body = try #require(object["metadata"] as? [String: Any]); body.removeValue(forKey: "runtimeAnnotations"); object["metadata"] = body
        let original = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try original.write(to: file)
        let old = try SharedLibraryStore(fileURL: file)
        #expect(old.metadata.savedQueries[id]?.query.scope == nil)
        #expect(!FileManager.default.fileExists(atPath: SharedLibraryStore.schemaOneBackupURL(for: file).path))
        #expect(try Data(contentsOf: file) == original)
        let scope = SharedLibraryQueryScope(mode: .run, projectID: UUID(), instanceID: UUID(), runID: UUID(), nodeID: UUID(), stepID: UUID())
        let query = SharedLibraryQuery(scope: scope, properties: .init(favorite: false, width: .init(minimum: 2048), registeredAt: .init(end: Date(timeIntervalSince1970: 123456)), model: .init(kind: .recordedIdentity, value: "model", revision: "rev")))
        let saved = try old.createSavedQuery(name: "typed", query: query)
        #expect(try Data(contentsOf: SharedLibraryStore.schemaOneBackupURL(for: file)) == original)
        #expect(try SharedLibraryStore(fileURL: file).metadata.savedQueries[saved]?.query == query)
        try old.undo()
        #expect(try SharedLibraryStore(fileURL: file).metadata.savedQueries[saved] == nil)
        try old.redo()
        #expect(try SharedLibraryStore(fileURL: file).metadata.savedQueries[saved]?.query == query)
        #expect(try Data(contentsOf: SharedLibraryStore.schemaOneBackupURL(for: file)) == original)
    }
    @Test func unknownNestedPropertiesAndBackupFailureNeverOverwrite() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("library.json")
        let store = try SharedLibraryStore(fileURL: file)
        _ = try store.createSavedQuery(name: "query", query: .init(properties: .init(width: .init(minimum: 1))))
        let bytes = try Data(contentsOf: file)
        let string = try #require(String(data: bytes, encoding: .utf8)).replacingOccurrences(of: "\"minimum\":1", with: "\"minimum\":1,\"unknown\":42")
        try Data(string.utf8).write(to: file)
        #expect(throws: SharedLibraryError.self) { _ = try SharedLibraryStore(fileURL: file) }
        #expect(try Data(contentsOf: file) == Data(string.utf8))
        let fresh = dir.appendingPathComponent("old.json")
        let legacy = Data(#"{"schema":1,"metadata":{"tags":[],"folders":[],"savedQueries":[],"tagAssignments":{},"importedLegacyKeys":[]}}"#.utf8)
        try legacy.write(to: fresh)
        let old = try SharedLibraryStore(fileURL: fresh)
        try Data("unrelated backup".utf8).write(to: SharedLibraryStore.schemaOneBackupURL(for: fresh))
        #expect(throws: SharedLibraryError.externalChange) { try old.createTags(["change"]) }
        #expect(old.metadata.tags.isEmpty && !old.canUndo)
        #expect(try Data(contentsOf: fresh) == legacy)
    }
    @Test func savedExactModelBytesAndDynamicScopeSurviveUpdates() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("library.json"), a = UUID(), b = UUID()
        let store = try SharedLibraryStore(fileURL: file)
        let composed = SharedLibraryModelSource(kind: .recordedIdentity, value: "é", revision: "é")
        let decomposed = SharedLibraryModelSource(kind: .recordedIdentity, value: "e\u{301}", revision: "e\u{301}")
        #expect(composed != decomposed && Set([composed, decomposed]).count == 2)
        let id = try store.createSavedQuery(name: "exact", query: .init(properties: .init(model: composed)))
        try store.updateSavedQuery(id, name: "exact", query: .init(properties: .init(model: decomposed)))
        let reopened = try SharedLibraryStore(fileURL: file)
        #expect(reopened.metadata.savedQueries[id]?.query.properties?.model == decomposed)
        let dynamic = try reopened.createSavedQuery(name: "dynamic", query: .init(scope: .init(mode: .currentProject)))
        let items = [a, b].map { id in SharedLibraryItem(key: id.uuidString, title: "same", kind: .asset,
            assetFacts: .init(projectID: id, instanceID: id, registeredAt: Date())) }
        #expect(try reopened.filter(items, savedQueryID: dynamic, context: .init(projectID: a, instanceID: a)).map(\.key) == [a.uuidString])
        #expect(try reopened.filter(items, savedQueryID: dynamic, context: .init(projectID: b, instanceID: b)).map(\.key) == [b.uuidString])
        #expect(try reopened.filter(items, savedQueryID: dynamic).isEmpty)
    }
    @Test func exactReferenceKeepsCollectionAttemptAndPassthroughOccurrences() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = try await ProjectStore.create(at: dir.appendingPathComponent("Test.dproject"), name: "source")
        let attempt = UUID()
        let asset = try await store.publishWorkflowAsset(data: Data("record".utf8), mediaType: "text/plain", name: "candidate", operationID: "d.text.input", stepID: attempt)
        let node = WorkflowNode(operationID: "d.text.input", title: "source", parameters: ["text": .text("record")])
        let graph = WorkflowGraph(nodes: [node])
        let candidate = WorkflowCandidate(attemptID: attempt, asset: asset.record.reference, seed: "1")
        let first = WorkflowStepRun(node: node, signature: "fixture", outputs: ["output": .collection([candidate])], status: .completed)
        let second = WorkflowStepRun(node: node, signature: "fixture", outputs: ["output": .asset(asset.record.reference)], status: .completed)
        let runs = [first, second].map { WorkflowRun(graph: graph, targetNodeID: node.id, steps: [$0], status: .completed) }
        let archive = try #require(try await store.workflowState().archive)
        _ = try await store.saveWorkflow(graphs: [graph], runs: runs, expectedRevision: archive.revision)
        let metadata = try await store.assetMetadataSnapshot(id: asset.asset.id, reference: asset.record.reference)
        #expect(Set(metadata.occurrences?.map(\.stepID) ?? []) == [first.id, second.id])
        #expect(Set(metadata.occurrences?.map(\.runID) ?? []) == Set(runs.map(\.id)))
        #expect(metadata.record?.stepID == attempt)
        try await store.close()
    }
    @Test func annotationCASIsFieldSpecificAndReadProjectionNeverPinsOrChangesMedia() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = ProjectFixture(directory: dir)
        let store = try await ProjectStore.create(at: fixture.project, name: "annotations")
        let published = try await store.publishWorkflowAsset(data: Data("original content".utf8), mediaType: "text/plain", name: "original", operationID: "d.text.input")
        let original = await store.snapshot(), asset = published.asset
        let baseline = ProjectAssetEditBaseline(project: original, asset: asset)
        let manifestFile = fixture.project.appendingPathComponent(ProjectStore.manifestFilename)
        let bytes = try Data(contentsOf: manifestFile)
        let snapshot = try await store.assetMetadataSnapshot(id: asset.id, reference: published.record.reference)
        #expect(snapshot.record?.reference == published.record.reference)
        #expect(snapshot.facts.width == nil && snapshot.request == nil)
        #expect(try Data(contentsOf: manifestFile) == bytes)
        _ = try await store.updateAsset(id: asset.id, isFavorite: true, expected: baseline)
        let updated = try await store.updateAsset(id: asset.id, note: "new note", expected: baseline)
        #expect(updated.assets.first?.isFavorite == true && updated.assets.first?.note == "new note")
        await #expect(throws: WorkflowIssue.self) { try await store.updateAsset(id: asset.id, note: "stale", expected: baseline) }
        #expect(try await store.workflowData(published.record.reference) == Data("original content".utf8))
        #expect(try await store.assetMetadataSnapshot(id: asset.id).record == snapshot.record)
        try await store.close()
        let reopened = try await ProjectStore.open(at: fixture.project)
        let cold = try await reopened.assetMetadataSnapshot(id: asset.id)
        #expect(cold.asset.note == "new note" && cold.asset.isFavorite)
        #expect(cold.record == snapshot.record)
        #expect(try await reopened.workflowData(published.record.reference) == Data("original content".utf8))
        try await reopened.close()
    }
}
