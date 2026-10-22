import AppKit
import DWorkbench
import Testing
@testable import UI

@Suite(.serialized) @MainActor
struct WorkflowCanvasViewportTests {
    @Test(arguments: [false, true])
    func newPressRecoversNodeDragWhoseReleaseWasLost(overControl: Bool) throws {
        let window = CursorFixtureWindow(contentRect: .init(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: .init(x: 0, y: 0, width: 640, height: 480))
        let document = CursorFixtureDocument(frame: .init(x: 0, y: 0, width: 3000, height: 2400))
        scroll.documentView = document; window.contentView = scroll
        let probe = WorkflowCanvasViewportInput.ProbeView(frame: document.bounds); document.addSubview(probe)
        defer { probe.stopMonitoring(); window.contentView = nil; window.close() }
        probe.reportViewportSize(); scroll.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: .init(x: 600, y: 500))
        let clip = scroll.contentView
        let start = clip.convert(.init(x: clip.bounds.minX + 100, y: clip.bounds.minY + 100), to: nil)
        let moved = CGPoint(x: start.x + 40, y: start.y - 20)
        var locked = false, cancelled = 0, committed = 0, pans = 0
        probe.navigationAllowed = { !locked }; probe.setTool(.hand)
        probe.pointerTarget = { _, _, _ in .node(UUID()) }
        probe.onPointer = { update in
            switch update.phase {
            case .began: locked = true
            case .cancelled: cancelled += 1; locked = false
            case .ended: committed += 1; locked = false
            default: break
            }
        }
        probe.onPan = { active, _, _ in if active { pans += 1 } }
        try #require(probe.routePointer(CursorFixtureEvent(type: .leftMouseDown, owner: window, point: start)))
        try #require(probe.routePointer(CursorFixtureEvent(type: .leftMouseDragged, owner: window, point: moved)))
        try #require(locked)
        // A missing mouse-up must not make the next down inherit this node.
        probe.pointerTarget = { _, _, _ in overControl ? .control : .blank }
        #expect(probe.routePointer(CursorFixtureEvent(type: .leftMouseDown, owner: window, point: start)) == !overControl)
        #expect(cancelled == 1 && !locked && committed == 0)
        let offset = clip.bounds.origin
        #expect(probe.routePointer(CursorFixtureEvent(type: .leftMouseDragged, owner: window, point: moved)) == !overControl)
        #expect(probe.routePointer(CursorFixtureEvent(type: .leftMouseUp, owner: window, point: moved)) == !overControl)
        #expect(committed == 0 && cancelled == 1 && pans == (overControl ? 0 : 1))
        #expect(overControl ? clip.bounds.origin == offset : clip.bounds.origin != offset)
    }

    @Test(arguments: [false, true])
    func siblingPopupOwnsCanvasClicksAndWheel(nodeBehind: Bool) async throws {
        try await exerciseSiblingPopup(nodeBehind: nodeBehind, native: false)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["D_UI_NATIVE_POPUP_TEST"] == "1"), arguments: [false, true])
    func nativeSiblingPopupClickReachesCapturedAction(nodeBehind: Bool) async throws {
        try await exerciseSiblingPopup(nodeBehind: nodeBehind, native: true)
    }

    private func exerciseSiblingPopup(nodeBehind: Bool, native: Bool) async throws {
        let window: NSWindow = native ? NSWindow(contentRect: .init(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled], backing: .buffered, defer: false) : CursorFixtureWindow(contentRect: .init(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: .init(x: 0, y: 0, width: 640, height: 480))
        let document = CursorFixtureDocument(frame: .init(x: 0, y: 0, width: 3000, height: 2400))
        scroll.documentView = document; window.contentView = scroll
        let probe = WorkflowCanvasViewportInput.ProbeView(frame: document.bounds); document.addSubview(probe)
        defer { probe.stopMonitoring(); window.contentView = nil; window.close() }
        probe.navigationAllowed = { true }; probe.setTool(.hand)
        probe.pointerTarget = { _, _, _ in nodeBehind ? .node(UUID()) : .blank }
        probe.reportViewportSize(); scroll.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: .init(x: 500, y: 400))
        let anchor = NSView(frame: .init(x: 600, y: 480, width: 30, height: 24)); document.addSubview(anchor)
        var calls = 0, canvasEvents = 0, wheels = 0
        probe.onPointer = { _ in canvasEvents += 1 }; probe.onWheel = { _, _, _, _ in wheels += 1 }
        let popup = try #require(WorkbenchPopupOverlay.present(from: anchor, contextID: "canvas-menu",
            title: "Node", items: [.init(id: "delete", title: "Delete", action: { calls += 1 })],
            style: .init(owner: nil, palette: .defaultLight, strength: 0.55, drawsGlass: false,
                         legacyFill: nil, readability: .init()), validContext: { true }))
        defer { popup.cancel(restoreFocus: false) }
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let row = try #require(descendants(popup).compactMap { $0 as? NSButton }.first)
        let point = row.convert(.init(x: row.bounds.midX, y: row.bounds.midY), to: nil)
        try #require(popup.superview === scroll.superview && row.bounds.width > 0)
        if native {
            NSApp.activate(); window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(100))
            try #require(NSApp.isActive && window.isVisible && window.isKeyWindow)
        }
        #expect(window.contentView?.superview?.hitTest(point) === row)
        let offset = scroll.contentView.bounds.origin
        #expect(!probe.routePointer(CursorFixtureEvent(type: .leftMouseDown, owner: window, point: point)))
        #expect(!probe.routePointer(CursorFixtureEvent(type: .leftMouseUp, owner: window, point: point)))
        let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0))
        _ = probe.routeWheel(FixtureWheel(base: try #require(NSEvent(cgEvent: cg)), owner: window, point: point))
        #expect(wheels == 0 && canvasEvents == 0 && scroll.contentView.bounds.origin == offset)
        // Full test-process event pair reaches the real native menu row. This is
        // not OS input or a claim about foreground/native performance.
        if native {
            try #require(HostingControlClick.send(to: row, in: popup))
            await Task.yield(); try await Task.sleep(for: .milliseconds(10))
            #expect(calls == 1 && popup.superview == nil && canvasEvents == 0)
        } else {
            #expect(calls == 0)
            popup.cancel(restoreFocus: false)
        }
        #expect(scroll.contentView.bounds.origin == offset)
        #expect(probe.routePointer(CursorFixtureEvent(type: .leftMouseDown, owner: window, point: point)))
        #expect(probe.routePointer(CursorFixtureEvent(type: .leftMouseUp, owner: window, point: point)))
    }

    @Test(arguments: [false, true])
    func handPointerPresentationDoesNotRepublishDuringWheelLayout(node: Bool) throws {
        let window = CursorFixtureWindow(contentRect: .init(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: .init(x: 0, y: 0, width: 640, height: 480))
        let document = CursorFixtureDocument(frame: .init(x: 0, y: 0, width: 3000, height: 2400))
        scroll.documentView = document; window.contentView = scroll
        let probe = WorkflowCanvasViewportInput.ProbeView(frame: document.bounds); document.addSubview(probe)
        defer { probe.stopMonitoring(); window.contentView = nil; window.close() }
        probe.setTool(.hand); probe.navigationAllowed = { true }; probe.reportViewportSize()
        scroll.layoutSubtreeIfNeeded(); scroll.contentView.scroll(to: .zero)
        if node { document.addSubview(WorkflowNodePlateView(frame: .init(x: 60, y: 60, width: 240, height: 180))) }
        let point = scroll.contentView.convert(.init(x: 120, y: 100), to: nil)
        let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0))
        let event = FixtureWheel(base: try #require(NSEvent(cgEvent: cg)), owner: window, point: point)
        var deliveries = 0, changes: [Bool] = []
        probe.onWheel = { _, _, _, _ in deliveries += 1 }
        probe.onHandPressedChanged = { changes.append($0) }
        for step in 0..<8 {
            #expect(probe.routeWheel(event))
            document.setFrameSize(.init(width: 3300 + step * 50, height: 2640 + step * 40))
            probe.setFrameSize(document.bounds.size); scroll.layoutSubtreeIfNeeded(); probe.reportViewportSize()
        }
        #expect(deliveries == 8 && changes.isEmpty)
        probe.pointerTarget = { _, _, _ in node ? .node(UUID()) : .blank }
        #expect(probe.routePointer(CursorFixtureEvent(type: .leftMouseDown, owner: window, point: point)))
        #expect(probe.handPressed && changes == [true])
        #expect(probe.routePointer(CursorFixtureEvent(type: .leftMouseUp, owner: window, point: point)))
        #expect(!probe.handPressed && changes == [true, false])
        #expect(probe.routePointer(CursorFixtureEvent(type: .leftMouseDown, owner: window, point: point)))
        probe.setTool(.pointer)
        #expect(!probe.handPressed && changes == [true, false, true, false])
        probe.stopMonitoring(); #expect(changes.count == 4)
        // This verifies presentation-state delivery, not native cursor appearance.
    }

    @Test(arguments: ["control", "text", "nested-scroll", "port", "overlay", "outside", "resign", "hidden", "detach"])
    func handPointerCannotAcquireForeignInput(reason: String) throws {
        let window = CursorFixtureWindow(contentRect: .init(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: .init(x: 0, y: 0, width: 640, height: 480)), scroll = NSScrollView(frame: .init(x: 0, y: 0, width: 640, height: 480))
        let document = CursorFixtureDocument(frame: .init(x: 0, y: 0, width: 3000, height: 2400))
        root.addSubview(scroll); window.contentView = root; scroll.documentView = document
        let probe = WorkflowCanvasViewportInput.ProbeView(frame: document.bounds); document.addSubview(probe)
        defer { probe.stopMonitoring(); window.contentView = nil; window.close() }
        probe.setTool(.hand); probe.navigationAllowed = { true }; probe.pointerTarget = { _, _, _ in .blank }
        probe.reportViewportSize(); scroll.layoutSubtreeIfNeeded(); scroll.contentView.scroll(to: .zero)
        var point = scroll.contentView.convert(.init(x: 120, y: 100), to: nil)
        let rect = document.convert(NSRect(x: point.x - 20, y: point.y - 20, width: 40, height: 40), from: nil)
        switch reason {
        case "control": document.addSubview(NSButton(frame: rect))
        case "text": document.addSubview(NSTextView(frame: rect))
        case "nested-scroll": document.addSubview(NSScrollView(frame: rect))
        case "port": let port = WorkflowPortDragView(frame: rect); port.enabled = true; document.addSubview(port)
        case "overlay": root.addSubview(NSView(frame: root.convert(rect, from: document)))
        case "outside": point = .init(x: -100, y: -100)
        case "resign": window.fixtureKey = false
        case "hidden": probe.isHidden = true
        case "detach": probe.removeFromSuperview()
        default: break
        }
        var changes: [Bool] = []; probe.onHandPressedChanged = { changes.append($0) }
        #expect(!probe.routePointer(CursorFixtureEvent(type: .leftMouseDown, owner: window, point: point)))
        #expect(changes.isEmpty && !probe.handPressed)
    }

    @Test(arguments: [false, true])
    func wheelDeviceUnitsKeepDirectionAndUseDistinctGain(precise: Bool) throws {
        for amount: Int32 in [-3, -1, 0, 1, 3] {
            let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: precise ? .pixel : .line,
                wheelCount: 1, wheel1: amount, wheel2: 0, wheel3: 0))
            let event = try #require(NSEvent(cgEvent: cg))
            #expect(event.hasPreciseScrollingDeltas == precise)
            let response = WorkflowCanvasWheelResponse.delta(event)
            let actual = exp(Double(response) * 0.015)
            let expected = precise ? exp(Double(event.scrollingDeltaY) * 0.015)
                : pow(1.1, Double(event.scrollingDeltaY))
            #expect(abs(actual - expected) < 1e-12)
            #expect(response.sign == event.scrollingDeltaY.sign)
        }
    }

    @Test(arguments: [Int32(0), Int32(12)])
    func wheelZeroVerticalOnlyHandsOffRealHorizontalMotion(horizontal: Int32) throws {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        let document = NSView(frame: CGRect(x: 0, y: 0, width: 3000, height: 2400))
        scroll.documentView = document; window.contentView = scroll
        defer { window.contentView = nil; window.close() }
        let probe = WorkflowCanvasViewportInput.ProbeView(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        document.addSubview(probe); scroll.layoutSubtreeIfNeeded()
        let scope = WorkflowCanvasScope(rootGraphID: UUID(), rootRevision: UUID(), graphID: UUID(), bodyPath: [])
        let wheel = WorkflowCanvasWheelZoom()
        probe.interactionScope = scope; probe.wheelZoom = wheel; probe.navigationAllowed = { true }
        let layout = WorkflowCanvasViewportGeometry(graphSize: CGSize(width: 1400, height: 900),
            viewportSize: scroll.contentView.bounds.size, zoom: 1, translation: .zero)
        let scale = wheel.request(delta: 8, mouse: CGPoint(x: 120, y: 100),
            nativeOffset: layout.centeredOffset(on: layout.centerRawPoint), layout: layout, scope: scope)
        let target = WorkflowCanvasViewportGeometry(graphSize: layout.graphSize,
            viewportSize: layout.viewportSize, zoom: scale, translation: .zero)
        let pending = try #require(wheel.offset(in: target, scope: scope))
        let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
            wheelCount: 2, wheel1: 0, wheel2: horizontal, wheel3: 0))
        let location = scroll.contentView.convert(CGPoint(x: 120, y: 100), to: nil)
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(CGScrollPhase.ended.rawValue))
        // Reuse the native gesture fixture: a hidden component host has no event
        // server window registration. Only ownership/location are injected.
        let event = FixtureWheel(base: try #require(NSEvent(cgEvent: cg)), owner: window, point: location)
        try #require(event.hasPreciseScrollingDeltas && event.scrollingDeltaY == 0 && event.phase.contains(.ended))
        #expect(WorkflowCanvasWheelResponse.isHorizontalNavigation(event) == (horizontal != 0),
            "A zero-delta end event must not cancel a previously submitted wheel anchor")
        try #require(probe.routeWheel(event), "The real probe must own this terminal event")
        #expect(wheel.offset(in: target, scope: scope) == (horizontal == 0 ? pending : nil))
    }

    @Test(arguments: [CGFloat(8), CGFloat(-8)])
    func wheelBurstKeepsAnchorUntilMatchingNativeLayout(delta: CGFloat) throws {
        let scope = WorkflowCanvasScope(rootGraphID: UUID(), rootRevision: UUID(), graphID: UUID(), bodyPath: [])
        let wheel = WorkflowCanvasWheelZoom()
        var layout = WorkflowCanvasViewportGeometry(graphSize: .init(width: 1400, height: 900),
            viewportSize: .init(width: 460, height: 330), zoom: 1, translation: .init(width: 240, height: 120))
        let initial = layout
        let nativeOffset = layout.centeredOffset(on: layout.centerRawPoint)
        let mouse = CGPoint(x: 90, y: 210)
        let anchor = layout.rawPoint(screenPoint: mouse, offset: nativeOffset)
        for _ in 0..<5 {
            let zoom = wheel.request(delta: delta, mouse: mouse, nativeOffset: nativeOffset,
                                     layout: layout, scope: scope)
            layout = WorkflowCanvasViewportGeometry(graphSize: layout.graphSize, viewportSize: layout.viewportSize,
                zoom: zoom, translation: layout.translation)
            // The native clip and document have not caught up, even after onChange ran.
            #expect(wheel.consumeScaleChange(to: zoom))
            #expect(wheel.takeReadyOffset(scope: scope, declaredLayout: layout, contentSize: initial.contentSize,
                                         viewport: layout.viewportSize) == nil)
            let target = try #require(wheel.offset(in: layout, scope: scope))
            let retained = layout.rawPoint(screenPoint: mouse, offset: target)
            #expect(abs(retained.x - anchor.x) < 0.001 && abs(retained.y - anchor.y) < 0.001)
        }
        let applied = try #require(wheel.takeReadyOffset(scope: scope, declaredLayout: layout, contentSize: layout.contentSize,
                                                       viewport: layout.viewportSize))
        let retained = layout.rawPoint(screenPoint: mouse, offset: applied)
        #expect(abs(retained.x - anchor.x) < 0.001 && abs(retained.y - anchor.y) < 0.001)
        #expect(wheel.takeReadyOffset(scope: scope, declaredLayout: layout, contentSize: layout.contentSize,
                                     viewport: layout.viewportSize) == nil, "Apply a wheel target only once")
    }

    @Test func interruptedWheelNeverReplaysAsCenterZoom() {
        let scope = WorkflowCanvasScope(rootGraphID: UUID(), rootRevision: UUID(), graphID: UUID(), bodyPath: [])
        let wheel = WorkflowCanvasWheelZoom()
        let initial = WorkflowCanvasViewportGeometry(graphSize: .init(width: 1400, height: 900),
            viewportSize: .init(width: 460, height: 330), zoom: 1, translation: .zero)
        let changed = wheel.request(delta: 8, mouse: .init(x: 90, y: 210),
            nativeOffset: initial.centeredOffset(on: initial.centerRawPoint), layout: initial, scope: scope)
        let target = WorkflowCanvasViewportGeometry(graphSize: initial.graphSize,
            viewportSize: initial.viewportSize, zoom: changed, translation: initial.translation)
        var otherOwner = scope; otherOwner.instanceID = UUID()
        #expect(wheel.takeReadyOffset(scope: otherOwner, declaredLayout: target, contentSize: target.contentSize,
                                     viewport: target.viewportSize) == nil)
        #expect(wheel.takeReadyOffset(scope: scope, declaredLayout: target, contentSize: target.contentSize,
                                     viewport: .init(width: 520, height: 330)) == nil)
        #expect(wheel.takeReadyOffset(scope: scope, declaredLayout: initial, contentSize: target.contentSize,
                                     viewport: target.viewportSize) == nil,
                "A matching old native frame cannot apply after the declared scale changed")
        wheel.cancel() // Native navigation takes ownership before its event is delivered.
        #expect(wheel.consumeScaleChange(to: changed), "The late scale callback must not submit a center scrollTo")
        #expect(wheel.takeReadyOffset(scope: scope, declaredLayout: target, contentSize: target.contentSize,
                                     viewport: target.viewportSize) == nil)
        #expect(!wheel.consumeScaleChange(to: 1), "An explicit toolbar scale still uses its own center rule")
    }

    @Test func viewportProbeObservesAncestorResizeWithoutDocumentLayout() {
        let scroll = NSScrollView(frame: .init(x: 0, y: 0, width: 600, height: 400))
        let document = NSView(frame: .init(x: 0, y: 0, width: 1800, height: 1200))
        scroll.documentView = document
        let probe = WorkflowCanvasViewportInput.ProbeView(frame: .init(x: 0, y: 0, width: 10, height: 10))
        var samples: [WorkflowCanvasViewportMeasurement] = []
        probe.onViewportSize = { samples.append($0) }
        document.addSubview(probe)
        scroll.layoutSubtreeIfNeeded()
        let initial = samples.last
        scroll.setFrameSize(.init(width: 359, height: 400))
        scroll.layoutSubtreeIfNeeded()
        #expect(samples.last?.surfaceWidth == 359)
        #expect(samples.last?.clip == scroll.contentView.bounds.size)
        #expect(samples.last != initial)
        probe.removeFromSuperview()
        let count = samples.count
        scroll.setFrameSize(.init(width: 600, height: 400))
        scroll.layoutSubtreeIfNeeded()
        #expect(samples.count == count, "An unmounted receiver has no resize callbacks")
    }

    @Test func toolBoundaryUsesActualTextAssetAndValueContracts() throws {
        let registry = WorkflowRegistry.standard
        let input = try #require(registry.operation("d.text.input")).definition.makeNode()
        var value = try #require(registry.operation("d.value.input")).definition.makeNode()
        value.dataConfiguration = .init(value: .text("文字值"))
        let template = try #require(registry.operation("d.text.template")).definition.makeNode()
        let graph = WorkflowGraph(nodes: [input, value, template], connections: [
            .init(sourceNode: input.id, targetNode: template.id, targetPort: "input")])
        let selected = ToolBoundaryDraft(graph: graph, selected: [template.id], registry: registry, tools: [])
        #expect(selected.inputs.first?.schema == .asset(.text))
        #expect(selected.outputs.first?.value.schema == .asset(.text))
        let literal = ToolBoundaryDraft(graph: graph, selected: [value.id], registry: registry, tools: [])
        #expect(literal.outputs.first?.value.schema == .text)
        var human = try #require(registry.operation("d.control.human")).definition.makeNode()
        human.dataConfiguration = .init(schema: .boolean)
        let humanDraft = ToolBoundaryDraft(graph: WorkflowGraph(nodes: [human]), selected: [human.id], registry: registry, tools: [])
        #expect(humanDraft.outputs.first?.value.schema == .boolean)
        var unsupported = input; unsupported.definitionVersion += 1
        #expect(WorkflowToolEditing.outputSchemaProposal(for: unsupported, port: "output", registry: registry, tools: []) == nil)
    }

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
        for zoom: CGFloat in [0.05, 0.5, 1, 4] {
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
                zoom == 0.05 ? zoom * 0.2 : zoom == 4 ? zoom * 3 : zoom)
            if zoom == 0.05 || zoom == 4 { #expect(blocked == zoom) }
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

@MainActor private final class CursorFixtureWindow: NSWindow {
    var fixtureKey = true
    var fixtureMouse = CGPoint(x: -100, y: -100)
    override var mouseLocationOutsideOfEventStream: NSPoint { fixtureMouse }
    override var isKeyWindow: Bool { fixtureKey }
}
@MainActor private final class CursorFixtureDocument: NSView {
    override var isFlipped: Bool { true }
}
private final class CursorFixtureEvent: NSEvent {
    let kind: NSEvent.EventType
    let owner: NSWindow
    let number: Int
    let point: CGPoint
    @MainActor init(type: NSEvent.EventType, owner: NSWindow, point: CGPoint) {
        kind = type; self.owner = owner; number = owner.windowNumber; self.point = point; super.init()
    }
    required init?(coder: NSCoder) { fatalError() }
    override var type: NSEvent.EventType { kind }
    override var window: NSWindow? { owner }
    override var windowNumber: Int { number }
    override var locationInWindow: NSPoint { point }
}

extension WorkflowCanvasViewportTests {
    @Test(arguments: ["hide", "resign", "detach", "cancel"])
    func acquiredHandPresentationEndsOnceAndRejectsLateUp(reason: String) throws {
        let window = CursorFixtureWindow(contentRect: .init(x: 0, y: 0, width: 640, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: .init(x: 0, y: 0, width: 640, height: 480))
        let document = CursorFixtureDocument(frame: .init(x: 0, y: 0, width: 3000, height: 2400))
        scroll.documentView = document; window.contentView = scroll
        let probe = WorkflowCanvasViewportInput.ProbeView(frame: document.bounds); document.addSubview(probe)
        defer { probe.stopMonitoring(); window.contentView = nil; window.close() }
        probe.navigationAllowed = { true }; probe.pointerTarget = { _, _, _ in .blank }; probe.setTool(.hand)
        probe.reportViewportSize(); scroll.layoutSubtreeIfNeeded(); scroll.contentView.scroll(to: .zero)
        let point = scroll.contentView.convert(.init(x: 100, y: 100), to: nil)
        var changes: [Bool] = [], clicks = 0
        probe.onHandPressedChanged = { changes.append($0) }; probe.onPointer = { _ in clicks += 1 }
        try #require(probe.routePointer(CursorFixtureEvent(type: .leftMouseDown, owner: window, point: point)))
        try #require(probe.handPressed && changes == [true])
        switch reason {
        case "hide": probe.isHidden = true
        case "resign": NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        case "detach": probe.removeFromSuperview()
        default: probe.cancelPointer()
        }
        #expect(!probe.handPressed && changes == [true, false])
        #expect(!probe.routePointer(CursorFixtureEvent(type: .leftMouseUp, owner: window, point: point)))
        #expect(clicks == 0)
        probe.stopMonitoring(); #expect(changes == [true, false])
    }
}
