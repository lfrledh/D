import AppKit
import DWorkbench
import Testing
@testable import UI

@Suite @MainActor
struct WorkflowCanvasViewportTests {
    @Test func cancelledPanAllowsBlankClickAndStartsAtNewObservedOffset() {
        var session = WorkflowCanvasPanSession()
        let first = CGPoint(x: 430, y: 280)
        #expect(session.startIfNeeded(at: first) == first)
        #expect(session.suppressBlankTap)
        #expect(session.startIfNeeded(at: CGPoint(x: 200, y: 100)) == first)
        session.reset() // @GestureState deactivation or a graph scope change
        #expect(session.startOffset == nil && !session.suppressBlankTap)
        let actualAfterCancellation = CGPoint(x: 612, y: 335)
        #expect(session.startIfNeeded(at: actualAfterCancellation) == actualAfterCancellation)
    }

    @Test func mouseAnchorAndVisibleCenterRoundTripAcrossZoomAndNegativeNodes() {
        let node = WorkflowNode(operationID: "d.text.input", title: "negative")
        let graph = WorkflowGraph(nodes: [node], layout: [
            .init(nodeID: node.id, x: -620, y: -290)
        ])
        let graphGeometry = WorkflowGraphGeometry(graph: graph)
        let viewport = CGSize(width: 460, height: 330)
        let offset = CGPoint(x: 900, y: 710)
        let mouse = CGPoint(x: 71, y: 212)
        for first: CGFloat in [0.5, 1, 1.8] {
            let before = WorkflowCanvasViewportGeometry(graphSize: graphGeometry.size,
                viewportSize: viewport, zoom: first, translation: graphGeometry.translation)
            let anchor = before.rawPoint(screenPoint: mouse, offset: offset)
            for second: CGFloat in [0.5, 1, 1.8] {
                let after = WorkflowCanvasViewportGeometry(graphSize: graphGeometry.size,
                    viewportSize: viewport, zoom: second, translation: graphGeometry.translation)
                let target = after.offset(rawPoint: anchor, at: mouse)
                let restored = after.rawPoint(screenPoint: mouse, offset: target)
                #expect(abs(restored.x - anchor.x) < 0.0001)
                #expect(abs(restored.y - anchor.y) < 0.0001)
                for edgeOffset in [CGPoint.zero,
                                   CGPoint(x: before.contentSize.width - viewport.width,
                                           y: before.contentSize.height - viewport.height)] {
                    let edgeRaw = before.rawPoint(screenPoint: mouse, offset: edgeOffset)
                    let limited = before.anchoredZoom(toward: second, mouse: mouse, offset: edgeOffset)
                    let allowed = WorkflowCanvasViewportGeometry(graphSize: graphGeometry.size,
                        viewportSize: viewport, zoom: limited.zoom, translation: graphGeometry.translation)
                    let kept = allowed.rawPoint(screenPoint: mouse, offset: limited.offset)
                    #expect(abs(kept.x - edgeRaw.x) < 0.0001)
                    #expect(abs(kept.y - edgeRaw.y) < 0.0001)
                    #expect(limited.offset.x >= 0 && limited.offset.y >= 0)
                    #expect(limited.offset.x <= allowed.contentSize.width - viewport.width)
                    #expect(limited.offset.y <= allowed.contentSize.height - viewport.height)
                }
            }
            let center = before.visibleRawCenter(offset: offset)
            let centered = before.centeredOffset(on: center)
            #expect(abs(centered.x - offset.x) < 0.0001)
            #expect(abs(centered.y - offset.y) < 0.0001)
            #expect(before.padding.width >= viewport.width)
            #expect(before.padding.height >= viewport.height)
            #expect(abs(before.unscaledPadding.width - viewport.width / 0.5) < 0.0001)
            #expect(abs(before.unscaledPadding.height - viewport.height / 0.5) < 0.0001)
            #expect(before.contentSize.width >= viewport.width * 3)
            #expect(before.contentSize.height >= viewport.height * 3)
        }
    }

    @Test func zoomBoundsDoNotMoveTheViewportAndEveryPanDirectionHasSpace() {
        let size = CGSize(width: 1400, height: 900)
        let viewport = CGSize(width: 440, height: 310)
        for zoom: CGFloat in [0.05, 0.5, 1, 1.8] {
            let layout = WorkflowCanvasViewportGeometry(graphSize: size, viewportSize: viewport,
                zoom: zoom, translation: CGSize(width: 150, height: 24))
            let initial = layout.centeredOffset(on: layout.centerRawPoint)
            let maximum = CGPoint(x: layout.contentSize.width - viewport.width,
                                  y: layout.contentSize.height - viewport.height)
            for delta in [CGSize(width: 80, height: 0), CGSize(width: -80, height: 0),
                          CGSize(width: 0, height: 80), CGSize(width: 0, height: -80)] {
                let moved = layout.pannedOffset(from: initial, translation: delta)
                #expect(moved.x >= 0 && moved.x <= maximum.x)
                #expect(moved.y >= 0 && moved.y <= maximum.y)
                #expect(moved != initial)
            }
            let blocked = WorkflowCanvasLayoutPolicy.clampedZoom(
                zoom == 0.05 ? zoom * 0.2 : zoom == 1.8 ? zoom * 3 : zoom)
            if zoom == 0.05 || zoom == 1.8 { #expect(blocked == zoom) }
            #expect(layout.centeredOffset(on: layout.centerRawPoint) == initial)
        }
    }

    @Test func middleAndResetUseContentCenterWithoutChangingGraphPositions() {
        let node = WorkflowNode(operationID: "d.text.input", title: "node")
        let graph = WorkflowGraph(nodes: [node], layout: [
            .init(nodeID: node.id, x: -390, y: 175)
        ])
        let geometry = WorkflowGraphGeometry(graph: graph)
        let viewport = CGSize(width: 520, height: 380)
        let beforeGraph = graph
        let beforePosition = geometry.rawPosition(node.id)
        let middle = WorkflowCanvasViewportGeometry(graphSize: geometry.size, viewportSize: viewport,
            zoom: 1.8, translation: geometry.translation)
        let recentered = middle.centeredOffset(on: middle.centerRawPoint)
        let middleCenter = middle.visibleRawCenter(offset: recentered)
        #expect(abs(middleCenter.x - middle.centerRawPoint.x) < 0.0001)
        #expect(abs(middleCenter.y - middle.centerRawPoint.y) < 0.0001)
        #expect(middle.zoom == 1.8)
        let reset = WorkflowCanvasViewportGeometry(graphSize: geometry.size, viewportSize: viewport,
            zoom: 1, translation: geometry.translation)
        let resetCenter = reset.visibleRawCenter(offset: reset.centeredOffset(on: reset.centerRawPoint))
        #expect(abs(resetCenter.x - reset.centerRawPoint.x) < 0.0001)
        #expect(abs(resetCenter.y - reset.centerRawPoint.y) < 0.0001)
        #expect(graph == beforeGraph && geometry.rawPosition(node.id) == beforePosition)
    }

    @Test func resizeAndWindowSpecificOffsetsPreserveLogicalCenter() {
        let graphSize = CGSize(width: 1600, height: 1000)
        let translation = CGSize(width: 260, height: 180)
        let first = WorkflowCanvasViewportGeometry(graphSize: graphSize,
            viewportSize: CGSize(width: 400, height: 300), zoom: 0.5, translation: translation)
        let visible = first.visibleRawCenter(offset: CGPoint(x: 430, y: 280))
        for viewport in [CGSize(width: 850, height: 500), CGSize(width: 320, height: 280)] {
            let otherWindow = WorkflowCanvasViewportGeometry(graphSize: graphSize,
                viewportSize: viewport, zoom: 1.8, translation: translation)
            let offset = otherWindow.centeredOffset(on: visible)
            let restored = otherWindow.visibleRawCenter(offset: offset)
            #expect(abs(restored.x - visible.x) < 0.0001)
            #expect(abs(restored.y - visible.y) < 0.0001)
        }
    }
}
