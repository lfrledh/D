# D 推理基础阶段验收

日期：2026-09-06。范围是用户批准的四项基础工作：单仓整合、真实 MLX 接入、生命周期验证、可重复验收与远程检查点。产品完整首版、图像后端和旧 UI 迁移属于后续阶段。

当前状态：四项基础工作已完成。收尾审阅发现的终态重入问题已修复，最终运行时的纯框架、真实 MLX 与 CLI 验收均已通过。

## 四项要求与证据

| 要求 | 已实现内容 | 验证依据 |
| --- | --- | --- |
| 将六个子模块纳入 D，保留边界和来源 | 六个源码目录成为普通 Git 跟踪文件；保留 Swift package 边界及导入 SHA | `6457418` 导入提交、[来源清单](history/SUBMODULE_PROVENANCE.json)、普通 HTTPS clone 的核心测试与旧应用构建；当前树无 gitlink |
| 真实本地 MLX 通过 DInference/DRuntime 运行 | 独立文本后端、受限本地模型准入、流式输出、参数与来源记录；新核心零远程依赖 | 固定 Qwen2.5-0.5B-Instruct-4bit 真正生成非空文本；不是 fake backend 或仅协议定义 |
| 验证排队、取消、drain、release、错误恢复和重复内存 | 显式运行许可、拥有生成任务并等待其退出、释放后交接；修复上游数组所有权及 runtime 终态交接 | 纯框架回归、37 个 MLX 展开场景、10 类 CLI 进程验收、7 组 C++ 生命周期回归、50 轮真实推理；各证据覆盖范围分别说明 |
| 可重复运行并保存进度 | 构建/测试脚本、固定模型摘要、CLI JSON 报告、依赖来源与补丁、GitHub 工作分支检查点 | 使用仓库脚本实际执行；独立普通 clone 对 `490ab4f` 的 1811 个 vendor 文件校验及 CLI 构建通过 |

## 两处关键修复

MLX 原版每轮加载、释放后增长 2720 bytes，独立上游加载与最小数组实验复现了同一缺陷。回移小范围所有权补丁后，C++ 对象生命周期回归通过，50 轮真实推理每轮释放后的活动分配和缓存均为 0。完整来源和实验见 [MLX 修复报告](MLX_OWNERSHIP_FIX.zh-CN.md)。

收尾审阅发现，runtime 在移除已结束任务后跨 actor 发布 outcome，期间仍保留旧 activeRunID。若此时复用同一 UUID，批量取消可能把新队列项当成旧活动任务，遗留无法完成的 outcome。修复要求在 release 已返回后，同一无 await 的 actor 段内清理旧 entry、活动许可、worker、phase 和预算；随后发布终态。恢复后的旧执行流程只能尝试启动队首，不能再覆盖新任务的状态。

公开请求 ID 仍可在任务结束后复用，旧句柄的内部 token 仍防止迟到取消影响新任务；没有增加公开 API 或把测试钩子放进生产接口。新旧任务交接、取消批次与资源释放的语义见 [ADR 0002](decisions/0002-run-lifecycle.md)。

## 最终运行结果

| 验证 | 结果 |
| --- | --- |
| 纯框架 | 17 项测试、18 个展开场景通过 |
| 终态重入原版对照 | 同 ID 重用后分别调用 cancelAll/shutdown，各 64 轮；旧代码捕获 4 次身份冲突、退出 1；修复后通过 |
| MLX XCTest | 25 项声明、37 个展开场景通过；0 失败、0 跳过、0 预期失败 |
| 真实 MLX suite | 7 个用例全部执行；终态前的取消/清理、队列交接、加载失败与消费者异常后的恢复均通过 |
| 最终运行时的 CLI | 10/10 验收通过；所有观测到的释放后 MLX 活动分配与缓存均为 0 |
| MLX 所有权底层回归 | 原版 7 组中 2 组失败；补丁版 7 组、36 检查通过 |
| 50 轮内存验证 | 同一进程连续加载、生成、释放全部完成；每轮活动分配与缓存均为 0 |

终态重入测试结合 actor gate、任务优先级和有界重复，直接检查不合法的 active/queued 身份重叠，先报告再安全清理，避免用永久等待来证明失败。它已在旧代码上实际复现，但仍受调度影响，不声称每轮都必现。修复把相关状态转换放在无 await 的区段，从结构上消除该重入窗口。

最终 MLX 测试总耗时约 12.1 秒，首个真实片段后取消至终态约 21.7 ms；五轮释放的活动分配和缓存均为 0。CLI 整组约 11.7 秒。这些是固定短文本 fixture 的本机观测。

本机证据位于同级 `D-Development/Logs`：`foundation-tests.log`、`terminal-reentrancy-original.log`、`terminal-reentrancy-fixed.log`、`mlx-tests.log`、`mlx-tests-summary-final.json`、`cli-acceptance/summary.json`、`mlx-ownership-tests.log`、`mlx-fixed-repeat-50.json`。最终结构化结果包为 `MLXTests-20260906T213356-39291.xcresult`，已核对通过及跳过数量。此前授权导致的失败和首次成功运行记录保留在 `TestRunnerAttempts`；该阻塞未在两次后续实际运行中重现，不推断系统授权如何变化。

17 项纯框架与最终 MLX/CLI 结果均包含终态重入修复。50 轮测试与 C++ 回归用于此前的 MLX 所有权修复；本次调度器改动没有修改该底层代码。旧应用仍使用旧 runtime 之外的 Packages 模块，其统一 workspace 构建证据保留在 MLX 修复报告中。

## 复验入口

在仓库根目录执行，模型、日志和构建产物默认位于同级外盘目录：

```sh
./scripts/test-foundation.sh
./scripts/build-mlx.sh
python3 scripts/download-test-model.py --verify-only
./scripts/test-mlx.sh
python3 scripts/verify-mlx-cli.py
./scripts/test-mlx-ownership.sh
./scripts/build-local.sh
```

首次需要 `python3 scripts/download-test-model.py` 下载固定 fixture；已下载时摘要校验通过才运行真实验收。Xcode 统一打开 `D.xcworkspace`；直接复制可执行文件而丢弃旁边的 Metal 资源不是受支持的运行方式。详见 [使用指南](MLX_REFERENCE_GUIDE.zh-CN.md)。

## 交付边界

本阶段提供可复验的文本推理基础，尚未把新 runtime 接入旧 SwiftUI 应用。验证对象是一份固定小模型、短文本和当前 M4 / 16 GiB / macOS 26.6.2 环境；不据此声称任意模型、长上下文、多模态或无限次运行均稳定。MLX 分配器计数不是全部进程 RSS，准入预算也不是系统 OOM 硬限制。

当前后端每次释放模型，用于明确验证执行生命周期。常驻模型复用、图像生成、统一下载授权书签、项目保存恢复、用户界面和商品化发布，继续按后续工作包推进，不由这份验收提前宣称完成。
