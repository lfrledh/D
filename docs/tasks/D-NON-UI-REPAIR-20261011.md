# D 非 UI 可靠性修补与有限文档整理

2026-10-11 · D-NON-UI-REPAIR-20261011 · 实施中，本地候选；不合并/推送/部署/UI改版。

## 身份与复用

原审计 B `178d5685e1ff953e790a7e6dc112273d6f7e54dc` → 原有限补丁 P `bb821f1fe31a263d33b1feeb33ee3cf3e7294d74` → 用户此次批准的两处 A2 收尾 `708e35f4531b0dfe2ec7a0ca1a11b335b12496c4`（本轮起点）。A1/A3沿用P独立复审与原有效证据；没有重新实施。P01/P02的最新版本仍存在，已按最新用户授权修补；旧初交/两次返修/Lead收尾预算不改写。

A2产品代码在 `d34ddd79f0f8d7c6a8084d0bd8406fe91eee0f93`，随后两提交只改测试。原P产品反例先失败；`5cc4d9d7c0357a5f71bd1e56701de8bebf51c8dd` 68方法/4suite通过，708再定向1方法/2场景通过。不是69个不同测试。非实现者`a2_closeout_review`接受源码/受控层；登记后项目切换的旧controller提示不承诺在新项目可见，普通App未验。旧Backend锁覆盖仅是A2受控条件，不关闭DIA09。

本轮固定入口保护详见[当前行动](../CURRENT_ACTIONS.zh-CN.md)。任务包19个文件已按清单核验；审计原件不变。外盘唯一证据根（下称R）：`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-NON-UI-REPAIR-20261011/run-20261011T095142Z`。主说明为本页，最终只有一份独立复审报告；日志/原失败与完整差分留R，不复制媒体入Git。

## 问题、风险与最小证据

| 项目 | 起点复核与修补 | 验证/状态 |
|---|---|---|
| DIA09 | UI锁缺完整闭包，App真实外workspace缺锁，development脚本查错内workspace。已有Backend固定pin作为来源，实际严格解析要求21项；19项缺NIO的失败保留，无依赖升级。脚本现在检查实际外层锁，测试入口固定依赖，支持独立App包缓存。 | 严格解析21项通过；development脚本20项通过。新增缓存参数初版Bash3空数组失败，经非实现者发现并修，定向1项通过。最终组合干净测试/实际App脚本构建待完成。 |
| DIA05 | 原审计反例在本轮起点再失败：只读backup重新授权旧Quick字节。 | Store组修补/真实Quick保存反例待组合验证。 |
| DIA08 | 原审计结构化引用反例再失败。 | 完整引用、嵌套/工具/历史定位待组合验证，不改计数单位或删除决策。 |
| DIA06 | 原服务反例再失败；待发布图像因模型不可用不能保存。 | 实际Controller恢复链与部分候选待组合验证，仅同存活Services内存pending。 |
| DIA04 | 两类权威错误与取消并发的原反例再失败。 | Services/实际历史消费者待组合验证；不改Runtime隔离政策。 |

原始反例：`lead/nonui-before-{command,result}.json`、`logs/nonui-before.log`（3方法失败）；`lead/dia04-before-{command,result}.json`、`logs/dia04-before.log`（1方法两类错误失败）。A2首次新增夹具编译失败单独保留，不计行为反例。修后测试、最终不可变版本及复审结论将在此原位补齐，不以实现者自述关闭问题。

## 协作与边界

Lead协调A2、构建、集成和文档；Store与图像各一位独立CLI Worker，分别负责DIA05/08与DIA06/04。请求及实际可观察上下文均为`gpt-6.1-sol/high`、`workspace-write`、network=false、approval=never；每人独立物理树、分支/索引、output/tmp，公共Git不授写。预检之后才IMPLEMENT；无递归。模型隐藏服务端解析unknown。各新任务初交25分钟（持久化/异步身份复杂度）、最多两轮定向修复；旧A2预算不借此刷新。

Git shim只读查询发出FSEvents/cache发现诊断，xcrun缓存在获准tmp；Lead检查后明确用已选Xcode的Git，未扩权限、未重试外部写入。运行上下文和异常记在R/workers各目录。未观察到成功越界；系统内部不可见部分不声称证明。模型身份不是质量保证，Lead/Worker/复审归因和消耗以实际记录为准，完整Lead归因与订阅费用unknown。

## 文档整理与历史

[历史索引](../history/README.md#non-ui-20261011)列明整理前固定P与替代入口。CURRENT只保留当前任务/保护/下一步，R1—R16失败/反馈/预算在固定全文及原任务可取回，原生门槛保留在[集中队列](../FAILURE_AND_PERMISSION_AUDIT.zh-CN.md)。PRODUCT_GOALS只修正节点/组合/UI“尚未实施”漂移；REPOSITORY_MAP当前表按格式20定位，旧schema12/16表固定归档，旧包/兼容保留。META/HUM重复联合段落改为自身贡献和固定T0/AUDIO原文链接；AUDIO两处相对断链修正。不迁走许可证或有效契约。

整理前后字节、位置与链接核验将保存于R/lead/docs-map.json；固定历史不重复复制，因此现行篇幅减少不意味着删除历史。本轮未清理退役代码或旧候选。

## 尚未证明与恢复

构建、受控CPU、普通App、真实模型和发行分开。此次不重跑模型、GPU、全故障矩阵；服务注入错误不能写成全部真实后端已触发并验证。普通App文稿发布/资产查看/保存冷开、A1—A3原生及R16布局命中/输入/拖动等仍须明确移交；不因代码审阅关闭。

保留全部候选/证据与源个人修改。恢复或对照用固定提交另建独立工作树；不reset、覆盖原项目或改写历史。最终SHA记外部回执，不自引用amend。本轮结束后等用户继续UI，不自动启动下一阶段。
