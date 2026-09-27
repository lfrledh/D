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

    /// Opt-in timing on an independent copy; never opens the supplied source for mutation.
    /// No speed threshold: correctness checks above remain the acceptance criteria.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["D_WORKFLOW_READ_BENCHMARK_PROJECT"] != nil))
    func measureRepeatedReadOnProjectCopy() async throws {
        let source = try #require(ProcessInfo.processInfo.environment["D_WORKFLOW_READ_BENCHMARK_PROJECT"])
        let temporary = try #require(ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"])
        let copy = URL(fileURLWithPath: temporary).appendingPathComponent("read-benchmark-\(UUID()).dproject")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: source), to: copy)
        let store = try await ProjectStore.open(at: copy)
        var durations: [Double] = []
        var previous: WorkflowArchive?
        for _ in 0..<3 {
            let start = ContinuousClock.now
            let archive = try #require(try await store.workflowState().archive)
            let duration = start.duration(to: .now)
            durations.append(Double(duration.components.attoseconds) / 1e18 + Double(duration.components.seconds))
            if let previous { #expect(previous == archive) }
            previous = archive
        }
        let archive = try #require(previous), start = ContinuousClock.now
        let saved = try await store.saveWorkflow(graphs: archive.graphs, runs: archive.runs, expectedRevision: archive.revision, tools: archive.tools)
        let saveDuration = start.duration(to: .now)
        #expect(try await store.workflowState().archive == saved)
        print("WORKFLOW_READ_BENCHMARK reads_seconds=\(durations) save_seconds=\(Double(saveDuration.components.seconds) + Double(saveDuration.components.attoseconds) / 1e18) copy=\(copy.path)")
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
