import AppKit
import DWorkbench
import SwiftUI
import Testing
@testable import UI

@Suite(.serialized) @MainActor
struct WorkflowPortDragTests {
    @Test func portHotspotExcludesTitlesAndSquareCorners() {
        let port = WorkflowPortDragView(frame: CGRect(x: 40, y: 30, width: 22, height: 22))
        port.enabled = true
        for point in [CGPoint(x: 51, y: 31), CGPoint(x: 61, y: 41), CGPoint(x: 41, y: 41)] {
            #expect(port.hitTest(point) === port)
        }
        for point in [CGPoint(x: 41, y: 31), CGPoint(x: 70, y: 41), CGPoint(x: 130, y: 41)] {
            #expect(port.hitTest(point) == nil)
        }
    }

    @Test func wireNativeHitKeepsHolesAndFullCutButton() {
        let view = WorkflowConnectionHitView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        var wire = Path(CGRect(x: 10, y: 94, width: 280, height: 12))
        wire = wire.subtracting(Path(ellipseIn: CGRect(x: 38, y: 88, width: 24, height: 24)))
        view.wirePath = wire.cgPath; view.midpoint = CGPoint(x: 150, y: 100); view.canDisconnect = true
        #expect(view.hitTest(CGPoint(x: 50, y: 100)) == nil)
        #expect(view.hitTest(CGPoint(x: 90, y: 100)) === view)
        #expect(view.hitTest(CGPoint(x: 90, y: 130)) == nil)
        view.updateHover(at: CGPoint(x: 140, y: 100))
        #expect(view.hovering)
        view.updateHover(at: CGPoint(x: 150, y: 110))
        #expect(view.hoveringCut && view.hitTest(CGPoint(x: 150, y: 110)) === view)
        view.updateHover(at: CGPoint(x: 150, y: 125))
        #expect(!view.hovering && view.hitTest(CGPoint(x: 150, y: 125)) == nil)
        view.midpoint = CGPoint(x: 50, y: 100)
        view.cutAvailable = WorkflowConnectionGeometry.canShowCut(at: view.midpoint,
            portCenters: [CGPoint(x: 50, y: 100)], controls: [])
        view.updateHover(at: CGPoint(x: 90, y: 100))
        #expect(!view.cutAvailable && view.hitTest(CGPoint(x: 50, y: 100)) == nil)
        #expect(!WorkflowConnectionGeometry.canShowCut(at: CGPoint(x: 150, y: 100),
            portCenters: [], controls: [CGRect(x: 155, y: 95, width: 20, height: 20)]))
    }

    @Test func nativePortGestureOwnsPreviewBothDirectionsAndCancellation() async throws {
        let app = NSApplication.shared
        let oldPolicy = app.activationPolicy(); app.setActivationPolicy(.regular)
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 600, height: 180))
        let output = WorkflowPortDragView(frame: CGRect(x: 20, y: 80, width: 22, height: 22))
        let input = WorkflowPortDragView(frame: CGRect(x: 340, y: 80, width: 22, height: 22))
        let editor = NSTextView(frame: CGRect(x: 20, y: 10, width: 200, height: 40))
        let graphID = UUID()
        let scope = WorkflowCanvasScope(rootGraphID: graphID, rootRevision: UUID(), graphID: graphID, bodyPath: [])
        let a = WorkflowPortIdentity(nodeID: UUID(), port: "text", input: false)
        let b = WorkflowPortIdentity(nodeID: UUID(), port: "input", input: true)
        output.port = a; input.port = b
        output.scope = scope; input.scope = scope; output.enabled = true; input.enabled = true
        root.addSubview(output); root.addSubview(input); root.addSubview(editor)
        let window = NSWindow(contentRect: root.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = root
        window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true)
        defer { output.cancel(); input.cancel(); window.close(); app.setActivationPolicy(oldPolicy) }
        try await Task.sleep(for: .milliseconds(150))
        try #require(window.isKeyWindow)
        try #require(window.makeFirstResponder(editor))
        editor.string = "preserve draft"; editor.allowsUndo = true
        var previews: [CGSize] = [], ends: [WorkflowPortIdentity?] = [], clicks = 0
        for view in [output, input] {
            view.onChange = { previews.append($0) }
            view.onEnd = { ends.append($0) }; view.onClick = { clicks += 1 }
        }
        func send(_ type: NSEvent.EventType, to view: NSView, at point: CGPoint) throws {
            let event = try #require(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 702, clickCount: 1, pressure: 1))
            window.sendEvent(event)
        }
        for (source, target) in [(output, input), (input, output)] {
            let count = ends.count
            // Use opposite edges inside the circular local hotspot; the title is outside.
            try send(.leftMouseDown, to: source, at: CGPoint(x: 2, y: 11))
            try send(.leftMouseDragged, to: target, at: CGPoint(x: 20, y: 11))
            #expect(ends.count == count && !previews.isEmpty)
            try send(.leftMouseUp, to: target, at: CGPoint(x: 20, y: 11))
            #expect(ends.count == count + 1 && ends.last! == target.port)
            try send(.leftMouseUp, to: target, at: CGPoint(x: 20, y: 11))
            #expect(ends.count == count + 1 && clicks == 0)
            let sourcePort = try #require(source.port), targetPort = try #require(target.port)
            let directed = try #require(WorkflowCanvasConnectionPolicy.directedPorts(sourcePort, targetPort))
            #expect(directed.output == a && directed.input == b)
        }
        try send(.leftMouseDown, to: output, at: CGPoint(x: 11, y: 11))
        try send(.leftMouseDragged, to: root, at: CGPoint(x: 290, y: 150))
        try send(.leftMouseUp, to: root, at: CGPoint(x: 290, y: 150))
        #expect(ends.last! == nil)
        try send(.leftMouseDown, to: output, at: CGPoint(x: 11, y: 11))
        try send(.leftMouseDragged, to: input, at: CGPoint(x: 11, y: 11))
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        let cancelled = ends.count
        try send(.leftMouseUp, to: input, at: CGPoint(x: 11, y: 11))
        #expect(ends.count == cancelled && ends.last! == nil)
        input.scope = WorkflowCanvasScope(rootGraphID: graphID, rootRevision: UUID(), graphID: graphID, bodyPath: [])
        try send(.leftMouseDown, to: output, at: CGPoint(x: 11, y: 11))
        try send(.leftMouseDragged, to: input, at: CGPoint(x: 11, y: 11))
        try send(.leftMouseUp, to: input, at: CGPoint(x: 11, y: 11))
        #expect(ends.last! == nil)
        #expect(WorkflowCanvasConnectionPolicy.directedPorts(a, a) == nil)
        #expect(window.firstResponder === editor && editor.string == "preserve draft")
    }
}
