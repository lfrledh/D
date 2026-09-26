import DInference
import DWorkbench
import Foundation
import Testing
@testable import D

/// Opt-in real inference through the App factory and the same production interpreter.
/// This is not a foreground GUI, listening or disconnected-network verdict.
@Suite(.serialized) @MainActor
struct NodeLanguageRealTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["D_NODE_LANGUAGE_REAL_CASE"] == "text"),
          .timeLimit(.minutes(15)))
    func languageTaskRewriteAndRecordUseControllerAndSameHeadlessPlan() async throws {
        let env = ProcessInfo.processInfo.environment
        let model = URL(fileURLWithPath: try #require(env["D_NODE_LANGUAGE_TEXT_MODEL"]))
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
        let root = support.appendingPathComponent("D/NodeLanguageAcceptance/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let project = root.appendingPathComponent("real-language.dproject")
        print("D_NODE_LANGUAGE_REAL_ROOT=\(root.path)")
        let store = try await ProjectStore.create(at: project, name: "Node language real text")
        let runtime = try await AppSessionFactory.makeSession(artifactDirectory: store.artifactDirectory)
        let started = Date()
        do {
            let validateModel = try #require(runtime.validateTextModel)
            let reference = try await validateModel(model)
            let backend = try #require(runtime.textBackendID)
            let identity = "text:" + (reference.revision ?? model.lastPathComponent)
            let services = WorkflowServices(store: store, session: runtime, defaultIdentity: { kind in
                kind == .text ? identity : ""
            }, resolveModel: { kind, selected in
                guard kind == .text, selected == identity else { throw WorkflowIssue("Unexpected model binding in real text check.") }
                return .init(identity: identity, reference: reference, backendID: backend)
            })
            let definition = try #require(WorkflowRegistry.standard.operation("d.model.language")).definition
            var creator = definition.makeNode()
            creator.parameters["task"] = .text("Write one short sentence describing a red boat on a quiet lake. Return only the sentence.")
            creator.parameters["maximumOutputTokens"] = .integer(48)
            creator.parameters["temperature"] = .decimal(0)
            creator.parameters["modelID"] = .text(identity)
            creator.dataConfiguration = .init(schema: .text)
            var rewrite = creator; rewrite.id = UUID(); rewrite.title = "Rewrite same operation"
            rewrite.parameters["task"] = .text("Rewrite the supplied Content as one very short English sentence. Return only the sentence.")
            let graph = WorkflowGraph(name: "Real task and content", nodes: [creator, rewrite],
                connections: [.init(sourceNode: creator.id, targetNode: rewrite.id, targetPort: "content")])
            let revision = try #require(try await store.workflowState().archive?.revision)
            _ = try await store.saveWorkflow(graphs: [graph], runs: [], expectedRevision: revision)
            let controller = WorkflowController(services: services); await controller.load()
            await controller.run(target: rewrite.id, only: false)
            try #require(controller.errorMessage == nil, Comment(rawValue: controller.errorMessage ?? ""))
            let run = try #require(controller.runs.last)
            try #require(run.status == .completed && run.steps.count == 2)
            for step in run.steps {
                let generated = (step.outputs["output"]?.datum?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                try #require(!generated.isEmpty)
                try #require(step.outputs["raw"]?.asset != nil)
            }
            try #require(run.steps.last?.inputs["content"] == run.steps.first?.outputs["output"])
            // A genuine structured result, validated by the existing operation parser.
            controller.addNode(operationID: "d.model.language")
            let structuredID = try #require(controller.selectedNodeID)
            let schema = WorkflowDataSchema.record([.init("title", .text)])
            controller.setDataConfiguration(nodeID: structuredID, value: .init(schema: schema))
            controller.setParameter(nodeID: structuredID, key: "modelID", value: .text(identity))
            controller.setParameter(nodeID: structuredID, key: "outputMode", value: .text("json"))
            controller.setParameter(nodeID: structuredID, key: "temperature", value: .decimal(0))
            controller.setParameter(nodeID: structuredID, key: "maximumOutputTokens", value: .integer(64))
            controller.setParameter(nodeID: structuredID, key: "task",
                value: .text("Output a JSON object with exactly one string field named title describing a quiet lake. Your response must start with { and end with }. Do not use backticks, markdown fences, or any text outside the object."))
            await controller.run(target: structuredID, only: false)
            try #require(controller.errorMessage == nil, Comment(rawValue: controller.errorMessage ?? ""))
            let structured = try #require(controller.runs.last)
            try #require(structured.status == .completed)
            let structuredValue = try #require(structured.steps.last?.outputs["output"]?.datum)
            try structuredValue.validate(as: schema)
            await controller.save()
            try #require(!controller.hasPendingSaves)
            let beforeHeadless = try #require(try await store.workflowState().archive)
            try #require(beforeHeadless.runs.count == 2)

            // Same frozen plan, new execution identity and empty call records.
            // No second executor implementation and no silently reused old model result.
            let previous = try #require(run.planCheckpoint)
            var headless = WorkflowPlanCheckpoint(plan: previous.plan, arguments: previous.arguments)
            headless.modelDefaults = previous.modelDefaults
            var headlessRun = WorkflowRun(id: headless.runID, graph: run.graph, targetNodeID: run.targetNodeID, status: .running)
            try services.beginPlan()
            let executor = WorkflowPlanExecutor(executeCall: { try await services.executeCall($0) }, save: { checkpoint in
                headlessRun.planCheckpoint = checkpoint
                headlessRun.steps = checkpoint.records.filter { $0.address.path.count == 1 }.map(\.step)
                switch checkpoint.state {
                case .ready: headlessRun.status = .queued
                case .running: headlessRun.status = .running
                case .paused, .waiting: headlessRun.status = .waiting
                case .completed: headlessRun.status = .completed
                case .failed: headlessRun.status = .failed
                case .cancelled: headlessRun.status = .cancelled
                case .saving: headlessRun.status = .saving
                case .interrupted: headlessRun.status = .interrupted
                }
                let saved = try #require(try await store.workflowState().archive)
                var runs = saved.runs.filter { $0.id != headlessRun.id }; runs.append(headlessRun)
                _ = try await store.saveWorkflow(graphs: saved.graphs, runs: runs, expectedRevision: saved.revision, tools: saved.tools)
            })
            let finished = try await executor.execute(headless)
            try #require(finished.state == .completed && finished.records.count == 2)
            try #require(finished.plan == previous.plan)
            try #require(Set(finished.records.map(\.id)).isDisjoint(with: Set(previous.records.map(\.id))))
            for call in finished.records {
                let generated = (call.step.outputs["output"]?.datum?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                try #require(!generated.isEmpty)
            }
            try #require(await runtime.status().activeRunID == nil)
            try #require(await runtime.status().queuedRunIDs.isEmpty)
            let archive = try #require(try await store.workflowState().archive)
            try #require(archive.runs.count == 3)
            try #require(archive.graphs == beforeHeadless.graphs && archive.tools == beforeHeadless.tools)
            for original in beforeHeadless.runs {
                try #require(archive.runs.first { $0.id == original.id } == original)
            }
            try #require(archive.runs.first { $0.id == headlessRun.id } == headlessRun)
            let requests = archive.assets.compactMap(\.request)
            try #require(requests.count == 5)
            try #require(requests.allSatisfy { $0.model == reference })
            let steps = archive.runs.flatMap(\.steps)
            try #require(steps.count == 5 && Set(steps.map(\.id)).count == 5)
            try #require(Set(requests.map(\.id)) == Set(steps.map(\.id)))
            for step in steps {
                let asset = try #require(archive.assets.first { $0.stepID == step.id && $0.request != nil })
                try #require(asset.reference == step.outputs["raw"]?.asset)
                let request = try #require(asset.request)
                try #require(request.id == step.id)
                guard case .text(let text) = request.input else { throw WorkflowIssue("Expected persisted text request.") }
                let task = try #require(step.node.parameters["task"]?.string)
                let content = step.inputs["content"]?.datum?.text
                try #require(text.prompt == task + (content.map { "\n\nContent:\n" + $0 } ?? ""))
                try #require(text.maxTokens == step.node.parameters["maximumOutputTokens"]?.integer)
                try #require(text.temperature == 0)
            }
            try JSONEncoder().encode(archive).write(to: root.appendingPathComponent("workflow-evidence.json"), options: .withoutOverwriting)
            let report: [String: Any] = [
                "case": "text", "driver": "AppSessionFactory + WorkflowController + WorkflowPlanExecutor",
                "project": project.path, "modelIdentity": identity, "revision": reference.revision ?? "unknown",
                "controllerRunID": run.id.uuidString, "structuredRunID": structured.id.uuidString,
                "headlessRunID": finished.runID.uuidString, "persistedRealRequests": requests.count,
                "elapsedSeconds": Date().timeIntervalSince(started), "guiValidated": false,
                "outputs": run.steps.compactMap { $0.outputs["output"]?.datum?.text },
            ]
            controller.deactivateAfterClose() // Do not write an older UI snapshot over the headless history.
            try await store.close()
            let reopened = try await ProjectStore.open(at: project)
            try #require(try await reopened.workflowState().archive == archive)
            try await reopened.close()
            await runtime.shutdown()
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: root.appendingPathComponent("real-result.json"), options: .withoutOverwriting)
            print("D_NODE_LANGUAGE_REAL_TEXT_PASS=\(root.path)")
        } catch {
            await runtime.shutdown()
            try? await store.close(preserveExternalChanges: true)
            throw error
        }
    }
}
