import DInference
import DWorkbench
import Foundation
import Testing
@testable import D

/// Opt-in integration, not GUI acceptance. Uses the production App factory and one shared runtime.
@Suite(.serialized) @MainActor
struct M0RealWorkflowTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["D_M0_REAL_ROOT"] != nil), .timeLimit(.minutes(20)))
    func productionTextAndThreeImagesThroughDurableWorkflow() async throws {
        let env = ProcessInfo.processInfo.environment
        let root = URL(fileURLWithPath: try #require(env["D_M0_REAL_ROOT"]))
        let textURL = URL(fileURLWithPath: try #require(env["D_M0_TEXT_MODEL"]))
        let imageURL = URL(fileURLWithPath: try #require(env["D_M0_IMAGE_MODEL"]))
        let projectURL = root.appendingPathComponent("real-M0-" + UUID().uuidString + ".dproject")
        let store = try await ProjectStore.create(at: projectURL, name: "M0 真实图文")
        let runtime = try await AppSessionFactory.makeSession(artifactDirectory: store.artifactDirectory)
        let start = Date()
        do {
            let text = try await #require(runtime.validateTextModel)(textURL)
            try await runtime.validateModel(imageURL)
            let image = ModelReference(directory: imageURL, revision: "ef52ee019fd1d0e75ae4deb40476ba65989716d7")
            let textID = try #require(runtime.textBackendID)
            let services = WorkflowServices(store: store, session: runtime,
                resolveText: { .init(identity: "text:" + (text.revision ?? "unknown"), reference: text, backendID: textID) },
                resolveImage: { .init(identity: "image:" + image.revision!, reference: image, backendID: runtime.backendID) })
            let c = WorkflowController(services: services); await c.load(); c.addExample("image")
            let g = try #require(c.graph)
            let rewrite = try #require(g.nodes.first { $0.operationID == "d.text.rewrite" })
            c.setParameter(nodeID: rewrite.id, key: "maximumOutputTokens", value: .integer(48))
            c.setParameter(nodeID: rewrite.id, key: "temperature", value: .decimal(0))
            let export = try #require(g.nodes.last?.id)
            c.setDestination(root)
            await c.run(target: export, only: false)
            try #require(c.errorMessage == nil, Comment(rawValue: c.errorMessage ?? ""))
            let firstRun = try #require(c.runs.last)
            try #require(firstRun.status == .waiting)
            let confirm = try #require(firstRun.steps.first { $0.status == .waiting })
            let rawText = try await services.readText(try #require(confirm.outputs["preview"]?.asset))
            try #require(!rawText.isEmpty)
            #expect(!firstRun.steps.contains { $0.node.operationID == "d.image.generate" && $0.status == .completed })
            // Explicit test-driver decision; this is not evidence of a human GUI click.
            await c.decide(stepID: confirm.id, accept: true, text: rawText, candidateID: nil, acceptPartial: false)
            try #require(c.errorMessage == nil, Comment(rawValue: c.errorMessage ?? ""))
            await c.resume(runID: firstRun.id)
            try #require(c.errorMessage == nil, Comment(rawValue: c.errorMessage ?? ""))
            let choose = try #require(c.runs.last?.steps.first { $0.node.operationID == "d.asset.choose" })
            let candidates = try #require(choose.outputs["preview"]?.candidates)
            try #require(candidates.count == 3 && candidates.allSatisfy { $0.asset != nil })
            #expect(Set(candidates.map(\.attemptID)).count == 3)
            #expect(Set(candidates.map(\.seed)).count == 3)
            await c.decide(stepID: choose.id, accept: true, text: nil, candidateID: candidates[1].id, acceptPartial: false)
            await c.resume(runID: firstRun.id)
            try #require(c.errorMessage == nil, Comment(rawValue: c.errorMessage ?? ""))
            try #require(c.runs.last?.status == .completed)
            let saved = try #require(try await store.workflowState().archive)
            #expect(saved.assets.filter { $0.request?.model == image }.count == 3)
            #expect(await runtime.status().activeRunID == nil)
            #expect(await runtime.status().queuedRunIDs.isEmpty)

            // Same text operation remains directly callable outside the graph.
            let draft = TextDraftSession(document: try TextDraftDocument(text: "A peaceful room in morning light."),
                engine: runtime.engine, backendID: textID)
            let selection = try draft.selection(inUTF16: NSRange(location: 0, length: draft.document.text.utf16.count))
            try await draft.requestRewrite(selection: selection, instruction: "Rewrite as one short sentence.", model: text,
                                           temperature: 0, topP: 0.95)
            #expect(draft.candidate != nil)
            #expect(draft.document.text == "A peaceful room in morning light.")
            let report: [String: Any] = ["project": projectURL.path, "elapsedSeconds": Date().timeIntervalSince(start),
                "textRevision": text.revision ?? "unknown", "imageRevision": image.revision!, "rewrittenText": rawText,
                "candidateIDs": candidates.map { $0.id.uuidString }, "seeds": candidates.map(\.seed),
                "workflowRun": firstRun.id.uuidString, "guiValidated": false, "driver": "DTests / production AppSessionFactory"]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: root.appendingPathComponent("real-workflow-result.json"), options: .withoutOverwriting)
            try await c.close(); try await store.close()
            let reopened = try await ProjectStore.open(at: projectURL)
            #expect(try await reopened.workflowState().archive?.runs == saved.runs)
            try await reopened.close()
            await runtime.shutdown()
        } catch {
            await runtime.shutdown(); try? await store.close(); throw error
        }
    }
}
