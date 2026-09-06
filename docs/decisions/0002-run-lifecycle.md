# ADR 0002：执行所有权、取消与预算

日期：2026-09-06。状态：已实现最小运行时。

## 状态和所有权

`queued → preparing → running → releasing → completed/failed/cancelled`。

活动取消变为`cancelling`，执行许可保持到后端execute真正结束、release完成。actor在await时可重入，必须用显式activeRunID维持完整任务独占。

每次提交拥有独立内部token。公开request UUID可在结束后复用，但旧句柄或旧流迟到取消不能影响新提交。

后端 release 返回后，在一个不含 await 的 actor 区段内清除旧 entry、activeRunID、worker、phase 和预算，再跨 actor 发布 outcome。这样同 UUID 的新提交不会与旧活动许可混淆。发布终态后的恢复路径不得再清理共享活动状态，因为重入提交可能已启动下一任务；只按原有 FIFO 队列调用 startNextIfIdle。

后端实例属于一个runtime，不可直接交给多个runtime重复调度。模型对象、KV cache、懒计算图与内部生成Task由后端独占。只有Sendable值/引用标识跨公共边界。

## 合约

- `estimate`不加载权重，不开始推理；声明包含权重、缓存、工作区的峰值估计。
- `execute`要传播取消与emit错误，返回前等待自己创建的全部工作和GPU操作结束；不许返回后继续emit。
- `release`要幂等，覆盖部分加载、错误和取消，不因当前Task已取消而跳过清理。第一版每次释放，不暗中保留未计入预算的驻留模型。
- `InferenceRun.events`为单消费者有界流。缓冲满明确失败，不默默丢失文本。当前策略为fail-fast，未来可比较背压或累计快照；事件条数限制不是所有进程内存的硬限制。
- `outcome()`是最终状态的权威来源，只在cleanup后完成；等待结果不会自动消费事件。调用者要持续消费events，或显式cancel；丢弃/保留句柄本身不是自动取消协议。
- `cancelAllAndWait`取消调用时的全部批次；`shutdown`先永久关闭admission，再等待取消/清理完成。非合作后端可拖延shutdown，本进程框架不伪装能强制终止GPU内核。

## 预算边界

超出声明预算的任务不执行；运行时只保留一个活动任务的预算。未知/零估计拒绝。此规则不是OOM保证：估计偏差、系统内存压力、MLX缓存和原应用绕过新runtime的任务均未被自动管控。

## 验证

确定性actor gate测试覆盖排队、取消drain、清理、异常、预算与缓冲行为。具体清单和结果见Tests/DRuntimeTests及同级D-Development/Logs/foundation-tests.log。MLX集成必须单测取消时延和真实内存；2.30.6的ChatSession内部取消差异已记录，不在本轮静默升级。
