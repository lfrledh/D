# D 原生 UI 单镜片与短动效修订

2026-10-10 · **UI-PRESENTATION-REBUILD-01**。当前候选 **052fdb4a**：悬停仅反馈文字，不叠第二块镜片；去掉内部白色反光渐变，保留细边与柔影；两侧开合改为非线性短过渡，默认200毫秒、最高强度220毫秒，正文不再额外等待。保留镜像标题/固定圆钮、两栏共存和移动选中镜片。真实内容模糊/折射仍未完成，原玻璃方向保留。状态见[当前行动](CURRENT_ACTIONS.zh-CN.md)，详见[任务末节](tasks/UI-PRESENTATION-REBUILD-01.md)。

## 唯一推荐入口

原入口已更新，本版当前已运行，可直接查看；入口仍拒绝已有D时双开：

`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261004T145523Z-continuous-closeout/delivery/启动聊天当前验收.command`

指向 `/Volumes/CodexProjects/Codex/D-Development/AgentTrials/UI-PRESENTATION-REBUILD-01/run-20261010-quiet-glass/delivery/D UI Review 052fdb4a.app`。

生产代码 **052fdb4a198a01500ef841a8d01785e714a10ee5**。10项定向组件检查通过；之后普通构建27.13秒，独立包签名/App Sandbox与4关键文件摘要一致。评审隔离会话仍为 `E6657FC1-65D2-4860-997C-8A0D531CAB07`。源/main未接纳。

本轮已成功查看同版浅深原生画面及设置的原生滑块。左右圆钮距外缘约2点各完成收起/展开，图像/视频按钮文字外留白切换成功，两栏保持；未选中项停指针时没有第二镜片。外观已恢复跟随系统，当前强度100%对应220毫秒，停在图像双栏、未加载模型。原图在`run-20261010-quiet-glass/gui`：`native-light-image-both.jpg`、`native-dark-image-both.jpg`、`native-dark-hover-video-pointer.jpg`。操作回执在`lead/native-sequence.json`。

此次没有连续原生录像或逐帧时长；代码/组件时序与点击后画面不能代替动效手感验收。请重点复看单镜片hover、材质是否仍显反光罩、约200毫秒的加速/减速与回弹。当前聊天路径原为已删除状态，未恢复或改草稿；本轮未做原生Undo/键盘焦点/阅读验收。旧输入最右2点接收器断言仍失败，不因圆钮边缘成功关闭。

## 旧首片原生参考（a226，非本版截图）

证据根R为 `/Volumes/CodexProjects/Codex/D-Development/AgentTrials/UI-PRESENTATION-REBUILD-01/run-20261008-first-slice`。

打开 `R/delivery/原生UI首片评审.html` 查看完整原图与明确标注差异的参考。图像字节来自原生截图，没有重绘；原始工具返回JPEG，保留早期.png证据名，同时提供正确.jpg别名。

![a2260084 原生深色空会话，左栏开右栏收，未选模型](images/ui-presentation-empty-a2260084.jpg)

已实际看到空输入紧凑、选择模型清楚、单一顶部分类与模式入口。短草稿Undo清空、Redo恢复；半屏30行输入仅内部滚动，附件/语音/选择模型/发送操作行可见。原生输入器与服务接线保留，后端/存储/模型不改。

旧图中的系统提示黑框、缺少占位文案和模型层级弱已在96d6代码中局部改善；052f本轮聊天原图可见透明主题系统提示框和输入占位，但处于已删除路径，不是可编辑草稿验收。原型01-chat为浅色双栏有消息，07-dark/09-narrow为图像页，均不能冒充本轮同状态聊天对照。交付的聊天HTML仅对齐主题/栏/消息/草稿，保留原样式；原型仍有Qwen演示模型，原生未选模型，且派生页本轮未渲染。**严格同状态对照仍待补。**

## 保留现场与后续门槛

旧-3812参数错误、曾明确报告锁屏、R6的-3811捕捉流失败分别保留。R7本轮桌面成功，无旧D进程时才启动052fdb4a；不改写前轮未验状态，不双开或丢弃现有工作。

继续时用文件→打开项目，选择独立副本：

`R/gui/UI review.dproject`

它带24节合成长文与受控媒体展示记录，`text:fixture`不是可运行模型。c978中间包已实际打开此副本；a226最终包尚未完成它的冷重开。不要把这些夹具写成模型生成成果。

当前优先待验：本版连续动效和用户观感；其余主体边缘点击、Escape/分类键盘焦点与菜单隔离/拖出/禁用、短长草稿原生回归；再顺路补同状态对照、右栏/焦点缩窗、浅色/大字/轻量、长文分类/模式往返、Finder附件→预览→保存冷开、已有Qwen短请求/停止及公共模态导航。模型文件已存在而本轮未登记/执行；不下载新模型。旧fit/封装/端口与viewport失败沿用原记录，见[集中队列](FAILURE_AND_PERMISSION_AUDIT.zh-CN.md)。

## 同树 Xcode Run

打开 `/Volumes/CodexProjects/Codex/D-Worktrees/D-UI-PRESENTATION-REBUILD-01/D.xcworkspace`，选 **D Nodes / My Mac / Debug**。本轮普通构建已通过，未实际点击Xcode Run。

忽略的本机 `Development/Development.local.xcconfig` 仅指定已有开发资源：

`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261004T041401Z-chat-resume/delivery/resources-with-python`

不修改签名/系统权限或重复下载。换机说明见[Development](../Development/README.md)。旧79f试用页固定存档见[历史索引](history/README.md#ui-presentation-takeover)。
