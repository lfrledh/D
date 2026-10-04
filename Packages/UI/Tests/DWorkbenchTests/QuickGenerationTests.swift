import DInference
import Foundation
import CoreGraphics
import ImageIO
import Testing
import UniformTypeIdentifiers
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
    @Test func inputActivityBlocksCloseAndLateCommitAfterOwnerStopsAdmitting() async throws {
        let (store, _, _, canvas) = try await fixture()
        var allowed = true
        let quick = QuickGenerationController(store: store, allowsSubmission: { allowed }) { throw WorkflowIssue("Never generate") }
        await quick.load(); quick.select(operationID: WorkflowModelRoutes.qwen35, modelID: "fixture")
        let draft = try #require(quick.draft)
        let port = try #require(quick.definition?.inputs.first { $0.assetListKind == .image })
        let ref = try await store.publishWorkflowAsset(data: imageData(), mediaType: "image/png",
            metadata: .init(width: 2, height: 2), name: "source", operationID: "d.asset.import").record.reference
        let activity = try quick.beginInputActivity()
        #expect(quick.isImporting)
        await #expect(throws: (any Error).self) { try await quick.prepareForTermination() }
        allowed = false
        #expect(throws: (any Error).self) { try quick.beginInputActivity() }
        #expect(throws: (any Error).self) {
            try quick.commitImportedAssets([ref], port: port, draftID: draft.id,
                expectedNode: draft.node, expectedInputs: draft.inputs)
        }
        #expect(quick.draft == draft)
        allowed = true
        try quick.checkInputActivity(activity)
        var drained = false, entered = false
        let stopping = Task { entered = true; await quick.cancel(); drained = true }
        while !entered { await Task.yield() }
        #expect(quick.isImporting && !drained)
        #expect(throws: (any Error).self) { try quick.checkInputActivity(activity) }
        quick.endInputActivity(activity)
        await stopping.value
        #expect(drained && !quick.isImporting)
        try await quick.prepareForTermination()
        #expect(try await store.workflowData(ref) == imageData())
        try await canvas.close(); try await store.close()
    }

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

    private func imageData() throws -> Data {
        let context = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(.init(x: 0, y: 0, width: 2, height: 2))
        let image = try #require(context.makeImage()), data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @Test func sharedModelDefinitionAndOrderedQuickInputsSurviveReopen() async throws {
        let (store, engine, quick, canvas) = try await fixture()
        let operation = try #require(WorkflowRegistry.standard.operation(WorkflowModelRoutes.qwen35)?.definition)
        quick.select(operationID: operation.id, modelID: "fixture:ordered")
        quick.setParameter("loadingStrategy", value: .text("ssdLayered"), draftID: try #require(quick.draft?.id))
        let draft = try #require(quick.draft)
        #expect(quick.definition == WorkflowRegistry.standard.definition(for: draft.node))
        let port = try #require(quick.definition?.inputs.first(where: { $0.assetListKind == .image }))
        let png = try imageData()
        let a = try await store.publishWorkflowAsset(data: png, mediaType: "image/png", metadata: .init(width: 2, height: 2), name: "first",
            operationID: "d.asset.import").record.reference
        let b = try await store.publishWorkflowAsset(data: png, mediaType: "image/png", metadata: .init(width: 2, height: 2), name: "second",
            operationID: "d.asset.import").record.reference
        try quick.commitImportedAssets([a, b], port: port, draftID: draft.id,
                                       expectedNode: draft.node, expectedInputs: draft.inputs)
        let firstItems = try quick.inputAssetItems(port: port, draftID: draft.id)
        #expect(try port.resolveAssets(#require(quick.draft?.inputs[port.id])) == [a, b])
        try quick.moveInputAsset(firstItems[1].id, by: -1, port: port, draftID: draft.id)
        let reordered = try quick.inputAssetItems(port: port, draftID: draft.id)
        #expect(reordered == [firstItems[1], firstItems[0]])
        try quick.removeInputAsset(firstItems[0].id, port: port, draftID: draft.id)
        #expect(try port.resolveAssets(#require(quick.draft?.inputs[port.id])) == [b])
        #expect(try quick.inputAssetItems(port: port, draftID: draft.id) == [firstItems[1]])
        try await quick.flush()
        let saved = quick.state
        #expect(await engine.requests.isEmpty)
        try await canvas.close(); try await store.close()
        let reopened = try await ProjectStore.open(at: store.rootURL)
        let restored = QuickGenerationController(store: reopened) { throw WorkflowIssue("must not execute") }
        await restored.load()
        #expect(restored.state == saved)
        #expect(restored.draft?.node.parameters["loadingStrategy"] == .text("ssdLayered"))
        #expect(try restored.inputAssetItems(port: port, draftID: draft.id) == [firstItems[1]])
        try restored.removeInputAsset(firstItems[1].id, port: port, draftID: draft.id)
        #expect(restored.draft?.inputs[port.id] == nil)
        #expect(await engine.requests.isEmpty)
        try await restored.flush(); try await reopened.close()
    }

    @Test func importedAssetBatchRejectsWrongKindAndStaleCallbacksWithoutChangingDraft() async throws {
        let (store, engine, quick, canvas) = try await fixture()
        let operation = try #require(WorkflowRegistry.standard.definitions.first {
            $0.modelKind != nil && $0.inputs.contains(where: { $0.assetListKind == .image })
        })
        quick.select(operationID: operation.id, modelID: "fixture:ordered")
        let captured = try #require(quick.draft)
        let port = try #require(quick.definition?.inputs.first(where: { $0.assetListKind == .image }))
        let image = try await store.publishWorkflowAsset(data: imageData(), mediaType: "image/png", metadata: .init(width: 2, height: 2), name: "retained image",
            operationID: "d.asset.import").record.reference
        let text = try await store.publishWorkflowAsset(data: Data("wrong kind".utf8), mediaType: "text/plain", name: "retained text",
            operationID: "d.asset.import").record.reference
        #expect(throws: WorkflowIssue.self) {
            try quick.commitImportedAssets([image, text], port: port, draftID: captured.id,
                                           expectedNode: captured.node, expectedInputs: captured.inputs)
        }
        #expect(quick.draft?.inputs[port.id] == nil)
        quick.setInput(port.id, value: .asset(image), draftID: captured.id)
        #expect(throws: WorkflowIssue.self) {
            try quick.commitImportedAssets([image], port: port, draftID: captured.id,
                                           expectedNode: captured.node, expectedInputs: captured.inputs)
        }
        #expect(quick.draft?.inputs[port.id] == .asset(image))
        quick.select(operationID: "d.model.language", modelID: "text:other")
        let other = quick.draft
        #expect(throws: WorkflowIssue.self) {
            try quick.commitImportedAssets([image], port: port, draftID: captured.id,
                                           expectedNode: captured.node, expectedInputs: [port.id: .asset(image)])
        }
        #expect(quick.draft == other)
        #expect(await store.snapshot().assets.contains(where: { $0.id == image.assetID }))
        #expect(await store.snapshot().assets.contains(where: { $0.id == text.assetID }))
        #expect(await engine.requests.isEmpty)
        try await quick.flush(); try await canvas.close(); try await store.close()
    }

    @Test func invalidOrderedInputIsVisibleAndOnlyExplicitSnapshotClearAllowsImport() async throws {
        let (store, engine, quick, canvas) = try await fixture()
        quick.select(operationID: WorkflowModelRoutes.fluxDev, modelID: "image:dev")
        let draftID = try #require(quick.draft?.id)
        let port = try #require(quick.definition?.inputs.first(where: { $0.assetListKind == .image }))
        let image = try await store.publishWorkflowAsset(data: imageData(), mediaType: "image/png",
            metadata: .init(width: 2, height: 2), name: "retained image", operationID: "d.asset.import").record.reference
        let invalid: [(WorkflowValue, String)] = [
            (.data(.list(element: .asset(.image), items: [])), "列表为空"),
            (.data(.text("wrong type")), "不是有序资产列表"),
            (.data(.list(element: .asset(.image), items: [
                .init(id: "duplicate", value: .asset(image)), .init(id: "duplicate", value: .asset(image))])), "重复项目身份")
        ]
        for (value, reason) in invalid {
            quick.setInput(port.id, value: value, draftID: draftID)
            let captured = try #require(quick.draft)
            #expect(quick.inputIssue?.contains(reason) == true && !quick.canStart)
            #expect(throws: WorkflowIssue.self) { try quick.inputAssetItems(port: port, draftID: draftID) }
            #expect(throws: WorkflowIssue.self) {
                try quick.commitImportedAssets([image], port: port, draftID: draftID,
                                               expectedNode: captured.node, expectedInputs: captured.inputs)
            }
            #expect(quick.draft?.inputs[port.id] == value)
            quick.start()
            #expect(await engine.requests.isEmpty)
            try quick.clearInputAssetList(port: port, draftID: draftID,
                                          expectedNode: captured.node, expectedInputs: captured.inputs)
            #expect(quick.draft?.inputs[port.id] == nil)
            #expect(quick.inputIssue == nil)
            #expect(quick.canStart)
            try quick.commitImportedAssets([image], port: port, draftID: draftID,
                                           expectedNode: captured.node, expectedInputs: [:])
            #expect(try port.resolveAssets(#require(quick.draft?.inputs[port.id])) == [image])
        }
        #expect(await engine.requests.isEmpty)
        try await quick.flush(); try await canvas.close(); try await store.close()
    }

    @Test func clearOrderedInputRejectsChangedDraftNodeAndInputSnapshot() async throws {
        let (store, engine, quick, canvas) = try await fixture()
        quick.select(operationID: WorkflowModelRoutes.qwen35, modelID: "text:vlm")
        let captured = try #require(quick.draft)
        let port = try #require(quick.definition?.inputs.first(where: { $0.assetListKind == .image }))
        quick.setInput(port.id, value: .data(.list(element: .asset(.image), items: [])), draftID: captured.id)
        let invalid = try #require(quick.draft)
        quick.setParameter("task", value: .text("changed"), draftID: captured.id)
        #expect(throws: WorkflowIssue.self) {
            try quick.clearInputAssetList(port: port, draftID: captured.id,
                                          expectedNode: invalid.node, expectedInputs: invalid.inputs)
        }
        #expect(quick.draft?.inputs[port.id] == invalid.inputs[port.id])
        let changedNode = try #require(quick.draft)
        quick.setInput("content", value: .data(.text("changed content")), draftID: captured.id)
        #expect(throws: WorkflowIssue.self) {
            try quick.clearInputAssetList(port: port, draftID: captured.id,
                                          expectedNode: changedNode.node, expectedInputs: changedNode.inputs)
        }
        quick.select(operationID: "d.model.language", modelID: "text:other")
        #expect(throws: WorkflowIssue.self) {
            try quick.clearInputAssetList(port: port, draftID: captured.id,
                                          expectedNode: invalid.node, expectedInputs: invalid.inputs)
        }
        #expect(await engine.requests.isEmpty)
        try await quick.flush(); try await canvas.close(); try await store.close()
    }

    @Test func newImageAndLanguageRoutesKeepQuickCandidateAndJSONControls() async throws {
        let (store, engine, quick, canvas) = try await fixture()
        for route in [WorkflowModelRoutes.qwen35, WorkflowModelRoutes.qwen38] {
            quick.select(operationID: route, modelID: "text:" + route)
            #expect(quick.draft?.node.parameters["outputMode"] == .text("text"))
            #expect(quick.definition?.fields.contains(where: { $0.id == "outputMode" }) == true)
        }
        quick.select(operationID: WorkflowModelRoutes.fluxDev, modelID: "image:dev")
        #expect(quick.draft?.node.parameters["count"] == .integer(1))
        var node = try #require(quick.draft?.node)
        node.parameters["count"] = .integer(3)
        let image = try await store.publishWorkflowAsset(data: imageData(), mediaType: "image/png",
            metadata: .init(width: 2, height: 2), name: "settings source", operationID: "d.asset.import").record.reference
        let sources: [String: WorkflowValue] = ["ref": .data(.list(element: .asset(.image),
            items: [.init(id: "source", value: .asset(image))]))]
        quick.useSettings(node, inputs: sources)
        #expect(quick.draft?.attempts == 3)
        #expect(quick.draft?.node.parameters["count"] == .integer(1))
        #expect(quick.draft?.inputs == sources)
        node.parameters["count"] = .integer(9)
        quick.useSettings(node)
        #expect(quick.draft?.attempts == 3)
        #expect(quick.draft?.inputs == sources)
        #expect(await engine.requests.isEmpty)
        try await quick.flush(); try await canvas.close(); try await store.close()
    }

    @Test func fixedToolDropCreatesOneUndoableGraphAndRejectsUnknownVersion() async throws {
        let (store, engine, quick, canvas) = try await fixture()
        var input = try #require(WorkflowRegistry.standard.operation("d.value.input")).definition.makeNode()
        input.dataConfiguration = .init(value: .text("tool value"))
        var body = WorkflowGraph(nodes: [input])
        body.interface = .init(outputs: [.init(name: "output", nodeID: input.id, schema: .text)])
        let tool = WorkflowToolDefinition(name: "fixed", graph: body)
        let archive = try #require(try await store.workflowState().archive)
        _ = try await store.saveWorkflow(graphs: [], runs: [], expectedRevision: archive.revision, tools: [tool])
        await canvas.load()
        #expect(canvas.graph == nil)
        canvas.addTool(.init(name: "unknown", graph: body))
        #expect(canvas.graph == nil && canvas.selectedNodeID == nil)
        canvas.addTool(tool, x: -120, y: 340)
        #expect(canvas.graph?.nodes.count == 1)
        let node = try #require(canvas.graph?.nodes.first)
        #expect(canvas.selectedNodeID == node.id)
        #expect(canvas.graph?.layout.first?.x == -120)
        #expect(canvas.graph?.layout.first?.y == 340)
        #expect(await engine.requests.isEmpty)
        canvas.undo()
        #expect(canvas.graphs.isEmpty)
        try await quick.prepareForTermination(); try await canvas.close(); try await store.close()
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

    @Test func switchingCategoryDuringGenerationPreservesSubmittingCategory() async throws {
        let (store, engine, quick, canvas) = try await fixture()
        let submitted = try #require(quick.draft)
        quick.start()
        quick.selectCategory(.image)
        quick.select(operationID: "d.image.generate", modelID: "image:fixture")
        let image = try #require(quick.draft)
        quick.setParameter("promptText", value: .text("图像草稿"), draftID: image.id)
        await quick.waitForCompletion()
        #expect(quick.category == .image)
        #expect(quick.visibleRuns.isEmpty)
        #expect(quick.state.runs.last?.draft == submitted)
        #expect(quick.state.runs.last?.status == .completed)
        #expect(await engine.requests.count == 1)
        quick.selectCategory(.text)
        #expect(quick.visibleRuns.count == 1)
        quick.selectCategory(.image)
        #expect(quick.draft?.node.parameters["promptText"] == .text("图像草稿"))
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

    @Test func retryKeepsFailedAttemptInputsAndStructuredResultDoesNotRun() async throws {
        let (store, engine, quick, canvas) = try await fixture()
        let captured = try #require(quick.draft)
        quick.start(); await quick.cancel()
        let failed = try #require(quick.state.runs.last)
        quick.setParameter("task", value: .text("下一次不同输入"), draftID: captured.id)
        quick.retryAttempt(failed.id); await quick.waitForCompletion()
        let retried = try #require(quick.state.runs.last)
        #expect(retried.retryOf == failed.id && retried.id != failed.id)
        #expect(retried.draft.node == captured.node)
        #expect(quick.state.runs.first == failed)
        let calls = await engine.requests.count
        #expect(calls == 1)
        canvas.addBlankGraph()
        let value = WorkflowDatum.record(schema: [.init("标题", .text)], fields: ["标题": .text("雨后 👩🏽‍🎨")])
        try await canvas.insertQuickValue(value, target: try #require(canvas.canvasInsertionTarget()))
        #expect(canvas.graph?.nodes.last?.dataConfiguration?.value == value)
        #expect(await engine.requests.count == calls)
        try await quick.flush(); try await canvas.close(); try await store.close()
    }

    @Test func crossProjectAssetCanCreateEmptyCanvasInOneUndoWithoutInference() async throws {
        let (destination, engine, quick, canvas) = try await fixture()
        let source = try await ProjectStore.create(at: destination.rootURL.deletingLastPathComponent()
            .appendingPathComponent("source.dproject"), name: "source")
        let original = try await source.publishWorkflowAsset(data: Data("原件 👩🏽‍🎨".utf8),
            mediaType: "text/plain", name: "original", operationID: "d.asset.import")
        let before = await source.snapshot()
        #expect(canvas.graphs.isEmpty)
        let target = try #require(canvas.canvasInsertionTarget())
        #expect(target.rootID == nil)
        // This is the same copy + captured insertion path used by the shared-library drop.
        let copied = try await destination.copyWorkflowAsset(original.record.reference, from: source)
        try await canvas.insertQuickResult(copied, target: target, x: 200, y: 180)
        #expect(canvas.graphs.count == 1 && canvas.graph?.nodes.count == 1)
        #expect(canvas.graph?.nodes.first?.assetReference == copied)
        #expect(await source.snapshot() == before)
        #expect(try await source.workflowData(original.record.reference) == Data("原件 👩🏽‍🎨".utf8))
        canvas.undo()
        #expect(canvas.graphs.isEmpty && !canvas.canUndo)
        // Empty -> edited -> empty does not make an old asynchronous destination valid again.
        #expect(!canvas.isCurrent(target))
        await #expect(throws: (any Error).self) { try await canvas.insertQuickResult(copied, target: target) }
        let empty = try #require(canvas.canvasInsertionTarget())
        let invalid = WorkflowAssetReference(projectID: copied.projectID, assetID: UUID(), kind: .text, sha256: copied.sha256)
        await #expect(throws: (any Error).self) { try await canvas.insertQuickResult(invalid, target: empty) }
        #expect(canvas.graphs.isEmpty && !canvas.canUndo)
        try await canvas.saveExplicitEdits()
        await canvas.load()
        let localTarget = try #require(canvas.canvasInsertionTarget())
        await canvas.addAssetNode(projectID: copied.projectID, assetID: copied.assetID,
            x: 80, y: 90, target: localTarget)
        #expect(canvas.graphs.count == 1 && canvas.graph?.nodes.count == 1)
        #expect(canvas.graph?.nodes.first?.assetReference == copied)
        canvas.undo()
        #expect(canvas.graphs.isEmpty && !canvas.canUndo)
        #expect(await engine.requests.isEmpty)
        try await quick.flush(); try await canvas.close(); try await source.close(); try await destination.close()
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
        let readOnly = QuickGenerationController(store: store, makeServices: { throw WorkflowIssue("must not run") })
        await readOnly.load()
        #expect(!readOnly.isLoaded)
        try await readOnly.prepareForTermination()
        #expect(try Data(contentsOf: file) == unknown)
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
