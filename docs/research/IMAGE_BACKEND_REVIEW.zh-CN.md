# 旧图像后端审阅与替换依据

本清单依据旧应用调用链及锁定依赖的源码，区分确定的接口错误与需要实测的资源风险。它不是旧图像生成的运行验收报告；本次没有执行旧图像模型或旧图像测试。

上游对照版本为 `ml-explore/mlx-swift-examples@c6844888f4ace8ffb6029f4fbfa317339e420eab`，与应用锁文件及 `D-Development/SourcePackages-App/checkouts/mlx-swift-examples` 一致。以下上游链接固定到该提交；本仓库链接指向外置 SSD 中的实际源码。

## 已存在的真实调用路径

- [DApp.AppDependencies](/Volumes/CodexProjects/Codex/D/D/DApp.swift:51) 按模型 ID 字符串选择 `SD3Service` 或 `StableDiffusionService`，并注入 `ModelLoadingActor`。
- [ImageCapabilityViewModel.loadSelectedModel](/Volumes/CodexProjects/Codex/D/Packages/UI/Sources/UI/ImageCapabilityViewModel.swift:50) 把所选目录交给加载层；[generate](/Volumes/CodexProjects/Codex/D/Packages/UI/Sources/UI/ImageCapabilityViewModel.swift:76) 消费 `AsyncStream<Data>`，将 PNG 转成 `NSImage` 加入历史列表。
- [StableDiffusionService.ensureLoaded](/Volumes/CodexProjects/Codex/D/Packages/ImageInference/Sources/ImageInference/StableDiffusionService.swift:49) 仅识别 `stabilityai/sdxl-turbo` 和 `stabilityai/stable-diffusion-2-1-base`；通过上游 `StableDiffusion` 创建生成器。
- [performGeneration](/Volumes/CodexProjects/Codex/D/Packages/ImageInference/Sources/ImageInference/StableDiffusionService.swift:86) 已连接参数、文本条件、去噪迭代、VAE 解码、像素转换和 PNG 编码。这是存在实际实现的旧文生图路径，但其中的确定缺陷尚未由本次运行验证修复。
- `Packages/ImageInference` 中还有自有 SD3 Transformer、CLIP/T5、VAE 与调度器组件。这些类的存在不代表已经组成可运行的 SD3 管线。

## 源码可以确定的问题

### 1. 解码前错误移除 batch 维度

[StableDiffusionService.swift:129](/Volumes/CodexProjects/Codex/D/Packages/ImageInference/Sources/ImageInference/StableDiffusionService.swift:129) 调用 `decoder(finalXt[0])`。上游 [generateLatents:331](https://github.com/ml-explore/mlx-swift-examples/blob/c6844888f4ace8ffb6029f4fbfa317339e420eab/Libraries/StableDiffusion/StableDiffusion.swift#L331) 构造 `[batch, height, width, channels]`，而 VAE 的 [Attention.callAsFunction:28](https://github.com/ml-explore/mlx-swift-examples/blob/c6844888f4ace8ffb6029f4fbfa317339e420eab/Libraries/StableDiffusion/VAE.swift#L28) 明确读取 `shape4`。

因此这里把 VAE 所需的四维输入提前变成三维，违反解码契约。应保留 batch 完成解码，再选择单图交给只接受三维的 [Image.init:29](https://github.com/ml-explore/mlx-swift-examples/blob/c6844888f4ace8ffb6029f4fbfa317339e420eab/Libraries/StableDiffusion/Image.swift#L29)。具体首先在哪个算子报错尚未实测，不能把此条写成已捕获的崩溃日志。

### 2. 重复进行颜色范围变换

上游 [detachedDecoder:284](https://github.com/ml-explore/mlx-swift-examples/blob/c6844888f4ace8ffb6029f4fbfa317339e420eab/Libraries/StableDiffusion/StableDiffusion.swift#L284) 已执行 `clip(x / 2 + 0.5, 0, 1)`；[本地服务:131](/Volumes/CodexProjects/Codex/D/Packages/ImageInference/Sources/ImageInference/StableDiffusionService.swift:131) 又执行一次。

即使先修好维度问题，第二次变换仍会把合法的 `[0,1]` 压到 `[0.5,1]`，改变亮度与对比度。正确范围转换只能发生一次。这是计算上确定的错误，不是本次观察到的真实成图外观。

### 3. 取消只有 UI 消费端，没有生成任务的所有权

[generate:78](/Volumes/CodexProjects/Codex/D/Packages/ImageInference/Sources/ImageInference/StableDiffusionService.swift:78) 创建 `Task.detached` 后丢弃 handle；流没有 `onTermination`，去噪循环也没有取消检查。[ImageCapabilityViewModel.cancel:110](/Volumes/CodexProjects/Codex/D/Packages/UI/Sources/UI/ImageCapabilityViewModel.swift:110) 只取消消费流的任务并立即复位 UI。

取消消费者不会自动取消这个 detached 生产者，因此 UI 显示可再次生成时，旧生产任务仍可能计算。现有接口没有“请求取消 → 停止提交新计算 → drain → 确认终态”的机制。上游 `ModelContainer` 的同步闭包能串行访问同一实例，但不能替代跨服务实例的执行许可或任务所有权。

### 4. 所选本地目录没有成为实际加载来源

[ModelLoadingActor.loadImageModel:41](/Volumes/CodexProjects/Codex/D/Packages/ModelLoading/Sources/ModelLoading/ModelLoadingActor.swift:41) 仅从目录名 `models--org--model` 还原模型 ID，再把 ID 传给工厂；原始 URL 没有传到图像服务。[ensureLoaded:63](/Volumes/CodexProjects/Codex/D/Packages/ImageInference/Sources/ImageInference/StableDiffusionService.swift:63) 随后使用新建的 `HubApi` 下载预设模型，上游 [resolve:376](https://github.com/ml-explore/mlx-swift-examples/blob/c6844888f4ace8ffb6029f4fbfa317339e420eab/Libraries/StableDiffusion/Load.swift#L376) 也从 Hub 缓存位置取文件。

所以“选择这个目录”并不保证“从这个目录加载”；任意本地 snapshot 名称还会被目录名解析拒绝。是否恰好命中同一缓存由环境决定，不能笼统说每次都会重复下载。替换接口需要传递经过验证的本地模型引用，并把下载与推理分开。

### 5. 卸载没有停止、等待和释放的可观察边界

[ImageGenerationService](/Volumes/CodexProjects/Codex/D/Packages/Core/Sources/Core/Services/Protocols/ImageGenerationService.swift:3) 只有 `generate`。[ModelLoadingActor.unloadModel:172](/Volumes/CodexProjects/Codex/D/Packages/ModelLoading/Sources/ModelLoading/ModelLoadingActor.swift:172) 仅删除缓存字典条目；[UI 卸载:69](/Volumes/CodexProjects/Codex/D/Packages/UI/Sources/UI/ImageCapabilityViewModel.swift:69) 也只移除服务引用，没有先取消并等待生成。

活动 detached 任务仍可持有服务，服务持有 `container`。这里可以确定的是缺少可等待的释放协议，不能据此宣称所有闲置模型永远泄漏；最后一个引用消失后仍可能正常析构。需要验证的是任务终止、GPU/CPU drain 和资源释放之后，运行时才允许下一任务取得许可。

### 6. 错误被当作无内容的正常结束

[performGeneration.catch:152](/Volumes/CodexProjects/Codex/D/Packages/ImageInference/Sources/ImageInference/StableDiffusionService.swift:152) 对所有可捕获错误只调用 `finish()`；接口本身是非 throwing 流。UI 只在收到空 `Data` 时设置失败，而该失败路径根本不发送空 `Data`。

因此不支持的模型、下载失败或可捕获的生成失败会丢失原因，也不能与成功但无产物区分。单一 `Data` 流还没有步骤进度、任务 ID、最终 seed、产物来源或明确终态；这些是接口缺口，不要求本阶段立即加入编辑器功能。

## 尚待验证的资源与并发风险

- [performTwoStage 调用:110](/Volumes/CodexProjects/Codex/D/Packages/ImageInference/Sources/ImageInference/StableDiffusionService.swift:110) 的注释不能作为已节省内存的证据：上游 [conserveMemory:135](https://github.com/ml-explore/mlx-swift-examples/blob/c6844888f4ace8ffb6029f4fbfa317339e420eab/Libraries/StableDiffusion/StableDiffusion.swift#L135) 默认为 `false`，本地未调用设置方法；传到第二阶段的 [DenoiseIterator.sd:18](https://github.com/ml-explore/mlx-swift-examples/blob/c6844888f4ace8ffb6029f4fbfa317339e420eab/Libraries/StableDiffusion/StableDiffusion.swift#L18) 还强持有生成器。仅打开开关也不等于该调用结构立即释放全部模型。
- `ensureLoaded` 在检查 `container == nil` 后等待网络；actor 可在此期间重入，多个请求可能重复创建容器。不同服务实例还没有共用 MLX 执行许可。是否实际出现竞态或峰值抬升，需要受控重叠请求验证。
- 宽高直接除以 8，步数、尺寸、分辨率上限和模型特定约束缺少服务层校验。结果可能包括截断尺寸、底层拒绝或过大工作区；具体输入与行为需要列入后续受控验收。
- 没有旧路径的分阶段峰值、取消后占用、反复加载/卸载趋势证据。16 GiB 是否足够不能从权重大小推断，也不能由文本后端验收代替。
- [ImageInferenceTests.swift:4](/Volumes/CodexProjects/Codex/D/Packages/ImageInference/Tests/ImageInferenceTests/ImageInferenceTests.swift:4) 是无断言的模板测试，不证明成图正确、取消生效或无泄漏。本清单不声称这些旧测试已经执行。

## SD3 的实际边界

[SD3Service.performGeneration:58](/Volumes/CodexProjects/Codex/D/Packages/ImageInference/Sources/ImageInference/Diffusion/SD3/SD3Service.swift:58) 只结束空流，是 stub。虽然同文件存在加载 Transformer 的 `ensureLoaded`，生成入口没有调用它，也没有连接文本编码、采样和 VAE。因此应用工厂能返回 `SD3Service` 不等于 SD3 已受支持。

## B1 与下一阶段替换范围

B1 选择固定版本的现代候选 FLUX.2 Klein 4B q8，放在独立实验探针中，用固定本地 snapshot、固定参数和真实 PNG 检验数学路径与本机资源可行性。分阶段求值、释放及独立进程观测能为是否接入生产后端提供证据，避免先把未知负载接进旧 UI。tiny 数值对照不能替代完整候选模型在 16 GiB 上的硬件验收；完整结论以另行保存的真实硬件报告为准。

替换应沿用已有 `DInference → DRuntime → MLX 后端` 边界：固定本地模型引用，完整执行许可，可取消并等待 drain/release，结构化进度和错误，返回经过验证的产物引用。旧 UI 的提示词、参数和展示能力可复用，但服务适配必须遵守这些生命周期规则。此次审阅不增加架构包数，不宣称旧实现或候选模型已达到商品质量。
