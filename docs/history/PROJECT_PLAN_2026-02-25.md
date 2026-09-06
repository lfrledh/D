//
//  PROJECT_PLAN.md
//  second try
//
//  Created by lfrledh on 2/25/26.
//
# 项目技术规划 PROJECT_PLAN.md

**版本：** 2.0
**日期：** 2026-02-25
**状态：** 规划中（基于重构后架构）

---

## 1. 项目愿景与核心哲学

构建一个 **健壮、可扩展、高度可维护** 的本地生成式 AI 推理平台（macOS 应用），以 **模型文件为中心**，支持 Safetensors 格式的主流开源模型（文本、图像、音频等）。核心设计目标：

- **稳定性优先**：不追求极致性能，但确保长时间运行无崩溃、无内存泄漏。
- **清晰分层**：严格隔离 UI、业务逻辑、数据模型，杜绝线程污染。
- **模块解耦**：每个模块职责单一，通过协议通信，便于替换和升级。
- **可测试性**：核心逻辑独立于 UI，可单元测试。

---

## 2. 总体架构

```
[Presentation Layer]       → SwiftUI Views (仅 UI)
          ↓
[ViewModel Layer]          → @MainActor ViewModels (UI状态，无业务)
          ↓
[Actor Layer]              → 并发安全容器 (ModelLoadingActor, InferenceCoordinatorActor)
          ↓
[Service Layer]            → 面向任务的接口协议 (TextGenerationService, etc.)
          ↓
[Model Adaptation Layer]   → 模型适配器 (实现 ModelAdapter, 使用 MLX)
          ↓
[Hardware Abstraction]     → 内存/设备配置 (HardwareProfile, MLX setup)
```

**关键原则：**

- **UI 层（Presentation + ViewModels）** 只能运行在主线程，所有耗时操作通过 `Task` 调用 Actors。
- **ViewModels** 仅暴露值类型（`String`, `Bool`, `[ModelInfo]`），不持有任何模型对象。
- **Actors** 是唯一持有可变状态（如已加载的适配器、当前内存使用）的地方，所有方法均为 `nonisolated` 以便从任何上下文调用。
- **Service 协议** 定义业务能力（如生成文本），实现类通常包装一个具体的 `ModelAdapter`，并可在非隔离上下文中调用。
- **Model Adapters** 负责与 MLX 交互，加载权重，执行推理。内部自定义 `Module` 子类全部标记 `@unchecked Sendable`，属性为 `let` 常量。
- **所有数据模型**（如 `ModelConfig`, `GenerateParameters`）均为 `Sendable` 结构体，禁止任何 `@MainActor` 注解。

---

## 3. 模块划分与职责

### 3.1 数据模型模块 `Models/`
- **职责**：存放所有跨层传递的纯值类型，无业务逻辑。
- **关键类型**：
  - `ModelConfig`：从 `config.json` 解析的配置
  - `LoadedTensor`：加载的权重数据（配合 SafetensorsLoader）
  - `GenerateParameters` / `ImageGenerationParameters`：生成参数
  - `InferenceTask`：描述推理任务的枚举
  - `ModelCapability`：模型能力选项集
  - `ModelInfo`：用于 UI 显示的模型摘要信息
- **规则**：所有属性为 `let`，结构体自身遵循 `Sendable`；不得包含任何 `@MainActor` 或 `nonisolated` 关键字（因为它们天然可在任意上下文使用）。

### 3.2 硬件抽象层 `Hardware/`
- **职责**：提供系统内存、GPU 核心数等只读信息，供内存规划使用。
- **关键类型**：
  - `HardwareProfile`：一次性快照，包含总内存、可用内存、推理预算等
  - `MLXConfiguration`：设置 MLX 内存限制、默认设备
- **规则**：均为 `Sendable` 结构体，初始化方法可在任何线程调用。

### 3.3 协议层 `ModelAdaptation/Protocols/`
- **职责**：定义各模块间的契约。
- **关键协议**：
  - `ModelAdapter`：所有模型适配器必须遵循的协议
  - `VisionAddOn`：用于多模态模型的视觉编码插件
- **规则**：协议本身应遵循 `Sendable`，所有方法标记 `nonisolated`（除非确实需要 actor 隔离）。

### 3.4 公共基础设施 `ModelAdaptation/Common/`
- **职责**：提供跨适配器共享的工具，如 safetensors 加载、分词器基类。
- **关键组件**：
  - `SafetensorsLoader`：静态方法，从文件加载 `[String: MLXArray]`
  - `BPETokenizer`：GPT-2 风格的分词器（线程安全）
- **规则**：所有方法应为 `nonisolated static`，返回 `Sendable` 类型；内部使用 `nonisolated(unsafe)` 处理非 `Sendable` 缓存时需保证只读。

### 3.5 适配器实现 `ModelAdaptation/TextModels/`、`VisionModels/` 等
- **职责**：实现具体模型（如 LLaMA、Flux）的 `ModelAdapter`。
- **设计要点**：
  - 每个适配器是一个 `final class`，遵循 `ModelAdapter` 和 `@unchecked Sendable`。
  - 内部包含 MLXNN 构建的模型结构（定义为嵌套 `private class`，均遵循 `@unchecked Sendable`）。
  - 所有存储属性为 `let` 常量（或 `nonisolated(unsafe) let`），确保初始化后只读。
  - 权重加载通过 `update(parameters:)` 更新模型参数。
  - 生成方法（如 `generateStream`）返回 `AsyncStream<String>`，内部循环检查 `Task.isCancelled`。

### 3.6 Actor 层 `Actors/`
- **职责**：保护共享可变状态，提供线程安全的业务入口。
- **关键 Actors**：
  - `ModelLoadingActor`：负责解析配置、加载 safetensors、实例化适配器。内部缓存已加载的适配器。
  - `InferenceCoordinatorActor`：管理推理任务的内存预算和并发执行，对外提供 `enqueue` 方法返回 `AsyncStream<String>`。
- **规则**：
  - 所有公开方法为 `nonisolated`，以便从任何上下文调用。
  - 内部状态使用 actor 隔离保护，方法间通过异步调用。
  - 返回 `AsyncStream` 时，确保流在后台生产元素，且生产过程中检查取消。

### 3.7 服务层 `Services/`
- **职责**：为 ViewModels 提供面向业务的高层接口，隐藏适配器细节。
- **关键服务**：
  - `TextGenerationService`：协议，定义 `generate(prompt:parameters:) -> AsyncStream<String>`
  - `LLaMATextGenerationService`：具体实现，包装 `LLaMAAdapter`，在非隔离上下文中调用适配器的生成方法。
- **规则**：服务类遵循 `@unchecked Sendable`，内部持有适配器（只读）；所有方法为 `nonisolated`。

### 3.8 ViewModel 层 `ViewModels/`
- **职责**：作为 UI 的唯一数据源，处理用户事件，调用 Actors，更新 UI 状态。
- **关键 ViewModel**：
  - `MainViewModel`：管理模型加载、生成状态、错误信息等。
- **规则**：
  - 类标记 `@MainActor`，所有属性为 `@Observable`。
  - 不持有任何业务对象（如适配器、服务），只通过依赖注入的 Actors 间接操作。
  - 耗时操作通过 `Task` 启动，在 `Task` 内部调用 actors，然后通过 `MainActor.run` 更新属性。

### 3.9 视图层 `Presentation/`
- **职责**：纯 SwiftUI 视图，仅绑定 ViewModel 的属性，不包含业务逻辑。
- **规则**：
  - 视图可访问 `@EnvironmentObject` 或直接传入 ViewModel。
  - 所有按钮、手势事件通过调用 ViewModel 的方法处理。
  - 避免在视图中创建 `Task`，所有异步操作由 ViewModel 发起。

---

## 4. 关键技术决策

### 4.1 并发安全策略
- **数据模型**：始终为 `Sendable` 结构体，无隔离注解。
- **协议方法**：一律标记 `nonisolated`，除非明确需要 actor 上下文。
- **Actors**：仅用于管理可变状态；方法为 `nonisolated` 以便调用方无需关心是否在 actor 内部。
- **MLXNN 自定义子类**：添加 `@unchecked Sendable`，存储属性用 `let` 或 `nonisolated(unsafe) let`，手动保证只读。
- **闭包传递**：跨 actor 传递的闭包必须标记 `@Sendable`。

### 4.2 错误处理
- 使用 `enum` 定义明确错误类型，遵循 `Error` 和 `Sendable`。
- 在 actor 方法中抛出错误，由 ViewModel 捕获并转换为 UI 可显示的消息。

### 4.3 内存管理
- 使用 `HardwareProfile` 在启动时计算推理内存预算。
- `InferenceCoordinatorActor` 跟踪当前使用内存，在 `enqueue` 时检查预算，任务结束后释放。
- 避免在 MLX 中过度分配，通过 `MLX.set(memoryLimit:)` 配置硬限制。

### 4.4 取消机制
- 所有长时间运行的操作（如生成循环）必须在每次迭代前检查 `Task.isCancelled`。
- 在 `AsyncStream` 的 `onTermination` 中取消内部任务。
- ViewModel 中的 `generationTask` 可随时取消，并传播给 actor。

### 4.5 文件大小限制
- 每个 Swift 文件不超过 500 行，超过时按功能拆分（如 `+Loading.swift`）。
- 大型适配器（如 LLaMA）可拆分为多个内部类文件，但统一放在同一目录。

---

## 5. 开发路线图

### 阶段 0：基础清理
- 删除所有 CPU 占位实现。
- 创建新的 `Models/` 目录，包含所有纯数据模型（已验证无污染）。
- 确立新架构原则。

### 阶段 1：核心基础设施
1. **硬件抽象**：实现 `HardwareProfile` 和 `MLXConfiguration`。
2. **协议定义**：完成 `ModelAdapter`、`TextGenerationService` 等协议。
3. **SafetensorsLoader**：实现从文件加载 `[String: MLXArray]`（使用 MLX）。
4. **BPETokenizer**：重构为纯 `Sendable` 结构体，使用 `String` 键替换 `MergePair`。

### 阶段 2：Actors 实现
1. **ModelLoadingActor**：实现配置解析、权重加载、适配器缓存。
2. **InferenceCoordinatorActor**：实现任务排队、内存跟踪、流式返回。

### 阶段 3：MLX 适配器（以 LLaMA 为第一个）
1. **LLaMAConfiguration**：从 `ModelConfig` 提取超参数。
2. **内部类定义**：`LLaMAAttention`、`LLaMAMLP`、`LLaMADecoderLayer`、`LLaMAModel`，全部遵循 `@unchecked Sendable`。
3. **LLaMAAdapter**：实现 `loadWeights`（调用 `update(parameters:)`）和流式生成方法（返回 `AsyncStream<String>`，含取消检查）。
4. **LLaMATextGenerationService**：包装适配器，实现 `TextGenerationService`。

### 阶段 4：ViewModel 与 UI
1. **MainViewModel**：实现模型选择、加载、生成等逻辑，严格遵循 `@MainActor`。
2. **视图**：基于现有视图调整，确保只依赖 ViewModel。
3. **App 入口**：初始化 Actors 和 ViewModel，注入依赖。

### 阶段 5：测试与优化
- 编写单元测试验证各模块并发安全。
- 使用 Thread Sanitizer 检测数据竞争。
- 集成一个真实小模型（如 TinyLlama）测试完整流程。

---

## 6. 可扩展性设计

- **新模型添加**：只需新建一个遵循 `ModelAdapter` 的类，并在 `ModelAdapterFactory` 中注册。核心代码无需改动。
- **新模态支持**：定义新的服务协议（如 `ImageGenerationService`），并在 `InferenceCoordinator` 中添加对应 case。
- **AI 助手集成**：可视为外部 MCP 客户端，通过标准协议与核心引擎交互，不影响现有架构。
- **量化与微调**：在适配器内部实现，或通过 MLX 提供的 `QuantizedLinear` 等模块动态替换。

---

## 7. 已知风险与缓解措施

- **MLXNN 模块的 `Sendable` 问题**：虽然 MLXNN 类型未标记 `Sendable`，但它们在初始化后只读，使用 `@unchecked Sendable` 是安全的。后续若 MLX 官方更新，可移除该标记。
- **Swift 6 严格并发变化**：当前设计完全遵循 Swift 6 规则，但若未来规则收紧，只需微调少量标记。
- **内存泄露**：在 `InferenceCoordinatorActor` 中通过 `defer` 确保内存释放；KV 缓存需在任务取消时及时释放（由 MLX 自动管理）。

---

## 8. 附录：文件与目录结构（建议）

```
second_try/
├── Actors/
│   ├── ModelLoadingActor.swift
│   └── InferenceCoordinatorActor.swift
├── Hardware/
│   ├── HardwareProfile.swift
│   └── MLXConfiguration.swift
├── ModelAdaptation/
│   ├── Protocols/
│   │   ├── ModelAdapter.swift
│   │   └── VisionAddOn.swift
│   ├── Common/
│   │   ├── SafetensorsLoader.swift
│   │   ├── BPETokenizer.swift
│   │   └── Sampling/ (future)
│   ├── Factory/
│   │   └── ModelAdapterFactory.swift
│   └── TextModels/
│       └── LLaMAAdapter.swift
├── Models/
│   ├── ModelConfig.swift
│   ├── LoadedTensor.swift
│   ├── GenerateParameters.swift
│   ├── ImageGenerationParameters.swift
│   ├── InferenceTask.swift
│   ├── ModelCapability.swift
│   └── ModelInfo.swift
├── Services/
│   ├── TextGenerationService.swift
│   └── LLaMATextGenerationService.swift
├── ViewModels/
│   └── MainViewModel.swift
├── Presentation/
│   ├── MainView.swift
│   ├── GenerationView.swift
│   └── ModelBrowserView.swift
├── Utils/
│   └── (日志、扩展等)
└── Resources/