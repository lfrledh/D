# D

开发中的原生 macOS 本地 AI 创作工作台，使用 SwiftUI、MLX Swift 和 Hugging Face 模型。

原生 SwiftUI／Liquid Glass 工作台通过 DRuntime 与 DMLXBackend 运行图像任务，使用自包含 `.dproject` 保存作品和生成条件。已支持项目内多份独立创作、候选整理、两图比较和条件复用，见 [最新验收](docs/EXPLORATION_STAGE_ACCEPTANCE.zh-CN.md)。当前行动与验收状态集中在 [行动指南](docs/CURRENT_ACTIONS.zh-CN.md)。已完成的单项目检查点见 [工作台验收](docs/WORKBENCH_ACCEPTANCE.zh-CN.md)，后续目标统一维护在 [产品目标清单](docs/PRODUCT_GOALS.zh-CN.md)。文字现已接入同一项目的有限创作闭环：选段改写、候选接受/拒绝、受保护撤销、安全保存重开；旧文本和占位界面已退出。PNG支持实际任务配方公开/私有预览、新副本内嵌、离线读回并显式恢复为新草稿。两者已本地验收，范围及真实运行证据见 [T0任务](docs/tasks/D-T0-WORKBENCH-01.md) 和 [PNG任务](docs/tasks/D-META-PNG-01.md)；CLI继续保留。

单仓整合与真实文本推理基础的四项工作已完成，最终验收结果和边界见 [基础阶段验收](docs/FOUNDATION_STAGE_ACCEPTANCE.zh-CN.md)。

图像 B2 已将分阶段加载、图像生成、进度、取消和产物引用接入现有核心，并完成图文总验收。当前固定支持 FLUX.2 Klein 4B q8、512×512、4 步、guidance 1。调用与限制见 [图像运行时使用说明](docs/IMAGE_RUNTIME_GUIDE.zh-CN.md)，最终检查点的运行证据与验收结论集中记录在 [图像运行时验收](docs/IMAGE_RUNTIME_ACCEPTANCE.zh-CN.md)。

此前的 B1 是独立硬件实验：同进程三轮各约 35 秒，MLX 分配峰值约 5.78 GiB，释放后约 0.5 MiB 残留。该实验及其 [原始报告](docs/IMAGE_PROBE_RESULTS.zh-CN.md) 保留为历史对照，不能用它代替 B2 的运行时与资源验收。

## 音频后端与跨配置（2026-09-10）

统一音频后端现已接入源工作分支。SA3 small music真实完成6秒提示生成、参考变体、区间重绘和取消/超时恢复；输出44.1kHz双声道float32 WAV及实际执行记录，样本经用户试听正常。2026-09-12 APP1内嵌引擎版的普通沙盒音频界面已通过真实生成/参考变体/区间重绘、取消交接、试听采用拒绝及安全导出/退出重开；[任务与证据](docs/tasks/D-AUDIO-APP-01.md)。普通D.app未替换，麦克风仍等设备；plain build-local不自动封装引擎，见[离线部署步骤](docs/AUDIO_BACKEND_GUIDE.zh-CN.md#应用内引擎的重建与保护)。Qwen1.5B短改写与取消、FLUX768×512已实测；更大型号和高配Mac仍逐项待测，不改既有量化精度。调用与限制见[后端指南](docs/AUDIO_BACKEND_GUIDE.zh-CN.md)，版本、失败与证据见[批次记录](docs/tasks/D-AUDIO-BACKEND-01.md)。

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

最新定位：面向视觉探索与创作，独立完成 AI 关键流程并与专业软件协作的 Mac 工作台。已确认的场景、范围与证据见 [总体产品规划](docs/PRODUCT_STRATEGY.zh-CN.md)；节点不是必经阶段。研究结论和框架基线见 [架构研究报告](docs/ARCHITECTURE_RESEARCH.zh-CN.md)。

根目录 Swift package 含 DInference（纯契约）和 DRuntime（串行任务生命周期）两个 target，零远程依赖、Swift 6 严格模式。Backends/MLX 中的 DMLXBackend 提供文本与图像后端，d-infer 是宿主入口。现有 Packages/UI 包内包含两个实际 target：DWorkbench 拥有项目、任务、资产及模型安装服务，只依赖 DInference；UI 依赖这些服务，负责展示和原生交互。D 应用装配具体 runtime／backend。其他旧 Packages/* 暂留源代码，不在新应用依赖路径中。

逻辑导航为“项目 → 模态 → 创作/参数/资产”，模型是共享资源，任务是运行状态。单项目支持多份创作文档，当前schema5含音频候选；旧格式迁移先保留原清单备份，原媒体不改写，真实用户项目未在本批迁移；快速草稿仍待排期。结构与服务演进规则见 [信息架构](docs/decisions/0007-project-information-architecture.md) 和 [服务边界](docs/decisions/0008-application-services-and-provider-evolution.md)。远程 API、对外推理服务和 RAW 媒体按目标清单后续启动，没有空的产品入口。

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
