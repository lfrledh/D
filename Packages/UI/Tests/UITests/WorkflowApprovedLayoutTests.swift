import AppKit
import DInference
import DWorkbench
import SwiftUI
import Testing
@testable import UI

private actor LayoutNoInference: InferenceEngine {
    func submit(_ request: InferenceRequest, backendID: String) async throws -> InferenceRun {
        throw WorkflowIssue("Layout fixtures must not execute")
    }
}

@Suite(.serialized) @MainActor struct WorkflowApprovedLayoutTests {
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
