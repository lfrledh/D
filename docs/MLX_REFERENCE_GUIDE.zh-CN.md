# 本地 MLX 参考实现

源码：Backends/MLX。它通过根 DInference/DRuntime 接口执行本地文本推理，使用 Swift 6；旧应用 UI 暂未使用这条链路。设计依据见 [ADR 0004](decisions/0004-local-mlx-reference-backend.md)。

## 当前验证状态（2026-09-06）

固定 fixture 已下载到外盘并校验，CLI 的 10 类进程验收全部通过，完整结果在项目同级 `D-Development/Logs/cli-acceptance/summary.json`。检查包含正常 token 上限、同进程五轮加载/生成/释放、指定片段取消、SIGINT/SIGTERM 取消和停止后续重复、断管后的报告保存，以及无效参数、模型路径与预算拒绝。

MLX XCTest 已实际执行通过：25 项声明、37 个参数展开场景，0 失败、0 跳过。真实 suite 的 7 个用例包含生成、严格 token 上限、加载后取消、取消与队列交接、连续释放、部分加载失败恢复及消费者异常。此前外盘访问授权造成的启动阻塞未在此次运行中重现。纯框架的 17 项测试、旧应用构建与真实模型测试分别保留验证证据。

原版每轮 2720 字节的增长已通过回移 MLX 数组所有权修复解决。C++ 7 组/36 项检查通过，50 轮真实加载/生成/释放后的 `activeBytes` 和 `cacheBytes` 均为 0。见 [修复报告](MLX_OWNERSHIP_FIX.zh-CN.md) 与 [原始调查](research/MLX_ALLOCATION_FINDINGS.zh-CN.md)。这不替代完整 XCTest，也不是所有模型、长期运行或整个进程无泄漏的证明。

## 环境与构建

Apple Silicon Mac、Xcode 与 Python 3；本机为 M4 / 16 GiB。打开根目录 D.xcworkspace。MLX 使用同仓 Vendor/mlx-swift 固定源码，其他远程依赖由解析锁文件固定，首次解析仍需要网络。两个构建入口都把 vendor 注册为 workspace 根包，确保统一覆盖远程间接依赖。纯 runtime 测试仍可独立执行，不依赖 MLX 或模型。

在项目根目录运行：

```sh
./scripts/test-foundation.sh
./scripts/build-mlx.sh
python3 scripts/download-test-model.py
```

构建脚本只在 stdout 输出 d-infer 的绝对路径，日志在项目同级 D-Development/Logs/build-mlx.log。依赖检出缓存为 D-Development/SourcePackages-MLX，与旧应用的 SourcePackages-App 分开。默认构建目录是同级 BuildCaches/D-MLX；可用 D_MLX_BUILD_ROOT 覆盖。必须保留 Xcode 生成的产品目录与 MLX 资源 bundle；不能只复制单个二进制后假设 Metal 资源仍可找到。

模型默认下载到同级 D-Development/Models/Qwen2.5-0.5B-Instruct-4bit，共约 276 MiB。清单 fixtures/text-model.json 固定 revision、大小和摘要，脚本不执行远程模型代码。已有文件只有校验通过才跳过；下载后原子替换完整文件。可用 --destination 指定另一个仓库外目录。

## 命令行运行

本机示例：

```sh
/Volumes/CodexProjects/Codex/BuildCaches/D-MLX/Build/Products/Debug/d-infer \
  --model /Volumes/CodexProjects/Codex/D-Development/Models/Qwen2.5-0.5B-Instruct-4bit \
  --revision a5339a4131f135d0fdc6a5c8b5bbed2753bbe0f3 \
  --prompt 'What is 2 + 2? Answer in one short sentence.' \
  --temperature 0 --max-tokens 32 \
  --report /Volumes/CodexProjects/Codex/D-Development/Logs/text-run.json
```

--help 不初始化后端。文本写 stdout，状态写 stderr，--report 原子写 JSON，包含实际输出、请求参数、权威终态、首片段与取消耗时、各阶段 MLX 内存快照。revision 是调用者提供的来源标签；文件校验由下载/验证脚本执行，不把字符串标签当作完整性证明。

--repeat 5 在同一进程重复加载和释放；--cancel-after-chunks 1 在第一个文本片段后请求取消。Ctrl-C 或 SIGTERM 取消当前任务并停止之后的重复，等待 drain 和报告保存。stdout 管道断开也通过正常清理路径退出。

退出码：0 成功；1 执行、输出或报告保存失败；2 参数错误；130 取消。取消是可验收的正常生命周期，但命令行按惯例返回非零。报告中的 outcome 保留 runtime 的实际结果；输出管道故障另记 outputError。

## 可重复验收

```sh
python3 scripts/verify-mlx-vendor.py
python3 scripts/download-test-model.py --verify-only
./scripts/test-mlx-ownership.sh
./scripts/test-mlx.sh
python3 scripts/verify-mlx-cli.py
```

test-mlx.sh 先验证依赖源码和全部模型文件，再使用 DMLXTests scheme build-for-testing，明确检查测试清单包含 DMLXBackendTests，并把模型目录注入测试进程。日志在 D-Development/Logs/mlx-tests.log，结构化 Xcode 结果保存在该目录的 MLXTests-*.xcresult。执行结束后，脚本还会检查真实取消和连续运行证据；缺少模型、启动超时或只有测试构建成功都不会变成“通过”。可把其他位置的同一固定 fixture 路径作为脚本第一个参数。

首次在外置磁盘运行 Xcode 测试时，macOS 可能要求 Xcode/xctest 访问“可移除宗卷”。需要在系统提示中允许；测试进程可能在加载 bundle 前等待授权，这不表示推理已经执行。

CLI 验证器覆盖帮助、参数错误、无效模型目录、预算拒绝、真实 token 上限、连续运行、自动取消、SIGINT/SIGTERM、管道断开及报告保存。结果在 D-Development/Logs/cli-acceptance，支持 --binary、--model、--reports 指定位置；每个子进程都有超时与回收处理。summary.json 的 complete 和 passed 都为 true 才表示整组完成并通过；帮助路径不会生成执行报告。

模型权重与缓存、完整日志、xcresult、测试临时目录都在仓库外。验收后提交精简的结果记录；不提交大体积生成产物。

## 解释指标与限制

- 当前真实基准使用固定的 Qwen2.5-0.5B-Instruct-4bit；不代表其他 Qwen2 权重或其他架构已验收。支持的量化参数有明确限制，后续扩展必须增加真实证据。
- 默认最多 2048 个输入 token、1024 个输出 token；实际还受模型上下文限制。加载与同步 prefill 不能被强制瞬间中断。
- activeBytes/cacheBytes/peakBytes 是进程内 MLX allocator 数据，不等于系统 RSS。单次剩余分配不能直接证明泄漏，也不能自动归因于无害的全局缓存；需要检查随运行次数的变化并定位来源。
- CLI 与真实测试的五轮检查允许释放后活跃分配相对首轮最多增加 1024 bytes，能检测原 2720 bytes/轮的回归；C++ weak_ptr 测试直接验证释放语义。短轮次数值检查不能替代长期运行和其他模型验证。
- memory-budget-mib 是加载前估计准入，包含权重、KV、工作区与缓存，不是硬 OOM 限制。
- 本实现按次释放模型，以验证清晰的生命周期；没有常驻模型复用优化。避免在旧 UI 推理同时运行时接入同进程新后端，直到资源入口统一。
- CLI 成功不证明旧应用的下载书签、图像生成、项目保存或界面体验已经完成。
