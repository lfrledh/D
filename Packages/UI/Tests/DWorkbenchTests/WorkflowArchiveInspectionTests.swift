import Foundation
import Testing
@testable import DWorkbench

@Suite("Workflow language format protection")
struct WorkflowArchiveInspectionTests {
    @Test func unknownKeysSurviveAsReadOnlyDetection() throws {
        var archive = WorkflowArchive(graphs: [.init(name: "中文")])
        let encoded = try JSONEncoder().encode(archive)
        #expect(try !WorkflowArchiveInspection.containsUnknownFields(original: encoded, decoded: archive))
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var graphs = try #require(object["graphs"] as? [[String: Any]])
        graphs[0]["futurePortSemantics"] = ["retain": true]
        object["graphs"] = graphs
        let future = try JSONSerialization.data(withJSONObject: object)
        archive = try JSONDecoder().decode(WorkflowArchive.self, from: future)
        #expect(try WorkflowArchiveInspection.containsUnknownFields(original: future, decoded: archive))
    }

    @Test func emptyContainersDoNotBypassTypeValidation() throws {
        let bad = WorkflowDataSchema.record([.init("same", .text), .init("same", .boolean)])
        #expect(throws: WorkflowIssue.self) { try WorkflowDatum.list(element: bad, items: []).validate() }
        #expect(throws: WorkflowIssue.self) { try WorkflowDatum.none(.enumeration([])).validate() }
        try WorkflowDatum.none(.text).validate(as: .optional(.optional(.text)))
        #expect(throws: WorkflowIssue.self) { try WorkflowDatum.none(.boolean).validate(as: .optional(.optional(.text))) }
        #expect(throws: WorkflowIssue.self) { try WorkflowDatum.result(.init(status: .failed, expected: bad)).validate() }
    }

    @Test func newStructuresRequireNewArchiveVersion() throws {
        var graph = WorkflowGraph(name: "structure")
        graph.interface = .init()
        var archive = WorkflowArchive(graphs: [graph])
        #expect(throws: WorkflowIssue.self) { try WorkflowArchiveInspection.validateStructure(archive) }
        archive.version = 2
        try WorkflowArchiveInspection.validateStructure(archive)
        #expect(ProjectManifest.readableSchemaVersions.contains(16))
        #expect(ProjectManifest.readableSchemaVersions.contains(17))
        for version in 13...15 { #expect(!ProjectManifest.readableSchemaVersions.contains(version)) }
    }

    @Test func humanWaitAndDataResultsCannotMasqueradeAsV1() throws {
        let node = WorkflowNode(operationID: "d.text.input", title: "old compatible operation")
        let graph = WorkflowGraph(nodes: [node])
        var step = WorkflowStepRun(node: node, signature: "fixture")
        step.outputs = ["output": .data(.text("new typed result"))]
        var archive = WorkflowArchive(runs: [.init(graph: graph, targetNodeID: node.id, steps: [step])])
        #expect(archive.requiresLanguageVersion)
        step.outputs = [:]
        step.humanTask = .init(id: step.id, kind: .approve, title: "explicit wait", materials: .text("check"), resultSchema: .boolean)
        archive.runs[0].steps = [step]
        #expect(archive.requiresLanguageVersion)
    }

    @Test func schema16MigrationBacksUpManifestWithoutChangingSnapshot() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent("workflow-v16-" + UUID().uuidString + ".dproject")
        let store = try await ProjectStore.create(at: root, name: "Legacy")
        var archive = try #require(try await store.workflowState().archive)
        archive = try await store.saveWorkflow(graphs: [], runs: [], expectedRevision: archive.revision)
        let pointer = try #require(await store.snapshot().workflowSnapshot)
        try await store.close()
        let manifestURL = root.appendingPathComponent(ProjectStore.manifestFilename)
        var manifest = try JSONDecoder().decode(ProjectManifest.self, from: Data(contentsOf: manifestURL))
        manifest.schemaVersion = 16
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .deferredToDate
        let prior = try encoder.encode(manifest)
        try prior.write(to: manifestURL)
        let snapshot = try Data(contentsOf: root.appendingPathComponent(pointer.relativePath))
        let reopened = try await ProjectStore.open(at: root)
        #expect(await reopened.snapshot().schemaVersion == 17)
        #expect(try Data(contentsOf: root.appendingPathComponent("project.v16.backup.json")) == prior)
        #expect(try Data(contentsOf: root.appendingPathComponent(pointer.relativePath)) == snapshot)
        #expect(try await reopened.workflowState().archive == archive)
        try await reopened.close()
    }
}
