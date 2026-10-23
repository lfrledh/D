import AppKit
import DWorkbench
import SwiftUI
import Testing
@testable import UI

@MainActor private final class MenuScopeWindow: NSWindow {
    var active = false
    var modal: NSWindow?
    override var isKeyWindow: Bool { active }
    override var attachedSheet: NSWindow? { modal }
}

@Suite(.serialized) @MainActor struct WorkbenchSystemCommandTests {
    @Test func exactWindowScopeRejectsOtherWindowSheetAndDestroyedHost() {
        let main = MenuScopeWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let viewer = MenuScopeWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        main.isReleasedWhenClosed = false; viewer.isReleasedWhenClosed = false
        defer { main.modal = nil; main.close(); viewer.close() }
        let scope = WorkbenchCommandScope(); #expect(!scope.permitsCommands)
        scope.window = main; main.active = true; #expect(scope.permitsCommands)
        main.active = false; viewer.active = true; #expect(!scope.permitsCommands)
        main.active = true; main.modal = viewer; #expect(!scope.permitsCommands)
        main.modal = nil; #expect(scope.permitsCommands)
        scope.window = nil; #expect(!scope.permitsCommands)
    }

    @Test func exportRetainsCapturedStoreAndRejectsChangedSelectionBeforeWriting() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"]!).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await ProjectStore.create(at: root.appendingPathComponent("A.dproject"), name: "A")
        let other = try await ProjectStore.create(at: root.appendingPathComponent("B.dproject"), name: "B")
        let source = root.appendingPathComponent("Source.txt"); try Data("Original".utf8).write(to: source)
        let published = try await store.importWorkflowMediaFile(at: source)
        let destination = root.appendingPathComponent("Export", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var active = store
        let command = WorkbenchAssetExportCommand(store: store, reference: published.record.reference, staleMessage: "target changed", isCurrent: { active === store })
        let before = await store.snapshot(), otherBefore = await other.snapshot()
        do {
            _ = try await command.perform { active = other; return destination }
            Issue.record("A destination-panel suspension must not redirect to a new project")
        } catch { #expect(error.localizedDescription.contains("target changed")) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        active = store
        #expect(try await command.perform { nil } == false)
        #expect(try await command.perform { destination })
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).count == 1)
        #expect(await store.snapshot() == before)
        #expect(await other.snapshot() == otherBefore)
        #expect(try Data(contentsOf: source) == Data("Original".utf8))
        try await store.close(); try await other.close()
    }

    @Test func recoveryKeepsStagesAndRunsDistinctAndNeverChoosesAMixedQueue() {
        let first = UUID(), second = UUID()
        let stageOnly = WorkflowDockRecovery.targets(stageIDs: [first], runIDs: [])
        #expect(stageOnly == [.stage(first)])
        #expect(WorkflowDockRecovery.targets(stageIDs: [first], runIDs: [second]).count == 2)
        #expect(WorkflowDockRecovery.targets(stageIDs: [first], runIDs: [first]).count == 2)
        #expect(stageOnly != WorkflowDockRecovery.targets(stageIDs: [second], runIDs: []))
        #expect(WorkflowDockRecovery.targets(stageIDs: [], runIDs: [first]) == [.run(first)])
        #expect(WorkflowMediaFormat.supportsReadOnlyExport("text/plain"))
        #expect(!WorkflowMediaFormat.supportsReadOnlyExport("application/unknown"))
    }

    @Test func menuResourcesAreRealBilingualSentences() throws {
        let keys = ["recent", "recentEmpty", "import", "export", "showLeft", "hideLeft", "showRight", "hideRight", "zoomIn", "zoomOut", "actualSize", "fit", "showWorkbench", "run", "generate", "runSettings", "pause", "resume", "stop", "retrySave", "workflow", "blankFlow", "templates", "stale", "guide"]
        for locale in ["zh-Hans", "en"] {
            let language = UILanguageStore(preferredLanguages: [locale]); try language.select(locale)
            for key in keys {
                let value = systemMenuText(language, key)
                #expect(!value.isEmpty && value != "—" && !value.contains("systemMenu."))
            }
        }
    }
}
