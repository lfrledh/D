# 来源与主张记录

访问日期均为2026-09-06。未标注出版日期的文档不推测其更新时间。工程建议与源码事实分开。

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
