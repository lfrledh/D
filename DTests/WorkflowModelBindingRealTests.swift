import DInference
import DWorkbench
import Foundation
import Testing
@testable import D

/// Opt-in real local models through ProjectSession's node-specific authorization path.
/// This is model/App integration, not foreground GUI or real disconnected-network evidence.
@Suite(.serialized) @MainActor
struct WorkflowModelBindingRealTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["D_BOUNDARY_REAL_MODELS"] == "1"), .timeLimit(.minutes(10)))
    func differentTextModelsRemainBoundAfterDefaultChangeAndReopen() async throws {
        let environment = ProcessInfo.processInfo.environment
        let a = URL(fileURLWithPath: try #require(environment["D_BOUNDARY_TEXT_A"]))
        let b = URL(fileURLWithPath: try #require(environment["D_BOUNDARY_TEXT_B"]))
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let root = support.appendingPathComponent("D/BoundaryAcceptance/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let project = root.appendingPathComponent("two-models.dproject")
        let suite = "D.BoundaryReal." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let owner = ProjectSession(sessionFactory: { artifacts in try await AppSessionFactory.makeSession(artifactDirectory: artifacts) }, settings: defaults)
        do {
        await owner.createProject(at: project)
        try #require(owner.errorMessage == nil)
        await owner.openWorkflow()
        let c = try #require(owner.workflow); c.addExample("text")
        let first = try #require(c.graph?.nodes[1].id)
        c.selectedNodeID = first
        await owner.registerWorkflowModel(at: a, target: try #require(c.modelSelectionTarget()), controller: c)
        let identityA = try #require(c.selectedNode?.parameters["modelID"]?.string)
        c.addNode(operationID: "d.text.rewrite")
        let second = try #require(c.selectedNodeID)
        await owner.registerWorkflowModel(at: b, target: try #require(c.modelSelectionTarget()), controller: c)
        let identityB = try #require(c.selectedNode?.parameters["modelID"]?.string)
        #expect(!identityA.isEmpty && !identityB.isEmpty && identityA != identityB)
        for id in [first, second] {
            c.setParameter(nodeID: id, key: "maximumOutputTokens", value: .integer(24))
            c.setParameter(nodeID: id, key: "instruction", value: .text("Rewrite as one short sentence."))
        }
        c.connect(source: first, sourcePort: "output", target: second, targetPort: "input")
        // Change the ordinary editor default after both explicit node bindings exist.
        await owner.registerTextModel(at: b)
        await owner.closeProject(); try #require(owner.manifest == nil)
        await owner.openProject(at: project); await owner.openWorkflow()
        let reopened = try #require(owner.workflow); reopened.selectedGraphID = reopened.graphs.first?.id
        await reopened.run(target: second, only: false)
        try #require(reopened.errorMessage == nil, Comment(rawValue: reopened.errorMessage ?? ""))
        let run = try #require(reopened.runs.last)
        #expect(run.status == .completed)
        for (id, identity) in [(first, identityA), (second, identityB)] {
            let step = try #require(run.steps.first { $0.node.id == id })
            #expect(step.node.parameters["modelID"] == .text(identity))
            let asset = try #require(step.outputs["output"]?.asset)
            let text = try #require(String(data: try await reopened.preview(asset), encoding: .utf8))
            #expect(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        print("D_BOUNDARY_REAL_PROJECT=\(project.path)")
        print("D_BOUNDARY_REAL_MODELS=\(identityA),\(identityB)")
        await owner.closeProject(); #expect(owner.manifest == nil)
        } catch { _ = await owner.cancelAndCloseProject(); throw error }
    }
}
