# D 原生 UI 首片评审

2026-10-09 · **UI-PRESENTATION-REBUILD-01**。公共外壳与真实聊天展示已实施，已有普通App原生检查和截图；仍有原生门槛未完成，未接纳main、未发行。唯一当前任务见[当前行动](CURRENT_ACTIONS.zh-CN.md)，完整结果与停点见[任务记录](tasks/UI-PRESENTATION-REBUILD-01.md)。

## 唯一推荐入口

双击原入口（已原位更新）：

`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261004T145523Z-continuous-closeout/delivery/启动聊天当前验收.command`

指向 `/Volumes/CodexProjects/Codex/D-Development/AgentTrials/UI-PRESENTATION-REBUILD-01/run-20261008-first-slice/delivery/D UI Review a2260084.app`。

代码 **a226008435f6ad52599b68b85d58c62228167e30**。同树正常开发构建后独立复制，沿既有ad-hoc签名与App Sandbox，codesign验证及4关键文件摘要匹配；未补包/重签。XCTest后重新普通构建，37.72秒。其后只更新文档，不冒称文档提交再构建。旧候选保留为恢复材料。

本入口沿用“已有D时拒绝双开”的保护，不关闭你的App；本轮自有隔离候选在桌面工具错误后原样保留。评审偏好/库会话 `E6657FC1-65D2-4860-997C-8A0D531CAB07`，不同于用户旧79f。R内临时启动器现为本入口转发，不是第二推荐入口。

## 实际看到的首片

证据根R为 `/Volumes/CodexProjects/Codex/D-Development/AgentTrials/UI-PRESENTATION-REBUILD-01/run-20261008-first-slice`。

打开 `R/delivery/原生UI首片评审.html` 查看完整原图与明确标注差异的参考。图像字节来自原生截图，没有重绘；原始工具返回JPEG，保留早期.png证据名，同时提供正确.jpg别名。

![a2260084 原生深色空会话，左栏开右栏收，未选模型](images/ui-presentation-empty-a2260084.jpg)

已实际看到空输入紧凑、选择模型清楚、单一顶部分类与模式入口。短草稿Undo清空、Redo恢复；半屏30行输入仅内部滚动，附件/语音/选择模型/发送操作行可见。原生输入器与服务接线保留，后端/存储/模型不改。

仍有视觉差异：左侧系统提示黑框、空输入缺少占位文案、模型区层级偏弱。原型01-chat为浅色双栏有消息，07-dark/09-narrow为图像页，均不能冒充本轮同状态聊天对照。交付的聊天HTML仅对齐主题/栏/消息/草稿，保留原样式；原型仍有Qwen演示模型，原生未选模型，且派生页本轮未渲染。**严格同状态对照仍待补。**

## 保留现场与后续门槛

桌面工具返回 `SCStreamErrorDomain -3812`，立即暂停原生，不轮询/提权/修改系统策略。隔离草稿已从磁盘只读核对，未把它算作冷重开通过。

继续时用文件→打开项目，选择独立副本：

`R/gui/UI review.dproject`

它带24节合成长文与受控媒体展示记录，`text:fixture`不是可运行模型。c978中间包已实际打开此副本；a226最终包尚未完成它的冷重开。不要把这些夹具写成模型生成成果。

当前待验：同状态对照、右栏/焦点缩窗、浅色/大字/轻量、长文分类/模式往返、Finder附件→预览→保存冷开、已有Qwen短请求/停止及公共模态导航。模型文件已存在而本轮未登记/执行；不下载新模型。旧fit/封装/端口与viewport失败沿用原记录，见[集中队列](FAILURE_AND_PERMISSION_AUDIT.zh-CN.md)。

## 同树 Xcode Run

打开 `/Volumes/CodexProjects/Codex/D-Worktrees/D-UI-PRESENTATION-REBUILD-01/D.xcworkspace`，选 **D Nodes / My Mac / Debug**。本轮普通构建已通过，未实际点击Xcode Run。

忽略的本机 `Development/Development.local.xcconfig` 仅指定已有开发资源：

`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261004T041401Z-chat-resume/delivery/resources-with-python`

不修改签名/系统权限或重复下载。换机说明见[Development](../Development/README.md)。旧79f试用页固定存档见[历史索引](history/README.md#ui-presentation-takeover)。
