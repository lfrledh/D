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

@MainActor private final class ViewportFlippedDocument: NSView {
    override var isFlipped: Bool { true }
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
    @Test(arguments: ["horizontal", "hidden-scrollers", "nested-scroll"])
    func nativeNavigationTakesOwnershipBeforePendingWheelLayout(kind: String) throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let scroll = NSScrollView(frame: .init(x: 0, y: 0, width: 600, height: 400))
        scroll.hasHorizontalScroller = true; scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .legacy; scroll.autohidesScrollers = false
        let document = ViewportFlippedDocument(frame: .init(x: 0, y: 0, width: 3000, height: 2400))
        scroll.documentView = document
        window.contentView = scroll
        window.orderFront(nil)
        let probe = WorkflowCanvasViewportInput.ProbeView(frame: .init(x: 0, y: 0, width: 10, height: 10))
        document.addSubview(probe)
        scroll.layoutSubtreeIfNeeded()
        try #require(window.isVisible && probe.window === window && probe.enclosingScrollView === scroll,
                     "The component window and the production probe must be attached before input")
        let clip = scroll.contentView
        try #require(document.isFlipped && clip.isFlipped)
        let scope = WorkflowCanvasScope(rootGraphID: UUID(), rootRevision: UUID(), graphID: UUID(), bodyPath: [])
        let layout = WorkflowCanvasViewportGeometry(graphSize: .init(width: 1200, height: 900),
            viewportSize: clip.bounds.size, zoom: 1, translation: .zero)
        document.setFrameSize(layout.contentSize)
        clip.scroll(to: .init(x: 900, y: 700))
        scroll.reflectScrolledClipView(clip)
        probe.interactionScope = scope; probe.navigationAllowed = { true }
        probe.allowsEvent = { _, _, _ in true }
        let wheel = WorkflowCanvasWheelZoom()
        probe.wheelZoom = wheel
        let scale = wheel.request(delta: 8, mouse: .init(x: 100, y: 100), nativeOffset: clip.bounds.origin,
                                  layout: layout, scope: scope)
        let target = WorkflowCanvasViewportGeometry(graphSize: layout.graphSize, viewportSize: layout.viewportSize,
            zoom: scale, translation: layout.translation)
        probe.wheelLayout = { _ in target }
        try #require(wheel.offset(in: target, scope: scope) != nil)
        let originalCanvasOffset = clip.bounds.origin
        func wheelEvent(at point: CGPoint, horizontal: Bool, owner: NSScrollView) throws -> NSEvent {
            let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                wheelCount: 2, wheel1: horizontal ? 0 : -24, wheel2: horizontal ? -24 : 0, wheel3: 0))
            let located = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: point,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 1, clickCount: 0, pressure: 0))
            cg.location = try #require(located.cgEvent).location
            cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
            cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent,
                                    value: Int64(window.windowNumber))
            let event = try #require(NSEvent(cgEvent: cg))
            try #require(event.type == .scrollWheel && event.windowNumber == window.windowNumber,
                         "The synthesized wheel must identify this window")
            try #require(abs(event.locationInWindow.x - point.x) < 1
                && abs(event.locationInWindow.y - point.y) < 1,
                "The synthesized wheel must preserve the requested location")
            try #require(horizontal ? event.scrollingDeltaX != 0 && event.scrollingDeltaY == 0
                                    : event.scrollingDeltaY != 0)
            let content = try #require(window.contentView)
            let hitPoint = content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
            var hit: NSView? = try #require(content.hitTest(hitPoint))
            while let current = hit, current !== owner { hit = current.superview }
            try #require(hit === owner, "The real hit chain must reach the expected scroll owner")
            return event
        }
        if kind == "hidden-scrollers" {
            probe.reportViewportSize()
            #expect(!scroll.hasHorizontalScroller && !scroll.hasVerticalScroller)
            // No scrollbar can take ownership: cancel the pending zoom explicitly.
            wheel.cancel()
        } else if kind == "nested-scroll" {
            let nested = NSScrollView(frame: .init(x: clip.bounds.minX + 40, y: clip.bounds.minY + 40,
                                                  width: 160, height: 120))
            nested.hasVerticalScroller = true
            nested.documentView = ViewportFlippedDocument(frame: .init(x: 0, y: 0, width: 160, height: 900))
            document.addSubview(nested); nested.layoutSubtreeIfNeeded()
            nested.contentView.scroll(to: .init(x: 0, y: 300))
            let point = nested.convert(.init(x: 70, y: 60), to: nil)
            let event = try wheelEvent(at: point, horizontal: false, owner: nested)
            let before = nested.contentView.bounds.origin
            #expect(probe.routeWheel(event))
            #expect(nested.contentView.bounds.origin != before, "The nested editor/list still scrolls")
            #expect(clip.bounds.origin == originalCanvasOffset)
        } else {
            let point = clip.convert(.init(x: clip.bounds.minX + 100, y: clip.bounds.minY + 100), to: nil)
            let event = try wheelEvent(at: point, horizontal: true, owner: scroll)
            #expect(probe.routeWheel(event))
            #expect(clip.bounds.origin.x != originalCanvasOffset.x, "Native horizontal navigation remains available")
        }
        #expect(wheel.offset(in: target, scope: scope) == nil)
        #expect(wheel.consumeScaleChange(to: scale))
        let handedOffOffset = clip.bounds.origin
        document.setFrameSize(target.contentSize)
        probe.reportViewportSize()
        #expect(clip.bounds.origin == handedOffOffset, "The late wheel layout cannot replay its old offset")
    }

    @Test func nativeWindowWheelAndMiddleClickStayInsideVisibleCanvas() async throws {
        let app = NSApplication.shared, activationPolicy = NSApplication.shared.activationPolicy()
        app.setActivationPolicy(.regular)
        defer { app.setActivationPolicy(activationPolicy) }
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
        let overlays = WorkbenchSidebarState(leading: false, trailing: false)
        let view = WorkflowCanvasView(controller: controller, onTextModel: {}, onImageModel: {},
            onImport: { _ in }, onDestination: {}, onPublishText: {}, onReturnText: { _ in })
            .testingOverlayState(overlays)
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
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<40 {
            if window.isVisible && window.isKeyWindow && host.window === window { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(window.isVisible && window.isKeyWindow && host.window === window)
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
        try #require(viewport.width > 0 && viewport.height > 0)
        func accessibilityElements(_ root: NSObject) -> [any NSAccessibilityProtocol] {
            var pending = [root], seen = Set<ObjectIdentifier>()
            var result: [any NSAccessibilityProtocol] = []
            while let item = pending.popLast(), seen.count < 2_000 {
                guard seen.insert(ObjectIdentifier(item)).inserted else { continue }
                if let ax = item as? any NSAccessibilityProtocol {
                    result.append(ax)
                    pending += (ax.accessibilityChildren() ?? []).compactMap { $0 as? NSObject }
                }
                if let view = item as? NSView { pending += view.subviews }
            }
            return result
        }
        func selectTool(_ hand: Bool) async throws {
            let picker = try #require(accessibilityElements(host).first {
                $0.accessibilityIdentifier() == "workflow-canvas-tool"
            })
            let buttons = accessibilityElements(try #require(picker as? NSObject))
                .filter { $0.accessibilityRole() == .button }
            try #require(buttons.count == 2)
            try #require(Set(buttons.compactMap { $0.accessibilityLabel() }) == Set(["指针", "手形"]))
            let button = try #require(buttons.first { $0.accessibilityLabel() == (hand ? "手形" : "指针") })
            try #require(HostingControlClick.send(to: button, in: host))
            for _ in 0..<20 {
                host.layoutSubtreeIfNeeded()
                if button.isAccessibilitySelected() { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(button.isAccessibilitySelected())
        }
        try await selectTool(false)
        #expect(!scroll.hasHorizontalScroller && !scroll.hasVerticalScroller)
        #expect(scroll.scrollerStyle == .overlay)
        #expect(abs(viewport.width - scroll.bounds.width) < 1
            && abs(viewport.height - scroll.bounds.height) < 1,
                "The production canvas removes both legacy scrollbar gutters")
        #expect(observations.last?.containerSize == viewport)
        try #require(abs((try #require(observations.last)).zoom - 1) < 0.0001)
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

        func dispatchQueued(_ event: NSEvent) throws {
            NSApplication.shared.postEvent(event, atStart: true)
            let queued = try #require(NSApplication.shared.nextEvent(matching: [
                .scrollWheel, .otherMouseDown, .leftMouseDown, .leftMouseDragged, .leftMouseUp
            ],
                until: Date(timeIntervalSinceNow: 0.1), inMode: .default, dequeue: true))
            let sameIdentity = queued.type == event.type && queued.windowNumber == event.windowNumber
                && (event.type == .scrollWheel
                    ? abs(queued.timestamp - event.timestamp) < 0.001
                    : queued.eventNumber == event.eventNumber)
            if !sameIdentity { NSApp.postEvent(queued, atStart: true) }
            try #require(sameIdentity, "The driver must dispatch its own queued event")
            NSApplication.shared.sendEvent(queued)
        }
        func dispatch(_ event: NSEvent) async throws {
            try dispatchQueued(event)
            for _ in 0..<10 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        }
        func wheel(at windowPoint: CGPoint, in target: NSWindow, delta: Int32,
                   units: CGScrollEventUnit = .pixel) throws -> NSEvent {
            let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: units,
                wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0))
            // NSEvent converts AppKit's bottom-left coordinates to Quartz's screen coordinates.
            let located = try #require(NSEvent.mouseEvent(with: .mouseMoved,
                location: windowPoint, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: target.windowNumber, context: nil, eventNumber: 1, clickCount: 0, pressure: 0))
            cg.location = try #require(located.cgEvent).location
            cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(target.windowNumber))
            cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent,
                                    value: Int64(target.windowNumber))
            let event = try #require(NSEvent(cgEvent: cg))
            try #require(event.windowNumber == target.windowNumber)
            try #require(abs(event.locationInWindow.x - windowPoint.x) < 1
                && abs(event.locationInWindow.y - windowPoint.y) < 1,
                "Wheel must enter the requested window coordinates")
            return event
        }
        var gestureIdentity = 1
        func left(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
            if type == .leftMouseDown { gestureIdentity = Int.random(in: 1...Int(Int16.max)) }
            return try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: gestureIdentity, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
        }
        let originalRaw = initialLayout.rawPoint(screenPoint: mouseInClip, offset: initialOffset)
        // An ordinary mouse burst arrives without a layout/scroll observation between ticks.
        for _ in 0..<4 { try dispatchQueued(wheel(at: mouseInWindow, in: window, delta: 1, units: .line)) }
        for _ in 0..<10 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        #expect(scroll.documentView?.frame.width != initialDocumentSize.width,
                "A real window wheel event must change the rendered canvas zoom")
        let zoomedSize = try #require(scroll.documentView).frame.size
        let zoomed = try #require(observations.last).zoom
        try #require(zoomed >= 0.5 && graphGeometry.size.width * zoomed >= viewport.width)
        let zoomedLayout = WorkflowCanvasViewportGeometry(graphSize: graphGeometry.size,
            viewportSize: viewport, zoom: zoomed, translation: graphGeometry.translation)
        let anchored = zoomedLayout.rawPoint(screenPoint: mouseInClip, offset: clip.bounds.origin)
        #expect(abs(anchored.x - originalRaw.x) < 3 && abs(anchored.y - originalRaw.y) < 3)

        let beforeOutside = clip.bounds.origin
        let beforeOutsideSize = try #require(scroll.documentView).frame.size
        overlays.leading = true; overlays.trailing = true
        for _ in 0..<40 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        #expect(clip.bounds.origin == beforeOutside && clip.bounds.size == viewport)
        for identifier in ["canvas-inspector-host", "canvas-library-host"] {
            let pane = try #require(descendants(host).first { $0.accessibilityIdentifier() == identifier })
            try #require(!pane.isHiddenOrHasHiddenAncestor && pane.bounds.width > 0 && pane.bounds.height > 0)
            let point = pane.convert(CGPoint(x: pane.bounds.midX, y: pane.bounds.midY), to: nil)
            let hit = try #require(host.hitTest(host.superview?.convert(point, from: nil) ?? point))
            try #require(hit === pane || hit.isDescendant(of: pane), "The actual floating pane owns this wheel location")
            try #require(hit !== scroll && !hit.isDescendant(of: scroll))
            try await dispatch(wheel(at: point, in: window, delta: 32))
            #expect(clip.bounds.origin == beforeOutside)
            #expect(scroll.documentView?.frame.size == beforeOutsideSize)
        }
        overlays.leading = false; overlays.trailing = false
        for _ in 0..<40 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        #expect(clip.bounds.origin == beforeOutside && clip.bounds.size == viewport)

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

        // A non-scrolling SwiftUI card surface uses the same ordinary-wheel zoom route
        // as blank canvas. Genuine native editors and nested scroll views keep their owner.
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
        let cardElement = try #require(accessibilityElements(host).first {
            $0.accessibilityIdentifier() == "workflow-node-" + cardNode.id.uuidString
        })
        let cardFrame = window.convertFromScreen(cardElement.accessibilityFrame())
        try #require(cardFrame.contains(windowPoint(inClip: cardCenter)),
                     "The geometric node center must belong to this actual rendered card")
        let inspectElement = try #require(accessibilityElements(host).first {
            $0.accessibilityIdentifier() == "workflow-node-inspect-" + cardNode.id.uuidString
        })
        let inspectFrame = window.convertFromScreen(inspectElement.accessibilityFrame())
        try #require(inspectFrame.width > 0 && inspectFrame.height > 0)
        let nativeButtonPoint = clip.convert(CGPoint(x: inspectFrame.midX, y: inspectFrame.midY), from: nil)
        let cardButton = CGPoint(x: nativeButtonPoint.x - clip.bounds.minX,
            y: clip.isFlipped ? nativeButtonPoint.y - clip.bounds.minY : clip.bounds.maxY - nativeButtonPoint.y)
        #expect(cardButton.x > 0 && cardButton.x < clip.bounds.width)
        #expect(cardButton.y > 0 && cardButton.y < clip.bounds.height)
        let cardOffset = clip.bounds.origin
        for point in [cardButton, cardCenter] {
            let eventLocation = windowPoint(inClip: point)
            var hit: NSView? = try #require(host.hitTest(host.superview?.convert(eventLocation, from: nil) ?? eventLocation))
            while let current = hit, current !== scroll {
                try #require(!(current is NSScrollView) && !(current is NSTextView) && !(current is NSControl),
                             "This node fixture must hit a non-scrolling surface, not an editor or native control")
                hit = current.superview
            }
            try #require(hit === scroll, "The rendered node point belongs to the canvas")
            let anchor = zoomedLayout.rawPoint(screenPoint: point, offset: clip.bounds.origin)
            try await dispatch(wheel(at: windowPoint(inClip: point), in: window, delta: 1, units: .line))
            let changedSize = try #require(scroll.documentView).frame.size
            #expect(changedSize != zoomedSize, "Ordinary wheel on a non-scrolling node zooms the canvas")
            let changedZoom = try #require(observations.last).zoom
            let changedLayout = WorkflowCanvasViewportGeometry(graphSize: graphGeometry.size,
                viewportSize: viewport, zoom: changedZoom,
                translation: graphGeometry.translation)
            let changedAnchor = changedLayout.rawPoint(screenPoint: point, offset: clip.bounds.origin)
            #expect(abs(changedAnchor.x - anchor.x) < 3 && abs(changedAnchor.y - anchor.y) < 3,
                    "Node wheel zoom preserves its anchor instead of adding native scrolling")
            try await dispatch(wheel(at: windowPoint(inClip: point), in: window, delta: -1, units: .line))
            let restoredSize = try #require(scroll.documentView).frame.size
            try #require(abs((try #require(observations.last)).zoom - zoomed) < 0.0001,
                         "The opposite wheel restores scale before reusing the card geometry")
            try #require(abs(restoredSize.width - zoomedSize.width) < 1 && abs(restoredSize.height - zoomedSize.height) < 1)
            #expect(abs(clip.bounds.origin.x - cardOffset.x) < 3 && abs(clip.bounds.origin.y - cardOffset.y) < 3)
        }

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
        let portZoom = try #require(observations.last).zoom
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
        for _ in 0..<20 {
            if window.attachedSheet == nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(window.attachedSheet == nil)
        try await selectTool(true)

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
        let beforeReverse = observations.last
        let reverseZoom = try #require(observations.last).zoom
        try #require(clip.bounds.size == viewport && reverseZoom >= 0.5)
        let reverseLayout = WorkflowCanvasViewportGeometry(graphSize: graphGeometry.size,
            viewportSize: clip.bounds.size, zoom: reverseZoom, translation: graphGeometry.translation)
        let reverseAnchor = reverseLayout.rawPoint(screenPoint: mouseInClip, offset: clip.bounds.origin)
        for _ in 0..<4 { try dispatchQueued(wheel(at: mouseInWindow, in: window, delta: -4)) }
        for _ in 0..<10 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        #expect(scroll.documentView?.frame.size != quickSize,
                "The visible canvas must resume wheel zoom in the same window")
        let afterReverse = WorkflowCanvasViewportGeometry(graphSize: graphGeometry.size,
            viewportSize: clip.bounds.size,
            zoom: (try #require(observations.last)).zoom,
            translation: graphGeometry.translation)
        let keptReverse = afterReverse.rawPoint(screenPoint: mouseInClip, offset: clip.bounds.origin)
        #expect(abs(keptReverse.x - reverseAnchor.x) < 3 && abs(keptReverse.y - reverseAnchor.y) < 3)
        #expect(observations.last != beforeReverse)

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
        try await selectTool(false)
        controller.selectedNodeID = graph.nodes.first?.id
        #expect(controller.selectedNodeID != nil)
        try await dispatch(left(.leftMouseDown, at: mouseInWindow))
        try await dispatch(left(.leftMouseUp, at: mouseInWindow))
        #expect(controller.selectedNodeID == nil)
        try await selectTool(true)
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
        let emptyZoom = try #require(observations.last).zoom
        let emptyLayout = WorkflowCanvasViewportGeometry(graphSize: emptyGeometry.size,
            viewportSize: clip.bounds.size, zoom: emptyZoom, translation: emptyGeometry.translation)
        let emptyCenter = emptyLayout.visibleRawCenter(offset: clip.bounds.origin)
        #expect(abs(emptyCenter.x - emptyLayout.centerRawPoint.x) < 3)
        #expect(abs(emptyCenter.y - emptyLayout.centerRawPoint.y) < 3)

        // Locate the actual reset control; its toolbar position is not canvas space.
        let reset = try #require(accessibilityElements(host).first {
            $0.accessibilityIdentifier() == "workflow-canvas-reset-view"
        })
        try #require(HostingControlClick.send(to: reset, in: host))
        for _ in 0..<15 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        try #require(observations.last?.zoom == 1)
        let resetLayout = WorkflowCanvasViewportGeometry(graphSize: emptyGeometry.size,
            viewportSize: clip.bounds.size, zoom: 1, translation: emptyGeometry.translation)
        #expect(abs((scroll.documentView?.frame.width ?? 0) - resetLayout.contentSize.width) < 2)
        let resetCenter = resetLayout.visibleRawCenter(offset: clip.bounds.origin)
        #expect(abs(resetCenter.x - resetLayout.centerRawPoint.x) < 3)
        #expect(abs(resetCenter.y - resetLayout.centerRawPoint.y) < 3)
        #expect(controller.graph == nil && controller.canUndo == undoBefore)

        // The edit affordance follows the visible configuration panel, not ordinary
        // selection or a separate "last clicked" flag. Use its actual production action.
        controller.selectedGraphID = graph.id
        for _ in 0..<15 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        let resetRestoredGraph = try #require(accessibilityElements(host).first {
            $0.accessibilityIdentifier() == "workflow-canvas-reset-view"
        })
        try #require(HostingControlClick.send(to: resetRestoredGraph, in: host))
        for _ in 0..<15 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        try #require(observations.last?.zoom == 1)
        func inspectButton(_ nodeID: UUID) throws -> any NSAccessibilityProtocol {
            try #require(accessibilityElements(host).first {
                $0.accessibilityIdentifier() == "workflow-node-inspect-" + nodeID.uuidString
            })
        }
        func revealNode(_ nodeID: UUID) async throws {
            let layout = WorkflowCanvasViewportGeometry(graphSize: graphGeometry.size,
                viewportSize: clip.bounds.size, zoom: 1, translation: graphGeometry.translation)
            clip.scroll(to: layout.centeredOffset(on: graphGeometry.rawPosition(nodeID)))
            scroll.reflectScrolledClipView(clip)
            for _ in 0..<10 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        }
        let firstNode = try #require(graph.nodes.first)
        let secondNode = try #require(graph.nodes.last)
        try #require(firstNode.id != secondNode.id)
        controller.selectedNodeID = firstNode.id
        try await revealNode(firstNode.id)
        #expect(try !inspectButton(firstNode.id).isAccessibilitySelected(),
                "Ordinary selection has not opened configuration")
        try #require(HostingControlClick.send(to: inspectButton(firstNode.id), in: host))
        for _ in 0..<10 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        #expect(try inspectButton(firstNode.id).isAccessibilitySelected())
        #expect(HostingControlClick.contains("workflow-field-text", in: host))
        try await revealNode(secondNode.id)
        try #require(HostingControlClick.send(to: inspectButton(secondNode.id), in: host))
        for _ in 0..<10 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        #expect(controller.selectedNodeID == secondNode.id)
        #expect(try inspectButton(secondNode.id).isAccessibilitySelected())
        try await revealNode(firstNode.id)
        #expect(try !inspectButton(firstNode.id).isAccessibilitySelected())
        let inspectorToggle = try #require(accessibilityElements(host).first {
            $0.accessibilityIdentifier() == "canvas-inspector-toggle"
        })
        try #require(HostingControlClick.send(to: inspectorToggle, in: host))
        for _ in 0..<10 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        try await revealNode(secondNode.id)
        #expect(try !inspectButton(secondNode.id).isAccessibilitySelected(),
                "A hidden configuration panel cannot leave a node looking inspected")
        #expect(!observations.isEmpty)
        #expect(controller.graphs == graphBefore && controller.availableAssets == assetsBefore)
        #expect(controller.runs == runsBefore && controller.canUndo == undoBefore)
        #expect(await engine.calls == 0)
        try await controller.close()
        try await store.close()
    }
}
