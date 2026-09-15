# D

开发中的原生 macOS 本地 AI 创作工作台，使用 SwiftUI、MLX Swift 和 Hugging Face 模型。

当前指导以[产品与架构原则](docs/PRODUCT_PRINCIPLES.zh-CN.md)为准：项目下按主要产物模态组织，跨模态复用数据、操作和原生UI组件，工作方式与布局分开；开发机16GiB不作为能力上限。旧视觉首批/固定小规格保留为阶段历史，不限制后续产品方向。[D-ALIGN-01](docs/tasks/D-ALIGN-01.md)已本地集成并完成有限阶段验收：统一能力来源并接通文字/图像配置，音频按实际部署声明与验证；接纳和推送见行动指南。完整可组合平台仍未实现。

2026-09-14统一开发基线已完成有限真实验收并接入源工作分支：单参考PNG改图与文字资料问答共用项目格式11。参考图支持显式导入、修改条件、生成候选、比较采用与安全导出；资料问答支持TXT/Markdown快照、选择片段、带来源记录的回答、接受/拒绝/撤销及安全保存，入口默认可见。引用标记核对位置，不证明回答内容一定正确。问题框缩放时的中文组字已修补并由用户确认。来自同一新构建的文字、参考图、SA3声音、MRT2器乐及Wan短视频均完成实际生成和相应采用/导出/冷重开检查；受测完整版本与推送回执见[当前行动](docs/CURRENT_ACTIONS.zh-CN.md)。普通D未被替换。麦克风已于9月15日完成真实录制/试听/导出/重开，详见下方音高识别增量。

项目升级先保留原清单的 `project.v<旧版本>.backup.json`，再写入当前版本12；媒体不改写。版本9的参考来源与版本10的资料/回答历史分别保留。旧版程序会拒绝版本12项目；需要保留旧版使用时，应先复制整个项目作为独立副本。不要手改版本号绕过检查。

原生 SwiftUI／Liquid Glass 工作台通过 DRuntime 与 DMLXBackend 运行图像任务，使用自包含 `.dproject` 保存作品和生成条件。已支持项目内多份独立创作、候选整理、两图比较和条件复用，见 [最新验收](docs/EXPLORATION_STAGE_ACCEPTANCE.zh-CN.md)。当前行动与验收状态集中在 [行动指南](docs/CURRENT_ACTIONS.zh-CN.md)。已完成的单项目检查点见 [工作台验收](docs/WORKBENCH_ACCEPTANCE.zh-CN.md)，后续目标统一维护在 [产品目标清单](docs/PRODUCT_GOALS.zh-CN.md)。文字现已接入同一项目的有限创作闭环：选段改写、候选接受/拒绝、受保护撤销、安全保存重开；旧文本和占位界面已退出。PNG支持实际任务配方公开/私有预览、新副本内嵌、离线读回并显式恢复为新草稿。两者已本地验收，范围及真实运行证据见 [T0任务](docs/tasks/D-T0-WORKBENCH-01.md) 和 [PNG任务](docs/tasks/D-META-PNG-01.md)；CLI继续保留。

单仓整合与真实文本推理基础的四项工作已完成，最终验收结果和边界见 [基础阶段验收](docs/FOUNDATION_STAGE_ACCEPTANCE.zh-CN.md)。

视频已接入基础工作台：项目→视频草稿/本地模型→生成/取消→预览、选择/采用/拒绝恢复→安全保存重开和MP4导出。带离线引擎的普通沙盒构建已真实验收，普通D未被替换。Wan2.1 T2V-1.3B输出无声H.264 MP4，项目保留实际参数、模型/精度和完整媒体检查记录；不自动采用、不覆盖已有副本。尺寸/帧数/参数/预算由显式请求决定，开发机不作为能力上限。当前没有I2V、音轨、时间线或自由组合。使用、部署、不同样本的资源和画质限制见[视频指南](Backends/Video/README.md)，受测版本及提交/推送见[本阶段记录](docs/tasks/D-VIDEO-WORKBENCH-01.md)。

图像 B2 已将分阶段加载、图像生成、进度、取消和产物引用接入现有核心，并完成当时图文验收。D-ALIGN-01已将文字额度和图像尺寸接入普通界面、请求及持久化。文字默认输入2048/输出256 token，宿主可选输入1…32768、输出1…8192，仍须通过模型context、真实token与资源校验。图像默认512×512，宽高分别可选256…2048且为32的倍数，沿用FLUX.2 Klein 4B q8/4步/guidance1；本轮真实512×768与保存重开通过。配置范围不等于全部组合或所有Mac已实测，见[D-ALIGN-01](docs/tasks/D-ALIGN-01.md)。

此前的 B1 是独立硬件实验：同进程三轮各约 35 秒，MLX 分配峰值约 5.78 GiB，释放后约 0.5 MiB 残留。该实验及其 [原始报告](docs/IMAGE_PROBE_RESULTS.zh-CN.md) 保留为历史对照，不能用它代替 B2 的运行时与资源验收。

## 短旋律器乐工作台（2026-09-13）

项目→音频现可在包含MRT2内嵌引擎的构建中输入短音符条件、风格与seed，生成48kHz器乐候选，试听比较、采用/拒绝、保存重开和安全导出。实际普通沙盒生成、取消恢复及旧SA3回归已验收。当前small短片段profile最多16秒、时间格40ms；它不是所有Mac或其他模型的上限。声音服从近似，试听含类似沙锤背景声，不承诺纯配器、分轨或精确谱面。普通D未替换，完整使用/离线部署步骤见[音频指南](docs/AUDIO_BACKEND_GUIDE.zh-CN.md)，版本和来源见[阶段记录](docs/tasks/D-MRT2-WORKBENCH-01.md#2026-09-13-阶段验收与本地接纳)。

当前普通内嵌引擎按实际部署分别呈现SA3 small music（最长120秒、44.1kHz双声道）和MRT2 small（最长16秒、48kHz双声道）。生成或参考原声超限在提交前明确拒绝，输入保持；本轮6秒/4秒真实回归、采用/拒绝及重开已完成。medium普通App部署、≥96GiB跨机及音乐控制质量仍另行验证。

## 音频后端与跨配置（2026-09-10）

统一音频后端现已接入源工作分支。SA3 small music真实完成6秒提示生成、参考变体、区间重绘和取消/超时恢复；输出44.1kHz双声道float32 WAV及实际执行记录，样本经用户试听正常。2026-09-12 APP1内嵌引擎版的普通沙盒音频界面已通过真实生成/参考变体/区间重绘、取消交接、试听采用拒绝及安全导出/退出重开；[任务与证据](docs/tasks/D-AUDIO-APP-01.md)。普通D.app未替换，麦克风旧待设备项现已关闭；plain build-local不自动封装引擎，见[离线部署步骤](docs/AUDIO_BACKEND_GUIDE.zh-CN.md#应用内引擎的重建与保护)。Qwen1.5B短改写与取消、FLUX768×512已实测；更大型号和高配Mac仍逐项待测，不改既有量化精度。调用与限制见[后端指南](docs/AUDIO_BACKEND_GUIDE.zh-CN.md)，版本、失败与证据见[批次记录](docs/tasks/D-AUDIO-BACKEND-01.md)。

## 本机开发环境（2026-09-07）

- 项目：`/Volumes/CodexProjects/Codex/D`
- 应用构建产物、模型与日志：`/Volumes/CodexProjects/Codex/D-Development`
- 纯框架与 MLX 集成构建缓存：`/Volumes/CodexProjects/Codex/BuildCaches/D-Foundation`、`/Volumes/CodexProjects/Codex/BuildCaches/D-MLX`
- 模型下载设置：`/Volumes/CodexProjects/Codex/D-Development/Models`
- Apple M4 / 16 GiB；macOS 26.6.2；Xcode 26.6。
- 打开 `D.xcworkspace`，应用选择 `D` / `My Mac`；CLI 使用 `d-infer`，真实后端测试使用 `DMLXTests`。本机稳定开发签名通过下述脚本/外盘xcconfig生效；直接Xcode GUI默认构建仍可能是ad-hoc，不能混用后假定授权连续。
- 命令行重建：`./scripts/build-local.sh`。默认缓存位于项目同级的 `D-Development`，可用 `D_DEVELOPMENT_ROOT` 覆盖。
- 新 workspace 的本用户 WorkspaceSettings 将 GUI DerivedData 放在外盘 `D-Development/DerivedData-Workspace`，该偏好不提交。命令行的依赖检出分别位于 `SourcePackages-App` 与 `SourcePackages-MLX`，避免并行构建互相清理检出目录。首次环境设置留下的约 636 MB 内置盘临时缓存未删除。
- 外盘需要保持挂载。系统工具、用户偏好及部分系统管理缓存仍位于内置盘。

### 原生构建与完整开发应用

在Xcode打开仓库根目录的 `D.xcworkspace`，选择 `D / My Mac` 即可编辑和编译Swift部分。`scripts/build-local.sh`使用已有本地签名配置构建原生应用；它不会自动把Python音视频环境装入应用。只看原生构建成功，不能判断三个音视频引擎已经部署。

本批统一构建入口的目的，是用**已有离线依赖与既有签名身份**依次构建Swift应用、封装SA3/MRT2、准备及封装视频引擎，得到独立的 `D Development.app`。配置中的运行环境和缓存需由开发者显式指定；工具不下载模型或安装依赖。新操作应使用全新的外盘输出目录，不覆盖普通D或以前的报告。

使用已有 Python 3.12 环境，将 `scripts/development-app-config.example.json` 复制到仓库外的开发目录，填写已批准的本机路径及签名身份。`sourcePackagesTemplate` 必须包含与锁文件一致的干净检出和完整本地 Git 对象，不能依赖其他缓存目录的外部链接。确认全部输入已就绪后，从仓库运行：

```sh
/path/to/existing/python3.12 -B scripts/build-development-app.py \
  --config /Volumes/YourSSD/D-Development/development-build.json \
  --run-root /Volumes/YourSSD/D-Development/Builds/unique-run
```

`unique-run` 必须尚不存在；输出位于其 `output/D Development.app`，汇总在 `evidence/build-development-report.json`，分阶段日志在 `logs`。图文及音视频生成模型仍由应用显式登记，不打进App；下方单独封装的内部音高评估引擎含其固定小型权重，许可边界不同。路径为示例；没有就绪环境时先按音频/视频指南准备，不要把占位值直接运行。工具拒绝缺失或不匹配的输入，并保留失败证据，不自动下载、修复签名或覆盖旧应用。

退出0表示封装完成，2表示输入/工具/报告失败，130表示取消；具体子阶段结果保留在报告中。`packaged`与`runtimeVerification=not-run`只说明封装完成，不代表模型运行、公证或系统隐私授权已验证。当前验收与实际产物索引见[批次记录](docs/tasks/D-MULTIMODAL-BASELINE-01.md)。

## 歌声条件离线准备（开发入口，2026-09-15）

`Backends/Audio/Python/d_singing_prepare.py`将SING1乐句与显式发音清单转换成DiffSinger variance输入：保留歌词、一字多音、休止、音高和整数微秒时值。**输出是prepared JSON，不是WAV，也不是App中的歌声生成功能。** 不自动猜读音、不下载声库，不把音高识别候选直接当已确认乐谱。规格、来源及实际验收状态见[任务](docs/tasks/D-SINGING-BACKEND-01.md)。

从源根使用已批准、可正常运行的独立Python3.12环境。先将`D_SINGING_PYTHON`设为其解释器的绝对路径，将`D_SINGING_OUTPUT`设为任务目录中尚不存在的绝对文件路径（父目录必须已存在，所有路径分量不可为符号链接），然后：

```sh
"$D_SINGING_PYTHON" -B Backends/Audio/Python/d_singing_prepare.py \
  --phrase "$PWD/Backends/Audio/Fixtures/Singing/phrase-v1.json" \
  --pronunciations "$PWD/Backends/Audio/Fixtures/Singing/pronunciations-v1.json" \
  --output "$D_SINGING_OUTPUT"
```

局部CPU回归使用同一解释器执行 `-B -m unittest -v Backends/Audio/Python/tests/test_singing_prepare.py`；事先把`D_TEST_TEMP_DIR`与`TMPDIR`设为已存在的独立任务临时目录，并使用`PYTHONDONTWRITEBYTECODE=1`。测试只写该目录中的合成夹具，不需要模型。

返回0仅表示条件JSON已安全保存；参数、输入或保存失败返回2并在stderr解释，stdout为空。拒绝覆盖已有输出；若文件已发布而后续同步失败，保留已发布文件并报告失败，不自动删除它。夹具发音表是合成测试数据，不代表绮萱或其他声库字典兼容。完整结果保留原始输入；其中`dsSegments`才是DS条件数组，不能将整个封装冒充模型输入或生成结果。

本机Xcode许可门槛与待核歌声材料见[集中待办H20/H21](docs/FAILURE_AND_PERMISSION_AUDIT.zh-CN.md#当前集中待办2026-09-14)。不通过运行系统Python/安装或接受条款来自动解决；此次无需新依赖、模型或应用构建。

## 短原声音高识别：内部评估（2026-09-15）

在包含独立 `PitchEngine.dengine` 的评估构建中，进入项目→音频→已保存原声→音高识别，使用完整原声或已选片段开始分析。可查看连续音高与近似音符、保存或拒绝候选、重开后继续查看、导出JSON。原声和原帧范围保留，不自动量化；当前单声道profile16ms…120秒，实际测试2秒合成声音及约11秒本人录音。尚无音符合成试听、人工修谱、MIDI/MusicXML、歌词演唱或哼唱直接驱动MRT2。

已验收App在外盘 `D-Development/AgentTrials/D-HUM-PITCH-01/run-20260914T152228Z/D Pitch Evaluation r2.app`。这不是替换普通D的发行包。SwiftF0源码/包声明MIT，独立权重许可unknown，**含权重评估App不得据本次授权公开分发**。原始录音、模型和大证据不入Git；[验收与来源](docs/tasks/D-HUM-PITCH-01.md)记录实际版本、限制和已修失败。

上面的统一构建器仍封装SA3/MRT2/视频三引擎，不自动安装识别依赖。识别引擎需在已有批准离线Python3.12/固定依赖/许可证材料齐备时，另执行以下内部评估步骤；各输出必须新建，输入和签名方案保持：

```sh
/path/to/existing/python3.12 -B Backends/Audio/Packaging/prepare_pitch_engine.py \
  --python-root /path/to/approved/python-root \
  --site-packages /path/to/approved/pitch-site-packages \
  --provider-directory Backends/Audio/Python \
  --output /Volumes/YourSSD/D-Development/new/PitchEngine.dengine \
  --internal-evaluation-ack
/path/to/existing/python3.12 -B Backends/Audio/Packaging/package_pitch_app.py \
  --app '/path/to/existing/D Development.app' \
  --engine /Volumes/YourSSD/D-Development/new/PitchEngine.dengine \
  --identity 'EXISTING_DEVELOPMENT_IDENTITY' \
  --output '/Volumes/YourSSD/D-Development/new/D Pitch Evaluation.app' \
  --report /Volumes/YourSSD/D-Development/new/pitch-report.json \
  --internal-evaluation-ack
```

路径与身份是示例，不能直接照抄；工具不下载、不接受许可、不配置钥匙串。缺少固定文件/许可证或已有输出时明确失败。当前机器的实际输入与证据在阶段记录R内，原有运行环境不做就地修补。

## 版本管理

原来的六个 Git 子模块现已纳入主仓库，保留原路径与 Swift package 边界。单仓检查点 `6457418` 已推送；原仓库历史与导入提交见 [来源记录](docs/history/SUBMODULE_PROVENANCE.json)。现在一次提交即可保存应用与各模块的关联修改。统一 Git 管理不等于已经合并所有 Swift 模块。

从零检出（HTTPS，无需 SSH 密钥或递归子模块初始化）：

```sh
git clone --branch codex/inference-foundation https://github.com/lfrledh/D.git
```

环境适配包含 ImageInference 的一个 `Darwin.sqrt` 编译修复。第三方 MLX 与 Flux2 的固定源码、许可证、补丁和摘要保存在 [Vendor](Vendor/README.md)，由 D 的 Git 提交锁定，不需要子模块初始化；Flux2 的具体修改见 [依赖记录](docs/FLUX2_DEPENDENCY_PATCH.zh-CN.md)。当前主仓库工作分支为 `codex/inference-foundation`；旧子模块的修复已在导入前推送到原仓库。

## 验证范围

环境基线已完成锁定依赖解析、命令行及 Xcode 图形界面 Debug arm64 构建、本地签名检查、应用启动与主窗口检查，以及应用内外盘下载路径设置。单仓迁移后的普通 clone 已通过 16 项纯框架测试与旧应用构建。这部分属于当时的历史基线；当前工作台已有独立的项目／任务测试，不能用旧构建记录替代当前 UI 验收。

2026-09-06 的文本基础阶段快照：固定版本的 Qwen2.5-0.5B-Instruct-4bit 已下载到外盘并校验，独立 CLI 的 10 类进程验收全部通过，覆盖真实输出、token 上限、连续运行、取消、信号与断管后的清理及报告保存。详情和复验入口见 [本地 MLX 使用说明](docs/MLX_REFERENCE_GUIDE.zh-CN.md)。

该文本检查点的 MLX XCTest 实际通过 25 项声明、37 个参数展开场景，0 失败、0 跳过；此前外盘访问授权造成的启动阻塞未在此次运行中重现。原先每轮 2720 字节增长已通过回移 MLX 所有权修复解决：C++ 7 组生命周期回归通过，50 轮真实推理释放后的 MLX 活跃分配与缓存均为 0。该证据针对已复现缺陷，不代表整个进程无任何泄漏。修复和依赖取舍见 [修复报告](docs/MLX_OWNERSHIP_FIX.zh-CN.md)。

2026-09-07 的 B2 图文 XCTest 已实际通过 **61 项声明／120 个展开场景**，**0 失败、0 跳过**，包含真实三轮图像、12 个阶段取消、图文交接、损坏权重和输出失败后的释放与恢复。测试观测的释放后 MLX 活跃分配和缓存均回到 0。最终图像 CLI 17/17、文本 CLI 10/10 与当时的旧应用构建均通过；各自的执行结果见 [图像运行时验收](docs/IMAGE_RUNTIME_ACCEPTANCE.zh-CN.md)。

工作台使用项目与模型库的安全作用域书签。应用的“资源 → 管理模型…”提供固定模型下载、暂停／继续、完整校验与已有模型登记；模型权重与暂存位于用户选择的外盘目录，小型索引和书签位于应用容器。关闭窗口后下载继续，退出应用保存检查点。模型库与服务检查点已经验收：58 项服务／安装器测试、6 项 UI 测试及普通沙盒真实下载到出图通过，详情和限制见 [验收报告](docs/MODEL_LIBRARY_ACCEPTANCE.zh-CN.md)。旧下载器不再接入应用。

早期代码审阅见 [项目审阅与讨论建议](docs/PROJECT_REVIEW.zh-CN.md)；其中环境与验证状态属于当时的历史基线，当前状态以上述进展为准。

## 架构研究与新框架（2026-09-07）

当前定位：面向创作者、艺术家和学生的可组合多模态Mac工作台，独立完成有限AI流程并与专业工具协作。[总体战略](docs/PRODUCT_STRATEGY.zh-CN.md)和[指导原则](docs/PRODUCT_PRINCIPLES.zh-CN.md)维护方向；节点不是必经阶段。下述模块是已有实现，通用组合/可编辑布局仍未完成；早期研究与基线见[架构研究报告](docs/ARCHITECTURE_RESEARCH.zh-CN.md)。

根目录 Swift package 含 DInference（纯契约）和 DRuntime（串行任务生命周期）两个 target，零远程依赖、Swift 6 严格模式。Backends/MLX 中的 DMLXBackend 提供文本与图像后端，d-infer 是宿主入口。现有 Packages/UI 包内包含两个实际 target：DWorkbench 拥有项目、任务、资产及模型安装服务，只依赖 DInference；UI 依赖这些服务，负责展示和原生交互。D 应用装配具体 runtime／backend。其他旧 Packages/* 暂留源代码，不在新应用依赖路径中。

逻辑导航为“项目 → 模态 → 创作/参数/资产”，模型是共享资源，任务是运行状态。单项目支持多份创作文档；当前统一候选schema11涵盖图文音视频及两类新来源记录，旧schema5是音频阶段的历史格式。旧格式迁移先保留原清单备份，原媒体不改写，本批只迁移自有验收项目；快速草稿仍待排期。结构与服务演进规则见 [信息架构](docs/decisions/0007-project-information-architecture.md) 和 [服务边界](docs/decisions/0008-application-services-and-provider-evolution.md)。远程 API、对外推理服务和 RAW 媒体按目标清单后续启动，没有空的产品入口。

运行 `./scripts/test-foundation.sh` 验证框架；运行 `./scripts/build-local.sh` 构建新应用，`./scripts/test-workbench.sh` 验证无 GPU 的项目与任务服务。二者默认使用外置SSD缓存：应用在D-Development，新核心测试在同级BuildCaches/D-Foundation；日志都保存在D-Development/Logs。详见 [框架调用与限制](docs/FOUNDATION_USAGE.md)、[架构决策](docs/decisions/0001-inference-boundary.md)、[任务生命周期决策](docs/decisions/0002-run-lifecycle.md)。

用户补充的旧规划已按原文保存在 [历史材料](docs/history/README.md)，当前协作规则见AGENTS.md。阶段规模、模型分工与验收方式见 [交付与模型预算计划](docs/DELIVERY_AND_MODEL_BUDGET.zh-CN.md)。提交与远程同步状态以 Git 为准。

## 真实 MLX 推理入口

文本调用见 [本地 MLX 使用说明](docs/MLX_REFERENCE_GUIDE.zh-CN.md)，图像调用见 [图像运行时使用说明](docs/IMAGE_RUNTIME_GUIDE.zh-CN.md)。在仓库根目录运行：

| 入口 | 用途 |
| --- | --- |
| `./scripts/build-mlx.sh` | 校验固定 MLX／Flux2 源码并构建 d-infer |
| `./scripts/test-mlx.sh [文本模型目录] [图像模型目录]` | 固定模型校验、测试构建、图文真实测试和零跳过证据检查 |
| `python3 scripts/verify-mlx-cli.py` | 文本 CLI 进程验收 |
| `python3 scripts/verify-image-cli.py` | 图像 CLI 进程验收；`--offline-only` 仅检查帮助和非法参数 |
| `python3 scripts/verify-mlx-vendor.py` | 无网络校验固定 MLX 源码及补丁 |
| `python3 scripts/verify-flux2-vendor.py` | 无网络校验固定 Flux2 源码、fixture 及补丁 |

`test-mlx.sh` 默认使用外盘的 Qwen2.5-0.5B-Instruct-4bit 和 FLUX.2-klein-4B-q8 两个模型目录；缺失或损坏任一模型会失败，不会跳过真实图像测试。图像 CLI 验证报告目录必须是新目录，已有作品与证据不会被清除。
