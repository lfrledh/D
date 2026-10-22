import AppKit
import DInference
import DWorkbench
import Foundation
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import UI

private actor WorkspaceNoInference: InferenceEngine {
    private(set) var submissions = 0
    func submit(_ request: InferenceRequest, backendID: String) async throws -> InferenceRun {
        submissions += 1
        throw WorkflowIssue("Presentation must not submit inference")
    }
}

@MainActor private final class MetadataHostProbeState {
    var starts = 0
    var updates = 0
    var gateHits = 0
}
private struct MetadataHostProbe: NSViewRepresentable {
    let state: MetadataHostProbeState
    func makeNSView(context: Context) -> NSTextField {
        state.starts += 1; context.environment.metadataEditorLifecycle.begin()
        let field = NSTextField(string: "retained editor")
        return field
    }
    func updateNSView(_ view: NSTextField, context: Context) {
        state.updates += 1; context.environment.metadataEditorLifecycle.begin()
    }
}

@Suite(.serialized) @MainActor struct WorkflowWorkspacePresentationTests {
    @Test func retainedVisibilityDefersKeyLoopWorkAndCoalescesLatestRequest() async throws {
        let host = RetainedNativeHostingView(rootView: Color.clear)
        host.setInitialVisibility(true)
        host.frame = .init(x: 0, y: 0, width: 300, height: 200)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        let button = NSButton(title: "Retained hit target", target: nil, action: nil)
        button.frame = .init(x: 20, y: 20, width: 180, height: 32)
        host.addSubview(button)
        let hitPoint = CGPoint(x: 40, y: 30)
        _ = try #require(host.hitTest(hitPoint), "Open pane must actually accept this point before testing closure")
        func drain() async {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
        host.requestVisibility(false)
        #expect(!host.isHidden, "Native key-loop work must not run inside updateNSView")
        #expect(host.hitTest(hitPoint) == nil, "Closing pane rejects mouse input immediately")
        host.requestVisibility(true)
        await drain()
        #expect(!host.isHidden, "A superseded close must not transiently release editor focus")
        #expect(host.hitTest(hitPoint) != nil)
        host.requestVisibility(false); host.requestVisibility(true); host.requestVisibility(false)
        await drain()
        #expect(host.isHidden)
        host.requestVisibility(true); host.invalidateVisibility()
        await drain()
        #expect(host.isHidden, "Dismantled host must not apply an obsolete open")
        #expect(host.hitTest(.init(x: 10, y: 10)) == nil)
        let initial = RetainedNativeHostingView(rootView: Color.clear)
        initial.setInitialVisibility(false)
        #expect(initial.isHidden, "Initially inactive panes must never enter the native key loop")
    }

    @Test func retainedSiblingSwitchReleasesFocusWithoutReplacingEditors() async throws {
        func pane(_ firstVisible: Bool) -> some View {
            ZStack {
                RetainedContentHost(content: TextSourcesQuestionEditor(value: "first", editEpoch: 0,
                    isEditable: true, accessibilityIdentifier: "retained-first", onEdit: { _ in }),
                    visible: firstVisible, identifier: "retained-first-host")
                RetainedContentHost(content: TextSourcesQuestionEditor(value: "second", editEpoch: 0,
                    isEditable: true, accessibilityIdentifier: "retained-second", onEdit: { _ in }),
                    visible: !firstVisible, identifier: "retained-second-host")
            }
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let host = NSHostingView(rootView: pane(true))
        host.frame = .init(x: 0, y: 0, width: 320, height: 240)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        func settle() async throws {
            for _ in 0..<4 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        }
        try await settle()
        let editors = descendants(host).compactMap { $0 as? NSTextView }
        let first = try #require(editors.first { $0.string == "first" })
        let second = try #require(editors.first { $0.string == "second" })
        #expect(window.makeFirstResponder(first))
        first.setMarkedText("pinyin", selectedRange: .init(location: 6, length: 0),
                            replacementRange: .init(location: NSNotFound, length: 0))
        host.rootView = pane(true); host.frame.size.width = 360
        try await settle()
        #expect(first.hasMarkedText() && window.firstResponder === first)
        host.rootView = pane(false)
        try await settle()
        #expect(first.isHiddenOrHasHiddenAncestor && !second.isHiddenOrHasHiddenAncestor)
        #expect(window.firstResponder !== first)
        host.rootView = pane(true)
        try await settle()
        #expect(!first.isHiddenOrHasHiddenAncestor && second.isHiddenOrHasHiddenAncestor)
        #expect(descendants(host).contains { $0 === first } && descendants(host).contains { $0 === second })
        #expect(window.firstResponder !== first, "Reopening must not steal text focus")
    }

    @Test func retainedNativeHostsForwardMetadataCloseGateWithoutReplacingEditor() async throws {
        let state = MetadataHostProbeState()
        let lifecycle = MetadataEditorLifecycle(begin: { state.gateHits += 1 })
        func view(_ visible: Bool) -> some View {
            RetainedContentHost(content:
                RetainedContentHost(content: MetadataHostProbe(state: state), visible: true, identifier: "inner"),
                visible: visible, identifier: "outer")
                .environment(\.metadataEditorLifecycle, lifecycle)
        }
        let host = NSHostingView(rootView: view(true)); host.frame = CGRect(x: 0, y: 0, width: 300, height: 200)
        for _ in 0..<15 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        #expect(state.starts == 1 && state.gateHits > 0)
        let gates = state.gateHits
        host.rootView = view(false); host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        host.rootView = view(true); host.frame.size.width = 340
        for _ in 0..<15 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
        #expect(state.starts == 1 && state.gateHits >= gates && state.updates > 0)
    }

    @Test func metadataLateReadDoesNotReplaceNewObjectAndSameObjectRefreshRetainsDraftParent() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory()).resolvingSymlinksInPath()
            .appendingPathComponent("metadata-identity-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await ProjectStore.create(at: root.appendingPathComponent("Test.dproject"), name: "Metadata")
        let runtime = WorkbenchSession(engine: WorkspaceNoInference(), backendID: "never",
            status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) }, shutdown: {}, cleanup: {}, validateModel: { _ in })
        let controller = WorkflowController(services: .init(store: store, session: runtime,
            resolveText: { throw WorkflowIssue("No model") }, resolveImage: { throw WorkflowIssue("No model") }))
        await controller.load()
        let a = try await store.publishWorkflowAsset(data: Data("A".utf8), mediaType: "text/plain", name: "A", operationID: "d.text.input")
        let b = try await store.publishWorkflowAsset(data: Data("B".utf8), mediaType: "text/plain", name: "B", operationID: "d.text.input")
        let first = try await store.assetMetadataSnapshot(id: a.asset.id), second = try await store.assetMetadataSnapshot(id: b.asset.id)
        let aid = WorkflowAssetPreviewState.Identity(controller: controller, reference: a.record.reference)
        let bid = WorkflowAssetPreviewState.Identity(controller: controller, reference: b.record.reference)
        let state = AssetMetadataLoadState()
        var pending: CheckedContinuation<ProjectAssetMetadataSnapshot, Error>?
        let slow = Task { @MainActor in await state.load(identity: aid) { try await withCheckedThrowingContinuation { pending = $0 } } }
        await Task.yield()
        let callback = try #require(pending)
        await state.load(identity: bid) { second }
        callback.resume(returning: first); await slow.value
        #expect(state.snapshot?.asset.id == b.asset.id && state.identity == bid)
        pending = nil
        let refresh = Task { @MainActor in await state.load(identity: bid) { try await withCheckedThrowingContinuation { pending = $0 } } }
        await Task.yield()
        let refreshCallback = try #require(pending)
        #expect(state.snapshot?.asset.id == b.asset.id) // Keep the editor's presentation parent during a refresh.
        state.invalidate(); refreshCallback.resume(returning: second); await refresh.value
        #expect(state.snapshot == nil && state.identity == nil)
        let results = WorkflowResultQueryState(), tags = try SharedLibraryStore()
        var waiting: CheckedContinuation<[ProjectAssetMetadataSnapshot], Error>?
        let oldRead = Task { @MainActor in await results.load(identity: .init(controller: controller, references: [a.record.reference])) {
            try await withCheckedThrowingContinuation { waiting = $0 }
        } }
        await Task.yield(); let oldCallback = try #require(waiting)
        await results.load(identity: .init(controller: controller, references: [b.record.reference])) { [second] }
        oldCallback.resume(returning: [first]); await oldRead.value
        #expect(Set(results.items.keys) == [b.record.reference] && !results.isLoading)
        results.query = .init(properties: .init(width: .init(minimum: 9999)))
        #expect(!results.keepsVisible(.asset(b.record.reference), store: tags))
        let failure = WorkflowCandidate(error: "failed before publication", seed: "none")
        #expect(results.keepsVisible(.collection([failure]), store: tags))
        #expect(results.keepsVisible(.data(.text("waiting for a decision")), store: tags))
        await results.load(identity: .init(controller: controller, references: [b.record.reference])) { throw WorkflowIssue("Read unavailable") }
        #expect(results.failure?.contains("Read unavailable") == true && !results.isLoading)
        let before = await store.snapshot()
        let expected = ProjectAssetEditBaseline(project: before, asset: b.asset)
        try await controller.saveAssetAnnotations(expected: expected, name: nil, note: "Saved by current controller", isFavorite: nil)
        await #expect(throws: WorkflowIssue.self) { try await controller.saveAssetAnnotations(expected: expected, name: nil, note: "Stale draft", isFavorite: nil) }
        controller.deactivateAfterClose()
        await #expect(throws: WorkflowIssue.self) { try await controller.saveAssetAnnotations(expected: expected, name: "Closed writer", note: nil, isFavorite: nil) }
        let saved = try await store.assetMetadataSnapshot(id: b.asset.id)
        #expect(saved.asset.name == b.asset.name && saved.asset.note == "Saved by current controller")
        try await store.close()
    }

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
        #expect(ends.start == ports[output] && ends.end == ports[input])
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
            onImport: { _ in }, onDestination: {}, onPublishText: {}, onReturnText: { _ in })
            .testingOverlayState(WorkbenchSidebarState(leading: false, trailing: false)))
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

extension WorkflowWorkspacePresentationTests {
    @Test func explicitPanelIntentPreservesResourcesPinAndRunTarget() {
        let a = UUID(), b = UUID(), run = UUID()
        var state = WorkflowWorkspacePanels()
        state.selectPreparation(.programs)
        state.selectRun(run)
        state.selectResult(node:a,call:nil)
        state.inspect(a)
        #expect(state.preparation == .configuration && state.output == .node)
        state.pinned = true
        state.inspect(b)
        #expect(state.nodeID == a && state.runID == run)
        state.clearSelection()
        #expect(state.preparation == .programs && state.output == .node && state.nodeID == a)
        state.pinned = false; state.clearSelection()
        #expect(state.output == .node && state.nodeID == a && state.runID == run)
        state.selectPreparation(.models)
        #expect(state.lastResource == .models && state.runID == run)
    }

    @Test func selectedRunAndExactCallNeverFallBackToLatestOrOtherNode() {
        let graph = WorkflowExamples.text(), node = graph.nodes[0]
        let first = WorkflowStepRun(node: node, signature: "first", status: .completed)
        let second = WorkflowStepRun(node: node, signature: "second", status: .completed)
        let run = WorkflowRun(graph: graph, targetNodeID: node.id, steps: [first, second], status: .completed)
        var state = WorkflowWorkspacePanels(); state.selectRun(run.id); state.inspect(node.id)
        #expect(state.record(in: run) == nil) // Multiple calls require an explicit choice.
        let call = WorkflowWorkspacePanels.records(in: run)[0]
        state.selectResult(node: node.id, call: .init(address: call.address, stepID: call.id))
        #expect(state.record(in: run)?.step.signature == "first")
        var other = run; other.id = UUID()
        #expect(state.record(in: other) == nil)
        state.selectRun(other.id)
        #expect(state.call == nil && state.record(in: run) == nil)
        state.nodeID = UUID()
        #expect(state.record(in: other) == nil)
    }
}

extension WorkflowWorkspacePresentationTests {
    @Test func resultTagDraftCannotWriteAfterItsControllerCloses() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory()).appendingPathComponent("tag-owner-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await ProjectStore.create(at: root.appendingPathComponent("Test.dproject"), name: "Test")
        let published = try await store.publishWorkflowAsset(data: Data("text".utf8), mediaType: "text/plain", name: "source", operationID: "d.text.input")
        let runtime = WorkbenchSession(engine: WorkspaceNoInference(), backendID: "never", status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) }, shutdown: {}, cleanup: {}, validateModel: { _ in })
        let controller = WorkflowController(services: WorkflowServices(store: store, session: runtime,
            resolveText: { throw WorkflowIssue("No model") }, resolveImage: { throw WorkflowIssue("No model") }))
        await controller.load()
        let check = WorkflowMetadataTarget.validation(controller: controller, assetID: published.asset.id)
        try check()
        controller.deactivateAfterClose()
        #expect(throws: WorkflowIssue.self) { try check() }
        try await store.close()
    }
}

// DUI-A01/A02: production state and summaries, with no windows or inference.
extension WorkflowWorkspacePresentationTests {
    @Test(arguments: [false, true])
    func finiteReviewDeletedResultTagStaysVisibleAndRemovable(any: Bool) throws {
        let store = try SharedLibraryStore()
        let tag = try #require(store.createTags(["temporary"]).first)
        let reference = WorkflowAssetReference(projectID: UUID(), assetID: UUID(), version: UUID(), kind: .image, sha256: String(repeating: "a", count: 64))
        let key = "asset:" + reference.projectID.uuidString + ":" + reference.assetID.uuidString
        try store.addTags([tag], to: [key])
        let state = WorkflowResultQueryState()
        let path: WritableKeyPath<SharedLibraryQuery, Set<UUID>> = any ? \.anyTagIDs : \.allTagIDs
        state.query[keyPath: path] = [tag]
        state.query.contentKinds = [.image]
        #expect(state.matches(reference, store: store))
        try store.deleteTags([tag]) // Legal: this is a result draft, not a saved query.
        #expect(!state.matches(reference, store: store))
        #expect(throws: SharedLibraryError.self) { try store.createSavedQuery(name: "invalid", query: state.query) }
        let chips = WorkflowResultQueryState.tagConditions(state.query[keyPath: path], store: store, missingLabel: "Deleted tag")
        #expect(chips.count == 1 && chips[0].id == tag)
        #expect(chips[0].title == "Deleted tag")
        #expect(!chips[0].title.contains(tag.uuidString))
        try store.undo()
        #expect(state.matches(reference, store: store))
        #expect(WorkflowResultQueryState.tagConditions(state.query[keyPath: path], store: store, missingLabel: "Deleted tag").first?.title == "temporary")
        try store.redo()
        state.query[keyPath: path].remove(chips[0].id) // Same mutation as the real chip button.
        #expect(state.matches(reference, store: store))
        #expect(state.query.contentKinds == [.image] && state.query[keyPath: path].isEmpty)
        #expect(store.metadata.tags[tag] == nil && store.canUndo)
    }

    @Test(arguments: ["zh-Hans", "en"])
    func finiteReviewSavedCallSummaryRetainsCompleteScope(languageID: String) throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"]))
            .appendingPathComponent("call-summary-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("library.json")
        let store = try SharedLibraryStore(fileURL: file)
        let scope = SharedLibraryQueryScope(mode: .run, projectID: UUID(), instanceID: UUID(), runID: UUID(), nodeID: UUID(), stepID: UUID())
        let saved = try store.createSavedQuery(name: "one call", query: .init(scope: scope))
        let reopened = try SharedLibraryStore(fileURL: file)
        let query = try #require(reopened.metadata.savedQueries[saved]?.query)
        #expect(query.scope == scope)
        let language = UILanguageStore(preferredLanguages: [languageID])
        try language.select(languageID)
        #expect(language.effectiveLanguageIdentifier == languageID && language.diagnostics.isEmpty)
        let text: (String, String, String) -> String = { metadataText(language, $0, $1, $2) }
        let title = SharedLibraryScopeSummary.title(try #require(query.scope), text: text)
        for id in [scope.projectID, scope.instanceID, scope.runID, scope.nodeID, scope.stepID] {
            #expect(title.contains(try #require(id).uuidString))
        }
        #expect(title.contains(languageID == "en" ? "Call " : "具体调用 "))
        var other = scope; other.stepID = UUID()
        #expect(SharedLibraryScopeSummary.title(other, text: text) != title)
        try reopened.updateSavedQuery(saved, name: "another call", query: .init(scope: other))
        try reopened.undo()
        #expect(reopened.metadata.savedQueries[saved]?.query.scope == scope)
        #expect(SharedLibraryScopeSummary.title(try #require(reopened.metadata.savedQueries[saved]?.query.scope), text: text) == title)
        try reopened.redo()
        #expect(reopened.metadata.savedQueries[saved]?.query.scope == other)
        let dynamic = SharedLibraryScopeSummary.title(.init(mode: .currentProject), text: text)
        #expect(dynamic == (languageID == "en" ? "Current project instance when used" : "使用时的当前项目实例"))
        let project = SharedLibraryScopeSummary.title(.init(mode: .project, projectID: scope.projectID), text: text)
        #expect(project.contains(try #require(scope.projectID).uuidString))
        #expect(!project.contains(try #require(scope.instanceID).uuidString))
        #expect(!project.contains("Call") && !project.contains("具体调用"))
        let facts = SharedLibraryAssetFacts(projectID: try #require(scope.projectID), instanceID: try #require(scope.instanceID),
            registeredAt: Date(), occurrences: [.init(runID: try #require(scope.runID), nodeID: try #require(scope.nodeID), stepID: try #require(scope.stepID))])
        #expect(facts.matches(scope: scope, properties: nil, context: .init()))
        #expect(!facts.matches(scope: other, properties: nil, context: .init()))
    }
}

// D-RENDERING-WORKSPACE-01: real service owners, isolated stores, no model submit.
@MainActor private struct RenderingWorkspaceFixture {
    let root:URL, suite:String, settings:UserDefaults, owner:ProjectSession
    let store:ProjectStore, controller:WorkflowController, manifest:ProjectManifest
    let engine: WorkspaceNoInference
    static func make() async throws -> Self {
        let root=URL(fileURLWithPath:ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory()).appendingPathComponent("render-workspace-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let suite="D.RenderingWorkspace."+UUID().uuidString
        let settings=try #require(UserDefaults(suiteName:suite))
        let engine = WorkspaceNoInference()
        let owner=ProjectSession(sessionFactory:{ _ in WorkbenchSession(engine:engine,backendID:"never",status:{ .init(activeRunID:nil,phase:nil,queuedRunIDs:[]) },shutdown:{},cleanup:{},validateModel:{ _ in }) },settings:settings)
        await owner.createProject(at:root.appendingPathComponent("Fixture.dproject"));await owner.openWorkflow()
        return Self(root:root,suite:suite,settings:settings,owner:owner,store:try #require(owner.currentStore),controller:try #require(owner.workflow),manifest:try #require(owner.manifest),engine:engine)
    }
    func runtimeValueGraph() throws -> WorkflowGraph {
        controller.addBlankGraph(name: "Same")
        controller.addNode(operationID: "d.value.input")
        let node = try #require(controller.graph?.nodes.last)
        controller.setDataConfiguration(nodeID: node.id, value: .init(value: .text("用户原文 {seed} 🙂")))
        return try #require(controller.graph)
    }
    func close() async throws { await owner.closeProject();settings.removePersistentDomain(forName:suite);try FileManager.default.removeItem(at:root) }
    func target(_ reference:WorkflowAssetReference)->WorkflowViewerTarget { .init(title:"Same human title",subtitle:"isolated",value:.asset(reference)) }
    func viewer(_ target:WorkflowViewerTarget)->WorkflowViewerSession { .init(owner:owner,store:store,projectID:manifest.id,instanceID:manifest.effectiveInstanceID,target:target) }
}

extension WorkflowWorkspacePresentationTests {
    @Test(arguments: ["zh-Hans", "en"])
    func modelDraftInsertionAndPreparationCopyInBothLanguages(locale: String) async throws {
        let f = try await RenderingWorkspaceFixture.make()
        let language = UILanguageStore(settings: f.settings, preferredLanguages: [locale])
        try language.select(locale)
        let entry = try #require(SharedLibraryProjection.entries(models: [], readiness: [:], tools: [], projects: [], language: language)
            .first { entry in
                guard case .operation(let id, _) = entry.selection else { return false }
                return f.controller.registry.operation(id)?.definition.modelKind == .text
            })
        #expect(SharedLibraryBrowserLogic.insertionIssue(for: entry, controller: f.controller, language: language) == nil)
        #expect(language.text("workflow.node.prepare.notReady", fallback: "missing").contains(locale == "en" ? "not ready" : "未就绪"))
        #expect(language.text("workflow.node.prepare.download", fallback: "missing").contains(locale == "en" ? "Register" : "登记"))
        #expect(WorkbenchOwnedIssue.summary("此模型身份与操作不匹配，且不是受支持的目录草稿。", language: language)?.contains(locale == "en" ? "does not match" : "不匹配") == true)
        try await f.close()
    }

    @Test(arguments: [false, true])
    func assetDragRetainsIndependentDestinationWhileCanvasIsClosed(explicitInstance: Bool) async throws {
        let f = try await RenderingWorkspaceFixture.make()
        f.controller.deactivateAfterClose()
        let project = UUID(), instance = UUID(), asset = UUID()
        let selection: SharedLibraryBrowserSelection = explicitInstance
            ? .assetInstance(projectID: project, instanceID: instance, assetID: asset)
            : .asset(projectID: project, assetID: asset)
        let entry = SharedLibraryBrowserEntry(item: .init(key: "asset-test", title: "Fixture", kind: .asset, readiness: .available), selection: selection)
        #expect(SharedLibraryBrowserLogic.insertionIssue(for: entry, controller: f.controller, language: nil) != nil)
        let provider = SharedLibraryBrowserLogic.dragProvider(for: entry, controller: f.controller)
        let value: WorkflowCanvasTransfer = try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadTransferable(type: WorkflowCanvasTransfer.self) { continuation.resume(with: $0) }
        }
        #expect(value == (explicitInstance ? .assetInstance(projectID: project, instanceID: instance, assetID: asset) : .asset(projectID: project, assetID: asset)))
        try await f.close()
    }

    @Test(arguments: ["program", "registered-ready", "registered-unprepared", "unregistered", "wrong-kind", "removed", "changed-target", "read-only", "closed"])
    func libraryProviderThroughProductionCanvasCommandRespectsExactAdmission(scenario: String) async throws {
        let f = try await RenderingWorkspaceFixture.make(), c = f.controller
        c.addExample("template")
        let graph = try #require(c.graph)
        let scope = WorkflowCanvasScope(rootGraphID: graph.id, rootRevision: graph.revision,
            graphID: graph.id, bodyPath: [], projectID: c.projectID, instanceID: c.projectInstanceID)
        let catalog = try #require(SharedLibraryProjection.entries(models: [], readiness: [:], tools: [], projects: [], language: nil)
            .first { entry in
                guard case .operation(let id, _) = entry.selection else { return false }
                return c.registry.operation(id)?.definition.modelKind == .text
            })
        guard case .operation(let operation, let model) = catalog.selection else { throw WorkflowIssue("Missing catalog model") }
        let modelID = try #require(model)
        let program = SharedLibraryBrowserEntry(item: .init(key: "operation:d.text.input", title: "Text input", kind: .program, readiness: .available),
            selection: .operation(id: "d.text.input", modelID: nil))
        let isProgram = ["program", "changed-target", "read-only", "closed"].contains(scenario)
        if !isProgram && scenario != "unregistered" {
            c.modelChoices = [.init(id: modelID, kind: scenario == "wrong-kind" ? .image : .text, displayName: "Fixture registered model")]
        }
        let entry = isProgram ? program : try #require(SharedLibraryProjection.entries(models: c.modelChoices,
            readiness: [modelID: scenario == "registered-ready" ? .available : .unprepared], tools: [], projects: [], language: nil)
            .first { $0.id == catalog.id })
        // Wrong-kind uses the original exact text identity, never a fallback model.
        let source = scenario == "wrong-kind"
            ? SharedLibraryBrowserEntry(item: catalog.item, selection: .operation(id: operation, modelID: "image:ef52ee019fd1d0e75ae4deb40476ba65989716d7")) : entry
        let issue = SharedLibraryBrowserLogic.insertionIssue(for: source, controller: c, language: nil)
        #expect((issue != nil) == ["wrong-kind"].contains(scenario))
        let provider = SharedLibraryBrowserLogic.dragProvider(for: source, controller: c)
        #expect(provider.hasItemConformingToTypeIdentifier("org.d-workbench.canvas-item") == (issue == nil))
        #expect(provider.canLoadObject(ofClass: NSString.self), "Catalog organization drag remains available")
        // A transfer captured before admission changes (or by an older source)
        // must still be rejected by the actual destination/Controller.
        let captured = issue == nil ? provider : SharedLibraryBrowserLogic.dragProvider(for: source)
        let payload: WorkflowCanvasTransfer = try await withCheckedThrowingContinuation { continuation in
            _ = captured.loadTransferable(type: WorkflowCanvasTransfer.self) { continuation.resume(with: $0) }
        }
        if scenario == "removed" { c.modelChoices = [] }
        if scenario == "changed-target" { c.addBlankGraph(name: "Different target") }
        if scenario == "closed" { c.deactivateAfterClose() }
        let before = c.graphs, stored = await f.store.snapshot(), choices = c.modelChoices, runs = c.runs
        let canvas = WorkflowCanvasView(controller: c, onTextModel: {}, onImageModel: {}, onImport: { _ in },
            onDestination: {}, onPublishText: {}, onReturnText: { _ in }, nodeTags: ModelNodeTagStore(settings: f.settings))
        var commandCalls = 0
        let surface = WorkflowGraphSurface(controller: c, graph: graph, zoom: .constant(1), tool: .constant(.pointer),
            navigationRequest: .constant(nil), viewportInteractionLocked: .constant(false),
            viewContext: .init(projectID: c.projectID, rootGraphID: graph.id, bodyPath: []),
            pendingConnection: .constant(nil), selectedConnectionID: .constant(nil), readOnly: scenario == "read-only",
            onPlan: { _, _ in }, onDropItem: { value, point in commandCalls += 1; return canvas.dropItem(value, point) })
        let point = CGPoint(x: -140, y: 580)
        let accepted = surface.acceptSurfaceDrop([payload], at: point, scope: scope)
        let succeeds = ["program", "registered-ready", "registered-unprepared", "unregistered", "removed"].contains(scenario)
        #expect(accepted == succeeds)
        #expect(commandCalls == (["changed-target", "read-only", "closed"].contains(scenario) ? 0 : 1))
        if succeeds {
            let added = try #require(c.graph?.nodes.last)
            #expect(c.graph?.nodes.count == graph.nodes.count + 1)
            #expect(added.operationID == (isProgram ? "d.text.input" : operation))
            #expect(added.parameters["modelID"] == (isProgram ? nil : .text(modelID)))
            let layout = try #require(c.graph?.layout.first { $0.nodeID == added.id })
            #expect(layout.x == point.x && layout.y == point.y)
            c.undo(); #expect(c.graphs == before)
        } else {
            #expect(c.graphs == before)
            if ["wrong-kind"].contains(scenario) {
                #expect(c.errorMessage?.contains("身份与操作不匹配") == true)
            }
        }
        #expect(c.modelChoices == choices && c.runs == runs)
        #expect((await f.store.snapshot()).revision == stored.revision, "Drop cannot silently persist or compute")
        try await f.close()
    }

    @Test(arguments:[0,1,2,3]) func workspaceDraftUsesRealBranchesWithoutChangingOwners(mode:Int) async throws {
        let f=try await RenderingWorkspaceFixture.make(), c=f.controller
        c.addExample("template")
        let graph=try #require(c.graph),target=graph.nodes[2].id
        try await c.saveExplicitEdits()
        let before=await f.store.snapshot(),runs=c.runs,graphs=c.graphs,undo=c.canUndo
        let draft=try WorkflowWorkspaceRunDraft(controller:c,target:target,mode:mode)
        let expected:Set<UUID> = mode == 0 ? Set(graph.nodes.prefix(3).map(\.id)) : mode == 1 ? [target] : mode == 2 ? [target,graph.nodes[3].id] : [graph.nodes[3].id]
        #expect(Set(draft.slice.plan.steps.map(\.id)) == expected)
        #expect(draft.slice.boundaries.count == [0,2,2,1][mode])
        #expect(expected.isSubset(of:Set(draft.marks.keys)))
        for boundary in draft.slice.boundaries {
            #expect(draft.marks[boundary.sourceNodeID]?.kind == .historicalInput)
        }
        if mode == 0 {
            let layers=WorkflowWorkspaceRunDraft.layers(draft.slice.plan)
            #expect(layers.count == 2 && Set(layers[0].map(\.id)) == Set(graph.nodes.prefix(2).map(\.id)))
        }
        c.selectedNodeID=graph.nodes[0].id
        #expect(draft.isCurrent(in:c))
        #expect(c.runs == runs && c.graphs == graphs && c.canUndo == undo)
        #expect((await f.store.snapshot()).revision == before.revision)
        var node=graph.nodes[0];node.parameters["text"] = .text("changed")
        c.updateNode(node,in:graph.id)
        #expect(!draft.isCurrent(in:c))
        c.undo();#expect(c.graph == graph)
        try await f.close()
    }

    @Test func runtimeProjectionAndViewerReadNeverPublishOrLoseWaitingCall() async throws {
        let f=try await RenderingWorkspaceFixture.make(),c=f.controller
        c.addExample("template");let graph=try #require(c.graph)
        await c.run(target:graph.nodes[3].id,only:false)
        let rows=WorkflowLibraryValue.entries(c,language:nil)
        let waiting=try #require(rows.first { $0.runtimeValue?.call.address.path.contains(.node(graph.nodes[3].id)) == true })
        let projected=try #require(waiting.runtimeValue)
        #expect(projected.isCurrent(in:c))
        #expect(!SharedLibraryBrowserLogic.allows(.add,entry:waiting))
        #expect(!SharedLibraryBrowserLogic.allows(.location,entry:waiting))
        #expect(SharedLibraryBrowserLogic.allows(.preview,entry:waiting))
        let before=await f.store.snapshot()
        let viewer=f.viewer(.init(title:waiting.item.title,subtitle:waiting.item.detail,value:projected.value,call:projected.call,port:projected.port))
        await viewer.load()?.value
        #expect(viewer.exactRecord?.step.status == .waiting)
        #expect(c.services.activity.current?.phase == "waiting" && c.services.activity.current?.finished == true)
        #expect(viewer.text == "Describe a moonlit garden in a restrained editorial tone.")
        c.selectedNodeID=graph.nodes[0].id
        #expect(viewer.target.call == projected.call && viewer.exactRecord?.step.status == .waiting)
        let wrongPort = f.viewer(.init(title: "same visible value", subtitle: "", value: projected.value, call: projected.call, port: "nonexistent"))
        await wrongPort.load()?.value
        #expect(wrongPort.exactRecord == nil)
        wrongPort.suspend()

        #expect((await f.store.snapshot()).revision == before.revision)
        let all = WorkflowLibraryValue.entries(f.controller, language: nil)
        let references = Set(all.compactMap { $0.runtimeValue?.reference })
        let deduplicated = WorkflowLibraryValue.entries(f.controller, language: nil, excludingSaved: references, indexedSaved: try await f.store.libraryMetadataSnapshots())
        let expected = all.filter { entry in
            guard let runtime = entry.runtimeValue, runtime.reference != nil else { return true }
            return f.controller.callRecords(runID: runtime.call.address.runID).first { $0.id == runtime.call.stepID && $0.address == runtime.call.address }?.step.status == .waiting
        }
        #expect(deduplicated.map(\.id) == expected.map(\.id))
        viewer.stop();try await f.close()
    }

    @Test(arguments:[false,true]) func viewerLateSuccessOrFailureCannotReplaceNewFullReference(fail:Bool) async throws {
        let f=try await RenderingWorkspaceFixture.make()
        let a=try await f.store.publishWorkflowAsset(data:Data("A 原文".utf8),mediaType:"text/plain",name:"Same",operationID:"d.text.input")
        let b=try await f.store.publishWorkflowAsset(data:Data("B 👩🏽‍🎨".utf8),mediaType:"text/plain",name:"Same",operationID:"d.text.input")
        var waiting:CheckedContinuation<Void,Never>?
        let viewer=WorkflowViewerSession(owner:f.owner,store:f.store,projectID:f.manifest.id,instanceID:f.manifest.effectiveInstanceID,target:f.target(a.record.reference),readText:{ ref in
            let data=try await f.store.workflowText(ref)
            if ref == a.record.reference {
                await withCheckedContinuation { waiting=$0 }
                if fail { throw WorkflowIssue("late A failure") }
            }
            return data
        })
        let old=try #require(viewer.load())
        for _ in 0..<100 where waiting == nil { try await Task.sleep(for:.milliseconds(5)) }
        let release=try #require(waiting)
        viewer.replace(f.target(b.record.reference));await viewer.load()?.value
        let current=viewer.generation
        release.resume();await old.value
        #expect(viewer.generation == current && viewer.text == "B 👩🏽‍🎨" && viewer.failure == nil)
        #expect(viewer.metadata?.record?.reference == b.record.reference)
        let second=f.viewer(f.target(a.record.reference));await second.load()?.value
        viewer.stop();#expect(second.text == "A 原文" && second.canRead)
        await f.owner.closeProject()
        #expect(second.load() == nil && second.suspended && !second.canRead)
        var played=false;second.audioAction { played=true };#expect(!played)
        try await f.close()
    }

    @Test func viewerMetadataSaveKeepsOriginalCASButNeverPublishesIntoReplacement() async throws {
        let f=try await RenderingWorkspaceFixture.make()
        let a=try await f.store.publishWorkflowAsset(data:Data("A".utf8),mediaType:"text/plain",name:"A",operationID:"d.text.input")
        let b=try await f.store.publishWorkflowAsset(data:Data("B".utf8),mediaType:"text/plain",name:"B",operationID:"d.text.input")
        await f.owner.refreshAfterFileOperation(store:f.store,instanceID:f.manifest.effectiveInstanceID)
        var waiting:CheckedContinuation<Void,Never>?
        let viewer=WorkflowViewerSession(owner:f.owner,store:f.store,projectID:f.manifest.id,instanceID:f.manifest.effectiveInstanceID,target:f.target(a.record.reference),writeAnnotations:{ expected,name,note,favorite in
            try await f.owner.saveAssetAnnotations(owner:f.store,expected:expected,name:name,note:note,isFavorite:favorite)
            await withCheckedContinuation { waiting=$0 }
        })
        await viewer.load()?.value
        let expected=ProjectAssetEditBaseline(snapshot:try #require(viewer.metadata))
        let save=Task { try await viewer.saveMetadata(expected,nil,"A only",nil) }
        for _ in 0..<100 where waiting == nil { try await Task.sleep(for:.milliseconds(5)) }
        let release=try #require(waiting)
        viewer.replace(f.target(b.record.reference));await viewer.load()?.value
        release.resume();try await save.value
        #expect(viewer.metadata?.asset.id == b.asset.id && viewer.metadata?.asset.note == "")
        #expect(try await f.store.assetMetadataSnapshot(id:a.asset.id).asset.note == "A only")
        await #expect(throws:SharedLibraryError.staleAnnotation) { try await viewer.saveMetadata(expected,nil,"stale",nil) }
        #expect(try await f.store.workflowText(a.record.reference) == "A")
        #expect(try await f.store.workflowText(b.record.reference) == "B")
        viewer.suspend();try await f.close()
    }

    @Test(arguments:[0.25,1.0,4.0,-1.0,4.1]) func canvasSpeedColdPreferenceAndInvalidProtection(speed:Double) throws {
        let suite="D.CanvasSpeed."+UUID().uuidString,settings=try #require(UserDefaults(suiteName:suite))
        defer { settings.removePersistentDomain(forName:suite) }
        let state=ChatDisplayPreferencesState(settings:settings)
        var p=state.preferences;p.canvasNavigation = .init(wheelSpeed:speed)
        let valid=(0.25...4).contains(speed)
        #expect(state.update(p) == valid)
        let cold=ChatDisplayPreferencesState(settings:settings)
        let actual=Double(cold.preferences.canvasNavigation?.resolvedSpeed ?? 1)
        let expectedSpeed=valid ? speed:1
        #expect(actual == expectedSpeed)
        if !valid {
            let corrupt=try JSONEncoder().encode(p)
            settings.set(corrupt,forKey:ChatDisplayPreferences.storageKey)
            let invalid=ChatDisplayPreferencesState(settings:settings)
            #expect(invalid.hasInvalidStoredRecord && !invalid.update(ChatDisplayPreferences()))
            #expect(settings.data(forKey:ChatDisplayPreferences.storageKey) == corrupt)
            invalid.reset();#expect(!invalid.hasInvalidStoredRecord && invalid.preferences.canvasNavigation == nil)
        }
    }

    @Test func viewerNativeTextKeepsSelectionAndReadingPositionOnEqualUpdate() async throws {
        let original=String(repeating:"中文 paragraph\n",count:300)
        let host=NSHostingView(rootView:WorkflowViewerText(text:original,query:"",next:0));host.frame=CGRect(x:0,y:0,width:500,height:300)
        func descendants(_ v:NSView)->[NSView] { [v]+v.subviews.flatMap(descendants) }
        host.layoutSubtreeIfNeeded()
        let editor=try #require(descendants(host).compactMap { $0 as? NSTextView }.first)
        editor.setSelectedRange(NSRange(location:50,length:4));editor.enclosingScrollView?.contentView.scroll(to:CGPoint(x:0,y:180))
        let origin=editor.enclosingScrollView?.contentView.bounds.origin
        host.rootView=WorkflowViewerText(text:original,query:"",next:0);host.layoutSubtreeIfNeeded()
        #expect(descendants(host).contains { $0 === editor })
        #expect(editor.selectedRange() == NSRange(location:50,length:4) && editor.enclosingScrollView?.contentView.bounds.origin == origin)
        host.rootView=WorkflowViewerText(text:original,query:"paragraph",next:1);host.layoutSubtreeIfNeeded()
        #expect((editor.string as NSString).substring(with:editor.selectedRange()) == "paragraph")
        #expect(!editor.isEditable && editor.isSelectable)
    }
}

extension WorkflowWorkspacePresentationTests {
    @Test(arguments:[false,true]) func operationTreeRetainsEveryExactExecutableLeaf(models:Bool) throws {
        let entries=SharedLibraryProjection.entries(models:[],readiness:[:],tools:[],projects:[],language:nil).filter {
            models ? [.model,.component].contains($0.item.kind):[.program,.tool].contains($0.item.kind)
        }
        let tree=WorkflowOperationTree.make(entries,models:models,language:nil)
        func leaves(_ nodes:[WorkflowOperationTree])->[SharedLibraryBrowserEntry] { nodes.flatMap { $0.entry.map { [$0] } ?? leaves($0.children ?? []) } }
        let flat=leaves(tree)
        #expect(!flat.isEmpty && Set(flat.map(\.id)) == Set(entries.map(\.id)) && flat.count == entries.count)
        for entry in flat { #expect(entries.first { $0.id == entry.id } == entry) }
    }
}


extension WorkflowWorkspacePresentationTests {
    @Test(arguments:[false,true]) func viewerRejectsLateReadAfterSameProjectReopen(fail:Bool) async throws {
        let f=try await RenderingWorkspaceFixture.make()
        let asset=try await f.store.publishWorkflowAsset(data:Data("fixed original".utf8),mediaType:"text/plain",name:"same",operationID:"d.text.input")
        var waiting:CheckedContinuation<Void,Never>?
        let old=WorkflowViewerSession(owner:f.owner,store:f.store,projectID:f.manifest.id,instanceID:f.manifest.effectiveInstanceID,target:f.target(asset.record.reference),readText:{ ref in
            let bytes=try await f.store.workflowText(ref)
            await withCheckedContinuation { waiting=$0 }
            if fail { throw WorkflowIssue("old reader failure") }
            return bytes
        })
        let read=try #require(old.load())
        for _ in 0..<100 where waiting == nil { try await Task.sleep(for:.milliseconds(5)) }
        let release=try #require(waiting)
        await f.owner.closeProject();await f.owner.openProject(at:f.root.appendingPathComponent("Fixture.dproject"));await f.owner.openWorkflow()
        let store=try #require(f.owner.currentStore),controller=try #require(f.owner.workflow)
        #expect(store !== f.store && controller !== f.controller)
        #expect(f.owner.manifest?.id == f.manifest.id && f.owner.manifest?.effectiveInstanceID == f.manifest.effectiveInstanceID)
        let fresh=WorkflowViewerSession(owner:f.owner,store:store,projectID:f.manifest.id,instanceID:f.manifest.effectiveInstanceID,target:f.target(asset.record.reference))
        await fresh.load()?.value
        release.resume();await read.value
        #expect(!old.canRead && old.text == nil && old.metadata == nil && old.failure == nil)
        #expect(fresh.text == "fixed original" && fresh.metadata?.record?.reference == asset.record.reference && fresh.failure == nil)
        fresh.suspend();old.suspend();try await f.close()
    }

    @Test func viewerWaitingCallIsReadOnlyAndSwitchKeepsTaskDraftsAndOtherReader() async throws {
        let f=try await RenderingWorkspaceFixture.make(),c=f.controller
        c.addExample("template");let graph=try #require(c.graph),target=graph.nodes[3].id
        await c.run(target:target,only:false)
        let arun=try #require(c.runs.last)
        let a=try #require(WorkflowWorkspacePanels.records(in:arun).first { $0.step.node.id == target })
        c.editReviewText(stepID:a.id,text:"draft A")
        await c.run(target:target,only:true)
        let brun=try #require(c.runs.last)
        let b=try #require(WorkflowWorkspacePanels.records(in:brun).first { $0.step.node.id == target })
        c.editReviewText(stepID:b.id,text:"draft B")
        let av=try #require(a.step.outputs.values.first),bv=try #require(b.step.outputs.values.first)
        #expect(a.id != b.id && av == bv)
        let viewer=f.viewer(.init(title:"A",subtitle:"",value:av,call:.init(address:a.address,stepID:a.id),port:a.step.outputs.keys.sorted().first))
        await viewer.load()?.value
        let host=NSHostingView(rootView:WorkflowViewerContent(session:viewer,reopen:{}));host.frame = .init(x:0,y:0,width:800,height:640)
        func descendants(_ v:NSView)->[NSView] { [v]+v.subviews.flatMap(descendants) }
        func editor()->NSTextView? { descendants(host).compactMap { $0 as? NSTextView }.first { $0.accessibilityIdentifier() == "workflow-review-text" } }
        for _ in 0..<40 { host.layoutSubtreeIfNeeded();try await Task.sleep(for:.milliseconds(10)) }
        #expect(editor() == nil) // Review drafts belong to the activity task form, never the read-only Viewer.
        let coordinator=WorkflowViewerCoordinator()
        let second=f.viewer(.init(title:"independent",subtitle:"",value:av));await second.load()?.value
        let secondGeneration=second.generation
        coordinator.navigate(.init(title:"B",subtitle:"",value:bv,call:.init(address:b.address,stepID:b.id),port:b.step.outputs.keys.sorted().first),in:viewer)
        for _ in 0..<40 { host.layoutSubtreeIfNeeded();try await Task.sleep(for:.milliseconds(10)) }
        #expect(editor() == nil)
        #expect(viewer.exactRecord?.id == b.id && second.generation == secondGeneration && second.target.title == "independent")
        #expect(c.runs.flatMap { WorkflowWorkspacePanels.records(in:$0) }.first { $0.id == a.id }?.step.reviewTextDraft == "draft A")
        viewer.suspend();second.suspend();host.removeFromSuperview();try await f.close()
    }
}


extension WorkflowWorkspacePresentationTests {
    @Test func actualWorkspaceIntentChangeInvalidatesPlanWhileInspectingDoesNot() async throws {
        let f=try await RenderingWorkspaceFixture.make(),c=f.controller;c.addExample("template")
        let graph=try #require(c.graph),a=graph.nodes[2].id,b=graph.nodes[3].id
        var controls:WorkflowCanvasUpdateProbe.Workspace?
        WorkflowCanvasUpdateProbe.workspace={controls=$0}
        defer { WorkflowCanvasUpdateProbe.workspace=nil }
        let host=NSHostingView(rootView:WorkflowCanvasView(controller:c,onTextModel:{},onImageModel:{},onImport:{_ in},onDestination:{},onPublishText:{},onReturnText:{_ in}));host.frame=CGRect(x:0,y:0,width:1200,height:800)
        func settle() async throws { for _ in 0..<8 { host.layoutSubtreeIfNeeded();try await Task.sleep(for:.milliseconds(10)) } }
        try await settle();try #require(controls).open(a,0);try await settle()
        #expect(controls?.draftTarget == a)
        c.selectedNodeID=b;try await settle();#expect(controls?.draftTarget == a)
        try #require(controls).target(b);try await settle();#expect(controls?.draftTarget == nil)
        try #require(controls).open(a,0);try await settle();try #require(controls).range(1);try await settle()
        #expect(controls?.draftTarget == nil && c.graph == graph && c.runs.isEmpty)
        host.removeFromSuperview();try await f.close()
    }
}

extension WorkflowWorkspacePresentationTests {
    @Test(arguments:["image","video","audio"]) func realViewerMediaReadersKeepIndependentContentAndPlayers(kind:String) async throws {
        let f=try await RenderingWorkspaceFixture.make()
        let published:WorkflowPublishedAsset
        if kind == "image" {
            let bitmap=try #require(WorkbenchLocalRenderer.bitmap(width:4,height:3));bitmap.setFillColor(CGColor(gray:0.7,alpha:1));bitmap.fill(.init(x:0,y:0,width:4,height:3))
            let image=try #require(bitmap.makeImage())
            let png=try #require(NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]))
            published=try await f.store.importWorkflowPNG(png,name:"fixture")
        } else {
            let root=try #require(ProcessInfo.processInfo.environment["D_GLASS_EVIDENCE_DIR"])
            published=try await f.store.importWorkflowMediaFile(at:URL(fileURLWithPath:root).appendingPathComponent(kind == "video" ? "synthetic.mp4":"synthetic.wav"))
        }
        let before=await f.store.snapshot(),target=f.target(published.record.reference)
        let one=f.viewer(target),two=f.viewer(target)
        await one.load()?.value;await two.load()?.value
        #expect(one.failure == nil && two.failure == nil)
        #expect(one.metadata?.record?.reference == published.record.reference && two.metadata?.record?.reference == published.record.reference)
        if kind == "image" { #expect(one.image?.width == 4 && two.image?.height == 3) }
        if kind == "video" {
            one.video.replace(url:one.mediaURL,identity:one.generation);two.video.replace(url:two.mediaURL,identity:two.generation)
            #expect(one.video.player !== two.video.player && two.video.player.currentItem != nil)
        }
        if kind == "audio" { #expect(one.audioFormat != nil && two.audioFormat != nil && one.audio.state == .recorded && two.audio.state == .recorded) }
        one.stop()
        #expect(two.canRead && two.metadata?.record?.reference == published.record.reference)
        if kind == "video" { #expect(one.video.player.currentItem == nil && two.video.player.currentItem != nil && two.video.player.rate == 0) }
        if kind == "audio" { two.audioAction { try two.audio.seek(toFrame:1) };#expect(two.audio.positionFrame == 1 && two.failure == nil) }
        #expect((await f.store.snapshot()).revision == before.revision)
        two.suspend();try await f.close()
    }
}

extension WorkflowWorkspacePresentationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["D_NATIVE_CANVAS_DROP"] == "1"), arguments: [false, true])
    func nativeCanvasDropReceiverAcceptsProgramAndRegisteredModel(model: Bool) async throws {
        let f = try await RenderingWorkspaceFixture.make(), c = f.controller
        c.addExample("template")
        let original = try #require(c.graph)
        let entry: SharedLibraryBrowserEntry
        if model {
            entry = try #require(SharedLibraryProjection.entries(models: [], readiness: [:], tools: [], projects: [], language: nil)
                .first { entry in
                    guard case .operation(let id, _) = entry.selection else { return false }
                    return c.registry.operation(id)?.definition.modelKind == .text
                })
            guard case .operation(_, let id) = entry.selection else { throw WorkflowIssue("Missing model") }
            c.modelChoices = [.init(id: try #require(id), kind: .text, displayName: "Registered fixture")]
        } else {
            entry = .init(item: .init(key: "operation:d.text.input", title: "Text", kind: .program, readiness: .available),
                          selection: .operation(id: "d.text.input", modelID: nil))
        }
        let provider = SharedLibraryBrowserLogic.dragProvider(for: entry, controller: c)
        let bytes: Data = try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: "org.d-workbench.canvas-item") { data, error in
                if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: error ?? CocoaError(.fileReadCorruptFile)) }
            }
        }
        let canvas = WorkflowCanvasView(controller: c, onTextModel: {}, onImageModel: {}, onImport: { _ in },
            onDestination: {}, onPublishText: {}, onReturnText: { _ in }, nodeTags: ModelNodeTagStore(settings: f.settings))
        var delivered: [(WorkflowCanvasTransfer, CGPoint)] = []
        let surface = WorkflowGraphSurface(controller: c, graph: original, zoom: .constant(1), tool: .constant(.pointer),
            navigationRequest: .constant(nil), viewportInteractionLocked: .constant(false),
            viewContext: .init(projectID: c.projectID, rootGraphID: original.id, bodyPath: []),
            pendingConnection: .constant(nil), selectedConnectionID: .constant(nil), readOnly: false,
            onPlan: { _, _ in }, onDropItem: { value, point in delivered.append((value, point)); return canvas.dropItem(value, point) })
        let host = NSHostingView(rootView: surface)
        host.frame = .init(x: 0, y: 0, width: 900, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        // The hidden host had no registered drop owner in its native hit path.
        // Keep this strict probe for an explicitly enabled visible-host run.
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(80)); host.layoutSubtreeIfNeeded()
        func descendants(_ v: NSView) -> [NSView] { v.subviews.flatMap { [$0] + descendants($0) } }
        let probe = try #require(descendants(host).compactMap { $0 as? WorkflowCanvasViewportInput.ProbeView }.first)
        let scroll = try #require(probe.enclosingScrollView)
        scroll.contentView.scroll(to: .zero); host.layoutSubtreeIfNeeded()
        let local = CGPoint(x: 90, y: 80)
        let point = scroll.contentView.convert(local, to: nil)
        var cursor = host.hitTest(host.superview?.convert(point, from: nil) ?? point)
        var receiver: NSView?
        while let view = cursor {
            if view.registeredDraggedTypes.contains(where: { UTType($0.rawValue).map { UTType.workflowCanvasItem.conforms(to: $0) } ?? false }) { receiver = view; break }
            cursor = view.superview
        }
        print("NATIVE_DROP_VIEWS=" + ([host] + descendants(host)).filter { !$0.registeredDraggedTypes.isEmpty }.map { "\(type(of: $0)):\($0.registeredDraggedTypes)" }.joined(separator: ";"))
        let target = try #require(receiver, "A real drop receiver must own the blank canvas point")
        let drag = WorkspaceCanvasDropInfo(bytes: bytes, key: entry.id, window: window, point: point)
        defer { drag.draggingPasteboard.releaseGlobally() }
        #expect(target.draggingEntered(drag).contains(.copy))
        try #require(target.prepareForDragOperation(drag))
        try #require(target.performDragOperation(drag))
        target.concludeDragOperation(drag)
        try await Task.sleep(for: .milliseconds(100)); host.layoutSubtreeIfNeeded()
        #expect(delivered.count == 1)
        #expect(delivered.first?.0 == (try WorkflowCanvasTransfer.decode(bytes)))
        #expect(c.graph?.nodes.count == original.nodes.count + 1)
        #expect(c.graph?.id == original.id)
        c.undo(); #expect(c.graph == original)
        try await f.close()
    }
}

@MainActor private final class WorkspaceCanvasDropInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard = NSPasteboard.withUniqueName()
    var draggingSourceOperationMask: NSDragOperation = .copy
    var draggingDestinationWindow: NSWindow?
    var draggingLocation: NSPoint
    var draggedImageLocation: NSPoint { draggingLocation }
    nonisolated var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    init(bytes: Data, key: String, window: NSWindow, point: CGPoint) {
        draggingDestinationWindow = window; draggingLocation = point; super.init()
        let item = NSPasteboardItem()
        item.setData(bytes, forType: .init("org.d-workbench.canvas-item")); item.setString(key, forType: .string)
        draggingPasteboard.writeObjects([item])
    }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?,
        classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {
        for (index, value) in (draggingPasteboard.readObjects(forClasses: classArray, options: searchOptions) ?? []).enumerated() {
            guard let writer = value as? NSPasteboardWriting else { continue }
            let item = NSDraggingItem(pasteboardWriter: writer)
            item.setDraggingFrame(.init(origin: draggingLocation, size: .init(width: 30, height: 30)), contents: nil)
            var stop: ObjCBool = false; block(item, index, &stop); if stop.boolValue { break }
        }
    }
}

extension WorkflowWorkspacePresentationTests {
    @Test func catalogDraftsRetainNamesAndExactRoutesWithoutRegistration() async throws {
        let f = try await RenderingWorkspaceFixture.make()
        let entries = SharedLibraryProjection.entries(models: [], readiness: [:], tools: [], projects: [], language: nil)
        for entry in entries {
            guard case .operation(let operation, let identity?) = entry.selection else { continue }
            let choice = try #require(WorkflowModelRoutes.draftChoice(operationID: operation, modelID: identity))
            #expect(choice.kind == f.controller.registry.operation(operation)?.definition.modelKind)
            #expect(SharedLibraryBrowserLogic.insertionIssue(for: entry, controller: f.controller, language: nil) == nil)
            #expect(WorkflowModelRoutes.draftChoice(operationID: "d.text.input", modelID: identity) == nil)
            if choice.kind == .text {
                let wrongRoute = operation == WorkflowModelRoutes.qwen35 ? "d.model.language" : WorkflowModelRoutes.qwen35
                #expect(WorkflowModelRoutes.draftChoice(operationID: wrongRoute, modelID: identity) == nil)
            }
            #expect(WorkflowModelRoutes.draftChoice(operationID: operation, modelID: identity + "unknown") == nil)
            let node = WorkflowNode(operationID: operation, title: "Draft", parameters: ["modelID": .text(identity)])
            let presented = WorkflowNodeIdentity.resolve(node: node, definition: f.controller.registry.operation(operation)?.definition,
                modelChoices: [], assets: [], tools: [], language: nil)
            #expect(presented.detail?.contains(choice.displayName) == true)
        }
        let submissions = await f.engine.submissions
        #expect(f.controller.modelChoices.isEmpty && submissions == 0)
        try await f.close()
    }
    @Test func unpreparedDraftPersistsIdentityAndStillCannotSubmitInference() async throws {
        let f = try await RenderingWorkspaceFixture.make(), c = f.controller
        let identity = "image:ef52ee019fd1d0e75ae4deb40476ba65989716d7"
        c.addNode(operationID: "d.image.generate", modelID: identity, x: -40, y: 70)
        let node = try #require(c.graph?.nodes.last)
        #expect(c.modelSelectionTarget(nodeID: UUID()) == nil)
        #expect(c.modelSelectionTarget(nodeID: node.id)?.previousIdentity == identity)
        c.setParameter(nodeID: node.id, key: "promptText", value: .text("Tiny fixture, must never infer"))
        try await c.saveExplicitEdits()
        let graphID = try #require(c.graph?.id)
        await f.owner.closeProject(); await f.owner.openProject(at: f.store.rootURL); await f.owner.openWorkflow()
        let reopened = try #require(f.owner.workflow)
        let stored = try #require(reopened.graphs.first { $0.id == graphID }?.nodes.first { $0.id == node.id })
        #expect(stored.parameters["modelID"] == .text(identity))
        #expect(reopened.modelChoices.isEmpty)
        await reopened.run(target: node.id, only: false)
        #expect((await f.engine.submissions) == 0)
        #expect(reopened.errorMessage != nil || reopened.runs.contains { $0.status == .failed })
        try await f.close()
    }
    @Test func defaultModelPresentationUsesCurrentDefaultWithoutWritingIt() throws {
        let definition = try #require(WorkflowRegistry.standard.operation("d.image.generate")?.definition)
        let node = definition.makeNode()
        #expect(WorkflowNodeIdentity.modelIdentity(node: node, definition: definition, defaults: ["image": "image:default"]) == "image:default")
        #expect(WorkflowNodeIdentity.modelIdentity(node: node, definition: definition, defaults: [:]) == nil)
        var explicit = node; explicit.parameters["modelID"] = .text("image:explicit")
        #expect(WorkflowNodeIdentity.modelIdentity(node: explicit, definition: definition, defaults: ["image": "image:default"]) == "image:explicit")
        #expect(node.parameters["modelID"]?.string == "")
    }
}

extension WorkflowWorkspacePresentationTests {
    @Test func exactResultNavigationAndRuntimeAnnotationsKeepFrozenStateAndSearch() async throws {
        let f = try await RenderingWorkspaceFixture.make(), c = f.controller
        let graph = try f.runtimeValueGraph()
        await c.run(target: graph.nodes[0].id, only: false)
        let runs = c.runs, manifest = await f.store.snapshot(), selected = c.selectedNodeID, undo = c.canUndo
        let libraryURL = f.root.appendingPathComponent("annotation-library.json")
        let library = try SharedLibraryStore(fileURL: libraryURL)
        let entries = WorkflowLibraryValue.entries(c, language: nil, library: library)
        let entry = try #require(entries.first { $0.runtimeValue?.annotationIdentity != nil })
        let value = try #require(entry.runtimeValue), identity = try #require(value.annotationIdentity)
        let context = WorkflowLibraryContext(controller: c, source: .call(value.call), name: "Same human name")
        #expect(context.isCurrent(in: c) && context.includes(entry))
        let otherCall = WorkflowCallReference(address: .init(runID: value.call.address.runID, path: value.call.address.path + [.iteration(4)]), stepID: value.call.stepID)
        let wrong = WorkflowLibraryContext(controller: c, source: .call(otherCall), name: "Same human name")
        #expect(!wrong.isCurrent(in: c) && !wrong.includes(entry))
        let run = WorkflowLibraryContext(controller: c, source: .run(value.call.address.runID), name: "Run")
        #expect(run.isCurrent(in: c) && entries.filter(run.includes).count >= entries.filter(context.includes).count)
        let missing = WorkflowLibraryContext(controller: c, source: .run(UUID()), name: "Run")
        #expect(!missing.isCurrent(in: c) && entries.filter(missing.includes).isEmpty)
        let state = SharedLibraryBrowserState(query: .init(text: "old search"), scope: .all, selectedKeys: [entry.id], focusedKey: entry.id)
        state.draftText = "unsubmitted composition"; state.operationPath = ["private"]
        _ = try SharedLibraryBrowserLogic.visibleEntries(entries.filter(context.includes), store: library, query: state.query, scope: state.scope)
        #expect(state.query.text == "old search" && state.draftText == "unsubmitted composition" && state.operationPath == ["private"] && state.focusedKey == entry.id)
        let annotation = WorkflowValueAnnotation(name: "精确结果🙂", note: "说明 {run}", favorite: true)
        try value.saveAnnotation(in: c, library: library, expected: nil, value: annotation)
        let tags = try library.createTags(["私人标签"])
        try library.editOrganizationTags(expected: .init(keys: [identity.storageKey], metadata: library.metadata), add: Set(tags))
        let refreshed = WorkflowLibraryValue.entries(c, language: nil, library: library)
        let annotated = try #require(refreshed.first { $0.item.key == identity.storageKey })
        #expect(annotated.item.title == annotation.name && annotated.item.assetFacts?.favorite == true && annotated.item.assetFacts?.note == annotation.note)
        #expect(SharedLibraryBrowserLogic.tagEditEntries([annotated.id], in: refreshed).count == 1)
        #expect(!SharedLibraryBrowserLogic.allows(.add, entry: annotated))
        #expect(try SharedLibraryStore(fileURL: libraryURL).metadata.runtimeAnnotations[identity.storageKey] == annotation)
        #expect(!library.metadata.importedLegacyKeys.contains(identity.storageKey))
        let wrongValue = WorkflowLibraryValue(projectID: value.projectID, instanceID: value.instanceID, call: otherCall, port: value.port, value: value.value, createdAt: value.createdAt)
        #expect(throws: SharedLibraryError.staleAnnotation) { try wrongValue.saveAnnotation(in: c, library: library, expected: nil, value: annotation) }
        #expect(c.runs == runs && c.selectedNodeID == selected && c.canUndo == undo)
        #expect(await f.store.snapshot() == manifest)
        await f.owner.closeProject()
        #expect(!context.isCurrent(in: c))
        #expect(throws: SharedLibraryError.staleAnnotation) { try value.saveAnnotation(in: c, library: library, expected: annotation, value: .init(name: "late")) }
        try await f.close()
    }

    @Test func resourceViewerUsesSameAssetAnnotationOwnerWithoutRegisteringVersion() async throws {
        let f = try await RenderingWorkspaceFixture.make()
        let published = try await f.store.publishWorkflowAsset(data: Data("original bytes".utf8), mediaType: "text/plain", name: "Original", operationID: "d.text.input")
        await f.owner.refreshAfterFileOperation(store: f.store, instanceID: f.manifest.effectiveInstanceID)
        let content = try await f.store.readOnlyAsset(id: published.asset.id)
        let viewer = f.viewer(.init(title: "Original", subtitle: "", resource: content.token))
        await viewer.load()?.value
        let baseline = ProjectAssetEditBaseline(snapshot: try #require(viewer.metadata))
        try await viewer.saveMetadata(baseline, "Renamed", "Note", true)
        #expect(viewer.metadata?.asset.name == "Renamed" && viewer.metadata?.asset.note == "Note")
        let after = try await f.store.readOnlyAsset(content.token)
        #expect(after.data == content.data && after.token == content.token)
        #expect(after.metadata.record == content.metadata.record)
        viewer.stop(); try await f.close()
    }

    @Test func legacyCallAndAmbiguousSavedVersionNeverNavigateToOtherBytes() async throws {
        let f = try await RenderingWorkspaceFixture.make(), c = f.controller
        let published = try await f.store.publishWorkflowAsset(data: Data("original".utf8), mediaType: "text/plain", name: "Same", operationID: "d.text.input")
        let node = WorkflowNode(operationID: "d.text.input", title: "Same", parameters: ["text": .text("original")])
        let graph = WorkflowGraph(name: "Legacy", nodes: [node])
        let step = WorkflowStepRun(node: node, signature: "historical", outputs: ["output": .asset(published.record.reference)], status: .completed)
        let run = WorkflowRun(graph: graph, targetNodeID: node.id, steps: [step], status: .completed)
        let archive = try #require(try await f.store.workflowState().archive)
        _ = try await f.store.saveWorkflow(graphs: [graph], runs: [run], expectedRevision: archive.revision)
        await c.load()
        let call = WorkflowCallReference(address: .init(runID: run.id, path: []), stepID: step.id)
        let scope = WorkflowLibraryContext(controller: c, source: .call(call), name: "Same")
        let occurrence = SharedLibraryAssetOccurrence(runID: run.id, nodeID: node.id, stepID: step.id, address: nil)
        let snapshot = ProjectAssetMetadataSnapshot(project: f.manifest, asset: published.asset, record: published.record, job: nil, occurrences: [occurrence], sourceIssue: nil)
        var saved = SharedLibraryBrowserEntry(item: .init(key: "saved", title: "Same", kind: .asset, assetFacts: snapshot.facts), selection: .unavailable("fixture"))
        saved.metadataSnapshot = snapshot
        #expect(scope.isCurrent(in: c) && scope.includes(saved))
        #expect(WorkflowLibraryValue.entries(c, language: nil, excludingSaved: [published.record.reference], indexedSaved: [snapshot]).isEmpty)
        let ambiguous = ProjectAssetMetadataSnapshot(project: f.manifest, asset: published.asset, record: nil, job: nil, occurrences: [occurrence], sourceIssue: "multiple versions")
        saved.metadataSnapshot = ambiguous
        #expect(!scope.includes(saved))
        let retained = WorkflowLibraryValue.entries(c, language: nil, excludingSaved: [published.record.reference], indexedSaved: [ambiguous])
        #expect(retained.count == 1 && retained[0].runtimeValue?.reference == published.record.reference)
        #expect(scope.includes(retained[0]))
        let wrongStep = WorkflowLibraryContext(controller: c, source: .call(.init(address: call.address, stepID: UUID())), name: "Same")
        #expect(!wrongStep.isCurrent(in: c) && !wrongStep.includes(retained[0]))
        try await f.close()
    }

    @Test func batchAttemptLocationSeparatesSameNamedOutputsAndViewerLanguageKeepsContent() async throws {
        let f = try await RenderingWorkspaceFixture.make(), c = f.controller
        let graph = try f.runtimeValueGraph()
        let id = try await c.createBatchStage(selection: .through(graph.nodes[0].id), pins: [], repetitions: 2,
            expectedGraphID: graph.id, expectedRevision: graph.revision)
        await c.runBatchStage(id)
        let stage = try #require(c.batchStages.first { $0.id == id })
        #expect(stage.attempts.count == 2 && stage.attempts.allSatisfy { $0.state == .completed })
        let rows = WorkflowLibraryValue.entries(c, language: nil)
        let a = stage.attempts[0], b = stage.attempts[1]
        let scope = WorkflowLibraryContext(controller: c, source: .attempt(stage: id, attempt: a.id, run: a.runID), name: "Same")
        let wrong = WorkflowLibraryContext(controller: c, source: .attempt(stage: id, attempt: a.id, run: b.runID), name: "Same")
        #expect(scope.isCurrent(in: c) && !wrong.isCurrent(in: c))
        let located = rows.filter(scope.includes)
        #expect(!located.isEmpty && located.allSatisfy { $0.runtimeValue?.call.address.runID == a.runID })
        let other = rows.filter { $0.runtimeValue?.call.address.runID == b.runID }
        #expect(!other.isEmpty && Set(located.map(\.id)).isDisjoint(with: other.map(\.id)))
        let value = try #require(located.first { $0.runtimeValue?.annotationIdentity != nil }?.runtimeValue)
        let viewer = f.viewer(.init(title: "captured label", subtitle: "captured status", value: value.value, call: value.call, port: value.port, usesCallTitle: true))
        await viewer.load()?.value
        let language = UILanguageStore(preferredLanguages: ["zh-Hans"])
        let original = viewer.target, body = viewer.text, generation = viewer.generation, runs = c.runs
        let chinese = viewer.displayTitle(language) + viewer.displaySubtitle(language)
        try language.select("en")
        #expect(viewer.displayTitle(language) + viewer.displaySubtitle(language) != chinese)
        #expect(viewer.target.call == original.call && viewer.target.value == original.value && viewer.text == body && viewer.generation == generation && c.runs == runs)
        #expect(await f.engine.submissions == 0)
        viewer.stop(); try await f.close()
    }

    @Test func viewerAnnotationLifecyclePinsTargetAndKeepsOtherEditorGate() async throws {
        let f = try await RenderingWorkspaceFixture.make(), c = f.controller
        let graph = try f.runtimeValueGraph()
        await c.run(target: graph.nodes[0].id, only: false)
        let value = try #require(WorkflowLibraryValue.entries(c, language: nil).first { $0.runtimeValue?.annotationIdentity != nil }?.runtimeValue)
        let viewer = f.viewer(.init(title: "Original", subtitle: "", value: value.value, call: value.call, port: value.port))
        await viewer.load()?.value
        let model = WorkbenchModel(projectSession: f.owner), target = viewer.target, generation = viewer.generation
        model.beginEditing() // A separate workbench editor must keep its own close gate.
        viewer.beginAnnotationEditing(model: model)
        viewer.beginAnnotationEditing(model: model) // duplicate appearance is idempotent
        #expect(viewer.editingAnnotations && model.hasPendingEditor)
        viewer.replace(.init(title: "Other", subtitle: "", value: .data(.text("Other"))))
        #expect(viewer.load() == nil && viewer.target.call == target.call && viewer.target.value == target.value && viewer.generation == generation)
        await f.owner.closeProject() // Simulate an owner becoming unavailable outside the normal gated UI.
        viewer.reconcile()
        #expect(viewer.runtimeAnnotationTarget == value && !viewer.canRead && viewer.editingAnnotations)
        viewer.endAnnotationEditing()
        #expect(model.hasPendingEditor && !viewer.editingAnnotations)
        model.endEditing(); #expect(!model.hasPendingEditor)
        viewer.endAnnotationEditing(); #expect(!model.hasPendingEditor)
        viewer.stop(); try await f.close()
    }

    @Test func viewerFailedAnnotationWriteAfterSuspensionStillReportsFailureToEditor() async throws {
        let f = try await RenderingWorkspaceFixture.make()
        let published = try await f.store.publishWorkflowAsset(data: Data("immutable".utf8), mediaType: "text/plain", name: "Original", operationID: "d.text.input")
        var waiting: CheckedContinuation<Void, any Error>?
        let viewer = WorkflowViewerSession(owner: f.owner, store: f.store, projectID: f.manifest.id, instanceID: f.manifest.effectiveInstanceID,
            target: f.target(published.record.reference), writeAnnotations: { _, _, _, _ in
                try await withCheckedThrowingContinuation { waiting = $0 }
            })
        await viewer.load()?.value
        let expected = ProjectAssetEditBaseline(snapshot: try #require(viewer.metadata))
        let model = WorkbenchModel(projectSession: f.owner)
        viewer.beginAnnotationEditing(model: model)
        let save = Task { try await viewer.saveMetadata(expected, "recoverable draft", nil, nil) }
        for _ in 0..<100 where waiting == nil { try await Task.sleep(for: .milliseconds(5)) }
        let release = try #require(waiting)
        viewer.suspend()
        release.resume(throwing: SharedLibraryError.externalChange)
        await #expect(throws: SharedLibraryError.externalChange) { try await save.value }
        #expect(viewer.editingAnnotations && model.hasPendingEditor && viewer.metadata?.asset.name == "Original")
        #expect(try await f.store.workflowText(published.record.reference) == "immutable")
        viewer.endAnnotationEditing(); viewer.stop(); try await f.close()
    }
}
