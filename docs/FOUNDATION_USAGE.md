# 新推理框架的使用边界

根Package.swift可直接在Xcode作为Swift package打开。测试不需要模型权重或网络。默认scratch为外盘同级 `BuildCaches/D-Foundation`（可通过 `D_FOUNDATION_BUILD_ROOT` 覆盖），日志在 `D-Development/Logs`。这个独立名称避开当前Swift工具链把D与D-Development路径前缀混淆而产生的调试符号缓存警告：

```sh
./scripts/test-foundation.sh
```

宿主注入符合InferenceBackend的真实实现后，可以：

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
```

`backend`、`request`、`budget`、`consume`由宿主提供；此代码说明调用方式，不是一个已配置模型的独立示例程序。

- `run.cancel()`请求停止，`run.outcome()`等待底层execute和release结束。
- `runtime.snapshot()`读取活动任务、队列和预算；目前不提供持久任务历史或事件广播。
- `runtime.cancelAllAndWait()`取消当前批次；`runtime.shutdown()`永久停止接收任务并等待退出。
- events单消费者；持续消费或显式cancel。缓冲条数限制不是字节级内存限制。溢出明确失败，不能只等outcome而忽略大量输出。
- 模型下载、目录授权、输入资产生命周期由宿主保证。后端只能访问宿主已解析且已授权的资源。
- 后端estimate不得开始真实加载；release须幂等并在取消状态下完成；execute不得返回后遗留生成任务或继续emit。
- 预算是后端声明的峰值准入限制，尚未连接MLX allocator，也不是跨进程或对旧应用的全局OOM防护。
- 新框架不依赖、也未接入旧Packages/*。真实MLX后端是下一条需要模型验证的迁移切片。
