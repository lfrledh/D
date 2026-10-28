import DWorkbench
import Foundation
import Observation
import Synchronization
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


extension WorkflowClosurePresentationTests {
    @Test func batchReviewCopyDistinguishesAssetsFromHumanForms() throws {
        let registry = WorkflowRegistry.standard
        let candidates = registry.definitions.filter { $0.interaction == .candidateReview }
        let textReviews = registry.definitions.filter { $0.interaction == .textReview }
        #expect(!candidates.isEmpty && !textReviews.isEmpty)
        let language = UILanguageStore(preferredLanguages: ["zh-Hans"])
        for definition in candidates + textReviews {
            var step = WorkflowStepRun(node: .init(operationID: definition.id, title: "用户标题 / unchanged"), signature: "frozen-signature")
            step.status = .waiting
            let original = step
            let key = WorkflowBatchPanel.reviewActionKey(for: step, registry: registry)
            #expect(key == (definition.interaction == .candidateReview ? "reviewGate" : "reviewHumanGate"))
            for locale in ["zh-Hans", "en"] {
                try language.select(locale)
                let label = workspaceText(language, key)
                #expect(label == language.text("metadata.panel.workspace." + key, fallback: "MISSING"))
                #expect(!label.isEmpty && label != "MISSING" && step == original)
            }
            for kind in WorkflowHumanTaskKind.allCases {
                step.humanTask = .init(id: UUID(), kind: kind, title: "人工原文", materials: .text("unchanged"), resultSchema: .text)
                let withTask = step
                #expect(WorkflowBatchPanel.reviewActionKey(for: step, registry: registry) == "reviewHumanGate")
                #expect(step == withTask)
            }
        }
        let unknown = WorkflowStepRun(node: .init(operationID: "unknown.operation", title: "Unknown"), signature: "original")
        #expect(WorkflowBatchPanel.reviewActionKey(for: unknown, registry: registry) == "reviewHumanGate")
    }
}


extension WorkflowClosurePresentationTests {
    @Test func modelFieldsAlwaysShowBothFactsWithoutGuessingVersionsOrComponentCounts() throws {
        let language = UILanguageStore(preferredLanguages: ["zh-Hans"])
        let known = try #require(ModelNodeCatalog.entries.first { $0.modelIdentity == "Qwen/Qwen3.5-9B" })
        let wrongRevision = ModelNodeDescriptor(id: known.id, modality: known.modality, title: "User 999B Q8",
            summary: known.summary, modelIdentity: known.modelIdentity, revision: "unreviewed-v99",
            engine: known.engine, device: known.device, precision: "Version 99, input FP32",
            availability: known.availability, deploymentNote: known.deploymentNote,
            operations: known.operations, notes: known.notes, evidencePaths: known.evidencePaths)
        for locale in ["zh-Hans", "en"] {
            try language.select(locale)
            for descriptor in ModelNodeCatalog.entries {
                let fields = ModelSpecificationPresentation(descriptor: descriptor, language: language)
                #expect(fields.parameterLabel == (locale == "en" ? "Parameter count" : "参数量"))
                #expect(fields.precisionLabel == (locale == "en" ? "Quantization / precision" : "量化精度"))
                #expect(!fields.parameterValue.isEmpty && !fields.precisionValue.isEmpty)
                #expect(!fields.parameterValue.contains("model.spec.") && !fields.precisionValue.contains("model.spec."))
            }
            for descriptor in [nil, wrongRevision] {
                let fields = ModelSpecificationPresentation(descriptor: descriptor, language: language)
                #expect(fields.parameterValue == workflowText(language, "model.spec.unrecorded"))
                #expect(fields.precisionValue == workflowText(language, "model.spec.unrecorded"))
            }
            let original = ModelSpecificationPresentation(descriptor: known, language: language)
            #expect(original.parameterValue == "9B · " + workspaceText(language, "languageParameters"))
            #expect(original.precisionValue == "BF16")
            let mixed = try #require(ModelNodeCatalog.entries.first { $0.id == "video.model.ltx-2.3-dev-q8-gemma3-q4-test-v1" })
            #expect(ModelSpecificationPresentation(descriptor: mixed, language: language).precisionValue == workflowText(language, "model.spec.weight.ltxMixed"))
            let vocoder = try #require(ModelNodeCatalog.entries.first { $0.id == "audio.singing.qixuan" })
            #expect(ModelSpecificationPresentation(descriptor: vocoder, language: language).parameterValue == "0.122B · " + workspaceText(language, "vocoderParameters"))
            let inputOnly = try #require(ModelNodeCatalog.entries.first { $0.id == "swift-f0-0.1.2-cpu-v1" })
            #expect(ModelSpecificationPresentation(descriptor: inputOnly, language: language).precisionValue == workflowText(language, "model.spec.weight.inputOnly"))
        }
        #expect(known.modelIdentity == "Qwen/Qwen3.5-9B" && wrongRevision.title == "User 999B Q8")
    }
}


extension WorkflowClosurePresentationTests {
    @Test func modelProgressCellsShareExactIdentityWithoutWakingOtherModel() {
        let state = WorkflowModelPreparationState(), record = ModelID()
        let a = state.cell(identity: "A", installation: nil)
        let anotherA = state.cell(identity: "A", installation: nil)
        let b = state.cell(identity: "B", installation: nil)
        let exact = state.cell(identity: "A", installation: record)
        #expect(a === anotherA)
        let changesA = Mutex(0), changesB = Mutex(0), changesExact = Mutex(0)
        withObservationTracking { _ = a.value } onChange: { changesA.withLock { $0 += 1 } }
        withObservationTracking { _ = b.value } onChange: { changesB.withLock { $0 += 1 } }
        withObservationTracking { _ = exact.value } onChange: { changesExact.withLock { $0 += 1 } }
        let progress = WorkflowModelPreparation(resource: .init(), taskID: UUID(), attemptID: UUID(), phase: "downloading", completed: 3, total: 5, issue: nil)
        state.replace(["A": progress], resources: [:])
        #expect(changesA.withLock { $0 } == 1)
        #expect(changesB.withLock { $0 } == 0 && changesExact.withLock { $0 } == 0)
        #expect(exact.value == nil) // An explicit missing copy never falls back.
        let ready = WorkflowModelPreparation(resource: progress.resource, taskID: progress.taskID, attemptID: progress.attemptID, phase: "registered", completed: nil, total: nil, issue: nil)
        state.replace(["A": ready], resources: [:])
        #expect(a.value == ready)
        #expect(state.cell(identity: "A", installation: nil).value == ready)
        #expect(b.value == nil)
    }

    @Test func approvedB2CopyIsAvailableInBothLanguagesAndDoesNotAlterIdentity() throws {
        let language = UILanguageStore(preferredLanguages: ["zh-Hans"])
        let keys = ["local.original", "local.copy", "local.copyRegister", "local.originalUnsupported", "local.registered", "local.copied", "missingFiles", "offlineDrive", "fileAuthorization", "multipleFiles", "recordChanged", "tokenizerExternal", "refreshAvailability.help"]
        for locale in ["zh-Hans", "en"] {
            try language.select(locale)
            for key in keys { #expect(language.text("modelManagement." + key, fallback: "MISSING") != "MISSING") }
            #expect(language.text("modelManagement.local.size", fallback: "MISSING", arguments: ["size": "9.1 GB"]).contains("9.1 GB"))
        }
    }
}
