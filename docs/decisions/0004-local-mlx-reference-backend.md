# ADR 0004：可测量的本地 MLX 文本后端

日期：2026-09-06。状态：已实现；CLI 实测通过，MLX XCTest 执行待系统授权。见 [检查点与剩余验收](../MLX_CHECKPOINT_2026-09-06.zh-CN.md)。

## 构建边界

根 DPlatform 保持零远程依赖、无需 Metal 的 DInference/DRuntime 测试。新增同仓 Backends/MLX 集成 package，包含 DMLXBackend、薄命令行入口和真实模型测试。它通过本地路径依赖 DPlatform；不是独立 Git 仓库或独立发布服务。

分离 package 是为了让 SwiftPM 解析依赖和 Xcode Metal 资源构建不成为纯调度测试的前置条件。两个 package 都有实际使用者，不创建其他预留包。旧 Packages/* 的 Swift manifest 暂时保留，旧 UI 尚未接入新 runtime。

锁定 MLX 0.30.6、mlx-swift-lm 2.30.6、swift-transformers 1.1.8；集成 package 有自己的 Package.resolved。使用 Xcode 编译 Metal 资源，CLI 与资源 bundle 一起保存在外盘。

真实 maxTokens=1/32 实验发现 LM 2.30.6 将正常长度终止标为 cancelled。源码 generateLoopTask 的 for-in 迭代 TokenIterator 值副本，随后检查原值的 tokenCount。适配层在父任务和生成任务均未取消、实际 token 数恰好达到请求上限时，将该原因规范化为 length，并在元数据保留 upstreamStopReason。真实取消优先，不把未达到上限的意外终止转换为成功。此兼容逻辑有回归测试；未来升级依赖时复核并删除已无必要的修正。

## 所有权与清理

每个 backend 实例归一个 runtime。runtime 的许可覆盖 estimate、execute、drain、release；MLX 后端还持有进程内许可，协调本实现的多个实例对全局分配器和默认流的访问。并发实例不排第二套队列，直接报告明确错误。

这个许可不能自动约束旧 UI 或任意第三方直接使用 MLX 的代码。因此本轮在独立命令行进程验证；未来接入应用时必须统一重推理入口，不能让旧推理与新后端同时操作资源并误称已统一调度。

只使用默认 CPU/GPU 流；不引入自定义 TaskLocal stream。ModelContainer.perform 包含输入准备、TokenIterator、生成流消费及任务等待；MLXArray 和模型对象不穿过公共契约。

持有 generateTask 返回的 Task；父任务取消同步转发，emit 抛错也取消生成。所有路径等待生成 task 完成，并同步流之后 execute 才返回。release 丢弃模型、同步、清空闲置缓存、恢复此前 cacheLimit，最后归还进程许可。部分加载失败即使 container 尚未赋值也必须 drain/release。

生命周期 observer 只用于记录诊断，不应驱动或等待新的 backend 生命周期操作；runtime 串行调用所有生命周期方法。额外的 releasing 状态阻止偶发重复 cleanup 在 observer 的 await 期间清除另一轮许可。

## 输入与内存

加载只接受已授权的本地目录。ModelConfiguration(directory:) 使用上游的本地权重与 tokenizer 路径；下载、版本选择和文件校验由外层固定 fixture 下载器负责。

当前接受 qwen2 架构；量化配置限定 flat affine 4-bit/group_size 64。拒绝已知会令上游断言、除零或不支持的维度/量化配置。并不据此承诺任何损坏的权重文件都能在进程内安全恢复；当前验收使用固定版本并校验过的模型文件。

加载前读取文件大小与配置，预算包含权重瞬时副本、f32 KV 估计、工作区和缓存。该预算是准入估算，不是硬 OOM 防护；不把 Memory.memoryLimit 描述成可靠的系统内存上限。

默认上下文上限 2048 prompt tokens、1024 output tokens；在 tokenization 后再次验证总上下文长度。同步 prefill 和权重加载不能即时中断，取消完成以底层结束为准。报告记录实际延迟，不承诺瞬时停止。

## 验收与复现

fixture 固定 Hugging Face revision 与每个文件的大小/摘要，权重不入库；下载器的 --verify-only 不访问网络。命令行报告记录请求、revision、实际文本、终态、生命周期及 MLX 分配器数据，报告原子写入。

fixture 校验还拒绝未列入清单的权重、目录和元数据，避免上游递归权重发现加载额外文件却仍被标记为固定版本。CLI 验收在启动用例前执行完整 fixture 校验。

每轮约 2720 bytes 的 MLX 活跃分配增长已在不依赖 D、只调用上游 loadContainer 的程序中复现。最小数组赋值对照与上游引用环问题吻合；保留锁定依赖和独立 probe，不修改 SwiftPM 外部 checkout。此限制尚未修复，不能声明长期内存稳定，见 [调查记录](../research/MLX_ALLOCATION_FINDINGS.zh-CN.md)。

真实测试必须显式提供模型路径；复验脚本先验证 fixture，再向 xctestrun 注入环境变量，检查真实执行证据。无模型时的 skipped suite 不能被记作通过。测试覆盖正常输出、token 上限、取消和队列交接、连续运行、部分加载失败及消费者错误后的恢复。

这是推理基础的参考实现，不包含模型商店、图像生成迁移、应用 UI 集成或自动模型路由。之后以同样的契约和验收方式推进图像后端。
