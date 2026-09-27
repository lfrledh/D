import AppKit
import DInference
import DWorkbench
import Foundation
import SwiftUI
import Testing
@testable import UI

private actor MediaPresetNoInferenceEngine: InferenceEngine {
    private(set) var calls = 0

    func submit(_ request: InferenceRequest, backendID: String) async throws -> InferenceRun {
        calls += 1
        throw WorkflowIssue("Media preset hosting must not execute inference.")
    }
}

@Suite("Workflow media preset UI", .serialized) @MainActor
struct WorkflowMediaPresetTests {
    @Test func actionSnapshotRejectsGraphSwitchRevisionAndNodeEdits() throws {
        let definition = try #require(WorkflowRegistry.standard.operation("d.video.generate")?.definition)
        var node = definition.makeNode()
        node.parameters["promptText"] = .text("original")
        let graph = WorkflowGraph(nodes: [node])
        let action = try #require(WorkflowVideoPresetAction(node: node, graph: graph))

        let replacement = try #require(action.replacement(
            in: graph, preset: WorkflowVideoPresets.connectivity
        ))
        #expect(replacement.parameters["steps"] == .integer(4))
        #expect(replacement.parameters["promptText"] == .text("original"))

        var edited = graph
        edited.nodes[0].parameters["promptText"] = .text("newer edit")
        #expect(action.replacement(in: edited, preset: WorkflowVideoPresets.official480p) == nil)

        var revised = graph
        revised.revision = UUID()
        #expect(action.replacement(in: revised, preset: WorkflowVideoPresets.official480p) == nil)

        var switched = graph
        switched.id = UUID()
        #expect(action.replacement(in: switched, preset: WorkflowVideoPresets.official480p) == nil)
    }

    @Test func actualCanvasHostsPresetAndMusicCapabilityPresentationWithoutRunning() async throws {
        let root = URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory(),
            isDirectory: true
        ).appendingPathComponent("workflow-media-preset-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try await ProjectStore.create(
            at: root.appendingPathComponent("Media.dproject"), name: "Media preset hosting"
        )
        let engine = MediaPresetNoInferenceEngine()
        let runtime = WorkbenchSession(
            engine: engine,
            backendID: "never",
            status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) },
            shutdown: {},
            cleanup: {},
            validateModel: { _ in }
        )
        let services = WorkflowServices(
            store: store,
            session: runtime,
            resolveText: { throw WorkflowIssue("Media preset hosting must not resolve text models.") },
            resolveImage: { throw WorkflowIssue("Media preset hosting must not resolve image models.") }
        )
        let controller = WorkflowController(services: services)
        await controller.load()
        controller.addLanguageExample(.multimodal)
        let video = try #require(controller.graph?.nodes.first { $0.operationID == "d.video.generate" })
        controller.selectedNodeID = video.id
        let originalGraphs = controller.graphs
        let action = try #require(WorkflowVideoPresetAction(
            node: video, graph: try #require(controller.graph)
        ))
        let connectivity = try #require(action.replacement(
            in: try #require(controller.graph), preset: WorkflowVideoPresets.connectivity
        ))
        controller.updateNode(connectivity, in: action.graphID)
        #expect(controller.graph?.nodes.first { $0.id == video.id }?.parameters["steps"] == .integer(4))
        #expect(controller.runs.isEmpty)
        controller.undo()
        #expect(controller.graphs == originalGraphs)
        let before = controller.graphs

        let language = UILanguageStore(preferredLanguages: ["en"])
        try language.select("en")
        var callbacks = 0
        let view = WorkflowCanvasView(
            controller: controller,
            onTextModel: { callbacks += 1 },
            onImageModel: { callbacks += 1 },
            onImport: { _ in callbacks += 1 },
            onDestination: { callbacks += 1 },
            onPublishText: { callbacks += 1 },
            onReturnText: { _ in callbacks += 1 },
            onAdditionalModel: { _ in callbacks += 1 }
        ).environment(\.dLanguageStore, language)
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(x: 0, y: 0, width: 1_420, height: 1_000)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }

        var strings: Set<String> = []
        for _ in 0..<40 {
            host.layoutSubtreeIfNeeded()
            strings = renderedStrings(host)
            if strings.contains("Connectivity check") && strings.contains("Full short preview") &&
                strings.contains("Official 480p starting point") { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(strings.contains("Connectivity check"))
        #expect(strings.contains("Full short preview"))
        #expect(strings.contains("Official 480p starting point"))
        #expect(controller.graphs == before)
        #expect(controller.runs.isEmpty && callbacks == 0)
        #expect(await engine.calls == 0)

        let music = try #require(controller.graph?.nodes.first { $0.operationID == "d.music.generate" })
        controller.selectedNodeID = music.id
        for _ in 0..<40 {
            host.layoutSubtreeIfNeeded()
            strings = renderedStrings(host)
            if strings.contains("MRT2 fixed capabilities and limits") { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(strings.contains("MRT2 fixed capabilities and limits"))
        #expect(controller.graphs == before)
        #expect(controller.runs.isEmpty && callbacks == 0)
        #expect(await engine.calls == 0)

        try await controller.close()
        try await store.close()
    }

    private func renderedStrings(_ root: NSView) -> Set<String> {
        var values: Set<String> = []
        var pending: [NSObject] = [root]
        var visited: Set<ObjectIdentifier> = []
        while let object = pending.popLast(), visited.count < 2_000 {
            guard visited.insert(ObjectIdentifier(object)).inserted else { continue }
            let accessibility: (label: String?, value: Any?, children: [Any])?
            if let element = object as? any NSAccessibilityProtocol {
                accessibility = (
                    element.accessibilityLabel() ?? element.accessibilityTitle(),
                    element.accessibilityValue(),
                    element.accessibilityChildren() ?? []
                )
            } else {
                accessibility = nil
            }
            if let label = accessibility?.label, !label.isEmpty { values.insert(label) }
            if let value = accessibility?.value as? String, !value.isEmpty { values.insert(value) }
            if let button = object as? NSButton, !button.title.isEmpty { values.insert(button.title) }
            if let field = object as? NSTextField, !field.stringValue.isEmpty { values.insert(field.stringValue) }
            pending.append(contentsOf: (accessibility?.children ?? []).compactMap { $0 as? NSObject })
            if let view = object as? NSView { pending.append(contentsOf: view.subviews) }
        }
        return values
    }
}
