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
    func detailRendersTagControlsAndPortAndConstraintDescriptionsAcrossResize() {
        let node = descriptor(id: "text.long-model-id", title: "说明模型")
        var rectangles: [String: CGRect] = [:]
        let view = ModelNodeDetail(node: node, tags: ["中文", "👩‍💻"], onTagsChange: { _ in nil })
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
