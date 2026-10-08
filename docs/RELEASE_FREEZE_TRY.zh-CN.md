# D 原生 UI 命中与动效修订

2026-10-09 · **UI-PRESENTATION-REBUILD-01**。用户认可首片方向，本轮继续按钮完整命中与局部动效。当前为 **96d6dcb2 实现检查点**：构建/包核对通过，本版真实边缘点击与动效展示因桌面锁定未执行。未接纳main、未发行。唯一当前任务见[当前行动](CURRENT_ACTIONS.zh-CN.md)，完整结果与停点见[任务记录](tasks/UI-PRESENTATION-REBUILD-01.md)。

## 唯一推荐入口

双击原入口（已原位更新）：

`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261004T145523Z-continuous-closeout/delivery/启动聊天当前验收.command`

指向 `/Volumes/CodexProjects/Codex/D-Development/AgentTrials/UI-PRESENTATION-REBUILD-01/run-20261009-hit-motion/delivery/D UI Review 96d6dcb2.app`。

生产代码 **96d6dcb2cd6c8a180e9d868106a73e1e84037600**。XCTest后普通构建30.21秒，独立复制；既有开发签名/App Sandbox及4关键文件摘要核对通过，未补包/重签。后续测试驱动/文档提交不改变App生产代码。旧候选保留，运行中的a226未被退出。

本版已修圆钮外层留白、plain图标及会话选择区域，菜单保持独立并补禁用时序；已接入按钮反馈、侧栏底板与输入局部变化。最终生产差分19组件方法通过，但新增边缘夹具未建立有效key window，0次点击，整组exit65；不是边缘验收通过。动效0/轻量/减弱策略保留，实际手感与视觉尚待原生检查。详细日志在R2/lead，见任务记录。

本入口沿用“已有D时拒绝双开”的保护，不关闭你的App；本轮自有隔离候选在桌面工具错误后原样保留。评审偏好/库会话 `E6657FC1-65D2-4860-997C-8A0D531CAB07`，不同于用户旧79f。R内临时启动器现为本入口转发，不是第二推荐入口。

## 旧首片原生参考（a226，非本版截图）

证据根R为 `/Volumes/CodexProjects/Codex/D-Development/AgentTrials/UI-PRESENTATION-REBUILD-01/run-20261008-first-slice`。

打开 `R/delivery/原生UI首片评审.html` 查看完整原图与明确标注差异的参考。图像字节来自原生截图，没有重绘；原始工具返回JPEG，保留早期.png证据名，同时提供正确.jpg别名。

![a2260084 原生深色空会话，左栏开右栏收，未选模型](images/ui-presentation-empty-a2260084.jpg)

已实际看到空输入紧凑、选择模型清楚、单一顶部分类与模式入口。短草稿Undo清空、Redo恢复；半屏30行输入仅内部滚动，附件/语音/选择模型/发送操作行可见。原生输入器与服务接线保留，后端/存储/模型不改。

旧图中的系统提示黑框、缺少占位文案和模型层级弱已在96d6代码中局部改善，尚无新原生图验证。原型01-chat为浅色双栏有消息，07-dark/09-narrow为图像页，均不能冒充本轮同状态聊天对照。交付的聊天HTML仅对齐主题/栏/消息/草稿，保留原样式；原型仍有Qwen演示模型，原生未选模型，且派生页本轮未渲染。**严格同状态对照仍待补。**

## 保留现场与后续门槛

上一轮桌面停点为 `SCStreamErrorDomain -3812`（参数无效），未认作锁屏。本轮工具明确报告Mac锁定/自动解锁未成功；立即暂停普通App操作，没有轮询/提权/修改系统策略。当前App未启动，需桌面恢复后通过同一入口验收；旧隔离草稿保持。

继续时用文件→打开项目，选择独立副本：

`R/gui/UI review.dproject`

它带24节合成长文与受控媒体展示记录，`text:fixture`不是可运行模型。c978中间包已实际打开此副本；a226最终包尚未完成它的冷重开。不要把这些夹具写成模型生成成果。

当前优先待验：本版真实边缘点击、菜单隔离/拖出/禁用/键盘、简短动效观察；再顺路补同状态对照、右栏/焦点缩窗、浅色/大字/轻量、长文分类/模式往返、Finder附件→预览→保存冷开、已有Qwen短请求/停止及公共模态导航。模型文件已存在而本轮未登记/执行；不下载新模型。旧fit/封装/端口与viewport失败沿用原记录，见[集中队列](FAILURE_AND_PERMISSION_AUDIT.zh-CN.md)。

## 同树 Xcode Run

打开 `/Volumes/CodexProjects/Codex/D-Worktrees/D-UI-PRESENTATION-REBUILD-01/D.xcworkspace`，选 **D Nodes / My Mac / Debug**。本轮普通构建已通过，未实际点击Xcode Run。

忽略的本机 `Development/Development.local.xcconfig` 仅指定已有开发资源：

`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261004T041401Z-chat-resume/delivery/resources-with-python`

不修改签名/系统权限或重复下载。换机说明见[Development](../Development/README.md)。旧79f试用页固定存档见[历史索引](history/README.md#ui-presentation-takeover)。
