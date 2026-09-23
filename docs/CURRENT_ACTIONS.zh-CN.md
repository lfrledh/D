# 当前行动与接手点

核实：2026-09-24；current。本页只回答当前状态和下一动作。当前任务为[模型节点说明原型](tasks/D-NODE-CATALOG-01.md)，上批整理见[历史回执](tasks/D-CONTEXT-RESET-01.md)。源码能力见[支持表](MODEL_SUPPORT_AND_RELEASE.zh-CN.md)，代码入口见[导航](REPOSITORY_MAP.zh-CN.md)。

## 当前授权与停点

用户批准 D-NODE-CATALOG-01：保留图像/文字/音频/视频分页，在每页增加“模型节点”，展示源中已适配的模型/变体、引擎/精度/设备、操作输入输出及必选/可选条件、推理前参数与空白用户标签。本轮**不做组合或节点执行**，不合并旧 AP1/CORE 候选，不改后端/作品 schema。

准备基线 `9fde96c625e86add2de8acb5e47ac9a52b71a5dc`；两项受限 Worker 独立实现数据与视图，Lead 接线/审阅/串行验证。组合 `23fc4364c5b04c40db29f25e53a7756611306445` 已通过工作台CPU、普通签名App构建、隔离原生GUI，并快进接纳至源、从源入口复验8+3项通过。最终仅文档结案SHA及推送结果以任务末尾和外部 final-receipt 为准。参数为说明，不会提交执行；标签只写本机偏好，独立测试使用隔离 suite。

D-CONTEXT-RESET-01 S0—S5 已结案；其 S6 组合提案被本次明确的原型顺序替代，未自动获准实施。文档整理与原型均不刷新其他候选的失败/修复预算。

## 源、受测代码、应用与候选分开

| 对象 | 固定版本与状态 | 证据能说明什么 |
| --- | --- | --- |
| 本轮源受测代码 | `23fc4364c5b04c40db29f25e53a7756611306445`；`codex/inference-foundation`已接纳，后续仅本文/任务结案 | 12模型/变体说明、端口和只读参数、可持久用户标签；不是组合或新推理能力 |
| 本轮隔离原型App | 本任务run的`cache/DerivedData/Build/Products/Debug/D.app`；代码23fc436… | 普通签名构建及真实原生UI通过，测试项目/偏好隔离；未替换普通D |
| 上批整理前源与远端（历史） | `codex/inference-foundation`，`b334920907de0324bf3e0146bb78433742356a6c`；上批整理时读远端确认相同 | 整理阶段只改文档；本轮在其上增加节点说明 UI。不可用该旧版本代表本轮 UI 受测代码 |
| 最近R9源验收代码 | `8fb7d48e14ba4e140177925905ddb8130751617d`；到b334仅4份文档变化 | 58 CPU＋3反例及完整正负首步历史证据；不是全模型本轮重测 |
| 最近有明确真人链路的隔离App | AP1受测`54721d91a535e71d01c9caeba86c04277fbbb933`；`D-Development/AgentTrials/D-AUDIO-PROJECT-01/run-20260916T120640Z-human/lead/D Audio Guarded.app` | 本轮只核实包存在/关键摘要；不是最新源重建。普通D是否同版unknown，不启动核对 |
| AP1独立候选 | `codex/d-audio-project-01`，`e5d24f4e1064423238e3c8e1112bc4b3a9a81e2e` | 歌声CPU/音符纠错等App验收与schema15在候选；源schema12。候选未直接源接纳，已进入CORE候选历史，不能混称当前源App |
| CORE组合候选 | `codex/d-core-close-01`，`9d3a503d327a820cb67e399922a07c27f953e903`；实际改码`aeb7e6a694997e3577abb056800740c3d70550e8`，之后仅文档 | AP1＋GPU歌声部署/记录组合，包装夹具24＋独立33、Swift parse等局部证据；尚无组合全构建、真实App/存储验收。冻结保留，不接纳 |
| CORE全50步参考运行 | `D-Development/AgentTrials/D-CORE-CLOSE-01/run-20260921T175000Z/video/full50/` | 9月22日正常结束约10小时54分；固定1216×736/121帧50步latent、首步及attention对照通过；无解码/MP4/全帧画质、完整D条件管线或App I2V通过 |

上批整理登记131个已有工作树；该清单为当时快照，保留在整理任务外部证据，不复制到每个任务。候选任务可用固定对象读取：`git show 9d3a503d327a820cb67e399922a07c27f953e903:docs/tasks/D-CORE-CLOSE-01.md`；它未在源出现不表示丢失，也不授权合并。旧视频失败、CPU参考与预算继续在[视频任务](tasks/D-VIDEO-I2V-01.md)。

## 保护、资源与待办

- 源唯一未提交项为个人scheme排序（orderHint 1→6），索引干净。完整差异、摘要、索引和小副本在本轮`protection/`；不得暂存/恢复/复制到任务树。源每次推进前后逐项核对，不称源工作区完全干净。
- 外盘物理路径/共同Git目录已核对。已知旧Worker停写；旧full50子进程已回收，guard记录进程组不存在；本轮DATA/VIEW、审阅、构建/测试均结束，两个隔离App正常退出，记录在任务末尾。这是观察，不是系统写锁，也不证明任何时刻全机空闲。
- 本轮按影响进行 CPU/原生 hosting、独立 App 构建及隔离 GUI；无需 GPU 推理、下载或新引擎。本次不证明旧模型/发行/候选的验收通过。日常授权见[协作规程](MULTI_AGENT_WORKFLOW.zh-CN.md)，不恢复空闲审批。
- H22输入法候选窗跟随位置仍不正常，输入确认正常；用户延期到专项UI。H23音符试听/缩放和H24 GPU歌声试听已关闭。麦克风旧待办不能再次当未配设备；本人待办唯一入口为[集中清单](FAILURE_AND_PERMISSION_AUDIT.zh-CN.md)。本原型验收未新增需要本人操作的待办。
- 旧AP1包装修复两轮/Lead有界IME收尾已耗；CORE的PACK/RECORD初交历史、I2V各轮预算按原task/run保留；新整理编号不增加余额。没有冻结的新产品规格时不续派。

## 恢复与下一步

先核对 Git、源 scheme、任务目录/进程，再读取[当前任务](tasks/D-NODE-CATALOG-01.md)末尾恢复点。证据在 `D-Development/AgentTrials/D-NODE-CATALOG-01/run-20260923T150725Z/`，任务记录区分初稿、返工、组合 CPU、构建和原生 UI。未提交候选或“构建通过”不等同已源接纳。

本阶段模型说明原型已完成并本地接纳；推送最终回执位于上述证据根的`final-receipt.json`。参数只读展示，用户标签可编辑。本阶段到此停止。用户正在研究组合方式和新 UI；下一阶段先由用户审阅模型/端口表达，再冻结其具体方案，不先开发组合器。AP1/I2V/CORE仍为独立候选债，首发范围与历史预算保持原记录，不因新增说明页面被标为已修复。
