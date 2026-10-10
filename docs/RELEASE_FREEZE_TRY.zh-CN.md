# D 原生 UI 可拖动镜片与栏内悬浮圆钮（原生待验）

2026-10-10 · **UI-PRESENTATION-REBUILD-01**。当前候选 **5a171721**：镜片支持按住略增大、拖动跟手、松手吸附并切换；取消不切页。单镜片、应用内折射、约200毫秒曲线保留。左右圆钮固定内缩8点并带独立圆底板，展开后完整浮在栏内，收起底板完全收入圆钮。当前为实现检查点，尚未完成本版原生自检，见[当前行动](CURRENT_ACTIONS.zh-CN.md)。

## 唯一试用入口

本版已启动，PID15648与隔离会话核对成功；原入口已更新，仍拒绝已有D时双开：

`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261004T145523Z-continuous-closeout/delivery/启动聊天当前验收.command`

指向 `/Volumes/CodexProjects/Codex/D-Development/AgentTrials/UI-PRESENTATION-REBUILD-01/run-20261010-lens-drag/delivery/D UI Review 5a171721.app`。

生产 **5a1717219caeb8281efc32963b2b77061637fc12**。最终8项定向检查7通过、1因测试窗口未成为key window而前置失败，未发送拖动事件；不称拖动回归通过。随后普通构建30.76秒，签名/App Sandbox及5文件摘要一致。隔离UUID仍为 `E6657FC1-65D2-4860-997C-8A0D531CAB07`。源/main与个人修改未推进。

原生工具在读取本版窗口时一次返回`-10005 timeoutReached`，已停止，不推断锁屏或扩权。本版尚无原生画面、边缘拖动、按压/松手放大、Escape取消或快速再次抓取结果，也没有本版连续动效展示。下一步先补这些原生检查；旧版浅深截图不能代本版。原输入/Undo/阅读/拖入与最右2点输入接收器旧余项继续保留。证据`run-20261010-lens-drag/lead`。

## 旧首片原生参考（a226，非本版截图）

证据根R为 `/Volumes/CodexProjects/Codex/D-Development/AgentTrials/UI-PRESENTATION-REBUILD-01/run-20261008-first-slice`。

打开 `R/delivery/原生UI首片评审.html` 查看完整原图与明确标注差异的参考。图像字节来自原生截图，没有重绘；原始工具返回JPEG，保留早期.png证据名，同时提供正确.jpg别名。

![a2260084 原生深色空会话，左栏开右栏收，未选模型](images/ui-presentation-empty-a2260084.jpg)

已实际看到空输入紧凑、选择模型清楚、单一顶部分类与模式入口。短草稿Undo清空、Redo恢复；半屏30行输入仅内部滚动，附件/语音/选择模型/发送操作行可见。原生输入器与服务接线保留，后端/存储/模型不改。

旧图中的系统提示黑框、缺少占位文案和模型层级弱已在96d6代码中局部改善；052f本轮聊天原图可见透明主题系统提示框和输入占位，但处于已删除路径，不是可编辑草稿验收。原型01-chat为浅色双栏有消息，07-dark/09-narrow为图像页，均不能冒充本轮同状态聊天对照。交付的聊天HTML仅对齐主题/栏/消息/草稿，保留原样式；原型仍有Qwen演示模型，原生未选模型，且派生页本轮未渲染。**严格同状态对照仍待补。**

## 保留现场与后续门槛

旧-3812参数错误、曾明确报告锁屏、R6的-3811捕捉流失败分别保留。R7和R8桌面成功，R8无旧D进程时才启动ad50e57f；R9同样核对无D后启动5a171721，但原生窗口读取超时；不改写前轮未验状态，不双开或丢弃现有工作。

继续时用文件→打开项目，选择独立副本：

`R/gui/UI review.dproject`

它带24节合成长文与受控媒体展示记录，`text:fixture`不是可运行模型。c978中间包已实际打开此副本；a226最终包尚未完成它的冷重开。不要把这些夹具写成模型生成成果。

当前优先待验：本版原生拖动/松手提交/取消、按压反馈、侧栏完整圆钮与连续动效；其余主体边缘点击、Escape/分类键盘焦点与菜单隔离/拖出/禁用、短长草稿原生回归；再顺路补同状态对照、右栏/焦点缩窗、浅色/大字/轻量、长文分类/模式往返、Finder附件→预览→保存冷开、已有Qwen短请求/停止及公共模态导航。模型文件已存在而本轮未登记/执行；不下载新模型。旧fit/封装/端口与viewport失败沿用原记录，见[集中队列](FAILURE_AND_PERMISSION_AUDIT.zh-CN.md)。

## 同树 Xcode Run

打开 `/Volumes/CodexProjects/Codex/D-Worktrees/D-UI-PRESENTATION-REBUILD-01/D.xcworkspace`，选 **D Nodes / My Mac / Debug**。本轮普通构建已通过，未实际点击Xcode Run。

忽略的本机 `Development/Development.local.xcconfig` 仅指定已有开发资源：

`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261004T041401Z-chat-resume/delivery/resources-with-python`

不修改签名/系统权限或重复下载。换机说明见[Development](../Development/README.md)。旧79f试用页固定存档见[历史索引](history/README.md#ui-presentation-takeover)。
