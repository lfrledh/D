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
    @Test(arguments: ["zh-Hans", "en"])
    func fixedInterfaceSchemaKeepsUserNamesAndUsesLocalizedTypes(locale: String) throws {
        let language = UILanguageStore(preferredLanguages: [locale]); try language.select(locale)
        let field = WorkflowRecordField("用户字段 / User field", .asset(.image), required: false)
        let schema = WorkflowDataSchema.record([field])
        let rendered = WorkflowDatumSnapshotText.schema(schema, language: language)
        #expect(rendered.contains(field.name))
        #expect(rendered.contains(workflowText(language, "workflow.kind.image")))
        #expect(rendered.contains(workflowText(language, "workflow.language.form.optional")))
        #expect(schema == .record([field]))
        #expect(!rendered.contains("WorkflowDataSchema") && !rendered.contains("DWorkbench."))
    }

    @Test(arguments: ["zh-Hans", "en"])
    func failureRecordFeedbackTranslatesWithoutChangingDiagnostics(locale: String) throws {
        let language = UILanguageStore(preferredLanguages: [locale]); try language.select(locale)
        let pending = "计算已失败，失败记录尚未保存；请重试保存记录。"
        let saved = "失败记录已保存；流程仍失败。需要重新计算时，请明确重试计算。"
        #expect(workflowRecoveryProgressText(pending, language: language) == (locale == "en"
            ? "The run failed, and its record has not been saved. Retry saving first." : "运行失败，记录尚未保存。请先重试保存。"))
        #expect(workflowRecoveryProgressText(saved, language: language) == (locale == "en"
            ? "The failure record has been saved. Run again if you need to retry the computation."
            : "失败记录已保存。需要重新计算时，请重新运行。"))
        let primary = "DHA integrity / 私有路径/a%20b {runID}\n原始严重诊断"
        let secondary = "write failed: /原样/🙂 {stepID}\nsecondary details"
        let raw = primary + "\n失败记录保存错误：" + secondary
        let run = failureFeedbackRun(primary: primary, secondary: secondary)
        #expect(workflowRecoveryErrorText(raw, runs: [run], language: language) == primary + "\n"
            + (locale == "en" ? "Failure record save error: " : "失败记录保存错误：") + secondary)
        #expect(workflowRecoveryErrorText(primary, runs: [run], language: language) == primary)
        #expect(workflowRecoveryProgressText(primary, language: language) == primary)
        #expect(workflowRecoveryProgressText(pending, language: nil) == "运行失败，记录尚未保存。请先重试保存。")
        #expect(workflowRecoveryErrorText(raw, runs: [run], language: nil) == raw)
        #expect(raw == primary + "\n失败记录保存错误：" + secondary)
    }

    @Test(arguments: ["zh-Hans", "en"])
    func failureRecordTranslationRequiresAnUnambiguousRecordedBoundary(locale: String) throws {
        let language = UILanguageStore(preferredLanguages: [locale]); try language.select(locale)
        let primary = "DHA original\n失败记录保存错误：inside original e\u{301}"
        let secondary = "\u{301}save detail\n失败记录保存错误：inside secondary 🙂"
        let raw = primary + "\n失败记录保存错误：" + secondary
        let run = failureFeedbackRun(primary: primary, secondary: secondary)
        let expected = primary + "\n" + (locale == "en" ? "Failure record save error: " : "失败记录保存错误：") + secondary
        #expect(Array(workflowRecoveryErrorText(raw, runs: [run], language: language).utf8) == Array(expected.utf8))
        #expect(workflowRecoveryErrorText(raw, runs: [], language: language) == raw)
        #expect(workflowRecoveryErrorText(raw + "!", runs: [run], language: language) == raw + "!")
        var mismatched = run; mismatched.planCheckpoint?.runID = UUID()
        #expect(workflowRecoveryErrorText(raw, runs: [mismatched], language: language) == raw)
        mismatched = run; mismatched.planCheckpoint?.records[0].address.runID = UUID()
        #expect(workflowRecoveryErrorText(raw, runs: [mismatched], language: language) == raw)
        mismatched = run; mismatched.status = .completed
        #expect(workflowRecoveryErrorText(raw, runs: [mismatched], language: language) == raw)
        mismatched = run; mismatched.planCheckpoint?.error = raw.precomposedStringWithCanonicalMapping
        #expect(workflowRecoveryErrorText(raw, runs: [mismatched], language: language) == raw)
        let alternate = failureFeedbackRun(primary: "DHA original", secondary: "inside original e\u{301}\n失败记录保存错误：" + secondary)
        #expect(workflowRecoveryErrorText(raw, runs: [run, alternate], language: language) == raw)
    }

    private func failureFeedbackRun(primary: String, secondary: String) -> WorkflowRun {
        let node = WorkflowNode(operationID: "d.image.generate", title: "Failure fixture")
        let graph = WorkflowGraph(nodes: [node])
        var step = WorkflowStepRun(node: node, signature: "fixture")
        step.status = .failed; step.error = primary
        var run = WorkflowRun(graph: graph, targetNodeID: node.id, steps: [step], status: .saving)
        let plan = WorkflowPlan(graphID: graph.id, graphRevision: graph.revision, steps: [.init(node: node, inputs: [])])
        run.planCheckpoint = .init(runID: run.id, plan: plan,
            records: [.init(address: .init(runID: run.id, path: [.node(node.id)]), step: step)], state: .saving)
        run.planCheckpoint?.error = primary + "\n失败记录保存错误：" + secondary
        return run
    }

    @Test func loadingChoicesTranslateWithoutChangingStoredValues() throws {
        for locale in ["en", "zh-Hans"] {
            let store = UILanguageStore(preferredLanguages: [locale]); try store.select(locale)
            for value in ["resident", "staged", "ssdLayered"] {
                let expected = store.text("workflow.loading." + value, fallback: "__missing__")
                #expect(expected != "__missing__" && expected != value)
                #expect(WorkflowCanvasPresentation.choiceTitle(fieldID: "loadingStrategy", value: value, language: store) == expected)
                #expect(WorkflowCanvasPresentation.choiceTitle(fieldID: "userChoice", value: value, language: store) == value)
            }
            #expect(WorkflowCanvasPresentation.choiceTitle(fieldID: "loadingStrategy", value: "future", language: store) == "future")
        }
    }
    @Test func scopePresentationFreezesGraphIdentityAtOpen() {
        var graph = WorkflowGraph(name: "scope"), node = WorkflowNode(operationID: "d.value.input", title: "input")
        graph.nodes = [node]
        let request = WorkflowScopePresentation(graph: graph, nodeID: node.id)
        let originalRevision = graph.revision
        graph.revision = UUID(); node.id = UUID(); graph.nodes = [node]
        #expect(request.graphID == graph.id && request.revision == originalRevision)
        #expect(request.nodeID != node.id && request.revision != graph.revision)
    }
    @Test func registeredOperationDisplayKeysHaveBothBuiltInTranslations() throws {
        var inventory: [String: String] = [:]
        for definition in WorkflowRegistry.standard.definitions {
            let prefix = "workflow.operation." + definition.id
            inventory[prefix + ".title"] = definition.title
            inventory[prefix + ".detail"] = definition.detail
            for field in definition.fields { inventory[prefix + ".field." + field.id] = field.title }
            for port in definition.inputs { inventory[prefix + ".input." + port.id] = port.title }
            for port in definition.outputs { inventory[prefix + ".output." + port.id] = port.title }
        }
        for locale in ["en", "zh-Hans"] {
            let store = UILanguageStore(preferredLanguages: [locale]); try store.select(locale)
            let missing = inventory.keys.filter { store.text($0, fallback: "__missing__") == "__missing__" }.sorted()
            #expect(missing.isEmpty, Comment(rawValue: "\(locale) missing operation display keys: \(missing.joined(separator: ", "))"))
        }
    }


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
        #expect(WorkflowCanvasPresentation.statusTitle(.cancelling, language: store) == "Stopping")
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
        let app = NSApplication.shared, activationPolicy = NSApplication.shared.activationPolicy()
        app.setActivationPolicy(.regular)
        defer { app.setActivationPolicy(activationPolicy) }
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
        ).startingPanels(WorkflowWorkspacePanels(preparation: .configuration)).environment(\.dLanguageStore, language)
        var positivePresses = 0
        let host = NSHostingView(rootView: VStack {
            Button("Hosting action probe") { positivePresses += 1 }
                .accessibilityIdentifier("hosting-action-probe")
            view
        })
        host.frame = CGRect(x: 0, y: 0, width: 1_420, height: 900)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        window.makeKeyAndOrderFront(nil); app.activate()
        for _ in 0..<40 {
            host.layoutSubtreeIfNeeded()
            if window.isVisible && window.isKeyWindow && host.window === window { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(window.isVisible && window.isKeyWindow && host.window === window,
                     "Visible localization host must be ready before the positive control probe")

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
                if let element = object as? any NSAccessibilityProtocol {
                    accessibility = (element.accessibilityLabel() ?? element.accessibilityTitle(), element.accessibilityValue(),
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
        func pressControl(_ root: NSView, identifier: String) -> Bool {
            var pending: [NSObject] = [root]
            var visited: Set<ObjectIdentifier> = []
            while let object = pending.popLast(), visited.count < 2_000 {
                guard visited.insert(ObjectIdentifier(object)).inserted else { continue }
                if let element = object as? any NSAccessibilityProtocol,
                   element.accessibilityIdentifier() == identifier {
                    return HostingControlClick.send(to: element, in: root)
                }
                if let element = object as? any NSAccessibilityProtocol {
                    pending.append(contentsOf: (element.accessibilityChildren() ?? []).compactMap { $0 as? NSObject })
                }
                if let view = object as? NSView { pending.append(contentsOf: view.subviews) }
            }
            print("D_HOSTING_CONTROL", identifier, "lookup-miss")
            return false
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

        let connection = try #require(controller.graph?.connections.first)
        HostingControlClick.diagnoseTree(in: host)
        let positiveResult = pressControl(host, identifier: "hosting-action-probe")
        print("HOSTING_POSITIVE result=\(positiveResult) count=\(positivePresses)")
        #expect(positiveResult && positivePresses == 1, "The same host must execute a plain SwiftUI Button")
        let disconnectID = "canvas-disconnect-" + connection.id.uuidString
        #expect(!HostingControlClick.contains(disconnectID, in: host))
        let edgePressed = pressControl(host, identifier: "workflow-connection-" + connection.id.uuidString)
        #expect(edgePressed)
        for _ in 0..<40 {
            host.layoutSubtreeIfNeeded()
            if HostingControlClick.contains(disconnectID, in: host) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(HostingControlClick.contains(disconnectID, in: host))
        #expect(HostingControlClick.contains("canvas-connection-inspector", in: host))
        host.layoutSubtreeIfNeeded()
        let editorAfterEdge = try #require(
            descendants(host).compactMap { $0 as? NSTextView }.first { $0.string == draft }
        )
        #expect(editorAfterEdge === mountedEditor)
        #expect(editorAfterEdge.selectedRange() == selectedRange)
        #expect(controller.selectedNodeID == input.id)

        // Native Menu content lives outside this offscreen NSHostingView's accessibility tree.
        // Check the mounted trigger and the exact localized title supplied to that menu.
        var chineseChrome: Set<String> = []
        for _ in 0..<40 {
            host.layoutSubtreeIfNeeded()
            chineseChrome = renderedStrings(host)
            if chineseChrome.contains("更多") { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(chineseChrome.contains("更多"))
        #expect(workflowText(language, "workflow.toolbar.addExample", fallback: "添加样例") == "添加样例")

        let graphsBefore = controller.graphs
        let graphIDBefore = controller.selectedGraphID
        let nodeIDBefore = controller.selectedNodeID
        let runCountBefore = controller.runs.count
        try language.select("en")
        host.layoutSubtreeIfNeeded()

        var chrome: Set<String> = []
        for _ in 0..<40 {
            host.layoutSubtreeIfNeeded()
            chrome = renderedStrings(host)
            if chrome.contains("More") { break }
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
        print("BOUNDARY_RENDERED_CHROME=\(chrome.sorted())")
        #expect(chrome.contains("More"))
        #expect(workflowText(language, "workflow.toolbar.addExample", fallback: "添加样例") == "Add Example")
        #expect(commands == 0)
        #expect(await engine.calls == 0)

        try await controller.close()
        try await projectStore.close()
    }
}

@Suite(.serialized) @MainActor struct WorkflowRunCopyB4Tests {
    @Test func preciseSubmissionKeysAndSystemTitlesDoNotRewriteHistory() throws {
        let zh = UILanguageStore(preferredLanguages: ["zh-Hans"]), en = UILanguageStore(preferredLanguages: ["en"])
        try zh.select("zh-Hans"); try en.select("en")
        for (kind, expected) in [(WorkflowHumanTaskKind.approve, "提交判断"), (.editText, "提交内容"), (.editMusic, "提交内容"), (.singleChoice, "提交选择"), (.multipleChoice, "提交选择")] {
            #expect(workflowText(zh, WorkflowHumanSubmission.key(kind)) == expected)
            #expect(workflowText(en, WorkflowHumanSubmission.key(kind) + ".help").contains("separately"))
        }
        let legacy = WorkflowBatchStage(name: "继续所选", repetitions: 1, attempts: [])
        var system = legacy; system.systemTitle = .continuation
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let before = try encoder.encode(system)
        #expect(WorkflowHumanPresentation.stage(legacy, language: en) == "继续所选")
        #expect(WorkflowHumanPresentation.stage(system, language: zh) == "后续批次")
        #expect(WorkflowHumanPresentation.stage(system, language: en) == "Continuation batch")
        #expect(try encoder.encode(system) == before)
        let decoded = try JSONDecoder().decode(WorkflowBatchStage.self, from: JSONEncoder().encode(legacy))
        #expect(decoded.systemTitle == nil && decoded.name == legacy.name)
    }

    @Test func batchReviewCountUsesCurrentExactRunsWithoutRewritingLedger() throws {
        let node = try #require(WorkflowRegistry.standard.operation("d.control.human")).definition.makeNode()
        let graph = WorkflowGraph(nodes: [node])
        var runs = (0..<16).map { _ in WorkflowRun(graph: graph, targetNodeID: node.id,
            steps: [.init(node: node, signature: "frozen", status: .waiting)], status: .waiting) }
        let attempts = runs.enumerated().map { index, run in
            var attempt = WorkflowBatchAttempt(ordinal: index + 1, runID: run.id); attempt.state = .waiting; return attempt
        }
        let stage = WorkflowBatchStage(name: "Existing batch", repetitions: 16, attempts: attempts)
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let frozenStage = try encoder.encode(stage)
        func count() -> Int { WorkflowBatchPanel.pendingReviewCount(stage, runsByID: Dictionary(uniqueKeysWithValues: runs.map { ($0.id, $0) })) }
        #expect(count() == 16)
        runs[14].status = .cancelled // Even stale waiting records cannot reopen a terminal run.
        runs[15].steps[0].status = .completed // Decision saved; explicit continuation is separate.
        #expect(count() == 14)
        #expect(WorkflowBatchPanel.pendingReviews(in: runs[14], attempt: attempts[14]).isEmpty)
        #expect(WorkflowBatchPanel.pendingReviews(in: runs[15], attempt: attempts[15]).isEmpty)
        runs[0].status = .saving
        #expect(count() == 13)
        runs.remove(at: 1)
        #expect(count() == 12) // No fallback to another run with the same node/name.
        let waitingRun = try #require(runs.first { $0.id == attempts[2].runID })
        var blockedStage = stage; blockedStage.attempts[2].state = .savingBlocked
        #expect(waitingRun.status == .waiting)
        #expect(WorkflowBatchPanel.pendingReviews(in: waitingRun, attempt: blockedStage.attempts[2]).isEmpty)
        #expect(WorkflowBatchPanel.pendingReviewCount(blockedStage, runsByID: Dictionary(uniqueKeysWithValues: runs.map { ($0.id, $0) })) == 11)
        #expect(WorkflowBatchPanel.pendingReviews(in: waitingRun, attempt: attempts[3]).isEmpty)
        #expect(try encoder.encode(stage) == frozenStage)
    }

    @Test func waitingPausedAndSavedHumanDecisionAreDifferent() throws {
        let en = UILanguageStore(preferredLanguages: ["en"]); try en.select("en")
        let graph = WorkflowGraph(), plan = WorkflowPlan(graphID: graph.id, graphRevision: graph.revision, steps: [])
        var run = WorkflowRun(graph: graph, targetNodeID: UUID(), status: .waiting)
        #expect(WorkflowHumanPresentation.runStatus(run, language: en) == "Waiting")
        run.planCheckpoint = .init(plan: plan); run.planCheckpoint?.state = .paused
        #expect(WorkflowHumanPresentation.runStatus(run, language: en) == "Paused")
        run.planCheckpoint?.state = .waiting
        #expect(WorkflowHumanPresentation.runStatus(run, language: en) == "Ready to continue")
        #expect(WorkflowOutputComparisonText.title(.changed, language: en) == "Settings or inputs have changed")
        #expect(WorkflowOutputComparisonText.title(.missingUpstream, language: en) == "No matching upstream output yet")
        #expect(WorkflowOutputComparisonText.title(.unavailable("raw diagnostic"), language: en).contains("Unable to compare"))
    }
}
