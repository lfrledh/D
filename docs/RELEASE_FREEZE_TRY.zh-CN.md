# D 文字工作面功能归组候选

2026-10-10 · **UI-PRESENTATION-REBUILD-01** · 生产 **5ac3353c774eb733915cabccf446e5e9dbf24be6**。保留已认可外壳与胶囊；本轮整理入口、名称和作用范围，不继续镜片/折射精修。复杂交互留在[最终集中待验清单](FAILURE_AND_PERMISSION_AUDIT.zh-CN.md)，不阻塞本轮功能整理。

## 唯一试用入口

[启动聊天当前验收.command](/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261004T145523Z-continuous-closeout/delivery/启动聊天当前验收.command)

现指向 [D UI Review 5ac3353c.app](</Volumes/CodexProjects/Codex/D-Development/AgentTrials/UI-PRESENTATION-REBUILD-01/run-20261010-function-organization/delivery/D UI Review 5ac3353c.app>)。已启动，PID22431与隔离UUID E6657FC1-65D2-4860-997C-8A0D531CAB07核实，入口拒绝已有D时双开。

最后普通构建35.45秒成功；严格签名、App Sandbox及7个关键文件与普通产物一致，无补包或重签。源01758b81/main91bef7d7与个人scheme未推进。本轮10项定向测试通过，修正后其中2项再次通过；最后两个编辑框只有外观差分，构建和独立静态复核通过。测试/构建不代表动效通过。

**原生边界：** 本轮在e6e3f444和27ef8afc实际操作并截图。最终5ac3353c只追加摘要/记忆编辑框的主题外观，读取窗口一次返回-10005 timeoutReached；停止原生、不重试/扩权、不推断锁屏。最终包已运行，但尚无它自己的截图。下列图明确属于27ef8afc，不冒充最终同版通过。

## 新入口

- **左侧“本会话设置”**：模型与常用预设、回答方式、上下文与记忆、会话整理、高级模型设置。当前规则只影响以后请求；预设在此应用，在设置统一管理；支持的其余参数仍在高级入口。
- **右侧“资料 / 成果 / 工具”**：资料负责查找与采用；成果负责已保存回答及可编辑内容；工具先选计算/换算/分析/联网或MCP任务，再看对应输入和结果。切页保留编辑状态，不自动运行。
- **消息“更多”**：继续讨论、回答版本、保存交接、朗读、查看详情按分隔线归组；历史详情读取当次快照。对话列表菜单可进入“会话整理”。
- **齿轮 / Command–逗号**：同一设置。发送键在“操作”；默认规则与当前项目预设在“聊天默认”；朗读声音/速度在“声音”；路径、下载与备份在“文件与模型”；凭据在“网络与凭据”。识别语言仍留在语音输入，应用语言独立。

## 实际检查与截图

27ef8afc的1080点普通窗口、深色17pt及浅色14pt已亲见；没有将图像重绘成设计稿。复看修正了重复标签、默认规则白底、历史详情首屏和计算结果主显示。摘要/记忆旧白底随后在5ac3353c修正，最终复看因超时保留待验。

[深色双栏与计算结果（27ef8afc）](</Volumes/CodexProjects/Codex/D-Development/AgentTrials/UI-PRESENTATION-REBUILD-01/run-20261010-function-organization/gui/09-final-tools-dark-27ef8afc.jpg>) · [统一设置与范围说明（27ef8afc）](</Volumes/CodexProjects/Codex/D-Development/AgentTrials/UI-PRESENTATION-REBUILD-01/run-20261010-function-organization/gui/10-final-defaults-dark-27ef8afc.jpg>) · [浅色展开上下文及资料（27ef8afc，仍显示旧白底）](</Volumes/CodexProjects/Codex/D-Development/AgentTrials/UI-PRESENTATION-REBUILD-01/run-20261010-function-organization/gui/11-final-context-light-27ef8afc.jpg>) · [消息历史详情（27ef8afc）](</Volumes/CodexProjects/Codex/D-Development/AgentTrials/UI-PRESENTATION-REBUILD-01/run-20261010-function-organization/gui/12-details-light-27ef8afc.jpg>)。

实际完成：计算0.1+0.2并保存0.3记录；工具↔资料切换保持输入/结果；设置默认规则草稿跨页保留及放弃；消息/会话菜单、成果、声音、文件和凭据页面打开；Command–逗号与齿轮路由一致。27ef8afc冷开副本后草稿/结果保留，实际插字后Undo精确恢复原草稿。恢复跟随系统主题、14pt，动效等原偏好保持。未加载模型、连接MCP、调用搜索、写入记忆或录音。

文件→打开项目选独立副本：

[Function review.dproject](</Volumes/CodexProjects/Codex/D-Development/AgentTrials/UI-PRESENTATION-REBUILD-01/run-20261010-function-organization/gui/Function review.dproject>)

其中text:fixture不可运行；24节长文是合成展示资料，不是模型成果。原始UI review.dproject所有文件摘要未变；副本仅增加一个计算记录，原草稿、消息、请求快照及预设逐项相同。真实Finder拖放、资料采用组合、模型停止与连续动效不由此替代。

证据根为外盘 run-20261010-function-organization；lead中保留构建、测试、native-final-stop、data-protection及delivery-review。旧R9的key-window前置失败、右缘2pt反例和旧桌面失败继续有效。无需重制网页原型；本轮批准的新功能位置优先于旧原型。

## 同树 Xcode Run

打开 /Volumes/CodexProjects/Codex/D-Worktrees/D-UI-PRESENTATION-REBUILD-01/D.xcworkspace，选 **D Nodes / My Mac / Debug**。本轮普通构建成功，未点击Xcode Run。既有Development.local.xcconfig仍使用外盘已授权开发资源；不改签名/权限或重复下载，换机见[Development](../Development/README.md)。
