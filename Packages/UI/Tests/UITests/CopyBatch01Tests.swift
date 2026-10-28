import AppKit
import Testing
@testable import DWorkbench
@testable import UI

@Suite(.serialized) @MainActor struct CopyBatch01Tests {
    @Test func taskCopyDistinguishesTransferFromQueuePauseAndVerification() {
        let cases: [(ModelDownloadState, String)] = [(.downloading, "downloading"), (.queued, "queued"), (.paused, "paused")]
        for (state, suffix) in cases {
            #expect(ModelAcquisitionPresentation.taskMessageKey(state) == "existingTask." + suffix)
        }
        for state in [ModelDownloadState.verifying, .publishing, .waitingRetry, .failed, .completed, .cancelled] {
            #expect(ModelAcquisitionPresentation.taskMessageKey(state) == "existingTask")
            #expect(ModelAcquisitionPresentation.taskActionKey(state) == "viewTask")
        }
        #expect(ModelAcquisitionPresentation.taskActionKey(.downloading) == "viewProgress")
        #expect(ModelAcquisitionPresentation.taskActionKey(.queued) == "viewTask")
        #expect(ModelAcquisitionPresentation.taskActionKey(.paused) == "viewTask")
        #expect(ModelAcquisitionPresentation.existingUseKey(registered: true) == "useRegistered")
        #expect(ModelAcquisitionPresentation.existingUseKey(registered: false) == "useExisting")
        #expect(ModelAcquisitionPresentation.queueHeld(.paused, hasUnfinishedTasks: false))
        #expect(ModelAcquisitionPresentation.queueHeld(.waitingForResume, hasUnfinishedTasks: true))
        #expect(!ModelAcquisitionPresentation.queueHeld(.waitingForResume, hasUnfinishedTasks: false))
        #expect(!ModelAcquisitionPresentation.queueHeld(.running, hasUnfinishedTasks: true))
    }

    @Test func partialDownloadProgressIsNotVerifiedReusableData() {
        let entry = ModelCatalogEntry(id: "copy", title: "Fixture", repository: "fixture/copy", revision: "fixed",
            files: [.init(path: "file", size: 100, sha256: String(repeating: "a", count: 64))])
        var record = ModelRecord(id: .init(), catalogID: entry.id, revision: entry.revision, storage: .managed,
            state: .paused, availability: .available, downloadedBytes: 0, totalBytes: 100, error: nil,
            directory: nil, activeLeaseCount: 0, registrationState: .unregistered)
        var control = ModelResourceControl(fileState: .partial, origin: .download)
        #expect(ModelLibraryModel.additionalDownloadBytes(entry, resource: nil) == 100)
        #expect(ModelLibraryModel.additionalDownloadBytes(entry, resource: .init(record: record, control: control)) == 100)
        for count: UInt64 in [1, 50, 100, 101] {
            record.downloadedBytes = count
            #expect(ModelLibraryModel.additionalDownloadBytes(entry, resource: .init(record: record, control: control)) == nil)
        }
        record.downloadedBytes = 100; control.fileState = .verified
        #expect(ModelLibraryModel.additionalDownloadBytes(entry, resource: .init(record: record, control: control)) == 0)
    }

    @Test func approvedTemplatesKeepCountsAndPendingSettingsSeparate() throws {
        let language = UILanguageStore(preferredLanguages: ["zh-Hans"])
        func t(_ key: String, _ arguments: [String: String] = [:]) -> String {
            workflowText(language, key, arguments: arguments)
        }
        #expect(t("container.batch", ["index": "3"]) == "批次 3")
        #expect(t("container.perInput", ["count": "4"]) == "每份输入重复次数：4")
        #expect(t("container.runCount", ["inputs": "2", "repetitions": "4", "total": "8"]) == "2份输入 × 每份4次＝后续运行8次")
        #expect(t("container.confirm", ["count": "2"]) == "确认选择（2项）")
        #expect(t("container.arrived", ["count": "6"]) == "已收到6项")
        #expect(t("container.saveSettings") == "保存设置")
        #expect(t("metadata.panel.workspace.saveOnly") == "重试保存")
        #expect(t("container.collectionDefaultDestination") == "不添加标签直接保存")
        #expect(t("container.library.collected") == "已保存到资产库")
        #expect(t("container.collectionSettings") == "设置")
        #expect(t("container.collectConfirmed") == "自动将合格候选保存到项目资产库")
        #expect(t("container.otherGates.pending") != t("container.otherGates.saved"))
        #expect(t("container.enlarge") != t("container.viewFullContent"))
        try language.select("en")
        #expect(t("container.batch", ["index": "3"]) == "Batch 3")
        #expect(t("container.runCount", ["inputs": "2", "repetitions": "4", "total": "8"]) == "2 inputs × 4 repetitions each = 8 downstream runs")
        #expect(t("container.useContinue", ["count": "2"]) == "Use Selected Items and Continue (2)")
        #expect(t("modelAcquisition.available", ["selected": "3", "available": "1"]) == "3 selected; 1 can be downloaded now.")
        #expect(t("container.collectionDefaultDestination") == "Save without adding tags")
        #expect(language.diagnostics.isEmpty)
    }

    @Test func nativeImportWarningTracksActualModeAndRetainsSelectionAcrossLanguage() async throws {
        let language = UILanguageStore(preferredLanguages: ["zh-Hans"])
        let panel = NSOpenPanel()
        // Keep a real panel-owned accessory, but do not present a file dialog in a component test.
        let live = NativeAssetImportAccessory(panel: panel, language: language)
        #expect(live.picker.indexOfSelectedItem == 0 && live.note.isHidden)
        live.picker.selectItem(at: 1); live.selectionChanged()
        #expect(!live.note.isHidden && live.picker.titleOfSelectedItem == "使用原文件（不复制）")
        try language.select("en")
        for _ in 0..<20 where live.picker.titleOfSelectedItem != "Use Original File (Do Not Copy)" { await Task.yield() }
        #expect(live.picker.indexOfSelectedItem == 1 && !live.note.isHidden)
        #expect(live.picker.titleOfSelectedItem == "Use Original File (Do Not Copy)")
        #expect(panel.title == "Import Asset" && panel.prompt == "Choose File…")
        live.picker.selectItem(at: 0); live.selectionChanged()
        #expect(live.note.isHidden && live.picker.titleOfSelectedItem == "Copy to Project (Default)")
    }
}
