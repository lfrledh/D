import AppKit
import DInference
import DWorkbench
import Foundation
import SwiftUI
import Testing
@testable import UI

private actor LocalizationNoInferenceEngine: InferenceEngine {
    private(set) var calls = 0

    func submit(_ request: InferenceRequest, backendID: String) async throws -> InferenceRun {
        calls += 1
        throw WorkflowIssue("Localization hosting must not execute inference")
    }
}

@Suite(.serialized) @MainActor
struct WorkflowLocalizationTests {
    @Test
    func missingEnvironmentUsesOriginalChineseFallbacks() {
        let definition = WorkflowOperationDefinition(
            id: "d.fixture.operation",
            title: "原始标题",
            detail: "原始说明",
            inputs: [.init("input", "原始输入", kinds: [.text])],
            outputs: [],
            fields: [.init("amount", "原始数量", .integer, .integer(1))]
        )
        #expect(WorkflowCanvasPresentation.operationTitle(definition, language: nil) == "原始标题")
        #expect(WorkflowCanvasPresentation.operationDetail(definition, language: nil) == "原始说明")
        #expect(WorkflowCanvasPresentation.fieldTitle(
            operationID: definition.id, field: definition.fields[0], language: nil
        ) == "原始数量")
        #expect(WorkflowCanvasPresentation.portTitle(
            operationID: definition.id, port: definition.inputs[0], input: true, language: nil
        ) == "原始输入")
    }

    @Test
    func knownDefinitionProjectsDisplayFromStableIDsWithoutChangingData() throws {
        let store = UILanguageStore(preferredLanguages: ["en"])
        try store.select("en")
        let definition = WorkflowOperationDefinition(
            id: "d.image.resize",
            title: "不会按中文反查",
            detail: "也不会按说明反查",
            inputs: [.init("input", "原始输入", kinds: [.image])],
            outputs: [.init("output", "原始输出", kinds: [.image])],
            fields: [.init("width", "原始宽度", .integer, .integer(512))]
        )
        let node = WorkflowNode(operationID: definition.id, title: "用户节点标题",
                                parameters: ["width": .integer(777)])

        #expect(WorkflowCanvasPresentation.operationTitle(definition, language: store) == "Resize Image")
        #expect(WorkflowCanvasPresentation.operationDetail(definition, language: store) == "Resize using an explicit mode.")
        #expect(WorkflowCanvasPresentation.fieldTitle(
            operationID: definition.id, field: definition.fields[0], language: store
        ) == "Width")
        #expect(WorkflowCanvasPresentation.portTitle(
            operationID: definition.id, port: definition.inputs[0], input: true, language: store
        ) == "Image")
        #expect(node.operationID == "d.image.resize")
        #expect(node.title == "用户节点标题")
        #expect(node.parameters["width"] == .integer(777))
    }

    @Test
    func kindRequirementAndStatusAreDisplayOnly() throws {
        let store = UILanguageStore(preferredLanguages: ["en"])
        try store.select("en")
        let port = WorkflowPortDefinition("reference", "参考", kinds: [.text, .image], required: false)
        #expect(WorkflowCanvasPresentation.portDetail(port, language: store) == "Text/Image · Optional")
        #expect(WorkflowCanvasPresentation.kind(.images, language: store) == "Image Collection")
        #expect(WorkflowCanvasPresentation.statusTitle(.cancelling, language: store) == "Cancelling")
        #expect(port.id == "reference")
        #expect(port.kinds == [.text, .image])
        #expect(!port.required)
    }

    @Test
    func switchingLanguageDoesNotInterpretPlanOrRawValues() throws {
        let store = UILanguageStore(preferredLanguages: ["zh-Hans"])
        let opaque = [
            "执行：节点 A → do not translate",
            "{\"reuse\":true,\"path\":\"/tmp/原样\"}",
            "等待确认\nkeep newline",
        ]
        let modelID = "model.identity/%-原样"
        let choice = "fill"

        #expect(WorkflowCanvasPresentation.planLines(opaque) == opaque)
        try store.select("en")
        #expect(WorkflowCanvasPresentation.planLines(opaque) == opaque)
        #expect(modelID == "model.identity/%-原样")
        #expect(choice == "fill")
    }

    @Test
    func languageSettingsAndEnvironmentAPIStayAvailable() {
        let store = UILanguageStore(preferredLanguages: ["en"])
        let settingsType: LanguageSettingsView.Type = LanguageSettingsView.self
        let canvasType: WorkflowCanvasView.Type = WorkflowCanvasView.self
        let environment = EnvironmentValues()
        #expect(String(describing: settingsType) == "LanguageSettingsView")
        #expect(String(describing: canvasType) == "WorkflowCanvasView")
        #expect(environment.dLanguageStore == nil)
        #expect(store.selection == UILanguageStore.systemIdentifier)
    }

    @Test
    func hostedCanvasSwitchPreservesDraftSelectionParametersAndControllerIdentity() async throws {
        let approvedRoot = try #require(ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"])
        let root = URL(fileURLWithPath: approvedRoot, isDirectory: true)
            .appendingPathComponent("workflow-localization-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let projectStore = try await ProjectStore.create(
            at: root.appendingPathComponent("localization.dproject"),
            name: "Localization hosting"
        )
        let engine = LocalizationNoInferenceEngine()
        let runtime = WorkbenchSession(
            engine: engine,
            backendID: "never",
            status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) },
            shutdown: {},
            cleanup: {},
            validateModel: { _ in }
        )
        let services = WorkflowServices(
            store: projectStore,
            session: runtime,
            resolveText: { throw WorkflowIssue("Localization hosting must not resolve a model") },
            resolveImage: { throw WorkflowIssue("Localization hosting must not resolve a model") }
        )
        let controller = WorkflowController(services: services)
        await controller.load()
        controller.addExample("text")
        let input = try #require(controller.graph?.nodes.first { $0.operationID == "d.text.input" })
        let draft = "待保存草稿 👩🏽‍🎨 e\u{301} 100%"
        controller.setParameter(nodeID: input.id, key: "text", value: .text(draft))
        controller.selectedNodeID = input.id

        let language = UILanguageStore(preferredLanguages: ["zh-Hans"])
        try language.select("zh-Hans")
        var commands = 0
        let view = WorkflowCanvasView(
            controller: controller,
            onTextModel: { commands += 1 },
            onImageModel: { commands += 1 },
            onImport: { _ in commands += 1 },
            onDestination: { commands += 1 },
            onPublishText: { commands += 1 },
            onReturnText: { _ in commands += 1 }
        ).environment(\.dLanguageStore, language)
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(x: 0, y: 0, width: 1_420, height: 900)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }

        func descendants(_ root: NSView) -> [NSView] {
            root.subviews.flatMap { [$0] + descendants($0) }
        }
        func renderedStrings(_ root: NSView) -> Set<String> {
            var values: Set<String> = []
            var pending: [NSObject] = [root]
            var visited: Set<ObjectIdentifier> = []
            while let object = pending.popLast(), visited.count < 2_000 {
                guard visited.insert(ObjectIdentifier(object)).inserted else { continue }
                let accessibility: (label: String?, value: Any?, children: [Any])?
                if let view = object as? NSView {
                    accessibility = (view.accessibilityLabel(), view.accessibilityValue(),
                                     view.accessibilityChildren() ?? [])
                } else if let element = object as? NSAccessibilityElement {
                    accessibility = (element.accessibilityLabel(), element.accessibilityValue(),
                                     element.accessibilityChildren() ?? [])
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

        var editor: NSTextView?
        for _ in 0..<40 {
            host.layoutSubtreeIfNeeded()
            editor = descendants(host).compactMap { $0 as? NSTextView }.first { $0.string == draft }
            if editor != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let mountedEditor = try #require(editor)
        let selectedRange = NSRange(location: 0, length: 2)
        mountedEditor.setSelectedRange(selectedRange)
        #expect(mountedEditor.selectedRange() == selectedRange)

        let graphsBefore = controller.graphs
        let graphIDBefore = controller.selectedGraphID
        let nodeIDBefore = controller.selectedNodeID
        let runCountBefore = controller.runs.count
        try language.select("en")

        var chrome: Set<String> = []
        for _ in 0..<40 {
            host.layoutSubtreeIfNeeded()
            chrome = renderedStrings(host)
            if chrome.contains(where: { $0.contains("Save") || $0.contains("Operations") }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let currentEditor = try #require(
            descendants(host).compactMap { $0 as? NSTextView }.first { $0.string == draft }
        )
        #expect(currentEditor === mountedEditor)
        #expect(currentEditor.string == draft)
        #expect(currentEditor.selectedRange() == selectedRange)
        #expect(controller.graphs == graphsBefore)
        #expect(controller.selectedGraphID == graphIDBefore)
        #expect(controller.selectedNodeID == nodeIDBefore)
        #expect(controller.graph?.nodes.first { $0.id == input.id }?.parameters["text"] == .text(draft))
        #expect(controller.runs.count == runCountBefore)
        #expect(chrome.contains(where: { $0.contains("Save") || $0.contains("Operations") }))
        #expect(commands == 0)
        #expect(await engine.calls == 0)

        try await controller.close()
        try await projectStore.close()
    }
}
