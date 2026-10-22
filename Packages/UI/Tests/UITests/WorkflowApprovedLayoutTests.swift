import AppKit
import DInference
@testable import DWorkbench
import SwiftUI
import Testing
@testable import UI

private actor LayoutNoInference: InferenceEngine {
    func submit(_ request: InferenceRequest, backendID: String) async throws -> InferenceRun {
        throw WorkflowIssue("Layout fixtures must not execute")
    }
}

@Suite(.serialized) @MainActor struct WorkflowApprovedLayoutTests {
    @Test(arguments: ["resume", "stop", "choose"])
    func pausedBatchDockUsesExactStageAndPreservesCompletedPrefix(action: String) async throws {
        try await exercisePausedBatchDock(action: action, native: false)
    }

    // Native hosting is an explicit companion check. Keep its key-window and
    // actual button assertions intact; a headless/blocked run is not a pass.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["D_UI_NATIVE_DOCK_TEST"] == "1"), arguments: ["resume", "stop", "choose"])
    func nativePausedBatchDockButtons(action: String) async throws {
        try await exercisePausedBatchDock(action: action, native: true)
    }

    private func exercisePausedBatchDock(action: String, native: Bool) async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory()).appendingPathComponent("paused-dock-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try await ProjectStore.create(at: root.appendingPathComponent("Batch.dproject"), name: "Synthetic paused batch")
        let session = WorkbenchSession(engine: LayoutNoInference(), backendID: "fixture", status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) }, shutdown: {}, cleanup: {}, validateModel: { _ in })
        let c = WorkflowController(services: WorkflowServices(store: store, session: session,
            resolveText: { throw WorkflowIssue("No model") }, resolveImage: { throw WorkflowIssue("No model") }))
        await c.load()
        var input = try #require(c.registry.operation("d.value.input")).definition.makeNode()
        input.dataConfiguration = .init(value: .text("frozen prefix"))
        let graph = WorkflowGraph(name: "Paused fixture", nodes: [input])
        let archive = try #require(try await store.workflowState().archive)
        _ = try await store.saveWorkflow(graphs: [graph], runs: [], expectedRevision: archive.revision)
        await c.load()
        func stage() async throws -> UUID {
            let id = try await c.createBatchStage(selection: .through(input.id), pins: [], repetitions: 2,
                expectedGraphID: graph.id, expectedRevision: graph.revision)
            let first = try #require(c.batchStages.first { $0.id == id }?.attempts.first?.runID)
            c.beforeHistorySave = { if c.runs.first(where: { $0.id == first })?.status == .completed { c.pause() } }
            await c.runBatchStage(id)
            try #require(c.batchStages.first { $0.id == id }?.attempts.map(\.state) == [.completed, .queued])
            return id
        }
        let firstStage = try await stage(), prefix = c.runs[0]
        if action == "choose" { _ = try await stage() }
        c.beforeHistorySave = {}
        let before = c.runs, stages = c.batchStages
        #expect(WorkflowDockRecovery.pausedQueues(c).count == (action == "choose" ? 2 : 1))
        var recordsOpened = 0
        if native {
        let host = NSHostingView(rootView: AnyView(WorkflowCanvasView(controller: c, onTextModel: {}, onImageModel: {}, onImport: { _ in }, onDestination: {}, onPublishText: {}, onReturnText: { _ in })
            .environment(\.dLanguageStore, UILanguageStore(preferredLanguages: ["en"]))))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        let application = NSApplication.shared, oldPolicy = NSApplication.shared.activationPolicy()
        application.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil); application.activate(ignoringOtherApps: true)
        defer { window.contentView = nil; window.close(); application.setActivationPolicy(oldPolicy) }
        func controls() -> [any NSAccessibilityProtocol] {
            var pending: [NSObject] = [host], seen = Set<ObjectIdentifier>(), result: [any NSAccessibilityProtocol] = []
            while let object = pending.popLast(), seen.count < 4000 {
                guard seen.insert(ObjectIdentifier(object)).inserted else { continue }
                if let element = object as? any NSAccessibilityProtocol {
                    if element.accessibilityRole() == .button { result.append(element) }
                    pending += (element.accessibilityChildren() ?? []).compactMap { $0 as? NSObject }
                }
                if let view = object as? NSView { pending += view.subviews }
            }
            return result
        }
        func settle() async throws { for _ in 0..<12 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(15)) } }
        try await settle()
        try #require(window.isVisible && window.isKeyWindow && host.window === window,
            "Dock controls require a visible key test window before interpreting AX results")
        let labels = controls().compactMap { $0.accessibilityLabel() }
        if action != "choose" {
            #expect(labels.contains("Resume") && labels.contains("Stop"), "The actual dock must not fall back to Run for a paused batch")
        }
        host.rootView = AnyView(WorkflowPausedBatchControls(controller: c) { recordsOpened += 1 }
            .frame(width: 112, height: 32).environment(\.dLanguageStore, UILanguageStore(preferredLanguages: ["en"])))
        try await settle()
        let button = try #require(controls().first { $0.accessibilityIdentifier() == "workflow-batch-" + action })
        #expect(HostingControlClick.send(to: button, in: host))
        } else {
            let queues = WorkflowDockRecovery.pausedQueues(c)
            if queues.count == 1, let id = queues.first?.id {
                if action == "resume" { await c.runBatchStage(id) }
                else { await c.stopBatchQueue(id) }
            } else { recordsOpened += 1 }
        }
        for _ in 0..<200 {
            if action == "choose" ? recordsOpened == 1 : (c.batchStages[0].state != .paused && !c.isRunning) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        if action == "choose" { #expect(recordsOpened == 1 && c.runs == before && c.batchStages == stages) }
        else {
            #expect(c.batchStages[0].id == firstStage)
            #expect(c.batchStages[0].attempts.map(\.state) == (action == "resume" ? [.completed, .completed] : [.completed, .cancelled]))
            #expect(c.runs[0] == prefix, "Completed prefix and its proof cannot be rewritten")
        }
        let saved = c.batchStages
        try await c.close(); try await store.close()
        let cold = try await ProjectStore.open(at: store.rootURL)
        #expect(try await cold.workflowState().archive?.batchStages == saved)
        try await cold.close()
    }

    @Test(arguments: [WorkflowCanvasTool.pointer, .hand])
    func renderedNodeDragKeepsCameraAndCommitsOnlyOnRelease(tool: WorkflowCanvasTool) async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory()).appendingPathComponent("node-routing-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try await ProjectStore.create(at: root.appendingPathComponent("Drag.dproject"), name: "Synthetic drag")
        let session = WorkbenchSession(engine: LayoutNoInference(), backendID: "fixture", status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) }, shutdown: {}, cleanup: {}, validateModel: { _ in })
        let controller = WorkflowController(services: WorkflowServices(store: store, session: session,
            resolveText: { throw WorkflowIssue("No model") }, resolveImage: { throw WorkflowIssue("No model") }))
        await controller.load(); controller.addBlankGraph(name: "Drag fixture")
        controller.addNode(operationID: "d.text.input", x: 240, y: 200)
        controller.addNode(operationID: "d.text.input", x: 620, y: 200)
        let window = LayoutDragWindow(contentRect: .init(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: AnyView(EmptyView())); window.contentView = host
        defer { window.contentView = nil; window.close() }
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        func settle() async throws {
            for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        }
        for zoom: CGFloat in [1, 1.5] {
            let original = try #require(controller.graph), node = try #require(original.nodes.first)
            host.rootView = AnyView(LayoutDragSurface(controller: controller, zoom: zoom, tool: tool))
            try await settle()
            let probe = try #require(descendants(host).compactMap { $0 as? WorkflowCanvasViewportInput.ProbeView }.first)
            let scroll = try #require(probe.enclosingScrollView), clip = scroll.contentView
            let plate = try #require(descendants(host).compactMap { $0 as? WorkflowNodePlateView }.min { $0.convert(.zero, to: host).x < $1.convert(.zero, to: host).x })
            plate.scrollToVisible(plate.bounds); try await settle()
            let start = plate.convert(CGPoint(x: plate.bounds.midX, y: 10 * zoom), to: nil)
            let end = CGPoint(x: start.x + 36 * zoom, y: start.y - 24 * zoom)
            let camera = clip.bounds.origin
            func send(_ type: NSEvent.EventType, _ point: CGPoint) throws {
                try #require(probe.routePointer(LayoutDragEvent(type: type, owner: window, point: point)))
            }
            try send(.leftMouseDown, start); try send(.leftMouseDragged, end)
            try await settle()
            #expect(controller.graph == original, "Continuous movement is local until release")
            #expect(clip.bounds.origin == camera, "Dragging a node cannot pan in either tool")
            try send(.leftMouseUp, end); try await settle()
            let moved = try #require(controller.graph)
            let oldPosition = try #require(original.layout.first { $0.nodeID == node.id })
            let newPosition = try #require(moved.layout.first { $0.nodeID == node.id })
            #expect(abs(newPosition.x - oldPosition.x - 36) < 0.01 && abs(newPosition.y - oldPosition.y - 24) < 0.01)
            #expect(moved.nodes == original.nodes && moved.connections == original.connections)
            #expect(moved.layout.filter { $0.nodeID != node.id } == original.layout.filter { $0.nodeID != node.id })
            #expect(clip.bounds.origin == camera && controller.runs.isEmpty)
            controller.undo(); #expect(controller.graph == original)
            controller.redo(); #expect(controller.graph == moved)
            controller.undo(); try await settle()
            try send(.leftMouseDown, start); try send(.leftMouseDragged, end)
            probe.cancelPointer(); try await settle()
            #expect(controller.graph == original && clip.bounds.origin == camera)

            // The opposite route remains tool-specific: blank hand drag pans;
            // blank pointer drag selects, without editing or panning the graph.
            clip.scroll(to: .zero); scroll.reflectScrolledClipView(clip); try await settle()
            let blank = clip.convert(CGPoint(x: clip.bounds.minX + 100, y: clip.bounds.minY + 100), to: nil)
            let blankEnd = CGPoint(x: blank.x - 30, y: blank.y + 20)
            let before = clip.bounds.origin
            try send(.leftMouseDown, blank); try send(.leftMouseDragged, blankEnd); try send(.leftMouseUp, blankEnd)
            try await settle()
            #expect(controller.graph == original)
            if tool == .hand { #expect(clip.bounds.origin != before) }
            else { #expect(clip.bounds.origin == before) }
            probe.stopMonitoring()
        }
        controller.deactivateAfterClose(); try await store.close()
    }

    @Test func compactPortsHaveRealAnchorsAndNonoverlappingNativeHits() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory()).appendingPathComponent("approved-layout-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try await ProjectStore.create(at: root.appendingPathComponent("Layout.dproject"), name: "Synthetic layout")
        let counts = [(0,1),(1,1),(3,1),(1,3),(3,3)]
        let definitions = counts.enumerated().map { index, count in
            WorkflowOperationDefinition(id: "fixture.layout.\(index)", title: "Long 节点标题 \(index)", detail: "",
                inputs: (0..<count.0).map { .init("i\($0)", "非常长的输入名称 Long input \($0)", kinds: [.text]) },
                outputs: (0..<count.1).map { .init("o\($0)", "非常长的输出名称 Long output \($0)", kinds: [.text]) })
        }
        let registry = try WorkflowRegistry(operations: definitions.map { definition in
            .init(definition: definition, execute: { _,_ in throw WorkflowIssue("Never execute") })
        })
        let session = WorkbenchSession(engine: LayoutNoInference(), backendID: "fixture", status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) }, shutdown: {}, cleanup: {}, validateModel: { _ in })
        let controller = WorkflowController(services: WorkflowServices(store: store, session: session,
            resolveText: { throw WorkflowIssue("No model") }, resolveImage: { throw WorkflowIssue("No model") }), registry: registry)
        await controller.load()
        // UI-only definitions are never registered as product capabilities or
        // written through ProjectStore's standard production schema validator.
        controller.addBlankGraph(name: "Component fixture")
        for (index, definition) in definitions.enumerated() {
            controller.addNode(operationID: definition.id, x: 220 + Double(index) * 300, y: 200)
        }
        let graph = try #require(controller.graph), nodes = graph.nodes
        try #require(nodes.count == definitions.count)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 2700, height: 1100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: AnyView(EmptyView())); window.contentView = host
        host.frame = .init(x: 0, y: 0, width: 2700, height: 1100)
        defer { window.contentView = nil; window.close() }
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        var measured: [UUID: CGSize] = [:]
        for collapsed in [false, true] {
            if collapsed { for node in nodes { controller.toggleCollapsed(node.id) } }
            for zoom: CGFloat in [1, 1.5] {
                host.rootView = AnyView(WorkflowGraphSurface(controller: controller, graph: controller.graph, zoom: .constant(zoom), tool: .constant(.pointer), navigationRequest: .constant(nil), viewportInteractionLocked: .constant(false), viewContext: .init(projectID: controller.projectID, rootGraphID: controller.rootGraph?.id, bodyPath: []), pendingConnection: .constant(nil), selectedConnectionID: .constant(nil), readOnly: false, onPlan: { _,_ in }, nodeSizeObserver: { measured[$0] = $1 }))
                for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
                let ports = descendants(host).compactMap { $0 as? WorkflowPortDragView }
                let plates = descendants(host).compactMap { $0 as? WorkflowNodePlateView }.sorted { $0.convert(CGPoint.zero, to: host).x < $1.convert(CGPoint.zero, to: host).x }
                try #require(plates.count == nodes.count)
                #expect(ports.count == counts.reduce(0) { $0 + $1.0 + $1.1 })
                for (index, node) in nodes.enumerated() {
                    let plate = plates[index]
                    #expect(abs(plate.bounds.width / zoom - 240) < 1)
                    let size = try #require(measured[node.id])
                    #expect(abs(size.width - 240) < 1 && abs(size.height - plate.bounds.height / zoom) < 1)
                    // Resolve a point from the actual rendered plate through the
                    // production target closure, not a synthetic .node target.
                    plate.scrollToVisible(plate.bounds)
                    host.layoutSubtreeIfNeeded()
                    let probe = try #require(descendants(host).compactMap { $0 as? WorkflowCanvasViewportInput.ProbeView }.first)
                    let clip = try #require(probe.enclosingScrollView?.contentView)
                    let native = plate.convert(CGPoint(x: plate.bounds.midX, y: 10 * zoom), to: clip)
                    let screen = CGPoint(x: native.x - clip.bounds.minX,
                        y: clip.isFlipped ? native.y - clip.bounds.minY : clip.bounds.maxY - native.y)
                    try #require(probe.pointerTarget(screen, clip.bounds.origin, clip.bounds.size) == .node(node.id),
                        "The visible card and the production pointer target must occupy the same coordinates")
                    let definition = definitions[index]
                    for input in [true, false] {
                        for (row, definition) in (input ? definition.inputs : definition.outputs).enumerated() {
                            let port = try #require(ports.first { $0.port == .init(nodeID: node.id, port: definition.id, input: input) })
                            // Bring each actual receiver into the hidden viewport. The
                            // canvas deliberately permits large margins around the graph.
                            port.scrollToVisible(port.bounds.insetBy(dx: -15, dy: -15))
                            host.layoutSubtreeIfNeeded()
                            let center = CGPoint(x: port.bounds.midX, y: port.bounds.midY)
                            let actual = port.convert(center, to: plate)
                            #expect(abs(actual.x / zoom - (input ? 0 : 240)) < 1)
                            #expect(abs(actual.y / zoom - (WorkflowNodePortLayout.firstCenter(collapsed: collapsed) + CGFloat(row) * WorkflowNodePortLayout.rowHeight(collapsed: collapsed))) < 1)
                            #expect(abs(port.bounds.height / zoom - (collapsed ? 16 : 22)) < 1)
                            for dx: CGFloat in [-8, 8] {
                                let local = CGPoint(x: center.x + dx * zoom, y: center.y)
                                #expect(port.hitTest(port.convert(local, to: port.superview)) === port)
                                let hostPoint = port.convert(local, to: host.superview)
                                let hit = host.hitTest(hostPoint)
                                try #require(hit.map(ObjectIdentifier.init) == ObjectIdentifier(port), Comment(rawValue: "Port host hit: " + String(describing: hit.map { type(of: $0) }) + "; node=\(index), collapsed=\(collapsed), zoom=\(zoom), dx=\(dx), point=\(hostPoint), host=\(host.frame)"))
                            }
                            #expect(port.hitTest(port.convert(.init(x: center.x, y: port.bounds.maxY + 0.5), to: port.superview)) == nil)
                        }
                    }
                }
            }
        }
        #expect(controller.graph?.nodes == graph.nodes && controller.runs.isEmpty)
        controller.deactivateAfterClose(); try await store.close()
    }

    @Test(arguments: [false, true])
    func internalTextMenuUsesCapturedActionsAndRejectsStaleOwner(temporary: Bool) async throws {
        let window = NSWindow(contentRect: .init(x: 0,y: 0,width: 500,height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let anchor = NSView(frame: .init(x: 20,y: 20,width: 100,height: 30)); window.contentView = anchor
        defer { window.contentView = nil; window.close() }
        var valid = true, temporaryCalls = 0, switches = 0
        func rows(_ mode: QuickTextPresentation) -> WorkbenchMenuRows {
            quickTextWorkspaceRows(presentation: mode, temporary: temporary, language: nil, enabled: true,
                current: { valid }, temporaryAction: { temporaryCalls += 1 }, switchAction: { switches += 1 })
        }
        let chat = rows(.chat)
        #expect(chat.items.count == 3 && chat.items[1].separator)
        #expect(chat.items[0].title == workflowText(nil, temporary ? "quick.textWorkspace.endTemporary" : "quick.textWorkspace.newTemporary"))
        #expect(rows(.single).items.count == 1)
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        func open(_ items: WorkbenchMenuRows) throws -> WorkbenchPopupOverlay {
            try #require(WorkbenchPopupOverlay.present(from: anchor, contextID: "captured-text-owner", title: "Text",
                items: items.items, style: .init(owner: nil, palette: .defaultLight, strength: 0.55, drawsGlass: false, legacyFill: nil, readability: .init()), validContext: { true }))
        }
        let popup = try open(chat)
        let button = try #require(descendants(popup).compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "chat-temporary-toggle" })
        button.performClick(nil); button.performClick(nil)
        await Task.yield(); try await Task.sleep(for: .milliseconds(20))
        #expect(temporaryCalls == 1 && switches == 0)
        for mode: QuickTextPresentation in [.chat, .single] {
            let forward = try open(rows(mode))
            let action = try #require(descendants(forward).compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "text-presentation-switch" })
            action.performClick(nil); action.performClick(nil)
            await Task.yield(); try await Task.sleep(for: .milliseconds(20))
        }
        #expect(switches == 2)
        let second = try open(rows(.single))
        let back = try #require(descendants(second).compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "text-presentation-switch" })
        valid = false; back.performClick(nil)
        await Task.yield(); try await Task.sleep(for: .milliseconds(20))
        #expect(temporaryCalls == 1 && switches == 2)
        second.cancel(restoreFocus: false)
    }

    @Test func approvedLayoutCopyUsesActualLanguageResources() throws {
        for locale in ["zh-Hans", "en"] {
            let language = UILanguageStore(preferredLanguages: [locale]); try language.select(locale)
            #expect(language.text("workflow.dock.stopRemaining", fallback: "MISSING") == (locale == "en" ? "Stop remaining generations" : "停止剩余生成"))
            #expect(language.text("metadata.panel.workspace.singleNote", fallback: "MISSING") == (locale == "en" ? "Rerun only the target node, using the upstream assets explicitly selected from previous runs." : "只重新运行目标节点，使用明确选择的上游历史资产。"))
        }
    }

    @Test func dockFitsMinimumWindowWithoutMovingCornerTools() {
        for width: CGFloat in [760, 900, 1200, 1920] {
            let dock = WorkflowDockLayout.width(available: width)
            #expect(dock == min(440, width - 224))
            let dockRight = (width + dock) / 2
            let toolsLeft = width - 16 - 88
            #expect(toolsLeft - dockRight >= 8)
        }
    }
}

// Component event qualification only; this is not OS input or native-frame evidence.
@MainActor private final class LayoutDragWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}
private final class LayoutDragEvent: NSEvent {
    let kind: NSEvent.EventType, owner: NSWindow, point: CGPoint
    @MainActor init(type: NSEvent.EventType, owner: NSWindow, point: CGPoint) {
        kind = type; self.owner = owner; self.point = point; super.init()
    }
    required init?(coder: NSCoder) { fatalError() }
    override var type: NSEvent.EventType { kind }
    override var window: NSWindow? { owner }
    override var locationInWindow: NSPoint { point }
}
@MainActor private struct LayoutDragSurface: View {
    let controller: WorkflowController
    let zoom: CGFloat
    let tool: WorkflowCanvasTool
    @State private var locked = false
    var body: some View {
        WorkflowGraphSurface(controller: controller, graph: controller.graph, zoom: .constant(zoom), tool: .constant(tool),
            navigationRequest: .constant(nil), viewportInteractionLocked: $locked,
            viewContext: .init(projectID: controller.projectID, rootGraphID: controller.rootGraph?.id, bodyPath: []),
            pendingConnection: .constant(nil), selectedConnectionID: .constant(nil), readOnly: false, onPlan: { _,_ in })
    }
}
