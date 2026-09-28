import AppKit
import DWorkbench
import Foundation
import SwiftUI
import Testing
@testable import UI

@Suite @MainActor
struct SharedLibraryBrowserTests {
    private func entry(
        _ key: String, title: String, kind: SharedLibraryItemKind = .program,
        inputs: Set<WorkflowDataKind> = [], outputs: Set<WorkflowDataKind> = [],
        readiness: SharedLibraryReadiness = .available,
        compatible: Bool? = true,
        selection: SharedLibraryBrowserSelection? = nil
    ) -> SharedLibraryBrowserEntry {
        SharedLibraryBrowserEntry(
            item: SharedLibraryItem(
                key: key, title: title, kind: kind, inputs: inputs, outputs: outputs,
                readiness: readiness, compatible: compatible
            ),
            selection: selection ?? .operation(id: key, modelID: nil)
        )
    }

    @Test
    func realStoreScopesAndIndependentInputOutputFilters() throws {
        let store = try SharedLibraryStore()
        let text = entry("operation:text", title: "文字草稿", inputs: [.text], outputs: [.text])
        let image = entry("operation:image", title: "图像草稿", inputs: [.image], outputs: [.image])
        let both = entry("operation:both", title: "组合", inputs: [.text, .image], outputs: [.image])
        let entries = [text, image, both]
        let tagID = try #require(store.createTags(["常用"]).first)
        try store.addTags([tagID], to: [text.id, both.id])
        let folderID = try store.createFolder(name: "收藏")
        try store.addMembers([image.id, both.id], to: folderID)
        let savedID = try store.createSavedQuery(
            name: "图像输入", query: SharedLibraryQuery(inputs: [.image])
        )

        let query = SharedLibraryQuery(inputs: [.text], outputs: [.image])
        #expect(try SharedLibraryBrowserLogic.visibleEntries(
            entries, store: store, query: query, scope: .all
        ).map(\.id) == [both.id])
        #expect(try SharedLibraryBrowserLogic.visibleEntries(
            entries, store: store, query: .init(), scope: .tag(tagID)
        ).map(\.id) == [text.id, both.id])
        #expect(try SharedLibraryBrowserLogic.visibleEntries(
            entries, store: store, query: .init(), scope: .folder(folderID)
        ).map(\.id) == [image.id, both.id])
        #expect(try SharedLibraryBrowserLogic.visibleEntries(
            entries, store: store, query: .init(), scope: .kind(.program)
        ).count == 3)
        let savedQuery = try #require(store.metadata.savedQueries[savedID]?.query)
        #expect(try SharedLibraryBrowserLogic.visibleEntries(
            entries, store: store, query: savedQuery, scope: .saved(savedID)
        ).map(\.id) == [image.id, both.id])
        #expect(throws: SharedLibraryError.missingFolder) {
            try SharedLibraryBrowserLogic.visibleEntries(
                entries, store: store, query: .init(), scope: .folder(UUID())
            )
        }
    }

    @Test
    func savingScopePreservesIntersectionAndRejectsUnrepresentableCases() throws {
        let store = try SharedLibraryStore()
        let firstTag = try #require(store.createTags(["第一"]).first)
        let secondTag = try #require(store.createTags(["第二"]).first)
        let both = entry("model:both", title: "两种标签", kind: .model)
        let firstOnly = entry("model:first", title: "第一标签", kind: .model)
        let secondOnly = entry("model:second", title: "第二标签", kind: .model)
        let asset = entry("asset:other", title: "素材", kind: .asset)
        let entries = [both, firstOnly, secondOnly, asset]
        try store.addTags([firstTag, secondTag], to: [both.id])
        try store.addTags([firstTag], to: [firstOnly.id])
        try store.addTags([secondTag], to: [secondOnly.id])

        let models = try SharedLibraryBrowserLogic.queryForSaving(
            .init(), scope: .kind(.model), store: store
        )
        #expect(models.kinds == [.model])
        let modelQueryID = try store.createSavedQuery(name: "仅模型", query: models)
        let reopenedModels = try #require(store.metadata.savedQueries[modelQueryID]?.query)
        #expect(store.filter(entries.map(\.item), query: reopenedModels).map(\.key)
            == [both.id, firstOnly.id, secondOnly.id])

        let tagQuery = try SharedLibraryBrowserLogic.queryForSaving(
            .init(anyTagIDs: [secondTag]), scope: .tag(firstTag), store: store
        )
        #expect(tagQuery.allTagIDs == [firstTag])
        #expect(tagQuery.anyTagIDs == [secondTag])
        #expect(store.filter(entries.map(\.item), query: tagQuery).map(\.key) == [both.id])
        #expect(throws: SharedLibraryBrowserIssue.conflictingKindScope) {
            try SharedLibraryBrowserLogic.queryForSaving(
                .init(kinds: [.asset]), scope: .kind(.model), store: store
            )
        }
        let folderID = try store.createFolder(name: "手工分类")
        #expect(throws: SharedLibraryBrowserIssue.folderCannotBeSaved) {
            try SharedLibraryBrowserLogic.queryForSaving(
                .init(), scope: .folder(folderID), store: store
            )
        }
    }

    @Test
    func renameDraftsSurviveSelectionReturnAndDeletedScopesRepairWithoutReset() throws {
        let tagID = UUID(), folderID = UUID(), queryID = UUID()
        var drafts = SharedLibraryBrowserRenameDrafts()
        drafts.set("标签草稿", for: .tag(tagID))
        drafts.set("分类草稿", for: .folder(folderID))
        drafts.set("筛选草稿", for: .saved(queryID))
        #expect(drafts.text(for: .tag(tagID), canonical: "旧标签") == "标签草稿")
        #expect(drafts.text(for: .folder(folderID), canonical: "旧分类") == "分类草稿")
        #expect(drafts.text(for: .saved(queryID), canonical: "旧筛选") == "筛选草稿")
        #expect(drafts.text(for: .tag(tagID), canonical: "旧标签") == "标签草稿")
        drafts.clear(.folder(folderID))
        #expect(drafts.text(for: .folder(folderID), canonical: "已改名") == "已改名")

        let store = try SharedLibraryStore()
        let realTagID = try #require(store.createTags(["可删"]).first)
        let parentID = try store.createFolder(name: "父")
        let childID = try store.createFolder(name: "子", parentID: parentID)
        let savedID = try store.createSavedQuery(name: "可删筛选", query: .init())
        let state = SharedLibraryBrowserState(
            query: .init(text: "保留搜索", anyTagIDs: [realTagID]), scope: .tag(realTagID),
            selectedKeys: ["entry:one"], focusedKey: "entry:one"
        )
        try SharedLibraryBrowserLogic.deleteTag(realTagID, store: store, state: state)
        #expect(state.scope == .all)
        #expect(state.query.anyTagIDs.isEmpty)
        state.scope = .folder(childID)
        try SharedLibraryBrowserLogic.deleteFolder(parentID, store: store, state: state)
        #expect(state.scope == .all)
        state.scope = .saved(savedID)
        try SharedLibraryBrowserLogic.deleteSavedQuery(savedID, store: store, state: state)
        #expect(state.scope == .all)
        let protectedTagID = try #require(store.createTags(["受保护"]).first)
        _ = try store.createSavedQuery(
            name: "引用标签", query: .init(allTagIDs: [protectedTagID])
        )
        state.scope = .tag(protectedTagID)
        #expect(throws: SharedLibraryError.tagInSavedQuery) {
            try SharedLibraryBrowserLogic.deleteTag(protectedTagID, store: store, state: state)
        }
        #expect(state.scope == .tag(protectedTagID))
        #expect(state.query.text == "保留搜索")
        #expect(state.selectedKeys == ["entry:one"])
        #expect(state.focusedKey == "entry:one")
    }

    @Test
    func dropRequiresCurrentEntryKeysAndCanvasPayloadKeepsProjectScope() throws {
        let projectID = UUID(), assetID = UUID()
        let asset = entry(
            "asset:\(projectID):\(assetID)", title: "素材", kind: .asset,
            selection: .asset(projectID: projectID, assetID: assetID)
        )
        let program = entry("operation:known", title: "程序")
        let entries = [asset, program]
        #expect(SharedLibraryBrowserLogic.validatedDropKeys(
            [asset.id, program.id], entries: entries
        ) == Set([asset.id, program.id]))
        #expect(SharedLibraryBrowserLogic.validatedDropKeys(
            ["file:///untrusted"], entries: entries
        ) == nil)
        #expect(SharedLibraryBrowserLogic.validatedDropKeys(
            [asset.id, "missing"], entries: entries
        ) == nil)
        #expect(SharedLibraryBrowserLogic.validatedDropKeys(
            [asset.id, asset.id], entries: entries
        ) == nil)
        let payload = try #require(SharedLibraryBrowserLogic.canvasTransfer(for: asset))
        #expect(try WorkflowCanvasTransfer.decode(payload.encoded())
            == .asset(projectID: projectID, assetID: assetID))
        #expect(SharedLibraryBrowserLogic.canvasTransfer(
            for: entry("unknown", title: "未知", readiness: .unknown)
        ) == nil)
    }

    @Test
    func actionPolicyHandlesEveryReadinessWithoutExecuting() {
        let modelSelection: SharedLibraryBrowserSelection = .operation(
            id: "d.image.generate", modelID: "model:exact"
        )
        for readiness in [SharedLibraryReadiness.available, .unprepared, .unknown] {
            let model = entry(
                "model:exact", title: "模型", kind: .model,
                readiness: readiness, selection: modelSelection
            )
            #expect(SharedLibraryBrowserLogic.allows(.use, entry: model))
            #expect(SharedLibraryBrowserLogic.allows(.add, entry: model))
            #expect(SharedLibraryBrowserLogic.allows(.prepare, entry: model)
                == (readiness != .available))
            #expect(SharedLibraryBrowserLogic.canvasTransfer(for: model)
                == .operation(id: "d.image.generate", modelID: "model:exact"))
        }
        for readiness in [SharedLibraryReadiness.unavailable, .unsupported] {
            let model = entry(
                "model:exact", title: "模型", kind: .model,
                readiness: readiness, selection: modelSelection
            )
            #expect(!SharedLibraryBrowserLogic.allows(.use, entry: model))
            #expect(!SharedLibraryBrowserLogic.allows(.add, entry: model))
            #expect(SharedLibraryBrowserLogic.allows(.prepare, entry: model))
            #expect(SharedLibraryBrowserLogic.canvasTransfer(for: model) == nil)
        }
        let genericUnknown = entry(
            "model:generic", title: "泛用入口", kind: .model, readiness: .unknown,
            selection: .operation(id: "d.image.generate", modelID: nil)
        )
        #expect(!SharedLibraryBrowserLogic.quickUseAllowed(genericUnknown))
        let incompatible = entry(
            "model:incompatible", title: "不兼容", kind: .model, readiness: .available,
            compatible: false, selection: modelSelection
        )
        #expect(!SharedLibraryBrowserLogic.allows(.use, entry: incompatible))
        #expect(!SharedLibraryBrowserLogic.allows(.add, entry: incompatible))
        #expect(SharedLibraryBrowserLogic.allows(.prepare, entry: incompatible))
        #expect(SharedLibraryBrowserLogic.canvasTransfer(for: incompatible) == nil)

        let projectID = UUID(), assetID = UUID()
        for readiness in SharedLibraryReadiness.allCases {
            let asset = entry(
                "asset:test", title: "素材", kind: .asset, readiness: readiness,
                selection: .asset(projectID: projectID, assetID: assetID)
            )
            let expected = readiness == .available || readiness == .unknown
            #expect(SharedLibraryBrowserLogic.allows(.preview, entry: asset) == expected)
            #expect(SharedLibraryBrowserLogic.allows(.add, entry: asset) == expected)
            #expect(SharedLibraryBrowserLogic.allows(.prepare, entry: asset)
                == (readiness != .available))
            #expect((SharedLibraryBrowserLogic.canvasTransfer(for: asset) != nil) == expected)
        }
    }

    @Test
    func compactDetailAndCallbacksResolveCurrentEntryByKey() {
        let old = entry("model:same", title: "旧名称", kind: .model)
        let current = entry(
            "model:same", title: "现名称", kind: .model, readiness: .unknown,
            selection: .operation(id: "d.image.generate", modelID: "model:same")
        )
        #expect(SharedLibraryBrowserLogic.detailEntry(key: old.id, entries: [current]) == current)
        #expect(SharedLibraryBrowserLogic.currentEntry(
            key: old.id, entries: [current], action: .use
        ) == current)
        let unsupported = entry(
            "model:same", title: "不支持", kind: .model, readiness: .unsupported,
            selection: current.selection
        )
        #expect(SharedLibraryBrowserLogic.currentEntry(
            key: old.id, entries: [unsupported], action: .use
        ) == nil)
        #expect(SharedLibraryBrowserLogic.detailEntry(key: old.id, entries: []) == nil)
        #expect(SharedLibraryBrowserLogic.currentEntry(
            key: old.id, entries: [], action: .add
        ) == nil)
    }

    @Test
    func fullAndCompactHostingRetainCallerStateAndInvokeNoActions() throws {
        let store = try SharedLibraryStore()
        let item = entry("operation:one", title: "一个程序")
        let second = entry("operation:two", title: "另一个程序")
        let query = SharedLibraryQuery(text: "一个")
        let fullState = SharedLibraryBrowserState(
            query: query, scope: .all, selectedKeys: [item.id], focusedKey: item.id
        )
        let compactState = SharedLibraryBrowserState(
            query: query, scope: .all, selectedKeys: [item.id], focusedKey: item.id
        )
        var useCount = 0, addCount = 0, previewCount = 0, prepareCount = 0
        var importCount = 0, closeCount = 0
        for compact in [false, true] {
            let state = compact ? compactState : fullState
            let browser = SharedLibraryBrowser(
                entries: [item, second], store: store, compact: compact, state: state,
                onUse: { _ in useCount += 1 },
                onAdd: { _ in addCount += 1 },
                onPreview: { _ in previewCount += 1 },
                onPrepare: { _ in prepareCount += 1 },
                onImport: { importCount += 1 },
                onClose: { closeCount += 1 }
            )
            let host = NSHostingView(rootView: browser)
            host.frame = CGRect(x: 0, y: 0, width: compact ? 240 : 850, height: 550)
            host.layoutSubtreeIfNeeded()
            #expect(state.query == query)
            #expect(state.selectedKeys == [item.id])
            #expect(state.focusedKey == item.id)
            #expect(state.scope == .all)
            state.selectedKeys = [second.id]
            state.focusedKey = second.id
            let reopened = SharedLibraryBrowser(
                entries: [item, second], store: store, compact: compact, state: state,
                onUse: { _ in useCount += 1 },
                onAdd: { _ in addCount += 1 },
                onPreview: { _ in previewCount += 1 },
                onPrepare: { _ in prepareCount += 1 },
                onImport: { importCount += 1 },
                onClose: { closeCount += 1 }
            )
            host.rootView = reopened
            host.layoutSubtreeIfNeeded()
            #expect(state.query == query)
            #expect(state.selectedKeys == [second.id])
            #expect(state.focusedKey == second.id)
        }
        #expect(useCount == 0 && addCount == 0 && previewCount == 0)
        #expect(prepareCount == 0 && importCount == 0 && closeCount == 0)
    }
}
