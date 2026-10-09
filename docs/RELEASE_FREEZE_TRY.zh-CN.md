# D 原生 UI 对称边栏与移动镜片修订

2026-10-10 · **UI-PRESENTATION-REBUILD-01**。当前候选 **e11efc54**：外侧固定圆钮/内侧标题形成镜像，四种模态共用开合状态，两栏可同时展开；底板从按钮位置弹簧展开，顶部选中镜片滑动并局部放大标签。公共窗口最小1080点。玻璃外观沿用不透明画布混色并加高光；真实玻璃模糊/折射仍未完成。本版原生效果待验，未接纳main。状态见[当前行动](CURRENT_ACTIONS.zh-CN.md)，证据与五条反馈见[任务末节](tasks/UI-PRESENTATION-REBUILD-01.md)。

## 唯一推荐入口

双击原入口（已原位更新）：

`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261004T145523Z-continuous-closeout/delivery/启动聊天当前验收.command`

指向 `/Volumes/CodexProjects/Codex/D-Development/AgentTrials/UI-PRESENTATION-REBUILD-01/run-20261010-sidebar-lens/delivery/D UI Review e11efc54.app`。

生产代码 **e11efc5454ca3abc2d597a8a03436fed6dc05231**。XCTest后普通构建29.31秒；独立包签名/App Sandbox与4关键文件摘要核对通过，无补包/重签。当前运行仍是用户已打开的 **78759211**，新包尚未启动。入口保留“已有D时拒绝双开”；正常保存退出当前D后再使用，不强退或覆盖普通D。评审隔离会话仍为 `E6657FC1-65D2-4860-997C-8A0D531CAB07`。

最终11项定向组件检查通过，包括普通窗口四分类双栏、快速开合与隐藏、输入身份/组合输入、长草稿、阅读和受控Stop/drain。Lead及非实现者看过生产镜片的离屏浅深/中间态样张，**没有本版原生截图或动效录像，真实边缘点击为0次**。本轮首次桌面读取即-3811捕捉流失败，未成功AX/操作；不推断锁屏、不轮询或改权限。证据在`run-20261010-sidebar-lens/lead`，离屏样张在其`tmp/lens-paint-samples.png`。

本轮优先查看：左右标题/按钮是否镜像；同一个按钮及固定图标的圆钮→面板→圆钮过渡；图像/视频两侧同时打开；分类镜片的移动/放大；浅深及减弱效果下状态是否清楚。再顺路补主体边缘点击、Escape/左右键、输入/Undo/阅读往返。旧输入最右2pt组件接收器断言仍失败，原composer对照同样失败，未弱化断言，不算拖入通过。

## 旧首片原生参考（a226，非本版截图）

证据根R为 `/Volumes/CodexProjects/Codex/D-Development/AgentTrials/UI-PRESENTATION-REBUILD-01/run-20261008-first-slice`。

打开 `R/delivery/原生UI首片评审.html` 查看完整原图与明确标注差异的参考。图像字节来自原生截图，没有重绘；原始工具返回JPEG，保留早期.png证据名，同时提供正确.jpg别名。

![a2260084 原生深色空会话，左栏开右栏收，未选模型](images/ui-presentation-empty-a2260084.jpg)

已实际看到空输入紧凑、选择模型清楚、单一顶部分类与模式入口。短草稿Undo清空、Redo恢复；半屏30行输入仅内部滚动，附件/语音/选择模型/发送操作行可见。原生输入器与服务接线保留，后端/存储/模型不改。

旧图中的系统提示黑框、缺少占位文案和模型层级弱已在96d6代码中局部改善，尚无新原生图验证。原型01-chat为浅色双栏有消息，07-dark/09-narrow为图像页，均不能冒充本轮同状态聊天对照。交付的聊天HTML仅对齐主题/栏/消息/草稿，保留原样式；原型仍有Qwen演示模型，原生未选模型，且派生页本轮未渲染。**严格同状态对照仍待补。**

## 保留现场与后续门槛

旧-3812参数错误、曾明确报告锁屏、当前-3811捕捉流失败分别记录。2026-10-10核实运行的是78759211，原生读取立即失败，保留现场；下一次用同一入口启动e11efc54，不双开或丢弃现有工作。

继续时用文件→打开项目，选择独立副本：

`R/gui/UI review.dproject`

它带24节合成长文与受控媒体展示记录，`text:fixture`不是可运行模型。c978中间包已实际打开此副本；a226最终包尚未完成它的冷重开。不要把这些夹具写成模型生成成果。

当前优先待验：本版镜像边栏的圆钮形变/双栏共存、分类镜片、浅深/收栏/短长草稿原生画面，真实主体边缘点击、Escape/分类左右键与菜单隔离/拖出/禁用、简短动效；再顺路补同状态对照、右栏/焦点缩窗、浅色/大字/轻量、长文分类/模式往返、Finder附件→预览→保存冷开、已有Qwen短请求/停止及公共模态导航。模型文件已存在而本轮未登记/执行；不下载新模型。旧fit/封装/端口与viewport失败沿用原记录，见[集中队列](FAILURE_AND_PERMISSION_AUDIT.zh-CN.md)。

## 同树 Xcode Run

打开 `/Volumes/CodexProjects/Codex/D-Worktrees/D-UI-PRESENTATION-REBUILD-01/D.xcworkspace`，选 **D Nodes / My Mac / Debug**。本轮普通构建已通过，未实际点击Xcode Run。

忽略的本机 `Development/Development.local.xcconfig` 仅指定已有开发资源：

`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261004T041401Z-chat-resume/delivery/resources-with-python`

不修改签名/系统权限或重复下载。换机说明见[Development](../Development/README.md)。旧79f试用页固定存档见[历史索引](history/README.md#ui-presentation-takeover)。
