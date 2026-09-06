# D 项目协作与架构规则

## 产品方向与当前状态

D 是面向专业 AI 创作者、兼顾初学者的原生 Mac 本地推理工作站。原生 MLX 推理与高完成度体验是核心。完整依据见 docs/ARCHITECTURE_RESEARCH.zh-CN.md 与 docs/decisions/。

当前处于渐进迁移阶段：根 Package.swift 的 DInference/DRuntime 是纯框架；同仓 Backends/MLX 是有真实使用者的 MLX 集成 package；Packages/* 是仍供旧应用使用的实现。六个原子模块已成为主仓库普通目录，Swift package 边界暂留。

2026-09-06 的验证快照：纯框架 16 项测试与旧应用构建通过，固定本地文本模型的 CLI 10 类验收通过。MLX XCTest 仅 build-for-testing 成功，实际执行在外盘权限授权前超时，仍待复验；每轮约 2720 字节的 MLX 活跃分配增长正在独立核查。CLI 尚未接入旧 UI，MLX 阶段未完成全部验收。docs/history 是历史资料，不是当前执行规范；后续状态以最新运行证据更新。

## 依赖与并发

- 新公共契约只含 Sendable 值和资源引用，不泄露 MLXArray、ChatSession、AppKit、SwiftUI。
- DInference 不依赖 DRuntime、MLX、网络或 UI；DRuntime 只依赖 DInference 和标准库/Foundation。
- 状态隔离和执行所有权解决并发；不得为了消除编译诊断批量添加 nonisolated、nonisolated(unsafe) 或 unchecked Sendable。
- actor 的 await 可重入，整次推理需要显式许可。execute返回前必须drain，release完成前不得放行下一任务。
- 所有任务必须有取消、清理、明确错误与可观测终态；不以字符串错误前缀或静默finish代替错误协议。
- 暂不创建空的未来功能包。先以真实用例验证边界，再提炼复用。

## 自动化协作

- 直接检查源码与Git状态，不依赖静态目录树推断存在的文件或功能。
- 在用户已确定的任务范围内完成修改、构建、测试和文档更新；不让用户代做例行文件操作。
- 遵守正在进行的用户讨论与范围；产品方向、重大取舍不能由过时说明代替用户决定。
- 保留已有未提交修改。Packages/* 已是主仓库的普通目录，原子模块来源见 docs/history/SUBMODULE_PROVENANCE.json；不要重新创建嵌套 Git 仓库或丢失来源记录。
- 有明确独立子任务时可以并行研究/审阅；共享目录编辑必须分配互不冲突的文件。
- 交付区分已实现、仅定义契约、未验证；只把实际运行结果写成通过。纯框架、CLI 真实进程验证和 MLX XCTest 分别报告；build-for-testing 不能记为测试执行通过，CLI 成功不能替代旧 UI 接入验证。
- 用户已授权在阶段完成、验证通过时 commit 并 push 保存进度；不必为每个检查点重复请求许可。默认推送工作分支，不擅自强制推送、删除远程历史或合并主分支。沿用 lfrledh 的提交署名，在提交说明注明由 Codex 完成的工作。
- 以小型工作包分配实现：明确行为、接口、不变量和验收标准。代码和测试是接口事实来源；不预先为全项目每个函数维护一份重复的提示词。

## 本机路径与验证

主项目 /Volumes/CodexProjects/Codex/D；应用产物、模型和日志使用同级 D-Development；纯核心测试 scratch 使用同级 BuildCaches/D-Foundation，避免 Swift 调试路径前缀碰撞；MLX 集成使用同级 BuildCaches/D-MLX，保留二进制旁的 Metal 资源。均优先外置 SSD。

- 新核心：`./scripts/test-foundation.sh`（Swift 6，无模型下载）。
- 原应用：`./scripts/build-local.sh`（Xcode，原锁定依赖）。
- MLX CLI：`./scripts/build-mlx.sh`；固定模型文件校验：`python3 scripts/download-test-model.py --verify-only`；真实进程验证：`python3 scripts/verify-mlx-cli.py`。
- MLX XCTest：`./scripts/test-mlx.sh`，包含模型校验、测试构建和执行证据检查。系统授权导致的启动超时不得记为模型测试已执行；授权解决后重新运行。
- 报告、ADR、README随实际边界变化更新。无需每次手工更新project_tree.txt；若需要目录树应排除.git、缓存和构建产物。
- 真实 MLX 集成需要验证输出、峰值内存、取消后停止和多次加载/卸载。`cacheBytes == 0` 及短轮次阈值检查不证明无泄漏；记录实际活跃分配趋势，未定位的增长保留为待核查事项。原有空模板测试不能作为这些能力的证明。
