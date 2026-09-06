# 新推理框架的使用边界

根 Package.swift 的 DInference/DRuntime 可直接在 Xcode 作为 Swift package 打开。它们保持零远程依赖；纯框架测试不需要模型权重或网络。默认 scratch 为外盘同级 `BuildCaches/D-Foundation`（可通过 `D_FOUNDATION_BUILD_ROOT` 覆盖），日志在 `D-Development/Logs`。这个独立名称避开当前 Swift 工具链把 D 与 D-Development 路径前缀混淆而产生的调试符号缓存警告：

```sh
./scripts/test-foundation.sh
```

真实实现已位于同仓 Backends/MLX，独立 CLI 通过以下公共契约调用后端。根包不直接依赖这个集成包，旧应用尚未迁移。宿主注入符合 InferenceBackend 的实现后，可以：

```swift
let configuration = try RuntimeConfiguration(memoryBudgetBytes: budget)
let runtime = try InferenceRuntime(backends: [backend], configuration: configuration)
let run = try await runtime.submit(request, backendID: backend.descriptor.id)

do {
    for try await output in run.events {
        // 将纯值或资产引用交给调用层；不要在这里接收裸模型对象。
        consume(output)
    }
} catch {
    // 错误/取消由下方权威终态统一处理。
}
let outcome = await run.outcome()
// 宿主退出时关闭准入并等待清理。
await runtime.shutdown()
```

`backend`、`request`、`budget`、`consume`由宿主提供；此代码说明调用方式，不是一个已配置模型的独立示例程序。

- `run.cancel()`请求停止，`run.outcome()`等待底层execute和release结束。
- `runtime.snapshot()`读取活动任务、队列和预算；目前不提供持久任务历史或事件广播。
- `runtime.cancelAllAndWait()`取消当前批次；`runtime.shutdown()`永久停止接收任务并等待退出。
- events单消费者；持续消费或显式cancel。缓冲条数限制不是字节级内存限制。溢出明确失败，不能只等outcome而忽略大量输出。
- 模型下载、目录授权、输入资产生命周期由宿主保证。后端只能访问宿主已解析且已授权的资源。
- 后端estimate不得开始真实加载；release须幂等并在取消状态下完成；execute不得返回后遗留生成任务或继续emit。
- 预算是后端声明的峰值准入限制。真实 MLX 后端另外设置缓存上限并记录 allocator 快照；这不把 runtime 预算变成分配器硬限制，也不是跨进程或对旧应用的全局 OOM 防护。
- 新框架不依赖旧 Packages/*，旧 UI 也尚未接入新 runtime；未来接入时必须统一重推理入口，避免旧后端绕过资源调度。

2026-09-06 的验证状态：16 项纯框架测试通过，固定模型的真实 CLI 10 类验收通过。原有重复加载分配增长已通过 MLX 所有权补丁修复，C++ 7 组回归通过，50 轮真实推理释放后的 MLX 活动分配与缓存均为 0，见 [修复记录](MLX_OWNERSHIP_FIX.zh-CN.md)。MLX XCTest 构建成功，但执行仍等待外盘权限问题解决后复验，因此 MLX 阶段仍待完整验收。构建命令、真实运行方法和具体限制见 [本地 MLX 参考实现](MLX_REFERENCE_GUIDE.zh-CN.md)。
