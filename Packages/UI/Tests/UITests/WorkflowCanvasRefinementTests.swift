import DWorkbench
import Foundation
import SwiftUI
import Testing
@testable import UI

@Suite @MainActor
struct WorkflowCanvasRefinementTests {
    @Test
    func portColorClassificationUsesContractAndLeavesUnionsNeutral() {
        #expect(WorkflowPortStyle.kind(for: .init("text", "Any title", kinds: [.text])) == .text)
        #expect(WorkflowPortStyle.kind(for: .init("images", "Any title", kinds: [.image, .list],
                                                   assetListKind: .image)) == .image)
        #expect(WorkflowPortStyle.kind(for: .init("list", "Image list", kinds: [.list],
                                                   assetListKind: .image)) == .image)
        #expect(WorkflowPortStyle.kind(for: .init("union", "Image", kinds: [.text, .image])) == nil)
        #expect(WorkflowPortStyle.kind(for: .init("generic", "Image", kinds: [.list])) == .list)
        #expect(WorkflowPortStyle.kind(for: .init("conflict", "Image", kinds: [.audio, .list],
                                                   assetListKind: .image)) == nil)
    }

    @Test
    func fitUsesBoundsWithoutChangingAnyStoredLayout() throws {
        let node = WorkflowNode(operationID: "d.text.input", title: "Large graph")
        let layout = WorkflowLayout(nodeID: node.id, x: -2_000, y: 1_200, collapsed: true)
        let graph = WorkflowGraph(nodes: [node], layout: [layout])
        let fitted = try #require(WorkflowCanvasFit.view(
            for: CGRect(x: -2_120, y: 1_000, width: 2_400, height: 1_200),
            viewport: CGSize(width: 780, height: 540)))
        #expect(fitted.center == CGPoint(x: -920, y: 1_600))
        #expect(fitted.zoom < 0.5)
        #expect(graph.layout == [layout])
    }

    @Test
    func fitKeepsWidelySeparatedCardsInsideTheViewportBelowFivePercent() throws {
        let first = WorkflowNode(operationID: "d.text.input", title: "First")
        let second = WorkflowNode(operationID: "d.text.input", title: "Second")
        let layouts = [WorkflowLayout(nodeID: first.id, x: 0, y: 0),
                       WorkflowLayout(nodeID: second.id, x: 5_760, y: 0)]
        let graph = WorkflowGraph(nodes: [first, second], layout: layouts)
        let viewport = CGSize(width: 260, height: 400)
        let bounds = CGRect(x: -120, y: -100, width: 6_000, height: 200)
        let fitted = try #require(WorkflowCanvasFit.view(for: bounds, viewport: viewport))
        #expect(abs(fitted.zoom - 0.034) < 0.000_001)
        let geometry = WorkflowGraphGeometry(graph: graph)
        let screen = WorkflowCanvasViewportGeometry(graphSize: geometry.size,
            viewportSize: viewport, zoom: fitted.zoom, translation: geometry.translation)
        let offset = screen.centeredOffset(on: fitted.center)
        let left = screen.offset(rawPoint: CGPoint(x: bounds.minX, y: 0), at: .zero).x - offset.x
        let right = screen.offset(rawPoint: CGPoint(x: bounds.maxX, y: 0), at: .zero).x - offset.x
        #expect(abs(left - 28) < 0.001)
        #expect(abs(right - 232) < 0.001)
        #expect(graph.layout == layouts)
    }

    @Test
    func fitHonorsNegativePositionsAndBothAxisLimits() throws {
        let bounds = CGRect(x: -4_120, y: -8_140, width: 6_000, height: 12_000)
        let viewport = CGSize(width: 260, height: 320)
        let fitted = try #require(WorkflowCanvasFit.view(for: bounds, viewport: viewport))
        #expect(abs(fitted.zoom - 0.022) < 0.000_001)
        #expect(fitted.center == CGPoint(x: -1_120, y: -2_140))
        let screen = WorkflowCanvasViewportGeometry(graphSize: CGSize(width: 7_000, height: 13_000),
            viewportSize: viewport, zoom: fitted.zoom, translation: CGSize(width: 4_300, height: 8_300))
        let offset = screen.centeredOffset(on: fitted.center)
        let top = screen.offset(rawPoint: CGPoint(x: 0, y: bounds.minY), at: .zero).y - offset.y
        let bottom = screen.offset(rawPoint: CGPoint(x: 0, y: bounds.maxY), at: .zero).y - offset.y
        #expect(abs(top - 28) < 0.001)
        #expect(abs(bottom - 292) < 0.001)
        #expect(WorkflowCanvasLayoutPolicy.restoredZoom(fitted.zoom) == fitted.zoom)
        #expect(WorkflowCanvasLayoutPolicy.clampedInteractiveZoom(fitted.zoom * 0.9,
            current: fitted.zoom) == fitted.zoom)
        #expect(WorkflowCanvasLayoutPolicy.clampedInteractiveZoom(0.05,
            current: fitted.zoom) == 0.05)
    }

    @Test
    func handConnectionSubmissionLeavesGraphAndUndoUntouched() throws {
        let source = WorkflowNode(operationID: "d.text.input", title: "Source")
        let target = WorkflowNode(operationID: "d.text.confirm", title: "Target")
        var graph = WorkflowGraph(nodes: [source, target])
        let original = graph
        let scope = WorkflowCanvasScope(rootGraphID: graph.id, rootRevision: graph.revision,
                                        graphID: graph.id, bodyPath: [])
        let payload = try WorkflowCanvasTransfer.output(
            rootGraphID: graph.id, bodyPath: [], graphID: graph.id,
            revision: graph.revision, nodeID: source.id, port: "output").validated()
        #expect(payload.matchesOutputScope(scope))
        var undoStack: [WorkflowGraph] = []
        let submit = {
            undoStack.append(graph)
            graph.connections.append(.init(sourceNode: source.id, sourcePort: "output",
                                           targetNode: target.id, targetPort: "input"))
        }
        #expect(!WorkflowCanvasConnectionSubmission.submit(tool: .hand, submit))
        #expect(graph == original && undoStack.isEmpty)
        #expect(WorkflowCanvasConnectionSubmission.submit(tool: .pointer, submit))
        #expect(graph.connections.count == 1 && undoStack == [original])
    }

    @Test
    func viewportProbeCallbacksShareSelectionNavigationGate() {
        let probe = WorkflowCanvasViewportInput.ProbeView()
        var selecting = true
        var locked = true
        var wheelCalls = 0
        var middleCalls = 0
        probe.navigationAllowed = {
            WorkflowCanvasViewportNavigationGate.allows(
                marqueeActive: selecting, interactionLocked: locked,
                nodeDragging: false, outputDragging: false)
        }
        probe.allowsEvent = { _, _, _ in true }
        probe.onWheel = { _, _, _, _ in wheelCalls += 1 }
        probe.onMiddleClick = { _ in middleCalls += 1 }
        let viewport = CGSize(width: 260, height: 300)
        #expect(!probe.allowsViewportEvent(.zero, .zero, viewport))
        #expect(!probe.dispatchWheel(1, .zero, .zero, viewport))
        #expect(!probe.dispatchMiddleClick(viewport))
        #expect(wheelCalls == 0 && middleCalls == 0)
        selecting = false
        #expect(!probe.allowsViewportEvent(.zero, .zero, viewport))
        #expect(!probe.dispatchWheel(1, .zero, .zero, viewport))
        #expect(!probe.dispatchMiddleClick(viewport))
        locked = false
        #expect(probe.allowsViewportEvent(.zero, .zero, viewport))
        #expect(probe.dispatchWheel(1, .zero, .zero, viewport))
        #expect(probe.dispatchMiddleClick(viewport))
        #expect(wheelCalls == 1 && middleCalls == 1)
    }

    @Test
    func groupPreviewMovesEveryCapturedNodeByTheSameRawDelta() {
        let a = UUID(), b = UUID()
        let scope = WorkflowCanvasScope(rootGraphID: UUID(), rootRevision: UUID(),
                                        graphID: UUID(), bodyPath: [])
        var drag = WorkflowCanvasNodeDragState(sessionID: UUID(), scope: scope, nodeID: a,
            originalPosition: CGPoint(x: 20, y: 30), origin: .zero,
            originalPositions: [a: CGPoint(x: 20, y: 30), b: CGPoint(x: -10, y: 80)])
        drag.update(screenTranslation: CGSize(width: 40, height: -20), zoom: 2)
        #expect(drag.previewPositions[a] == CGPoint(x: 40, y: 20))
        #expect(drag.previewPositions[b] == CGPoint(x: 10, y: 70))
    }

    @Test
    func dragUsesActualFitZoomAndRejectsInvalidPositions() {
        let original = CGPoint(x: 20, y: 30)
        let translation = CGSize(width: 10, height: -5)
        #expect(WorkflowCanvasDragGeometry.rawPosition(
            original: original, screenTranslation: translation, zoom: 0.005)
            == CGPoint(x: 2_020, y: -970))
        for zoom in [CGFloat.zero, .nan, .infinity] {
            #expect(WorkflowCanvasDragGeometry.rawPosition(
                original: original, screenTranslation: translation, zoom: zoom) == original)
        }
        #expect(WorkflowCanvasDragGeometry.rawPosition(
            original: original, screenTranslation: CGSize(width: CGFloat.infinity, height: 0),
            zoom: 0.005) == original)
    }

    @Test
    func marqueeUsesDisplayedGraphCoordinatesAndAddsShiftBaseline() {
        let a = WorkflowNode(operationID: "d.text.input", title: "A")
        let b = WorkflowNode(operationID: "d.text.input", title: "B")
        let graph = WorkflowGraph(nodes: [a, b], layout: [
            .init(nodeID: a.id, x: -300, y: 100),
            .init(nodeID: b.id, x: 500, y: 100)
        ])
        let geometry = WorkflowGraphGeometry(graph: graph)
        let scope = WorkflowCanvasScope(rootGraphID: graph.id, rootRevision: graph.revision,
                                        graphID: graph.id, bodyPath: [])
        let center = geometry.displayPosition(a.id)
        let marquee = WorkflowCanvasMarquee(scope: scope,
            start: CGPoint(x: center.x - 15, y: center.y - 15),
            current: CGPoint(x: center.x + 15, y: center.y + 15), baseline: [b.id])
        #expect(marquee.selectedIDs(geometry: geometry, cardSizes: [:], edge: .zero) == [a.id, b.id])
    }
    @Test func narrowPanelsDoNotOverrideTheUsersWidePreferences() {
        let narrow = WorkflowCanvasLayoutPolicy.visiblePanels(width: 860, library: true, inspector: true, preferLibrary: false)
        #expect(!narrow.library && narrow.inspector)
        let chooseLibrary = WorkflowCanvasLayoutPolicy.visiblePanels(width: 860, library: true, inspector: true, preferLibrary: true)
        #expect(chooseLibrary.library && !chooseLibrary.inspector)
        let wide = WorkflowCanvasLayoutPolicy.visiblePanels(width: 1280, library: true, inspector: true, preferLibrary: true)
        #expect(wide.library && wide.inspector)
        let closed = WorkflowCanvasLayoutPolicy.visiblePanels(width: 1280, library: false, inspector: false, preferLibrary: false)
        #expect(!closed.library && !closed.inspector)
    }

}
