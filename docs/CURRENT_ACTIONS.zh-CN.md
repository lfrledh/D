# 当前行动与接手点

核实：2026-09-24；current。本页只回答当前状态和下一动作。当前任务为[UI开发前收尾](tasks/D-UI-READINESS-01.md)，上批整理见[历史回执](tasks/D-CONTEXT-RESET-01.md)。源码能力见[支持表](MODEL_SUPPORT_AND_RELEASE.zh-CN.md)，代码入口见[导航](REPOSITORY_MAP.zh-CN.md)。

## 当前授权与停点

最近完成任务：[D-UI-READINESS-01](tasks/D-UI-READINESS-01.md)，P0—P4有限收尾已完成。标签N3/N4修复、N1/N6来源与接线回归、N5活动状态去重、P2后端扩展约束与P3现有DRuntime结构演练已验收。只读模型说明页保持；正式节点/图/插件未实现，未批量改后端或项目schema，未恢复旧S6/AP1/CORE/I2V。

本轮源基线`165c54471c4380eb5482312d6c2c70ab97db48a9`，已快进接纳`e24552a6de13b38c4f84baec83462f6681795bb7`并从源目录复验通过；唯一个人scheme差异受保护。隔离组合代码、CPU/hosting、独立普通签名构建、原生GUI和未参与实现者的新上下文接手均通过。此后结案仅改本页及任务记录；最终源HEAD/远端确认保存在`D-Development/AgentTrials/D-UI-READINESS-01/run-20260924T065313Z/final-receipt.json`，不为文档自引用SHA重复提交。实现、返工和完整恢复点见当前任务末尾。上轮23fc436至165c544的原型证据仍是历史，不与本轮相加。

当前停点：等待用户节点UI/UX方案，不继续开发。节点粒度、连接/画布、候选交互和图保存未冻结。开发交接就绪不代表全架构解耦或发布。CURRENT_ACTIONS是当前任务与停点的唯一权威入口，其他活动资料只记录职责/约束与版本范围。

## 源、受测代码、应用与候选分开

| 对象 | 固定版本与状态 | 证据能说明什么 |
| --- | --- | --- |
| 本轮受测组合代码 | `34ee0c5e2172a0bc5479960f7d7660567e657a30` | 标签保护与草稿、说明来源交叉检查、真实工作台接线CPU/hosting、独立App构建及隔离GUI；runtime 70项在faca752执行，到34ee其代码完全相同 |
| 本轮源接纳与源入口复验 | `e24552a6de13b38c4f84baec83462f6681795bb7`；到34ee仅3份文档 | 源目录节点相关9项UI/16项Workbench及运行时70项通过；后续结案仅文档，最终版本及推送状态见外部final-receipt |
| 本轮隔离App | `D-UI-READINESS-01/run-20260924T065313Z/cache/DerivedData/Build/Products/Debug/D.app`；代码34ee0c5 | 原生标签/损坏提示/禁生成/切页/重开通过，独立项目字节与App关键摘要不变；不是新模型或真人IME验收 |
| 上轮模型说明受测代码（历史） | `23fc4364c5b04c40db29f25e53a7756611306445`；到165c544仅两份文档 | 12模型/变体说明、端口和只读参数、可持久用户标签；不是组合或新推理能力 |
| 上轮隔离原型App（历史） | `D-NODE-CATALOG-01/run-20260923T150725Z/cache/DerivedData/Build/Products/Debug/D.app`；代码23fc436… | 当时普通签名构建及真实原生UI通过；未替换普通D，不是本轮产物 |
| 上批整理前源与远端（历史） | `codex/inference-foundation`，`b334920907de0324bf3e0146bb78433742356a6c`；整理时读远端确认相同 | 整理阶段只改文档，随后模型说明阶段增加 UI；该旧版本不能代表本轮受测代码 |
| 最近R9源验收代码 | `8fb7d48e14ba4e140177925905ddb8130751617d`；到b334仅4份文档变化 | 58 CPU＋3反例及完整正负首步历史证据；不是全模型本轮重测 |
| 最近有明确真人链路的隔离App | AP1受测`54721d91a535e71d01c9caeba86c04277fbbb933`；`D-Development/AgentTrials/D-AUDIO-PROJECT-01/run-20260916T120640Z-human/lead/D Audio Guarded.app` | 整理阶段核实包存在/关键摘要；不是最新源重建。普通D是否同版unknown，不启动核对 |
| AP1独立候选 | `codex/d-audio-project-01`，`e5d24f4e1064423238e3c8e1112bc4b3a9a81e2e` | 歌声CPU/音符纠错等App验收与schema15在候选；源schema12。候选未直接源接纳，已进入CORE候选历史，不能混称当前源App |
| CORE组合候选 | `codex/d-core-close-01`，`9d3a503d327a820cb67e399922a07c27f953e903`；实际改码`aeb7e6a694997e3577abb056800740c3d70550e8`，之后仅文档 | AP1＋GPU歌声部署/记录组合，包装夹具24＋独立33、Swift parse等局部证据；尚无组合全构建、真实App/存储验收。冻结保留，不接纳 |
| CORE全50步参考运行 | `D-Development/AgentTrials/D-CORE-CLOSE-01/run-20260921T175000Z/video/full50/` | 9月22日正常结束约10小时54分；固定1216×736/121帧50步latent、首步及attention对照通过；无解码/MP4/全帧画质、完整D条件管线或App I2V通过 |

上批整理登记131个已有工作树；该清单为当时快照，保留在整理任务外部证据，不复制到每个任务。候选任务可用固定对象读取：`git show 9d3a503d327a820cb67e399922a07c27f953e903:docs/tasks/D-CORE-CLOSE-01.md`；它未在源出现不表示丢失，也不授权合并。旧视频失败、CPU参考与预算继续在[视频任务](tasks/D-VIDEO-I2V-01.md)。

## 保护、资源与待办

- 源唯一未提交项为个人scheme排序（orderHint 1→6），索引干净。完整差异、摘要、索引和小副本在本轮`protection/`；不得暂存/恢复/复制到任务树。源每次推进前后逐项核对，不称源工作区完全干净。
- 外盘物理路径/共同Git目录已核对。上一批DATA/VIEW和两个隔离App均已结束；旧full50已回收的记录继续保留。本批TAGS/RUNTIME/CROSS实现及各一次定向修复已停写；两个自有隔离App正常退出0，构建/CPU回归均结束，只读审核与新上下文接手结束；无待用户操作项新增。这是任务级观察，不是系统写锁。
- 本轮按影响进行 CPU/原生 hosting、独立 App 构建及隔离 GUI；无需 GPU 推理、下载或新引擎。本次不证明旧模型/发行/候选的验收通过。日常授权见[协作规程](MULTI_AGENT_WORKFLOW.zh-CN.md)，不恢复空闲审批。
- H22输入法候选窗跟随位置仍不正常，输入确认正常；用户延期到专项UI。H23音符试听/缩放和H24 GPU歌声试听已关闭。麦克风旧待办不能再次当未配设备；本人待办唯一入口为[集中清单](FAILURE_AND_PERMISSION_AUDIT.zh-CN.md)。本人验证与本轮自动检查分开。
- 旧AP1包装修复两轮/Lead有界IME收尾已耗；CORE的PACK/RECORD初交历史、I2V各轮预算按原task/run保留；新整理编号不增加余额。没有冻结的新产品规格时不续派。

## 恢复与下一步

先核对Git、源scheme、任务目录/进程，再读取[当前任务](tasks/D-UI-READINESS-01.md)末尾恢复点。证据根：`D-Development/AgentTrials/D-UI-READINESS-01/run-20260924T065313Z/`。原型历史证据仍在`D-NODE-CATALOG-01/run-20260923T150725Z/final-receipt.json`，不可混称本轮重测。

本批P0—P4仅标签、说明来源、接线回归与扩展约束，现已结案，等待用户节点UI/UX方案。AP1/I2V/CORE仍为独立候选债，首发范围与历史预算保持原记录。新UI可复用接口及必须随实施提取的页面依赖见[后端扩展与服务接线](BACKEND_EXTENSION_CONTRACT.zh-CN.md)。说明原型、结构演练与正式节点执行分别报告；没有下一批自动开工许可。
