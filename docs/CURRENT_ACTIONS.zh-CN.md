# 当前行动与接手点

最后核实：2026-10-02。当前任务、真实基线、候选、阻塞和下一动作只从本页进入。历史回执不自动授权续跑。

## D-RELEASE-FREEZE-01 / D-DISCUSSION-FREEZE-20261002

本轮实现收尾，**部分完成**；正在交付公开开发主线及同版App，原生/质量/文件入口缺口保持未关闭。结束后等用户试用与冻结判断，不增加模型/平台、不进入正式发行。

- main为唯一公开开发集成线，用户已批准有限门槛后正常推进，不要求全部发行QA先过。首批已推b5004991e0323c976e4ba3f8bf55774b28222cb6；最终main与远端核对见R/lead/final-receipt.json。非强推，无Release或许可证/收费变化。
- 代码、最终文件CPU及正常App受测版本：**ca2121c771d6b7cd65a1d8f068440fdf7bba9221**。后续只更新本轮文档；最终SHA见回执，不把尚未产生的文档SHA记为重跑测试版本。
- 实施/同树Xcode：`/Volumes/CodexProjects/Codex/D-Worktrees/D-RELEASE-FREEZE-01`，分支`codex/release-freeze-01`；干净main集成树为同级`D-DISCUSSION-MAIN`。唯一启动器见[试用指南](RELEASE_FREEZE_TRY.zh-CN.md)。两版README对外描述开发预览，不链接私人目录作公开下载。
- 旧main708f5fbb7e5e78b5583c487a67329c0eeaf6e5cf已保留`archive/main-before-refresh-2026-10-02`及验证过的D-main.bundle；六个历史子模块bundle覆盖准确gitlink。路径/摘要见R/lead/main-backup.json。同SSD备份不是异地容灾，不含所有未提交数据/模型。
- 保护源仍`/Volumes/CodexProjects/Codex/D`、`codex/inference-foundation@01758b81527dc27eb4563bf1b66fd1ceab6647ee`。个人scheme仍未暂存orderHint1→6，SHA256`ca3635d88aa5a15397b90e528667c66c0e6db7e596176e885c79d194b544206c`，索引保持旧值；不切分支/暂存/还原。当前main不再经过这个旧源。

R=`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261002T062206Z-discussion`；R4为同级`run-20261001T162316Z-r4`，R3为同级`run-20261001T040512Z-low-memory`。详细变化、失败、预算和验收映射只保留[任务记录](tasks/D-RELEASE-FREEZE-01.md)最新“讨论冻结本地实现收尾”段。

## 当前能力与证据边界

| 切片 | 已实现/实测 | 未闭合 |
|---|---|---|
| W1公开开发线 | 旧历史可恢复，双语README、About/Topics准确；正常推main不触发发行 | 公开源码不等于开放许可证、正式安装包或功能冻结 |
| W4A模型导入 | 原位引用/独立复制，固定必要树校验，外部附加文件不删不执行；共享ModelLibrary与执行读取一致。64项模型库、35项Qwen/Flux、23项图像目录检查；Dev原目录metadata/header准入通过 | 原生文件面板/即时就绪刷新待H32；不是任意模型格式发现 |
| 本轮真实计算 | cd4cd4b Qwen9原始精度SSD四采样帧正确先红后蓝；Klein BF16取消/完整生成/有序双参考归零，两份固定PNG与R3字节一致 | 非任意确定性/大内存常驻证明。其余未变的长计算沿用R3/R4，不重复生成 |
| W4B媒体与位置 | 固定资产版本、引用/独立副本、在途快照、同内容重定位/收纳；普通副本深检漏比摘要先失败后通过。独立实例ID防恢复项目串写 | **文件UI切片预算耗尽**：Quick原件失联且另有命名Canvas项目时，资料库先预览失败，不能进入该条目的位置页；服务可用，入口未闭环。详情仅本项目已知使用计数，无导航关系清单/Finder入口/离线库聚合；lastVerifiedAt未随显式深检持久更新，副本时间未独立展示 |
| W4C手动备份 | 默认元数据+媒体，可选模型、缓存不含；先保存Quick/Canvas草稿，取消/失败/换项目不发布；恢复新目录及独立实例、原件保留。结构音乐、嵌套工具/历史、源位置不可用恢复通过 | 原生文件选择/恢复操作和真实NAS未测。模型恢复需正常重新登记，设备授权不复制 |
| 最终组合CPU | ca2121c：UI28项/文件与备份服务36项通过；非实现者审阅关键Lead修改和两项修复，无新增数据损坏风险 | 组件通过不关闭原生/hosting失败。新增入口缺陷已单列，未“测试绿就全部完成” |
| H22 | DEBUG显式开关的自然client firstRect透传与cursor set/push/pop来源诊断可编译，非实现者审阅通过；不记录正文 | **未定位/未修复**候选不随动和指针回退；未提交组字消失是跨App线索，未在D复现。Mac locked阻塞自然输入和正常包复验 |
| W3质量 | 4份旧完整LTX/H3视频全部帧已看，R/quality可直接查看原MP4；真实上游条件/采样代码CPU哨兵排除一项跨帧mask冻结假设 | LTX红区域持续/H3首尾跳变原因及通用控制质量未定；真人音轨/审美未验，不改称模型固有限制 |
| E01性能 | 1000条元数据索引、20次标签筛选/100条标签保存重开观测；默认浏览不散列媒体 | workflowState仍读取/散列流程快照；不是零I/O、键入延迟或全部规模/NAS保证 |

## 唯一集中本人清单与下一动作

桌面工具本轮最后明确返回`Mac locked / apps=[]`，证据R/lead/native-final-blocker.json。不要无状态变化重复检查/解锁；不关闭旧D或要求重复授权。H22、H32和必要旧产物试听/质量判断统一在[集中待办](FAILURE_AND_PERMISSION_AUDIT.zh-CN.md)。H31及已关闭录音、断网/Xcode事项不重开。

新普通App通过正常签名构建与入口只读检查，但**锁屏未启动本包、未点Xcode Run**。两项旧hosting未到达真实目标的失败保留；解锁后换到可见路径才能补，不无限AX遍历。待用户返回先保存退出旧D，再用唯一新入口集中办；诊断包和关闭诊断的正常包结果分开。

## 恢复与停止规则

Model/备份/文件UI/Qwen受限Worker均已交回；本轮自有模型/CPU/构建作业终态和最后保护快照见R/lead/final-receipt.json。CLI为可观察gpt-6-sol/high，hidden解析/完整Lead消耗/订阅费用unknown。文件UI初交+两修复+一次Lead接管已经用尽，下一次修改必须先明确新的有限修补范围，不能换编号重置。其他切片旧额度和失败见任务记录。

恢复核真实HEAD/index、个人scheme、活跃句柄/已知写入者及受测二进制，不只相信摘要。源码/测试/引擎无变化的历史结果按影响复用；旧App、模型、项目、候选、外盘证据不删除。AP1/CORE/I2V候选不自动合入；Pitch内嵌评估权重、首次使用/升级恢复、依赖/渠道与许可等[发行责任](MODEL_SUPPORT_AND_RELEASE.zh-CN.md)仍在。

**公开主线可更新；本轮全部用户闭环、功能冻结和正式发行尚未通过。** 下一步停在用户试用和冻结判断，先处理上述具体缺口，不恢复开放式模型扩张。
