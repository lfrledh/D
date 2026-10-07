import DWorkbench
import Foundation
import SwiftUI
import Testing
@testable import UI

@Suite @MainActor
struct WorkflowCanvasPresentationTests {
    @Test
    func publicCanvasTypeIsVisibleWithoutInventingAController() {
        let type: WorkflowCanvasView.Type = WorkflowCanvasView.self
        #expect(String(describing: type) == "WorkflowCanvasView")
    }

    @Test
    func panelPolicyFitsBothLibrariesAtMinimumWindowWithoutOuterScroll() {
        for width: CGFloat in [760, 860, 1_100, 1_420] {
            #expect(!WorkflowCanvasLayoutPolicy.usesHorizontalPanelScroll(width: width))
        }
        #expect(WorkflowCanvasLayoutPolicy.libraryWidth * 2
                + WorkflowCanvasLayoutPolicy.canvasMinimumWidth + 2 <= WorkflowCanvasLayoutPolicy.minimumVisibleWidth)
    }

    @Test
    func zoomIsBoundedAndFallbackLayoutIsDeterministic() {
        #expect(WorkflowCanvasLayoutPolicy.clampedZoom(0.1) == 0.1)
        #expect(WorkflowCanvasLayoutPolicy.clampedZoom(0) == 0.05)
        #expect(WorkflowCanvasLayoutPolicy.clampedZoom(1.25) == 1.25)
        #expect(WorkflowCanvasLayoutPolicy.clampedZoom(4) == 1.8)

        #expect(WorkflowCanvasLayoutPolicy.fallbackPosition(index: 0) == CGPoint(x: 170, y: 130))
        #expect(WorkflowCanvasLayoutPolicy.fallbackPosition(index: 3) == CGPoint(x: 1_070, y: 130))
        #expect(WorkflowCanvasLayoutPolicy.fallbackPosition(index: 4) == CGPoint(x: 170, y: 380))
    }

    @Test
    func graphGeometryPreservesStoredCoordinatesAndMakesNegativeLayoutsReachable() {
        let first = WorkflowNode(id: UUID(), operationID: "d.text.input", title: "第一")
        let second = WorkflowNode(id: UUID(), operationID: "d.text.confirm", title: "第二")
        let graph = WorkflowGraph(
            nodes: [first, second],
            layout: [
                WorkflowLayout(nodeID: first.id, x: -240, y: -80),
                WorkflowLayout(nodeID: second.id, x: 420, y: 260)
            ]
        )

        let geometry = WorkflowGraphGeometry(graph: graph)
        #expect(geometry.rawPosition(first.id) == CGPoint(x: -240, y: -80))
        #expect(geometry.rawPosition(second.id) == CGPoint(x: 420, y: 260))
        #expect(geometry.displayPosition(first.id).x >= 150)
        #expect(geometry.displayPosition(first.id).y >= 110)
        #expect(geometry.displayPosition(second.id).x > geometry.displayPosition(first.id).x)
        #expect(geometry.size.width >= 1_400)
        #expect(geometry.size.height >= 900)
    }

    @Test
    func graphGeometryUsesTheSameRegistryAsTheCards() throws {
        let definition = WorkflowOperationDefinition(id: "fixture.manyPorts", title: "Ports", detail: "",
            inputs: (0..<20).map { .init("i\($0)", "Input \($0)", kinds: [.text]) },
            outputs: [.init("output", "Output", kinds: [.text])])
        let registry = try WorkflowRegistry(operations: [.init(definition: definition,
            execute: { _, _ in throw WorkflowIssue("Geometry must not execute") })])
        let node = definition.makeNode()
        let graph = WorkflowGraph(nodes: [node], layout: [.init(nodeID: node.id, x: 0, y: -20)])
        let geometry = WorkflowGraphGeometry(graph: graph, registry: registry)
        let halfHeight = WorkflowLayout.cardHeightBudget(inputs: 20, outputs: 1) / 2
        #expect(geometry.displayPosition(node.id).y - halfHeight >= 24)
        #expect(geometry.displayPosition(node.id).y + halfHeight <= geometry.size.height - 24)
        #expect(geometry.rawPosition(node.id) == CGPoint(x: 0, y: -20))
    }

    @Test
    func graphGeometryFallsBackOnlyForNodesWithoutStoredLayout() {
        let laidOut = WorkflowNode(id: UUID(), operationID: "d.text.input", title: "固定")
        let fallback = WorkflowNode(id: UUID(), operationID: "d.text.confirm", title: "回退")
        let graph = WorkflowGraph(
            nodes: [laidOut, fallback],
            layout: [WorkflowLayout(nodeID: laidOut.id, x: 500, y: 600)]
        )

        let geometry = WorkflowGraphGeometry(graph: graph)
        #expect(geometry.rawPosition(laidOut.id) == CGPoint(x: 500, y: 600))
        #expect(geometry.rawPosition(fallback.id)
                == WorkflowCanvasLayoutPolicy.fallbackPosition(index: 1))
    }

    @Test
    func portDescriptionsExposeKindsAndRequirementWithoutUsingCopyAsSchema() {
        let required = WorkflowPortDefinition("input", "输入", kinds: [.text, .image])
        let optional = WorkflowPortDefinition("reference", "参考", kinds: [.image], required: false)

        #expect(WorkflowCanvasPresentation.portDetail(required) == "文字/图像 · 必选")
        #expect(WorkflowCanvasPresentation.portDetail(optional) == "图像 · 可选")
        #expect(WorkflowCanvasPresentation.kind(.images) == "图像集合")
        #expect(WorkflowCanvasPresentation.kind(.receipt) == "导出回执")
    }

    @Test
    func controllerPlanStringsRemainOpaqueAndInOrder() {
        let opaque = [
            "执行：节点 A → 不应拆词",
            "reuse??? {\"unknown\":true}",
            "等待确认\n保留换行"
        ]
        let displayed = WorkflowCanvasPresentation.planLines(opaque)
        #expect(displayed == opaque)
    }

    @Test
    func ReadOnlyReasonGatesAllMutationsButDoesNotRepresentPreviewState() {
        #expect(WorkflowCanvasPresentation.allowsMutation(readOnlyReason: nil))
        #expect(!WorkflowCanvasPresentation.allowsMutation(readOnlyReason: "未知版本，仅可查看"))
    }

    @Test(arguments: [
        WorkflowStepStatus.waiting,
        .interrupted,
        .saving,
        .partial,
        .failed
    ])
    func recoverableRunStatesOfferResume(status: WorkflowStepStatus) {
        #expect(WorkflowCanvasPresentation.canResume(status))
    }

    @Test(arguments: [
        WorkflowStepStatus.queued,
        .running,
        .completed,
        .cancelling,
        .cancelled,
        .rejected
    ])
    func terminalOrActiveRunStatesDoNotOfferResume(status: WorkflowStepStatus) {
        #expect(!WorkflowCanvasPresentation.canResume(status))
    }

    @Test func connectionInspectionKeepsConcreteCallsAndNeverInventsCurrentOutput() {
        let source = WorkflowNode(operationID: "d.model.language", title: "model")
        let target = WorkflowNode(operationID: "d.value.return", title: "target")
        let edge = WorkflowConnection(sourceNode: source.id, sourcePort: "output", targetNode: target.id, targetPort: "input")
        let graph = WorkflowGraph(nodes: [source, target], connections: [edge])
        let map = WorkflowNode(operationID: "d.control.map", title: "map")
        let body = WorkflowPlan(graphID: graph.id, graphRevision: graph.revision, steps: [.init(node: target, inputs: [])])
        let plan = WorkflowPlan(graphID: UUID(), graphRevision: UUID(), steps: [.init(node: map, inputs: [], kind: .map(body: body, continueOnFailure: true))])
        var run = WorkflowRun(graph: graph, targetNodeID: target.id)
        var first = WorkflowStepRun(node: target, signature: "a"), second = WorkflowStepRun(node: target, signature: "b")
        first.inputs = ["input": .data(.text("first item"))]; second.inputs = ["input": .data(.text("second item"))]
        let records: [WorkflowPlanCallRecord] = [
            .init(address: .init(runID: run.id, path: [.node(map.id), .item("a"), .node(target.id)]), step: first),
            .init(address: .init(runID: run.id, path: [.node(map.id), .item("b"), .node(target.id)]), step: second),
        ]
        run.planCheckpoint = .init(runID: run.id, plan: plan, records: records)
        let values = WorkflowConnectionPresentation.snapshots(edge, graphID: graph.id, runs: [run])
        #expect(values.count == 2)
        #expect(WorkflowConnectionPresentation.snapshots(edge, graphID: UUID(), runs: [run]).isEmpty)
        // Same node IDs in a copied graph are not the original tool body identity.
        var copied = graph; copied.id = UUID()
        #expect(WorkflowConnectionPresentation.snapshots(edge, graphID: copied.id, runs: [run]).isEmpty)
        #expect(values.map(\.value) == [first.inputs["input"]!, second.inputs["input"]!])
        #expect(values.map(\.address) == records.map { $0.address.path })
        #expect(Set(values.map(\.id)).count == 2)
        #expect(WorkflowConnectionPresentation.configuredValue(source: source) == nil)
        var differentPort = edge; differentPort.targetPort = "missing"
        #expect(WorkflowConnectionPresentation.snapshots(differentPort, graphID: graph.id, runs: [run]).isEmpty)
        var literal = WorkflowNode(operationID: "d.value.input", title: "value")
        literal.dataConfiguration = .init(value: .text("new setting"))
        #expect(WorkflowConnectionPresentation.configuredValue(source: literal) == .data(.text("new setting")))
        #expect(values[0].value == .data(.text("first item")))
    }

    @Test
    func connectionIdentityDisplaysOnlyStableSourceInformation() throws {
        let source = try #require(UUID(uuidString: "12345678-1234-1234-1234-1234567890ab"))
        let connection = WorkflowConnection(sourceNode: source, sourcePort: "output",
                                            targetNode: UUID(), targetPort: "input")
        #expect(WorkflowCanvasPresentation.connectionIdentity(connection) == "12345678.output")
    }
}
