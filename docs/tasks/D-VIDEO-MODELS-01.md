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

## r4：继续视频接线与画布导航（2026-09-30）

用户批准继续本任务，并新增画布鼠标交互。实际起点`6262c527dd511332f42d080d738b27ffb65e6a58`；源与旧UI候选/个人scheme不变。新证据R4=`D-Development/AgentTrials/D-VIDEO-MODELS-01/run-20260930T000439Z-app-canvas`。已有PROCESS预算仍用尽，不借新切片重置。新画布与媒体检查各自初交+最多2轮定向修复；Lead负责共享Store/模型绑定/运行时/部署。管理worktree工具再次因本会话错误内盘仓库绑定拒绝固定ref，未操作空仓库；使用已核共同Git目录的外盘隔离树。

画布冻结行为：中央画布滚轮以鼠标点为锚缩放，沿用现有缩放范围；空白左拖平移视口，初始四方向均可移动；中键居中且保留缩放；右下“恢复默认视图”恢复100%并居中。中心为当前画布内容几何中心，空图用默认中心；不移动真实节点。节点卡片非交互区继续原节点拖动/Undo，端口、输入框、按钮与编辑器保留各自手势；侧栏滚动不能缩放画布。视口/鼠标状态按现有project/root/body隔离，不改模型请求/参数/来源/项目schema。真实鼠标与组件结果分别验，锁屏只挂相应原生事项。

视频继续复用既有运行时、使用权、Store：新增配方按冻结模型身份选择，stream开关记录实际加载策略，不改变精度/层数；旧Wan无声约束保持，H3/LTX带音轨结果须独立检查、完整保存重开。现有LTX2.3 Q8/Gemma Q4烟测配置增加明确Swift身份，不能冒充BF16。H3固定资源按开发授权获取，不能从盘占用直接断言统一内存不可运行。LTX2.5资源实际门控单独记录，不阻塞其他实现。

派工精确文件/接口/反例、运行目录/缓存/只读与实现预检均在R4各任务spec/job/route；写Worker继续受限离线CLI，各自独立工作树，Lead停写接回后才提交。非实现者审阅重要改动；重构建/GPU/GUI由Lead串行。编译、CPU/hosting、模型、原生操作分别记录，未运行不升级结论。

### r4 实施中间点（非验收）

Lead 正在接入 schema19 的可选音轨事实、冻结视频配方、模型选择和静态节点投影。此准备提交不是可交付App：媒体检查实现由AVMEDIA交回后整合；外部进程组transport/普通包部署仍在制作。新增TRANSPORT仅负责App的Swift进程组所有权，与已用尽预算的私有Python PROCESS实现不同，不修改或重置后者。新传输必须原子建立进程组，取消/超时后确认父进程回收、进程组消失与双管道排空；未知收尾不能释放重推理许可。临时/输出和受限路由在R4/TRANSPORT。H3RUN本次私有候选执行与资源准入已初交，尚待Lead复验及非实现者审核。

根包首次新配方测试发现预期列表漏加Q8，修正枚举期望并保留旧身份；新清单交叉检查第一次将本地清单键误当执行profile，已明确两种身份的映射，revision及精度边界检查未降低。测试失败原日志均保留R4/lead/root-tests。

### r4 2026-09-30 包部署与验证中间点

当前组合HEAD `2299e75a2a1d1857267d71f6022383e4e4111a0d`，另有Lead未提交的后端保护、媒体检查、打包脚本/测试及文档。不是干净受测SHA，也未源接纳。CANVAS初交+两轮修复、APPDRIVER初交+两轮修复完成；AVMEDIA初交+两轮后由Lead有界修正有理帧率/音轨偏移夹具与时间容差。来源和旧失败保留R4，不再给这些Worker追加普通轮次。

- `lead/external-video-cpu-03.log`：实际12项/2 suites通过，覆盖独立inode/hash/目的路径替换、bootstrap残留、输入变更优先、原子进程组取消/超时/子孙排空。并非真实模型。
- `lead/ui-tests/test-09-store-canvas-math.log`：AV/Store12项与画布数学5项通过；schema18备份与音轨保存/重开/导出使用隔离夹具。`test-08`虽进程0，hosting未出完成记录，标未完成。
- `lead/prepare-engine-08.log`：固定LTX源码124项及两项tokenizer补丁比对，H3源码/档案/Metal摘要比对；复制闭包中的Mach-O依赖均在包内或系统内。内部开发包不代表依赖分发审查完成。
- `lead/app-build-01.log` 与 `lead/app-signature-01.json`：普通D Nodes构建、深层签名核查通过。产物`R4/lead/app-build/Build/Products/Debug/D.app`，仅隔离产物，没有启动/覆盖普通D。
- `lead/real-ltx-01.log`：正式Runtime真实权重验证已启动，尚待结果；生成/准入取消/恢复三个周期不能提前写通过。
- `lead/gui-locked.json`：工具明确返回Mac锁定，H32暂存真实鼠标/新模型节点界面验收。无新系统权限请求，不自动关闭旧测试实例。

准备资源在`R4/delivery/resources-final`，本树忽略的`Development/Development.local.xcconfig`指向该目录并沿用已有开发身份；源码的准备脚本可重建资源，权重不在App。源个人scheme摘要/未暂存状态继续保护，普通用户App与旧候选未动。


本中间点后的实际部署失败与修正：`real-ltx-01`在导入PIL依赖时SIGKILL，未进模型计算。`python-import-01`和`python-import-verbose-01`定位，`dylib-signature-failures-01.json`确认重定位的原生库签名失效；外层App `codesign --deep`成功不证明Resources内这些库可加载。Lead在新准备目录复用现有`_sign_engine`、既有开发身份/Team签署新副本（没有改签名方案/普通App/来源目录）。`prepare-engine-09`后`python-import-02`真实PIL/MLX/LTX CLI导入通过；`app-build-02`为普通工程重新构建。模型验证尚待重新运行，旧失败不删除。

非实现者审阅另发现复制后来源绑定及`@executable_path`入口歧义，已在准备器目标副本做固定源码摘要/文件集合精确核对，依Python/native实际入口解析，共享库歧义拒绝；`packaging-tests-01`三个反例通过。`ui-tests/test-10-recipes.log`27项/3 suites通过（节点配方3、既有注册12、AV/Store12）；不是完整hosting。`mlx-build-04`编译通过，最新代码另补真实非零退出码到错误信息。

### r4 固定候选检查点：真实生成已运行，媒体接纳与原生验收分开

生产代码/普通构建受测`7beb5b6494396311934b5a11a6a696d21b38c543`；随后仅新增三份测试与文档，没有修改生产推理、Store或画布实现。最终候选SHA、各测试文件摘要、源/旧候选保护和进程状态写R4/lead/final-receipt.json；不把新增测试倒记成在7beb提交内运行。源尚未接纳，不推main。

| 检查 | 实际结果与范围 | R4证据 |
| --- | --- | --- |
| 固定H3权重 | 38个固定源文件、144023606861字节，逐文件校验；独立APFS克隆包，权重不进App/Git | lead/h3-download-result.json、h3-pack-path.json |
| H3普通包内引擎→正式Runtime | 1测试3周期：原始BF16全部50层、256²/22帧/24fps/2步/seed42/流式true；生成114.532秒，准入取消8.114秒，再生成112.429秒；结束activeRunID nil/reservedBytes0 | lead/real-h3-01.log、.xcresult、-context.json、-summary.json |
| LTX普通包内引擎→正式Runtime | 1测试3周期：2.3 dev Q8/Gemma Q4、256²/9帧/24fps/2步/CFG1/STG0/seed42/流式true；生成130.448秒，准入取消8.061秒，再生成124.476秒 | lead/real-ltx-02.log、.xcresult、-summary.json |
| 当前运行时CPU | 12项/2 suites通过：后端5、真实自有子进程7；固定模型计算以夹具替代 | lead/external-video-cpu-04-command.json、.log、.xcresult |
| 节点/库/应用CPU | test15：28 UI（画布几何/拖动/展示/四配方库映射）与6 Workbench（3配方、3服务）通过；登记重开使用真实ProjectSession/隔离suite，Engine只记录请求并受控失败 | lead/ui-tests/test-15-services-canvas-command.json、.log |
| AV/Store夹具与真实LTX | 12个合成AV/Store方法通过；另1个opt-in真实LTX文件解码/发布/重开/导出通过，原文件不变 | lead/ui-tests/test-11-real-ltx-store.log |
| 真实H3→Store | **失败**：真实输出被音轨/容器时间线检查拒绝；不以Runtime成功覆盖 | lead/ui-tests/test-12-real-h3-store.log、lead/review-media/ |
| 普通App与引擎 | app-build-02成功，外层包签名及真实Python/PIL/MLX/LTX导入通过；引擎随普通工程构建嵌入，无手工改App；复制交付包签名复核通过 | lead/app-build-02.log、python-import-03.json、delivery/preview-build.json |
| 实际GUI/hosting | 锁屏未跑新包；旧test08原生hosting未记录结束，不能用exit0当通过。新增画布手势及模型登记/运行/保存界面待H32 | lead/gui-locked.json、集中清单 |

两个2步样本独立保存于R4/delivery/samples；H3首帧可辨红杯、存在变形，LTX首帧抽象纹理。它们是链路/文件检查，不能代表成片质量、较大参数或全LTX BF16验收。LTX正常30步/CFG3独立候选对照见后续同run记录，不重算上述Runtime3周期。

**H3保存失败的根因与停止点**：AVFoundation直接读到视频终点`88000/96000`、音轨/mvhd终点`88800/96000`，但`AVAsset.duration`仍为前者；启用precise、providesPrecise=true也相同。VideoMediaInspector.swift的assetDuration==最长轨终点假设导致拒绝（8.333ms），不是Double舍入或显存不足。mvhd/tkhd/elst一致、软件完整解码22帧与29600个PCM样本成功，原MP4 SHA256 `de441ddda7bc8de4192ff88ddab04798269104a5eb28aac4ca435c82b5ff4e33`未变。来源：lead/review-media/audio-times[-precise].json、movie-atoms.json、full-decode-precise-02.json；首次探针把无效sample duration序列化为NaN失败，02仅改诊断值为null，不改媒体。

AVMEDIA已用初交+两轮修复+一次有界Lead接管，现保留剩余缺陷并停止相关实现；不借APPDRIVER、改任务编号或更改mux绕开额度。最小后续有限修补：移除错误的API时长等式假设，保持实际mvhd、完整轨道解码、既定同步容差和文件身份校验，补“合法AAC尾稍长、asset duration仍取视频”CPU反例，再重验真实H3及LTX。须明确追加有限授权后实施；本轮未放宽标准、未覆盖输出。

**新增测试修正**：test12同时发现登记重开比较的URL带/不带目录斜杠；test13输出确证仅表示差异。改为完整physical path、目录类型及device/inode，非文件名前缀匹配。非实现者又要求关闭结果和控制器身份反例，test15已断言requestClose成功、workflow/store/manifest清空、重开对象不同。失败日志保留；没有修改生产绑定掩盖问题。非实现者baseline02_services_readonly核代码/日志，未自行重跑。video_extension_map独立诊断媒体语义；两者都不称另一个模型完成整轮验收。

**部署与保护**：R4/delivery/engines-r4为经签名固定源副本，resources-signed含原四引擎及可选第五视频引擎；本工作树忽略的Development.local.xcconfig引用它，源配置未动。候选普通包为R4/delivery/D Video Preview.app，启动器仅使用独立D_UI_TEST_SESSION，已有D运行则拒绝启动，不关闭用户进程。尚未原生启动，见delivery/使用说明.md。源仍01758b81527dc27eb4563bf1b66fd1ceab6647ee，旧UI候选4b90327db126e46a9277a0a401d2b6ea3e283399，个人scheme内容/摘要及未暂存状态保持。测试项目、临时文件、所有原日志与候选保留。

**来源/消耗**：受限Worker实现与修复历史按前文及各job记录；Lead承担共享装配、保护/部署修补和以上验收。CANVAS/APPDRIVER普通修复已用2轮；AVMEDIA普通2轮+Lead接管用尽；TRANSPORT普通1轮；H3RUN普通1轮；未刷新旧PROCESS预算。非实现者只读审核与实际检查分开。可核实时长写各周期/工具日志；完整Lead归因、订阅扣费未知，不拿API价格换算。

**恢复**：先查W HEAD/差异、源个人文件、已拥有进程；R4/lead/final-receipt.json指向最新候选与未完成项。H3 Store阻塞与H32锁屏独立；LTX2.5 H31只阻塞该资源及实测。LTX2.3 full BF16尚未实测；H3公开Base是CFG蒸馏，不承诺不存在的非蒸馏权重。不要把本次候选同步或后端成功写成已在源App完整接纳。
