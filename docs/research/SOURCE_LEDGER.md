# 来源与主张记录

首轮访问日期为2026-09-06；后续研究另列日期。未标注出版日期的文档不推测其更新时间。工程建议与源码事实分开。

| 来源/发布方 | 日期/版本 | 支持的主张 | URL与访问说明 |
| --- | --- | --- | --- |
| SwiftPM Package / Swift项目 | 页面未注明；当前文档 | 一个package含多个target；target编译为module | https://docs.swift.org/package-manager/PackageDescription/PackageDescription.html ，已打开 |
| Swift并发迁移指南 / Swift项目 | 当前文档 | 数据隔离、Sendable、渐进迁移 | https://www.swift.org/migration/ ，研究代理读取 |
| ChatSession / Apple MLX团队 | 锁定7e19e090（LM2.30.6，2026-02-18） | session不得并发使用；外层流取消与内部生成等待 | 本地D-Development/SourcePackages/checkouts/mlx-swift-lm/Libraries/MLXLMCommon/ChatSession.swift:19,319；主执行者复核 |
| ChatSession / Apple MLX团队 | e3d4a20e，2026-09-03 main | 单session所有权要求；显式取消内部generation任务 | https://github.com/ml-explore/mlx-swift-lm/blob/e3d4a20e9e20e7b8ab39aded7bbfad4ae22c9438/Libraries/MLXLMCommon/ChatSession.swift#L145 ，主执行者再次打开；不是D当前依赖 |
| ModelContainer / Apple MLX团队 | LM2.30.6锁定本地源码 | 非Sendable MLXArray；SerialAccessContainer；独立session可并行的条件 | Libraries/MLXLMCommon/ModelContainer.swift:34,85,167；Utilities/SerialAccessContainer.swift:39，代理逐段读取 |
| ComfyUI datatypes / Comfy Org | 当前文档 | IMAGE/LATENT/MASK/AUDIO与采样参数具有不同语义 | https://docs.comfy.org/custom-nodes/backend/datatypes ，主执行者复核 |
| ComfyUI节点概览 / Comfy Org | 当前文档 | 服务与界面分离、无界面workflow调用 | https://docs.comfy.org/custom-nodes/overview ，代理读取 |
| ComfyUI routes / Comfy Org | 当前文档 | 验证、排队、事件、中断、模型释放 | https://docs.comfy.org/development/comfyui-server/comms_routes ，代理读取 |
| ComfyUI execution / Comfy Org | 15eb748b，2026-09-06 | workflow执行器与缓存；模型资源管理 | https://github.com/Comfy-Org/ComfyUI/blob/15eb748b3ec5f8a0a2d470b7fb280e2d7579f916/execution.py#L664 ，代理固定commit读取 |
| ComfyUI model management / Comfy Org | 同上 | 权重/推理空间/预留/释放 | https://github.com/Comfy-Org/ComfyUI/blob/15eb748b3ec5f8a0a2d470b7fb280e2d7579f916/comfy/model_management.py#L913 ，代理读取 |
| Diffusers loading / Hugging Face | 当前文档 | task pipeline组合编码器、denoiser、VAE、scheduler | https://huggingface.co/docs/diffusers/using-diffusers/loading ，主执行者复核 |
| Diffusers callbacks / Hugging Face | main文档，非锁定稳定API | step回调、中断、预览 | https://huggingface.co/docs/diffusers/main/en/using-diffusers/callback ，代理读取 |
| Modular Diffusers / Hugging Face | main文档 | blocks与组件复用 | https://huggingface.co/docs/diffusers/main/en/modular_diffusers/overview ，代理读取；仅借鉴概念 |
| Diffusers reproducibility / Hugging Face | 当前文档 | RNG状态、跨平台/版本复现限制 | https://huggingface.co/docs/diffusers/using-diffusers/reusing_seeds ，代理读取 |
| llama.cpp server架构 / ggml-org | 9e0e2205，2026-09-06 | 推理context、队列、slot、原生类型与外部表示分离 | https://github.com/ggml-org/llama.cpp/blob/9e0e220594af405a62835dc3a27495729fd8506b/tools/server/README-dev.md#L39 ，主执行者复核 |
| Safetensors / Hugging Face | 当前文档 | 张量文件格式不包含任意模型完整执行定义 | https://huggingface.co/docs/safetensors/index ，主执行者复核 |

本次不复制上游实现。研究记录中核对了ComfyUI GPL-3.0、Diffusers Apache-2.0、llama.cpp MIT的固定提交LICENSE；未形成发布许可或法律结论。

## 2026-09-07：信息架构与服务演进

| 来源 | 核对的行为／用于决策的事实 | 访问与适用范围 |
| --- | --- | --- |
| [Photoshop 工作区](https://helpx.adobe.com/photoshop/desktop/get-started/learn-the-basics/workspace-overview.html) | 文档窗口、工具选项与上下文任务栏分工 | 已打开；用于对象与工具呈现分离，不是布局复制 |
| [DaVinci Resolve](https://www.blackmagicdesign.com/products/davinciresolve) | 按任务提供专门工作区，素材组织与输出有自己的工具 | 已打开；产品分类行为，不采纳营销性能主张 |
| [Blender 工作区](https://docs.blender.org/manual/en/latest/interface/window_system/workspaces.html) | 同一项目切换由编辑器／布局组成的工作区 | 官方搜索正文可读；页面直接抓取失败，未臆测额外内容 |
| [ComfyUI 子图](https://docs.comfy.org/interface/features/subgraph) | 封装多个节点并暴露输入输出 | 已打开；支持逐步呈现复杂能力，不保证任意图的简单模式转换 |
| [NN/g 渐进展示](https://www.nngroup.com/articles/progressive-disclosure/) | 次要功能按需展开 | 官方研究摘要；用作减少首次操作负担的参考 |
| [Apple Liquid Glass](https://developer.apple.com/videos/play/wwdc2025/219/) | 材质用于浮于内容之上的导航／控制 | 官方视频文字摘要；不等于所有容器都应透明 |
| [VS Code 语言服务](https://code.visualstudio.com/api/language-extensions/language-server-extension-guide) | 编辑器与计算服务可经协议分离 | 已核对官方摘要；借鉴接口边界，D 暂不引入 RPC |
| [ComfyUI 服务路由](https://docs.comfy.org/development/comfyui-server/comms_routes) | 提交先校验入队，状态事件与结果可分别读取 | 已打开；不照搬全部服务端接口 |
| [fal 异步推理](https://fal.ai/docs/documentation/model-apis/inference/queue) | 运行中取消不保证停止，远程结果 URL 有保留期限 | 已打开并核对取消／结果段落；为远期提供方声明语义保留边界 |
| [Apple URLSessionDownloadTask](https://developer.apple.com/documentation/foundation/urlsessiondownloadtask) | 默认下载写临时文件，恢复能力有条件 | 官方摘要；D 为明确将大文件片段写外盘，采用有界 URLSession 流式 Range 接收，不直接依赖系统临时文件位置 |

设计结论与用户确认保存在 ADR 0007／0008。当前实现状态在目标清单和行动指南；本表不宣称远程 API、节点或多文档已实现。

### 模型库窗口生命周期补充（2026-09-07）

- [Apple：SwiftUI Window](https://developer.apple.com/documentation/swiftui/window)：单主窗口关闭时默认退出应用；实机已复现下载因此进入退出暂停流程。D 的应用委托显式保留无窗口运行，安装归应用所有，随后通过 UI 回归和真实下载检查。
- [Apple：applicationShouldTerminateAfterLastWindowClosed](https://developer.apple.com/documentation/appkit/nsapplicationdelegate/applicationshouldterminateafterlastwindowclosed(_:))：应用委托决定最后窗口关闭是否触发退出。
