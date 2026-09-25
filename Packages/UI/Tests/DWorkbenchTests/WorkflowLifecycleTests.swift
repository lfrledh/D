import CryptoKit
import DInference
import Foundation
import ImageIO
import CoreGraphics
import Testing
import UniformTypeIdentifiers
@testable import DWorkbench

private actor WorkflowSubmitGate {
    private var waiting: CheckedContinuation<Void, Never>?
    private var opened = false
    private(set) var entered = false
    func wait() async { entered = true; if opened { return }; await withCheckedContinuation { waiting = $0 } }
    func open() { opened = true; waiting?.resume(); waiting = nil }
}
@MainActor private final class WorkflowSaveSwitch { var fails = true }

private actor WorkflowFixtureEngine: InferenceEngine {
    let directory: URL
    var requests: [InferenceRequest] = []
    var failSecondImage = false
    var gate: WorkflowSubmitGate?
    init(directory: URL) { self.directory = directory }
    func failSecond() { failSecondImage = true }
    func suspend(using gate: WorkflowSubmitGate) { self.gate = gate }
    func submit(_ request: InferenceRequest, backendID: String) async throws -> InferenceRun {
        requests.append(request)
        if let gate { await gate.wait() }
        let result: InferenceResult
        let outputs: [InferenceOutput]
        switch request.input {
        case .text:
            outputs = [.textDelta("清晨的花园 👩🏽‍🎨 e\u{301}")]; result = .init(metadata: ["fixture":"CPU"])
        case .image(let input):
            let images = requests.filter { if case .image = $0.input { true } else { false } }
            if failSecondImage && images.count == 2 { throw WorkflowIssue("controlled candidate failure") }
            let folder = directory.appendingPathComponent(request.id.uuidString + "-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("image.png")
            try workflowFixturePNG(width: input.width, height: input.height).write(to: url)
            let artifact = ArtifactReference(url: url, mediaType: "image/png")
            outputs = [.artifact(artifact)]; result = .init(artifacts: [artifact], metadata: ["fixture":"CPU"])
        default: throw WorkflowIssue("fixture unsupported")
        }
        return InferenceRun(id: request.id, events: AsyncThrowingStream { c in outputs.forEach { c.yield($0) }; c.finish() },
                            cancel: {}, outcome: { .completed(result) })
    }
}
private func workflowFixturePNG(width: Int = 16, height: Int = 12) throws -> Data {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 0.5)); context.fill(.init(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage()); let data = NSMutableData()
    let target = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(target, image, nil); #expect(CGImageDestinationFinalize(target)); return data as Data
}

@Suite("M0 workflow durable lifecycle", .serialized) @MainActor
struct WorkflowLifecycleTests {
    private func fixture(release: @escaping @MainActor () async -> Void = {}, prepare: @escaping @MainActor () async -> Void = {}) async throws -> (URL, ProjectStore, WorkflowFixtureEngine, WorkflowController) {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent("M0-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try await ProjectStore.create(at: root.appendingPathComponent("测试.dproject"), name: "测试")
        let engine = WorkflowFixtureEngine(directory: store.artifactDirectory)
        let session = WorkbenchSession(engine: engine, backendID: "fixture.image", status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) },
            shutdown: {}, cleanup: {}, validateModel: { _ in }, textBackendID: "fixture.text", imageCapability: .scalableKlein4B)
        let services = WorkflowServices(store: store, session: session,
            resolveText: { await prepare(); return .init(identity: "text:fixture", reference: .init(directory: root, revision: "fixture"), backendID: "fixture.text", release: release) },
            resolveImage: { .init(identity: "image:fixture", reference: .init(directory: root, revision: "fixture"), backendID: "fixture.image") })
        let controller = WorkflowController(services: services); await controller.load()
        return (root, store, engine, controller)
    }

    @Test func textWaitReopensIdempotentDecisionAndNoSilentRun() async throws {
        let (_, store, engine, c) = try await fixture()
        c.addExample("text"); let graph = try #require(c.graph); let target = try #require(graph.nodes.last?.id)
        await c.run(target: target, only: false)
        #expect(c.errorMessage == nil); #expect(c.runs.last?.status == .waiting)
        #expect(await engine.requests.count == 1)
        let step = try #require(c.runs.last?.steps.last)
        let before = await store.snapshot(); #expect(before.draft.prompt == "")
        await c.decide(stepID: step.id, accept: true, text: "人工确认 🇯🇵 e\u{301}", candidateID: nil, acceptPartial: false)
        #expect(c.errorMessage == nil)
        let assets = await store.snapshot().assets.count
        await c.decide(stepID: step.id, accept: true, text: "不同重复请求", candidateID: nil, acceptPartial: false)
        #expect(await store.snapshot().assets.count == assets)
        #expect(await engine.requests.count == 1)
        await c.resume(runID: try #require(c.runs.last?.id)); #expect(c.runs.last?.status == .completed)
        let archive = try #require(try await store.workflowState().archive)
        #expect(archive.runs.last?.steps.last?.decision?.accepted == true)
        try await c.close(); try await store.close()
        let reopened = try await ProjectStore.open(at: store.rootURL)
        let restored = try #require(try await reopened.workflowState().archive)
        #expect(restored.runs == archive.runs); #expect(restored.graphs == archive.graphs)
        try await reopened.close()
    }

    @Test func editsAndGraphSwitchDuringSubmittedModelRunKeepOriginalSnapshot() async throws {
        let (_, store, engine, c) = try await fixture()
        let gate = WorkflowSubmitGate(); await engine.suspend(using: gate)
        c.addExample("text"); let original = try #require(c.graph)
        let operation = Task { await c.run(target: original.nodes[1].id, only: false) }
        for _ in 0..<2000 {
            if await !engine.requests.isEmpty { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let submitted = try #require(await engine.requests.first)
        c.setParameter(nodeID: original.nodes[0].id, key: "text", value: .text("new unsent input"))
        c.addExample("template"); let other = try #require(c.graph)
        await gate.open(); await operation.value
        #expect(c.errorMessage == nil)
        #expect(c.graph == other)
        let run = try #require(c.runs.last)
        #expect(run.graph.id == original.id)
        #expect(run.graph.nodes[0].parameters["text"] == original.nodes[0].parameters["text"])
        #expect(await engine.requests == [submitted])
        #expect(c.graphs.first { $0.id == original.id }?.nodes[0].parameters["text"] == .text("new unsent input"))
        try await c.close(); try await store.close()
    }

    @Test(arguments: [false, true])
    func cancellationPresentationWaitsForReleaseAndPreservesSaveFailure(failHistory: Bool) async throws {
        let release = WorkflowSubmitGate(), prepare = WorkflowSubmitGate()
        var pausePreparation = false
        let (_, store, engine, c) = try await fixture(release: { await release.wait() }, prepare: {
            if pausePreparation { await prepare.wait() }
        })
        let submit = WorkflowSubmitGate(); await engine.suspend(using: submit)
        c.addExample("text"); let target = try #require(c.graph?.nodes[1].id)
        c.beforeHistorySave = {
            if failHistory && c.runs.last?.status == .cancelled { throw WorkflowIssue("cancel history unavailable") }
        }
        let work = Task { await c.run(target: target, only: false) }
        for _ in 0..<2000 {
            if await submit.entered { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await submit.entered)
        let cancellation = Task { await c.cancel() }
        for _ in 0..<2000 {
            if c.runs.last?.status == .cancelling { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(c.runs.last?.status == .cancelling)
        await submit.open()
        for _ in 0..<2000 {
            if await release.entered { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await release.entered)
        #expect(c.isRunning)
        #expect(!c.progressMessage.contains("已停止并释放"))
        await release.open(); await cancellation.value; await work.value
        #expect(!c.isRunning)
        if failHistory {
            #expect(c.hasPendingSaves)
            #expect(c.runs.last?.status == .saving)
            #expect(c.errorMessage?.contains("cancel history unavailable") == true)
            #expect(!c.progressMessage.contains("已停止并释放"))
            c.beforeHistorySave = {}
            await c.save()
        } else {
            #expect(c.runs.last?.status == .cancelled)
            #expect(c.errorMessage == nil)
            #expect(c.progressMessage == "已取消，计算已停止并释放资源。")
            #expect(c.runs.last?.steps.last?.error == nil)
            let runID = try #require(c.runs.last?.id)
            pausePreparation = true
            let resuming = Task { await c.resume(runID: runID) }
            for _ in 0..<2000 {
                if await prepare.entered { break }
                try await Task.sleep(for: .milliseconds(1))
            }
            #expect(await prepare.entered)
            await c.cancel() // No active backend yet; preparation still must observe cancellation.
            await prepare.open(); await resuming.value
            #expect(c.runs.last?.status == .cancelled)
            #expect(c.errorMessage == nil)
            #expect(c.progressMessage == "已取消，计算已停止并释放资源。")
            #expect(await engine.requests.count == 1)
            pausePreparation = false
            await c.resume(runID: runID)
            #expect(c.runs.last?.status == .completed)
            #expect(c.errorMessage == nil)
        }
        try await c.close(); try await store.close()
    }

    @Test func productionProjectSessionBridgePublishesSnapshotAndReturnsFreshDocument() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent("M0-session-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "D.M0.Bridge." + UUID().uuidString
        let settings = try #require(UserDefaults(suiteName: suite))
        defer { settings.removePersistentDomain(forName: suite) }
        let subject = ProjectSession(sessionFactory: { directory in
            let engine = WorkflowFixtureEngine(directory: directory)
            return WorkbenchSession(engine: engine, backendID: "fixture.image", status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) },
                shutdown: {}, cleanup: {}, validateModel: { _ in }, textBackendID: "fixture.text",
                validateTextModel: { .init(directory: $0, revision: "fixture") })
        }, settings: settings)
        let url = root.appendingPathComponent("bridge.dproject")
        await subject.createProject(at: url); await subject.createTextDocument(name: "原文")
        let original = try #require(subject.text?.editor.document.id)
        subject.editText("已发布中文 👩🏽‍🎨", documentID: original); await subject.saveText()
        await subject.publishTextToWorkflow()
        let controller = try #require(subject.workflow)
        let ref = try #require(controller.graph?.nodes.last?.assetReference)
        subject.editText("聊天继续；不得改变流程快照", documentID: original); await subject.saveText()
        #expect(try await controller.services.readText(ref) == "已发布中文 👩🏽‍🎨")
        #expect(controller.runs.isEmpty)
        await subject.returnWorkflowText(ref)
        #expect(subject.errorMessage == nil)
        #expect(subject.text?.editor.document.id != original)
        #expect(subject.text?.editor.document.text == "已发布中文 👩🏽‍🎨")
        #expect(await subject.requestClose())
        #expect(subject.workflow == nil)
        let before = controller.graphs; controller.addExample("text"); #expect(controller.graphs == before)
        await subject.openProject(at: url); await subject.openWorkflow()
        #expect(subject.workflow?.graphs == before)
        #expect(await subject.requestClose())
    }

    @Test func documentAndGraphRewriteShareRequestsAndDurableProvenanceWithoutHiddenGraph() async throws {
        let (root, unused, engine, _) = try await fixture(); try await unused.close()
        let suite = "D.M0.Rewrite." + UUID().uuidString
        let settings = try #require(UserDefaults(suiteName: suite)); defer { settings.removePersistentDomain(forName: suite) }
        let model = ModelReference(directory: root, revision: "fixture")
        let subject = ProjectSession(sessionFactory: { _ in
            WorkbenchSession(engine: engine, backendID: "fixture.image", status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) },
                shutdown: {}, cleanup: {}, validateModel: { _ in }, textBackendID: "fixture.text", validateTextModel: { _ in model })
        }, settings: settings)
        let url = root.appendingPathComponent("shared-rewrite.dproject")
        await subject.createProject(at: url); await subject.createTextDocument(name: "独立会话")
        let editor = try #require(subject.text); let id = editor.editor.document.id
        let input = "清晨 👩🏽‍🎨 e\u{301}"; let instruction = "Polish this text."
        subject.editText(input, documentID: id); await subject.saveText()
        subject.selectText(.init(location: 0, length: input.utf16.count), documentID: id)
        editor.instruction = instruction; await subject.registerTextModel(at: root)
        #expect(subject.canRewriteText); await subject.rewriteText()
        let candidate = try #require(editor.editor.candidate)
        #expect(editor.canAccept); #expect(subject.workflow == nil)
        subject.acceptTextRewrite(); await subject.saveText()
        #expect(await subject.requestClose()); await subject.openProject(at: url); await subject.openWorkflow()
        let c = try #require(subject.workflow)
        let archive = try #require(try await c.services.store.workflowState().archive)
        #expect(archive.graphs.isEmpty && archive.runs.isEmpty) // a shared asset is not a hidden graph
        let record = try #require(archive.assets.first { $0.reference.assetID == candidate.runID })
        #expect(record.request == candidate.request)
        #expect(record.metadata == candidate.executionDetails())
        #expect(try await c.services.readText(record.reference) == candidate.replacement)
        c.addExample("text"); let graph = try #require(c.graph)
        c.setParameter(nodeID: graph.nodes[0].id, key: "text", value: .text(input))
        c.setParameter(nodeID: graph.nodes[1].id, key: "instruction", value: .text(instruction))
        c.setParameter(nodeID: graph.nodes[1].id, key: "maximumOutputTokens", value: .integer(editor.editor.document.generationSettings.maximumOutputTokens))
        c.setParameter(nodeID: graph.nodes[1].id, key: "maximumPromptTokens", value: .integer(editor.editor.document.generationSettings.maximumPromptTokens))
        await c.run(target: graph.nodes[1].id, only: false)
        #expect(c.errorMessage == nil)
        let output = try #require(c.runs.last?.steps.last?.outputs["output"]?.asset)
        let graphRecord = try #require(try await c.services.store.workflowState().archive?.assets.first { $0.reference == output })
        #expect(graphRecord.request?.model == record.request?.model)
        #expect(graphRecord.request?.input == record.request?.input)
        #expect(graphRecord.metadata["backend"] == record.metadata["backend"])
        #expect(graphRecord.metadata["operation"] == record.metadata["operation"])
        #expect(graphRecord.metadata["runID"] != record.metadata["runID"])
        #expect(await engine.requests.count == 2)
        #expect(await subject.requestClose())
    }

    @Test func failedDocumentRewriteRecordRetriesSavingWithoutRepeatingInferenceOrChangingOriginal() async throws {
        let (root, store, engine, _) = try await fixture()
        let failure = WorkflowSaveSwitch()
        let document = try TextDraftDocument(text: "原文 e\u{301}")
        let editor = ProjectTextController(document: document, engine: engine, backendID: "fixture.text",
            recordRewrite: { candidate in
                if failure.fails { throw WorkflowIssue("controlled unavailable output") }
                _ = try await store.publishWorkflowAsset(data: Data(candidate.replacement.utf8), mediaType: "text/plain",
                    name: "candidate", operationID: "d.text.rewrite", request: candidate.request,
                    details: candidate.executionDetails(), assetID: candidate.runID)
            }, persist: { _, _ in })
        editor.select(.init(location: 0, length: document.text.utf16.count), documentID: document.id)
        editor.instruction = "Polish"; await editor.rewrite(using: .init(directory: root))
        #expect(editor.editor.document == document && !editor.canAccept)
        #expect(editor.editor.candidate != nil && editor.errorMessage != nil)
        failure.fails = false; try await editor.flush()
        #expect(editor.canAccept); #expect(await engine.requests.count == 1)
        editor.accept(); try await editor.flush()
        #expect(editor.editor.document.text != document.text)
        #expect(try await store.workflowState().archive?.assets.count == 1)
        editor.rebind(engine: engine, backendID: "fixture.rebound")
        editor.select(.init(location: 0, length: editor.editor.document.text.utf16.count), documentID: document.id)
        await editor.rewrite(using: .init(directory: root))
        let rebound = try #require(editor.editor.candidate)
        #expect(rebound.backendID == "fixture.rebound")
        let reboundRecord = try #require(try await store.workflowState().archive?.assets.first { $0.reference.assetID == rebound.runID })
        #expect(reboundRecord.metadata["backend"] == "fixture.rebound")
        editor.reject()
        try await store.close()
    }

    @Test func switchingProjectsWaitsForAdmittedGraphAndNeverWritesIntoNewProject() async throws {
        let (root, unused, engine, _) = try await fixture(); try await unused.close()
        let suite = "D.M0.Switch." + UUID().uuidString
        let settings = try #require(UserDefaults(suiteName: suite)); defer { settings.removePersistentDomain(forName: suite) }
        let subject = ProjectSession(sessionFactory: { _ in
            WorkbenchSession(engine: engine, backendID: "fixture.image", status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) },
                shutdown: {}, cleanup: {}, validateModel: { _ in }, textBackendID: "fixture.text",
                validateTextModel: { .init(directory: $0, revision: "fixture") })
        }, settings: settings, closeDecision: { .wait })
        let bURL = root.appendingPathComponent("B.dproject")
        let b = try await ProjectStore.create(at: bURL, name: "B"); let bID = await b.snapshot().id; try await b.close()
        let aURL = root.appendingPathComponent("A.dproject")
        await subject.createProject(at: aURL); await subject.registerTextModel(at: root); await subject.openWorkflow()
        let c = try #require(subject.workflow); c.addExample("text"); let graph = try #require(c.graph)
        let gate = WorkflowSubmitGate(); await engine.suspend(using: gate)
        let run = Task { await c.run(target: graph.nodes[1].id, only: false) }
        for _ in 0..<2000 {
            if await !engine.requests.isEmpty { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await engine.requests.count == 1)
        c.setParameter(nodeID: graph.nodes[0].id, key: "text", value: .text("A edited after submission"))
        let switchProject = Task { await subject.openProject(at: bURL) }
        for _ in 0..<2000 {
            if subject.isChangingProject { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(subject.manifest?.id != bID && subject.isChangingProject)
        await gate.open(); await run.value; await switchProject.value
        #expect(subject.manifest?.id == bID)
        #expect(subject.manifest?.assets.isEmpty == true)
        #expect(subject.manifest?.workflowSnapshot == nil)
        let old = try await ProjectStore.open(at: aURL)
        let history = try #require(try await old.workflowState().archive)
        #expect(history.runs.last?.status == .completed)
        #expect(history.runs.last?.graph.nodes[0].parameters["text"] == graph.nodes[0].parameters["text"])
        #expect(history.graphs[0].nodes[0].parameters["text"] == .text("A edited after submission"))
        #expect(history.assets.allSatisfy { $0.reference.projectID != bID })
        try await old.close(); #expect(await subject.requestClose())
    }

    @Test func pendingWaitSurvivesCloseAndStaleConfirmationCannotPublish() async throws {
        let (_, store, _, c) = try await fixture()
        c.addExample("template"); let g = try #require(c.graph)
        await c.run(target: try #require(g.nodes.last?.id), only: false)
        let waiting = try #require(c.runs.last?.steps.last)
        #expect(waiting.status == .waiting)
        let original = try #require(try await store.workflowState().archive)
        c.setParameter(nodeID: g.nodes[0].id, key: "text", value: .text("new original"))
        await c.decide(stepID: waiting.id, accept: true, text: "stale", candidateID: nil, acceptPartial: false)
        #expect(c.errorMessage?.contains("过期") == true)
        #expect(try await store.workflowState().archive?.assets == original.assets)
        c.undo(); c.errorMessage = nil
        await c.save(); try await c.close(); try await store.close()
        let reopened = try await ProjectStore.open(at: store.rootURL)
        #expect(try await reopened.workflowState().archive?.runs.last?.status == .waiting)
        try await reopened.close()
    }

    @Test func unacceptedReviewDraftSurvivesReopenAndNeverPublishesOrRuns() async throws {
        let (_, store, engine, c) = try await fixture()
        c.addExample("template"); let target = try #require(c.graph?.nodes.last?.id)
        await c.run(target: target, only: false)
        let run = try #require(c.runs.last); let step = try #require(run.steps.last)
        let original = await store.snapshot().assets
        let draft = "未接受 👩🏽‍🎨 e\u{301}"
        c.editReviewText(stepID: step.id, text: draft)
        #expect(c.runs.last?.steps.last?.decision == nil)
        #expect(await store.snapshot().assets == original)
        #expect(await engine.requests.isEmpty)
        c.addExample("text")
        c.editReviewText(stepID: step.id, text: "wrong selected graph")
        #expect(c.runs.last?.steps.last?.reviewTextDraft == draft)
        await c.save(); try await c.close(); try await store.close()
        let reopened = try await ProjectStore.open(at: store.rootURL)
        let restored = try #require(try await reopened.workflowState().archive)
        #expect(restored.runs.last?.steps.last?.reviewTextDraft == draft)
        #expect(restored.runs.last?.status == .waiting)
        #expect(restored.runs.last?.steps.last?.decision == nil)
        #expect(await reopened.snapshot().assets == original)
        c.editReviewText(stepID: step.id, text: "late callback")
        #expect(c.runs.last?.steps.last?.reviewTextDraft == draft)
        try await reopened.close()
    }

    @Test func fullGraphPartialRetryAndSelectionAreExplicit() async throws {
        let (_, store, engine, c) = try await fixture()
        await engine.failSecond(); c.addExample("image")
        let g = try #require(c.graph); let target = try #require(g.nodes.last?.id)
        await c.run(target: target, only: false)
        #expect(c.runs.last?.status == .waiting)
        #expect(await engine.requests.count == 1) // no image before text confirmation
        let confirm = try #require(c.runs.last?.steps.last(where: { $0.status == .waiting }))
        await c.decide(stepID: confirm.id, accept: true, text: "A quiet garden", candidateID: nil, acceptPartial: false)
        #expect(await engine.requests.count == 1)
        await c.resume(runID: try #require(c.runs.last?.id))
        #expect(c.errorMessage == nil)
        let generation = try #require(c.runs.last?.steps.first(where: { $0.node.operationID == "d.image.generate" }))
        #expect(generation.status == .partial)
        let candidates = try #require(generation.outputs["output"]?.candidates)
        #expect(candidates.filter { $0.asset != nil }.count == 2)
        let choose = try #require(c.runs.last?.steps.first(where: { $0.node.operationID == "d.asset.choose" }))
        await c.decide(stepID: choose.id, accept: true, text: nil, candidateID: candidates[0].id, acceptPartial: false)
        #expect(c.errorMessage != nil); #expect(c.runs.last?.steps.first { $0.id == choose.id }?.decision == nil)
        c.errorMessage = nil
        await c.retryFailedCandidates(stepID: generation.id)
        #expect(c.errorMessage == nil)
        let retry = try #require(c.runs.last?.steps.last?.outputs["output"]?.candidates)
        #expect(retry.allSatisfy { $0.asset != nil }); #expect(retry[0].asset == candidates[0].asset); #expect(retry[2].asset == candidates[2].asset)
        #expect(await engine.requests.count == 5) // one text, three initial images, only one retry
        try await store.close()
    }

    @Test func noModelFileFlowExportAndLayoutDoNotExecuteAgain() async throws {
        let (root, store, engine, c) = try await fixture()
        let file = root.appendingPathComponent("有 空格.png"); try workflowFixturePNG().write(to: file)
        c.addExample("file"); let g = try #require(c.graph)
        await c.importFile(file, nodeID: g.nodes[0].id)
        c.setParameter(nodeID: g.nodes[2].id, key: "format", value: .text("jpeg"))
        c.setDestination(root)
        await c.run(target: g.nodes[3].id, only: false)
        #expect(c.errorMessage == nil); #expect(c.runs.last?.status == .completed); #expect(await engine.requests.isEmpty)
        let receipt = try #require(c.runs.last?.steps.last?.outputs["output"])
        guard case .receipt(let r) = receipt else { Issue.record("expected receipt"); return }
        #expect(r.names.contains("1.jpg")); #expect(r.names.contains("recipe.json"))
        let step = try #require(c.latestStep(for: g.nodes[1].id))
        c.moveNode(id: g.nodes[1].id, x: 400, y: 600); #expect(!c.isStale(step))
        await c.run(target: g.nodes[3].id, only: false); #expect(c.errorMessage == nil); #expect(await engine.requests.isEmpty)
        // Import was a copy. Mutating source cannot rewrite the authoritative imported asset.
        try Data("not a png anymore".utf8).write(to: file)
        let ref = try #require(c.graph?.nodes.first?.assetReference)
        #expect(try await store.workflowData(ref).starts(with: [137,80,78,71]))
        let record = try #require(await store.snapshot().assets.first { $0.id == ref.id })
        try Data("tampered".utf8).write(to: store.rootURL.appendingPathComponent(record.relativePath))
        await #expect(throws: (any Error).self) { _ = try await store.workflowData(ref) }
        try await store.close()
    }

    @Test func failedPublicationPreservesManifestAndRetryUsesSameAssetIdentity() async throws {
        let (_, store, _, _) = try await fixture()
        let oldBytes = try Data(contentsOf: store.rootURL.appendingPathComponent("project.json"))
        let id = UUID(), text = Data("原文".utf8)
        await #expect(throws: (any Error).self) {
            _ = try await store.publishWorkflowAsset(data: text, mediaType: "text/plain", metadata: .init(), name: "原文", parents: [],
                operationID: "d.text.input", stepID: nil, request: nil, details: [:], assetID: id,
                checkpoint: { if case .beforeManifest = $0 { throw WorkflowIssue("simulated disk full") } })
        }
        #expect(try Data(contentsOf: store.rootURL.appendingPathComponent("project.json")) == oldBytes)
        #expect(await store.snapshot().assets.isEmpty)
        let result = try await store.publishWorkflowAsset(data: text, mediaType: "text/plain", name: "原文", operationID: "d.text.input", assetID: id)
        #expect(result.asset.id == id); #expect(try await store.workflowData(result.record.reference) == text)
        _ = try await store.publishWorkflowAsset(data: text, mediaType: "text/plain", name: "原文", operationID: "d.text.input", assetID: id)
        #expect(await store.snapshot().assets.count == 1); try await store.close()
    }

    @Test func futureWorkflowAndUnknownNodePreserveRawBytes() async throws {
        for variant in 0..<3 {
            let (_, store, _, c) = try await fixture()
            c.addExample("text")
            if variant == 2 { await c.run(target: try #require(c.graph?.nodes[0].id), only: false) }
            await c.save(); let saved = await store.snapshot(); try await store.close()
            let pointer = try #require(saved.workflowSnapshot)
            let url = store.rootURL.appendingPathComponent(pointer.relativePath)
            var raw = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            if variant == 1 {
                var graphs = try #require(raw["graphs"] as? [[String: Any]])
                var nodes = try #require(graphs[0]["nodes"] as? [[String: Any]])
                nodes[0]["operationID"] = "future.module"; nodes[0]["parameters"] = ["opaque": ["newShape": [1, 2, 3]]]
                graphs[0]["nodes"] = nodes; raw["graphs"] = graphs
            } else if variant == 2 {
                var runs = try #require(raw["runs"] as? [[String: Any]])
                var steps = try #require(runs[0]["steps"] as? [[String: Any]])
                var node = try #require(steps[0]["node"] as? [String: Any])
                node["definitionVersion"] = 999; node["opaque"] = ["must":"survive"]
                steps[0]["node"] = node; runs[0]["steps"] = steps; raw["runs"] = runs
            } else { raw["version"] = 999; raw["extra"] = ["must":"survive"] }
            let bytes = try JSONSerialization.data(withJSONObject: raw, options: .sortedKeys); try bytes.write(to: url)
            var manifest = saved; manifest.workflowSnapshot = .init(generation: pointer.generation, byteCount: bytes.count,
                sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
            try JSONEncoder().encode(manifest).write(to: store.rootURL.appendingPathComponent("project.json"))
            let reopened = try await ProjectStore.open(at: store.rootURL)
            let state = try await reopened.workflowState(); #expect(state.archive == nil); #expect(state.originalBytes == bytes)
            await #expect(throws: (any Error).self) { _ = try await reopened.saveWorkflow(graphs: [], runs: [], expectedRevision: UUID()) }
            #expect(try Data(contentsOf: url) == bytes); try await reopened.close()
        }
    }

    @Test func sourceTwelveMigrationPreservesExactBackupAndCandidateSchemasRejected() async throws {
        let (_, store, _, _) = try await fixture(); var old = await store.snapshot(); try await store.close()
        old.schemaVersion = 12; let original = try JSONEncoder().encode(old)
        try original.write(to: store.rootURL.appendingPathComponent("project.json"))
        let migrated = try await ProjectStore.open(at: store.rootURL)
        #expect(await migrated.snapshot().schemaVersion == 16)
        #expect(try Data(contentsOf: store.rootURL.appendingPathComponent("project.v12.backup.json")) == original)
        try await migrated.close()
        #expect(!ProjectManifest.readableSchemaVersions.contains(13)); #expect(!ProjectManifest.readableSchemaVersions.contains(14)); #expect(!ProjectManifest.readableSchemaVersions.contains(15))
    }

    @Test func deliveredResultHistoryFailureDoesNotRepeatInference() async throws {
        let (_, store, engine, c) = try await fixture()
        c.addExample("text"); let rewrite = try #require(c.graph?.nodes[1].id)
        var fail = true
        c.beforeHistorySave = {
            if fail && c.runs.last?.steps.last?.status == .completed { throw WorkflowIssue("history volume unavailable") }
        }
        await c.run(target: rewrite, only: false)
        #expect(c.runs.last?.status == .saving); #expect(c.runs.last?.steps.last?.status == .completed)
        #expect(await engine.requests.count == 1)
        fail = false; await c.save(); c.errorMessage = nil
        await c.resume(runID: try #require(c.runs.last?.id))
        #expect(c.errorMessage == nil); #expect(c.runs.last?.status == .completed)
        #expect(await engine.requests.count == 1)
        try await c.close(); try await store.close()
    }

    @Test func retryHistoryFailureRetainsOriginalSuccessfulCandidates() async throws {
        let (_, store, engine, c) = try await fixture(); await engine.failSecond()
        c.addExample("image"); let g = try #require(c.graph)
        await c.run(target: g.nodes[2].id, only: false)
        let waiting = try #require(c.runs.last?.steps.last)
        await c.decide(stepID: waiting.id, accept: true, text: "studio", candidateID: nil, acceptPartial: false)
        await c.run(target: g.nodes[3].id, only: false)
        let generated = try #require(c.runs.last?.steps.last)
        let original = try #require(generated.outputs["output"]?.candidates)
        #expect(original.filter { $0.asset != nil }.count == 2)
        var fail = true
        c.beforeHistorySave = { if fail { throw WorkflowIssue("retry manifest failure") } }
        await c.retryFailedCandidates(stepID: generated.id)
        #expect(c.runs.last?.steps.last?.outputs["output"]?.candidates == original)
        #expect(await engine.requests.count == 4)
        fail = false; await c.save(); c.errorMessage = nil
        let retryID = try #require(c.runs.last?.id)
        // Cold recovery after interruption, with a new upstream asset under the same configuration.
        let newer = try await store.publishWorkflowAsset(data: Data("different prompt v2".utf8), mediaType: "text/plain",
            name: "new confirmation", operationID: "d.text.confirm")
        var archive = try #require(try await store.workflowState().archive)
        let confirmNode = g.nodes[2]
        let newerStep = WorkflowStepRun(node: confirmNode, signature: try c.registry.signature(confirmNode.id, in: try #require(c.graph)),
            outputs: ["output": .asset(newer.record.reference)], status: .completed)
        archive.runs[archive.runs.count - 1].status = .interrupted
        archive.runs[archive.runs.count - 1].steps[0].status = .interrupted
        archive.runs.append(.init(graph: try #require(c.graph), targetNodeID: confirmNode.id, steps: [newerStep], status: .completed))
        _ = try await store.saveWorkflow(graphs: archive.graphs, runs: archive.runs, expectedRevision: archive.revision)
        c.deactivateAfterClose()
        let recovered = WorkflowController(services: c.services); await recovered.load()
        await recovered.resume(runID: retryID)
        #expect(recovered.errorMessage == nil)
        let request = try #require(await engine.requests.last)
        if case .image(let input) = request.input { #expect(input.prompt == "studio") }
        else { Issue.record("expected image retry") }
        let recoveredRun = try #require(recovered.runs.first { $0.id == retryID })
        let retried = try #require(recoveredRun.steps.last?.outputs["output"]?.candidates)
        #expect(await engine.requests.count == 5)
        #expect(retried[0].asset == original[0].asset && retried[2].asset == original[2].asset)
        #expect(retried.allSatisfy { $0.asset != nil })
        try await recovered.close(); try await store.close()
    }

    @Test func pinExistingRegisteredOriginalRejectsChangedBytes() async throws {
        let (root, store, _, c) = try await fixture()
        let file = root.appendingPathComponent("reference.png"); try workflowFixturePNG(width: 512, height: 512).write(to: file)
        let documentID = try #require(await store.snapshot().documents.first?.id)
        let manifest = try await store.importImageReference(at: file, name: "reference", documentID: documentID)
        let original = try #require(manifest.assets.first)
        let before = try Data(contentsOf: store.rootURL.appendingPathComponent("project.json"))
        try workflowFixturePNG(width: 544, height: 512).write(to: store.rootURL.appendingPathComponent(original.relativePath))
        await #expect(throws: (any Error).self) { _ = try await store.pinWorkflowAsset(original.id) }
        #expect(try Data(contentsOf: store.rootURL.appendingPathComponent("project.json")) == before)
        #expect(try await store.workflowState().archive?.assets.isEmpty == true)
        try await c.close(); try await store.close()
    }

    @Test func sameConfigurationNewUpstreamVersionInvalidatesDescendants() async throws {
        let (_, store, _, c) = try await fixture(); c.addExample("template")
        let g = try #require(c.graph)
        await c.run(target: g.nodes[3].id, only: false)
        let waiting = try #require(c.runs.last?.steps.last)
        #expect(!c.isStale(waiting))
        await c.run(target: g.nodes[0].id, only: true)
        #expect(c.isStale(waiting))
        await c.decide(stepID: waiting.id, accept: true, text: "stale", candidateID: nil, acceptPartial: false)
        #expect(c.errorMessage?.contains("过期") == true)
        try await c.close(); try await store.close()
    }

    @Test func concurrentDecisionIsOneDurablePublicationAndCloseDisablesEdits() async throws {
        let (_, store, _, c) = try await fixture(); c.addExample("template")
        await c.run(target: try #require(c.graph?.nodes.last?.id), only: false)
        let waiting = try #require(c.runs.last?.steps.last)
        let before = await store.snapshot().assets.count
        let first = Task { await c.decide(stepID: waiting.id, accept: true, text: "one", candidateID: nil, acceptPartial: false) }
        await Task.yield()
        await c.decide(stepID: waiting.id, accept: false, text: nil, candidateID: nil, acceptPartial: false)
        await first.value
        let decision = try #require(c.runs.last?.steps.last?.decision)
        #expect(await store.snapshot().assets.count == before + (decision.accepted ? 1 : 0))
        try await c.close(); let graphs = c.graphs
        c.undo(); c.redo(); c.addExample("text")
        #expect(c.graphs == graphs); try await store.close()
    }

    @Test func smallProgramExtensionUsesRealStoreWithoutControllerSpecialCase() async throws {
        let (_, store, engine, c) = try await fixture(); c.addExample("text")
        let input = try #require(c.graph?.nodes[0].id)
        c.setParameter(nodeID: input, key: "text", value: .text("\n  中文 👩🏽‍🎨\r\n \t\n e\u{301}\n"))
        c.addNode(operationID: "d.text.remove-blank-lines")
        let target = try #require(c.selectedNodeID)
        c.connect(source: input, sourcePort: "output", target: target, targetPort: "input")
        await c.run(target: target, only: false)
        #expect(c.errorMessage == nil); #expect(await engine.requests.isEmpty)
        let result = try #require(c.runs.last?.steps.last?.outputs["output"]?.asset)
        #expect(try await c.services.readText(result) == "  中文 👩🏽‍🎨\n e\u{301}")
        try await c.close(); try await store.close()
        let reopened = try await ProjectStore.open(at: store.rootURL)
        #expect(try await reopened.workflowState().archive?.runs.last?.status == .completed)
        try await reopened.close()
    }

    @Test func samePortContractTwoImplementationsPublishDistinctSourceAndRejectWithoutFallback() async throws {
        let (_, store, engine, c) = try await fixture()
        let parent = try await store.publishWorkflowAsset(data: Data("hello".utf8), mediaType: "text/plain",
            name: "input", operationID: "d.text.input").record.reference
        func implementation(_ id: String, maximum: Int) -> WorkflowOperation {
            WorkflowOperation(definition: .init(id: id, title: id, detail: "fixture",
                inputs: [.init("input", "text", kinds: [.text])], outputs: [.init("output", "text", kinds: [.text])]),
                execute: { context, services in
                    let input = try #require(context.inputs["input"]?.asset)
                    let value = try await services.readText(input)
                    guard value.count <= maximum else { throw WorkflowIssue("fixture capacity") }
                    return .outputs(["output": .asset(try await services.publishText(id + ":" + value, parents: [input], context: context))])
                })
        }
        let first = implementation("fixture.program.first", maximum: 4)
        let second = implementation("fixture.program.second", maximum: 10)
        let registry = try WorkflowRegistry(operations: [first, second])
        let chosen = try #require(registry.operation(second.definition.id))
        let input: [String: WorkflowValue] = ["input": .asset(parent)]
        let context = WorkflowExecutionContext(node: chosen.definition.makeNode(), stepID: UUID(), inputs: input)
        try registry.validateInputs(input, node: context.node, connectedPorts: ["input"])
        let result = try await chosen.execute(context, c.services)
        guard case .outputs(let outputs) = result else { Issue.record("Expected typed text output"); return }
        let output = try #require(outputs["output"]?.asset)
        #expect(try await c.services.readText(output) == "fixture.program.second:hello")
        let record = try #require(try await store.workflowState().archive?.assets.first { $0.reference == output })
        #expect(record.operationID == second.definition.id && record.parents == [parent])
        await #expect(throws: WorkflowIssue.self) {
            _ = try await first.execute(.init(node: first.definition.makeNode(), stepID: UUID(), inputs: input), c.services)
        }
        #expect(try await store.workflowState().archive?.assets.count == 2)
        #expect(await engine.requests.isEmpty); #expect(registry.operation("fixture.missing") == nil)
        try await store.close()
    }

    @Test func exportDerivedRecipeKeepsAncestryWithoutPrivatePathsAndWillNotOverwrite() async throws {
        let (root, store, _, c) = try await fixture()
        let request = InferenceRequest(model: .init(directory: root.appendingPathComponent("secret-model"), revision: "fixed-revision"),
            input: .image(.init(prompt: "actual prompt", width: 16, height: 12, steps: 4, guidanceScale: 1, seed: UInt64.max)))
        let original = try await store.publishWorkflowAsset(data: workflowFixturePNG(), mediaType: "image/png",
            metadata: .init(width: 16, height: 12), name: "source", operationID: "d.image.generate", request: request,
            details: ["privatePath": root.path])
        var node = try #require(c.registry.operation("d.image.convert")).definition.makeNode()
        node.parameters["format"] = .text("jpeg")
        let ref = try await c.services.transformImage(original.record.reference,
            context: .init(node: node, stepID: UUID(), inputs: ["input": .asset(original.record.reference)]))
        let id = UUID()
        let receipt = try await store.exportWorkflowAssets([ref], name: "recipe", exportID: id, directory: root)
        let directory = root.appendingPathComponent("recipe-" + id.uuidString + ".dexport")
        let bytes = try Data(contentsOf: directory.appendingPathComponent("recipe.json"))
        let text = try #require(String(data: bytes, encoding: .utf8))
        #expect(!text.contains(root.path)); #expect(text.contains("fixed-revision")); #expect(text.contains(String(UInt64.max)))
        #expect(!text.contains("actual prompt")); #expect(text.contains("withheld"))
        let json = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let history = try #require(json["provenance"] as? [[String: Any]])
        #expect(history.count == 2)
        #expect(history.last?["input"] == nil) // conversion is not falsely attributed to the generation request
        #expect((history.last?["processing"] as? [String: String])?["backgroundPolicy"] == "white")
        #expect(try await store.exportWorkflowAssets([ref], name: "recipe", exportID: id, directory: root) == receipt)
        let target = directory.appendingPathComponent("1.jpg"); let unrelated = Data("existing user file".utf8)
        try unrelated.write(to: target)
        await #expect(throws: (any Error).self) { _ = try await store.exportWorkflowAssets([ref], name: "recipe", exportID: id, directory: root) }
        #expect(try Data(contentsOf: target) == unrelated)
        try await c.close(); try await store.close()
    }
}
