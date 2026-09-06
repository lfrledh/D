# D

原生 macOS 本地 AI 工作站原型，使用 SwiftUI、MLX Swift 和 Hugging Face 模型。

目前文本推理链路与部分图像推理代码已实现；SD3、音频、视频、视觉语言和 AI 助手仍未完成。构建通过不代表全部模型推理已验证。

## 本机开发环境（2026-09-06）

- 项目：`/Volumes/CodexProjects/Codex/D`
- 缓存、构建产物、日志：`/Volumes/CodexProjects/Codex/D-Development`
- 模型下载设置：`/Volumes/CodexProjects/Codex/D-Development/Models`
- Apple M4 / 16 GiB；macOS 26.6.2；Xcode 26.6。
- 打开 `D.xcodeproj`，选择 `D` / `My Mac`。Debug 使用本机 ad-hoc 签名。
- 命令行重建：`./scripts/build-local.sh`。默认缓存位于项目同级的 `D-Development`，可用 `D_DEVELOPMENT_ROOT` 覆盖。
- Xcode 的本用户 WorkspaceSettings 已将 DerivedData 放在外盘；该本地偏好不提交；命令行和 Xcode 项目缓存目录内均设置 SourcePackages 链接，以复用外盘依赖。Xcode 会在指定 DerivedData 内再创建项目子目录。首次打开留下约 636 MB 内置盘临时缓存，未删除。
- 外盘需要保持挂载。系统工具、用户偏好及部分系统管理缓存仍位于内置盘。

## 版本管理

原来的六个 Git 子模块现已纳入主仓库，保留原路径与 Swift package 边界。原仓库历史与导入提交见 [来源记录](docs/history/SUBMODULE_PROVENANCE.json)。现在一次提交即可保存应用与各模块的关联修改。

从零检出（HTTPS，无需 SSH 密钥或递归子模块初始化）：

```sh
git clone https://github.com/lfrledh/D.git
```

环境适配包含 ImageInference 的一个 `Darwin.sqrt` 编译修复。当前主仓库工作分支为 `codex/inference-foundation`；旧子模块的修复已在导入前推送到原仓库。

## 验证范围

已完成锁定依赖解析、命令行及 Xcode 图形界面 Debug arm64 构建、本地签名检查、应用启动与主窗口检查，以及应用内外盘下载路径设置。没有下载模型权重，未验证文本输出或图像生成质量。原有单元测试基本为空模板。

原有下载路径实现没有持久化 security-scoped bookmark，外盘目录跨重启访问仍需修复/验证；仅保存路径字符串不能保证永久授权。StableDiffusion 使用独立 HubApi，缓存路径还需统一。

详见 [项目审阅与讨论建议](docs/PROJECT_REVIEW.zh-CN.md)。

## 架构研究与新框架（2026-09-06）

最新定位：像ComfyUI一样灵活、提供更易用模式的专业Mac本地AI创作工作站。研究结论和框架基线见 [架构研究报告](docs/ARCHITECTURE_RESEARCH.zh-CN.md)。

根目录新增一个内部Swift package，含DInference（纯契约）和DRuntime（串行任务生命周期）两个target，零远程依赖、Swift6严格模式。它是迁移目的地；旧应用仍使用Packages/*，尚未接入新的runtime。

运行 `./scripts/test-foundation.sh` 验证框架；运行 `./scripts/build-local.sh` 构建旧应用。二者默认使用外置SSD缓存：应用在D-Development，新核心测试在同级BuildCaches/D-Foundation；日志都保存在D-Development/Logs。详见 [框架调用与限制](docs/FOUNDATION_USAGE.md)、[架构决策](docs/decisions/0001-inference-boundary.md)、[任务生命周期决策](docs/decisions/0002-run-lifecycle.md)。

用户补充的旧规划已按原文保存在 [历史材料](docs/history/README.md)，当前协作规则见AGENTS.md。阶段规模、模型分工与验收方式见 [交付与模型预算计划](docs/DELIVERY_AND_MODEL_BUDGET.zh-CN.md)。提交与远程同步状态以 Git 为准。
