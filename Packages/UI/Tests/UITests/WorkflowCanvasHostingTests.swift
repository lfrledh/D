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
    @Test func waitingEditorDisablesBeforeLoadAndDuringOtherExecution() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent("canvas-delay-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try await ProjectStore.create(at: root.appendingPathComponent("delayed.dproject"), name: "Delayed editor")
        let load = CanvasDelayGate(); let compute = CanvasDelayGate()
        let engine = CanvasNoInferenceEngine(gate: compute)
        let runtime = WorkbenchSession(engine: engine, backendID: "never", status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) },
            shutdown: {}, cleanup: {}, validateModel: { _ in }, textBackendID: "fixture.text")
        let services = WorkflowServices(store: store, session: runtime,
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
        c.addExample("text")
        let rewrite = try #require(c.graph?.nodes.first { $0.operationID == "d.text.rewrite" })
        let execution = Task { await c.run(target: rewrite.id, only: false) }
        for _ in 0..<100 {
            if await compute.started { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await compute.started)
        c.selectedGraphID = graph.id
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if !editor.isEditable { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(c.isRunning && !editor.isEditable)
        #expect(editor.string == draft)
        await compute.open(); await execution.value
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if editor.isEditable { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!c.isRunning && editor.isEditable)
        #expect(c.runs.first?.steps.last?.reviewTextDraft == draft)
        #expect(c.runs.first?.steps.last?.decision == nil)
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
        var commands = 0
        let view = WorkflowCanvasView(controller: controller, onTextModel: { commands += 1 }, onImageModel: { commands += 1 },
            onImport: { _ in commands += 1 }, onDestination: { commands += 1 }, onPublishText: { commands += 1 },
            onReturnText: { _ in commands += 1 })
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
        for width: CGFloat in [820, 1320] {
            host.frame.size.width = width; host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            let current = try #require(descendants(host).compactMap { $0 as? NSTextView }.first { $0.isEditable })
            #expect(current === editor); #expect(current.string == draft)
            #expect(controller.runs.last?.status == .waiting)
            #expect(controller.runs.last?.steps.last?.decision == nil)
            #expect(controller.runs.last?.steps.last?.reviewTextDraft == draft)
            #expect(await engine.calls == 0 && commands == 0)
        }
        try await controller.close(); try await store.close()
    }
}
