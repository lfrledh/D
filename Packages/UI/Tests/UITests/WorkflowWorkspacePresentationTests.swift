import AppKit
import DInference
import DWorkbench
import Foundation
import SwiftUI
import Testing
@testable import UI

private actor WorkspaceNoInference: InferenceEngine {
    func submit(_ request: InferenceRequest, backendID: String) async throws -> InferenceRun {
        throw WorkflowIssue("Presentation must not submit inference")
    }
}

@Suite(.serialized) @MainActor struct WorkflowWorkspacePresentationTests {
    @Test func explicitTargetSurvivesInspectionButInvalidatesDeletionAndGraphChanges() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent("workspace-target-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await ProjectStore.create(at: root.appendingPathComponent("Test.dproject"), name: "Test")
        let runtime = WorkbenchSession(engine: WorkspaceNoInference(), backendID: "never",
            status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) }, shutdown: {}, cleanup: {}, validateModel: { _ in })
        let services = WorkflowServices(store: store, session: runtime,
            resolveText: { throw WorkflowIssue("No model") }, resolveImage: { throw WorkflowIssue("No model") })
        let controller = WorkflowController(services: services)
        await controller.load(); controller.addExample("text")
        let graph = try #require(controller.graph), a = graph.nodes[0], b = graph.nodes[1]
        let target = WorkflowRunTarget(context: .init(controller), nodeID: a.id)
        let preview = WorkflowRunPreview(controller: controller, nodeID: a.id, only: false,
            lines: try controller.plan(target: a.id, only: false))
        controller.selectedNodeID = b.id
        #expect(target.isCurrent(in: controller) && target.nodeID == a.id)
        #expect(preview.isCurrent(in: controller))
        var edited = b; edited.title = "changed"
        controller.updateNode(edited, in: graph.id)
        #expect(target.isCurrent(in: controller))
        #expect(!preview.isCurrent(in: controller))
        let insertion = try #require(controller.canvasInsertionTarget())
        #expect(controller.deleteNode(id: a.id, target: insertion))
        #expect(!target.isCurrent(in: controller))
        controller.undo(); #expect(target.isCurrent(in: controller))
        controller.addBlankGraph(); #expect(!target.isCurrent(in: controller))
        #expect(controller.runs.isEmpty)
        controller.selectedGraphID = graph.id
        try await controller.saveExplicitEdits()
        let other = WorkflowController(services: services); await other.load()
        other.selectedGraphID = graph.id
        #expect(!target.isCurrent(in: other)) // Same project/IDs, distinct presentation owner.
    }

    @Test func selectionMapsMultipleSingleAndConnectionWithoutInventedTarget() {
        let graph = WorkflowExamples.text()
        let a = graph.nodes[0].id, b = graph.nodes[1].id
        #expect(WorkflowObjectSelection.nodes(in: graph, single: a, multiple: [a, b], connection: nil).count == 2)
        #expect(WorkflowObjectSelection.nodes(in: graph, single: a, multiple: [b], connection: nil).map(\.id) == [b])
        #expect(WorkflowObjectSelection.nodes(in: graph, single: a, multiple: [a, b], connection: UUID()).isEmpty)
        #expect(WorkflowObjectSelection.nodes(in: graph, single: UUID(), multiple: [UUID()], connection: nil).isEmpty)
    }

    @Test func edgesAndOcclusionShareGeometryAndBoundedCache() throws {
        let graph = WorkflowExamples.text(), geometry = WorkflowGraphGeometry(graph: graph)
        let wire = graph.connections[0]
        let output = WorkflowPortIdentity(nodeID: wire.sourceNode, port: wire.sourcePort, input: false)
        let input = WorkflowPortIdentity(nodeID: wire.targetNode, port: wire.targetPort, input: true)
        let ports = [output: CGPoint(x: 217, y: 100), input: CGPoint(x: 503, y: 100)]
        let occluder = UUID()
        var frames = [wire.sourceNode: CGRect(x: 0, y: 20, width: 240, height: 160),
                      wire.targetNode: CGRect(x: 480, y: 20, width: 240, height: 160),
                      occluder: CGRect(x: 335, y: 50, width: 50, height: 100)]
        let ends = WorkflowConnectionGeometry.endpoints(for: wire, geometry: geometry, portCenters: ports, nodeFrames: frames)
        #expect(ends.start == CGPoint(x: 240, y: 100) && ends.end == CGPoint(x: 480, y: 100))
        let cache = WorkflowConnectionHitCache()
        var hit = cache.path(for: wire, geometry: geometry, portCenters: ports, excluding: [], nodeFrames: frames)
        #expect(hit.cgPath.contains(CGPoint(x: 300, y: 100)))
        #expect(!hit.cgPath.contains(CGPoint(x: 360, y: 100)))
        #expect(!hit.cgPath.contains(CGPoint(x: 220, y: 100)))
        #expect(!WorkflowConnectionGeometry.canShowCut(at: CGPoint(x: 330, y: 100), portCenters: [], controls: Array(frames.values)))
        let first = cache.builds
        frames[UUID()] = CGRect(x: 10_000, y: 10_000, width: 240, height: 200)
        for _ in 0..<36 { _ = cache.path(for: wire, geometry: geometry, portCenters: ports, excluding: [], nodeFrames: frames) }
        #expect(cache.builds == first)
        frames[occluder] = CGRect(x: 335, y: 250, width: 50, height: 100)
        hit = cache.path(for: wire, geometry: geometry, portCenters: ports, excluding: [], nodeFrames: frames)
        #expect(cache.builds == first + 1 && hit.cgPath.contains(CGPoint(x: 360, y: 100)))
        let view = WorkflowConnectionHitView(frame: CGRect(x: 0, y: 0, width: 800, height: 400))
        view.updateGeometry(path: hit.cgPath, midpoint: CGPoint(x: 360, y: 100), cutAvailable: true)
        view.canDisconnect = true; view.updateHover(at: CGPoint(x: 350, y: 100))
        #expect(view.hovering)
        frames[occluder] = CGRect(x: 335, y: 50, width: 50, height: 100)
        hit = cache.path(for: wire, geometry: geometry, portCenters: ports, excluding: [], nodeFrames: frames)
        view.updateGeometry(path: hit.cgPath, midpoint: CGPoint(x: 360, y: 100), cutAvailable: false)
        #expect(!view.hovering && view.hitTest(CGPoint(x: 360, y: 100)) == nil)
        print("R16_WIRE nearby invalidation builds=\(cache.builds), unchanged36=0")
    }

    @Test func realCanvasHostRoutesOccludedPortToTopCardAndKeepsButtonsAndBothDirections() async throws {
        let app = NSApplication.shared, policy = NSApplication.shared.activationPolicy()
        app.setActivationPolicy(.regular)
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent("workspace-native-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root); app.setActivationPolicy(policy) }
        let store = try await ProjectStore.create(at: root.appendingPathComponent("Native.dproject"), name: "Native")
        let runtime = WorkbenchSession(engine: WorkspaceNoInference(), backendID: "never",
            status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) }, shutdown: {}, cleanup: {}, validateModel: { _ in })
        let controller = WorkflowController(services: WorkflowServices(store: store, session: runtime,
            resolveText: { throw WorkflowIssue("No model") }, resolveImage: { throw WorkflowIssue("No model") }))
        await controller.load(); controller.addExample("text")
        let original = try #require(controller.graph)
        let a = original.nodes[0], b = original.nodes[1], top = original.nodes[2]
        for wire in original.connections { controller.disconnect(wire.id) }
        controller.moveNode(id: a.id, x: 600, y: 450)
        controller.moveNode(id: b.id, x: 900, y: 450)
        controller.moveNode(id: top.id, x: 650, y: 450)
        let initial = try #require(controller.graph)
        let host = NSHostingView(rootView: WorkflowCanvasView(controller: controller, onTextModel: {}, onImageModel: {},
            onImport: { _ in }, onDestination: {}, onPublishText: {}, onReturnText: { _ in }))
        host.frame = CGRect(x: 0, y: 0, width: 1600, height: 900)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(300)); host.layoutSubtreeIfNeeded()
        try #require(window.isKeyWindow)
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        func port(_ id: UUID, _ input: Bool) throws -> WorkflowPortDragView {
            try #require(descendants(host).compactMap { $0 as? WorkflowPortDragView }.first { $0.port?.nodeID == id && $0.port?.input == input })
        }
        func send(_ type: NSEvent.EventType, _ point: CGPoint) throws {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 611, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
            app.sendEvent(event)
        }
        let hidden = try port(a.id, false)
        let covered = hidden.convert(CGPoint(x: 11, y: 11), to: nil)
        let hit = host.hitTest(host.superview?.convert(covered, from: nil) ?? covered)
        #expect(!(hit is WorkflowPortDragView))
        try send(.leftMouseDown, covered)
        try send(.leftMouseDragged, CGPoint(x: covered.x + 45, y: covered.y - 20))
        try await Task.sleep(for: .milliseconds(40))
        try send(.leftMouseUp, CGPoint(x: covered.x + 45, y: covered.y - 20))
        try await Task.sleep(for: .milliseconds(100))
        let moved = try #require(controller.graph)
        #expect(WorkflowGraphGeometry(graph: moved).rawPosition(top.id) == CGPoint(x: 695, y: 470))
        #expect(WorkflowGraphGeometry(graph: moved).rawPosition(a.id) == CGPoint(x: 600, y: 450))
        #expect(moved.connections.isEmpty)
        controller.undo(); #expect(controller.graph == initial)
        // Move the cover away. Real AppKit down/drag/up must connect either direction.
        controller.moveNode(id: top.id, x: 650, y: 690)
        try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded()
        for reverse in [false, true] {
            let output = try port(a.id, false), input = try port(b.id, true)
            let from = (reverse ? input : output).convert(CGPoint(x: 11, y: 11), to: nil)
            let to = (reverse ? output : input).convert(CGPoint(x: 11, y: 11), to: nil)
            try send(.leftMouseDown, from); try send(.leftMouseDragged, to); try send(.leftMouseUp, to)
            try await Task.sleep(for: .milliseconds(100))
            #expect(controller.graph?.connections.count == 1)
            #expect(controller.graph?.connections.first?.sourceNode == a.id)
            #expect(controller.graph?.connections.first?.targetNode == b.id)
            #expect(controller.graph?.connections.first?.sourcePort == "output")
            #expect(controller.graph?.connections.first?.targetPort == "input")
            controller.undo()
            try await Task.sleep(for: .milliseconds(80))
        }
        // Click the actual top card's delete affordance through its native geometry.
        var pending: [NSObject] = [host], visited = Set<ObjectIdentifier>()
        var delete: (any NSAccessibilityProtocol)?
        while let object = pending.popLast(), visited.count < 3000 {
            guard visited.insert(ObjectIdentifier(object)).inserted else { continue }
            if let value = object as? any NSAccessibilityProtocol {
                if value.accessibilityIdentifier() == "workflow-node-delete-" + top.id.uuidString { delete = value; break }
                pending += (value.accessibilityChildren() ?? []).compactMap { $0 as? NSObject }
            }
            if let view = object as? NSView { pending += view.subviews }
        }
        let button = try #require(delete)
        try #require(HostingControlClick.send(to: button, in: host, unitPoint: CGPoint(x: 0.3, y: 0.5)))
        try await Task.sleep(for: .milliseconds(100))
        #expect(controller.graph?.nodes.contains { $0.id == top.id } == false)
        controller.undo()
        #expect(controller.graph?.nodes.contains { $0.id == top.id } == true)
        print("R16_NATIVE_HOST occludedPort=topNodeDrag buttons=delete bothDirections=connected undo=restored")
    }

    @Test func nativeTopPlateAndVisiblePortOwnOnlyTheirUncoveredArea() {
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 500, height: 300))
        let port = WorkflowPortDragView(frame: CGRect(x: 200, y: 80, width: 22, height: 22))
        port.enabled = true; root.addSubview(port)
        #expect(root.hitTest(CGPoint(x: 211, y: 91)) === port)
        let plate = WorkflowNodePlateView(frame: CGRect(x: 190, y: 60, width: 240, height: 150))
        root.addSubview(plate)
        #expect(root.hitTest(CGPoint(x: 211, y: 91)) === plate)
        plate.removeFromSuperview()
        port.visibleAt = { $0.x < 0 }
        #expect(port.hitTest(CGPoint(x: 202, y: 91)) === port)
        #expect(port.hitTest(CGPoint(x: 219, y: 91)) == nil)
    }
}
