import AppKit
import DWorkbench
import SwiftUI
import Testing
@testable import UI

@Suite @MainActor
struct ModelNodeViewsTests {
    @Test
    func listRendersSelectedRowsAndReadableStatusAtRealSidebarWidths() {
        let first = descriptor(id: "image.long-id", title: "长模型名称 👩‍💻")
        let second = descriptor(id: "image.other", title: "另一个模型")
        var selected: [String] = []
        var rectangles: [String: CGRect] = [:]
        let view = ModelNodeList(entries: [first, second], selectedID: first.id) { selected.append($0) }
            .observingLayout { rectangles[$0] = $1 }
        let host = NSHostingView(rootView: view)
        for width: CGFloat in [210, 260] {
            settle(host, width: width, height: 420)
            for id in ["model-node-list", "model-node-list-\(first.id)", "model-node-list-\(second.id)"] {
                #expect(isInsideViewport(rectangles[id], of: host), "\(id) is clipped at sidebar width \(width)")
            }
            #expect(rectangles["model-node-list-\(first.id)"]?.height ?? 0 > 44)
        }

        #expect(selected.isEmpty)
    }

    @Test
    func tagEditorUsesRealStoreCallbackAndPreservesDraftAccordingToAction() throws {
        let modelID = "editor-\(UUID().uuidString)"
        let store = ModelNodeTagStore()
        let persist: ([String]) -> String? = { tags in
            do {
                try store.setTags(tags, for: modelID)
                return nil
            } catch {
                return error.localizedDescription
            }
        }

        var editor = ModelNodeTagEditorState(tagState: .missing)
        editor.draft = "  新标签  "
        #expect(editor.proposedAddition() == .success(["新标签"]))
        editor.addDraft(using: persist)
        #expect(editor.tags == ["新标签"])
        #expect(editor.draft.isEmpty)
        #expect(store.readState(for: modelID) == .valid(["新标签"]))

        editor.draft = "删除时保留"
        editor.remove("新标签", using: persist)
        #expect(editor.tags.isEmpty)
        #expect(editor.draft == "删除时保留")
        #expect(store.readState(for: modelID) == .missing)

        editor = ModelNodeTagEditorState(tagState: .valid(["收藏"]))
        editor.draft = " 收藏 "
        #expect(editor.proposedAddition() == .failure("这个标签已经存在。"))
        editor.draft = " \n "
        #expect(editor.proposedAddition() == .failure("请输入标签内容。"))

        let suiteName = "D.ModelNodeViewsTests.\(UUID().uuidString)"
        let settings = try #require(UserDefaults(suiteName: suiteName))
        defer { settings.removePersistentDomain(forName: suiteName) }
        let persistedStore = ModelNodeTagStore(settings: settings)
        try persistedStore.setTags(["收藏"], for: modelID)
        #expect(persistedStore.readState(for: modelID) == .valid(["收藏"]))
        settings.set(Data([0x00, 0x01]), forKey: "D.ModelNodeTags.v1.\(modelID)")

        editor.draft = "候选"
        editor.addDraft { tags in
            do {
                try persistedStore.setTags(tags, for: modelID)
                return nil
            } catch {
                return error.localizedDescription
            }
        }
        #expect(editor.tags == ["收藏"])
        #expect(editor.draft == "候选")
        #expect(editor.errorMessage == ModelNodeTagStoreError.corruptRecord.localizedDescription)

        editor.remove("收藏") { tags in
            do {
                try persistedStore.setTags(tags, for: modelID)
                return nil
            } catch {
                return error.localizedDescription
            }
        }
        #expect(editor.tags == ["收藏"])
        #expect(editor.draft == "候选")
        #expect(editor.errorMessage == ModelNodeTagStoreError.corruptRecord.localizedDescription)

        var corruptEditor = ModelNodeTagEditorState(tagState: .corrupt)
        corruptEditor.draft = "不会提交"
        var callbackWasCalled = false
        corruptEditor.addDraft { _ in
            callbackWasCalled = true
            return nil
        }
        #expect(!corruptEditor.isEditable)
        #expect(!callbackWasCalled)
        #expect(corruptEditor.draft == "不会提交")
    }

    @Test
    func sameNodeIncomingCorruptionLocksEditorWithoutResettingLocalState() {
        var editor = ModelNodeTagEditorState(tagState: .valid(["收藏"]))
        editor.draft = "保留草稿"
        editor.reject("保留错误")

        editor.applyIncomingReadState(.valid(["外部刷新不覆盖本地状态"]))
        editor.applyIncomingReadState(.missing)
        #expect(editor.isEditable)
        #expect(editor.tags == ["收藏"])
        #expect(editor.draft == "保留草稿")
        #expect(editor.errorMessage == "保留错误")

        editor.applyIncomingReadState(.corrupt)
        #expect(!editor.isEditable)
        #expect(editor.tags == ["收藏"])
        #expect(editor.draft == "保留草稿")
        #expect(editor.errorMessage == "保留错误")

        var callbackWasCalled = false
        editor.addDraft { _ in
            callbackWasCalled = true
            return nil
        }
        editor.remove("收藏") { _ in
            callbackWasCalled = true
            return nil
        }
        #expect(!callbackWasCalled)
        #expect(editor.tags == ["收藏"])
        #expect(editor.draft == "保留草稿")
    }

    @Test
    func detailSameNodeIncomingCorruptionReplacesEmptyStateWithReadOnlyWarning() {
        let node = descriptor(id: "text.same-node", title: "同一模型")
        var rectangles: [String: CGRect] = [:]
        let initialView = ModelNodeDetail(node: node, tagState: .missing, onTagsChange: { _ in nil })
            .observingLayout { rectangles[$0] = $1 }
        let host = NSHostingView(rootView: initialView)
        settle(host, width: 480, height: 560)
        #expect(isHorizontallyReachable(rectangles["model-node-tags-empty-\(node.id)"], of: host))

        rectangles.removeAll()
        host.rootView = ModelNodeDetail(node: node, tagState: .corrupt, onTagsChange: { _ in nil })
            .observingLayout { rectangles[$0] = $1 }
        settle(host, width: 480, height: 560)

        #expect(isHorizontallyReachable(rectangles["model-node-tags-corrupt-\(node.id)"], of: host))
        #expect(rectangles["model-node-tags-empty-\(node.id)"] == nil)
    }

    @Test
    func detailRendersTagControlsAndPortAndConstraintDescriptionsAcrossResize() {
        let node = descriptor(id: "text.long-model-id", title: "说明模型")
        var rectangles: [String: CGRect] = [:]
        let view = ModelNodeDetail(node: node, tagState: .valid(["中文", "👩‍💻"]), onTagsChange: { _ in nil })
            .observingLayout { rectangles[$0] = $1 }
        let host = NSHostingView(rootView: view)
        for width: CGFloat in [480, 640, 480] {
            settle(host, width: width, height: 560)
            for id in [
                "model-node-detail-\(node.id)", "model-node-tag-draft-\(node.id)",
                "model-node-tag-add-\(node.id)", "model-node-tag-remove-\(node.id)-中文",
                "model-node-tag-remove-\(node.id)-👩‍💻",
                "model-node-ports-\(node.id)-generate-inputs",
                "model-node-ports-\(node.id)-generate-outputs",
                "model-node-parameter-\(node.id)-generate-steps",
                "model-node-parameter-\(node.id)-generate-recipe"
            ] {
                #expect(isHorizontallyReachable(rectangles[id], of: host), "\(id) is horizontally clipped at detail width \(width)")
            }
        }

        #expect(rectangles["model-node-detail-content-\(node.id)"]?.height ?? 0 > 560,
                "Long model ID, evidence, ports, and constraints must remain scrollable rather than truncate.")
    }

    private func descriptor(id: String, title: String) -> ModelNodeDescriptor {
        ModelNodeDescriptor(
            id: id, modality: .image, title: title, summary: "可换行的模型摘要，用于窄侧栏和详情检查。",
            modelIdentity: "org.example.very-long-model-identity/with-a-copyable-revision", revision: "revision-2026-09-24",
            engine: "Native engine", device: "GPU", precision: "FP16", availability: .workbench,
            deploymentNote: "描述性数据；不安装、不下载、不启动推理。",
            operations: [ModelNodeOperation(
                id: "generate", title: "生成", summary: "从文本条件生成结果。",
                inputs: [ModelNodePort(id: "prompt", title: "提示词", dataType: "Text", requirement: .required,
                                       detail: "创作描述。")],
                outputs: [
                    ModelNodePort(id: "image", title: "图像", dataType: "Image", requirement: .required,
                                  detail: "成功后必有的图像。"),
                    ModelNodePort(id: "preview", title: "预览", dataType: "Image", requirement: .optional,
                                  detail: "可能产生的预览。"),
                    ModelNodePort(id: "mask", title: "蒙版", dataType: "Mask", requirement: .conditional("使用局部编辑时"),
                                  detail: "局部编辑成功后产生的蒙版。")
                ],
                parameters: [
                    ModelNodeParameter(id: "steps", title: "步数", defaultValue: "20", acceptedValues: "1…100",
                                       detail: "后端范围。", isAdjustable: true),
                    ModelNodeParameter(id: "recipe", title: "固定配方", defaultValue: "adapter-default",
                                       acceptedValues: "固定：不得由此说明页作为执行设置提交", detail: "原创作界面未暴露。", isAdjustable: false)
                ]
            )], notes: ["固定配方仍可能限制某些参数。"], evidencePaths: ["Sources/Adapter.swift"]
        )
    }

    private func settle<Content: View>(_ host: NSHostingView<Content>, width: CGFloat, height: CGFloat) {
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
    }

    private func isInsideViewport<Content: View>(_ rectangle: CGRect?, of host: NSHostingView<Content>) -> Bool {
        guard let rectangle else { return false }
        let viewport = host.bounds.insetBy(dx: -1, dy: -1)
        return rectangle.minX >= viewport.minX && rectangle.maxX <= viewport.maxX
            && rectangle.minY >= viewport.minY && rectangle.maxY <= viewport.maxY
    }

    private func isHorizontallyReachable<Content: View>(_ rectangle: CGRect?, of host: NSHostingView<Content>) -> Bool {
        guard let rectangle else { return false }
        let viewport = host.bounds.insetBy(dx: -1, dy: -1)
        return rectangle.width > 0 && rectangle.minX >= viewport.minX && rectangle.maxX <= viewport.maxX
    }
}
