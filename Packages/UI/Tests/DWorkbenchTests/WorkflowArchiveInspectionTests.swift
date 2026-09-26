import Foundation
import Testing
@testable import DWorkbench

@Suite("Workflow language format protection")
struct WorkflowArchiveInspectionTests {
    @Test @MainActor func storeRebuildsCheckpointAndRejectsUnpublishedNestedReferences() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent("checked-workflow-" + UUID().uuidString + ".dproject")
        let store = try await ProjectStore.create(at: root, name: "checked")
        var node = try #require(WorkflowRegistry.standard.operation("d.value.input")).definition.makeNode()
        node.dataConfiguration = .init(value: .number(2, unit: nil))
        let graph = WorkflowGraph(nodes: [node])
        let plan = try WorkflowPlanCompiler().compile(graph, target: node.id)
        let executor = WorkflowPlanExecutor(executeCall: { context in
            .outputs(["output": .data(try #require(context.node.dataConfiguration?.value))])
        }, save: { _ in })
        let checkpoint = try await executor.execute(.init(plan: plan))
        var run = WorkflowRun(id: checkpoint.runID, graph: graph, targetNodeID: node.id,
            steps: checkpoint.records.map(\.step), status: .completed)
        run.planCheckpoint = checkpoint
        var archive = try #require(try await store.workflowState().archive)
        archive = try await store.saveWorkflow(graphs: [graph], runs: [run], expectedRevision: archive.revision)
        var forged = run
        forged.planCheckpoint?.plan.steps[0].node.dataConfiguration?.value = .number(99, unit: nil)
        await #expect(throws: (any Error).self) { _ = try await store.saveWorkflow(graphs: [graph], runs: [forged], expectedRevision: archive.revision) }
        #expect(try await store.workflowState().archive == archive)
        let unknown = WorkflowAssetReference(projectID: await store.snapshot().id, assetID: UUID(), version: UUID(), kind: .image, sha256: String(repeating: "a", count: 64))
        node.dataConfiguration = .init(value: .asset(unknown))
        var parent = try #require(WorkflowRegistry.standard.operation("d.control.map")).definition.makeNode()
        parent.control = .map(body: .init(nodes: [node]), continueOnFailure: false)
        await #expect(throws: (any Error).self) { _ = try await store.saveWorkflow(graphs: [.init(nodes: [parent])], runs: [run], expectedRevision: archive.revision) }
        #expect(try await store.workflowState().archive == archive)
        try await store.close()
        let reopened = try await ProjectStore.open(at: root)
        #expect(try await reopened.workflowState().archive == archive)
        try await reopened.close()
    }

    @Test @MainActor func oldValidationNodeWithoutListCountRetainsParametersAcrossStoreReopen() async throws {
        let registry = WorkflowRegistry.standard
        var input = try #require(registry.operation("d.value.input")).definition.makeNode()
        input.dataConfiguration = .init(value: .list(element: .text, items: [.init(id: "一", value: .text("旧内容 👩🏽‍🎨"))]))
        var validation = try #require(registry.operation("d.value.validate")).definition.makeNode()
        validation.parameters.removeValue(forKey: "expectedItemCount")
        validation.dataConfiguration = .init(schema: .list(.text))
        let oldParameters = validation.parameters
        #expect(oldParameters == ["strict": .flag(false)])
        let graph = WorkflowGraph(nodes: [input, validation], connections: [.init(sourceNode: input.id, targetNode: validation.id, targetPort: "input")])
        try registry.validate(graph)
        let signature = try registry.signature(validation.id, in: graph)
        let plan = try WorkflowPlanCompiler().compile(graph, target: validation.id)
        #expect(plan.steps.last?.node.parameters == oldParameters)
        var invalid = validation
        invalid.parameters.removeValue(forKey: "strict")
        #expect(throws: WorkflowIssue.self) { try registry.validate(invalid) }
        invalid = validation
        invalid.parameters["expectedItemCount"] = .flag(true)
        #expect(throws: WorkflowIssue.self) { try registry.validate(invalid) }

        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent("legacy-validation-" + UUID().uuidString + ".dproject")
        let store = try await ProjectStore.create(at: root, name: "旧校验节点")
        let revision = try #require(try await store.workflowState().archive).revision
        let saved = try await store.saveWorkflow(graphs: [graph], runs: [], expectedRevision: revision)
        try await store.close()
        let reopened = try await ProjectStore.open(at: root)
        let loaded = try #require(try await reopened.workflowState().archive)
        #expect(loaded == saved)
        let restored = try #require(loaded.graphs.first)
        #expect(restored.nodes.last?.parameters == oldParameters)
        #expect(try registry.signature(validation.id, in: restored) == signature)
        #expect(try WorkflowPlanCompiler().compile(restored, target: validation.id) == plan)
        try await reopened.close()
    }

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
        step.humanTask = nil
        step.node.dataConfiguration = .init(value: .text("frozen"))
        archive.runs[0].steps = [step]
        #expect(archive.requiresLanguageVersion)
        #expect(throws: WorkflowIssue.self) { try WorkflowArchiveInspection.validateStructure(archive) }
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
