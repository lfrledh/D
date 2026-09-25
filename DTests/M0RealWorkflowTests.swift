import DInference
import DWorkbench
import Foundation
import ImageIO
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
            let validateText = try #require(runtime.validateTextModel)
            let text = try await validateText(textURL)
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
            let resize = try #require(g.nodes.first { $0.operationID == "d.image.resize" })
            let convert = try #require(g.nodes.first { $0.operationID == "d.image.convert" })
            c.setParameter(nodeID: resize.id, key: "width", value: .integer(384))
            c.setParameter(nodeID: resize.id, key: "height", value: .integer(256))
            c.setParameter(nodeID: convert.id, key: "format", value: .text("jpeg"))
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
            let finalRun = try #require(c.runs.last)
            let exportStep = try #require(finalRun.steps.last)
            let jpeg = root.appendingPathComponent("export-" + exportStep.id.uuidString + ".dexport/1.jpg")
            let imageSource = try #require(CGImageSourceCreateWithURL(jpeg as CFURL, nil))
            #expect(CGImageSourceGetType(imageSource) as String? == "public.jpeg")
            let decoded = try #require(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
            #expect(decoded.width == 384 && decoded.height == 256)
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
            // Cancel the node path only after real text output / image denoising is observed.
            var cancellations: [[String: Any]] = []
            for imageRun in [false, true] {
                c.addExample(imageRun ? "image" : "text")
                let node = try #require(c.graph?.nodes.first { $0.operationID == (imageRun ? "d.image.generate" : "d.text.rewrite") })
                if imageRun {
                    // Explicitly detach the prompt so this isolated cancellation case uses its own input.
                    for edge in c.graph?.connections.filter({ $0.targetNode == node.id }) ?? [] { c.disconnect(edge.id) }
                    c.setParameter(nodeID: node.id, key: "promptText", value: .text("A red ceramic teapot on a wooden table"))
                } else {
                    c.setParameter(nodeID: node.id, key: "maximumOutputTokens", value: .integer(1024))
                    c.setParameter(nodeID: node.id, key: "instruction", value: .text("Write a long detailed story of at least 1000 words."))
                }
                let task = Task { await c.run(target: node.id, only: false) }
                var observed = false
                for _ in 0..<6000 {
                    let state = await runtime.status()
                    if imageRun ? state.phase == "正在生成图像" : services.streamedTextCharacterCount > 0 { observed = true; break }
                    try await Task.sleep(for: .milliseconds(20))
                }
                let cancellationStart = Date()
                await c.cancel(); await task.value
                try #require(observed, "Actual execution stage was not observed; not a valid cancellation proof")
                #expect(c.runs.last?.status == .cancelled)
                #expect(await runtime.status().activeRunID == nil)
                #expect(await runtime.status().queuedRunIDs.isEmpty)
                cancellations.append(["kind": imageRun ? "image" : "text", "observedExecution": observed,
                    "releaseSeconds": Date().timeIntervalSince(cancellationStart), "status": c.runs.last?.status.rawValue ?? "unknown"])
            }
            let report: [String: Any] = ["project": projectURL.path, "elapsedSeconds": Date().timeIntervalSince(start),
                "textRevision": text.revision ?? "unknown", "imageRevision": image.revision!, "rewrittenText": rawText,
                "candidateIDs": candidates.map { $0.id.uuidString }, "seeds": candidates.map(\.seed),
                "workflowRun": firstRun.id.uuidString, "cancellations": cancellations,
                "guiValidated": false, "driver": "DTests / production AppSessionFactory"]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: root.appendingPathComponent("real-workflow-result.json"), options: .withoutOverwriting)
            try await c.close(); try await store.close()
            let reopened = try await ProjectStore.open(at: projectURL)
            #expect(try await reopened.workflowState().archive?.runs.first { $0.id == firstRun.id } == saved.runs.first { $0.id == firstRun.id })
            try await reopened.close()
            await runtime.shutdown()
        } catch {
            await runtime.shutdown(); try? await store.close(); throw error
        }
    }
}
