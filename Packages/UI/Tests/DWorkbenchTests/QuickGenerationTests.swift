import DInference
import Foundation
import Testing
@testable import DWorkbench

private actor QuickFixtureEngine: InferenceEngine {
    private(set) var requests: [InferenceRequest] = []
    func submit(_ request: InferenceRequest, backendID: String) async throws -> InferenceRun {
        requests.append(request)
        return .init(id: request.id, events: AsyncThrowingStream { c in
            c.yield(.textDelta("测试结果 👩🏽‍🎨 e\u{301}")); c.finish()
        }, cancel: {}, outcome: { .completed(.init(metadata: ["fixture": "CPU"])) })
    }
}

@Suite("Quick generation ownership", .serialized) @MainActor
struct QuickGenerationTests {
    private func fixture() async throws -> (ProjectStore, QuickFixtureEngine, QuickGenerationController, WorkflowController) {
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent("Quick-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = try await ProjectStore.create(at: folder.appendingPathComponent("自动创作.dproject"), name: "CPU fixture")
        let engine = QuickFixtureEngine()
        let session = WorkbenchSession(engine: engine, backendID: "fixture", status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) }, shutdown: {}, cleanup: {}, validateModel: { _ in }, textBackendID: "fixture.text")
        func services() -> WorkflowServices { WorkflowServices(store: store, session: session) { _, identity in
            .init(identity: identity, reference: .init(directory: folder, revision: identity), backendID: "fixture.text")
        } }
        let quick = QuickGenerationController(store: store, makeServices: services)
        let canvas = WorkflowController(services: services()); await canvas.load()
        await quick.load(); quick.select(operationID: "d.model.language", modelID: "text:A")
        let id = try #require(quick.draft?.id)
        quick.setParameter("task", value: .text("重写这段话"), draftID: id)
        return (store, engine, quick, canvas)
    }

    @Test func perModelDraftsRawNumericInputAndReopen() async throws {
        let (store, engine, quick, canvas) = try await fixture()
        let a = try #require(quick.draft?.id)
        quick.setParameter("task", value: .text("中文 👩🏽‍🎨 e\u{301}"), draftID: a)
        quick.setFieldText("maximumOutputTokens", text: "1-", draftID: a)
        #expect(!quick.canStart)
        quick.select(operationID: "d.model.language", modelID: "text:B")
        quick.setParameter("task", value: .text("B"), draftID: try #require(quick.draft?.id))
        quick.select(operationID: "d.model.language", modelID: "text:A")
        #expect(quick.draft?.node.parameters["task"] == .text("中文 👩🏽‍🎨 e\u{301}"))
        #expect(quick.draft?.fieldText["maximumOutputTokens"] == "1-")
        quick.start(); await quick.waitForCompletion(); #expect(await engine.requests.isEmpty)
        quick.setFieldText("maximumOutputTokens", text: "24", draftID: a)
        #expect(quick.canStart)
        try await quick.flush()
        let expected = quick.state
        try await canvas.close(); try await store.close()
        let reopened = try await ProjectStore.open(at: store.rootURL)
        #expect(try await reopened.quickCreationState() == expected)
        try await reopened.close()
    }

    @Test func switchingDraftDuringGenerationDoesNotReassignPublishedResult() async throws {
        let (store, engine, quick, canvas) = try await fixture()
        let captured = try #require(quick.draft)
        quick.start()
        quick.select(operationID: "d.model.language", modelID: "text:B")
        await quick.waitForCompletion()
        let result = try #require(quick.state.runs.last)
        #expect(result.status == .completed)
        #expect(result.draft == captured)
        #expect(quick.visibleRuns.isEmpty)
        #expect(await engine.requests.count == 1)
        #expect(result.outputs["output"]?.datum?.text == "测试结果 👩🏽‍🎨 e\u{301}")
        quick.select(operationID: "d.model.language", modelID: "text:A")
        #expect(quick.visibleRuns.count == 1)
        try await quick.flush(); try await canvas.close(); try await store.close()
    }

    @Test func cancelBeforeAdmissionDoesNotSubmitAndCanRunAgain() async throws {
        let (store, engine, quick, canvas) = try await fixture()
        quick.start(); await quick.cancel()
        #expect(await engine.requests.isEmpty)
        #expect(quick.state.runs.last?.status == .cancelled)
        #expect(!quick.isRunning)
        quick.start(); await quick.waitForCompletion()
        #expect(await engine.requests.count == 1)
        #expect(quick.state.runs.last?.status == .completed)
        try await quick.flush(); try await canvas.close(); try await store.close()
    }

    @Test func copiedSettingsAndResultDoNotRunAndStaleTargetRejected() async throws {
        let (store, engine, quick, canvas) = try await fixture()
        quick.setInput("content", value: .data(.text("原文 e\u{301}")), draftID: try #require(quick.draft?.id))
        canvas.addBlankGraph()
        let target = try #require(canvas.canvasInsertionTarget())
        let draft = try #require(quick.draft)
        try await canvas.insertQuickSettings(draft, target: target)
        #expect(canvas.graph?.nodes.count == 2)
        #expect(canvas.graph?.connections.count == 1)
        #expect(canvas.graph?.nodes.first?.parameters == draft.node.parameters)
        #expect(await engine.requests.isEmpty)
        await #expect(throws: (any Error).self) { try await canvas.insertQuickSettings(draft, target: target) }
        #expect(canvas.graph?.nodes.count == 2)
        let asset = try await store.publishWorkflowAsset(data: Data("独立结果".utf8), mediaType: "text/plain", name: "结果", operationID: "d.asset.import")
        let current = try #require(canvas.canvasInsertionTarget())
        try await canvas.insertQuickResult(asset.record.reference, target: current)
        #expect(canvas.graph?.nodes.count == 3)
        #expect(canvas.graph?.nodes.last?.assetReference == asset.record.reference)
        #expect(await engine.requests.isEmpty)
        try await quick.flush(); try await canvas.close(); try await store.close()
    }

    @Test func unknownStateAndSameRevisionExternalEditNeverOverwritten() async throws {
        let (store, _, quick, canvas) = try await fixture()
        try await quick.flush()
        let file = store.rootURL.appendingPathComponent("quick-creation.json")
        let original = try Data(contentsOf: file)
        var object = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        object["futureMeaning"] = "must survive"
        let unknown = try JSONSerialization.data(withJSONObject: object)
        try unknown.write(to: file)
        await #expect(throws: (any Error).self) { try await quick.flush() }
        #expect(try Data(contentsOf: file) == unknown)
        #expect(quick.saveIssue != nil && !quick.canStart)
        // Controlled fixture restores its own bytes; this is not a recovery path for user data.
        try original.write(to: file)
        await quick.retrySave(); #expect(quick.saveIssue == nil)
        let before = try Data(contentsOf: file)
        let modified = Data(String(decoding: before, as: UTF8.self).replacingOccurrences(of: "重写这段话", with: "外部修改内容").utf8)
        try modified.write(to: file)
        await #expect(throws: (any Error).self) { try await quick.flush() }
        #expect(try Data(contentsOf: file) == modified)
        try await canvas.close(); try await store.close()
    }

    @Test func metadataAndDraftEditsCannotChangeFrozenRun() async throws {
        let (store, engine, quick, canvas) = try await fixture()
        quick.start()
        quick.setParameter("task", value: .text("下一次内容"), draftID: try #require(quick.draft?.id))
        await quick.waitForCompletion()
        #expect(quick.state.runs.last?.draft.node.parameters["task"] == .text("重写这段话"))
        #expect(quick.draft?.node.parameters["task"] == .text("下一次内容"))
        let requests = await engine.requests
        #expect(requests.count == 1)
        try await quick.flush(); try await canvas.close(); try await store.close()
    }
    @Test func publishedQuickStateFailureCanRetryWithoutAcceptingOtherWriters() async throws {
        let (store, _, quick, canvas) = try await fixture()
        try await quick.flush()
        let before = quick.state
        var attempted = before; attempted.revision += 1
        attempted.drafts[0].node.parameters["task"] = .text("own publication")
        await #expect(throws: (any Error).self) {
            _ = try await store.saveQuickCreationState(attempted, expectedRevision: before.revision,
                afterPublication: { throw WorkflowIssue("controlled failure after atomic publication") })
        }
        let revised = try await store.saveQuickCreationState(attempted, expectedRevision: before.revision)
        #expect(revised == before.revision + 2)
        let saved = try await store.quickCreationState()
        #expect(saved.drafts[0].node.parameters["task"] == .text("own publication"))
        // The original controller is deliberately stale; it must not overwrite this externally advanced version.
        await #expect(throws: (any Error).self) { try await quick.flush() }
        try await canvas.close(); try await store.close()
    }

    @Test(arguments: [QuickRunRecord.Status.running, .failed, .cancelled])
    func coldReopenRecoversPublishedAssetByFrozenRunAndAttemptWithoutExecuting(status: QuickRunRecord.Status) async throws {
        let (store, engine, quick, canvas) = try await fixture()
        try await quick.flush()
        var state = quick.state
        let runID = UUID(), attempt = WorkflowCandidate(seed: "42")
        let draft = try #require(quick.draft)
        state.runs.append(.init(id: runID, draft: draft, createdAt: Date(), status: status,
            outputs: [:], candidates: [attempt], issue: nil))
        _ = try await store.saveQuickCreationState(state, expectedRevision: state.revision)
        let raw = try await store.publishWorkflowAsset(data: Data("published before crash".utf8), mediaType: "text/plain",
            name: "retained", operationID: draft.node.operationID, stepID: runID)
        let candidate = try await store.publishWorkflowAsset(data: Data("attempt retained".utf8), mediaType: "text/plain",
            name: "candidate", operationID: draft.node.operationID, stepID: attempt.attemptID)
        try await canvas.close(); try await store.close()
        let reopened = try await ProjectStore.open(at: store.rootURL)
        let restored = QuickGenerationController(store: reopened) { throw WorkflowIssue("reopen must never construct execution services") }
        await restored.load()
        #expect(restored.isLoaded)
        let recovered = try #require(restored.state.runs.last)
        #expect(recovered.status == (status == .running ? .interrupted : status))
        #expect(Set(recovered.outputs.values.compactMap(\.asset)) == Set([raw.record.reference, candidate.record.reference]))
        #expect(await engine.requests.isEmpty)
        try await restored.flush(); try await reopened.close()
    }

    @Test func independentAttemptsCaptureOneBatchAndNeverReassignToChangedDraft() async throws {
        let (store, engine, quick, canvas) = try await fixture()
        quick.setAttempts(3, draftID: try #require(quick.draft?.id))
        quick.start()
        quick.select(operationID: "d.model.language", modelID: "text:B")
        await quick.waitForCompletion()
        #expect(await engine.requests.count == 3)
        #expect(quick.state.runs.count == 3)
        #expect(Set(quick.state.runs.compactMap(\.batchID)).count == 1)
        #expect(quick.state.runs.compactMap(\.attemptIndex) == [1, 2, 3])
        #expect(quick.state.runs.allSatisfy { $0.draft.node.parameters["modelID"] == .text("text:A") && $0.status == .completed })
        #expect(quick.visibleRuns.isEmpty)
        try await quick.flush(); try await canvas.close(); try await store.close()
    }

    @Test func crossProjectCopyPreservesOriginalAndStructuredParentsAndRejectsCollision() async throws {
        let (source, engine, quick, canvas) = try await fixture()
        let destination = try await ProjectStore.create(at: source.rootURL.deletingLastPathComponent().appendingPathComponent("另一项目.dproject"), name: "destination")
        let original = try await source.publishWorkflowAsset(data: Data("来源 👩🏽‍🎨".utf8), mediaType: "text/plain", name: "input", operationID: "d.asset.import")
        let notes = WorkflowNoteSequence(clock: .seconds, notes: [.init(id: "n", pitch: 60, start: 0, end: 0.2, velocity: 0.5)], duration: 0.2, sources: [original.record.reference])
        let data = try JSONEncoder().encode(notes.datum())
        let structured = try await source.publishWorkflowAsset(data: data, mediaType: WorkflowMediaFormat.noteType, name: "notes", parents: [original.record.reference], operationID: "d.music.notes")
        let snapshot = await source.snapshot()
        let copied = try await destination.copyWorkflowAsset(structured.record.reference, from: source)
        let decoded = try WorkflowNoteSequence(datum: JSONDecoder().decode(WorkflowDatum.self, from: await destination.workflowData(copied)))
        #expect(decoded.notes == notes.notes)
        let destinationID = await destination.snapshot().id
        #expect(decoded.sources.count == 1 && decoded.sources[0].projectID == destinationID)
        #expect(try await destination.workflowData(decoded.sources[0]) == Data("来源 👩🏽‍🎨".utf8))
        #expect(try await destination.copyWorkflowAsset(structured.record.reference, from: source) == copied)
        #expect(await source.snapshot() == snapshot)
        #expect(try await source.workflowData(structured.record.reference) == data)
        let other = try await ProjectStore.create(at: source.rootURL.deletingLastPathComponent().appendingPathComponent("碰撞.dproject"), name: "collision")
        let collision = try await other.publishWorkflowAsset(data: Data("来源 👩🏽‍🎨".utf8), mediaType: "text/plain", name: "input", operationID: "d.asset.import", assetID: original.asset.id)
        await #expect(throws: (any Error).self) { try await destination.copyWorkflowAsset(collision.record.reference, from: other) }
        #expect(await engine.requests.isEmpty)
        try await other.close(); try await destination.close(); try await quick.flush(); try await canvas.close(); try await source.close()
    }

    @Test func sharedRuntimeResultCopyRejectsWrongOwnerAndChangedFiles() async throws {
        try await withFixture { fixture in
            let owner = try await ProjectStore.create(at: fixture.project, name: "runtime owner")
            let destination = try await ProjectStore.create(at: fixture.directory.appendingPathComponent("destination.dproject"), name: "project")
            let request = fixture.request()
            _ = try await destination.enqueue(request: request)
            let output = try fixture.publishPNG(jobID: request.id)
            let bytes = try Data(contentsOf: output)
            let result = InferenceResult(artifacts: [.init(url: output, mediaType: "image/png")])
            let copied = try await destination.copyRuntimeResult(result, request: request, from: owner)
            #expect(try Data(contentsOf: #require(copied.artifacts.first?.url)) == bytes)
            let retried = try await destination.copyRuntimeResult(result, request: request, from: owner)
            #expect(retried.artifacts == copied.artifacts)
            await #expect(throws: (any Error).self) { try await destination.copyRuntimeResult(result, request: fixture.request(), from: owner) }
            let copiedURL = try #require(copied.artifacts.first?.url)
            try Data("controlled changed destination".utf8).write(to: copiedURL)
            await #expect(throws: (any Error).self) { try await destination.copyRuntimeResult(result, request: request, from: owner) }
            #expect(try Data(contentsOf: output) == bytes)
            #expect(try Data(contentsOf: copiedURL) == Data("controlled changed destination".utf8))
            try await destination.close(); try await owner.close()
        }
    }

}
