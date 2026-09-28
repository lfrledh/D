import AppKit
import DWorkbench
import Foundation
import Testing
@testable import UI

@Suite @MainActor
struct WorkflowBaseline02Tests {
    private let modelDefinition = WorkflowOperationDefinition(
        id: "d.test.model", title: "模型操作", detail: "", inputs: [], outputs: [], modelKind: .text
    )

    @Test func exactModelNamesKeepSeparateNodeInstancesAndAnnotations() {
        let choices = [WorkflowModelChoice(id: "text:A", kind: .text, displayName: "模型 A")]
        let first = WorkflowNode(operationID: modelDefinition.id, title: "写一首诗",
            parameters: ["modelID": .text("text:A")])
        let second = WorkflowNode(operationID: modelDefinition.id, title: "摘要",
            parameters: ["modelID": .text("text:A")])
        let a = WorkflowNodeIdentity.resolve(node: first, definition: modelDefinition,
            modelChoices: choices, assets: [], tools: [], language: nil)
        let b = WorkflowNodeIdentity.resolve(node: second, definition: modelDefinition,
            modelChoices: choices, assets: [], tools: [], language: nil)
        #expect(first.id != second.id)
        #expect(a.title == "模型 A" && b.title == "模型 A")
        #expect(a.annotation == "写一首诗" && b.annotation == "摘要")
        #expect(a.detail == "text:A" && b.detail == "text:A")
    }

    @Test func unboundAndUnknownModelsRemainExplicit() {
        let unbound = WorkflowNode(operationID: modelDefinition.id, title: "注释",
            parameters: ["modelID": .text("")])
        let unknown = WorkflowNode(operationID: modelDefinition.id, title: "注释",
            parameters: ["modelID": .text("text:exact-unavailable")])
        let empty = WorkflowNodeIdentity.resolve(node: unbound, definition: modelDefinition,
            modelChoices: [], assets: [], tools: [], language: nil)
        let missing = WorkflowNodeIdentity.resolve(node: unknown, definition: modelDefinition,
            modelChoices: [], assets: [], tools: [], language: nil)
        #expect(empty.title == "选择模型" && empty.detail == nil)
        #expect(missing.title == "未识别的模型")
        #expect(missing.detail == "text:exact-unavailable")
    }

    @Test func toolNameRequiresExactVersionAndDigest() throws {
        let tool = WorkflowToolDefinition(name: "固定工具", graph: WorkflowGraph())
        let reference = WorkflowToolReference(id: tool.id, version: tool.version,
            digest: try WorkflowPlanCompiler.digest(tool))
        var node = WorkflowNode(operationID: "d.control.invoke", title: "任务注释")
        node.control = .invoke(reference)
        let exact = WorkflowNodeIdentity.resolve(node: node, definition: nil,
            modelChoices: [], assets: [], tools: [tool], language: nil)
        #expect(exact.title == "固定工具")
        node.control = .invoke(.init(id: tool.id, version: tool.version, digest: "changed"))
        let changed = WorkflowNodeIdentity.resolve(node: node, definition: nil,
            modelChoices: [], assets: [], tools: [tool], language: nil)
        #expect(changed.title == "未识别的工具")
    }

    @Test func viewMemorySeparatesNestedBodiesAndRestoresSelection() {
        let project = UUID(), root = UUID(), node = UUID()
        let outer = WorkflowCanvasViewContext(projectID: project, rootGraphID: root, bodyPath: [])
        let inner = WorkflowCanvasViewContext(projectID: project, rootGraphID: root,
            bodyPath: [.init(nodeID: node, slot: "body")])
        var memory = WorkflowCanvasViewStateStore()
        let outerState = WorkflowCanvasViewMemory(zoom: 1.8,
            scrollPoint: CGPoint(x: 440, y: 210), selectedNodeID: node)
        let innerState = WorkflowCanvasViewMemory(zoom: 0.5,
            scrollPoint: CGPoint(x: 20, y: 90), selectedNodeID: nil)
        memory.save(outerState, for: outer)
        memory.save(innerState, for: inner)
        #expect(memory.state(for: outer) == outerState)
        #expect(memory.state(for: inner) == innerState)
        #expect(memory.state(for: .init(projectID: UUID(), rootGraphID: root, bodyPath: [])) == nil)
    }

    @Test func visibleInsertionPointUsesCurrentZoomAndScroll() {
        let offset = CGPoint(x: 120, y: 80)
        let container = CGSize(width: 500, height: 400)
        let translation = CGSize(width: 180, height: 260)
        let half = WorkflowCanvasViewport.visibleRawCenter(contentOffset: offset,
            containerSize: container, zoom: 0.5, translation: translation)
        let normal = WorkflowCanvasViewport.visibleRawCenter(contentOffset: offset,
            containerSize: container, zoom: 1, translation: translation)
        let enlarged = WorkflowCanvasViewport.visibleRawCenter(contentOffset: offset,
            containerSize: container, zoom: 1.8, translation: translation)
        #expect(half == CGPoint(x: 560, y: 300))
        #expect(normal == CGPoint(x: 190, y: 20))
        #expect(abs(enlarged.x - 25.5555) < 0.01)
        #expect(abs(enlarged.y + 104.4444) < 0.01)
    }

    @Test func outputTransferRejectsOldScope() {
        let root = UUID(), graph = UUID(), node = UUID(), revision = UUID()
        let old = WorkflowCanvasTransfer.output(rootGraphID: root, bodyPath: [],
            graphID: graph, revision: revision, nodeID: node, port: "output")
        let current = WorkflowCanvasScope(rootGraphID: root, rootRevision: UUID(),
            graphID: graph, bodyPath: [])
        #expect(!old.matchesOutputScope(current))
    }

    @Test func connectionFailureNamesIncompatibleAndOccupiedInputs() throws {
        let source = WorkflowOperationDefinition(id: "fixture.source", title: "source", detail: "",
            inputs: [], outputs: [.init("text", "text", kinds: [.text]),
                                  .init("image", "image", kinds: [.image])])
        let target = WorkflowOperationDefinition(id: "fixture.target", title: "target", detail: "",
            inputs: [.init("input", "input", kinds: [.text])], outputs: [])
        let registry = try WorkflowRegistry(operations: [
            .init(definition: source, execute: { _, _ in throw WorkflowIssue("test only") }),
            .init(definition: target, execute: { _, _ in throw WorkflowIssue("test only") }),
        ])
        let a = source.makeNode(), b = target.makeNode(), c = source.makeNode()
        var graph = WorkflowGraph(nodes: [a, b, c])
        #expect(WorkflowCanvasConnectionPolicy.issue(graph: graph, registry: registry, tools: [],
            sourceNodeID: a.id, sourcePort: "image", targetNodeID: b.id, targetPort: "input") == .incompatibleKind)
        graph.connections = [.init(sourceNode: a.id, sourcePort: "text",
                                   targetNode: b.id, targetPort: "input")]
        #expect(WorkflowCanvasConnectionPolicy.issue(graph: graph, registry: registry, tools: [],
            sourceNodeID: a.id, sourcePort: "text", targetNodeID: b.id, targetPort: "input") == .duplicate)
        #expect(WorkflowCanvasConnectionPolicy.issue(graph: graph, registry: registry, tools: [],
            sourceNodeID: c.id, sourcePort: "text", targetNodeID: b.id, targetPort: "input") == .occupiedInput)
    }
}
