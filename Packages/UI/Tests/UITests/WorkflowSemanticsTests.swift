import AppKit
import DWorkbench
import Foundation
import SwiftUI
import Testing
@testable import UI

@Suite(.serialized) @MainActor struct WorkflowSemanticsTests {
    @Test func fullOutputIdentitySurvivesSameNameAndCollidingUUIDPrefixes() throws {
        let a = WorkflowNode(operationID: "d.text.input", title: "Same"), b = WorkflowNode(operationID: "d.text.input", title: "Same")
        let graph = WorkflowGraph(nodes: [a, b])
        let first = WorkflowStepRun(id: UUID(uuidString: "12345678-0000-0000-0000-000000000001")!, node: a, signature: "a", outputs: ["text": .data(.text("first"))])
        let second = WorkflowStepRun(id: UUID(uuidString: "12345678-0000-0000-0000-000000000002")!, node: b, signature: "b", outputs: ["text": .data(.text("second"))])
        let run = WorkflowRun(graph: graph, targetNodeID: b.id, steps: [first, second])
        let outputs = WorkflowHumanPresentation.outputs(run)
        #expect(outputs.count == 2 && Set(outputs.map(\.id)).count == 2)
        #expect(Dictionary(uniqueKeysWithValues: outputs.map { ($0.storageKey, $0.value) }).count == 2)
        #expect(outputs.map(\.value) == [.data(.text("first")), .data(.text("second"))])
        #expect(Set(outputs.map { $0.id.address.runID }) == [run.id])
        #expect(WorkflowHumanPresentation.name(a, in: graph.nodes) != WorkflowHumanPresentation.name(b, in: graph.nodes))
        #expect(WorkflowHumanPresentation.name(a, in: graph.nodes.reversed()) == WorkflowHumanPresentation.name(a, in: graph.nodes))
    }

    @Test(arguments: ["zh-Hans", "en"])
    func sameSecondRunsDisambiguateAndFrozenNamesStayFrozen(languageID: String) throws {
        let language = UILanguageStore(preferredLanguages: [languageID]); try language.select(languageID)
        let node = WorkflowNode(operationID: "d.text.input", title: "Frozen")
        var first = WorkflowRun(graph: WorkflowGraph(name: "Review", nodes: [node]), targetNodeID: node.id, status: .completed)
        first.createdAt = Date(timeIntervalSince1970: 100_000.1)
        var second = WorkflowRun(graph: first.graph, targetNodeID: node.id, status: .completed)
        second.createdAt = Date(timeIntervalSince1970: 100_000.2)
        let runs = [first, second]
        let title = WorkflowHumanPresentation.run(first, in: runs, language: language)
        #expect(title != WorkflowHumanPresentation.run(second, in: runs, language: language))
        #expect(title == WorkflowHumanPresentation.run(first, in: runs.reversed(), language: language))
        #expect(!title.contains(first.id.uuidString) && !title.contains(String(first.id.uuidString.prefix(6))))
        var current = first.graph; current.nodes[0].title = "Changed current"
        #expect(first.graph.nodes[0].title == "Frozen" && current.nodes[0].id == node.id)
    }

    @Test(arguments: [true, false])
    func batchOrderComesOnlyFromFrozenParentInput(recorded: Bool) {
        let runID = UUID(), parent = WorkflowNode(operationID: "d.control.map", title: "Batch")
        let child = WorkflowNode(operationID: "d.text.input", title: "Child")
        let parentAddress = WorkflowExecutionAddress(runID: runID, path: [.node(parent.id)])
        let input: [String: WorkflowValue] = recorded ? ["input": .data(.list(element: .text, items: [.init(id: "B", value: .text("b")), .init(id: "A", value: .text("a"))]))] : [:]
        let parentCall = WorkflowPlanCallRecord(address: parentAddress, step: .init(node: parent, signature: "parent", inputs: input))
        let call = WorkflowPlanCallRecord(address: parentAddress.appending(.item("A")).appending(.node(child.id)), step: .init(node: child, signature: "child"))
        let title = WorkflowHumanPresentation.call(call, in: [call, parentCall], language: nil)
        #expect(title.contains(recorded ? "批次项 2" : "顺序未记录"))
        #expect(!title.contains(call.id.uuidString))
        #expect(title == WorkflowHumanPresentation.call(call, in: [parentCall, call], language: nil))
    }

    @Test(arguments: [WorkflowStepStatus.waiting, .saving, .failed])
    func pendingDecisionNeverMasksSavingRecovery(status: WorkflowStepStatus) {
        let node = WorkflowNode(operationID: "d.review.text", title: "Review")
        let step = WorkflowStepRun(node: node, signature: "frozen", status: .waiting)
        let run = WorkflowRun(graph: WorkflowGraph(nodes: [node]), targetNodeID: node.id, steps: [step], status: status)
        #expect(WorkflowHumanPresentation.opensPendingDecision(run) == (status != .saving))
        var decided = run; decided.steps[0].status = .completed
        #expect(!WorkflowHumanPresentation.opensPendingDecision(decided))
        #expect(run.steps[0].decision == nil) // Presentation never accepts or resumes.
    }

    @Test(arguments: ["cancel", "apply", "changed-query", "changed-context", "invalid"])
    func filterDraftAppliesAllFieldsOrNone(scenario: String) throws {
        let first = UUID(), second = UUID()
        let original = SharedLibraryQuery(text: "body", allTagIDs: [first], anyTagIDs: [second])
        var draft = SharedLibraryQueryDraft(query: original, context: "project/instance/run/call")
        draft.query.contentKinds = [.image]; draft.query.properties = .init(favorite: true, width: .init(minimum: 64))
        var live = original
        switch scenario {
        case "cancel": break
        case "apply": live = try draft.validated(current: live, context: draft.context)
        case "changed-query":
            live.text = "new query"
            #expect(throws: WorkflowIssue.self) { try draft.validated(current: live, context: draft.context) }
        case "changed-context":
            #expect(throws: WorkflowIssue.self) { try draft.validated(current: live, context: "different-call") }
        default:
            draft.query.properties?.width = .init(minimum: 100, maximum: 1)
            #expect(throws: SharedLibraryError.self) { try draft.validated(current: live, context: draft.context) }
        }
        #expect(live.allTagIDs == [first] && live.anyTagIDs == [second])
        #expect((live.properties != nil) == (scenario == "apply"))
        #expect(live.contentKinds == (scenario == "apply" ? [.image] : []))
    }

    @Test func deletedTagsKeepNamesAndStableSeparateActionsWithoutWideningScope() throws {
        let store = try SharedLibraryStore()
        let first = try #require(store.createTags(["First"]).first), second = try #require(store.createTags(["Second"]).first)
        let state = SharedLibraryBrowserState(query: .init(text: "note", allTagIDs: [first, second], anyTagIDs: [second]), scope: .tag(first))
        state.reconcile(using: store)
        try store.deleteTags([first, second]); state.reconcile(using: store)
        let a = state.tagPresentation.title(first, tags: store.metadata.tags, missing: "Deleted")
        let b = state.tagPresentation.title(second, tags: store.metadata.tags, missing: "Deleted")
        #expect(a.hasPrefix("Deleted · First · ") && b.hasPrefix("Deleted · Second · ") && a != b)
        #expect(state.scope == .tag(first))
        #expect(throws: SharedLibraryError.missingTag) { try SharedLibraryBrowserLogic.visibleEntries([], store: store, query: state.query, scope: state.scope) }
        state.query.allTagIDs.remove(first); state.reconcile(using: store)
        #expect(state.tagPresentation.title(second, tags: store.metadata.tags, missing: "Deleted") == b)
        #expect(state.query.text == "note" && state.query.anyTagIDs == [second] && state.query.allTagIDs == [second])
        let recreated = try #require(store.createTags(["First"]).first)
        state.query.allTagIDs.insert(recreated); state.reconcile(using: store)
        try store.deleteTags([recreated]); state.reconcile(using: store)
        #expect(state.tagPresentation.title(recreated, tags: store.metadata.tags, missing: "Deleted") != a)
        let saved = SharedLibrarySaveQueryRequest(query: state.query, scopeTitle: "Captured scope", tagTitles: [first: a, second: b])
        #expect(saved.tagTitles[first] == a && saved.tagTitles[second] == b)
        var memory = SharedLibraryTagPresentation(); memory.observe(tags: [:], requested: [first, second])
        let unknown = memory.title(second, tags: [:], missing: "Deleted")
        memory.observe(tags: [:], requested: [second])
        #expect(memory.title(second, tags: [:], missing: "Deleted") == unknown)
        #expect(memory.title(first, tags: [:], missing: "Deleted") != unknown)
    }

    @Test func userContentAndParametersAreOpaqueToPresentation() throws {
        let body = "12345678-0000-0000-0000-000000000001 SHA256: " + String(repeating: "a", count: 64) + "\nlet id = UUID()"
        let node = WorkflowNode(operationID: "d.text.input", title: body, parameters: ["seed": .text("123456789"), "text": .text(body)])
        let identity = WorkflowNodeIdentity.resolve(node: node, definition: WorkflowRegistry.standard.operation(node.operationID)?.definition, modelChoices: [], assets: [], tools: [], language: nil)
        #expect(identity.title.utf8.elementsEqual(body.utf8))
        #expect(node.parameters["text"]?.string?.utf8.elementsEqual(body.utf8) == true)
        #expect(node.parameters["seed"]?.string == "123456789")
        let unnamed = WorkflowNode(operationID: "d.text.input", title: "")
        #expect(WorkflowHumanPresentation.name(unnamed, in: [unnamed]) == WorkflowCanvasPresentation.operationTitle(WorkflowRegistry.standard.definition(for: unnamed)!, language: nil))
    }

    @Test func modelTargetPresentationInvalidatesWithoutCallingSelection() async throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"]))
            .appendingPathComponent("semantics-target-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try await ModelLibrary(stateDirectory: root)
        let model = ModelLibraryModel(library: library)
        await model.refresh()
        let entry = try #require(model.catalog.first)
        for revision in [entry.revision, "unrecorded-revision"] {
            let record = ModelRecord(id: .init(), catalogID: entry.id, revision: revision, storage: .managed,
                state: .queued, availability: .available, downloadedBytes: 0, totalBytes: 1, error: nil,
                directory: nil, activeLeaseCount: 0, registrationState: .unregistered)
            #expect((model.presentationEntry(for: record) != nil) == (revision == entry.revision))
        } // Never borrow current catalog facts for another revision.
        var isCurrent = true, calls = 0
        model.presentSelection { _ in calls += 1 }
        model.captureSelectionPresentation("Project / Flow / Named node") { isCurrent }
        #expect(model.currentSelectionTitle == "Project / Flow / Named node")
        isCurrent = false; #expect(model.currentSelectionTitle == nil && calls == 0)
        model.presentManagement(); #expect(model.selectionTitle == nil && model.selectionAction == nil)
        try await library.shutdown()
    }

    @Test(arguments: ["zh-Hans", "en"])
    func actualMetadataEditorRendersOffscreen(languageID: String) async throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"]))
            .appendingPathComponent("semantics-component-" + languageID)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let project = try await ProjectStore.create(at: root.appendingPathComponent(UUID().uuidString + ".dproject"), name: "Synthetic review — not model output")
        let result = try await project.publishWorkflowAsset(data: Data("Body with UUID 12345678-0000-0000-0000-000000000001".utf8), mediaType: "text/plain", name: "Named result", operationID: "d.text.input")
        let snapshot = try await project.assetMetadataSnapshot(id: result.asset.id)
        let language = UILanguageStore(preferredLanguages: [languageID]); try language.select(languageID)
        let view = AssetAnnotationEditor(snapshot: snapshot, validate: {}, save: { _,_,_,_ in Issue.record("Rendering must not save") }, dismiss: {})
            .environment(\.dLanguageStore, language).preferredColorScheme(.light).padding().background(Color.white)
        let host = NSHostingView(rootView: view); host.frame = CGRect(x: 0, y: 0, width: 560, height: 600)
        for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        #expect(host.fittingSize.width > 300 && host.fittingSize.height > 150)
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if let png = bitmap.representation(using: .png, properties: [:]) { try png.write(to: root.appendingPathComponent("metadata-editor.png")) }
        }
        #expect((await project.snapshot()).assets.first?.name == "Named result")
        try await project.close()
    }
}
