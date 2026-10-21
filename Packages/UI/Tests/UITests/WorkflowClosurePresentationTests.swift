import DWorkbench
import Foundation
import Testing
@testable import UI

@Suite @MainActor struct WorkflowClosurePresentationTests {
    @Test func preparationUsesExactCopyAndTruthfulStages() throws {
        var record = ModelRecord(id: .init(), catalogID: "fixture", revision: "fixed", storage: .external,
            state: .installed, availability: .available, downloadedBytes: 100, totalBytes: 100,
            error: nil, directory: nil, activeLeaseCount: 0)
        var control = ModelResourceControl(fileState: .verified, origin: .local)
        let registered = WorkflowModelPreparation.make(record: record, control: control, task: nil, requiresPreparation: true)
        #expect(registered.phase == "registered" && registered.total == nil)
        record.availability = .unavailable
        #expect(WorkflowModelPreparation.make(record: record, control: control, task: nil, requiresPreparation: true).phase == "unavailable")
        record.availability = .available; record.state = .verifying; control.fileState = .unchecked
        #expect(WorkflowModelPreparation.make(record: record, control: control, task: nil, requiresPreparation: true).phase == "verifyingModel")
        record.state = .installed; record.registrationState = .unregistered; control.fileState = .verified; control.role = .execution
        #expect(WorkflowModelPreparation.make(record: record, control: control, task: nil, requiresPreparation: true).phase == "unregistered")
        let state = WorkflowModelPreparationState(), missing = ModelID()
        state.replace(["model": registered], resources: [record.id: registered])
        #expect(state.value(identity: "model", installation: record.id)?.resource == registered.resource)
        #expect(state.value(identity: "model", installation: missing) == nil) // no fallback to another copy
        let task = ModelDownloadTask(resourceID: .init(rawValue: record.id.rawValue), catalogID: record.catalogID, recipeIdentity: "fixture", postAction: .filesOnly)
        let queued = WorkflowModelPreparation.make(record: record, control: control, task: task, requiresPreparation: true)
        #expect(queued.phase == "queued" && queued.total == nil && queued.attemptID == task.attemptID)
    }
    @Test func readOnlyDecodedLegacyContentDoesNotBecomeAnInlineReceiver() throws {
        let datum = try WorkflowNoteSequence(clock: .seconds, notes: [], duration: 1, sources: []).datum()
        #expect(WorkflowValueCompatibility.consumers(.data(datum), language: nil).contains { $0.result.status == .direct })
        #expect(WorkflowValueCompatibility.registeredAssetConsumers(nil, decoded: datum, plans: [], tools: [], language: nil).isEmpty)
        let ref = WorkflowAssetReference(projectID: UUID(), assetID: UUID(), version: UUID(), kind: .notes, sha256: String(repeating: "a", count: 64))
        let registered = WorkflowValueCompatibility.registeredAssetConsumers(ref, decoded: datum, plans: [], tools: [], language: nil)
        #expect(registered.contains { $0.operationID == "d.music.render" && $0.result.status == .direct })
        #expect(!registered.contains { $0.operationID == "d.value.field" && $0.result.status == .direct })
    }
    @Test func modelScaleKeepsExactRevisionAndComponentMeaning() throws {
        let original = try #require(ModelNodeCatalog.entries.first { $0.modelIdentity == "Qwen/Qwen3.5-9B" })
        let scale = try #require(original.parameterScale)
        #expect(scale.publishedBillions == "9" && scale.scope == .languageModel && scale.activeBillions == nil)
        #expect(ModelNodeCatalog.parameterScale(modelIdentity: original.modelIdentity, revision: "unknown") == nil)
        #expect(ModelNodeUILocalization.display(original, language: UILanguageStore(preferredLanguages: ["en"])).parameterScale == scale)
        let packed = try #require(ModelNodeCatalog.entries.first { $0.id == "flux2-klein-4b-q8" })
        #expect(packed.parameterScale == nil) // no inference from packed count or display name
        #expect(packed.weightSummary == "model.spec.weight.q8Compute")
        let expected = ["mrt2-small-export-v1":"0.23", "ace-step-1.5-xl-sft-f32-no-lm":"4", "wan21-t2v-1.3b-bf16-v1":"1.3", "audio.singing.qixuan":"0.122", "medium":"1.4", "video.model.minimax-h3-fl2va-bf16-full-v1":"33"]
        for (id, count) in expected {
            let item = try #require(ModelNodeCatalog.entries.first { $0.id == id })
            #expect(item.parameterScale?.publishedBillions == count)
            #expect(item.parameterScale?.noteKey?.isEmpty == false && item.weightSummary != nil)
        }
        #expect(ModelNodeCatalog.entries.first { $0.id == "video.model.ltx-2.3-dev-bf16-full-v1" }?.parameterScale?.scope == .officialPublished)
        #expect(ModelNodeCatalog.entries.first { $0.id == "sm-sfx" }?.parameterScale == nil)
        #expect(ModelNodeCatalog.entries.first { $0.id == "sm-sfx" }?.unrecordedScaleReasonKey == "model.spec.unknown.stableAudioConflict")
    }
}

extension WorkflowClosurePresentationTests {
    @Test func dynamicCopyUsesResourcesWhileFactsAndUserTextRemainUnchanged() throws {
        let language = UILanguageStore(preferredLanguages: ["zh-Hans"])
        let message = WorkflowProgressMessage("candidateProgress", ["index": "2", "count": "3", "completed": "5", "total": "8"])
        let chinese = workflowProgressText(message, language: language)
        try language.select("en")
        #expect(workflowProgressText(message, language: language) == "Candidate 2/3 · 5/8")
        #expect(chinese == "候选 2/3 · 5/8" && message.arguments["index"] == "2")
        let phases = ["unavailable", "authorization", "verifyingModel", "publishingModel", "failedModel", "queued", "downloading", "verifying", "publishing", "waitingRetry", "paused", "failed", "cancelled", "unknown", "partial", "unchecked", "invalid", "deleting", "deleted", "registering", "registered", "prepareExecution", "unregistered"]
        for locale in ["en", "zh-Hans"] {
            try language.select(locale)
            for phase in phases { #expect(language.text("workflow.preparation." + phase, fallback: "MISSING") != "MISSING") }
            for state in JobState.allCases { #expect(language.text("workflow.jobStatus." + state.rawValue, fallback: "MISSING") != "MISSING") }
            #expect(language.text("workbench.seedValue", fallback: "MISSING", arguments: ["seed": "18446744073709551615"]).contains("18446744073709551615"))
            for code in ["start", "editingCopy", "toolSaved", "toolVersionSaved", "toolAdded", "workflowSaved", "waitingDecision", "paused", "runSaved", "pausePending", "batchPausePending", "failed", "savePending", "cancelled", "cancelling", "rejected", "resultSaved", "decisionSaved", "rejectedEmpty", "candidatesRetried", "preparingContext", "savingResult", "rewritingPreview", "generatingCandidate", "candidateProgress"] {
                #expect(language.text("workflow.progress." + code, fallback: "MISSING") != "MISSING")
            }
            for descriptor in ModelNodeCatalog.entries {
                for key in [descriptor.parameterScale?.noteKey, descriptor.unrecordedScaleReasonKey, descriptor.weightSummary?.hasPrefix("model.spec.") == true ? descriptor.weightSummary : nil].compactMap({ $0 }) {
                    #expect(language.text(key, fallback: "MISSING") != "MISSING")
                }
            }
        }
        let matches = WorkflowValueCompatibility.consumers(.data(.text("用户原文 {index} é")), language: nil)
        let target = try #require(matches.first { $0.operationID == "d.text.template" })
        let immutable = target.result
        try language.select("en"); let english = target.displayTitle(language)
        try language.select("zh-Hans"); let translated = target.displayTitle(language)
        #expect(english != translated && target.result == immutable && target.operationID == "d.text.template")
        let facade = WorkbenchModel(projectSession: ProjectSession(sessionFactory: { _ in throw WorkflowIssue("unused") }), language: language)
        #expect(facade.language === language)
    }

    @Test func metadataFailuresTranslateWithoutRewritingUserNamesOrRawDiagnostics() throws {
        let language = UILanguageStore(preferredLanguages: ["zh-Hans"])
        let raw = "private/path {name} e\u{301}"
        let errors: [SharedLibraryError] = [.invalidName, .duplicateName(raw), .missingTag, .missingFolder, .missingQuery,
            .invalidKey, .invalidReference, .folderCycle, .folderDepth, .invalidMembership, .tagInSavedQuery,
            .limitExceeded(raw), .unsupportedSchema(9), .corruptedMetadata(raw), .invalidFileURL,
            .externalChange, .staleTagEdit, .staleAnnotation, .invalidProperty]
        let chinese = errors.map { sharedLibraryErrorText($0, language: language) }
        try language.select("en")
        for (i, error) in errors.enumerated() {
            let english = sharedLibraryErrorText(error, language: language)
            #expect(!english.isEmpty && english != "—" && english != chinese[i])
        }
        #expect(sharedLibraryErrorText(SharedLibraryError.duplicateName(raw), language: language).utf8.suffix(raw.utf8.count).elementsEqual(raw.utf8))
        #expect(sharedLibraryErrorText(WorkflowIssue(raw), language: language) == raw)
        #expect(sharedLibraryErrorText(SharedLibraryError.corruptedMetadata(raw), language: language).hasSuffix(raw))
    }
}
