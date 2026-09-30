import AppKit
import DInference
import DWorkbench
import Foundation
import SwiftUI
import Testing
@testable import UI

private actor ViewportNoInferenceEngine: InferenceEngine {
    private(set) var calls = 0
    func submit(_ request: InferenceRequest, backendID: String) async throws -> InferenceRun {
        calls += 1
        throw WorkflowIssue("Canvas navigation must not run inference")
    }
}

@MainActor private final class ViewportLayerVisibility: ObservableObject {
    @Published var quickVisible = false
}

@MainActor private struct ViewportDualLayerHost: View {
    @ObservedObject var visibility: ViewportLayerVisibility
    let canvas: WorkflowCanvasView
    @State private var quickValue = 0.5
    @State private var quickDraft = "draft"

    var body: some View {
        ZStack {
            VStack {
                TextField("Quick editor", text: $quickDraft)
                Slider(value: $quickValue)
                Button("Quick action") {}
            }
            .frame(width: 280)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.gray)
            .opacity(visibility.quickVisible ? 1 : 0)
            .allowsHitTesting(visibility.quickVisible)
            canvas.opacity(visibility.quickVisible ? 0 : 1)
                .allowsHitTesting(!visibility.quickVisible)
        }
    }
}

@Suite(.serialized) @MainActor
struct WorkflowCanvasViewportHostingTests {
    @Test func nativeWindowWheelAndMiddleClickStayInsideVisibleCanvas() async throws {
        let temporaryRoot = try #require(ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"])
        let root = URL(fileURLWithPath: temporaryRoot)
            .appendingPathComponent("canvas-viewport-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await ProjectStore.create(at: root.appendingPathComponent("Viewport.dproject"), name: "Viewport")
        let engine = ViewportNoInferenceEngine()
        let runtime = WorkbenchSession(engine: engine, backendID: "never",
            status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) },
            shutdown: {}, cleanup: {}, validateModel: { _ in })
        let services = WorkflowServices(store: store, session: runtime,
            resolveText: { throw WorkflowIssue("No model in viewport test") },
            resolveImage: { throw WorkflowIssue("No model in viewport test") })
        let controller = WorkflowController(services: services)
        await controller.load()
        let asset = root.appendingPathComponent("source.txt")
        try Data("existing asset".utf8).write(to: asset)
        await controller.importLibraryFile(asset)
        #expect(controller.errorMessage == nil && !controller.availableAssets.isEmpty)
        controller.addExample("template")
        let target = try #require(controller.graph?.nodes.last?.id)
        await controller.run(target: target, only: false)
        let existingCalls = await engine.calls
        #expect(!controller.runs.isEmpty && existingCalls == 0)
        let graphBefore = controller.graphs
        let assetsBefore = controller.availableAssets
        let runsBefore = controller.runs
        let undoBefore = controller.canUndo
        var observations: [WorkflowCanvasScrollObservation] = []
        var cardSizes: [UUID: CGSize] = [:]
        var portCenters: [WorkflowPortIdentity: CGPoint] = [:]
        var lockChanges: [Bool] = []
        let view = WorkflowCanvasView(controller: controller, onTextModel: {}, onImageModel: {},
            onImport: { _ in }, onDestination: {}, onPublishText: {}, onReturnText: { _ in })
            .observingScroll { _, observation in observations.append(observation) }
            .observingNodeSizes { id, size in cardSizes[id] = size }
            .observingPortCenters { portCenters = $0 }
            .observingViewportLock { lockChanges.append($0) }
        let visibility = ViewportLayerVisibility()
        let host = NSHostingView(rootView: ViewportDualLayerHost(visibility: visibility, canvas: view))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1100, height: 740),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        func descendants(_ view: NSView) -> [NSView] {
            view.subviews.flatMap { [$0] + descendants($0) }
        }
        var probe: WorkflowCanvasViewportInput.ProbeView?
        for _ in 0..<40 {
            host.layoutSubtreeIfNeeded()
            probe = descendants(host).compactMap { $0 as? WorkflowCanvasViewportInput.ProbeView }.first
            if probe?.enclosingScrollView != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let marker = try #require(probe)
        let scroll = try #require(marker.enclosingScrollView)
        scroll.scrollerStyle = .legacy
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = false
        for _ in 0..<20 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        let clip = scroll.contentView
        let graph = try #require(controller.graph)
        let graphGeometry = WorkflowGraphGeometry(graph: graph, tools: controller.tools,
            registry: controller.registry)
        let viewport = clip.bounds.size
        #expect(viewport.width < scroll.bounds.width && viewport.height < scroll.bounds.height,
                "Legacy scrollbars must consume real clip space in this fixture")
        #expect(observations.last?.containerSize == viewport)
        let initialLayout = WorkflowCanvasViewportGeometry(graphSize: graphGeometry.size,
            viewportSize: viewport, zoom: 1, translation: graphGeometry.translation)
        for _ in 0..<40 {
            host.layoutSubtreeIfNeeded()
            let target = initialLayout.centeredOffset(on: initialLayout.centerRawPoint)
            if abs(clip.bounds.origin.x - target.x) < 2 && abs(clip.bounds.origin.y - target.y) < 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let initialOffset = clip.bounds.origin
        let initialDocumentSize = try #require(scroll.documentView).frame.size
        let mouseInClip = CGPoint(x: viewport.width * 0.24, y: viewport.height * 0.67)
        func windowPoint(inClip point: CGPoint) -> CGPoint {
            clip.convert(CGPoint(x: clip.bounds.minX + point.x,
                y: clip.isFlipped ? clip.bounds.minY + point.y : clip.bounds.maxY - point.y), to: nil)
        }
        let mouseInWindow = windowPoint(inClip: mouseInClip)

        func dispatch(_ event: NSEvent) async throws {
            NSApplication.shared.postEvent(event, atStart: true)
            let queued = try #require(NSApplication.shared.nextEvent(matching: [
                .scrollWheel, .otherMouseDown, .leftMouseDown, .leftMouseDragged, .leftMouseUp
            ],
                until: Date(timeIntervalSinceNow: 0.1), inMode: .default, dequeue: true))
            NSApplication.shared.sendEvent(queued)
            for _ in 0..<10 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        }
        func wheel(at windowPoint: CGPoint, in target: NSWindow, delta: Int32) throws -> NSEvent {
            let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0))
            cg.location = target.convertPoint(toScreen: windowPoint)
            cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(target.windowNumber))
            cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent,
                                    value: Int64(target.windowNumber))
            return try #require(NSEvent(cgEvent: cg))
        }
        func left(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: 1))
        }
        let originalRaw = initialLayout.rawPoint(screenPoint: mouseInClip, offset: initialOffset)
        try await dispatch(wheel(at: mouseInWindow, in: window, delta: 32))
        #expect(scroll.documentView?.frame.width != initialDocumentSize.width,
                "A real window wheel event must change the rendered canvas zoom")
        let zoomedSize = try #require(scroll.documentView).frame.size
        let zoomed = zoomedSize.width / initialDocumentSize.width
        let zoomedLayout = WorkflowCanvasViewportGeometry(graphSize: graphGeometry.size,
            viewportSize: viewport, zoom: zoomed, translation: graphGeometry.translation)
        let anchored = zoomedLayout.rawPoint(screenPoint: mouseInClip, offset: clip.bounds.origin)
        #expect(abs(anchored.x - originalRaw.x) < 3 && abs(anchored.y - originalRaw.y) < 3)

        let outside = CGPoint(x: 20, y: mouseInWindow.y) // node library, outside the graph scroll view
        let beforeOutside = clip.bounds.origin
        let beforeOutsideSize = try #require(scroll.documentView).frame.size
        try await dispatch(wheel(at: outside, in: window, delta: 32))
        #expect(clip.bounds.origin == beforeOutside)
        #expect(scroll.documentView?.frame.size == beforeOutsideSize)
        try await dispatch(wheel(at: CGPoint(x: window.frame.width - 20, y: mouseInWindow.y),
                                 in: window, delta: 32)) // inspector
        #expect(clip.bounds.origin == beforeOutside)
        #expect(scroll.documentView?.frame.size == beforeOutsideSize)

        let otherWindow = NSWindow(contentRect: window.frame, styleMask: [.titled],
            backing: .buffered, defer: false)
        otherWindow.isReleasedWhenClosed = false
        defer { otherWindow.close() }
        try await dispatch(wheel(at: mouseInWindow, in: otherWindow, delta: 32))
        #expect(clip.bounds.origin == beforeOutside)
        #expect(scroll.documentView?.frame.size == beforeOutsideSize)

        let middle = try #require(NSEvent.mouseEvent(with: .otherMouseDown,
            location: mouseInWindow, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1))
        try await dispatch(middle)
        let recentered = zoomedLayout.visibleRawCenter(offset: clip.bounds.origin)
        #expect(abs(recentered.x - zoomedLayout.centerRawPoint.x) < 3)
        #expect(abs(recentered.y - zoomedLayout.centerRawPoint.y) < 3)
        #expect(scroll.documentView?.frame.size == zoomedSize, "Middle click keeps the zoom")

        // A SwiftUI card button is a virtual control, so native NSControl tests alone cannot
        // protect it. Position the card in the clip, then wheel over its top-right button area.
        let cardNode = try #require(graph.nodes.first)
        let cardSize = try #require(cardSizes[cardNode.id])
        let cardRaw = graphGeometry.rawPosition(cardNode.id)
        clip.scroll(to: zoomedLayout.centeredOffset(on: cardRaw))
        scroll.reflectScrolledClipView(clip)
        for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        let cardDisplay = graphGeometry.displayPosition(cardNode.id)
        let cardCenter = CGPoint(
            x: (cardDisplay.x + zoomedLayout.unscaledPadding.width) * zoomed - clip.bounds.origin.x,
            y: (cardDisplay.y + zoomedLayout.unscaledPadding.height) * zoomed - clip.bounds.origin.y)
        let cardButton = CGPoint(x: cardCenter.x + 80 * zoomed,
                                 y: cardCenter.y - (cardSize.height / 2 - 25) * zoomed)
        #expect(cardButton.x > 0 && cardButton.x < clip.bounds.width)
        #expect(cardButton.y > 0 && cardButton.y < clip.bounds.height)
        try await dispatch(wheel(at: windowPoint(inClip: cardButton), in: window, delta: 24))
        #expect(scroll.documentView?.frame.size == zoomedSize,
                "Virtual node controls keep their own input instead of zooming the canvas")

        let cardBackdrop = windowPoint(inClip: CGPoint(x: cardCenter.x - 75 * zoomed,
            y: cardCenter.y - (cardSize.height / 2 - 28) * zoomed))
        try await dispatch(left(.leftMouseDown, at: cardBackdrop))
        try await dispatch(left(.leftMouseDragged,
            at: CGPoint(x: cardBackdrop.x + 32, y: cardBackdrop.y + 14)))
        #expect(lockChanges.last == true, "A real card drag locks viewport zoom")
        let nodeDragSize = try #require(scroll.documentView).frame.size
        try await dispatch(wheel(at: mouseInWindow, in: window, delta: 24))
        #expect(scroll.documentView?.frame.size == nodeDragSize)
        controller.selectedGraphID = nil // cancel without committing a move or adding Undo
        for _ in 0..<10 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        try await dispatch(left(.leftMouseUp, at: cardBackdrop))
        #expect(lockChanges.last == false && controller.graphs == graphBefore)
        controller.selectedGraphID = graph.id
        for _ in 0..<15 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }

        let output = try #require(portCenters.first { !$0.key.input })
        let portNode = try #require(graph.nodes.first { $0.id == output.key.nodeID })
        let portZoom = (try #require(scroll.documentView).frame.width) / initialDocumentSize.width
        let portLayout = WorkflowCanvasViewportGeometry(graphSize: graphGeometry.size,
            viewportSize: clip.bounds.size, zoom: portZoom, translation: graphGeometry.translation)
        clip.scroll(to: portLayout.centeredOffset(on: graphGeometry.rawPosition(portNode.id)))
        scroll.reflectScrolledClipView(clip)
        for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        let portInClip = CGPoint(
            x: (output.value.x + portLayout.unscaledPadding.width) * portZoom - clip.bounds.origin.x,
            y: (output.value.y + portLayout.unscaledPadding.height) * portZoom - clip.bounds.origin.y)
        #expect(portInClip.x > 0 && portInClip.x < clip.bounds.width)
        #expect(portInClip.y > 0 && portInClip.y < clip.bounds.height)
        let portWindow = windowPoint(inClip: portInClip)
        try await dispatch(left(.leftMouseDown, at: portWindow))
        try await dispatch(left(.leftMouseDragged,
            at: CGPoint(x: portWindow.x + 28, y: portWindow.y + 12)))
        #expect(lockChanges.last == true, "A real output-port drag locks viewport zoom")
        let portDragSize = try #require(scroll.documentView).frame.size
        try await dispatch(wheel(at: mouseInWindow, in: window, delta: 24))
        #expect(scroll.documentView?.frame.size == portDragSize)
        controller.selectedGraphID = nil
        for _ in 0..<10 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        try await dispatch(left(.leftMouseUp, at: portWindow))
        #expect(lockChanges.last == false && controller.graphs == graphBefore)
        controller.selectedGraphID = graph.id
        for _ in 0..<15 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        try await dispatch(middle) // return to content center before testing blank pan

        let sheet = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.beginSheet(sheet, completionHandler: nil)
        #expect(window.attachedSheet === sheet)
        let sheetSize = try #require(scroll.documentView).frame.size
        try await dispatch(wheel(at: mouseInWindow, in: window, delta: 24))
        #expect(scroll.documentView?.frame.size == sheetSize)
        window.endSheet(sheet)
        sheet.close()

        let beforePan = clip.bounds.origin
        try await dispatch(left(.leftMouseDown, at: mouseInWindow))
        try await dispatch(left(.leftMouseDragged,
            at: CGPoint(x: mouseInWindow.x + 65, y: mouseInWindow.y + 48)))
        try await dispatch(left(.leftMouseUp,
            at: CGPoint(x: mouseInWindow.x + 65, y: mouseInWindow.y + 48)))
        #expect(abs(clip.bounds.origin.x - beforePan.x) > 10)
        #expect(abs(clip.bounds.origin.y - beforePan.y) > 10)

        // Both entries stay mounted. Quick's SwiftUI opacity and hit testing must prevent the
        // canvas's native local monitor from seeing events in the same window.
        visibility.quickVisible = true
        for _ in 0..<10 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        #expect(descendants(host).contains { $0 is WorkflowCanvasViewportInput.ProbeView })
        let quickOffset = clip.bounds.origin
        let quickSize = try #require(scroll.documentView).frame.size
        try await dispatch(wheel(at: mouseInWindow, in: window, delta: 32))
        let quickMiddle = try #require(NSEvent.mouseEvent(with: .otherMouseDown,
            location: mouseInWindow, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 2, clickCount: 1, pressure: 1))
        try await dispatch(quickMiddle)
        try await dispatch(wheel(at: CGPoint(x: window.frame.width / 2,
            y: window.frame.height / 2), in: window, delta: 32)) // Quick's virtual controls
        let quickEditor = try #require(descendants(host).compactMap { $0 as? NSTextField }
            .first { $0.stringValue == "draft" })
        #expect(window.makeFirstResponder(quickEditor))
        let editorFrame = quickEditor.convert(quickEditor.bounds, to: nil)
        try await dispatch(wheel(at: CGPoint(x: editorFrame.midX, y: editorFrame.midY),
                                 in: window, delta: 32))
        #expect(clip.bounds.origin == quickOffset)
        #expect(scroll.documentView?.frame.size == quickSize)
        visibility.quickVisible = false
        for _ in 0..<10 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        try await dispatch(wheel(at: mouseInWindow, in: window, delta: -16))
        #expect(scroll.documentView?.frame.size != quickSize,
                "The visible canvas must resume wheel zoom in the same window")

        // A cancelled blank gesture must release its initial offset and permit the next click.
        let heldOffset = clip.bounds.origin
        try await dispatch(left(.leftMouseDown, at: mouseInWindow))
        try await dispatch(left(.leftMouseDragged,
            at: CGPoint(x: mouseInWindow.x - 40, y: mouseInWindow.y + 30)))
        #expect(clip.bounds.origin != heldOffset)
        controller.selectedGraphID = nil
        for _ in 0..<20 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        #expect(controller.graph == nil)
        try await dispatch(left(.leftMouseUp, at: mouseInWindow))
        controller.selectedGraphID = graph.id
        for _ in 0..<20 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        #expect(controller.graph?.id == graph.id)
        controller.selectedNodeID = graph.nodes.first?.id
        #expect(controller.selectedNodeID != nil)
        try await dispatch(left(.leftMouseDown, at: mouseInWindow))
        try await dispatch(left(.leftMouseUp, at: mouseInWindow))
        #expect(controller.selectedNodeID == nil)
        let freshPanOffset = clip.bounds.origin
        try await dispatch(left(.leftMouseDown, at: mouseInWindow))
        try await dispatch(left(.leftMouseDragged,
            at: CGPoint(x: mouseInWindow.x + 45, y: mouseInWindow.y - 35)))
        try await dispatch(left(.leftMouseUp,
            at: CGPoint(x: mouseInWindow.x + 45, y: mouseInWindow.y - 35)))
        #expect(abs(clip.bounds.origin.x - freshPanOffset.x) > 5)
        #expect(abs(clip.bounds.origin.y - freshPanOffset.y) > 5)

        controller.selectedGraphID = nil
        for _ in 0..<20 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        #expect(controller.graph == nil)
        let graphlessBeforePan = clip.bounds.origin
        try await dispatch(left(.leftMouseDown, at: mouseInWindow))
        try await dispatch(left(.leftMouseDragged,
            at: CGPoint(x: mouseInWindow.x - 35, y: mouseInWindow.y + 40)))
        try await dispatch(left(.leftMouseUp,
            at: CGPoint(x: mouseInWindow.x - 35, y: mouseInWindow.y + 40)))
        #expect(abs(clip.bounds.origin.x - graphlessBeforePan.x) > 5)
        #expect(abs(clip.bounds.origin.y - graphlessBeforePan.y) > 5)

        let graphlessSize = try #require(scroll.documentView).frame.size
        try await dispatch(wheel(at: mouseInWindow, in: window, delta: 24))
        #expect(scroll.documentView?.frame.size != graphlessSize)
        let graphlessZoomedSize = try #require(scroll.documentView).frame.size
        let graphlessMiddle = try #require(NSEvent.mouseEvent(with: .otherMouseDown,
            location: mouseInWindow, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 3, clickCount: 1, pressure: 1))
        try await dispatch(graphlessMiddle)
        #expect(scroll.documentView?.frame.size == graphlessZoomedSize)
        let emptyGeometry = WorkflowGraphGeometry(graph: WorkflowGraph())
        let emptyZoom = graphlessZoomedSize.width / graphlessSize.width
        let emptyLayout = WorkflowCanvasViewportGeometry(graphSize: emptyGeometry.size,
            viewportSize: clip.bounds.size, zoom: emptyZoom, translation: emptyGeometry.translation)
        let emptyCenter = emptyLayout.visibleRawCenter(offset: clip.bounds.origin)
        #expect(abs(emptyCenter.x - emptyLayout.centerRawPoint.x) < 3)
        #expect(abs(emptyCenter.y - emptyLayout.centerRawPoint.y) < 3)

        // The bottom-right visible button restores 100% without adding a graph or undo step.
        let reset = windowPoint(inClip: CGPoint(x: clip.bounds.width - 82, y: clip.bounds.height - 27))
        try await dispatch(left(.leftMouseDown, at: reset))
        try await dispatch(left(.leftMouseUp, at: reset))
        #expect(abs((scroll.documentView?.frame.width ?? 0) - graphlessSize.width) < 2)
        let resetLayout = WorkflowCanvasViewportGeometry(graphSize: emptyGeometry.size,
            viewportSize: clip.bounds.size, zoom: 1, translation: emptyGeometry.translation)
        let resetCenter = resetLayout.visibleRawCenter(offset: clip.bounds.origin)
        #expect(abs(resetCenter.x - resetLayout.centerRawPoint.x) < 3)
        #expect(abs(resetCenter.y - resetLayout.centerRawPoint.y) < 3)
        #expect(controller.graph == nil && controller.canUndo == undoBefore)
        #expect(!observations.isEmpty)
        #expect(controller.graphs == graphBefore && controller.availableAssets == assetsBefore)
        #expect(controller.runs == runsBefore && controller.canUndo == undoBefore)
        #expect(await engine.calls == 0)
        try await controller.close()
        try await store.close()
    }
}
