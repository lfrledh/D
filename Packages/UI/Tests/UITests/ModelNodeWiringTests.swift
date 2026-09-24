import AppKit
import DInference
import DWorkbench
import Foundation
import SwiftUI
import Testing
@testable import UI

private actor NodePageEngine: InferenceEngine {
    private(set) var submissions: [UUID] = []
    func submit(_ request: InferenceRequest, backendID: String) -> InferenceRun {
        submissions.append(request.id)
        return InferenceRun(id: request.id, events: AsyncThrowingStream { $0.finish() },
            cancel: {}, outcome: { .cancelled })
    }
}

@Suite(.serialized) @MainActor
struct ModelNodeWiringTests {
    private func withFixture(_ check: @MainActor (ProjectSession, WorkbenchModel, ModelNodePresentation,
                                       ModelNodeTagStore, UserDefaults, NodePageEngine, URL) async throws -> Void) async throws {
        let base = try #require(ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"])
        let folder = URL(fileURLWithPath: base).appendingPathComponent("node-wiring-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = "D.NodeWiring.\(UUID())"
        let settings = try #require(UserDefaults(suiteName: suite))
        defer { settings.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder) }
        let engine = NodePageEngine()
        let service = ProjectSession(sessionFactory: { _ in
            WorkbenchSession(engine: engine, backendID: "node.fixture", status: {
                .init(activeRunID: nil, phase: nil, queuedRunIDs: [])
            }, shutdown: {}, cleanup: {}, validateModel: { _ in })
        }, settings: settings)
        let project = folder.appendingPathComponent("Node.dproject")
        await service.createProject(at: project)
        try #require(service.manifest != nil)
        try await check(service, WorkbenchModel(projectSession: service), ModelNodePresentation(),
                        ModelNodeTagStore(settings: settings), settings, engine, project)
        #expect(await service.requestClose())
    }

    @Test func nodePageBlocksCurrentAndPreviouslyCapturedGenerationAndLeavingRestoresIt() async throws {
        try await withFixture { service, model, page, _, _, engine, project in
            await service.registerModel(at: project.deletingLastPathComponent())
            service.prompt = "An explicit fake-engine regression"
            #expect(model.canRunVisibleGeneration)
            let oldAction = page.generationAction(model: model, enabled: { model.canRunVisibleGeneration })
            page.selectPane(.nodes)
            let blocked = page.generationAction(model: model, enabled: { model.canRunVisibleGeneration })
            #expect(!page.generationCommand(model: model, enabled: { model.canRunVisibleGeneration }).isEnabled)
            #expect(!(await oldAction()))
            #expect(!(await blocked()))
            #expect(await engine.submissions.isEmpty)
            #expect(service.manifest?.jobs.isEmpty == true)
            page.selectPane(.creations)
            #expect(!(await oldAction()), "Returning to the same pane must not revive a stale command.")
            #expect(!(await blocked()))
            let fresh = page.generationAction(model: model, enabled: { model.canRunVisibleGeneration })
            #expect(page.generationCommand(model: model, enabled: { model.canRunVisibleGeneration }).isEnabled)
            #expect(await fresh())
            let deadline = ContinuousClock.now + .seconds(5)
            while service.isBusy, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            #expect(!service.isBusy)
            #expect(await engine.submissions.count == 1)
            #expect(service.manifest?.jobs.count == 1)
        }
    }

    @Test func staleNodeCallbacksCannotWriteAfterSelectionABAOrNavigation() async throws {
        try await withFixture { service, model, page, tags, _, engine, _ in
            let node = try #require(ModelNodeCatalog.entries.first { $0.modality == .image })
            page.selectPane(.nodes); page.selectNode(node.id)
            let write = page.tagWriter(node: node, store: tags, model: model)
            #expect(write(["原标签"]) == nil)
            page.selectNode("another-model"); page.selectNode(node.id)
            #expect(write(["迟到修改"]) != nil)
            #expect(tags.readState(for: node.id) == .valid(["原标签"]))
            let next = page.tagWriter(node: node, store: tags, model: model)
            await service.selectCreatorMode(.text)
            #expect(next(["跨模态迟到"]) != nil)
            await service.selectCreatorMode(.image)
            #expect(next(["导航 ABA"]) != nil)
            page.modalityChanged(); page.selectNode(node.id)
            let beforeProjectChange = page.tagWriter(node: node, store: tags, model: model)
            page.projectChanged()
            #expect(beforeProjectChange(["跨项目迟到"]) != nil)
            #expect(tags.readState(for: node.id) == .valid(["原标签"]))
            #expect(tags.readState(for: "another-model") == .missing)
            #expect(await engine.submissions.isEmpty)
        }
    }

    @Test func browsingAndActualTagActionsPreserveProjectAndCorruptPreference() async throws {
        try await withFixture { service, model, page, tags, settings, engine, project in
            #expect(!model.canRunVisibleGeneration, "No model is installed in this fixture.")
            let savedBefore = try Data(contentsOf: project.appendingPathComponent("project.json"))
            let original = try #require(service.manifest)
            let node = try #require(ModelNodeCatalog.entries.first { $0.modality == .image })
            page.selectPane(.nodes); page.selectNode(node.id)
            let writer = page.tagWriter(node: node, store: tags, model: model)
            var editor = ModelNodeTagEditorState(tagState: tags.readState(for: node.id))
            editor.draft = "旧标签"; editor.addDraft(using: writer)
            editor.draft = "中文 👩‍💻 e\u{301}"; editor.remove("旧标签", using: writer)
            #expect(editor.draft == "中文 👩‍💻 e\u{301}")
            editor.addDraft(using: writer)
            #expect(editor.tags == ["中文 👩‍💻 e\u{301}"] && editor.draft.isEmpty)
            #expect(ModelNodeTagStore(settings: settings).readState(for: node.id) == .valid(editor.tags))
            settings.set(["仍有价值的原标签", " "], forKey: "D.ModelNodeTags.v1." + node.id)
            editor.draft = "保留草稿"
            editor.remove(editor.tags[0], using: writer)
            #expect(editor.tags == ["中文 👩‍💻 e\u{301}"] && editor.draft == "保留草稿")
            #expect(editor.errorMessage != nil)
            #expect(settings.stringArray(forKey: "D.ModelNodeTags.v1." + node.id) == ["仍有价值的原标签", " "])
            var geometry: [String: CGRect] = [:]
            let host = NSHostingView(rootView: ModelNodeDetail(node: node, tagState: tags.readState(for: node.id),
                onTagsChange: writer).observingLayout { geometry[$0] = $1 })
            host.frame = NSRect(x: 0, y: 0, width: 640, height: 720)
            settle(host)
            #expect(geometry["model-node-tags-corrupt-\(node.id)"] != nil)
            #expect(geometry["model-node-tags-empty-\(node.id)"] == nil)
            page.selectPane(.assets); page.selectPane(.creations)
            #expect(try Data(contentsOf: project.appendingPathComponent("project.json")) == savedBefore)
            #expect(service.manifest == original)
            #expect(await engine.submissions.isEmpty)
        }
    }
    private func settle<Content: View>(_ host: NSHostingView<Content>) {
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
    }

}
