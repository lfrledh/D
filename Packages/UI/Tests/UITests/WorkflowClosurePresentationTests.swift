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
        #expect(registered.phase.contains("已校验并登记") && registered.total == nil)
        record.availability = .unavailable
        #expect(WorkflowModelPreparation.make(record: record, control: control, task: nil, requiresPreparation: true).phase == "模型文件当前不可访问")
        record.availability = .available; record.state = .verifying; control.fileState = .unchecked
        #expect(WorkflowModelPreparation.make(record: record, control: control, task: nil, requiresPreparation: true).phase == "正在校验模型文件")
        record.state = .installed; record.registrationState = .unregistered; control.fileState = .verified; control.role = .execution
        #expect(WorkflowModelPreparation.make(record: record, control: control, task: nil, requiresPreparation: true).phase == "文件已校验，尚未登记")
        let state = WorkflowModelPreparationState(), missing = ModelID()
        state.replace(["model": registered], resources: [record.id: registered])
        #expect(state.value(identity: "model", installation: record.id)?.resource == registered.resource)
        #expect(state.value(identity: "model", installation: missing) == nil) // no fallback to another copy
        let task = ModelDownloadTask(resourceID: .init(rawValue: record.id.rawValue), catalogID: record.catalogID, recipeIdentity: "fixture", postAction: .filesOnly)
        let queued = WorkflowModelPreparation.make(record: record, control: control, task: task, requiresPreparation: true)
        #expect(queued.phase == "等待下载" && queued.total == nil && queued.attemptID == task.attemptID)
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
        #expect(packed.weightSummary?.contains("Q8") == true)
        let expected = ["mrt2-small-export-v1":"0.23", "ace-step-1.5-xl-sft-f32-no-lm":"4", "wan21-t2v-1.3b-bf16-v1":"1.3", "audio.singing.qixuan":"0.122", "medium":"1.4", "video.model.minimax-h3-fl2va-bf16-full-v1":"33"]
        for (id, count) in expected {
            let item = try #require(ModelNodeCatalog.entries.first { $0.id == id })
            #expect(item.parameterScale?.publishedBillions == count)
            #expect(item.parameterScale?.note?.isEmpty == false && item.weightSummary != nil)
        }
        #expect(ModelNodeCatalog.entries.first { $0.id == "video.model.ltx-2.3-dev-bf16-full-v1" }?.parameterScale?.scope == .officialPublished)
        #expect(ModelNodeCatalog.entries.first { $0.id == "sm-sfx" }?.parameterScale == nil)
        #expect(ModelNodeCatalog.entries.first { $0.id == "sm-sfx" }?.unrecordedScaleReason?.contains("433M") == true)
    }
}
