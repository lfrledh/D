# D 节点命中、连线与平移修订候选

2026-10-10 · **UI-PRESENTATION-REBUILD-01** · 生产 **0b48129c429a7c3a9726950d6a201ce4dc3851b3**。保留现有布局、材质、镜片与输入修复。

## 唯一试用入口

[启动聊天当前验收.command](/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261004T145523Z-continuous-closeout/delivery/启动聊天当前验收.command)

指向 [D UI Review 0b48129c.app](</Volumes/CodexProjects/Codex/D-Development/AgentTrials/UI-PRESENTATION-REBUILD-01/run-20261010-canvas-feedback/delivery/D UI Review 0b48129c.app>)。实际包路径、隔离UUID与冷重开PID32256核实；入口拒绝双开，不覆盖普通D。当前留在独立 [Canvas review.dproject](</Volumes/CodexProjects/Codex/D-Development/AgentTrials/UI-PRESENTATION-REBUILD-01/run-20261010-canvas-feedback/gui/Canvas review.dproject>) 的“双输入文字模板”。冷启动后可用文件→打开项目→切换到工作流→左上流程选择器打开它，无需模型。

## 这轮变化

- 端口接线只命中小色点附近的22点圆形区域；标题/说明可拖动节点。指针工具仍支持两个方向起拖。
- 已存线和正在拖出的线都在节点前景，点到卡片边缘这一段不再被卡片遮住。前景命中让位于其他端口和卡片控件。
- 手型、指针都可移动节点；只有手型拖空白才平移，指针拖空白框选。平移直接使用原生滚动，取消每帧上报造成的工作面重算。
- 右键连线可“断开连接”；线上悬停出现中点圆钮，进入圆钮变剪刀，点击断开，支持“更多→撤销”。中点恰与端口/控件重叠时不显示剪刀，仍可在线的其他位置右键。

## 同版原生证据

已实际操作端口标题拖节点、手型拖节点/空白、指针框选、正反向圆点边缘拖接、线选择打开详情、右键断开、剪刀可见圆钮上缘点击断开，以及菜单一次Undo恢复原连接ID。保存后正常退出、用同一入口冷重开，三条连接ID和新位置保留，既有运行/资产/媒体未改。原项目75/77文件摘要、个人scheme及源/main保持。

- [节点画布全景](</Volumes/CodexProjects/Codex/D-Development/AgentTrials/UI-PRESENTATION-REBUILD-01/run-20261010-canvas-feedback/gui/14-delivery-overview-0b48129c.png>)
- [悬停中点圆钮](</Volumes/CodexProjects/Codex/D-Development/AgentTrials/UI-PRESENTATION-REBUILD-01/run-20261010-canvas-feedback/gui/07-wire-midpoint-dot-0b48129c.png>) · [进入中点的剪刀状态](</Volumes/CodexProjects/Codex/D-Development/AgentTrials/UI-PRESENTATION-REBUILD-01/run-20261010-canvas-feedback/gui/08-wire-scissors-0b48129c.png>)
- [连线原生右键菜单](</Volumes/CodexProjects/Codex/D-Development/AgentTrials/UI-PRESENTATION-REBUILD-01/run-20261010-canvas-feedback/gui/05-wire-context-menu-0b48129c.png>)

上述均为0b48129c真实画面。中点状态通过在线上短拖移动指针到达；工具没有纯移鼠标API，未把未按键hover过程记为通过。截图不能证明连续跟手或在途预览的每帧状态。

15项相关测试通过，最终4项受影响方法复验通过，不重复累加；36次跨runloop平移产生36个实际中间offset，canvas/surface/retained重算均0。此为开销隔离测量，不是屏幕帧率。普通构建27.85秒，严格签名/App Sandbox及7文件与普通产物一致。

## 剩余观察

[唯一集中队列](FAILURE_AND_PERMISSION_AUDIT.zh-CN.md)保留实际步骤：纯hover与在途线连续过程、密集交叉及缩放后命中、失焦/Escape取消、手形抓握全程和大图连续平移手感。其他镜片/面板、输入滚动条、材料拖放、阅读/真实停止、新建封装组合按原版本继续，不因本轮通过关闭。Agent承担可独立完成的检查，不将确定的实现错误转交用户。

本轮没有加载模型或扩展音频/E/收费/搜索，F26继续延期。R12超时与旧失败保留于任务回执；同版操作明细在R13/lead/native-review.json。
