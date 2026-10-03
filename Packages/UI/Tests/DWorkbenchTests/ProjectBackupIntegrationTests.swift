import Foundation
import DInference
import Testing
@testable import DWorkbench

@Suite("Project backup snapshot and independent restore", .serialized)
struct ProjectBackupIntegrationTests {
    @Test @MainActor func restoredQuickUsesNamedOwnerAndColdReopensWithoutGlobalWrites() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent("RestoredQuick-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = try await ProjectStore.create(at: root.appendingPathComponent("original.dproject"), name: "恢复草稿")
        let global = try await ProjectStore.create(at: root.appendingPathComponent("global.dproject"), name: "全局不变")
        let engine = BackupNoGenerationEngine()
        let suite = "D.RestoredQuick." + UUID().uuidString
        let settings = try #require(UserDefaults(suiteName: suite))
        defer { settings.removePersistentDomain(forName: suite) }
        func owner(_ suffix: String) -> ProjectSession {
            ProjectSession(sessionFactory: { _ in WorkbenchSession(engine: engine, backendID: "fixture",
                status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) }, shutdown: {}, cleanup: {}, validateModel: { _ in }) },
                settings: settings)
        }
        let originalQuick = QuickGenerationController(store: original) { throw WorkflowIssue("No generation") }
        await originalQuick.load(); originalQuick.select(operationID: "d.image.generate", modelID: "image:fixture")
        let draft = try #require(originalQuick.draft)
        originalQuick.setParameter("promptText", value: .text("未保存中文 e\u{301} 🙂"), draftID: draft.id)
        try await originalQuick.flush()
        let globalBefore = try await global.quickCreationState()
        let backup = root.appendingPathComponent("quick.dbackup")
        _ = try await original.createBackup(at: backup)
        let originalID = await original.snapshot().effectiveInstanceID
        try await original.close()
        try FileManager.default.moveItem(at: original.rootURL, to: root.appendingPathComponent("original-preserved.dproject"))
        let restoredURL = root.appendingPathComponent("restored.dproject")
        _ = try await ProjectStore.restoreBackup(at: backup, to: restoredURL)
        let opened = owner("first")
        await opened.openProject(at: restoredURL)
        let restoredQuick = try #require(opened.projectQuick)
        #expect(restoredQuick.store === opened.currentStore)
        #expect(opened.manifest?.effectiveInstanceID != originalID)
        #expect(restoredQuick.draft?.node.parameters["promptText"]?.string == "未保存中文 e\u{301} 🙂")
        restoredQuick.setParameter("promptText", value: .text("只修改恢复副本"), draftID: draft.id)
        await opened.openWorkflow()
        opened.workflow?.addNode(operationID: "d.value.input")
        let nodeCount = opened.workflow?.graph?.nodes.count
        try await opened.saveWorkflowForBackup(store: restoredQuick.store,
            instanceID: try #require(opened.manifest?.effectiveInstanceID))
        #expect(await opened.requestClose())
        #expect(opened.projectQuick == nil)
        let reopened = owner("second")
        await reopened.openProject(at: restoredURL)
        #expect(reopened.projectQuick?.draft?.node.parameters["promptText"]?.string == "只修改恢复副本")
        await reopened.openWorkflow()
        #expect(reopened.workflow?.graph?.nodes.count == nodeCount)
        #expect(try await global.quickCreationState() == globalBefore)
        #expect(await engine.submissions == 0)
        #expect(await reopened.requestClose())
        try await global.close()
    }

    @Test @MainActor func damagedRestoredQuickIsReadOnlyAndSurvivesClose() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent("BadRestoredQuick-" + UUID().uuidString + ".dproject")
        let store = try await ProjectStore.create(at: root, name: "损坏草稿保留")
        try await store.close()
        let data = Data("invalid quick JSON".utf8)
        let sidecar = root.appendingPathComponent("quick-creation.json")
        try data.write(to: sidecar)
        let engine = BackupNoGenerationEngine()
        let suite = "D.BadRestoredQuick." + UUID().uuidString
        let settings = try #require(UserDefaults(suiteName: suite))
        defer { settings.removePersistentDomain(forName: suite) }
        let session = ProjectSession(sessionFactory: { _ in WorkbenchSession(engine: engine, backendID: "fixture",
            status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) }, shutdown: {}, cleanup: {}, validateModel: { _ in }) },
            settings: settings)
        await session.openProject(at: root)
        let quick = try #require(session.projectQuick)
        #expect(!quick.isLoaded && quick.error != nil)
        quick.select(operationID: "d.image.generate", modelID: "image:fixture")
        #expect(quick.draft == nil)
        #expect(await session.requestClose())
        #expect(try Data(contentsOf: sidecar) == data)
    }

    @Test @MainActor func structuredMusicAndNestedHistorySurviveIndependentRestore() async throws {
        let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent("StructuredBackup-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let store = try await ProjectStore.create(at: base.appendingPathComponent("original.dproject"), name: "音符与来源")
        let sequence = WorkflowNoteSequence(clock: .seconds,
            notes: [.init(id: "原声🎵", pitch: 60, start: 0, end: 0.1, velocity: 0.3)], duration: 0.12)
        let audio = try await store.publishWorkflowAsset(data: WorkflowMusicPrograms.render(sequence: sequence, sampleRate: 16_000),
            mediaType: "audio/wav", name: "原声", operationID: "d.music.preview")
        let notes = WorkflowNoteSequence(clock: .seconds, notes: sequence.notes, duration: 0.12, sources: [audio.record.reference])
        let notesData = try JSONEncoder().encode(notes.datum())
        let noteAsset = try await store.publishWorkflowAsset(data: notesData, mediaType: WorkflowMediaFormat.noteType,
            name: "可编辑音符", parents: [audio.record.reference], operationID: "d.music.notes")
        let chords = WorkflowChordTrack(chords: [.init(id: "c1", root: 0, quality: .major7, octave: 4,
            inversion: 1, start: 0, end: 1)], duration: 4,
            tempo: .init(beatsPerMinute: 120, firstBeatSeconds: 0, numerator: 4, denominator: 4),
            sources: [noteAsset.record.reference])
        let chordData = try JSONEncoder().encode(chords.datum())
        let chordAsset = try await store.publishWorkflowAsset(data: chordData, mediaType: WorkflowMediaFormat.chordType,
            name: "和声", parents: [noteAsset.record.reference], operationID: "d.music.chords")
        var input = try #require(WorkflowRegistry.standard.operation("d.value.input")).definition.makeNode()
        input.dataConfiguration = .init(value: .text("保留的决定 中文 e\u{301}"))
        var body = WorkflowGraph(nodes: [input])
        body.interface = .init(outputs: [.init(name: "output", nodeID: input.id, schema: .text)])
        let tool = WorkflowToolDefinition(name: "可展开工具", graph: body)
        var invoke = try #require(WorkflowRegistry.standard.operation("d.control.invoke")).definition.makeNode()
        invoke.control = .invoke(.init(id: tool.id, version: tool.version, digest: try WorkflowPlanCompiler.digest(tool)))
        let graph = WorkflowGraph(nodes: [invoke])
        let plan = try WorkflowPlanCompiler().compile(graph, tools: [tool], target: invoke.id)
        let executor = WorkflowPlanExecutor(executeCall: { context in
            .outputs(["output": .data(try #require(context.node.dataConfiguration?.value))])
        }, save: { _ in })
        let checkpoint = try await executor.execute(.init(plan: plan))
        var run = WorkflowRun(id: checkpoint.runID, graph: graph, targetNodeID: invoke.id,
            steps: checkpoint.records.filter { $0.address.path.count == 1 }.map(\.step), status: .completed)
        run.planCheckpoint = checkpoint
        let prior = try #require(try await store.workflowState().archive)
        let saved = try await store.saveWorkflow(graphs: [graph], runs: [run], expectedRevision: prior.revision, tools: [tool])
        let before = await store.snapshot()
        let backup = base.appendingPathComponent("music.dbackup")
        _ = try await store.createBackup(at: backup)
        try await store.close()
        try FileManager.default.moveItem(at: store.rootURL, to: base.appendingPathComponent("original-offline.dproject"))
        let restoredURL = base.appendingPathComponent("restored.dproject")
        _ = try await ProjectStore.restoreBackup(at: backup, to: restoredURL)
        let restored = try await ProjectStore.open(at: restoredURL)
        let after = await restored.snapshot()
        #expect(after.id == before.id && after.effectiveInstanceID != before.effectiveInstanceID)
        #expect(try await restored.workflowState().archive == saved)
        #expect(try await restored.workflowData(noteAsset.record.reference) == notesData)
        #expect(try await restored.workflowData(chordAsset.record.reference) == chordData)
        #expect(try WorkflowNoteSequence(datum: JSONDecoder().decode(WorkflowDatum.self,
            from: try await restored.workflowData(noteAsset.record.reference))).sources == [audio.record.reference])
        #expect(try WorkflowChordTrack(datum: JSONDecoder().decode(WorkflowDatum.self,
            from: try await restored.workflowData(chordAsset.record.reference))).sources == [noteAsset.record.reference])
        #expect(try await restored.workflowData(audio.record.reference).isEmpty == false)
        try await restored.close()
    }

    @Test func restoreWithoutOriginalPreservesWorkflowAndSeparatesInstance() async throws {
        let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent("BackupIntegration-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let source = base.appendingPathComponent("melody.txt")
        let content = Data("哼唱记录 e\u{301} 🎵".utf8); try content.write(to: source)
        let store = try await ProjectStore.create(at: base.appendingPathComponent("original.dproject"), name: "原项目")
        let asset = try await store.importWorkflowMediaFile(at: source, mode: .reference)
        let before = await store.snapshot()
        let archive = try await store.workflowState().archive
        let plan = try await store.backupPlan()
        #expect(plan.missing.isEmpty)
        let backup = base.appendingPathComponent("backup.dbackup")
        _ = try await ProjectBackup.create(plan, at: backup)
        let backupManifest = try JSONDecoder().decode(ProjectManifest.self, from: Data(contentsOf: backup.appendingPathComponent("project.json")))
        #expect(backupManifest.assets.allSatisfy { $0.fileLocations == nil })
        #expect(!plan.files.contains { $0.relativePath.hasPrefix("AssetInputs/") || $0.relativePath.hasPrefix(".lock") })
        try await store.close()
        try FileManager.default.moveItem(at: store.rootURL, to: base.appendingPathComponent("moved-original.dproject"))
        try FileManager.default.removeItem(at: source)
        let destination = base.appendingPathComponent("restored.dproject")
        _ = try await ProjectStore.restoreBackup(at: backup, to: destination)
        let restored = try await ProjectStore.open(at: destination)
        let after = await restored.snapshot()
        #expect(after.id == before.id && after.effectiveInstanceID != before.effectiveInstanceID)
        #expect(try await restored.workflowData(asset.record.reference) == content)
        #expect(try await restored.workflowState().archive == archive)
        #expect(after.assets.map(\.id) == before.assets.map(\.id))
        await #expect(throws: (any Error).self) { try await ProjectStore.restoreBackup(at: backup, to: destination) }
        #expect(try await restored.workflowData(asset.record.reference) == content)
        try await restored.close()
    }

    @Test func missingOriginalIsAnExplicitIncompleteBackup() async throws {
        let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent("IncompleteBackup-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let source = base.appendingPathComponent("source.txt"); try Data("fixed".utf8).write(to: source)
        let store = try await ProjectStore.create(at: base.appendingPathComponent("original.dproject"), name: "不完整")
        let imported = try await store.importWorkflowMediaFile(at: source, mode: .reference)
        try FileManager.default.removeItem(at: source)
        let plan = try await store.backupPlan()
        #expect(plan.missing == [imported.asset.relativePath])
        let backup = base.appendingPathComponent("incomplete")
        await #expect(throws: (any Error).self) { try await ProjectBackup.create(plan, at: backup) }
        #expect(try await !ProjectBackup.create(plan, at: backup, allowIncomplete: true).complete)
        await #expect(throws: (any Error).self) { try await ProjectStore.restoreBackup(at: backup, to: base.appendingPathComponent("restore.dproject")) }
        #expect(await store.snapshot().assets.contains { $0.id == imported.asset.id })
        try await store.close()
    }
}

private actor BackupNoGenerationEngine: InferenceEngine {
    private(set) var submissions = 0
    func submit(_ request: InferenceRequest, backendID: String) async throws -> InferenceRun {
        submissions += 1
        throw WorkflowIssue("Backup must not generate")
    }
}
