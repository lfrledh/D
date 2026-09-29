# D-VIDEO-MODELS-01：H3 / LTX 本地视频扩展

2026-09-30 · 当前补充r3（开发权重授权澄清） · 实施中，尚未接纳/新增可运行节点。r1/r2执行与失败历史保留。

## 授权与基线
用户批准适配 MiniMax H3 与 LTX 系列的真实推理栈和模型节点，要求全尺寸、非量化配置；小内存测试可另选量化配置，真实权重流式开关必须进入请求与来源记录。不能用开发机内存限定产品支持上限。未批准替换模型、静默缩层/量化、云端补足、公开发布。

源 `codex/inference-foundation@01758b81527dc27eb4563bf1b66fd1ceab6647ee`；前端候选 `codex/ui-baseline-02@4b90327db126e46a9277a0a401d2b6ea3e283399`，后者是本批起点。专属树 `/Volumes/CodexProjects/Codex/D-Worktrees/D-VIDEO-MODELS-01`，分支 `codex/video-models-01`。前端候选原封保留，不把其旧 GUI 失败升级为通过，不源接纳。

R=`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-VIDEO-MODELS-01/run-20260929T173017Z`。保护源 scheme 的未暂存差异、摘要和索引，记录 R/lead/protection-before.json；不改普通 App、旧模型/作品/候选。管理工作树工具因当前会话绑定内盘空仓库而不能解析指定 SHA，返回 invalid reference；未在空仓库实施，改在已核验共同 Git 目录创建隔离树。已知旧自有测试 App PID37434 仍保留，不处置用户现场。

## r1已核事实与当时待决（权重审批停点已由r3替代）
H3 官方 revision `42ed227ee7df40d41602854ae760620d6eb651fe` 的公开 Base 是 **CFG-distilled BF16**，没有公开非蒸馏版证据；不得标“非蒸馏”。Context-IR/Regenerate-2K 未公开不冒充本地能力。首个固定适配目标为公开 FL2VA 原始 BF16、全部50层、不近似复用、不量化计算的配置。Ref2VA 的不同权重/条件保留明确后续映射，不冒用 FL2VA。

LTX 当前官方版本 2.5，2.3仍有独立权重/文字编码器。首个完整配置是22B dev 单阶段，不加 distilled LoRA，不把 BF16 DiT + q4 encoder 标成全链非量化。2.5权重门控涉及本人分享联系信息；已集中询问，不代填/读取凭据/绕门控。H3许可地域与使用资格亦由本人确认后使用权重。代码适配不受此等待阻塞。

复用候选：MIT `antirez/h3.c@8974cc055ea9c02fcd14cc27dfda3e1027c05153`；MIT `dgrauet/ltx-2-mlx@1724ca673d59f023a8a95efee06e5d36d61c2765`。权重各自许可与代码MIT分开；原始源码压缩包/摘要存 R/upstream。上游 README/他机数字仅是线索，不是 D 实测。

## 最小接入契约与所有权
继续使用 DInference 值、唯一 DRuntime、既有重计算许可与安装使用权。H3/LTX 不得冒充 Wan profile；旧 Wan 请求和无声音轨验证不放松。新的音视频结果需要显式保存/重开/导出验证，不能静默丢音轨。流式只换权重加载策略，开/关均不改变模型、层数、精度、提示、seed和输出尺寸；高内存模式不硬绑16GiB。

首先冻结离线执行配方的真实参数映射，在 Backends/Video/Adapters 下分别放 H3/LTX，不建新包或通用插件平台。配方规划接口 `build_plan(request, *, engine, model, output, text_encoder=None)`：纯值检查＋只读本地路径检查，返回 `argv`、`environment`、`provenance`；不执行、不下载、不写输出。request v1 字段 `schema_version, profile, prompt, negative_prompt, width, height, frames, fps, steps, seed, stream_weights`；LTX额外 `cfg_scale, stg_scale`。拒绝未知字段、bool冒充数字、非有限值、无效联合条件、不支持profile；不调整输入。输出路径不能已存在；模型/引擎必须显式本地，不接受仓库ID触发隐式下载。此规划接口不是运行后端，也不证明安装完整/权重精度，最终执行准入必须另校验完整资源。

H3 profile `minimax-h3-fl2va-bf16-full-v1`：32倍尺寸/像素<=768*1344，帧22…362且17n+5，24fps，2…1000步，UInt64 seed。负提示非空拒绝。必须显式50层、reuse/core-reuse=1、reference RoPE、三个BF16 projection flags、F32 final head；无token reduction/int8/render缩小/show。stream_weights仅映射--ssd-streaming。其上游5帧能力暂不纳入这个音视频配方；不能标硬件不支持。

LTX profile `ltx-2.3-dev-bf16-full-v1` / `ltx-2.5-dev-bf16-full-v1`：32倍尺寸、8n+1帧、显式正帧率、步数、UInt32 seed、有限cfg/stg。固定 `generate --one-stage --dev-transformer transformer-dev.safetensors`；不走默认distilled/两阶段/增强prompt/隐式随机seed。2.3必须显式本地非量化Gemma路径，2.5本地专用Gemma4随pack，不能替换为普通Gemma4；stream_weights仅映射--low-ram，文本塔不因此宣称流式。最终资源预检须阻止q4/q8伪装full。

## 分工、检查和停止
Lead协调资源预检、Swift契约/选择与Store/App接线、文件保护、组合验收。两个受限Worker分别仅新增 `Backends/Video/Adapters/h3_plan.py`、`Backends/Video/Tests/test_h3_plan.py` 与 `ltx_plan.py`/对应测试；各自独立树/分支/输出/cache/tmp；不改本规格和公共代码，不运行模型/构建/GUI/网络。配置 gpt-6-sol/high（外部API/原生精度边界比普通脚本复杂），初交+2定向修复；重要Lead实现由非实现者审阅。任务真正运行身份、执行基线见R各job/route记录，不能由本段推定预检通过。

冻结CPU用例：精确非量化/全层参数；stream开/关只改变加载；中文/空格/包含shell字符路径不执行shell；missing/unsupported拒绝；bool/浮点seed/NaN/超界/未知字段拒绝；无隐式下载与覆盖。直接交叉检查固定源码的CLI参数/streaming分支，不仅重复常量；配方测试不等于真实推理。语法用tokenize.open+内存compile。执行进程的取消/drain、资源身份、音视频检查、无模型节点不误报就绪、请求冻结、存储恢复及旧Wan回归均是最终接纳要求，缺项不得关闭本任务。

重构建/GPU串行。真实测试资源因许可/门控不可取得时保留精确缺口；不给未验证后端默认可运行状态，不用目录卡片充数。大日志/权重/样本在外盘证据或模型目录，不入Git。阶段结束分别报告实现、编译、CPU、模型、GUI与未完成项。

## r2：执行与值型接线准备

Lead澄清LTX完整2.5配方必须显式 diffusion decoder，2.3为conv；不默认使用更轻解码器。LTX Worker初交后的修复1同时关闭NUL参数缺陷，并落实这项新澄清；不倒记为原规格违约。H3初交、LTX修复1由Lead复读并在隔离组合分支保留历史合并。Lead将LTX测试临时根改为调用方TMPDIR，去除本机run硬编码。非实现者审阅见R/lead/review，纯配方仍不等于后端。

新增两个互不重叠的有限切片：值型视频执行选项（DInference与根包测试）；本地视频引擎子进程监督（Python适配目录与对应CPU测试）。各独立受限树/基线/输出，gpt-6-sol/high，初交加最多2次修复，不能修改公共规格。前者仅给现有VideoRequest增加可选、有类型的H3/LTX选项，旧Wan缺省解码不变；后者服务本次上游进程及其FFmpeg回收，不新建运行时或模型调度器。确切允许路径、接口与反例在各任务输出规格中冻结。Lead负责最终实际调用、资源与产物发布。

## 真实模型入口与 Lead 有界收尾（2026-09-30）

两项资格/门控问题 H30/H31 尚未得到本人回复；不下载 H3/LTX2.5 权重。LTX2.3 Q8 + Gemma3 Q4 测试资源共 36,826,797,038 字节，固定清单逐文件摘要已核；非蒸馏 dev，但不是全精度。BF16 模型与文字塔单独清单约72.58GB，未以小机实测冒充。实际独立环境/下载证据在R/lead与tests，不提交权重。

Swift 值型组合在 `c863e2b67fca18d1048e29bd0ea725961f250a14` 根包79项/14 suites通过；受限Worker无法启动SwiftPM嵌套沙箱后按规则停报，Lead在原有权限检查。PROCESS经历初交+两轮修复，15 CPU项曾通过；初交权限拒绝后未立刻停报、Lead较晚发现的事实保留（R/lead/process-worker-event.json）。不得把后续修补归为Sol独立通过。

固定 `9dcf4978034a09402411b8709dbdd9b5be8bb603` 的第一次真实Q8流式调用：上游GPU完成256×256、9帧、24fps、2步、seed42音视频，日志106.1秒；VAE阶段报告Metal峰值3.47GB，不等于全流程RSS。随后ffprobe退出竞争导致包装器失败，初始两个probe日志不完整，不能验收通过。原MP4保留。`__metadata__: null` 曾被自写资源检查器误拒绝，已对照safetensors参考读取器纠正，原件没有被修改。

PROCESS剩余普通修复为0；Lead执行一次有界接管：本机自有子进程证明Darwin在僵尸尚未回收时signal0可报EPERM，wait后为ESRCH。新增真实进程竞态回归先失败（tests/process-lead-before-02.log）再通过；仅对已拥有Popen有界wait0.1秒后复查同PGID，持续拒绝仍失败，绝不把EPERM直接当不存在。18项CPU检查通过。非实现者video_extension_map复核代码/日志，未另跑测试；没有改权限、换用户或忽略拒绝。依据Apple XNU killpg1对SZOMB过滤：https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_sig.c 。

Lead另修私有产物检查：明确`-xerror`全量音视频解码、哈希后再检查取消、请求读取1MiB上限；资源每4MiB分块可取消。新入口固定tempfile.tempdir为任务tmp，避免磁盘错误回落系统临时路径；调用同一上游CLI函数与参数，没有改变模型数值。新5项CPU媒体检查包含真实FFmpeg合成/损坏副本、取消、拒绝和临时目录失败；不算真实模型样本。h3_primary_research只读审查取消和媒体验证；video_extension_map复核进程/临时目录。

`real-ltx23-q8/strict-recheck-01/result.json`：只读复验原始MP4的完整JSON与解码均通过，视频9帧/24fps/0.375秒，AAC48kHz立体声约0.33秒，在明确AV容差内。原件SHA256 `56ee9103049794d536a53e3e43f5c19bfba35189bdb3b6b69c82ed050d70004c` 不变。这是修补后复验原样本，不倒改第一次完整调用失败历史。2步极短样本不是画质、音画语义、官方数值对照或BF16验收。

仍待：修补后的整个真实入口与取消复验、完整App运行时/安装使用权/音视频Store接线、新节点和流式开关、普通Xcode可复建依赖打包。旧Wan仅值型拒绝外来选项的针对性回归；没有声称新后端已注册或前端节点可生成。当前代码不改项目schema、原App或已有模型请求。精确最终提交与后续结果写外部回执，不能用本文把尚未执行事项记为通过。


## 代码验证检查点（未结案；后续授权规则见r3）

受测完整适配代码 `b207c0f34d86be408ba1e586db8842b36c6fcd58`。之后仅更新本任务与CURRENT_ACTIONS；最终文档SHA写R/lead/final-handoff.json，不自引用提交。

- **通过**：R/real-ltx23-q8/attempt-02 完整入口，GPU引擎93.968秒（不含资源预检），生成256²/9帧/24fps/2步/seed42 H.264＋AAC。probe完整JSON、逐帧计数、严格完整解码、AV时间线、摘要通过；没有发布到用户项目。
- **通过**：attempt-03-cancel 在真实Gemma编码阶段发SIGTERM给自有包装器；约0.247秒后包装器结束，退出2、engine_process=cancelled、原引擎进程组46158已不存在；未把取消当成功或发布输出。GPU正在计算时能结束，不宣称任意硬件瞬间停止。
- **通过**：attempt-04-after-cancel 重新加载并生成，GPU引擎90.043秒，完整媒体检查通过。两次成功样本摘要相同仅是这个固定输入/环境的观察，不承诺普遍逐像素确定性。VAE阶段Metal峰值3.58GB，仅是阶段指标；全流程RSS和跨机精度仍未知。未运行关闭流式的20GB Q8 DiT驻留测试，未运行全BF16模型，不能由开发机实测推断产品容量上限。
- **CPU/结构**：H3配方6、LTX配方10、资源9、准入5、进程18、媒体5、实际tokenizer方法3，共56项，R/lead-cpu-final及tests/ltx-job-final-five.log。媒体中含合成的真实FFmpeg文件/损坏副本；模型样本另列。根包79项/14 suites受测c863e2b至本次b207的Sources/Tests差异为空（R/lead/tested-code.json）；未宣称重新跑过App。
- **审核**：两个非实现者只读复核，范围、限制在R/lead/review-final.json。重要进程修补归Lead，PROCESS的两轮用尽及历史未停报保持。共享重计算许可、模型安装租约、GUI、Xcode普通可复建运行时、带音轨Store迁移/重开、正式节点streamWeights开关都仍未验收。

### 版本/精度与剩余边界

|资源/实现|已核对的身份|当前实际程度|
|---|---|---|
|MiniMax H3官方Base|官方42ed227ee7df40d41602854ae760620d6eb651fe；BF16、CFG蒸馏；所选首条FL2VA配方，不把Ref2VA/未发布能力写成已实现|h3.c固定8974cc055ea9c02fcd14cc27dfda3e1027c05153，MIT源码编译及1768无权重检查；全50层/禁隐式int8/真SSD streaming配方已核。等待H30，不含真实H3生成或App节点|
|LTX2.3 dev BF16|非蒸馏dev，DiT和Gemma3文字塔均固定无量化资源，禁止隐含蒸馏LoRA|有独立完整资源清单及同一one-stage入口，但72.58GB资源未实测；不能称“满血版已通过”|
|LTX2.3 Q8测试|dgrauet/ltx-2.3-mlx-q8@6671a7572a530862d1d60ce393b5d93491e3f76b；Gemma3 Q4@86cc6a8dedbc456dd0e4af01a9d09f396f77e558|36.83GB已下载摘要核验；本机流式GPU、取消和恢复局部通过；不是BF16或画质验收|
|LTX2.5 dev|官方5e6e71018ee1756ed329b697a7b4aedc934dfce9；dev与distilled必须分开；自定义Gemma4-LTX，不能以Gemma3代替|纯值/CLI参数映射，显式diffusion decoder；H31门控未完成，未下载、未真实执行；2.3成功不证明2.5成功|

流式开关是每任务冻结值，不改变模型版本/量化/蒸馏。H3是DiT块预取；LTX是48个transformer block的逐块权重加载，文字塔/解码阶段不由此开关流式。前端尚无该开关，不能把Python参数等同已交付节点。

当前AV接线债已有定位：`VideoMediaInspector.inspect`、`VideoAssetMetadata.validate`和ProjectStore视频恢复分支仍保留Wan无声/固定时间线约束；新输出实际有AAC轨及B帧。下一步应增加明确的AV验证/来源/保存分支，保留旧Wan严格规则；不能丢音轨、放松全局检查或另造Store。`WorkflowModelBinding`目前只有imageRecipe，通用generateVideo和ProjectSession模型选择仍绑定Wan；需要按选定模型的冻结视频配方接入，不能把显示字符串当执行规则。H3/LTX只读说明卡片也未作为本轮节点交付。

### 恢复

源仍01758b81527dc27eb4563bf1b66fd1ceab6647ee、旧前端候选仍4b90327db126e46a9277a0a401d2b6ea3e283399。源scheme完整diff、SHA256、index及未暂存状态逐项与起点相同（R/lead/protection-after-model-tests.json）。专属候选留在codex/video-models-01；不源接纳、不推送、不改普通D，不删除任何候选/证据。已知旧GUI测试实例仍保持，不把本轮无GPU进程解释为全系统所有进程已退出。

下次先核候选/源/进程，再续本任务的真实运行时和节点接线；按r3授权获取开发测试资源，不再等待H30资格回复，H31只影响其实际门控资源。不是重置修复预算、重新规划产品或自动接纳其他候选。当前只能交付后端候选进展，整项用户需求尚未完成。

## r3：开发权重授权澄清（2026-09-30）

用户明确：D提供适配且正式App不附权重；模型由用户选择下载/使用。开发适配和推理测试所需权重也已长期授权，今后不再逐模型询问下载或商用资格，不设置额外资格审批停点。本次修正规则从记录后适用，不把此前未下载/未实测改写为完成，不将开发授权推导为公开分发许可。

- H30从本人审批待办中关闭；适配、节点、运行时/Store接线均继续。H31只保留实际平台要求本人登录、访问申请或提交个人信息的条件，不再作为本任务实现的前置审批。既有可访问资源按授权下载并固定来源/版本/摘要；不绕过平台访问控制。
- 正式产品不随App携带权重；代码/依赖的来源、许可与补丁记录继续。模型下载、开发验证、产品分发三者分别记录，不新增法务框架或资格对话框。
- 本次只更新AGENTS、产品原则、当前行动、集中待办及本任务记录。代码/测试/资源清单与受测b207版本不变；没有新模型运行、App构建或GUI验收，不重算历史用量，不恢复已消耗修复预算。
- 进入本次澄清的候选为`696a825ab95a6eff5eed495d356f9c01e67061c1`。最终文档提交及保护核对另存R/lead/download-authorization-clarification.json；上一final-handoff.json仍是其时点的代码验收索引，不覆盖。
