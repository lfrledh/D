# D 真实文本后端检查点

状态：实现与 CLI 验证已完成；完整 MLX XCTest 执行等待系统授权，尚未完成阶段验收。

## 已落实

- 六个 Git 子模块在 6457418 原样纳入主仓库，保留 Swift 边界、原始来源和外盘历史备份。普通 HTTPS clone 取得完整源码，16 项核心测试和旧应用 Debug 构建通过。
- 同仓 MLX 集成 package 接入 DInference/DRuntime，提供真实本地文本输出、模型准入估算、受控排队、拥有生成 Task 的取消路径、drain 后释放及生命周期记录。旧 UI 尚未迁移。
- CLI 支持结果流、参数校验、JSON 报告、重复运行、SIGINT/SIGTERM 取消与断管清理；测试和诊断程序各有明确入口。
- 固定模型文件清单及摘要。Qwen2.5-0.5B-Instruct-4bit revision `a5339a4131f135d0fdc6a5c8b5bbed2753bbe0f3`，10 文件，共 289599545 bytes；权重保存在外盘，不入 Git。

## 验证状态

| 验证链 | 实际结果 |
|---|---|
| 普通远程检出 | 六棵源码树匹配原提交，无 gitlink 或嵌套 Git；16 核心测试通过，旧应用构建通过 |
| 新 MLX 集成的独立检出构建 | 远程 9664d2f 的普通 clone 使用自己的 build-mlx.sh 构建成功；DPlatform 路径正确，d-infer 与 Metal 库均生成，锁文件和工作区保持干净 |
| 新 MLX 源码、CLI 和测试 bundle | Xcode `build-for-testing` 成功 |
| CLI 实际进程验收 | 10/10：帮助、非法参数、缺模型、预算拒绝、1-token 上限、连续五轮、首块取消、SIGINT、SIGTERM、断管 |
| MLX XCTest | 25 项声明、37 个参数展开场景已编译；尚未执行通过。首次启动在测试 bundle 加载前等待可移除宗卷授权并超时 |
| 独立分配探针 | 无 D 的数组对照和纯模型加载复现了上游活跃分配增长 |

XCTest 包含真实生成、严格 token 上限、加载后取消、取消与队列交接、五轮释放、部分加载失败和消费者错误恢复。已修正测试 trace：先记录输出尝试再交给 runtime，并检查 drained 之后的调用，避免 runtime 拒绝迟到输出却使测试漏报。编译这些断言不等于执行它们，CLI 也不能替代全部 XCTest 场景。

## 测量及限制

2026-09-06 本机 M4 / 16 GiB、macOS 26.6.2、Xcode 26.6、Swift 6.3.3，Debug arm64。11:28 UTC 的 CLI 复验中，32-token 五轮样本首块约 0.78–0.80 秒，MLX 峰值约 345 MB（十进制）；首块后发起的取消到终态约 20–23 ms。这些是短提示、此模型与本机的观测，不是大模型或长 prefill 的承诺。

五轮释放后的 cacheBytes 均为 0，activeBytes 为 2720、5440、8160、10880、13600。64 MiB 短时容差能发现整个模型遗留，不能证明没有小额持续增长。独立纯上游加载得到相同序列；证据、复验和上游修复状态见 [分配调查](research/MLX_ALLOCATION_FINDINGS.zh-CN.md)。

准入预算不是系统 OOM 硬限制。只支持经过验证的 qwen2 配置范围；默认限制 prompt/output token 数。同步权重加载和 prefill 只能协作取消。进程许可只协调新后端，不能约束旧 UI 或第三方直接操作 MLX。

## 尚需完成的验收

macOS 授予 Xcode/xctest 访问外盘后运行 `./scripts/test-mlx.sh`，确认真实 suite 已启用、各场景完成、没有挂起或测试失败，并保存 xcresult。此前 runner 已超时退出，没有将未执行或跳过的测试记为通过。

完成这条验证链后才能结束本阶段验收。后续商品化还需解决上述 MLX 分配问题，并扩展到长期运行、真实图像负载和应用集成；当前检查点没有声称完成这些工作。

复验命令见 [参考实现指南](MLX_REFERENCE_GUIDE.zh-CN.md)。原始日志在同级 D-Development/Logs：clone-validation-summary.json、clone-mlx-validation-summary.json、build-mlx-tests-prepared.log、cli-acceptance/summary.json、mlx-tests.log、mlx-allocation-probe.log、mlx-load-only-probe.log。报告和权重不随源码提交；这里保留可审阅的结果摘要。
