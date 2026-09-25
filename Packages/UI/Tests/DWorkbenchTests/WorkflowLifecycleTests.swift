import CryptoKit
import DInference
import Foundation
import ImageIO
import CoreGraphics
import Testing
import UniformTypeIdentifiers
@testable import DWorkbench

private actor WorkflowFixtureEngine: InferenceEngine {
    let directory: URL
    var requests: [InferenceRequest] = []
    var failSecondImage = false
    init(directory: URL) { self.directory = directory }
    func failSecond() { failSecondImage = true }
    func submit(_ request: InferenceRequest, backendID: String) async throws -> InferenceRun {
        requests.append(request)
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
    private func fixture() async throws -> (URL, ProjectStore, WorkflowFixtureEngine, WorkflowController) {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent("M0-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try await ProjectStore.create(at: root.appendingPathComponent("测试.dproject"), name: "测试")
        let engine = WorkflowFixtureEngine(directory: store.artifactDirectory)
        let session = WorkbenchSession(engine: engine, backendID: "fixture.image", status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) },
            shutdown: {}, cleanup: {}, validateModel: { _ in }, textBackendID: "fixture.text", imageCapability: .scalableKlein4B)
        let services = WorkflowServices(store: store, session: session,
            resolveText: { .init(identity: "text:fixture", reference: .init(directory: root, revision: "fixture"), backendID: "fixture.text") },
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
        for futureNode in [false, true] {
            let (_, store, _, c) = try await fixture()
            c.addExample("text"); await c.save(); let saved = await store.snapshot(); try await store.close()
            let pointer = try #require(saved.workflowSnapshot)
            let url = store.rootURL.appendingPathComponent(pointer.relativePath)
            var raw = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            if futureNode {
                var graphs = try #require(raw["graphs"] as? [[String: Any]])
                var nodes = try #require(graphs[0]["nodes"] as? [[String: Any]])
                nodes[0]["operationID"] = "future.module"; nodes[0]["parameters"] = ["opaque": ["newShape": [1, 2, 3]]]
                graphs[0]["nodes"] = nodes; raw["graphs"] = graphs
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
}
