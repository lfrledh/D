import DInference
import Foundation
import Testing
@testable import DWorkbench
@testable import UI

private actor FilePresentationNoInferenceEngine: InferenceEngine {
    func submit(_ request: InferenceRequest, backendID: String) async throws -> InferenceRun {
        throw WorkflowIssue("File presentation fixture does not execute inference.")
    }
}

@Suite("Project file status presentation")
struct ProjectFilesPresentationTests {
    @Test func missingReferenceStaysMissingAndPartialResultStaysPartial() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent("file-presentation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.txt")
        try Data("fixed source".utf8).write(to: source)
        let store = try await ProjectStore.create(at: root.appendingPathComponent("Work.dproject"), name: "Work")
        let published = try await store.importWorkflowMediaFile(at: source, mode: .reference)
        let initial = try await store.assetLocationOverview(published.asset.id)
        #expect(ProjectFilesPresentation.selectedStatus(initial) == .verified)
        try FileManager.default.removeItem(at: source)
        let missing = try await store.assetLocationOverview(published.asset.id, deep: true)
        #expect(ProjectFilesPresentation.selectedStatus(missing) == .missing)
        let summary = try await store.projectFileOverview()
        #expect(summary.libraryAvailability.reduce(0) { $0 + $1.missing } == 1)
        #expect(summary.libraryAvailability.reduce(0) { $0 + $1.offline + $1.needsAuthorization } == 0)
        let results = try await store.collectProjectMedia()
        #expect(!ProjectFilesPresentation.allSucceeded(results))
        try await store.close()
    }

    @Test @MainActor func cancelledOperationRefreshesCommittedExternalPreviewsWithoutDiskError() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent("file-cancel-refresh-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settingsName = "D.FileCancel." + UUID().uuidString
        let settings = try #require(UserDefaults(suiteName: settingsName))
        defer { settings.removePersistentDomain(forName: settingsName) }
        let engine = FilePresentationNoInferenceEngine()
        let owner = ProjectSession(sessionFactory: { _ in
            WorkbenchSession(engine: engine, backendID: "files.none",
                status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) },
                shutdown: {}, cleanup: {}, validateModel: { _ in })
        }, settings: settings)
        await owner.createProject(at: root.appendingPathComponent("Work.dproject"))
        let store = try #require(owner.currentStore)
        let instanceID = try #require(owner.manifest?.effectiveInstanceID)
        let firstSource = root.appendingPathComponent("first.txt")
        let secondSource = root.appendingPathComponent("second.txt")
        try Data("first external".utf8).write(to: firstSource)
        try Data("second external".utf8).write(to: secondSource)
        let first = try await store.importWorkflowMediaFile(at: firstSource, mode: .reference)
        await owner.refreshAfterFileOperation(store: store, instanceID: instanceID)
        #expect(owner.assetURLs[first.asset.id] != nil)
        let cancelledRefresh = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            await owner.refreshAfterFileOperation(store: store, instanceID: instanceID)
        }
        await cancelledRefresh.value
        #expect(owner.assetURLs[first.asset.id] != nil)
        #expect(owner.errorMessage == nil)
        var displayedIDs: Set<UUID> = []
        let job = Task { @MainActor in
            let second = try await store.importWorkflowMediaFile(at: secondSource, mode: .reference)
            withUnsafeCurrentTask { $0?.cancel() }
            await ProjectFilesPresentation.refreshAfterOperation(store: store, instanceID: instanceID,
                onContentsChanged: { changedStore, changedInstance in
                    await owner.refreshAfterFileOperation(store: changedStore, instanceID: changedInstance)
                }, refreshOverview: {
                    let overview = try? await store.projectFileOverview(deep: false)
                    displayedIDs = Set(overview?.assets.map(\.asset.id) ?? [])
                })
            return second.asset.id
        }
        let secondID = try await job.value
        #expect(owner.manifest?.assets.contains(where: { $0.id == secondID }) == true)
        #expect(owner.assetURLs[first.asset.id] != nil)
        #expect(owner.assetURLs[secondID] != nil)
        #expect(displayedIDs == Set([first.asset.id, secondID]))
        #expect(owner.errorMessage == nil)
        await owner.closeProject()
    }

    @Test @MainActor func manualBackupFlushesCanvasAndQuickAndRejectsFailedOrStaleSave() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory())
            .appendingPathComponent("file-backup-drafts-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settingsName = "D.FileBackup." + UUID().uuidString
        let settings = try #require(UserDefaults(suiteName: settingsName))
        defer { settings.removePersistentDomain(forName: settingsName) }
        let engine = FilePresentationNoInferenceEngine()
        let owner = ProjectSession(sessionFactory: { _ in
            WorkbenchSession(engine: engine, backendID: "files.none",
                status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) },
                shutdown: {}, cleanup: {}, validateModel: { _ in })
        }, settings: settings)
        await owner.createProject(at: root.appendingPathComponent("Work.dproject"))
        await owner.openWorkflow()
        let store = try #require(owner.currentStore)
        let instanceID = try #require(owner.manifest?.effectiveInstanceID)
        let controller = try #require(owner.workflow)
        controller.addBlankGraph()
        controller.addNode(operationID: "d.text.input")
        let nodeID = try #require(controller.graph?.nodes.first?.id)
        controller.setParameter(nodeID: nodeID, key: "text", value: .text("new unsaved canvas edit"))
        let library = try await ModelLibrary(stateDirectory: root.appendingPathComponent("Models"))
        let quick = QuickGenerationController(store: store) { throw WorkflowIssue("No inference in backup fixture") }
        await quick.load()
        quick.select(operationID: "d.model.language", modelID: "test-model")
        let draftID = try #require(quick.draft?.id)
        quick.setParameter("task", value: .text("new unsaved quick edit"), draftID: draftID)
        let backup = root.appendingPathComponent("Good.dbackup")
        let receipt = try await ProjectFilesPresentation.createBackup(at: backup, store: store,
            instanceID: instanceID, modelLibrary: library, models: [], allowIncomplete: false,
            isActive: { owner.currentStore === store && owner.manifest?.effectiveInstanceID == instanceID },
            saveDrafts: { captured, id in
                try await owner.saveWorkflowForBackup(store: captured, instanceID: id)
                try await quick.flush()
            })
        #expect(receipt.complete)
        let restoredURL = root.appendingPathComponent("Restored.dproject")
        _ = try await ProjectStore.restoreBackup(at: backup, to: restoredURL)
        let restored = try await ProjectStore.open(at: restoredURL)
        let archive = try #require(try await restored.workflowState().archive)
        #expect(archive.graphs.first?.nodes.first?.parameters["text"] == .text("new unsaved canvas edit"))
        let quickState = try await restored.quickCreationState()
        #expect(quickState.drafts.first(where: { $0.id == draftID })?.node.parameters["task"] == .text("new unsaved quick edit"))
        try await restored.close()

        let cancelledURL = root.appendingPathComponent("Cancelled.dbackup")
        let cancelledJob = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ProjectFilesPresentation.createBackup(at: cancelledURL, store: store,
                instanceID: instanceID, modelLibrary: library, models: [], allowIncomplete: false,
                isActive: { owner.currentStore === store && owner.manifest?.effectiveInstanceID == instanceID },
                saveDrafts: { captured, id in try await owner.saveWorkflowForBackup(store: captured, instanceID: id) })
        }
        do { _ = try await cancelledJob.value; Issue.record("Cancelled backup must not be created") }
        catch is CancellationError {}
        #expect(!FileManager.default.fileExists(atPath: cancelledURL.path))

        controller.setParameter(nodeID: nodeID, key: "text", value: .text("must not back up"))
        controller.beforeHistorySave = { throw WorkflowIssue("controlled save failure") }
        let failedURL = root.appendingPathComponent("Failed.dbackup")
        do {
            _ = try await ProjectFilesPresentation.createBackup(at: failedURL, store: store,
                instanceID: instanceID, modelLibrary: library, models: [], allowIncomplete: false,
                isActive: { owner.currentStore === store && owner.manifest?.effectiveInstanceID == instanceID },
                saveDrafts: { captured, id in try await owner.saveWorkflowForBackup(store: captured, instanceID: id) })
            Issue.record("Failed canvas save must block backup")
        } catch {}
        #expect(!FileManager.default.fileExists(atPath: failedURL.path))
        controller.beforeHistorySave = {}
        try await controller.saveExplicitEdits()
        let otherURL = root.appendingPathComponent("Other.dproject")
        let staleURL = root.appendingPathComponent("Stale.dbackup")
        do {
            _ = try await ProjectFilesPresentation.createBackup(at: staleURL, store: store,
                instanceID: instanceID, modelLibrary: library, models: [], allowIncomplete: true,
                isActive: { owner.currentStore === store && owner.manifest?.effectiveInstanceID == instanceID },
                saveDrafts: { captured, id in
                    try await owner.saveWorkflowForBackup(store: captured, instanceID: id)
                    await owner.closeProject()
                    await owner.createProject(at: otherURL)
                })
            Issue.record("Stale instance must block backup")
        } catch {}
        #expect(owner.currentStore !== store)
        #expect(!FileManager.default.fileExists(atPath: staleURL.path))
        await owner.closeProject()
    }
}
