# D 原生 UI 悬浮材质修订

2026-10-09 · **UI-PRESENTATION-REBUILD-01**。当前为 **0d3079d8 显式底色实现检查点**：共享浮层直接绘制不透明的面板色/画布色混合，撤掉背景材质采样；不再声称模糊下方内容。79cdf材质修复已被用户实机否定，确认运行的是正确包。本版通过离屏像素检查，原生工具仍返回-3811捕捉失败；视觉、真实边缘点击和动效展示尚未执行，未接纳main。唯一当前任务见[当前行动](CURRENT_ACTIONS.zh-CN.md)，完整结果与停点见[任务记录](tasks/UI-PRESENTATION-REBUILD-01.md)。

## 唯一推荐入口

双击原入口（已原位更新）：

`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261004T145523Z-continuous-closeout/delivery/启动聊天当前验收.command`

指向 `/Volumes/CodexProjects/Codex/D-Development/AgentTrials/UI-PRESENTATION-REBUILD-01/run-20261009-explicit-canvas-fill/delivery/D UI Review 0d3079d8.app`。

生产代码 **0d3079d804a1a20ee051fa68a424cb1983026b08**。XCTest后普通构建27.33秒，独立复制；既有开发签名/App Sandbox及4关键文件摘要核对通过，未补包/重签。旧候选保留，运行中的79cdf未被退出；新包未启动。

设置中的“画布底色占比”沿用原值：0%为面板原色，100%为画布色，底板始终不透明。轻量/减弱透明度/高对比用面板原色；装饰动效策略保留。20组离屏渲染（浅/深、0/50/100%、透明/红/蓝背景及轻量/零动效）在主体及内侧留白取样通过；这是生产组件绘制检查，不是原生窗口截图。

继承96d6按钮/菜单/动效实现及19组件方法证据；其新增边缘夹具曾在key-window前置失败，0次点击，仍不能算边缘通过。本轮另3项策略/偏好方法通过；最初像素测试有只读环境编译错误，随后NSColor读数比较失败，修正为明确sRGB字节转换后通过，未扩大容差或改变生产颜色。记录在`run-20261009-explicit-canvas-fill/lead`。

本入口沿用“已有D时拒绝双开”的保护，不关闭你的App；本轮自有隔离候选在桌面工具错误后原样保留。评审偏好/库会话 `E6657FC1-65D2-4860-997C-8A0D531CAB07`，不同于用户旧79f。R内临时启动器现为本入口转发，不是第二推荐入口。

## 旧首片原生参考（a226，非本版截图）

证据根R为 `/Volumes/CodexProjects/Codex/D-Development/AgentTrials/UI-PRESENTATION-REBUILD-01/run-20261008-first-slice`。

打开 `R/delivery/原生UI首片评审.html` 查看完整原图与明确标注差异的参考。图像字节来自原生截图，没有重绘；原始工具返回JPEG，保留早期.png证据名，同时提供正确.jpg别名。

![a2260084 原生深色空会话，左栏开右栏收，未选模型](images/ui-presentation-empty-a2260084.jpg)

已实际看到空输入紧凑、选择模型清楚、单一顶部分类与模式入口。短草稿Undo清空、Redo恢复；半屏30行输入仅内部滚动，附件/语音/选择模型/发送操作行可见。原生输入器与服务接线保留，后端/存储/模型不改。

旧图中的系统提示黑框、缺少占位文案和模型层级弱已在96d6代码中局部改善，尚无新原生图验证。原型01-chat为浅色双栏有消息，07-dark/09-narrow为图像页，均不能冒充本轮同状态聊天对照。交付的聊天HTML仅对齐主题/栏/消息/草稿，保留原样式；原型仍有Qwen演示模型，原生未选模型，且派生页本轮未渲染。**严格同状态对照仍待补。**

## 保留现场与后续门槛

旧-3812是参数错误，96d6阶段工具明确报告Mac锁定，本轮-3811为捕捉流启动失败，均分开记录。未轮询/提权/修改系统策略。当前已确认用户运行79cdf；新0d3079d8未启动。保存现有工作并正常退出D后使用同一入口，入口会拒绝已有D时双开。

继续时用文件→打开项目，选择独立副本：

`R/gui/UI review.dproject`

它带24节合成长文与受控媒体展示记录，`text:fixture`不是可运行模型。c978中间包已实际打开此副本；a226最终包尚未完成它的冷重开。不要把这些夹具写成模型生成成果。

当前优先待验：本版浮层在不同桌面背景位置保持画布底色、真实边缘点击、菜单隔离/拖出/禁用/键盘、简短动效观察；再顺路补同状态对照、右栏/焦点缩窗、浅色/大字/轻量、长文分类/模式往返、Finder附件→预览→保存冷开、已有Qwen短请求/停止及公共模态导航。模型文件已存在而本轮未登记/执行；不下载新模型。旧fit/封装/端口与viewport失败沿用原记录，见[集中队列](FAILURE_AND_PERMISSION_AUDIT.zh-CN.md)。

## 同树 Xcode Run

打开 `/Volumes/CodexProjects/Codex/D-Worktrees/D-UI-PRESENTATION-REBUILD-01/D.xcworkspace`，选 **D Nodes / My Mac / Debug**。本轮普通构建已通过，未实际点击Xcode Run。

忽略的本机 `Development/Development.local.xcconfig` 仅指定已有开发资源：

`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261004T041401Z-chat-resume/delivery/resources-with-python`

不修改签名/系统权限或重复下载。换机说明见[Development](../Development/README.md)。旧79f试用页固定存档见[历史索引](history/README.md#ui-presentation-takeover)。
