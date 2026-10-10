# D 系统性 UI 性能修补候选

2026-10-10 · **UI-PRESENTATION-REBUILD-01 / R15** · 生产 **f1dec35fd816caf3f2219ad94131ea623ccaf588**。继承R14节点局部拖动，保留布局、功能和视觉默认。

## 唯一试用入口

[启动聊天当前验收.command](/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261004T145523Z-continuous-closeout/delivery/启动聊天当前验收.command)

指向 [D UI Review f1dec35f.app](</Volumes/CodexProjects/Codex/D-Development/AgentTrials/UI-PRESENTATION-REBUILD-01/run-20261010-systematic-performance/delivery/D UI Review f1dec35f.app>)。普通签名/App Sandbox、7文件摘要和实际PID41034/隔离UUID已核实；入口拒绝双开，不覆盖普通D。当前已打开独立 [Performance review.dproject](</Volumes/CodexProjects/Codex/D-Development/AgentTrials/UI-PRESENTATION-REBUILD-01/run-20261010-systematic-performance/gui/Performance review.dproject>) 的「双输入文字模板」，四节点/三连接。重新启动后用文件→打开项目；顶部工作流→左上流程选择器进入，文字/图像通过快速生成入口切换。没有运行模型。

## 六组结果

| 范围 | 操作因何减少重复工作 | 证据边界 |
|---|---|---|
| 注册表/查询 | 内置表一次初始化，参数定义和历史结果同次展示只查询一次。 | 固定Debug夹具500次注册表访问95.39→3.67毫秒。 |
| 节点状态 | 当前作用域复用图/历史分析；参数、工具、上游结果变化仍失效。 | 同四节点100轮79.71→0.42毫秒；布局/Undo不重复规划，权威执行校验保留。 |
| 画布 | R14局部节点拖动保留；临时线独立更新，未变命中路径复用。 | 36次节点/临时线更新根、卡片和命中构造均0；原生移动后右键及反向拖接成功。 |
| 聊天 | 草稿/活动输出与旧行、列表分开；父链完整校验共享索引。 | 800消息3次校验882.62→9.09毫秒；36草稿旧行/列表更新0，受控流旧行0。 |
| 文本/宿主 | 复用原生高度与Markdown配置；完整段落证明已过上限后无需再测全文。 | 长文100次测高717.88→5.91毫秒；组字/字体/宽度/缩短失效反例通过。无换行长段、隐藏宿主全面跳更新保留。 |
| 媒体/合成 | 修复预览所有者与取消边界；未新建缓存或降低画质/动效。 | 两个20秒采样PNG解码各7样本，未取得新增缓存收益依据；冷首显/峰值尚无结论。 |

以上是函数/宿主开销，不能换算FPS。13项值/状态、35项宿主相关检查通过，最后2项复验不重复计数。普通构建31.66秒，位于全部XCTest之后。缓存所有者/容量/失效、原失败及精确证据见[任务R15](tasks/UI-PRESENTATION-REBUILD-01.md#r15系统性-ui-性能修补2026-10-10)。

## 同版原生检查

已实际操作图片切换/125%/fit、草稿键入/Undo/Redo、40行内部滚动、历史词法搜索打开目标消息、双栏切换；两工具拖节点、移动后线右键断开、输入→输出反向接回、逐次Undo和保存均有直接结果。最终图内容/布局/连接身份及草稿恢复；原四份项目75/77/81/83文件摘要、源/main及个人scheme保持。

- [搜索、消息与双栏](</Volumes/CodexProjects/Codex/D-Development/AgentTrials/UI-PRESENTATION-REBUILD-01/run-20261010-systematic-performance/gui/02-chat-search-f1dec35f.png>)
- [40行草稿内部滚动](</Volumes/CodexProjects/Codex/D-Development/AgentTrials/UI-PRESENTATION-REBUILD-01/run-20261010-systematic-performance/gui/03-long-draft-f1dec35f.png>)
- [节点撤销恢复后保存](</Volumes/CodexProjects/Codex/D-Development/AgentTrials/UI-PRESENTATION-REBUILD-01/run-20261010-systematic-performance/gui/05-canvas-restored-f1dec35f.png>)
- 媒体同状态：[修前](</Volumes/CodexProjects/Codex/D-Development/AgentTrials/UI-PRESENTATION-REBUILD-01/run-20261010-systematic-performance/gui/baseline-media.png>) / [修后](</Volumes/CodexProjects/Codex/D-Development/AgentTrials/UI-PRESENTATION-REBUILD-01/run-20261010-systematic-performance/gui/01-media-f1dec35f.png>)。

原生SwiftUI短采样的历史宿主148→197次、聊天根7→10次；两个阶段未逐事件对齐，超过99.7%视图名称unknown且无layout更新，不能声称整体变快，也不足以把差异判成代码回退。媒体CPU采样827→796个Running样本的差异也没有整体提速意义；不是连续FPS或P95。正常外观未见本轮新增静态阻断，图像模态旧浅色矩形/按钮组织留下一轮设计。

## 合并待验

[唯一集中队列](FAILURE_AND_PERMISSION_AUDIT.zh-CN.md)已合并实际入口、步骤、预期和证据：当前候选连续拖动/长历史手感、按住Escape与缩放/失焦组合、无换行超长段和重媒体冷首显/长期内存，以及旧镜片、滚动条thumb、材料拖放/采用、真实模型停止与封装组合。用户主要观察体验，Agent负责可独立定位；不逐项催验。没有扩展模型、音频/E/收费/搜索，F26继续延期。
