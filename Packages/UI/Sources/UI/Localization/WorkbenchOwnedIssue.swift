import SwiftUI
import DWorkbench

/// Exact D-owned UI guard messages only; never mutates the stored diagnostic.
/// Unknown/backend text remains verbatim. The original is available separately.
@MainActor enum WorkbenchOwnedIssue {
    static let keys: [String: String] = [
        "此模型身份与操作不匹配，且不是受支持的目录草稿。": "workflow.node.prepare.identityMismatch",
        "长期工作区不可用。": "consistency.ownedIssue.e0",
        "字段来源不可用。": "consistency.ownedIssue.e1",
        "源素材已不存在。": "consistency.ownedIssue.e2",
        "项目已切换；备份未创建。": "consistency.ownedIssue.e3",
        "Metadata target unavailable / 素材所属实例不可访问。": "consistency.ownedIssue.e4",
        "Metadata target changed / 所属项目实例或页面已改变，草稿未提交。": "consistency.ownedIssue.e5",
        "Library page changed / 资料库页面已改变，草稿未提交。": "consistency.ownedIssue.e6",
        "临时聊天需要支持有序消息的文字模型；其他能力请返回普通快速生成。": "consistency.ownedIssue.e7",
        "所属项目尚未打开，请从项目入口打开后再查看文件位置。": "consistency.ownedIssue.e8",
        "快速草稿已切换，未登记模型。": "consistency.ownedIssue.e9",
        "快速草稿已切换，已登记的模型未替换当前草稿。": "consistency.ownedIssue.e10",
        "目标项目已改变或当前不可编辑，未导入素材。": "consistency.ownedIssue.e11",
        "工具不属于当前项目的固定版本。": "consistency.ownedIssue.e12",
        "素材身份无效。": "consistency.ownedIssue.e13",
        "目标项目已改变。": "consistency.ownedIssue.e14",
        "缺少已复制的素材引用。": "consistency.ownedIssue.e15",
        "拖放期间目标已改变，未插入其他流程。": "consistency.ownedIssue.e16",
        "请先选择单项输入，不能隐式复制候选集合。": "consistency.ownedIssue.e17",
        "目标项目已改变，未放入其他流程。": "consistency.ownedIssue.e18",
        "对话已删除或不存在。": "consistency.ownedIssue.e19",
        "请返回原对话后再采用此回答。": "consistency.ownedIssue.e20",
        "回答仍在运行、待保存或等待工具完成，不能采用。": "consistency.ownedIssue.e21",
        "对话不存在。": "consistency.ownedIssue.e22",
        "请等待回答完成并返回原对话后再选择版本。": "consistency.ownedIssue.e23",
        "原会话已离开。": "consistency.ownedIssue.e24",
        "长期保存入口不可用。": "consistency.ownedIssue.e25",
        "请返回原对话后再修改消息。": "consistency.ownedIssue.e26",
        "请先恢复已删除的对话。": "consistency.ownedIssue.e27",
        "请从资料库重新拖入具有明确项目实例的素材。": "consistency.ownedIssue.e28",
        "Conversation import must be a regular file up to 2 MiB. / 会话导入限2MiB普通文件。": "consistency.ownedIssue.e29",
        "Preset file must be at most 2 MiB. / 预设文件不能超过2MiB。": "consistency.ownedIssue.e30",
        "No selected conversation path. / 尚无所选会话路径。": "consistency.ownedIssue.e31",
        "长期保存入口不可用；成果仍在临时会话。": "consistency.ownedIssue.e32",
        "消息不存在。": "consistency.ownedIssue.e33",
        "请返回原对话后再编辑消息。": "consistency.ownedIssue.e34",
        "回答不存在。": "consistency.ownedIssue.e35",
        "请等待回答和保存完成，并在原对话中选择。": "consistency.ownedIssue.e36",
        "当前对话或模型参数尚不能提交比较。": "consistency.ownedIssue.e37",
        "请先完成参数输入并选择模型，再保存当前配置。": "consistency.ownedIssue.e38",
        "Output budgets must be positive integers / 输出预算须为正整数。": "consistency.ownedIssue.e39",
        "The summary threshold must be positive / 摘要阈值须为正整数。": "consistency.ownedIssue.e40",
        "作品所属实例不可访问，草稿保留。": "consistency.ownedIssue.e41",
        "请输入标签内容。": "consistency.ownedIssue.e42",
        "这个标签已经存在。": "consistency.ownedIssue.e43"
    ]
    static func alertMessage(_ raw: String, language: UILanguageStore?) -> String {
        guard let summary = summary(raw, language: language), summary != raw else { return raw }
        return summary + "\n\n" + consistencyText(language, "error.original") + ":\n" + raw
    }
    static func summary(_ raw: String, language: UILanguageStore?) -> String? {
        guard let key = keys[raw] else { return nil }
        return workflowText(language, key, fallback: raw)
    }
}
struct WorkbenchIssueText: View {
    let raw: String
    var key: String? = nil
    @Environment(\.dLanguageStore) private var language
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(key.map { workflowText(language, $0, fallback: raw) } ?? WorkbenchOwnedIssue.summary(raw, language: language) ?? ChatErrorText.display(raw, language: language))
            if key != nil || WorkbenchOwnedIssue.summary(raw, language: language).map({ $0 != raw }) == true {
                DisclosureGroup(consistencyText(language, "error.original")) { Text(raw).textSelection(.enabled) }
            }
        }
    }
}

// Captures diagnostics without translating business identity or matching sentences.
extension WorkflowIssue {
    init(presenting error: any Error, fallbackCode: String) {
        self = error as? WorkflowIssue ?? WorkflowIssue(error.localizedDescription)
        if code == nil { code = fallbackCode }
    }
}
