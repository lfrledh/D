# D 节点工作面候选

2026-10-10 · **UI-PRESENTATION-REBUILD-01 / R16** · 生产 **67b1472efed99bc63c87ced5152de62d75c5ba06**。用户已认可R15实际性能改善，本版继承R14/R15，完成节点连线、卡片与功能归位的实现。

## 唯一试用入口

[启动聊天当前验收.command](/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261004T145523Z-continuous-closeout/delivery/启动聊天当前验收.command)

指向 [D UI Review 67b1472e.app](</Volumes/CodexProjects/Codex/D-Development/AgentTrials/UI-PRESENTATION-REBUILD-01/run-20261010-node-workspace/delivery/D UI Review 67b1472e.app>)。普通签名/App Sandbox和7文件摘要已核对；保留隔离试用UUID，入口拒绝双开，不覆盖普通D。启动后用文件→打开项目选择独立 [Node workspace review.dproject](</Volumes/CodexProjects/Codex/D-Development/AgentTrials/UI-PRESENTATION-REBUILD-01/run-20261010-node-workspace/gui/Node workspace review.dproject>)，进入工作流→「双输入文字模板」。旧五份验收项目原样保护。

## 新入口

| 位置 | 用途 |
|---|---|
| 顶部 | 切换流程、新建、保存与流程菜单。 |
| 左侧 | 当前对象配置：概览、节点、连线或多选。 |
| 右侧 | 节点、素材、结果；结果可选择实际运行记录。 |
| 底部 | 显式选择运行终点与范围，查看计划后执行；运行中暂停/停止及历史。 |
| 左下 / 右下 | 指针/手型、撤销/重做 / 缩放、显示全部、重置。 |
| 节点卡片 | 身份、状态、端口、折叠和直接删除；省略号/右键保留选择、设为运行目标、运行到这里和仅重跑。 |

主线位于卡片后，端口短引出段属于节点本身；被遮挡的线和端口不应抢操作。运行目标独立于当前检查对象，不会自动选最后一个节点。既有“恢复保存”还会继续执行，因此显示为“恢复保存并继续流程”。

## 已验与待验

13项UI值/宿主、13项Controller/执行/保存方法最终分批通过；本地化缺键修复后单独复验。36次节点/临时线更新根、卡片和命中构造仍0，保留局部拖动；这不是FPS。全部测试后普通构建28.48秒，包签名与产物一致。

**本版尚无真实原生图。** CUA读取Finder明确报告Mac已锁定、自动解锁未成功；Agent立即停止相应GUI，未启动候选、未轮询或改变权限。全宿主事件测试另停在key-window前置、零事件，两者各自记录。不能用旧截图、构建或离屏检查替代同版原生验收。

[唯一合并待验清单](FAILURE_AND_PERMISSION_AUDIT.zh-CN.md)列明新布局静态自检、遮挡命中/双向连线、明确目标→非模型执行→保存冷开，以及连续拖动手感的步骤、预期和已验部分。Agent负责尚缺的确定性检查；用户集中观察体验，不逐项催验。详细失败与版本证据见[任务R16](tasks/UI-PRESENTATION-REBUILD-01.md#r16节点工作面分层与入口归位2026-10-10)。旧R15真实截图与性能证据保留在任务记录，不能当成本版图。F26继续延期。
