# D 节点拖动性能修订候选

2026-10-10 · **UI-PRESENTATION-REBUILD-01** · 生产 **2d2b8380c81b782a356432125ddf038f86a6f794**。本轮只处理节点拖动的额外开销，保留现有布局和交互。

## 唯一试用入口

[启动聊天当前验收.command](/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261004T145523Z-continuous-closeout/delivery/启动聊天当前验收.command)

指向 [D UI Review 2d2b8380.app](</Volumes/CodexProjects/Codex/D-Development/AgentTrials/UI-PRESENTATION-REBUILD-01/run-20261010-node-drag-performance/delivery/D UI Review 2d2b8380.app>)。实际PID35328、包路径和隔离UUID核实；入口拒绝双开，不覆盖普通D。当前已打开独立 [Node drag review.dproject](</Volumes/CodexProjects/Codex/D-Development/AgentTrials/UI-PRESENTATION-REBUILD-01/run-20261010-node-drag-performance/gui/Node drag review.dproject>) 的“双输入文字模板”，可直接拖动，无需模型。重新启动后用文件→打开项目→工作流→左上流程选择器进入。

## 这轮修复

节点移动现在只更新其外层位置和连线，不再逐帧重算整张工作面、所有卡片及连线命中区域。原生控件身份保持，松手只提交一次布局，仍支持一次撤销；折叠节点的线端跟随，反向曲线绘制范围完整。此前圆点命中、前景连线、两工具分工及右键/剪刀入口保留。

相同36次连续位移的宿主测量：工作面重算72→0、卡片216→0、连线命中区144→0；实际端口仍有36个中间位置。17个相关方法分批通过，最后2方法复验通过不重复累加。普通构建28.98秒，签名/App Sandbox及7个包文件摘要匹配。这些是开销/行为证据，不是屏幕帧率。

## 同版原生检查

已实际操作pointer/hand拖节点、折叠后拖动与展开、空白平移、移位后线右键断开及一次Undo恢复原ID、空处释放和保存。新快照仅改变测试节点位置，内容、连接、运行、资产与工具不变；旧项目75/77及上一轮用户保存后的81文件、个人scheme和源/main保持。

- [拖动后的节点与连线](</Volumes/CodexProjects/Codex/D-Development/AgentTrials/UI-PRESENTATION-REBUILD-01/run-20261010-node-drag-performance/gui/02-pointer-node-moved-2d2b8380.png>)
- [拖动后的连线菜单](</Volumes/CodexProjects/Codex/D-Development/AgentTrials/UI-PRESENTATION-REBUILD-01/run-20261010-node-drag-performance/gui/06-moved-wire-menu-2d2b8380.png>)
- [保存后的全景](</Volumes/CodexProjects/Codex/D-Development/AgentTrials/UI-PRESENTATION-REBUILD-01/run-20261010-node-drag-performance/gui/07-saved-overview-2d2b8380.png>)

均为2d2b8380真实画面；独立复看无新增静态问题。截图不能证明在途每帧同步或持续FPS。当前工具无法分离按住拖动/释放，未用松手后的Escape冒充手势取消；宿主取消复位已验，原生按住Escape后立即点击仍保留。向上越过原边界松手时仍沿用旧坐标原点重定位逻辑。

## 剩余观察

[唯一集中队列](FAILURE_AND_PERMISSION_AUDIT.zh-CN.md)继续保留连续拖动手感/帧率、按住取消后的即时命中、缩放/失焦组合，以及旧镜片、输入滚动条、材料拖放、阅读/停止与封装余项。Agent承担可独立完成的检查，未把实现错误转交用户。旧R13的双向边缘连线与冷开证据按旧版保留，本轮未重复全矩阵。没有加载模型或扩展音频/E/收费/搜索，F26继续延期。
