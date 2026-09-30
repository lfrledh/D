import AppKit
import DInference
import DWorkbench
import Foundation
import SwiftUI
import Testing
@testable import UI

private actor Baseline02NoInferenceEngine: InferenceEngine {
    private(set) var calls = 0
    func submit(_ request: InferenceRequest, backendID: String) async throws -> InferenceRun {
        calls += 1
        throw WorkflowIssue("Hosting scroll must not execute inference")
    }
}

@Suite @MainActor
struct WorkflowBaseline02Tests {
    private let modelDefinition = WorkflowOperationDefinition(
        id: "d.test.model", title: "模型操作", detail: "", inputs: [], outputs: [], modelKind: .text
    )

    @Test func exactModelNamesKeepSeparateNodeInstancesAndAnnotations() {
        let choices = [WorkflowModelChoice(id: "text:A", kind: .text, displayName: "模型 A")]
        let first = WorkflowNode(operationID: modelDefinition.id, title: "写一首诗",
            parameters: ["modelID": .text("text:A")])
        let second = WorkflowNode(operationID: modelDefinition.id, title: "摘要",
            parameters: ["modelID": .text("text:A")])
        let a = WorkflowNodeIdentity.resolve(node: first, definition: modelDefinition,
            modelChoices: choices, assets: [], tools: [], language: nil)
        let b = WorkflowNodeIdentity.resolve(node: second, definition: modelDefinition,
            modelChoices: choices, assets: [], tools: [], language: nil)
        #expect(first.id != second.id)
        #expect(a.title == "模型 A" && b.title == "模型 A")
        #expect(a.annotation == "写一首诗" && b.annotation == "摘要")
        #expect(a.detail == "text:A" && b.detail == "text:A")
    }

    @Test func unboundAndUnknownModelsRemainExplicit() {
        let unbound = WorkflowNode(operationID: modelDefinition.id, title: "注释",
            parameters: ["modelID": .text("")])
        let unknown = WorkflowNode(operationID: modelDefinition.id, title: "注释",
            parameters: ["modelID": .text("text:exact-unavailable")])
        let empty = WorkflowNodeIdentity.resolve(node: unbound, definition: modelDefinition,
            modelChoices: [], assets: [], tools: [], language: nil)
        let missing = WorkflowNodeIdentity.resolve(node: unknown, definition: modelDefinition,
            modelChoices: [], assets: [], tools: [], language: nil)
        #expect(empty.title == "选择模型" && empty.detail == nil)
        #expect(missing.title == "未识别的模型")
        #expect(missing.detail == "text:exact-unavailable")
    }

    @Test func toolNameRequiresExactVersionAndDigest() throws {
        let tool = WorkflowToolDefinition(name: "固定工具", graph: WorkflowGraph())
        let reference = WorkflowToolReference(id: tool.id, version: tool.version,
            digest: try WorkflowPlanCompiler.digest(tool))
        var node = WorkflowNode(operationID: "d.control.invoke", title: "任务注释")
        node.control = .invoke(reference)
        let exact = WorkflowNodeIdentity.resolve(node: node, definition: nil,
            modelChoices: [], assets: [], tools: [tool], language: nil)
        #expect(exact.title == "固定工具")
        node.control = .invoke(.init(id: tool.id, version: tool.version, digest: "changed"))
        let changed = WorkflowNodeIdentity.resolve(node: node, definition: nil,
            modelChoices: [], assets: [], tools: [tool], language: nil)
        #expect(changed.title == "未识别的工具")
    }

    @Test func viewMemorySeparatesNestedBodiesAndRestoresSelection() {
        let project = UUID(), root = UUID(), node = UUID()
        let outer = WorkflowCanvasViewContext(projectID: project, rootGraphID: root, bodyPath: [])
        let inner = WorkflowCanvasViewContext(projectID: project, rootGraphID: root,
            bodyPath: [.init(nodeID: node, slot: "body")])
        var memory = WorkflowCanvasViewStateStore()
        let outerState = WorkflowCanvasViewMemory(zoom: 1.8,
            rawVisibleCenter: CGPoint(x: 440, y: 210), selectedNodeID: node)
        let innerState = WorkflowCanvasViewMemory(zoom: 0.5,
            rawVisibleCenter: CGPoint(x: 20, y: 90), selectedNodeID: nil)
        memory.save(outerState, for: outer)
        memory.save(innerState, for: inner)
        #expect(memory.state(for: outer) == outerState)
        #expect(memory.state(for: inner) == innerState)
        #expect(memory.state(for: .init(projectID: UUID(), rootGraphID: root, bodyPath: [])) == nil)
    }

    @Test func capturedLogicalCenterSurvivesPaddingAndZoomChanges() {
        let context = WorkflowCanvasViewContext(projectID: UUID(), rootGraphID: UUID(), bodyPath: [])
        var memory = WorkflowCanvasViewStateStore()
        let geometry = WorkflowCanvasViewportGeometry(graphSize: CGSize(width: 1400, height: 900),
            viewportSize: CGSize(width: 500, height: 400), zoom: 1.8,
            translation: CGSize(width: 150, height: 24))
        let manuallyObserved = geometry.visibleRawCenter(offset: CGPoint(x: 737, y: 519))
        memory.capture(zoom: 1.8, rawVisibleCenter: manuallyObserved,
            selectedNodeID: UUID(), for: context)
        #expect(memory.state(for: context)?.rawVisibleCenter == manuallyObserved)
    }

    @Test func manualHostingScrollRestoresActualOffsetAfterGraphSwitch() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent("baseline02-scroll-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await ProjectStore.create(at: root.appendingPathComponent("Scroll.dproject"), name: "Scroll")
        let engine = Baseline02NoInferenceEngine()
        let runtime = WorkbenchSession(engine: engine, backendID: "never",
            status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) },
            shutdown: {}, cleanup: {}, validateModel: { _ in })
        let services = WorkflowServices(store: store, session: runtime,
            resolveText: { throw WorkflowIssue("No model in scroll test") },
            resolveImage: { throw WorkflowIssue("No model in scroll test") })
        let controller = WorkflowController(services: services)
        await controller.load()
        controller.addExample("text")
        let originalGraph = try #require(controller.graph)
        let originalContext = WorkflowCanvasViewContext(projectID: controller.projectID,
            rootGraphID: originalGraph.id, bodyPath: [])
        var observations: [WorkflowCanvasViewContext: [CGPoint]] = [:]
        let view = WorkflowCanvasView(controller: controller, onTextModel: {}, onImageModel: {},
            onImport: { _ in }, onDestination: {}, onPublishText: {}, onReturnText: { _ in })
            .observingScroll { context, observation in
                observations[context, default: []].append(observation.contentOffset)
            }
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(x: 0, y: 0, width: 860, height: 580)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        func graphScrollView() -> NSScrollView? {
            descendants(host).compactMap { $0 as? NSScrollView }.first {
                ($0.documentView?.frame.width ?? 0) >= 1_400 && ($0.documentView?.frame.height ?? 0) >= 900
            }
        }
        var scroll: NSScrollView?
        for _ in 0..<40 {
            host.layoutSubtreeIfNeeded()
            scroll = graphScrollView()
            if scroll != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let canvas = try #require(scroll)
        canvas.contentView.scroll(to: CGPoint(x: 237, y: 119))
        canvas.reflectScrolledClipView(canvas.contentView)
        let actual = canvas.contentView.bounds.origin
        #expect(actual.x > 20 && actual.y > 20, "The source graph must be manually scrolled before restoration")
        for _ in 0..<40 {
            host.layoutSubtreeIfNeeded()
            if observations[originalContext]?.contains(where: {
                abs($0.x - actual.x) < 2 && abs($0.y - actual.y) < 2
            }) == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(observations[originalContext]?.contains(where: {
            abs($0.x - actual.x) < 2 && abs($0.y - actual.y) < 2
        }) == true)
        controller.addBlankGraph()
        let blankGraph = try #require(controller.graph)
        #expect(blankGraph.id != originalGraph.id)
        let blankContext = WorkflowCanvasViewContext(projectID: controller.projectID,
            rootGraphID: blankGraph.id, bodyPath: [])
        var blankOffset = CGPoint(x: CGFloat.infinity, y: CGFloat.infinity)
        let blankGeometry = WorkflowGraphGeometry(graph: blankGraph, tools: controller.tools,
            registry: controller.registry)
        func expectedBlankOffset(_ scroll: NSScrollView) -> CGPoint {
            let layout = WorkflowCanvasViewportGeometry(graphSize: blankGeometry.size,
                viewportSize: scroll.contentView.bounds.size, zoom: 1,
                translation: blankGeometry.translation)
            return layout.centeredOffset(on: layout.centerRawPoint)
        }
        for _ in 0..<40 {
            host.layoutSubtreeIfNeeded()
            let blankScroll = graphScrollView()
            blankOffset = blankScroll?.contentView.bounds.origin ?? blankOffset
            let expected = blankScroll.map(expectedBlankOffset) ?? .zero
            if observations[blankContext]?.contains(where: {
                abs($0.x - expected.x) < 2 && abs($0.y - expected.y) < 2
            }) == true && abs(blankOffset.x - expected.x) < 2 && abs(blankOffset.y - expected.y) < 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let blankScroll = try #require(graphScrollView())
        let expected = expectedBlankOffset(blankScroll)
        #expect(observations[blankContext]?.contains(where: {
            abs($0.x - expected.x) < 2 && abs($0.y - expected.y) < 2
        }) == true, "The blank graph must mount and report its reset offset before switching back")
        #expect(abs(blankOffset.x - expected.x) < 2 && abs(blankOffset.y - expected.y) < 2)
        controller.selectedGraphID = originalGraph.id
        var restored = CGPoint.zero
        for _ in 0..<40 {
            host.layoutSubtreeIfNeeded()
            restored = graphScrollView()?.contentView.bounds.origin ?? .zero
            if abs(restored.x - actual.x) < 2 && abs(restored.y - actual.y) < 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(abs(restored.x - actual.x) < 2 && abs(restored.y - actual.y) < 2)
        #expect(controller.runs.isEmpty)
        #expect(await engine.calls == 0)
        try await controller.close()
        try await store.close()
    }

    @Test func visibleInsertionPointUsesCurrentZoomAndScroll() {
        let offset = CGPoint(x: 120, y: 80)
        let container = CGSize(width: 500, height: 400)
        let translation = CGSize(width: 180, height: 260)
        func center(_ zoom: CGFloat) -> CGPoint {
            WorkflowCanvasViewportGeometry(graphSize: CGSize(width: 1400, height: 900),
                viewportSize: container, zoom: zoom, translation: translation)
                .visibleRawCenter(offset: offset)
        }
        #expect(center(0.5) == CGPoint(x: -440, y: -500))
        #expect(center(1) == CGPoint(x: -810, y: -780))
        #expect(abs(center(1.8).x + 974.4444) < 0.01)
        #expect(abs(center(1.8).y + 904.4444) < 0.01)
    }

    @Test func outputTransferRejectsOldScope() {
        let root = UUID(), graph = UUID(), node = UUID(), revision = UUID()
        let old = WorkflowCanvasTransfer.output(rootGraphID: root, bodyPath: [],
            graphID: graph, revision: revision, nodeID: node, port: "output")
        let current = WorkflowCanvasScope(rootGraphID: root, rootRevision: UUID(),
            graphID: graph, bodyPath: [])
        #expect(!old.matchesOutputScope(current))
    }

    @Test func connectionHitAreaExcludesBothPortCenters() {
        let source = WorkflowNode(operationID: "d.text.input", title: "source")
        let target = WorkflowNode(operationID: "d.text.output", title: "target")
        let connection = WorkflowConnection(sourceNode: source.id, targetNode: target.id)
        let graph = WorkflowGraph(nodes: [source, target], connections: [connection], layout: [
            .init(nodeID: source.id, x: 170, y: 200),
            .init(nodeID: target.id, x: 660, y: 240),
        ])
        let geometry = WorkflowGraphGeometry(graph: graph)
        let start = CGPoint(x: geometry.displayPosition(source.id).x + WorkflowCanvasLayoutPolicy.nodeWidth / 2,
                            y: geometry.displayPosition(source.id).y)
        let end = CGPoint(x: geometry.displayPosition(target.id).x - WorkflowCanvasLayoutPolicy.nodeWidth / 2,
                          y: geometry.displayPosition(target.id).y)
        let hit = WorkflowConnectionGeometry.hitPath(for: connection, geometry: geometry, portCenters: [:])
        #expect(!hit.contains(start) && !hit.contains(end))
        #expect(hit.boundingRect.width > 0)
    }

    @Test func connectionFailureNamesIncompatibleAndOccupiedInputs() throws {
        let source = WorkflowOperationDefinition(id: "fixture.source", title: "source", detail: "",
            inputs: [], outputs: [.init("text", "text", kinds: [.text]),
                                  .init("image", "image", kinds: [.image])])
        let target = WorkflowOperationDefinition(id: "fixture.target", title: "target", detail: "",
            inputs: [.init("input", "input", kinds: [.text])], outputs: [])
        let registry = try WorkflowRegistry(operations: [
            .init(definition: source, execute: { _, _ in throw WorkflowIssue("test only") }),
            .init(definition: target, execute: { _, _ in throw WorkflowIssue("test only") }),
        ])
        let a = source.makeNode(), b = target.makeNode(), c = source.makeNode()
        var graph = WorkflowGraph(nodes: [a, b, c])
        #expect(WorkflowCanvasConnectionPolicy.issue(graph: graph, registry: registry, tools: [],
            sourceNodeID: a.id, sourcePort: "image", targetNodeID: b.id, targetPort: "input") == .incompatibleKind)
        graph.connections = [.init(sourceNode: a.id, sourcePort: "text",
                                   targetNode: b.id, targetPort: "input")]
        #expect(WorkflowCanvasConnectionPolicy.issue(graph: graph, registry: registry, tools: [],
            sourceNodeID: a.id, sourcePort: "text", targetNodeID: b.id, targetPort: "input") == .duplicate)
        #expect(WorkflowCanvasConnectionPolicy.issue(graph: graph, registry: registry, tools: [],
            sourceNodeID: c.id, sourcePort: "text", targetNodeID: b.id, targetPort: "input") == .occupiedInput)
    }
}
