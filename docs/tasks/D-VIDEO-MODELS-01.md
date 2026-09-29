# D-VIDEO-MODELS-01：H3 / LTX 本地视频扩展

2026-09-30 · r1 · 实施中，尚未接纳/新增可运行节点。

## 授权与基线
用户批准适配 MiniMax H3 与 LTX 系列的真实推理栈和模型节点，要求全尺寸、非量化配置；小内存测试可另选量化配置，真实权重流式开关必须进入请求与来源记录。不能用开发机内存限定产品支持上限。未批准替换模型、静默缩层/量化、云端补足、公开发布。

源 `codex/inference-foundation@01758b81527dc27eb4563bf1b66fd1ceab6647ee`；前端候选 `codex/ui-baseline-02@4b90327db126e46a9277a0a401d2b6ea3e283399`，后者是本批起点。专属树 `/Volumes/CodexProjects/Codex/D-Worktrees/D-VIDEO-MODELS-01`，分支 `codex/video-models-01`。前端候选原封保留，不把其旧 GUI 失败升级为通过，不源接纳。

R=`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-VIDEO-MODELS-01/run-20260929T173017Z`。保护源 scheme 的未暂存差异、摘要和索引，记录 R/lead/protection-before.json；不改普通 App、旧模型/作品/候选。管理工作树工具因当前会话绑定内盘空仓库而不能解析指定 SHA，返回 invalid reference；未在空仓库实施，改在已核验共同 Git 目录创建隔离树。已知旧自有测试 App PID37434 仍保留，不处置用户现场。

## 已核事实与待决
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
