# 当前行动与接手点

核实：2026-09-23；current。本页只回答当前状态和下一动作，历史阶段不再逐段追加为“当前”。本轮唯一总回执为[上下文整理任务](tasks/D-CONTEXT-RESET-01.md)。源码能力见[支持表](MODEL_SUPPORT_AND_RELEASE.zh-CN.md)，代码入口见[导航](REPOSITORY_MAP.zh-CN.md)。

## 当前授权与停点

**D-CONTEXT-RESET-01 的S0—S5整理已完成并本地接纳**；S6只提下一阶段方案，等待用户决定。统一节点工作台是当前目标，旧模态导航仍是现有实现。不得从旧任务的“下一步”自动续跑视频、整合歌声、改UI或重构存储。文档整理不刷新任何候选的修复预算。

整理候选`codex/d-context-reset-01@cafae278acd7949385eab855e58b9d1f71271d58`已通过非实现者审阅与新上下文十题接手，源已快进接纳并复查。最终仅追加本页和任务总回执；提交/远端精确状态见本轮外部final-receipt与Git，本文不写自身提交SHA。

## 源、受测代码、应用与候选分开

| 对象 | 固定版本与状态 | 证据能说明什么 |
| --- | --- | --- |
| 整理前实际源与远端 | `codex/inference-foundation`，`b334920907de0324bf3e0146bb78433742356a6c`；本轮读远端确认相同 | 当前生产源码快照。本轮只改文档，产品代码仍等同此版本；最终文档HEAD从Git/回执取 |
| 最近R9源验收代码 | `8fb7d48e14ba4e140177925905ddb8130751617d`；到b334仅4份文档变化 | 58 CPU＋3反例及完整正负首步历史证据；不是全模型本轮重测 |
| 最近有明确真人链路的隔离App | AP1受测`54721d91a535e71d01c9caeba86c04277fbbb933`；`D-Development/AgentTrials/D-AUDIO-PROJECT-01/run-20260916T120640Z-human/lead/D Audio Guarded.app` | 本轮只核实包存在/关键摘要；不是最新源重建。普通D是否同版unknown，不启动核对 |
| AP1独立候选 | `codex/d-audio-project-01`，`e5d24f4e1064423238e3c8e1112bc4b3a9a81e2e` | 歌声CPU/音符纠错等App验收与schema15在候选；源schema12。候选未直接源接纳，已进入CORE候选历史，不能混称当前源App |
| CORE组合候选 | `codex/d-core-close-01`，`9d3a503d327a820cb67e399922a07c27f953e903`；实际改码`aeb7e6a694997e3577abb056800740c3d70550e8`，之后仅文档 | AP1＋GPU歌声部署/记录组合，包装夹具24＋独立33、Swift parse等局部证据；尚无组合全构建、真实App/存储验收。冻结保留，不接纳 |
| CORE全50步参考运行 | `D-Development/AgentTrials/D-CORE-CLOSE-01/run-20260921T175000Z/video/full50/` | 9月22日正常结束约10小时54分；固定1216×736/121帧50步latent、首步及attention对照通过；无解码/MP4/全帧画质、完整D条件管线或App I2V通过 |

本轮登记131个已有工作树，均可读取；除源scheme外无未提交改动。清单只留本轮外部证据，不复制到每个任务。候选任务可用固定对象读取：`git show 9d3a503d327a820cb67e399922a07c27f953e903:docs/tasks/D-CORE-CLOSE-01.md`；它未在源出现不表示丢失，也不授权合并。旧视频失败、CPU参考与预算继续在[视频任务](tasks/D-VIDEO-I2V-01.md)。

## 保护、资源与待办

- 源唯一未提交项为个人scheme排序（orderHint 1→6），索引干净。完整差异、摘要、索引和小副本在本轮`protection/`；不得暂存/恢复/复制到任务树。源每次推进前后逐项核对，不称源工作区完全干净。
- 外盘物理路径/共同Git目录已核对。已知旧Worker停写；旧full50子进程已回收，guard记录进程组不存在；本轮范围进程检查未见项目运行命令。这是观察，不是系统写锁，也不证明任何时刻全机空闲。
- 当前不启动GPU/GUI、构建、模型下载或新产品任务。日常资源授权/下载规则见[协作规程](MULTI_AGENT_WORKFLOW.zh-CN.md)，不恢复逐模型/空闲审批。
- H22输入法候选窗跟随位置仍不正常，输入确认正常；用户延期到专项UI。H23音符试听/缩放和H24 GPU歌声试听已关闭。麦克风旧待办不能再次当未配设备；本人待办唯一入口为[集中清单](FAILURE_AND_PERMISSION_AUDIT.zh-CN.md)。整理本身无需本人操作。
- 旧AP1包装修复两轮/Lead有界IME收尾已耗；CORE的PACK/RECORD初交历史、I2V各轮预算按原task/run保留；新整理编号不增加余额。没有冻结的新产品规格时不续派。

## 恢复与下一步

整理已结束，本轮三个只读代理均完成、无自有长进程。接手先核对本页版本、源scheme、任务树状态、已知写入者与权限，再读[本轮记录](tasks/D-CONTEXT-RESET-01.md)的结果/待完成；不要只凭聊天摘要恢复。详细本机路径和保护证据在`D-Development/AgentTrials/D-CONTEXT-RESET-01/run-20260923T141656Z/`，私有绝对路径不入公开文档。

整理结束后唯一提案是该任务的[S6](tasks/D-CONTEXT-RESET-01.md#s6-下一阶段有限提案)：少量现有操作形成可检查、有人类选择的真实组合。具体UI还待用户方案，下一产品实施等批准。AP1/I2V是独立候选验收债，不作为所有组合数据工作的全局前置，也未取消其首发承诺。旧状态与规则正文见[历史索引](history/README.md)。
