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
        let view = WorkflowCanvasView(controller: controller, onTextModel: {}, onImageModel: {},
            onImport: { _ in }, onDestination: {}, onPublishText: {}, onReturnText: { _ in })
            .observingScroll { _, observation in observations.append(observation) }
        let host = NSHostingView(rootView: view)
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
        let clip = scroll.contentView
        let graph = try #require(controller.graph)
        let graphGeometry = WorkflowGraphGeometry(graph: graph, tools: controller.tools,
            registry: controller.registry)
        let viewport = clip.bounds.size
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
        let mouseInWindow = clip.convert(CGPoint(x: clip.bounds.minX + mouseInClip.x,
            y: clip.isFlipped ? clip.bounds.minY + mouseInClip.y : clip.bounds.maxY - mouseInClip.y), to: nil)

        func dispatch(_ event: NSEvent) async throws {
            NSApplication.shared.postEvent(event, atStart: true)
            let queued = try #require(NSApplication.shared.nextEvent(matching: [.scrollWheel, .otherMouseDown],
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

        marker.isHidden = true
        let beforeHidden = try #require(scroll.documentView).frame.size
        try await dispatch(wheel(at: mouseInWindow, in: window, delta: 32))
        #expect(scroll.documentView?.frame.size == beforeHidden,
                "An inactive canvas cannot intercept a window wheel event")
        marker.isHidden = false
        #expect(!observations.isEmpty)
        #expect(controller.graphs == graphBefore && controller.availableAssets == assetsBefore)
        #expect(controller.runs == runsBefore && controller.canUndo == undoBefore)
        #expect(await engine.calls == 0)
        try await controller.close()
        try await store.close()
    }
}
