# D 当前行动指南

## 2026-09-10 集中授权续办检查点

H09/H10/H11/H12均已明确获用户批准，不再等待原授权。H12固定1.5B权重10文件880,170,545bytes完整核验；实际统一CLI连续两次中文改写完成，每轮release active/cache=0，峰值966,847,960bytes。受测二进制来自d1a5c26e3d2eda84ad7641a98b5aa33ce7f55407，候选03798abfe17229f7678f9fcd611df87da7c775ac仅后续文档；不是1.5B完整模型库GUI/取消/专业质量验收。

H11用户确认适用资格并授权固定small music四权重1,919,674,322bytes及独立依赖；下载完整核验，未代接受/注册。mlx/mlx-metal0.32.2、numpy2.3.5、sentencepiece0.2.2安装于新外盘venv，使用固定预编译wheel，原全局Python未变。首个6秒请求在计算前失败：当前Swift启动器解析python符号链接后运行基础解释器，丢失venv依赖。对照sys.prefix/find_spec确认；新建标准venv --copies保留明确真实可执行路径，CPU --inspect和完整固定权重/Vendor核对通过，未改实现/精度或注入PYTHONPATH。原环境/失败保留；此兼容限制不是SA3数值通过。

H09在独立HUM候选增加批准的用途说明和两个麦克风能力，并仅将DEBUG有效UUID+audio测试门传给recordingEnabled。Lead补正启用后仍显示“未启用”的旧侧栏文字；Sol/high受限只读复核先指出反例、后接受修正，未替代真实测试。候选372a8acadf39b92faf4b17b6315f0f63774e4cff普通既有身份签名构建成功；首版已核对Sandbox/Hardened Runtime及麦克风能力，修正版尚待重新启动/实际提示。没有替换普通D、变更Team/bundleID/钥匙串/TCC，schema4仍未源接纳。

H10用户最初已保存退出且空闲。首个自有测试PID37620创建本轮新项目后正常退出0；退出后CUA getAXState重新定位到“Model Library Acceptance”旧D窗口，尚不能确认其进程身份，未继续操作/关闭。已请用户保存退出该窗口；不能把它当本轮隔离实例。后续音频generate-copies启动被自动审批明确拒绝（仍有D运行、GPU空闲未重确认），命令未执行；没有换路径绕过。暂停GUI/GPU依赖项，独立CPU检查继续。不要再在Quit后调用D对象getAXState（工具可能重启/重定位）；用自有进程退出回执及仅枚举状态确认。

下一动作：收到退出/当前空闲证据后，重新以专属UUID启动已复核测试版，在真实“开始录音”入口交用户点击麦克风提示；完成短录音/试听与H10保存导出恢复。同时按单重任务顺序完成SA3生成/变体/重绘/取消与重复释放，以及1.5B剩余验证。许可和下载无需重复审批；当前资源拒绝不是全盘权限缺口。全部原预算/失败/来源保留，不启动新产品批次。

证据：H09 `/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-HUM-ENTRY-01/run-20260909T152120Z-h09-authorized`（preparation/label-fix、signed-build2、review/routing及两次review、app-run/result、protection-checkpoint）；H11 `/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-AUDIO-BACKEND-01/run-20260909T152406Z-h11-authorized`（authorization、download/environment/copies、environment-launch-diagnosis、generate失败、inspect-copies、retry-resource-rejection）；H12 `/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-AUDIO-BACKEND-01/run-20260909T151340Z-h12-authorized`（download-result、normal/report）。开发与用户媒体来源分开；本次Lead实施与实测，Sol只读审核；完整Lead/订阅消耗unknown。


人工协作事项的持续入口：[待办与已解决记录](FAILURE_AND_PERMISSION_AUDIT.zh-CN.md#人工协作待办持续维护入口)。用户回到 Mac 时先读此处；不把旧失败重复算作未处理。

更新：2026-09-09。只记录当前执行所需信息；历史依据按需读取，不默认加载全部报告。

## 声音工作台装配：工程验收通过，真实使用门槛待集中处理（2026-09-09）

用户授权本阶段至推送，普通派工/修复/审核已自主完成。服务与生产UI已在隔离批次接通：限定WAV/CAF PCM导入、波形/普通播放控制、原始帧范围片段与Unicode注释、安全保存重开、原件和明确float32 WAV片段导出。导入按钮冻结渲染时的项目上下文/文档，文件面板前后校验；失效操作不写入后来的文档。录音结束/待恢复文件处理已有服务与界面接线，实际设备尚未验收。

**准确的验证范围：** UI修补代码/测试b042c7ebefca0798c671a6c277254e13a1c2b7bb，定向11方法全部通过；隔离组合40ec0d7b6b1525c3a0c12cab7e00f3a6773ab63d（比b042仅UI任务记录）从组合目录运行全UI包226方法/29套件，225通过/1既有可选权重检查跳过、零失败。该组合完整独立DerivedData应用编译通过，CODE_SIGNING_ALLOWED=NO/CODE_SIGNING_REQUIRED=NO，仅编译未启动，不证明签名/沙盒/麦克风/GUI。没有重跑真实文字/图像推理；旧路径CPU回归包含在组合中，定向方法不重复相加。

**版本与交付边界：** 候选在`codex/d-hum-entry-01`，本轮获准推送以保存进度；源`codex/inference-foundation`产品仍与已验收a406af9cd8908a77ae2f013d29121164d6fc0745相同，本轮源起点55e31bd0827ca63ea23cd5b3de39bd9535637c9c之后只更新四份状态/路线文档。未把schema4或新声音路径接管源入口：UIflag不是Store迁移开关。音频DEBUG入口须有效D_UI_TEST_SESSION UUID与D_AUDIO_WORKBENCH_TEST=1，录音仍关闭。最终完整源/候选SHA和实际推送确认见外部final-receipt.json；本节覆盖较早“接线待开始”记录，但不追改当时事实。

**审核与恢复：** 服务/界面分别由Sol/high受限CLI实现，顺序执行以保护共享存储；各自初交和两轮修复后，Lead各一次限定收尾，非实现者只读审核接受相应Lead差异。不是Sol独立通过，也没有重做协作机制试验。所有本轮子执行/审核/构建/测试进程已结束；源scheme内容/摘要/索引/未暂存状态与普通D.app四关键文件保护保持，既有作品未改，工作树/证据保留。用量只保留本run逐次原始记录，完整Lead与订阅费用unknown，不宣称成本最优。

**停点与下一动作：** [人工清单H09/H10](FAILURE_AND_PERMISSION_AUDIT.zh-CN.md#人工协作待办持续维护入口)等待用户回到Mac后集中处理：批准具体麦克风能力增量及测试入口，再完成当前独立窗口的实际录音/人耳试听/导入导出/保存重开/旧项目副本迁移与界面检查。没有新音乐模型/依赖/签名身份/TCC授权。通过后再决定源默认接纳；不能把工程编译或合成PCM当作声音闭环已交付。随后优先HUM可编辑音符/MUS-0普通试听与MIDI，再接一个MUS-1受控器乐候选、紧接MUS-2歌声，TTS单列，不等全部文字/图像/META增强。

批次记录：[声音装配候选](https://github.com/lfrledh/D/blob/codex/d-hum-entry-01/docs/tasks/D-HUM-ENTRY-01.md)。持久证据：`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-HUM-ENTRY-01/run-20260909T055825Z-assembly`，从final-receipt.json按需读ui/acceptance-integration、ui-review/lead-final-verification、combination/lead-tests-ui-integrated、app-build/final-assembly及保护/推送记录。恢复先核对真实HEAD/索引/个人修改，不仅相信摘要。

## 当前检查点：H08与原声基础组件已验收，本地批次保留（2026-09-09）

用户批准本阶段直到验收和本地提交，不再逐项询问普通修补。H08已关闭：类型限定、实际容器/有符号PCM检查、宽窄滚动/Unicode组件覆盖均通过；本次Lead补齐重播false/抛错后的旧进度定时器释放。原18项断言保留，新增3项真实Timer所有权反例先在未修补实现失败、再通过；不是改接受标准。

**实际受测：** AUDIO代码939b522e038fb74a3c640ff85db84956e7959f88，21方法/2套件通过、无跳过；STORE与AUDIO隔离组合211ae96ec508e086d6ff901936cc524f02a20aa3，全UI包207项中206通过、1项原可选文字权重检查跳过、零失败；核心17方法/2套件通过。21已包含在207内，不叠加计数。组合还验证导入后移走来源、原件/片段导出、重开后持久化参数交给原生播放准备与帧范围定位，原声字节不变；未播放声音。方法、SHA/文件摘要/进程结果在本轮证据中。

**审核与归因：** 本次Lead修复一行生产代码并增加直接回归；Sol/high为非实现者只读复核，接受此差异且无剩余组件阻塞，未独立跑测试。前期Terra/Sol初交和修复、Lead接管及类型修补历史保留。当前两段审核运行设置均匹配Sol/high/read-only/approval-never，无新权限/缓存或未配对命令事件。没有新增实现Worker或重新做并行试验；隐藏服务解析、完整Lead消耗/订阅费用未知。

**交付位置与边界：** 已验收基础代码在外盘`D-Worktrees/D-HUM-ENTRY-01`、分支`codex/d-hum-entry-01`；AUDIO候选19aa520ace3003af977de7b2957189cffce31e81相比受测939b522仅任务文档。源本轮起点692ac43dc470f57f0be7ab868f0d943618099a03，后续只提交这四份状态/路线文档，产品代码仍与a406af9cd8908a77ae2f013d29121164d6fc0745相同。尚未把schema4或新声音入口设为源默认：共享会话/生产UI接线、完整应用编译、真实录音/试听/GUI和产品迁移验收仍待下一阶段，不能用组件通过替代。

**下一阶段：声音灵感工作台接线与真实使用闭环。** 唯一服务Worker先实现项目/录音/播放生命周期与保存协调；接口接纳后，UI Worker接波形、片段、备注和原生导入导出。共享ProjectSession/ProjectStore不并行写。Lead冻结异步身份/草稿版本/未保存输入/关闭失败规则，串行集成与真实验收；使用独立测试项目，不碰既有作品。当前阶段在此结案，不自动开始装配。详细边界与反例在下方批次记录；实际麦克风能力和真人窗口在可审阅实现准备好后集中核对，不为CPU缺陷要求全盘访问。

音频推理按[音乐路线](MUSIC_ROADMAP.zh-CN.md)：原声保全/试听→可编辑音符与八小节→一个受控本地器乐候选→紧接歌声，TTS单列。数据/输入工作可按依赖交错，不等全部文本/图像/META增强；当前无音乐模型接入、下载或手机实施。

保护/恢复：源个人scheme完整内容、摘要、索引及未暂存状态保持，普通D.app四个关键文件内容/大小/mtime保持；本轮自有CPU/审核进程均结束，没有推送或删除候选。批次记录：[D-HUM-ENTRY-01](/Volumes/CodexProjects/Codex/D-Worktrees/D-HUM-ENTRY-01/docs/tasks/D-HUM-ENTRY-01.md)。最终完整源/批次SHA及仅文档差异、测试/审核/保护/用量索引：`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-HUM-ENTRY-01/run-20260909T040308Z-h08-acceptance/final-receipt.json`。旧失败证据不覆盖，恢复先核对真实Git状态和活动任务。

## 最新结案：T0 工作台、PNG 配方交接与人工遗留项

2026-09-08，本轮有限里程碑已本地集成并通过验收，未推送。**本节覆盖下文历史停点；没有启动下一产品批次。**

- 源分支 `codex/inference-foundation` 从 `1d290a847766e69324d9b999ed8cc49425e2d07e` 快进至组合受测 `685ef0502586bc5785826a3dc938622d8401f0e7`。隔离组合和源目录各自165方法/22套件通过，源入口实际指向源文件。正常签名构建、同次8/8 UI、真实文字/图像与中文组字缩放在 `a6c516ad6b52c944ce70a0bd764d68a94fd0f3bc` 验证；到685ef仅文档变化，代码/测试/夹具/工程/执行入口一致。之后本地结案提交仅文档，最终完整SHA见下列外部回执。
- T0：同一项目内新建文稿，选段改写、候选预览、接受/拒绝/受保护单级撤销、安全保存和重开已接线并真实验收。选区/正文版本改变使旧候选失效；中文、组合字符与emoji按Character边界处理。正文持久化，临时候选/选择/撤销不跨关闭保存，关闭前需处理候选。当前固定小文字模型只证明流程，不保证专业写作或音乐理论质量。
- PNG：实际任务配方的公开/私有预览、新副本导出、另一项目离线读取、显式创建新草稿及重开已验收。只恢复可用提示词与seed，不恢复完整环境或自动运行；公开提示词隐去时不能创建伪空草稿。原媒体非D块字节保持，外部元数据不执行，原件/已有目标不覆盖。
- 最后一项全新DerivedData普通签名产物恢复已通过：自动恢复图像项目、真实蓝杯作品和FLUX目录可访问状态；配方草稿保留Unicode和最大UInt64 seed；v2及中文文稿重开成功，Qwen已校验选择恢复。v1/v2原始备份逐字节相同、原图片未变。未修改真实用户作品、未重新申请系统权限；这不是公证、发行、任意未来构建或永久TCC保证。
- 用户报告的窄窗口裁切已修复并接纳：分栏/工具栏随宽度重排，原生编辑器身份和选区保留；最终真人明确“输入与缩放均正常”。人工清单H01—H05/H07本轮事项关闭，H06仅在实际新提示出现时处理。

证据根：`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-T0-WORKBENCH-01/run-20260908T125225Z-human-finish`。索引 `final-stage-receipt.json`；关键 `final-fresh-restore.json`、`final-fresh-restore-files.json`、`final-merged-acceptance.json`、`final-source-acceptance.json`、`source-ff-result.json`；原始失败与所有历史验收继续保留。任务：[T0](tasks/D-T0-WORKBENCH-01.md)、[PNG](tasks/D-META-PNG-01.md)。

来源：Terra完成既有组件实现及记录中的有限返工，Astra负责共享装配、实际修补和产品验收，Sol/high做非实现者只读差异审核；本次续办只有恢复/集成/文档与只读进展汇总，没有再次修产品代码或追加Worker修复轮次。路由与沙箱为可观察证据，隐藏解析和完整订阅费用仍unknown；不能据此认定成本最优。

恢复检查点：本轮自有应用、CPU、构建和子任务均结束；候选/证据保留。源索引干净，唯一个人scheme排序差异保持未暂存（SHA256 ca3635d88aa5a15397b90e528667c66c0e6db7e596176e885c79d194b544206c）；原普通D.app四个关键文件内容/大小/mtime均保持。产品代码已进入本地源分支，但旧普通D.app未替换；已验收的新应用仍在本轮 `signed-build/DerivedData-fresh/Build/Products/Debug/D.app`。

下一建议是一个较完整的“声音灵感工作台”里程碑：短原声导入/录制、波形定位和普通试听、独立片段与备注、安全保存重开及音频导出；Lead先冻结音频资产/时间/迁移契约，再按就绪度把存储与音频服务/视图交给0—2 Worker。仅为提案，格式与时长上限、麦克风权限增量及真实验收另行明确，不在本轮开工。之后紧接可编辑音符/八小节受控音乐/歌声路线，见 [音乐与HUM](MUSIC_ROADMAP.zh-CN.md)；不以全部文字增强或META完成为前置，不下载模型/声库。

## 历史基线与范围（由上文最新结案覆盖）

- 源本地检查点仍为 `6735266933773adaee33b3a66a01b09c0b1f7d9b`，codex/inference-foundation；上一批已接纳记录复用。本轮 [D-T0-WORKBENCH-01](tasks/D-T0-WORKBENCH-01.md) 候选完成工作台/生产保存接线，受测代码 `62fc7b5dd568e5f53354382dd189d09e96b7e0bc`：142 CPU/离屏、核心17及隔离无签名App编译通过，非实现者审核无剩余静态阻塞。**真实改写/GUI待验收，未源接纳、未推送、未默认启用schema3**；最终候选文档SHA见任务外部回执。默认协作仍按就绪度0—2 Worker，不重新试验。
- 历史服务阶段起始提交：`28cbb6c`，分支 `codex/inference-foundation`。
- 已验收：纯核心、真实文本／图像后端、单项目图像工作台、D-F03 应用服务分离、D-M01 模型安装到真实出图、D-W02 / D-W04a 多文档探索与比较。
- 最新检查点：[多文档探索与比较验收](EXPLORATION_STAGE_ACCEPTANCE.zh-CN.md)，源码和运行证据见对应 JSON。提交及远程同步状态以 Git 为准。
- UI 逻辑：项目拥有多份创作文档，模型为共享资源；多文档 v2 已验收；快速草稿另行排期。
- 当前硬件：M4／16 GiB，外盘优先；单个重推理任务，固定 FLUX.2 Klein 4B q8、512²、4 步、guidance 1。

## 最小阅读入口

1. `AGENTS.md`：长期不变量、工具和验证要求。
2. `PRODUCT_GOALS.zh-CN.md`：当前目标行、状态、依赖与启动条件。
3. `decisions/0007-project-information-architecture.md`、`decisions/0008-application-services-and-provider-evolution.md`：本轮设计边界。
4. 相关实际源码和测试：DInference／DRuntime、UI package 与 D 应用装配；不要从文档推测接口。

## 工作包和验收

| 包 | 交付 | 状态 |
| --- | --- | --- |
| A | 设计文档；真实 DWorkbench target；无视图项目／任务服务；兼容 v1 与旧生命周期 | 已验收 |
| B | 固定模型库、外盘授权、下载暂停／恢复、完整校验、安装租约与模型管理 UI | 已验收；管理库跨盘搬迁另列 D-M02 |
| C | 普通沙盒真实安装到生成／保存／重开；失败恢复、服务与核心回归、外观／键盘验证 | 已验收；2 张参考图片、运行中取消交接、后台安装、恢复均通过 |

模型目录约束不能因下载索引而放宽；索引／暂存放在模型安装之外。原来已准备的模型可登记完整验证，但不能以此代替下载路径验收。

## 复验入口

- `./scripts/test-foundation.sh`：无模型核心回归。
- `./scripts/test-workbench.sh`：项目、应用服务、安装器 CPU 测试；真实模型结果另行记录。
- `./scripts/build-local.sh`：正常 Debug arm64 沙盒构建。
- 涉及后端文件／资源边界时按改动运行相应 MLX 测试；数学与资源算法变化时复验真实取消、释放、峰值和数值。
- XCTest 宿主测试后重新正常构建，确认没有测试签名例外，再验证真实沙盒权限。
- CUA 流程、XCTest 执行、CPU fixture、真实网络与 GPU 结果分开报告；未执行不记为通过。

## 当前检查点：可持续探索与比较已验收

[总体规划](PRODUCT_STRATEGY.zh-CN.md)、[工作包](EXPLORATION_STAGE_PLAN.zh-CN.md) 与 [验收及证据](EXPLORATION_STAGE_ACCEPTANCE.zh-CN.md) 是本阶段入口。D-W02 / D-W04a 完成：独立创作、候选整理、比较、条件复用、采用与重开；v1 原字节备份后迁移 v2，图片不改写。

最终 CPU 82 项通过，核心 17 项通过，关闭协调 2 项通过，8 个不同 UI 场景按完整和定向运行通过；真实正常沙盒 4 次新提交、3 成功／1 取消，固定参考一致、导出和路径失联恢复通过。测试类别、各轮失败与实测限制见验收报告，不混计为一次测试运行。

导出使用系统同卷临时目录再原子发布到已授权文件，不依赖父目录宽泛授权。草稿／选择／候选元数据的已接受写入须在导航和关闭前完成；编辑弹窗绑定固定对象，失败不丢弃输入。

下一步先与用户确认参考引导／定向修改的具体创作场景，再形成单独工作包并审批。当前没有已自动启动的后续阶段。D-W04 的搜索／集合、快速草稿、其他模态和远期服务按目标表保留，不自动展开。保留用户 Xcode scheme 排序修改。

## 进入新产品阶段前：授权稳定性

历史权限和其他失败已按原因／复验／当前处理整理为 [审计清单](FAILURE_AND_PERMISSION_AUDIT.zh-CN.md)。已知历史权限阻塞对应的核心验收后来通过；UI 启动超时的具体根因未证实，不能统一归因于 D 外盘权限。

D-C01a 的只读诊断子任务 [D-C01a-DIAG-01](tasks/D-C01a-DIAG-01.md) **已本地集成并通过任务验收；未推送**。2026-09-07 源目录在 `2524fc61417ddb5fe07e28f466ba6709fcba69f8` 完成 15 个 CPU 测试方法（原 10＋新增 5，后者含 8 个真实 CLI 场景）、Lead 12 场景、报告保护及普通 D.app 只读交叉检查。之后仅有结案文档变化，最终版本／证据见任务记录；源个人 scheme 排序修改保持未暂存。

诊断入口：`python3 -B scripts/diagnose-app.py --app PATH`，必须显式指定产物，可用 `--report PATH` 新建报告；只检查并报告，不修签名／权限。对应局部回归：`python3 -B -m unittest discover -s scripts/tests -p test_diagnose_app.py -v`。该任务当时的真实产物为 ad-hoc，本任务不证明公证、TCC、GUI 或跨构建恢复通过。

D-C01a 整阶段尚未完成。2026-09-07 用户回到 Mac 并授权处理环境／应用权限后，已完成外盘项目绑定、现有开发私钥调用、Apple Development 签名正常构建及原路径首次重开恢复。后续 `build-local.sh` 读取外盘本机签名配置；直接 Xcode GUI Build 仍保留原设置，不能混用后假定签名稳定。完整 8 项 UI XCTest、真实签名版生成／导出、再次签名重建恢复尚待验证。详见 [最新授权检查点、构建意外与恢复记录](MAC_PERMISSION_SETUP.zh-CN.md)。没有启动 D-P01、双 Worker 或推送。

D-C01a-RESULT-01 候选仍在独立工作树、HEAD `829ca10e2f396c8309723d55a69149cb132017d6`；因既有权限事件停止，第一轮修复尚未由 Lead 复验／集成。本轮授权设置不改写该试点结论。B10 偶发测试保留观察；物理拔盘／断电、完整 VoiceOver 等仍属于发行前独立验收。

## 2026-09-08：v7 RESULT 恢复与产品批次授权

D-C01a-RESULT-01 已保留历史合并、由 Lead 有界修补、非实现者只读审核，并从源目录通过 15 方法与 39 场景复验；受测代码 653c09cd2e526c7e8cc0f09b925232f85826ee46。[记录](tasks/D-C01a-RESULT-01.md)。此前“第一轮修复尚未复验”的段落为历史停点，已由本段替代。不是 D-C01a 整阶段或真实 UI 8/8 完成，未推送。

用户 v7 已批准有限 T0 产品批次及一个独立 META 配方切片，并批准有门槛的双 Worker 流程切换。Lead 准备分支 codex/d-t0-meta-01；规格／并发／验收尚未完成，不提前标记常规多代理已启用。源用户 scheme 排序修改继续保护。当前源签名行为不因本批变化。

## v7 首组产品批次：已本地接纳，常规多代理已启用

源接收快照 c808293692eb7be90b7c9de73667c9d7bc327e3a → 已受测组合 `c3197ad9cdade3d486a4153418cacc39af85bc81`。批次 [D-T0-META-01](tasks/D-T0-META-01.md) 完成：两个独立受限 Terra/medium 实现重叠229.3338秒；各自两轮修复，META另经Lead测试夹具收尾，生产代码非实现者审查及组合验收通过。工作台117/核心17在组合通过，源目录工作台117再通过。此后仅结案文档，最终源HEAD见外部final-receipt并以Git核对。未推送，候选和证据保留。

**常规多子代理开发流程已启用**：以后用户批准产品目标/继续获准批次，由Lead按任务就绪度使用0—2 Worker，受限独立CLI与串行重验证；不需额外会话逐步骤传话。本批所有子任务/自有检查进程结束，未建立系统写锁。当前停止在批次结案，不自动展开下一目标。个人scheme唯一未暂存差异保持，索引干净。签名/权限/精度/数据保护规则不变。

已明确多模态出口：[音乐/HUM](MUSIC_ROADMAP.zh-CN.md)、[资产来源](ASSET_PROVENANCE_PLAN.zh-CN.md)。图像有限出口已有历史证据，签名版完整 UI/重建恢复缺口保留，不阻塞独立组件。当前 T0 范围仅编辑/运行桥接/草稿 Data 归档，META 仅内部配方 Data/隐私，不默认启用新 UI；完整工作台保存、真实文字生成、PNG往返及音乐仍未验收。

下一用户可感知出口是 T0 工作台界面和生产保存接线，在允许的独立环境完成实际选段改写、保存重开。下一音乐包以 HUM/MUS0 原声/自由时间/音符数据与普通试听出口进入，不等所有图像/文字增强或 META 全部完成；下载/音源/模型精度需另行明确。

## T0 工作台候选：代码/编译通过，真实闭环待验收

本轮用户已批准有限工作台接线，取代上面“下一目标待批准”的历史停点。候选 codex/d-t0-workbench-01 在外盘同名工作树；源仍保持6735266…及唯一未暂存scheme修改。完整SHA、来源、失败/修复、保护和恢复索引见 [任务记录](tasks/D-T0-WORKBENCH-01.md)，不要把短SHA补造为新基线。

已实现同项目文稿、选区失效、候选处理、单级撤销、序列化自动/显式保存和重开；schema3备份迁移未用于真实作品。现有Qwen模型全部文件摘要已由生产代码只读校验，但没有新的MLX生成。142方法是本轮组合一次运行，不加总早期139/141或各子包方法；核心17和unsigned编译分别记录。真实GUI/CUA访问超时、用户D/GPU空闲状态未确认，因此整个候选留在隔离分支，原入口不变。

本批两个Terra/medium局部Worker均初交+2修复，Lead负责共享接线和反例，另有非实现者只读审核；各自自有进程已结束。下一动作仅恢复本目标的真实验收：确认设备空闲，界面控制可用，使用明确测试产物绝对路径和独立项目，完成现有模型真实改写/候选交互/保存重开，再按原规则本地接纳。Xcode已登记隔离编译产物到LaunchServices，不能只按名字D猜测产物；未启动它或替换普通D。签名/权限方案不改，不为此下载。

音乐/HUM的原声/自由时间/音符数据和普通试听仍有明确后续出口，不等待完整高级文本或META。PNG内嵌、音乐模型、手机等没有在本轮开工。

## v8 里程碑检查点（2026-09-08；覆盖上面的下一步待批描述）

本轮授权为T0真实收尾＋一个后续有限闭环。**产品代码未接纳，普通D未替换，无推送**。本段所在源提交仅更新当前动作/协作规程；最后已接纳产品代码仍6735266933773adaee33b3a66a01b09c0b1f7d9b。以下候选不能当作已交付：

- T0：候选目录 /Volumes/CodexProjects/Codex/D-Worktrees/D-T0-WORKBENCH-01；任务记录 docs/tasks/D-T0-WORKBENCH-01.md。代码与既有62fc7b5dd568e5f53354382dd189d09e96b7e0bc一致，新增签名构建来自8c40e968c61f4ee661efdb6c92ffe77cd7b91cff，之后仅任务记录6bf7eef9be37036e06b96dd3dbcb364ceee8a712。现有配置正常签名、完整性和entitlements已核对；GUI仅库存查询响应，未绑定/启动实例。当前空闲/GPU/GUI窗口请求未获答复，真实改写/IME/取消释放/签名保存及合成v1/v2迁移仍待。证据 D-Development/AgentTrials/D-T0-WORKBENCH-01/run-v8-20260908/validation-entry.json。
- 后续选择META-PNG：目录 /Volumes/CodexProjects/Codex/D-Worktrees/D-META-PNG-01；任务记录 docs/tasks/D-META-PNG-01.md。受测ea1c19abf89ca8fdc6339df904aba0c0c7c59a98，137 CPU方法通过，完整禁止签名编译通过；新副本/离线读取/新草稿为合成文件与会话实测，不是GUI。非实现者复审仍要求4个精确尺寸边界夹具；Lead自查预览校验在界面线程，尚需移出。Terra初交+2修复、Lead一次有界夹具接管已用；未自动追加轮次，保留候选和真实产品门槛。曾出现旧项目移位锁测试1次异常，定向及最终组合通过但根因unknown，不声称修复。最终候选SHA/模型/进程/证据由 D-Development/AgentTrials/D-META-PNG-01/run-v8-20260908/final-receipt.json 索引。
- HUM-ENTRY的具体依赖：现有ProjectStore仅接纳image/png及固定图片结果路径；原声素材需独立持久化增量，不能悄悄扩大schema。音乐/HUM下一出口仍是原声导入、保存和普通试听，然后明确的真实哼唱转录验证，不等全部T0增强或META平台。没有启动模型/声库下载、手机或完整音乐编辑器。

最小剩余动作：协调本轮实际GUI/GPU窗口；META另需上述限定收尾的追加预算后再复验，不重新全库审计或重新试验协作机制。当前所有本轮自有子进程已结束；用户D/GPU空闲未知，不关闭用户D腾资源。scheme当前内容/摘要/索引/未暂存状态保持；恢复时重新核对真实仓库，不只相信本段历史状态。

## 人工协作集中处理：2026-09-08

今后用户回到 Mac 时，先读取 [人工协作待办](FAILURE_AND_PERMISSION_AUDIT.zh-CN.md#人工协作待办持续维护入口)，按最新任务回执核对并集中处理。Lead 持续记录等待用户的具体事件；权限、测试窗口、预算和普通工程缺陷分开，授权后实际复验才关闭，不后台自动触发。

本轮源起点 `188662d79f5283db97e5a928deae4f346b219a3a`；本次只接纳文档清单，不接纳 T0/META 产品代码。用户已确认当前约 30 分钟 GUI/GPU 空闲窗口，T0 固定签名候选按完整产物路径成功控制，并用独立 `D_UI_TEST_SESSION` 在本轮外盘目录通过原生面板创建项目和新文稿，未恢复真实项目、未出现新的系统授权提示。中文输入法已交给本人操作，等待回报；模型访问、真实改写、保存重开及迁移不因这一小步记为通过。

保留的待办：H03 真人 IME；H02 后续模型／保存等实际验证；H04 同次完整 UI 与稳定签名跨构建连续验收；H05 PNG 两项有界收尾需额外预算批准。旧 GitHub／外盘 runner／RESULT 缓存事故已有后续处理，不能再次当作待设置权限。源个人 scheme 保持原内容和未暂存状态；没有改真实作品、签名、系统权限、模型或推送。当前进程、检查结果、最终文档 SHA 与恢复点以外部 `D-Development/PermissionSetup/run-20260908T122903Z-return/receipt.json` 为准，恢复先核对，不能仅相信此历史段落。

## 2026-09-08 人工集中收尾检查点

候选实际受测代码 `a6c516ad6b52c944ce70a0bd764d68a94fd0f3bc`，组合目录 `/Volumes/CodexProjects/Codex/D-Worktrees/D-HUMAN-FINISH-01`、分支 `codex/d-human-finish-01`。源当前只更新待办文档，产品代码尚未接纳；不存在仍运行的本轮测试应用、构建或审核进程。本次源提交仅CURRENT_ACTIONS与FAILURE_AND_PERMISSION_AUDIT文档变化，最终SHA见外部 `human-checkpoint-receipt.json`。用户一小时窗口已结束，追加15分钟协调尚无回复，不能视作已同意。

- 165方法/22套件组合CPU通过（显式启用既有文字权重只读检查）；8项UI在同一个 `uitests-refined.xcresult` 中全部通过。此前第一次8项有2项原生GoTo面板失败保留，测试只增强完整路径和面板消失的同步断言，未降低原验收。
- Lead修复文字窗口宽度反馈/分栏约束：窄窗口上下布局、工具栏换行，AnyLayout保留原生编辑器身份，原选段有44pt最小高度。窄/宽实际往返、真实候选与失效警告可达；用户在最终构建上明确回复“输入与缩放均正常”。离屏回归的窄布局断言经历旧实现先失败后通过；早期仅bounds的探针曾通过，不能冒充完整复现。
- 正常签名Qwen真实改写证明原文接受前不变，接受只替换选段、撤销恢复、取消后下一任务可运行，校验中变选区明确拒绝、完成后变选区禁用接受且可拒绝。旧构建保存的测试正文与模型选择在新构建恢复；中文输入法人工结果单列。最终a6实测再次真实生成“阳光明媚。”并接受/撤销/保存。模型文风和标点不宣称专业质量。
- 正常面板打开合成v1/v2，均迁移schema3且原清单备份逐字节一致、图片未变；v1另已GUI重开。真实作品未迁移。PNG私有/公开新副本由正常面板保存，在另一项目离线读回；公开提示词withheld导致新草稿不可用，私有明确接受生成独立草稿801488BE-1237-41E1-A15C-B8343E8DBAEC并落盘，原文档不变、没有自动生成。独立CRC/JSON检查确认全部非配方PNG块字节保持、Unicode和最大UInt64 seed准确。
- 正常开发签名FLUX.2 Klein4B q8，512²/4步/guidance1/seed42真实完成；作业6A86F463-F611-4C45-9B39-493C38C56191，原生导出436021字节且与项目图片SHA256一致，sips解码512²，CUA看图为蓝色陶杯。estimatedPeakBytes为预算估计，不冒充本轮峰值实测或数值基准。
- 真实编译已在新的DerivedData-fresh完成；二进制和签名资源摘要与前产物不同，Info.plist相同。**尚待这个全新产物重开图像/模型授权、配方草稿及v2/T0最终恢复检查；不提前记整个里程碑或D-C01a完成。**

证据根 `/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-T0-WORKBENCH-01/run-20260908T125225Z-human-finish`：verified-checks-before-human-ime、human-ime-final、gui-progress-1/2、migration-after-native-open、migration-and-recipe-before-rebuild、png-native-crosscheck、image-normal-signed-result、normal-fresh-rebuild、checkpoint-await-final-window（JSON）；review/gui-delta-response.md。GUI截图/操作另在本会话，JSON明确区分用户报告、CUA与文件检查。

来源：Terra既有初步实现/历史返工原样保留；本轮Astra Lead亲自修复，Sol/high非实现者仅只读审核差异，非独立测试执行。观察上下文四次均Sol/high/read-only，隐藏服务端解析unknown；各阶段耗时/usage原始快照保留，未将累计/缓存快照盲目相加，完整Lead与订阅费用unknown。没有新Terra第三轮、签名方案变更、安装、推送或权限扩大。CUA一次粘贴超时后核对正文/磁盘，改用原生输入；界面AX旧状态与截图不一致后以实际启动作业核实，不推断应用拒绝生成。

恢复：先核对真实源/组合HEAD、scheme内容/摘要/index/未暂存状态和自有进程；源本轮文档新增属于已批准清单维护，之后可在隔离组合分支保留历史合入该明确源快照，核对仅文档差异，再按既定验收门槛接纳。下一动作只是上述新产物恢复，不能再重复真人IME、模型下载或整套协作试验。音乐/HUM原声导入保存与普通试听仍是明确后续出口，不等全部文字增强，本轮不启动。
