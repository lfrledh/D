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
    func panelPolicyKeepsThreeColumnsAtContractWidthAndScrollsBelowIt() {
        #expect(!WorkflowCanvasLayoutPolicy.usesHorizontalPanelScroll(width: 1_100))
        #expect(!WorkflowCanvasLayoutPolicy.usesHorizontalPanelScroll(width: 1_420))
        #expect(WorkflowCanvasLayoutPolicy.usesHorizontalPanelScroll(width: 1_099))
        #expect(WorkflowCanvasLayoutPolicy.minimumWorkspaceWidth == 1_100)
        #expect(WorkflowCanvasLayoutPolicy.libraryWidth
                + WorkflowCanvasLayoutPolicy.canvasMinimumWidth
                + WorkflowCanvasLayoutPolicy.inspectorWidth == 1_100)
    }

    @Test
    func zoomIsBoundedAndFallbackLayoutIsDeterministic() {
        #expect(WorkflowCanvasLayoutPolicy.clampedZoom(0.1) == 0.5)
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

    @Test
    func connectionIdentityDisplaysOnlyStableSourceInformation() throws {
        let source = try #require(UUID(uuidString: "12345678-1234-1234-1234-1234567890ab"))
        let connection = WorkflowConnection(sourceNode: source, sourcePort: "output",
                                            targetNode: UUID(), targetPort: "input")
        #expect(WorkflowCanvasPresentation.connectionIdentity(connection) == "12345678.output")
    }
}
