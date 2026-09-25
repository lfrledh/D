import AppKit
import DInference
import DWorkbench
import Foundation
import SwiftUI
import Testing
@testable import UI

private actor CanvasNoInferenceEngine: InferenceEngine {
    private(set) var calls = 0
    func submit(_ request: InferenceRequest, backendID: String) async throws -> InferenceRun {
        calls += 1; throw WorkflowIssue("Hosting must never run inference")
    }
}

/// This exercises the actual view tree, not screen capture or native human interaction.
@Suite(.serialized) @MainActor
struct WorkflowCanvasHostingTests {
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
            #expect(await engine.calls == 0 && commands == 0)
        }
        try await controller.close(); try await store.close()
    }
}
