import AppKit
import DInference
import DWorkbench
import Foundation
import SwiftUI
import Testing
@testable import UI

private actor CanvasDelayGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false
    private(set) var started = false
    func wait() async {
        started = true
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() { opened = true; continuation?.resume(); continuation = nil }
}

private actor CanvasNoInferenceEngine: InferenceEngine {
    private(set) var calls = 0
    let gate: CanvasDelayGate?
    init(gate: CanvasDelayGate? = nil) { self.gate = gate }
    func submit(_ request: InferenceRequest, backendID: String) async throws -> InferenceRun {
        calls += 1
        if let gate { await gate.wait() }
        throw WorkflowIssue("Controlled hosting engine has no model")
    }
}

/// This exercises the actual view tree, not screen capture or native human interaction.
@Suite(.serialized) @MainActor
struct WorkflowCanvasHostingTests {
    @Test func officialExamplesAndToolCopiesHaveNonoverlappingRenderedCards() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent("example-card-layout-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try await ProjectStore.create(at: root.appendingPathComponent("Layout.dproject"), name: "Layout")
        let engine = CanvasNoInferenceEngine()
        let runtime = WorkbenchSession(engine: engine, backendID: "never",
            status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) },
            shutdown: {}, cleanup: {}, validateModel: { _ in })
        let services = WorkflowServices(store: store, session: runtime,
            resolveText: { throw WorkflowIssue("Layout must not load models") },
            resolveImage: { throw WorkflowIssue("Layout must not load models") })
        let controller = WorkflowController(services: services); await controller.load()
        func measure() async throws {
            let graph = try #require(controller.graph)
            let before = controller.graphs
            let toolsBefore = controller.tools
            for locale in ["zh-Hans", "en"] {
                var sizes: [UUID: CGSize] = [:]
                let view = WorkflowCanvasView(controller: controller, onTextModel: {}, onImageModel: {},
                    onImport: { _ in }, onDestination: {}, onPublishText: {}, onReturnText: { _ in })
                    .observingNodeSizes { sizes[$0] = $1 }
                    .environment(\.dLanguageStore, UILanguageStore(preferredLanguages: [locale]))
                let host = NSHostingView(rootView: view)
                host.frame = CGRect(x: 0, y: 0, width: 1500, height: 900)
                for _ in 0..<40 {
                    host.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(10))
                    if sizes.count == graph.nodes.count { break }
                }
                #expect(sizes.count == graph.nodes.count)
                let geometry = WorkflowGraphGeometry(graph: graph, tools: controller.tools, registry: controller.registry)
                let rectangles = try graph.nodes.map { node -> CGRect in
                    let size = try #require(sizes[node.id])
                    #expect(size.width > 0 && size.height > 0)
                    let point = geometry.displayPosition(node.id)
                    let rectangle = CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                        width: size.width, height: size.height)
                    #expect(rectangle.minY >= 0 && rectangle.maxY <= geometry.size.height,
                        "Card must remain reachable: \(graph.name) / \(node.title) / \(locale)")
                    return rectangle
                }
                for i in rectangles.indices {
                    for j in rectangles.indices where j > i {
                        #expect(!rectangles[i].intersects(rectangles[j]),
                            "Overlapping cards: \(graph.name) / \(graph.nodes[i].title) / \(graph.nodes[j].title) / \(locale)")
                    }
                }
                #expect(controller.graphs == before && controller.tools == toolsBefore)
                let calls = await engine.calls
                #expect(controller.runs.isEmpty && calls == 0)
            }
        }
        var measuredBodies = 0
        func measureTree() async throws {
            try await measure()
            let parent = try #require(controller.graph)
            let path = controller.bodyPath
            for node in parent.nodes {
                let children: [(String, WorkflowGraph)]
                switch node.control {
                case .branch(_, let thenBody, let otherwiseBody):
                    children = [("then", thenBody), ("otherwise", otherwiseBody)]
                case .map(let body, _), .loop(let body, _, _, _): children = [("body", body)]
                default: children = []
                }
                for (slot, body) in children {
                    controller.openBody(nodeID: node.id, slot: slot)
                    try #require(controller.errorMessage == nil)
                    try #require(controller.graph?.id == body.id)
                    try #require(controller.bodyPath == path + [.init(nodeID: node.id, slot: slot)])
                    measuredBodies += 1
                    try await measureTree()
                    controller.closeBody()
                    try #require(controller.graph?.id == parent.id && controller.bodyPath == path)
                }
            }
        }
        for choice in WorkflowLanguageExample.allCases {
            let count = controller.graphs.count
            let previous = controller.selectedGraphID
            controller.addLanguageExample(choice)
            try #require(controller.errorMessage == nil)
            try #require(controller.graphs.count == count + 1 && controller.selectedGraphID != previous)
            try #require(controller.graph?.id == controller.selectedGraphID && controller.bodyPath.isEmpty)
            try await measureTree()
        }
        for tool in controller.tools {
            let reference = WorkflowToolReference(id: tool.id, version: tool.version,
                digest: try WorkflowPlanCompiler.digest(tool))
            let count = controller.graphs.count
            let previous = controller.selectedGraphID
            controller.openToolCopy(reference)
            try #require(controller.errorMessage == nil)
            try #require(controller.graphs.count == count + 1 && controller.selectedGraphID != previous)
            try #require(controller.graph?.id == controller.selectedGraphID && controller.bodyPath.isEmpty)
            try #require(controller.graph?.id != tool.graph.id)
            try #require(controller.graph?.nodes.count == tool.graph.nodes.count)
            try await measureTree()
        }
        #expect(measuredBodies > 0)
        try await controller.close(); try await store.close()
    }

    @Test func waitingEditorWaitsForLoadAndPreservesCompositionDuringOtherExecution() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent("canvas-delay-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try await ProjectStore.create(at: root.appendingPathComponent("delayed.dproject"), name: "Delayed editor")
        let load = CanvasDelayGate(); let compute = CanvasDelayGate()
        let engine = CanvasNoInferenceEngine(gate: compute)
        let runtime = WorkbenchSession(engine: engine, backendID: "never", status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) },
            shutdown: {}, cleanup: {}, validateModel: { _ in }, textBackendID: "fixture.text")
        let services = WorkflowServices(store: store, session: runtime,
            defaultIdentity: { _ in "fixture" },
            resolveText: { .init(identity: "fixture", reference: .init(directory: root), backendID: "fixture.text") },
            resolveImage: { throw WorkflowIssue("No image model") })
        let c = WorkflowController(services: services); await c.load(); c.addExample("template")
        let graph = try #require(c.graph)
        await c.run(target: try #require(graph.nodes.last?.id), only: false)
        let step = try #require(c.runs.last?.steps.last)
        let host = NSHostingView(rootView: WorkflowWaitingDecision(controller: c, step: step, readOnly: false,
            preview: { ref in await load.wait(); return try await c.preview(ref) }))
        host.frame = CGRect(x: 0, y: 0, width: 500, height: 350)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        func editors(_ view: NSView) -> [NSTextView] {
            view.subviews.flatMap { ($0 as? NSTextView).map { [$0] } ?? editors($0) }
        }
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if await load.started { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await load.started)
        let editor = try #require(editors(host).first)
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if !editor.isEditable { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        // The reused native editor exposes and enforces its editable state;
        // loading cannot accept keystrokes that a delayed asset read overwrites.
        #expect(!editor.isEditable)
        #expect(c.runs.last?.steps.last?.reviewTextDraft == nil)
        await load.open()
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if editor.isEditable && !editor.string.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(editor.isEditable)
        let draft = "读取完成后输入 👩🏽‍🎨"
        editor.string = draft; editor.didChangeText()
        try await Task.sleep(for: .milliseconds(30))
        #expect(c.runs.last?.steps.last?.reviewTextDraft == draft)
        editor.setMarkedText("pin", selectedRange: NSRange(location: 3, length: 0),
                             replacementRange: NSRange(location: editor.string.utf16.count, length: 0))
        #expect(editor.hasMarkedText())
        c.addExample("text")
        let rewrite = try #require(c.graph?.nodes.first { $0.operationID == "d.text.rewrite" })
        let execution = Task { await c.run(target: rewrite.id, only: false) }
        for _ in 0..<100 {
            if await compute.started { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await compute.started, "\(c.errorMessage ?? c.progressMessage)")
        c.selectedGraphID = graph.id
        host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30))
        #expect(c.isRunning && editor.isEditable && editor.hasMarkedText())
        editor.insertText("拼", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.didChangeText()
        try await Task.sleep(for: .milliseconds(30))
        let composed = editor.string
        #expect(composed == draft + "拼" && !editor.hasMarkedText())
        #expect(c.runs.first?.steps.last?.reviewTextDraft == composed)
        #expect(c.runs.first?.steps.last?.decision == nil)
        await compute.open(); await execution.value
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if editor.isEditable { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!c.isRunning && editor.isEditable)
        #expect(c.runs.first?.steps.last?.reviewTextDraft == composed)
        #expect(c.runs.first?.steps.last?.decision == nil)
        await c.save()
        #expect(try await store.workflowState().archive?.runs.first?.steps.last?.reviewTextDraft == composed)
        try await c.close(); try await store.close()
    }

    @Test func mountsWideAndNarrowWithoutExecutingOrChangingGraph() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent("canvas-host-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try await ProjectStore.create(at: root.appendingPathComponent("hosting.dproject"), name: "Canvas hosting")
        let engine = CanvasNoInferenceEngine()
        let runtime = WorkbenchSession(engine: engine, backendID: "never", status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) },
            shutdown: {}, cleanup: {}, validateModel: { _ in })
        let services = WorkflowServices(store: store, session: runtime,
            resolveText: { throw WorkflowIssue("Hosting must not resolve a model") },
            resolveImage: { throw WorkflowIssue("Hosting must not resolve a model") })
        let controller = WorkflowController(services: services); await controller.load(); controller.addExample("image")
        let before = controller.graphs
        let language = UILanguageStore(preferredLanguages: ["zh-Hans"])
        var commands = 0
        let view = WorkflowCanvasView(controller: controller, onTextModel: { commands += 1 }, onImageModel: { commands += 1 },
            onImport: { _ in commands += 1 }, onDestination: { commands += 1 }, onPublishText: { commands += 1 },
            onReturnText: { _ in commands += 1 }).environment(\.dLanguageStore, language)
        let host = NSHostingView(rootView: view)
        for width: CGFloat in [1320, 820, 1320] {
            host.frame = CGRect(x: 0, y: 0, width: width, height: 850)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
            #expect(host.fittingSize.width <= width)
            #expect(controller.graphs == before); #expect(controller.runs.isEmpty)
            #expect(commands == 0); #expect(await engine.calls == 0)
        }
        if let directory = ProcessInfo.processInfo.environment["D_M0_RENDER_DIR"] {
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("M0-offscreen-hosting.png"), options: .withoutOverwriting)
        }
        // Exercise the actual waiting editor, whose local draft must survive the breakpoint.
        controller.addExample("template")
        let target = try #require(controller.graph?.nodes.last?.id)
        await controller.run(target: target, only: false)
        controller.selectedNodeID = target
        for _ in 0..<30 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let editor = try #require(descendants(host).compactMap { $0 as? NSTextView }.first { $0.isEditable })
        let draft = "尚未接受的修改 👩🏽‍🎨 e\u{301}"
        editor.string = draft; editor.didChangeText()
        editor.setSelectedRange(NSRange(location: 0, length: 2))
        for (width, locale): (CGFloat, String) in [(820, "en"), (1320, "zh-Hans"), (820, "en")] {
            try language.select(locale)
            host.frame.size.width = width; host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            let current = try #require(descendants(host).compactMap { $0 as? NSTextView }.first { $0.isEditable })
            #expect(current === editor); #expect(current.string == draft)
            #expect(current.selectedRange() == NSRange(location: 0, length: 2))
            #expect(host.fittingSize.width <= width)
            #expect(controller.runs.last?.status == .waiting)
            #expect(controller.runs.last?.steps.last?.decision == nil)
            #expect(controller.runs.last?.steps.last?.reviewTextDraft == draft)
            #expect(await engine.calls == 0 && commands == 0)
        }
        try await controller.close(); try await store.close()
    }
}
