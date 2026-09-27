import Foundation
import Testing
@testable import DWorkbench

@Suite("Validated workflow reads")
struct WorkflowValidatedReadTests {
    private func fixture() async throws -> (ProjectStore, WorkflowArchive) {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent("validated-read-\(UUID()).dproject")
        let store = try await ProjectStore.create(at: root, name: "读取保护")
        var input = try #require(WorkflowRegistry.standard.operation("d.value.input")).definition.makeNode()
        input.dataConfiguration = .init(value: .text("中文 e\u{301} 👩🏽‍🎨"))
        let revision = try #require(try await store.workflowState().archive).revision
        let archive = try await store.saveWorkflow(graphs: [.init(nodes: [input])], runs: [], expectedRevision: revision)
        #expect(try await store.workflowState().archive == archive)
        #expect(try await store.workflowState().archive == archive)
        return (store, archive)
    }

    @Test func immediatePostSaveCacheStillRejectsChangedSnapshotBeforeWarmRead() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent("validated-immediate-\(UUID()).dproject")
        let store = try await ProjectStore.create(at: root, name: "立即读取保护")
        let revision = try #require(try await store.workflowState().archive).revision
        var input = try #require(WorkflowRegistry.standard.operation("d.value.input")).definition.makeNode()
        input.dataConfiguration = .init(value: .text("提交后 e\u{301} 👩🏽‍🎨"))
        let saved = try await store.saveWorkflow(graphs: [.init(nodes: [input])], runs: [], expectedRevision: revision)

        // Do not warm workflowState after save. The Store now owns a post-commit validation cache.
        let pointer = try #require(await store.snapshot().workflowSnapshot)
        let snapshot = store.rootURL.appendingPathComponent(pointer.relativePath)
        let manifest = store.rootURL.appendingPathComponent("project.json")
        let manifestBytes = try Data(contentsOf: manifest)
        var altered = try Data(contentsOf: snapshot)
        altered[altered.startIndex] = altered[altered.startIndex] == 123 ? 91 : 123
        try altered.write(to: snapshot)

        await #expect(throws: (any Error).self) { _ = try await store.workflowState() }
        await #expect(throws: (any Error).self) {
            _ = try await store.saveWorkflow(
                graphs: saved.graphs, runs: saved.runs, expectedRevision: saved.revision, tools: saved.tools
            )
        }
        #expect(try Data(contentsOf: manifest) == manifestBytes)
        #expect(try Data(contentsOf: snapshot) == altered)
        try await store.close()
    }

    @Test @MainActor func postCommitCachePreservesExactUnicodeOptionalRecordAndNestedControl() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent("validated-unicode-\(UUID()).dproject")
        let store = try await ProjectStore.create(at: root, name: "精确往返")
        let exact = "中文 e\u{301} 👩🏽‍🎨 \u{1F1EF}\u{1F1F5}"
        let outerTitle = "外层：\(exact)"
        let leafFieldName = "叶值 e\u{301}"
        let fields: [WorkflowRecordField] = [
            .init(leafFieldName, .text),
            .init("可选 e\u{301}", .optional(.text), required: false),
        ]
        let value = WorkflowDatum.record(schema: fields, fields: [
            leafFieldName: .text(exact),
            "可选 e\u{301}": .none(.text),
        ])
        func input(_ title: String) throws -> WorkflowNode {
            var node = try #require(WorkflowRegistry.standard.operation("d.value.input")).definition.makeNode()
            node.title = title
            node.dataConfiguration = .init(value: value)
            return node
        }
        func branch(_ title: String, then yes: WorkflowGraph, otherwise no: WorkflowGraph) throws -> WorkflowNode {
            var node = try #require(WorkflowRegistry.standard.operation("d.control.branch")).definition.makeNode()
            node.title = title
            node.control = .branch(predicate: .init(comparison: .exists), then: yes, otherwise: no)
            return node
        }

        let deepest = WorkflowGraph(name: exact, nodes: [try input("叶：\(exact)")])
        let fallback = WorkflowGraph(name: "保留组合字符 e\u{301}", nodes: [try input("否：\(exact)")])
        let nested = try branch("内层：\(exact)", then: deepest, otherwise: fallback)
        let nestedGraph = WorkflowGraph(name: "嵌套：\(exact)", nodes: [nested])
        let outer = try branch(outerTitle, then: nestedGraph, otherwise: fallback)
        let graph = WorkflowGraph(name: exact, nodes: [outer])

        let toolID = try #require(UUID(uuidString: "10000000-0000-0000-0000-000000000001"))
        let toolGraphID = try #require(UUID(uuidString: "20000000-0000-0000-0000-000000000002"))
        let toolGraphRevision = try #require(UUID(uuidString: "20000000-0000-0000-0000-000000000003"))
        let toolNodeID = try #require(UUID(uuidString: "30000000-0000-0000-0000-000000000004"))
        let invocationID = try #require(UUID(uuidString: "40000000-0000-0000-0000-000000000005"))
        let invocationGraphID = try #require(UUID(uuidString: "50000000-0000-0000-0000-000000000006"))
        let invocationGraphRevision = try #require(UUID(uuidString: "50000000-0000-0000-0000-000000000007"))
        let toolVersion = 7
        let toolInputs: [WorkflowRecordField] = [.init("内容 e\u{301}", .text)]
        var toolInput = try #require(WorkflowRegistry.standard.operation("d.value.input")).definition.makeNode()
        toolInput.id = toolNodeID
        toolInput.title = "工具叶：\(exact)"
        toolInput.parameters["publicName"] = .text(toolInputs[0].name)
        toolInput.dataConfiguration = .init(value: .text("不会替代外部输入"))
        var toolGraph = WorkflowGraph(
            id: toolGraphID, revision: toolGraphRevision, name: "固定工具：\(exact)", nodes: [toolInput]
        )
        toolGraph.interface = .init(
            inputs: toolInputs,
            outputs: [.init(name: "output", nodeID: toolNodeID, schema: .text)]
        )
        let tool = WorkflowToolDefinition(id: toolID, version: toolVersion, name: "固定工具", graph: toolGraph)
        let toolDigest = try WorkflowPlanCompiler.digest(tool)
        var invocation = try #require(WorkflowRegistry.standard.operation("d.control.invoke")).definition.makeNode()
        invocation.id = invocationID
        invocation.title = "调用固定工具"
        invocation.dataConfiguration = .init(fields: toolInputs)
        invocation.control = .invoke(.init(id: toolID, version: toolVersion, digest: toolDigest))
        let invocationGraph = WorkflowGraph(
            id: invocationGraphID, revision: invocationGraphRevision, name: "执行固定工具", nodes: [invocation]
        )
        let plan = try WorkflowPlanCompiler().compile(
            invocationGraph, tools: [tool], target: invocationID, only: false
        )
        var checkpoint = WorkflowPlanCheckpoint(plan: plan)
        checkpoint.externalInputs[invocationID] = [toolInputs[0].name: .data(.text(exact))]
        let executor = WorkflowPlanExecutor(executeCall: { context in
            .outputs(["output": .data(try #require(context.node.dataConfiguration?.value))])
        }, save: { snapshot in
            try WorkflowCheckpointValidation.validate(snapshot, expected: plan)
        })
        checkpoint = try await executor.execute(checkpoint)
        var run = WorkflowRun(
            id: checkpoint.runID,
            graph: invocationGraph,
            targetNodeID: invocationID,
            steps: checkpoint.records.filter { $0.address.path.count == 1 }.map(\.step),
            status: .completed
        )
        run.planCheckpoint = checkpoint

        func exactStrings(in archive: WorkflowArchive) throws -> (title: String, field: String, fieldKey: String, leaf: String) {
            let storedOuter = try #require(archive.graphs.first?.nodes.first)
            guard case .branch(_, let storedNestedGraph, _) = storedOuter.control else {
                Issue.record("Expected persisted outer Branch")
                throw WorkflowIssue("missing outer Branch")
            }
            let storedNested = try #require(storedNestedGraph.nodes.first)
            guard case .branch(_, let storedDeepest, _) = storedNested.control else {
                Issue.record("Expected persisted nested Branch")
                throw WorkflowIssue("missing nested Branch")
            }
            let storedLeaf = try #require(storedDeepest.nodes.first?.dataConfiguration?.value)
            guard case .record(let storedFields, let storedValues) = storedLeaf else {
                Issue.record("Expected persisted leaf Record")
                throw WorkflowIssue("missing leaf Record")
            }
            let storedField = try #require(storedFields.first)
            let storedEntry = try #require(storedValues.first {
                $0.key.utf8.elementsEqual(storedField.name.utf8)
            })
            guard case .text(let leaf) = storedEntry.value else {
                Issue.record("Expected persisted leaf Text")
                throw WorkflowIssue("missing leaf Text")
            }
            return (storedOuter.title, storedField.name, storedEntry.key, leaf)
        }
        func expectExactUTF8(_ archive: WorkflowArchive) throws {
            let stored = try exactStrings(in: archive)
            #expect(stored.title.utf8.elementsEqual(outerTitle.utf8))
            #expect(stored.field.utf8.elementsEqual(leafFieldName.utf8))
            #expect(stored.fieldKey.utf8.elementsEqual(leafFieldName.utf8))
            #expect(stored.leaf.utf8.elementsEqual(exact.utf8))
            let storedInvocation = try #require(archive.graphs.dropFirst().first?.nodes.first)
            guard case .invoke(let reference) = storedInvocation.control else {
                Issue.record("Expected persisted tool invocation")
                throw WorkflowIssue("missing tool invocation")
            }
            #expect(reference.id == toolID)
            #expect(reference.version == toolVersion)
            #expect(reference.digest.utf8.elementsEqual(toolDigest.utf8))
        }

        let revision = try #require(try await store.workflowState().archive).revision
        let saved = try await store.saveWorkflow(
            graphs: [graph, invocationGraph], runs: [run], expectedRevision: revision, tools: [tool]
        )

        let immediate = try #require(try await store.workflowState().archive)
        #expect(immediate == saved)
        #expect(immediate.version == 2)
        #expect(immediate.graphs.first?.name == exact)
        #expect(immediate.tools?.first?.version == toolVersion)
        #expect(immediate.runs.first?.planCheckpoint?.externalInputs[invocationID]?[toolInputs[0].name] == .data(.text(exact)))
        try expectExactUTF8(immediate)
        let pointer = try #require(await store.snapshot().workflowSnapshot)
        let encoded = try Data(contentsOf: store.rootURL.appendingPathComponent(pointer.relativePath))
        let diskDecoded = try JSONDecoder().decode(WorkflowArchive.self, from: encoded)
        #expect(diskDecoded == saved)
        #expect(diskDecoded.runs.first?.planCheckpoint?.externalInputs[invocationID]?[toolInputs[0].name] == .data(.text(exact)))
        try expectExactUTF8(diskDecoded)

        try await store.close()
        let reopened = try await ProjectStore.open(at: root)
        let decoded = try #require(try await reopened.workflowState().archive)
        #expect(decoded == saved)
        #expect(decoded.graphs.first?.name == exact)
        #expect(decoded.tools?.first?.id == toolID)
        #expect(decoded.tools?.first?.version == toolVersion)
        #expect(decoded.runs.first?.planCheckpoint?.externalInputs[invocationID]?[toolInputs[0].name] == .data(.text(exact)))
        try expectExactUTF8(decoded)
        try await reopened.close()
    }

    @Test func warmReadStillRejectsChangedSnapshotBytes() async throws {
        let (store, _) = try await fixture()
        let pointer = try #require(await store.snapshot().workflowSnapshot)
        let path = store.rootURL.appendingPathComponent(pointer.relativePath)
        var bytes = try Data(contentsOf: path)
        bytes[0] = bytes[0] == 123 ? 91 : 123 // Same length and generation; digest differs.
        try bytes.write(to: path)
        await #expect(throws: (any Error).self) { _ = try await store.workflowState() }
        #expect(try Data(contentsOf: path) == bytes)
        try await store.close()
    }

    @Test func warmReadStillRejectsExternalManifestChangeAndClosedStore() async throws {
        let (store, _) = try await fixture()
        var manifest = await store.snapshot()
        manifest.name = "外部修改"
        let bytes = try JSONEncoder().encode(manifest)
        let path = store.rootURL.appendingPathComponent("project.json")
        try bytes.write(to: path)
        await #expect(throws: ProjectStoreError.externalModification) { _ = try await store.workflowState() }
        try await store.close(preserveExternalChanges: true)
        await #expect(throws: (any Error).self) { _ = try await store.workflowState() }
        #expect(try Data(contentsOf: path) == bytes)
    }

    @Test func newRevisionAndAssetPublicationInvalidatePriorReadAndPreserveFailure() async throws {
        let (store, old) = try await fixture()
        var graph = try #require(old.graphs.first)
        graph.nodes[0].dataConfiguration?.value = .text("新草稿")
        let saved = try await store.saveWorkflow(graphs: [graph], runs: [], expectedRevision: old.revision)
        #expect(try await store.workflowState().archive == saved)
        await #expect(throws: (any Error).self) { _ = try await store.saveWorkflow(graphs: [graph], runs: [], expectedRevision: old.revision) }
        let before = try Data(contentsOf: store.rootURL.appendingPathComponent("project.json"))
        let assetID = UUID(), text = Data("不能丢失".utf8)
        await #expect(throws: (any Error).self) {
            _ = try await store.publishWorkflowAsset(data: text, mediaType: "text/plain", metadata: .init(), name: "输入", parents: [],
                operationID: "d.text.input", stepID: nil, request: nil, details: [:], assetID: assetID,
                checkpoint: { if case .beforeManifest = $0 { throw WorkflowIssue("injected publication failure") } })
        }
        #expect(try Data(contentsOf: store.rootURL.appendingPathComponent("project.json")) == before)
        #expect(try await store.workflowState().archive == saved)
        let published = try await store.publishWorkflowAsset(data: text, mediaType: "text/plain", name: "输入", operationID: "d.text.input", assetID: assetID)
        let withAsset = try #require(try await store.workflowState().archive)
        #expect(withAsset.assets.map(\.reference) == [published.record.reference])
        _ = try await store.updateAsset(id: assetID, name: "重命名", note: "不改变流程快照")
        #expect(try await store.workflowState().archive == withAsset)
        #expect(await store.snapshot().assets.first?.name == "重命名")
        #expect(try await store.workflowData(published.record.reference) == text)
        // A warmed read does not make newly submitted invalid data trusted.
        graph.nodes[0].operationID = "future.unknown"
        await #expect(throws: (any Error).self) {
            _ = try await store.saveWorkflow(graphs: [graph], runs: [], expectedRevision: withAsset.revision)
        }
        #expect(try await store.workflowState().archive == withAsset)
        try await store.close()
        let reopened = try await ProjectStore.open(at: store.rootURL)
        #expect(try await reopened.workflowState().archive == withAsset)
        #expect(try await reopened.workflowData(published.record.reference) == text)
        try await reopened.close()
    }

    @Test func durableWorkflowWriteFailuresNeverPublishCandidateCacheAndRetrySameAsset() async throws {
        for boundary in [WorkflowStoreCheckpoint.snapshotDurable, .beforeManifest] {
            let (store, saved) = try await fixture()
            let manifest = store.rootURL.appendingPathComponent("project.json")
            let before = try Data(contentsOf: manifest)
            let assetID = UUID(), text = Data("失败边界 e\u{301} 👩🏽‍🎨".utf8)
            await #expect(throws: (any Error).self) {
                _ = try await store.publishWorkflowAsset(
                    data: text, mediaType: "text/plain", metadata: .init(), name: "候选", parents: [],
                    operationID: "d.text.input", stepID: nil, request: nil, details: [:], assetID: assetID,
                    checkpoint: { point in
                        switch (boundary, point) {
                        case (.snapshotDurable, .snapshotDurable), (.beforeManifest, .beforeManifest):
                            throw WorkflowIssue("injected durable boundary failure")
                        default:
                            break
                        }
                    }
                )
            }
            #expect(try Data(contentsOf: manifest) == before)
            #expect(await store.snapshot().assets.isEmpty)
            #expect(try await store.workflowState().archive == saved)

            let published = try await store.publishWorkflowAsset(
                data: text, mediaType: "text/plain", name: "候选", operationID: "d.text.input", assetID: assetID
            )
            let retried = try #require(try await store.workflowState().archive)
            #expect(published.asset.id == assetID)
            #expect(retried.assets.map(\.reference) == [published.record.reference])
            #expect(try await store.workflowData(published.record.reference) == text)
            try await store.close()
        }
    }

    /// Opt-in timing on an independent copy; never opens the supplied source for mutation.
    /// No speed threshold: correctness checks above remain the acceptance criteria.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["D_WORKFLOW_READ_BENCHMARK_PROJECT"] != nil))
    func measureRepeatedReadOnProjectCopy() async throws {
        let source = try #require(ProcessInfo.processInfo.environment["D_WORKFLOW_READ_BENCHMARK_PROJECT"])
        let temporary = try #require(ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"])
        let copy = URL(fileURLWithPath: temporary).appendingPathComponent("read-benchmark-\(UUID()).dproject")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: source), to: copy)
        let store = try await ProjectStore.open(at: copy)
        let coldStart = ContinuousClock.now
        var archive = try #require(try await store.workflowState().archive)
        let coldDuration = coldStart.duration(to: .now)
        var saveDurations: [Double] = [], postSaveReadDurations: [Double] = []
        var historyCounts: [Int] = [], snapshotBytes: [Int] = []
        for cycle in 1...5 {
            var graphs = archive.graphs
            if graphs.isEmpty {
                graphs = [WorkflowGraph(name: "SAVE benchmark edit \(cycle)")]
            } else {
                graphs[0].name += " • SAVE edit \(cycle)"
                graphs[0].revision = UUID()
            }
            let saveStart = ContinuousClock.now
            let saved = try await store.saveWorkflow(
                graphs: graphs, runs: archive.runs, expectedRevision: archive.revision, tools: archive.tools
            )
            let saveDuration = saveStart.duration(to: .now)
            let readStart = ContinuousClock.now
            let read = try #require(try await store.workflowState().archive)
            let readDuration = readStart.duration(to: .now)
            #expect(read == saved)
            let pointer = try #require(await store.snapshot().workflowSnapshot)
            #expect(try Data(contentsOf: store.rootURL.appendingPathComponent(pointer.relativePath)).count == pointer.byteCount)
            saveDurations.append(Double(saveDuration.components.seconds) + Double(saveDuration.components.attoseconds) / 1e18)
            postSaveReadDurations.append(Double(readDuration.components.seconds) + Double(readDuration.components.attoseconds) / 1e18)
            historyCounts.append(saved.runs.count)
            snapshotBytes.append(pointer.byteCount)
            archive = saved
        }
        let coldSeconds = Double(coldDuration.components.seconds) + Double(coldDuration.components.attoseconds) / 1e18
        print("WORKFLOW_READ_BENCHMARK cycle_count=5 cold_read_seconds=\(coldSeconds) save_seconds=\(saveDurations) post_save_read_seconds=\(postSaveReadDurations) history_counts=\(historyCounts) snapshot_bytes=\(snapshotBytes) copy=\(copy.path)")
        try await store.close()
    }

    @Test func missingFileAndRelocatedStoreNeverReturnCachedData() async throws {
        let (store, archive) = try await fixture()
        let pointer = try #require(await store.snapshot().workflowSnapshot)
        let file = store.rootURL.appendingPathComponent(pointer.relativePath)
        let held = file.appendingPathExtension("held")
        try FileManager.default.moveItem(at: file, to: held)
        await #expect(throws: (any Error).self) { _ = try await store.workflowState() }
        try FileManager.default.moveItem(at: held, to: file)
        #expect(try await store.workflowState().archive == archive)
        let moved = store.rootURL.appendingPathExtension("moved.dproject")
        try FileManager.default.moveItem(at: store.rootURL, to: moved)
        await #expect(throws: (any Error).self) { _ = try await store.workflowState() }
        let replacement = try await store.relocated(to: moved)
        await #expect(throws: (any Error).self) { _ = try await store.workflowState() }
        #expect(try await replacement.workflowState().archive == archive)
        try await replacement.close()
    }
}
