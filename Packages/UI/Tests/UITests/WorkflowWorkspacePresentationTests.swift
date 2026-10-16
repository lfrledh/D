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
        state.selectPreparation(.assets)
        state.selectRun(run)
        state.inspect(a)
        #expect(state.preparation == .configuration && state.output == .node)
        state.pinned = true
        state.inspect(b)
        #expect(state.nodeID == a && state.runID == run)
        state.clearSelection()
        #expect(state.preparation == .assets && state.output == .node && state.nodeID == a)
        state.pinned = false; state.clearSelection()
        #expect(state.output == .overview && state.runID == run)
        state.selectPreparation(.nodes)
        #expect(state.lastResource == .nodes && state.runID == run)
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
