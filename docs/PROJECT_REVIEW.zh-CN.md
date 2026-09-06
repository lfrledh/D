# D：项目审阅与计划讨论底稿

审阅时间：2026-09-06。基线：主仓库 `708f5fb`（2026-04-03），6 个子模块使用主仓库锁定提交。本文件是依据代码重建的理解与建议，不是找回的原始需求文档，也不是已经确认的新计划。

## 本次完成

代码与主要开发产物已放到外置 2 TB APFS SSD 的 CodexProjects 卷；与 aroma 卷共享同一个约 2 TB APFS 容器，可用容量不能相加。Xcode 工程已打开，依赖解析成功，Debug 构建成功，D 主窗口已通过实际 UI 检查。

本地变更只有：ImageInference 的 AttentionBlock 显式使用 Darwin.sqrt；三个 Debug target 使用本地 ad-hoc 签名；本用户外盘 DerivedData 偏好；构建脚本与说明文档。Release 签名保持原配置。未升级依赖、未实现新产品功能、未推送 GitHub。

日志在同级 D-Development/Logs：resolve.log、build.log（原始失败）、build-fixed.log（成功）。应用在 D-Development/DerivedData/Build/Products/Debug/D.app。

未发现 README、AGENTS.md 或旧规划 Markdown：主仓库与子模块当前文件和可达 Git 历史中均未找到此类说明。仅发现 project_tree.txt 与空的 VAEConfig.txt。旧 AI 的说明可能未提交或位于仓库之外。

## 从代码还原的目标

D 希望成为 Apple Silicon 上的原生多模态 AI 工作站：统一下载、选择、加载和卸载模型，通过共享界面完成文本、图像、音频、视频及视觉语言任务，并提供参数面板与生成资产历史。AIAssistant 包表明有更高层助手的预留，但无法仅凭这个名称确认原先是否计划自主 Agent、工具调用或工作流编排。

主要模块：

| 模块 | 实际职责与状态 |
| --- | --- |
| D | SwiftUI 应用入口、依赖装配、下载路径、图像服务选择 |
| Core | 硬件快照、模型描述与参数、服务协议；部分类型未接入流程 |
| ModelLoading | Actor 管理模型容器、Hugging Face 下载、本地文本模型加载 |
| TextInference | MLX ChatSession 包装，流式文本生成 |
| ImageInference | SD2.1 / SDXL Turbo 包装及自写 SD3、VAE、CLIP、T5 组件 |
| UI | 多模态标签、资源/参数侧栏、生成区、下载管理、图像历史 |
| AIAssistant | 仅 import Foundation 和占位注释 |

本地包约 5,178 行 Swift（包含 manifest 与测试模板）。代码规模不能转换为可靠的完成百分比。

## 当前进度

| 能力 | 代码证据 | 判断 |
| --- | --- | --- |
| 应用与模块装配 | DApp、MainView、六个 Swift 包 | 已构建、已启动 |
| 文本 | 本地加载、ChatSession、参数、流式输出、取消按钮 | 主链路已有实现，真实模型尚未实测 |
| 基础图像 | StableDiffusionService 只接受 SDXL Turbo 和 SD2.1 base | 有生成链路，加载路径、错误和输出需验证 |
| SD3 / SD3.5 | 多个模型组件存在，SD3Service.performGeneration 直接 finish | 未接通，当前无法生成 |
| 音频 / 视频 / 视觉语言 | 标签页占位，服务协议为空 | 未实现 |
| AI 助手 | 空包 | 未实现 |
| 模型下载 | 进度、暂停、恢复、取消 UI 与部分逻辑 | 原型，恢复和错误处理有明显缺口 |
| 历史 / 项目资产 | NSImage 内存数组、缩略图，详情占位 | 无持久化项目/资产管理闭环 |
| 测试 | 单元测试为空 example，UI 测试主要是启动模板 | 没有推理正确性保障 |

因此更适合把现状视为“有界面和部分推理链路的可运行原型”。

## 主要难点与代码风险

1. **模型兼容与推理正确性（高难度）**：自写 SD3/VAE/T5 需要验证张量布局、权重键映射、数值精度、scheduler、提示词编码和解码完整链路。AttentionBlock 把张量解释为 NCHW，但 MLX 卷积路径需核对布局；T5Attention 返回 scores 并被下层复用为 positionBias，存在数值语义疑点；SD3Transformer 中 useDual 计算后未使用。上述是静态审阅线索，需对照参考实现与固定输入测试，不能靠编译通过判定正确。
2. **任务取消与并发（中高难度）**：生成服务另建 Task / Task.detached，AsyncStream 没有 onTermination 取消传递；停止 UI 消费不保证底层停止推理。部分状态使用 @unchecked Sendable，存在共享可变状态风险。
3. **16 GiB 内存约束（中高难度）**：HardwareProfile 有预算计算，但 MLXConfiguration.configure 没有调用者。缓存可同时保留文本和图像服务，缺少统一排队、峰值预测和卸载策略。SSD 增加模型存储容量，不增加统一内存。
4. **下载与模型存储（中等难度）**：resumeDownload 调用 startDownload，但后者发现 existing 就返回旧 handle，不创建新 Task；暂停的取消错误也可能覆盖 paused 状态。图像加载仅接受 models--org--model 文件夹名，而下载路径使用 HubApi.localRepoLocation，需要统一模型定位方式。下载会 snapshot 整个仓库，缺少必要文件筛选。
5. **外盘与沙盒（中等难度）**：SettingsView 仅保存路径字符串，无持久化 security-scoped bookmark；StableDiffusion 使用默认 HubApi，与显式 downloadBase 的下载器不一致。已设置外盘目录，但跨重启权限和所有推理后端的缓存位置不能视为验证完成。
6. **错误透明度（中等难度）**：StableDiffusionService catch 直接 finish，UI 可能无图也无错误；SD3 占位同样静默结束。应统一成可取消且能传递结构化错误/进度的接口。
7. **维护成本（中等难度）**：六个子模块让一个人的原子修改和版本协调变复杂；主工程与包对 mlx-swift-examples 的依赖约束不同。锁文件此次可用，升级仍应单独评估。包最低 macOS 14，而 App 设置 macOS 26.2，产品系统范围也需明确。

## 生态变化带来的选择

本次仅核对官方文档作初步方向判断，未做完整竞品调研，也未据此升级工程。

- MLX Swift LM 的官方仓库已提供 LLM / VLM 以及新的 Hugging Face 集成示例；当前项目锁定 2.30.6，后续升级需要 API 迁移评估：[官方仓库](https://github.com/ml-explore/mlx-swift-lm)。
- LM Studio 提供本地 HTTP 接口、兼容接口、工具调用和 MCP 相关能力：[开发文档](https://lmstudio.ai/docs/developer)、[工具调用](https://lmstudio.ai/docs/developer/openai-compat/tools)。
- Ollama 已有工具调用与流式工具调用支持：[工具调用](https://ollama.com/blog/tool-support)、[流式工具调用](https://ollama.com/blog/streaming-tool)。这些能力并非全部在 D 停滞之后才出现，应避免把现有能力误称为近期新增。

我的建议：D 保留原生 Mac 体验、模型/资产组织和任务控制，把推理后端做成可替换适配器。原生 MLX 和可选本地服务可以共存。是否支持云端是产品偏好，需要由你决定。不要把“重写每个模型架构”作为默认投入方向，除非底层推理研究本身就是你的目标。

## 建议讨论的阶段计划（尚未批准）

1. 明确第一位用户、最重要的三个任务、是否严格离线，以及更重视创作还是助手自动化。
2. 固定可重复构建基线，补任务取消、错误、内存、外盘权限与模型目录管理。
3. 选一个完整工作流验收：模型获取 → 加载 → 生成 → 停止 → 保存 → 重开恢复；先在这台 M4 / 16 GiB 上实测。
4. 对原生 MLX 与本地服务适配做小规模比较，用稳定性、峰值内存、速度、模型覆盖及维护成本决定默认后端。
5. 在文本闭环和一个图像后端可靠后，按实际需求逐步加入视觉语言、语音或 Agent；视频及多模型并行最后评估。

难度判断：聚焦的文本工作台为中等；稳定的文本+图像工作站为中高；自研全模态推理与可靠 Agent 为高。当前没有足够需求与性能数据支持可信工期或百分比承诺。
