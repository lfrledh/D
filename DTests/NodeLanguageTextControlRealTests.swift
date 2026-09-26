import DInference
import DWorkbench
import Foundation
import Testing
@testable import D

/// Opt-in real text control-boundary checks through the production App composition root.
/// These tests do not establish GUI or disconnected-network acceptance.
@Suite(.serialized) @MainActor
struct NodeLanguageTextControlRealTests {
    private struct BranchBody {
        let graph: WorkflowGraph
        let sourceID: UUID
        let languageID: UUID
        let sourceText: String
        let task: String
    }

    private struct ExecutionObservation {
        let runtimeRunID: UUID?
        let state: JobState?
        let phase: String?
        let streamedCharacterCount: Int
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["D_NODE_LANGUAGE_REAL_CASE"] == "text-control"),
          .timeLimit(.minutes(15)))
    func selectedBranchRunsRealTextWithoutAdmittingUnselectedModel() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let modelPath = environment["D_NODE_LANGUAGE_TEXT_MODEL"] else {
            throw WorkflowIssue("D_NODE_LANGUAGE_TEXT_MODEL is required for text-control acceptance.")
        }
        let modelURL = URL(fileURLWithPath: modelPath)
        let root = try acceptanceRoot(caseName: "branch")
        let project = root.appendingPathComponent("branch-control.dproject")
        print("D_NODE_LANGUAGE_TEXT_CONTROL_BRANCH_ROOT=\(root.path)")

        let store = try await ProjectStore.create(at: project, name: "Text control branch acceptance")
        var ownedRuntime: WorkbenchSession?
        var reopenedStore: ProjectStore?
        var storeIsClosed = false
        var controller: WorkflowController?
        let started = Date()
        do {
            let runtime = try await AppSessionFactory.makeSession(artifactDirectory: store.artifactDirectory)
            ownedRuntime = runtime
            guard let validateModel = runtime.validateTextModel else {
                throw WorkflowIssue("The production App session has no text model validator.")
            }
            let reference = try await validateModel(modelURL)
            guard let backendID = runtime.textBackendID else {
                throw WorkflowIssue("The production App session has no text backend.")
            }
            let identity = "text:" + (reference.revision ?? modelURL.lastPathComponent)
            let missingIdentity = "text:missing-unselected-" + UUID().uuidString
            var resolvedModelIDs: [String] = []
            let services = WorkflowServices(
                store: store,
                session: runtime,
                defaultIdentity: { kind in kind == .text ? identity : "" },
                resolveModel: { kind, selected in
                    resolvedModelIDs.append(selected)
                    guard kind == .text, selected == identity else {
                        throw WorkflowIssue("Unexpected model resolution in branch acceptance: \(selected)")
                    }
                    return .init(identity: identity, reference: reference, backendID: backendID)
                }
            )

            let selected = try languageBody(
                name: "Selected real language body",
                sourceText: "A red boat rests on a quiet lake beneath the morning mist.",
                task: "Rewrite the supplied Content as one short English sentence. Return only the sentence.",
                modelID: identity,
                maximumOutputTokens: 64
            )
            let unselected = try languageBody(
                name: "Unselected missing-model body",
                sourceText: "This body must never execute.",
                task: "Return one sentence. This request must never be submitted.",
                modelID: missingIdentity,
                maximumOutputTokens: 64
            )
            var selector = try node("d.value.input", title: "Select installed model branch")
            selector.dataConfiguration = .init(value: .boolean(true))
            var branch = try node("d.control.branch", title: "Lazy real text branch")
            branch.control = .branch(
                predicate: .init(comparison: .equals, value: .boolean(true)),
                then: selected.graph,
                otherwise: unselected.graph
            )
            let graph = WorkflowGraph(
                name: "Real text lazy branch",
                nodes: [selector, branch],
                connections: [.init(sourceNode: selector.id, targetNode: branch.id)]
            )
            let stateBeforeSave = try await store.workflowState()
            guard let archiveBeforeSave = stateBeforeSave.archive else {
                throw WorkflowIssue("New branch project has no workflow archive.")
            }
            _ = try await store.saveWorkflow(
                graphs: [graph], runs: [], expectedRevision: archiveBeforeSave.revision
            )

            let subject = WorkflowController(services: services)
            controller = subject
            await subject.load()
            await subject.run(target: branch.id, only: false)
            guard subject.errorMessage == nil else {
                throw WorkflowIssue(subject.errorMessage ?? "Branch execution failed without an error message.")
            }
            guard let run = subject.runs.last else {
                throw WorkflowIssue("Branch execution did not create a run.")
            }
            guard run.status == .completed else {
                throw WorkflowIssue("Branch run status was \(run.status.rawValue), expected completed.")
            }
            guard let checkpoint = run.planCheckpoint else {
                throw WorkflowIssue("Branch run did not retain its plan checkpoint.")
            }
            let selectedRecords = checkpoint.records.filter { $0.step.node.id == selected.languageID }
            guard selectedRecords.count == 1 else {
                throw WorkflowIssue("Selected language body must have exactly one call record.")
            }
            let selectedRecord = selectedRecords[0]
            guard selectedRecord.step.status == .completed else {
                throw WorkflowIssue("Selected language call did not complete.")
            }
            guard selectedRecord.address.path.contains(.branch(true)) else {
                throw WorkflowIssue("Selected language call lacks the true-branch execution address.")
            }
            let unselectedRecords = checkpoint.records.filter {
                $0.step.node.id == unselected.sourceID || $0.step.node.id == unselected.languageID
            }
            guard unselectedRecords.isEmpty else {
                throw WorkflowIssue("The unselected body produced call records.")
            }
            guard resolvedModelIDs == [identity] else {
                throw WorkflowIssue("Model resolver calls were \(resolvedModelIDs), expected only the selected identity.")
            }
            guard !resolvedModelIDs.contains(missingIdentity) else {
                throw WorkflowIssue("The unselected missing model was resolved.")
            }
            guard let branchRecord = checkpoint.records.first(where: { $0.step.node.id == branch.id }) else {
                throw WorkflowIssue("Branch execution record is missing.")
            }
            let selectedOutput = selectedRecord.step.outputs["output"]
            guard branchRecord.step.outputs["output"] == selectedOutput else {
                throw WorkflowIssue("Branch output does not preserve the selected body output.")
            }
            let generatedText = selectedOutput?.datum?.text ?? ""
            guard !generatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw WorkflowIssue("Selected real language body returned empty text.")
            }

            await subject.save()
            guard subject.errorMessage == nil, !subject.hasPendingSaves else {
                throw WorkflowIssue(subject.errorMessage ?? "Branch result still has pending saves.")
            }
            let stateAfterRun = try await store.workflowState()
            guard let archive = stateAfterRun.archive else {
                throw WorkflowIssue("Completed branch project has no workflow archive.")
            }
            let requestAssets = archive.assets.filter { $0.request != nil }
            guard requestAssets.count == 1 else {
                throw WorkflowIssue("Branch acceptance expected exactly one submitted inference request.")
            }
            let requestAsset = requestAssets[0]
            guard requestAsset.stepID == selectedRecord.id else {
                throw WorkflowIssue("Persisted request does not belong to the selected call.")
            }
            guard archive.assets.allSatisfy({ $0.stepID != nil || $0.request == nil }) else {
                throw WorkflowIssue("A persisted inference request lacks a call identity.")
            }
            guard archive.assets.contains(where: { $0.stepID == selectedRecord.id && $0.request != nil }) else {
                throw WorkflowIssue("Selected call has no persisted inference request.")
            }
            guard archive.assets.contains(where: { $0.stepID == selectedRecord.id && $0.operationID == "d.model.language" }) else {
                throw WorkflowIssue("Selected language publication is missing.")
            }
            guard let request = requestAsset.request else {
                throw WorkflowIssue("Selected request metadata is missing.")
            }
            guard request.id == selectedRecord.id, request.model == reference else {
                throw WorkflowIssue("Selected request identity or fixed model changed.")
            }
            guard case .text(let textRequest) = request.input else {
                throw WorkflowIssue("Selected request is not a text request.")
            }
            let expectedPrompt = selected.task + "\n\nContent:\n" + selected.sourceText
            guard textRequest.prompt == expectedPrompt,
                  textRequest.maxTokens == 64,
                  textRequest.temperature == 0 else {
                throw WorkflowIssue("Selected text request parameters changed.")
            }
            guard let sourceRecord = checkpoint.records.first(where: { $0.step.node.id == selected.sourceID }) else {
                throw WorkflowIssue("Selected source call record is missing.")
            }
            guard let sourceReference = sourceRecord.step.outputs["output"]?.asset else {
                throw WorkflowIssue("Selected source asset is missing.")
            }
            guard requestAsset.parents == [sourceReference] else {
                throw WorkflowIssue("Selected inference parent provenance changed.")
            }
            guard selectedRecord.step.outputs["raw"]?.asset == requestAsset.reference else {
                throw WorkflowIssue("Selected raw output does not reference its persisted request asset.")
            }
            let storedSourceData = try await store.workflowData(sourceReference)
            guard String(data: storedSourceData, encoding: .utf8) == selected.sourceText else {
                throw WorkflowIssue("Selected source body text changed before close.")
            }
            guard archive.assets.allSatisfy({ asset in
                asset.stepID != selectedRecord.id || asset.request != nil
            }) else {
                throw WorkflowIssue("Selected language call has an unexpected non-request publication.")
            }

            subject.deactivateAfterClose()
            try await store.close()
            storeIsClosed = true
            let reopened = try await ProjectStore.open(at: project)
            reopenedStore = reopened
            let reopenedState = try await reopened.workflowState()
            guard reopenedState.archive == archive else {
                throw WorkflowIssue("Branch workflow archive changed after reopen.")
            }
            let reopenedSourceData = try await reopened.workflowData(sourceReference)
            guard String(data: reopenedSourceData, encoding: .utf8) == selected.sourceText else {
                throw WorkflowIssue("Selected source body text changed after reopen.")
            }
            try await reopened.close()
            reopenedStore = nil
            await runtime.shutdown()
            ownedRuntime = nil

            let report: [String: Any] = [
                "case": "text-control-branch",
                "status": "PASS",
                "driver": "AppSessionFactory + WorkflowServices + WorkflowController",
                "project": project.path,
                "elapsedSeconds": Date().timeIntervalSince(started),
                "modelRevision": reference.revision ?? "unknown",
                "runID": run.id.uuidString,
                "selectedCallID": selectedRecord.id.uuidString,
                "requestID": request.id.uuidString,
                "selectedResolverCalls": resolvedModelIDs.count,
                "unselectedResolverCalls": resolvedModelIDs.filter { $0 == missingIdentity }.count,
                "unselectedCallRecords": unselectedRecords.count,
                "submittedRequests": requestAssets.count,
                "guiValidated": false,
                "offlineValidated": false,
            ]
            try writeReport(report, to: root.appendingPathComponent("real-result.json"))
            print("D_NODE_LANGUAGE_TEXT_CONTROL_BRANCH_PASS=\(root.path)")
        } catch {
            let primaryError = error
            controller?.deactivateAfterClose()
            if let runtime = ownedRuntime {
                await runtime.shutdown()
            }
            var cleanupErrors: [String] = []
            if let reopened = reopenedStore {
                do {
                    try await reopened.close(preserveExternalChanges: true)
                } catch {
                    cleanupErrors.append("reopenedStore: " + error.localizedDescription)
                }
            }
            if !storeIsClosed {
                do {
                    try await store.close(preserveExternalChanges: true)
                } catch {
                    cleanupErrors.append("store: " + error.localizedDescription)
                }
            }
            var failureReport: [String: Any] = [
                "case": "text-control-branch",
                "status": "FAIL",
                "error": primaryError.localizedDescription,
                "elapsedSeconds": Date().timeIntervalSince(started),
                "guiValidated": false,
                "offlineValidated": false,
            ]
            failureReport["cleanupErrors"] = cleanupErrors
            do {
                try writeReport(failureReport, to: root.appendingPathComponent("real-result-failure.json"))
            } catch {
                throw WorkflowIssue(
                    "Branch failure: \(primaryError.localizedDescription); cleanup: \(cleanupErrors); failure evidence write failed: \(error.localizedDescription)"
                )
            }
            throw primaryError
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["D_NODE_LANGUAGE_REAL_CASE"] == "text-control"),
          .timeLimit(.minutes(15)))
    func realTextCancellationDrainsBeforeNextRequest() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let modelPath = environment["D_NODE_LANGUAGE_TEXT_MODEL"] else {
            throw WorkflowIssue("D_NODE_LANGUAGE_TEXT_MODEL is required for text-control acceptance.")
        }
        let modelURL = URL(fileURLWithPath: modelPath)
        let root = try acceptanceRoot(caseName: "cancel")
        let project = root.appendingPathComponent("cancel-control.dproject")
        print("D_NODE_LANGUAGE_TEXT_CONTROL_CANCEL_ROOT=\(root.path)")

        let store = try await ProjectStore.create(at: project, name: "Text cancellation boundary acceptance")
        var ownedRuntime: WorkbenchSession?
        var reopenedStore: ProjectStore?
        var storeIsClosed = false
        var controller: WorkflowController?
        var firstTask: Task<Void, Never>?
        let started = Date()
        do {
            let protectedText = "Test-owned original text before cancellation."
            let manifestWithDocument = try await store.createTextDocument(
                name: "Protected original document",
                text: protectedText
            )
            guard let frozenOriginalDocument = manifestWithDocument.activeDocument,
                  frozenOriginalDocument.textDraft?.text == protectedText else {
                throw WorkflowIssue("The protected original text document was not created exactly.")
            }
            let protectedAssetData = Data("Test-owned original asset before cancellation.\n".utf8)
            let protectedPublication = try await store.publishWorkflowAsset(
                data: protectedAssetData,
                mediaType: "text/plain",
                name: "Protected original asset",
                operationID: "d.asset.import"
            )
            let frozenOriginalAsset = protectedPublication.asset
            let frozenOriginalRecord = protectedPublication.record
            guard frozenOriginalAsset.role == .original,
                  try await store.workflowData(frozenOriginalRecord.reference) == protectedAssetData else {
                throw WorkflowIssue("The protected original asset was not frozen exactly.")
            }

            let runtime = try await AppSessionFactory.makeSession(artifactDirectory: store.artifactDirectory)
            ownedRuntime = runtime
            guard let validateModel = runtime.validateTextModel else {
                throw WorkflowIssue("The production App session has no text model validator.")
            }
            let reference = try await validateModel(modelURL)
            guard let backendID = runtime.textBackendID else {
                throw WorkflowIssue("The production App session has no text backend.")
            }
            let identity = "text:" + (reference.revision ?? modelURL.lastPathComponent)
            var resolvedModelIDs: [String] = []
            let services = WorkflowServices(
                store: store,
                session: runtime,
                defaultIdentity: { kind in kind == .text ? identity : "" },
                resolveModel: { kind, selected in
                    resolvedModelIDs.append(selected)
                    guard kind == .text, selected == identity else {
                        throw WorkflowIssue("Unexpected model resolution in cancellation acceptance: \(selected)")
                    }
                    return .init(identity: identity, reference: reference, backendID: backendID)
                }
            )
            let cancellationTask = "Write a detailed but finite description of a quiet harbor at dawn. Return plain text."
            let recoveryTask = "Write one short sentence about a green lantern. Return only the sentence."
            let first = try languageNode(
                title: "Cancellable real text",
                task: cancellationTask,
                modelID: identity,
                maximumOutputTokens: 512
            )
            let second = try languageNode(
                title: "Post-cancel real text",
                task: recoveryTask,
                modelID: identity,
                maximumOutputTokens: 64
            )
            let graph = WorkflowGraph(name: "Cancel then run", nodes: [first, second])
            let stateBeforeSave = try await store.workflowState()
            guard let archiveBeforeSave = stateBeforeSave.archive else {
                throw WorkflowIssue("New cancellation project has no workflow archive.")
            }
            _ = try await store.saveWorkflow(
                graphs: [graph], runs: [], expectedRevision: archiveBeforeSave.revision
            )
            let subject = WorkflowController(services: services)
            controller = subject
            await subject.load()

            firstTask = Task { @MainActor in
                await subject.run(target: first.id, only: true)
            }
            let observation = try await waitForObservableExecution(
                runtime: runtime,
                services: services,
                controller: subject,
                timeout: .seconds(120)
            )
            guard let observation else {
                throw WorkflowIssue("The first request completed too quickly or never reached an observable real runtime boundary; cancellation evidence is not satisfied.")
            }
            await subject.cancel()
            guard let runningTask = firstTask else {
                throw WorkflowIssue("The owned Controller task handle was lost.")
            }
            await runningTask.value
            firstTask = nil

            guard !subject.isRunning else {
                throw WorkflowIssue("Controller still owns the cancelled task after run returned.")
            }
            guard subject.errorMessage == nil else {
                throw WorkflowIssue(subject.errorMessage ?? "Cancellation failed without an error message.")
            }
            guard let cancelledRun = subject.runs.last else {
                throw WorkflowIssue("Cancellation did not create a workflow run.")
            }
            guard cancelledRun.status == .cancelled else {
                throw WorkflowIssue("Observed request ended as \(cancelledRun.status.rawValue), so cancellation evidence is not satisfied.")
            }
            guard let cancelledCheckpoint = cancelledRun.planCheckpoint else {
                throw WorkflowIssue("Cancelled run did not retain a checkpoint.")
            }
            let cancelledRecords = cancelledCheckpoint.records.filter { $0.step.node.id == first.id }
            guard cancelledRecords.count == 1 else {
                throw WorkflowIssue("Cancelled request must retain exactly one call record.")
            }
            let cancelledRecord = cancelledRecords[0]
            guard cancelledRecord.step.status == .cancelled else {
                throw WorkflowIssue("Cancelled call record is not terminally cancelled.")
            }
            guard let observedRuntimeRunID = observation.runtimeRunID,
                  observedRuntimeRunID == cancelledRecord.id else {
                throw WorkflowIssue("Observed runtime identity does not match the cancelled call/request identity.")
            }
            let idleAfterCancel = await runtime.status()
            guard idleAfterCancel.activeRunID == nil, idleAfterCancel.queuedRunIDs.isEmpty else {
                throw WorkflowIssue("Runtime was not drained before the next request.")
            }
            guard !services.hasPendingSaves else {
                throw WorkflowIssue("Cancelled request left an unpublished result pending.")
            }

            await subject.run(target: second.id, only: true)
            guard subject.errorMessage == nil else {
                throw WorkflowIssue(subject.errorMessage ?? "Post-cancel request failed without an error message.")
            }
            guard let recoveryRun = subject.runs.last else {
                throw WorkflowIssue("Post-cancel request did not create a run.")
            }
            guard recoveryRun.status == .completed else {
                throw WorkflowIssue("Post-cancel run status was \(recoveryRun.status.rawValue), expected completed.")
            }
            guard recoveryRun.id != cancelledRun.id else {
                throw WorkflowIssue("Post-cancel execution reused the cancelled run identity.")
            }
            guard let recoveryCheckpoint = recoveryRun.planCheckpoint else {
                throw WorkflowIssue("Post-cancel run did not retain a checkpoint.")
            }
            let recoveryRecords = recoveryCheckpoint.records.filter { $0.step.node.id == second.id }
            guard recoveryRecords.count == 1 else {
                throw WorkflowIssue("Post-cancel request must retain exactly one call record.")
            }
            let recoveryRecord = recoveryRecords[0]
            guard recoveryRecord.step.status == .completed else {
                throw WorkflowIssue("Post-cancel call did not complete.")
            }
            guard recoveryRecord.id != cancelledRecord.id else {
                throw WorkflowIssue("Post-cancel request reused the cancelled call identity.")
            }
            let recoveredText = recoveryRecord.step.outputs["output"]?.datum?.text ?? ""
            guard !recoveredText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw WorkflowIssue("Post-cancel request returned empty text.")
            }
            guard let recoveryRaw = recoveryRecord.step.outputs["raw"]?.asset else {
                throw WorkflowIssue("Post-cancel request has no raw text asset.")
            }
            let rawData = try await store.workflowData(recoveryRaw)
            guard String(data: rawData, encoding: .utf8) == recoveredText else {
                throw WorkflowIssue("Post-cancel raw asset and structured output differ.")
            }
            let idleAfterRecovery = await runtime.status()
            guard idleAfterRecovery.activeRunID == nil, idleAfterRecovery.queuedRunIDs.isEmpty else {
                throw WorkflowIssue("Runtime was not idle after the recovery request.")
            }
            guard resolvedModelIDs == [identity, identity] else {
                throw WorkflowIssue("Expected one model resolution per real request, got \(resolvedModelIDs).")
            }

            await subject.save()
            guard subject.errorMessage == nil, !subject.hasPendingSaves else {
                throw WorkflowIssue(subject.errorMessage ?? "Cancellation acceptance still has pending saves.")
            }
            let stateAfterRuns = try await store.workflowState()
            guard let archive = stateAfterRuns.archive else {
                throw WorkflowIssue("Cancellation project has no workflow archive.")
            }
            guard archive.runs.count == 2 else {
                throw WorkflowIssue("Cancellation acceptance expected exactly two workflow runs.")
            }
            guard archive.assets.count == 2 else {
                throw WorkflowIssue("Expected one protected original asset and one recovery request asset.")
            }
            guard archive.assets.allSatisfy({ $0.stepID != cancelledRecord.id }) else {
                throw WorkflowIssue("Cancelled call published an asset after cancellation.")
            }
            let requestAssets = archive.assets.filter { $0.request != nil }
            guard requestAssets.count == 1 else {
                throw WorkflowIssue("Only the post-cancel request may be persisted as submitted output.")
            }
            let nonRequestAssets = archive.assets.filter { $0.request == nil }
            guard nonRequestAssets == [frozenOriginalRecord] else {
                throw WorkflowIssue("The protected original workflow asset record changed.")
            }
            let requestAsset = requestAssets[0]
            guard requestAsset.stepID == recoveryRecord.id,
                  requestAsset.reference == recoveryRaw,
                  requestAsset.parents.isEmpty else {
                throw WorkflowIssue("Post-cancel request provenance contains stale cancelled data.")
            }
            guard let request = requestAsset.request else {
                throw WorkflowIssue("Post-cancel request metadata is missing.")
            }
            guard request.id == recoveryRecord.id, request.model == reference else {
                throw WorkflowIssue("Post-cancel request identity or fixed model changed.")
            }
            guard case .text(let textRequest) = request.input else {
                throw WorkflowIssue("Post-cancel request is not a text request.")
            }
            guard textRequest.prompt == recoveryTask,
                  textRequest.maxTokens == 64,
                  textRequest.temperature == 0 else {
                throw WorkflowIssue("Post-cancel request contains stale or changed request fields.")
            }
            let manifestAfterRuns = await store.snapshot()
            guard manifestAfterRuns.documents.first(where: { $0.id == frozenOriginalDocument.id }) == frozenOriginalDocument else {
                throw WorkflowIssue("The protected original text document changed during cancellation or recovery.")
            }
            guard manifestAfterRuns.assets.first(where: { $0.id == frozenOriginalAsset.id }) == frozenOriginalAsset else {
                throw WorkflowIssue("The protected original project asset changed during cancellation or recovery.")
            }
            guard try await store.workflowData(frozenOriginalRecord.reference) == protectedAssetData else {
                throw WorkflowIssue("The protected original asset bytes changed during cancellation or recovery.")
            }

            subject.deactivateAfterClose()
            try await store.close()
            storeIsClosed = true
            let reopened = try await ProjectStore.open(at: project)
            reopenedStore = reopened
            let reopenedManifest = await reopened.snapshot()
            guard reopenedManifest.documents.first(where: { $0.id == frozenOriginalDocument.id }) == frozenOriginalDocument else {
                throw WorkflowIssue("The protected original text document changed after reopen.")
            }
            guard reopenedManifest.assets.first(where: { $0.id == frozenOriginalAsset.id }) == frozenOriginalAsset else {
                throw WorkflowIssue("The protected original project asset changed after reopen.")
            }
            let reopenedState = try await reopened.workflowState()
            guard reopenedState.archive == archive else {
                throw WorkflowIssue("Cancellation workflow archive changed after reopen.")
            }
            guard try await reopened.workflowData(frozenOriginalRecord.reference) == protectedAssetData else {
                throw WorkflowIssue("The protected original asset bytes changed after reopen.")
            }
            try await reopened.close()
            reopenedStore = nil
            await runtime.shutdown()
            ownedRuntime = nil
            let report: [String: Any] = [
                "case": "text-control-cancel",
                "status": "PASS",
                "driver": "AppSessionFactory + WorkflowServices + WorkflowController",
                "project": project.path,
                "elapsedSeconds": Date().timeIntervalSince(started),
                "modelRevision": reference.revision ?? "unknown",
                "observedRuntimeRunID": observation.runtimeRunID?.uuidString ?? "none",
                "observedState": observation.state?.rawValue ?? "unknown",
                "observedPhase": observation.phase ?? "unknown",
                "observedStreamedCharacterCount": observation.streamedCharacterCount,
                "cancelledRunID": cancelledRun.id.uuidString,
                "cancelledCallID": cancelledRecord.id.uuidString,
                "cancelledRequestID": observedRuntimeRunID.uuidString,
                "cancelledFinalStatus": cancelledRun.status.rawValue,
                "recoveryRunID": recoveryRun.id.uuidString,
                "recoveryCallID": recoveryRecord.id.uuidString,
                "recoveryRequestID": request.id.uuidString,
                "runtimeIdleBeforeRecovery": true,
                "runtimeIdleAfterRecovery": true,
                "protectedDocumentID": frozenOriginalDocument.id.uuidString,
                "protectedAssetID": frozenOriginalAsset.id.uuidString,
                "protectedAssetSHA256": frozenOriginalRecord.reference.sha256,
                "persistedAssetRecords": archive.assets.count,
                "persistedRequestRecords": requestAssets.count,
                "guiValidated": false,
                "offlineValidated": false,
            ]
            try writeReport(report, to: root.appendingPathComponent("real-result.json"))
            print("D_NODE_LANGUAGE_TEXT_CONTROL_CANCEL_PASS=\(root.path)")
        } catch {
            let primaryError = error
            if let task = firstTask {
                task.cancel()
                if let controller, controller.isRunning {
                    await controller.cancel()
                }
                await task.value
                firstTask = nil
            } else if let controller, controller.isRunning {
                await controller.cancel()
            }
            controller?.deactivateAfterClose()
            if let runtime = ownedRuntime {
                await runtime.shutdown()
            }
            var cleanupErrors: [String] = []
            if let reopened = reopenedStore {
                do {
                    try await reopened.close(preserveExternalChanges: true)
                } catch {
                    cleanupErrors.append("reopenedStore: " + error.localizedDescription)
                }
            }
            if !storeIsClosed {
                do {
                    try await store.close(preserveExternalChanges: true)
                } catch {
                    cleanupErrors.append("store: " + error.localizedDescription)
                }
            }
            var failureReport: [String: Any] = [
                "case": "text-control-cancel",
                "status": "FAIL",
                "error": primaryError.localizedDescription,
                "elapsedSeconds": Date().timeIntervalSince(started),
                "guiValidated": false,
                "offlineValidated": false,
            ]
            failureReport["cleanupErrors"] = cleanupErrors
            do {
                try writeReport(failureReport, to: root.appendingPathComponent("real-result-failure.json"))
            } catch {
                throw WorkflowIssue(
                    "Cancellation failure: \(primaryError.localizedDescription); cleanup: \(cleanupErrors); failure evidence write failed: \(error.localizedDescription)"
                )
            }
            throw primaryError
        }
    }

    private func acceptanceRoot(caseName: String) throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = support
            .appendingPathComponent("D/NodeLanguageAcceptance/TextControl", isDirectory: true)
            .appendingPathComponent(caseName + "-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func node(_ operationID: String, title: String) throws -> WorkflowNode {
        guard let operation = WorkflowRegistry.standard.operation(operationID) else {
            throw WorkflowIssue("Text-control acceptance requires unregistered operation \(operationID).")
        }
        var result = operation.definition.makeNode()
        result.title = title
        return result
    }

    private func languageNode(
        title: String,
        task: String,
        modelID: String,
        maximumOutputTokens: Int
    ) throws -> WorkflowNode {
        var result = try node("d.model.language", title: title)
        result.parameters["task"] = .text(task)
        result.parameters["outputMode"] = .text("text")
        result.parameters["maximumOutputTokens"] = .integer(maximumOutputTokens)
        result.parameters["temperature"] = .decimal(0)
        result.parameters["topP"] = .decimal(0.95)
        result.parameters["modelID"] = .text(modelID)
        result.dataConfiguration = .init(schema: .text)
        return result
    }

    private func languageBody(
        name: String,
        sourceText: String,
        task: String,
        modelID: String,
        maximumOutputTokens: Int
    ) throws -> BranchBody {
        var source = try node("d.text.input", title: name + " source")
        source.parameters["text"] = .text(sourceText)
        let language = try languageNode(
            title: name + " language",
            task: task,
            modelID: modelID,
            maximumOutputTokens: maximumOutputTokens
        )
        var graph = WorkflowGraph(
            name: name,
            nodes: [source, language],
            connections: [.init(sourceNode: source.id, targetNode: language.id, targetPort: "content")]
        )
        graph.interface = .init(outputs: [
            .init(name: "output", nodeID: language.id, schema: .text),
        ])
        return .init(
            graph: graph,
            sourceID: source.id,
            languageID: language.id,
            sourceText: sourceText,
            task: task
        )
    }

    private func waitForObservableExecution(
        runtime: WorkbenchSession,
        services: WorkflowServices,
        controller: WorkflowController,
        timeout: Duration
    ) async throws -> ExecutionObservation? {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var observedControllerStart = false
        while ContinuousClock.now < deadline {
            if controller.isRunning {
                observedControllerStart = true
            }
            let status = await runtime.status()
            let streamedCharacterCount = services.streamedTextCharacterCount
            let runtimeIsGenerating = status.activeRunID != nil && status.state == .generating
            let streamedWhileRuntimeIsActive = status.activeRunID != nil && streamedCharacterCount > 0
            if runtimeIsGenerating || streamedWhileRuntimeIsActive {
                return .init(
                    runtimeRunID: status.activeRunID,
                    state: status.state,
                    phase: status.phase,
                    streamedCharacterCount: streamedCharacterCount
                )
            }
            if observedControllerStart, !controller.isRunning {
                return nil
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    private func writeReport(_ report: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .withoutOverwriting)
    }
}
