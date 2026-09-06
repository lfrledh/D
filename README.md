# D

原生 macOS 本地 AI 工作站原型，使用 SwiftUI、MLX Swift 和 Hugging Face 模型。

目前的新推理链路已通过 DRuntime 调度固定文本模型和 FLUX.2 Klein 图像模型，并提供独立命令行入口。旧 SwiftUI 应用保留文本与部分图像推理原型，尚未接入新 runtime；SD3、音频、视频、视觉语言和 AI 助手仍未完成。

单仓整合与真实文本推理基础的四项工作已完成，最终验收结果和边界见 [基础阶段验收](docs/FOUNDATION_STAGE_ACCEPTANCE.zh-CN.md)。

图像 B2 已将分阶段加载、图像生成、进度、取消和产物引用接入现有核心，并完成图文总验收。当前固定支持 FLUX.2 Klein 4B q8、512×512、4 步、guidance 1。调用与限制见 [图像运行时使用说明](docs/IMAGE_RUNTIME_GUIDE.zh-CN.md)，最终检查点的运行证据与验收结论集中记录在 [图像运行时验收](docs/IMAGE_RUNTIME_ACCEPTANCE.zh-CN.md)。

此前的 B1 是独立硬件实验：同进程三轮各约 35 秒，MLX 分配峰值约 5.78 GiB，释放后约 0.5 MiB 残留。该实验及其 [原始报告](docs/IMAGE_PROBE_RESULTS.zh-CN.md) 保留为历史对照，不能用它代替 B2 的运行时与资源验收。

## 本机开发环境（2026-09-07）

- 项目：`/Volumes/CodexProjects/Codex/D`
- 应用构建产物、模型与日志：`/Volumes/CodexProjects/Codex/D-Development`
- 纯框架与 MLX 集成构建缓存：`/Volumes/CodexProjects/Codex/BuildCaches/D-Foundation`、`/Volumes/CodexProjects/Codex/BuildCaches/D-MLX`
- 模型下载设置：`/Volumes/CodexProjects/Codex/D-Development/Models`
- Apple M4 / 16 GiB；macOS 26.6.2；Xcode 26.6。
- 打开 `D.xcworkspace`，应用选择 `D` / `My Mac`；CLI 使用 `d-infer`，真实后端测试使用 `DMLXTests`。Debug 使用本机 ad-hoc 签名。
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

环境基线已完成锁定依赖解析、命令行及 Xcode 图形界面 Debug arm64 构建、本地签名检查、应用启动与主窗口检查，以及应用内外盘下载路径设置。单仓迁移后的普通 clone 已通过 16 项纯框架测试与旧应用构建。原有应用测试大多为空模板，不能据此证明推理正确。

2026-09-06 的文本基础阶段快照：固定版本的 Qwen2.5-0.5B-Instruct-4bit 已下载到外盘并校验，独立 CLI 的 10 类进程验收全部通过，覆盖真实输出、token 上限、连续运行、取消、信号与断管后的清理及报告保存。详情和复验入口见 [本地 MLX 使用说明](docs/MLX_REFERENCE_GUIDE.zh-CN.md)。

该文本检查点的 MLX XCTest 实际通过 25 项声明、37 个参数展开场景，0 失败、0 跳过；此前外盘访问授权造成的启动阻塞未在此次运行中重现。原先每轮 2720 字节增长已通过回移 MLX 所有权修复解决：C++ 7 组生命周期回归通过，50 轮真实推理释放后的 MLX 活跃分配与缓存均为 0。该证据针对已复现缺陷，不代表整个进程无任何泄漏。修复和依赖取舍见 [修复报告](docs/MLX_OWNERSHIP_FIX.zh-CN.md)。

2026-09-07 的 B2 图文 XCTest 已实际通过 **61 项声明／120 个展开场景**，**0 失败、0 跳过**，包含真实三轮图像、12 个阶段取消、图文交接、损坏权重和输出失败后的释放与恢复。测试观测的释放后 MLX 活跃分配和缓存均回到 0。最终图像 CLI 17/17、文本 CLI 10/10 与旧应用构建均通过，旧 UI 尚未迁移；各自的执行结果见 [图像运行时验收](docs/IMAGE_RUNTIME_ACCEPTANCE.zh-CN.md)。

原有下载路径实现没有持久化 security-scoped bookmark，外盘目录跨重启访问仍需修复/验证；仅保存路径字符串不能保证永久授权。StableDiffusion 使用独立 HubApi，缓存路径还需统一。

早期代码审阅见 [项目审阅与讨论建议](docs/PROJECT_REVIEW.zh-CN.md)；其中环境与验证状态属于当时的历史基线，当前状态以上述进展为准。

## 架构研究与新框架（2026-09-07）

最新定位：像ComfyUI一样灵活、提供更易用模式的专业Mac本地AI创作工作站。研究结论和框架基线见 [架构研究报告](docs/ARCHITECTURE_RESEARCH.zh-CN.md)。

根目录内部 Swift package 含 DInference（纯契约）和 DRuntime（串行任务生命周期）两个 target，零远程依赖、Swift 6 严格模式。Backends/MLX 中的 DMLXBackend 提供真实文本与图像后端，d-infer 是宿主入口。B2 复用这三个核心模块，没有新增生产框架包；旧应用仍使用 Packages/*，尚未接入新的 runtime。

运行 `./scripts/test-foundation.sh` 验证框架；运行 `./scripts/build-local.sh` 构建旧应用。二者默认使用外置SSD缓存：应用在D-Development，新核心测试在同级BuildCaches/D-Foundation；日志都保存在D-Development/Logs。详见 [框架调用与限制](docs/FOUNDATION_USAGE.md)、[架构决策](docs/decisions/0001-inference-boundary.md)、[任务生命周期决策](docs/decisions/0002-run-lifecycle.md)。

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
