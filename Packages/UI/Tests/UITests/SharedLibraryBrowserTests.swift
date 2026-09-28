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
        selection: SharedLibraryBrowserSelection? = nil
    ) -> SharedLibraryBrowserEntry {
        SharedLibraryBrowserEntry(
            item: SharedLibraryItem(
                key: key, title: title, kind: kind, inputs: inputs, outputs: outputs,
                readiness: readiness, compatible: true
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
    func unknownExactModelCanOnlySelectDraft() {
        let exact = entry(
            "model:exact", title: "待确认模型", kind: .model, readiness: .unknown,
            selection: .operation(id: "d.image.generate", modelID: "model:exact")
        )
        let generic = entry(
            "model:generic", title: "泛用入口", kind: .model, readiness: .unknown,
            selection: .operation(id: "d.image.generate", modelID: nil)
        )
        let unsupported = entry(
            "model:unsupported", title: "不支持", kind: .model, readiness: .unsupported,
            selection: .operation(id: "d.image.generate", modelID: "model:unsupported")
        )
        #expect(SharedLibraryBrowserLogic.quickUseAllowed(exact))
        #expect(!SharedLibraryBrowserLogic.quickUseAllowed(generic))
        #expect(!SharedLibraryBrowserLogic.quickUseAllowed(unsupported))
        #expect(SharedLibraryBrowserLogic.canvasTransfer(for: exact) == nil)
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
