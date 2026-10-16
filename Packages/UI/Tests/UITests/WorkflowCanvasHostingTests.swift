import AppKit
import DInference
@testable import DWorkbench
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
        let layoutHost = NSHostingView(rootView: view)
        for width: CGFloat in [1320, 820, 1320] {
            layoutHost.frame = CGRect(x: 0, y: 0, width: width, height: 850)
            layoutHost.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
            #expect(layoutHost.fittingSize.width <= width)
            #expect(controller.graphs == before); #expect(controller.runs.isEmpty)
            #expect(commands == 0); #expect(await engine.calls == 0)
        }
        if let directory = ProcessInfo.processInfo.environment["D_M0_RENDER_DIR"] {
            let bitmap = try #require(layoutHost.bitmapImageRepForCachingDisplay(in: layoutHost.bounds))
            layoutHost.cacheDisplay(in: layoutHost.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("M0-offscreen-hosting.png"), options: .withoutOverwriting)
        }
        // Exercise the actual waiting editor, whose local draft must survive the breakpoint.
        controller.addExample("template")
        let target = try #require(controller.graph?.nodes.last?.id)
        await controller.run(target: target, only: false)
        controller.selectedNodeID = target
        let host = NSHostingView(rootView: WorkflowCanvasView(controller: controller,
            onTextModel: { commands += 1 }, onImageModel: { commands += 1 }, onImport: { _ in commands += 1 },
            onDestination: { commands += 1 }, onPublishText: { commands += 1 }, onReturnText: { _ in commands += 1 })
            .startingPanels(WorkflowWorkspacePanels(output: .node, runID: controller.runs.last?.id, nodeID: target))
            .environment(\.dLanguageStore, language))
        host.frame = .init(x: 0, y: 0, width: 1320, height: 850)
        for _ in 0..<30 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let editor = try #require(descendants(host).compactMap { $0 as? NSTextView }.first { $0.isEditable })
        let draft = "尚未接受的修改 👩🏽‍🎨 e\u{301}"
        editor.string = draft; editor.didChangeText()
        editor.setSelectedRange(NSRange(location: 0, length: 2))
        #expect(editor.selectedRange() == NSRange(location: 0, length: 2))
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

extension WorkflowCanvasHostingTests {
    private func repairPreviewFixture() async throws -> (ProjectStore, WorkflowController, WorkflowAssetReference) {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent("repair-preview-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try await ProjectStore.create(at: root.appendingPathComponent("Preview.dproject"), name: "Preview")
        let runtime = WorkbenchSession(engine: CanvasNoInferenceEngine(), backendID: "never",
            status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) }, shutdown: {}, cleanup: {}, validateModel: { _ in })
        let controller = WorkflowController(services: WorkflowServices(store: store, session: runtime,
            defaultIdentity: { _ in "" }, resolveText: { throw WorkflowIssue("No model") }, resolveImage: { throw WorkflowIssue("No model") }))
        await controller.load()
        let asset = try await store.publishWorkflowAsset(data: Data("original preview".utf8), mediaType: "text/plain",
            name: "Original", operationID: "d.text.publish", details: ["origin": "repair-fixture"])
        return (store, controller, asset.record.reference)
    }

    @Test(arguments: ["success", "failure", "cancel", "same-identity", "disappear", "metadata-success", "metadata-failure"])
    func assetPreviewRejectsLateResultsThroughProductionState(_ outcome: String) async throws {
        let (store, c, ref) = try await repairPreviewFixture()
        let state = WorkflowAssetPreviewState(), gate = CanvasDelayGate()
        let first = WorkflowAssetPreviewState.Identity(controller: c, reference: ref)
        let other = WorkflowAssetReference(projectID: ref.projectID, assetID: UUID(), version: ref.version, kind: ref.kind, sha256: ref.sha256)
        let next = outcome == "same-identity" ? first : WorkflowAssetPreviewState.Identity(controller: c, reference: other)
        let old = Task {
            await state.load(identity: first, preview: {
                if !outcome.hasPrefix("metadata-") { await gate.wait() }
                if outcome == "failure" { throw WorkflowIssue("late failure") }
                return Data("late A".utf8)
            }, metadata: {
                if outcome.hasPrefix("metadata-") { await gate.wait() }
                if outcome == "metadata-failure" { throw WorkflowIssue("late metadata failure") }
                return "late source A"
            })
        }
        for _ in 0..<100 { if await gate.started { break }; try await Task.sleep(for: .milliseconds(2)) }
        #expect(await gate.started)
        if outcome == "cancel" { old.cancel() }
        if outcome == "disappear" { state.invalidate() }
        else { await state.load(identity: next, preview: { Data("current B".utf8) }, metadata: { "source B" }) }
        await gate.open(); await old.value
        if outcome == "disappear" {
            #expect(state.identity == nil && state.data == nil && state.sourceMetadata == nil && state.failure == nil)
        } else {
            #expect(state.identity == next && state.data == Data("current B".utf8))
            #expect(state.sourceMetadata == "source B" && state.failure == nil)
        }
        // Current failures clear content and provenance together.
        await state.load(identity: first, preview: { throw WorkflowIssue("current failure") }, metadata: { "must not appear" })
        #expect(state.data == nil && state.sourceMetadata == nil && state.failure?.contains("current failure") == true)
        #expect(try await store.workflowText(ref) == "original preview")
        try await c.close(); try await store.close()
    }

    @Test func assetPreviewHostReusesSlotAndReloadsFullReferenceAndOwner() async throws {
        let (store, c, ref) = try await repairPreviewFixture()
        let state = WorkflowAssetPreviewState()
        let host = NSHostingView(rootView: AnyView(WorkflowAssetPreview(controller: c, reference: ref, state: state)))
        host.frame = CGRect(x: 0, y: 0, width: 440, height: 350)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close() }
        func settle(_ condition: () -> Bool) async throws {
            for _ in 0..<150 {
                host.layoutSubtreeIfNeeded()
                if condition() { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            Issue.record("Preview host did not settle")
        }
        try await settle { state.sourceMetadata != nil }
        #expect(state.data == Data("original preview".utf8) && state.failure == nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(state.sourceMetadata?.contains("repair-fixture") == true)
        // Keep version identical: a version-only task key would never reload.
        let missing = WorkflowAssetReference(projectID: ref.projectID, assetID: UUID(), version: ref.version, kind: ref.kind, sha256: ref.sha256)
        host.rootView = AnyView(WorkflowAssetPreview(controller: c, reference: missing, state: state))
        try await settle { state.failure != nil }
        #expect(state.data == nil && state.sourceMetadata == nil)
        let replacement = WorkflowController(services: c.services); await replacement.load()
        host.rootView = AnyView(WorkflowAssetPreview(controller: replacement, reference: ref, state: state))
        try await settle { state.identity == .init(controller: replacement, reference: ref) && state.sourceMetadata != nil }
        #expect(state.data == Data("original preview".utf8) && state.failure == nil)
        let (otherStore, otherController, _) = try await repairPreviewFixture()
        host.rootView = AnyView(WorkflowAssetPreview(controller: otherController, reference: ref, state: state))
        try await settle { state.identity == .init(controller: otherController, reference: ref) && state.failure != nil }
        #expect(state.data == nil && state.sourceMetadata == nil)
        host.rootView = AnyView(EmptyView())
        try await settle { state.identity == nil }
        host.rootView = AnyView(WorkflowAssetPreview(controller: c, reference: ref, state: state))
        try await settle { state.sourceMetadata != nil }
        #expect(state.data == Data("original preview".utf8) && state.failure == nil)
        #expect(try await store.workflowText(ref) == "original preview")
        host.rootView = AnyView(EmptyView())
        try await c.close(); replacement.deactivateAfterClose(); try await store.close()
        try await otherController.close(); try await otherStore.close()
    }
}

private actor CanvasSeriousImageEngine: InferenceEngine {
    private(set) var calls = 0
    var onSubmit: (@MainActor @Sendable () -> Void)?
    func configure(_ action: @escaping @MainActor @Sendable () -> Void) { onSubmit = action }
    func submit(_ request: InferenceRequest, backendID: String) async throws -> InferenceRun {
        calls += 1
        await onSubmit?()
        return InferenceRun(id: request.id, events: AsyncThrowingStream { $0.finish() }, cancel: {},
            outcome: { .failed(.inputIntegrityChanged("DHA UI serious")) })
    }
}

@MainActor private struct RecoveryButtonFixture: View {
    let controller: WorkflowController
    var body: some View {
        VStack {
            if let run = controller.runs.last {
                WorkflowRunRecoveryButton(controller: controller, run: run, readOnly: false)
            }
        }
        .padding()
        .accessibilityElement(children: .contain)
    }
}

extension WorkflowCanvasHostingTests {
    @Test(arguments: ["zh-Hans", "en"])
    func actualFailureRecoveryButtonSavesOnlyAndThenOffersExplicitRetry(locale: String) async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent("dha-recovery-button-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try await ProjectStore.create(at: root.appendingPathComponent("Recovery.dproject"), name: "Recovery fixture")
        let engine = CanvasSeriousImageEngine()
        let session = WorkbenchSession(engine: engine, backendID: "fixture.image",
            status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) }, shutdown: {}, cleanup: {},
            validateModel: { _ in }, imageCapability: .scalableKlein4B)
        let services = WorkflowServices(store: store, session: session) { _, identity in
            .init(identity: identity, reference: .init(directory: root, revision: "fixture"), backendID: "fixture.image",
                imageRecipe: .klein(capability: .scalableKlein4B))
        }
        let c = WorkflowController(services: services); await c.load()
        c.addBlankGraph(name: "Failure recovery"); c.addNode(operationID: "d.image.generate")
        let target = try #require(c.selectedNodeID)
        c.setParameter(nodeID: target, key: "modelID", value: .text("image:frozen"))
        c.setParameter(nodeID: target, key: "promptText", value: .text("fixture"))
        c.setParameter(nodeID: target, key: "count", value: .integer(1))
        await engine.configure { c.beforeHistorySave = { throw WorkflowIssue("DHA UI history write") } }
        await c.run(target: target, only: false)
        let run = try #require(c.runs.last)
        try #require(run.status == .saving && run.steps.last?.status == .failed)
        let application = NSApplication.shared
        let previousPolicy = application.activationPolicy()
        application.setActivationPolicy(.regular)
        defer { application.setActivationPolicy(previousPolicy) }
        var mounted = false
        let host = NSHostingView(rootView: VStack {
            Button("Hosting accessibility probe") {}
                .accessibilityIdentifier("dha-hosting-probe")
            RecoveryButtonFixture(controller: c)
        }
            .onAppear { mounted = true }
            .environment(\.dLanguageStore, UILanguageStore(preferredLanguages: [locale])))
        host.frame = CGRect(x: 0, y: 0, width: 420, height: 160)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        // Establish and verify this test process's window prerequisites before
        // interpreting an absent accessibility element as a product failure.
        window.makeKeyAndOrderFront(nil)
        application.activate(ignoringOtherApps: true)
        defer { window.close() }
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if mounted && window.isVisible && window.isKeyWindow { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(window.isVisible && window.isKeyWindow && host.window === window,
            "Recovery fixture requires a visible key window in the test process")
        try #require(mounted, "Recovery fixture SwiftUI view did not appear")
        func control(_ identifier: String) async throws -> any NSAccessibilityProtocol {
            for _ in 0..<100 {
                host.layoutSubtreeIfNeeded()
                var pending: [NSObject] = [host], visited = Set<ObjectIdentifier>()
                while let object = pending.popLast(), visited.count < 2_000 {
                    guard visited.insert(ObjectIdentifier(object)).inserted else { continue }
                    if let element = object as? any NSAccessibilityProtocol {
                        if element.accessibilityIdentifier() == identifier { return element }
                        pending.append(contentsOf: (element.accessibilityChildren() ?? []).compactMap { $0 as? NSObject })
                    }
                    if let view = object as? NSView { pending.append(contentsOf: view.subviews) }
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            HostingControlClick.diagnoseTree(in: host)
            throw WorkflowIssue("Recovery fixture accessibility element was not mounted: " + identifier)
        }
        _ = try await control("dha-hosting-probe")
        let recoveryID = "workflow-run-recovery-" + run.id.uuidString
        let savingButton = try await control(recoveryID)
        #expect(savingButton.accessibilityLabel() == (locale == "en" ? "Retry Saving Failure Record" : "重试保存失败记录"))
        c.beforeHistorySave = {}; await engine.configure {}
        #expect(HostingControlClick.send(to: savingButton, in: host))
        for _ in 0..<200 {
            if c.runs.last?.status == .failed && !c.isRunning { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(c.runs.last?.id == run.id && c.runs.last?.status == .failed && !c.hasPendingSaves)
        #expect(await engine.calls == 1)
        #expect(c.errorMessage?.contains("DHA UI serious") == true && c.errorMessage?.contains("DHA UI history write") == true)
        #expect(c.progressMessage.contains("失败记录已保存") && !c.progressMessage.contains("计算结果仍保留"))
        // This is the same production button after recovery, with an explicit
        // computation action. Test-process events do not certify foreground UI.
        host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30))
        let retryButton = try await control(recoveryID)
        #expect(retryButton.accessibilityLabel() == (locale == "en" ? "Retry Computation" : "重试计算"))
        #expect(HostingControlClick.send(to: retryButton, in: host))
        for _ in 0..<200 {
            if await engine.calls == 2, !c.isRunning { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await engine.calls == 2 && c.runs.last?.status == .failed)
        #expect(c.errorMessage?.contains("DHA UI serious") == true)
        try await c.close(); try await store.close()
    }
}
