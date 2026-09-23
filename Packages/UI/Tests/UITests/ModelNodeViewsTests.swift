import AppKit
import DWorkbench
import SwiftUI
import Testing
@testable import UI

@Suite @MainActor
struct ModelNodeViewsTests {
    @Test
    func listUsesStableRowsAndRemainsInsideASidebarWidth() {
        let first = descriptor(id: "image.long-id", title: "长模型名称 👩‍💻")
        let second = descriptor(id: "image.other", title: "另一个模型")
        var selected: [String] = []
        let view = ModelNodeList(entries: [first, second], selectedID: first.id) { selected.append($0) }
        let host = NSHostingView(rootView: view)
        settle(host, width: 260, height: 420)

        #expect(host.fittingSize.width <= 261)
        let buttons = descendants(host).compactMap { $0 as? NSButton }
        #expect(buttons.contains { $0.accessibilityIdentifier() == "model-node-list-\(first.id)" })
        #expect(buttons.contains { $0.accessibilityIdentifier() == "model-node-list-\(second.id)" })
        #expect(selected.isEmpty)
    }

    @Test
    func tagEditorTrimsRejectsDuplicatesAndPreservesTagsOnFailure() {
        var editor = ModelNodeTagEditorState(tags: ["收藏"])
        editor.draft = "  新标签  "
        #expect(editor.proposedAddition() == .success(["收藏", "新标签"]))
        editor.draft = " 收藏 "
        #expect(editor.proposedAddition() == .failure("这个标签已经存在。"))
        editor.draft = " \n "
        #expect(editor.proposedAddition() == .failure("请输入标签内容。"))
        editor.reject("存储不可用")
        #expect(editor.tags == ["收藏"])
        #expect(editor.errorMessage == "存储不可用")
        editor.accept(tags: ["收藏", "新标签"])
        #expect(editor.tags == ["收藏", "新标签"])
        #expect(editor.draft.isEmpty)
    }

    @Test
    func detailHostsReadableMetadataAndDoesNotExposeParameterEditors() {
        let node = descriptor(id: "text.long-model-id", title: "说明模型")
        let view = ModelNodeDetail(node: node, tags: ["中文", "👩‍💻"], onTagsChange: { _ in nil })
        let host = NSHostingView(rootView: view)
        settle(host, width: 480, height: 560)

        #expect(host.fittingSize.width <= 481)
        let textFields = descendants(host).compactMap { $0 as? NSTextField }
        #expect(textFields.contains { $0.accessibilityIdentifier() == "model-node-tag-draft-\(node.id)" })
        #expect(!textFields.contains { $0.accessibilityIdentifier() == "model-node-parameter-\(node.id)-generate-steps" })
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
                outputs: [ModelNodePort(id: "image", title: "图像", dataType: "Image", requirement: .conditional("启用图像输出时"),
                                        detail: "成功后产生的图像。")],
                parameters: [ModelNodeParameter(id: "steps", title: "步数", defaultValue: "20", acceptedValues: "1…100",
                                                 detail: "后端范围。", isAdjustable: true)]
            )], notes: ["固定配方仍可能限制某些参数。"], evidencePaths: ["Sources/Adapter.swift"]
        )
    }

    private func settle<Content: View>(_ host: NSHostingView<Content>, width: CGFloat, height: CGFloat) {
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}
