# D 项目协作与架构规则

## 产品方向与当前状态（2026-09-07）

D 是面向专业 AI 创作者、兼顾初学者的原生 Mac 本地推理工作站。原生 MLX 推理与高完成度体验是核心。完整依据见 docs/ARCHITECTURE_RESEARCH.zh-CN.md 与 docs/decisions/。

当前处于渐进迁移阶段：根 Package.swift 的 DInference/DRuntime 是纯框架；同仓 Backends/MLX 中的 DMLXBackend 提供真实文本与图像后端，d-infer 是宿主 CLI。B2 复用这三个核心模块，没有新增生产框架包。D 应用已迁移到图像项目工作台：Packages/UI 仅依赖 DInference，包含项目、任务应用服务与 Liquid Glass 视图，具体 runtime/MLX 在 D/AppSessionFactory.swift 装配。其他旧 Packages/* 不再接入应用，源代码暂留。六个原子模块仍是主仓库普通目录。当前产品目标与状态统一维护在 docs/PRODUCT_GOALS.zh-CN.md，工作台检查点以 docs/WORKBENCH_ACCEPTANCE.zh-CN.md 的实际证据为准。

图像 B2 已通过 DRuntime 调度固定 FLUX.2 Klein 4B q8，支持 512²、4 步、guidance 1、本地模型完整校验、分阶段加载、进度、取消与图片引用。图文 XCTest 已实际通过 61 项声明／120 个展开场景，0 失败、0 跳过，包含 12 个阶段取消、图文交接、消费者失败、损坏权重和输出目录故障；观测释放后的 MLX 活跃分配与缓存均为 0。最终图像 CLI 17/17、文本 CLI 10/10 和旧应用构建均通过；不能把构建通过视作 UI 已迁移。调用规则见 docs/IMAGE_RUNTIME_GUIDE.zh-CN.md，最终检查点证据与未完成项以 docs/IMAGE_RUNTIME_ACCEPTANCE.zh-CN.md 为准。

图像 B1 的独立实验保留在 Experiments/Flux2Probe，原报告 docs/IMAGE_PROBE_RESULTS.zh-CN.md 记录了当时约 0.5 MiB 固定残留。它是历史硬件与数学对照，不是当前生产后端状态；不要用 B2 结果覆盖原始 B1 报告，也不要用 B1 残留替代 B2 的资源测量。

2026-09-06 的文本基础阶段快照：纯框架 17 项测试与旧应用构建通过，固定本地文本模型的 CLI 10 类验收通过。该检查点的 MLX XCTest 实际通过 25 项声明／37 个展开场景，失败和跳过均为 0；原每轮 2720 字节增长已由固定 vendor 补丁修复；C++ 7 组/36 检查和 50 轮真实推理通过，后者每轮释放的 MLX 活跃分配与缓存均为 0。这些数量不包含后续 B2 图像测试。docs/history 是历史资料，不是当前执行规范；后续状态以最新运行证据更新。

## 依赖与并发

文本基础阶段四项工作的验收基线见 docs/FOUNDATION_STAGE_ACCEPTANCE.zh-CN.md；图像阶段见 docs/IMAGE_RUNTIME_ACCEPTANCE.zh-CN.md。后续修改应按实际影响复验，不用旧检查点的未完成说明覆盖较新的运行证据。

- 用户已授权按产品质量需要升级、替换、修复第三方依赖，或自行实现；调用库是手段。发现问题应说明可复现行为、影响、选择方案及验证结果，不因属于上游就默认保留缺陷。
- 依赖修复必须进入可重复检出的源码或固定版本配置，记录上游来源、许可证、补丁和回退/移除条件；不能只改本机 SwiftPM checkout。优先选择有证据支持、维护范围最小的方案，保持执行所有权和模块边界。
- 新公共契约只含 Sendable 值和资源引用，不泄露 MLXArray、ChatSession、AppKit、SwiftUI。
- DInference 不依赖 DRuntime、MLX、网络或 UI；DRuntime 只依赖 DInference 和标准库/Foundation。
- 状态隔离和执行所有权解决并发；不得为了消除编译诊断批量添加 nonisolated、nonisolated(unsafe) 或 unchecked Sendable。
- actor 的 await 可重入，整次推理需要显式许可。execute返回前必须drain，release完成前不得放行下一任务。
- 文本与图像后端共用进程级 MLX 执行许可。release 清理计算资源并恢复 allocator 设置；宿主在后端空闲（例如全部终态或 shutdown）后调用 cleanupUnpublishedArtifacts，仅处理本实例跟踪的未发布文件，不能扫描作品根目录或删除已经发布的 PNG。
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

主项目 /Volumes/CodexProjects/Codex/D；应用产物、模型和日志使用同级 D-Development；纯核心测试 scratch 使用同级 BuildCaches/D-Foundation，避免 Swift 调试路径前缀碰撞；MLX 集成使用同级 BuildCaches/D-MLX，保留二进制旁的 Metal 资源。统一入口是 D.xcworkspace；命令行依赖检出区分 SourcePackages-App/MLX，不能将两者链接到同一个可变检出目录。均优先外置 SSD。

- 用户已授权按验证需要下载真实模型权重并执行本地推理，优先存放外置 SSD，固定来源并校验文件。本机 M4／16 GiB：选择模型与测试参数时须评估权重、上下文/KV 缓存、推理工作区及系统余量，逐步提高负载并记录实际峰值；不能把权重文件大小当作运行内存需求，也不能用小文本模型结果替代图像等负载的实测。
- 新核心：`./scripts/test-foundation.sh`（Swift 6，无模型下载）。
- 项目与工作台服务：`./scripts/test-workbench.sh`（Swift 6，CPU 图片 fixture，不加载 MLX；测试目录和缓存使用外盘）。
- XCTest 的 build/test 会给宿主签名注入临时沙盒例外；做真实权限验收或交付前必须重新正常 build，并核验签名中没有测试例外。CUA 的真实 UI 验证不能虚报为 XCTest UI 测试执行成功。
- 新工作台应用：`./scripts/build-local.sh`（D.xcworkspace，固定 vendor MLX 与锁定远程依赖）。
- MLX CLI：`./scripts/build-mlx.sh` 构建文本／图像共用的 d-infer。文本固定模型文件校验：`python3 scripts/download-test-model.py --verify-only`；图像固定模型校验与调用参数见 docs/IMAGE_RUNTIME_GUIDE.zh-CN.md。
- CLI 真实进程验证：文本 `python3 scripts/verify-mlx-cli.py`；图像 `python3 scripts/verify-image-cli.py`。后者 `--offline-only` 只验证帮助和参数，不能记为真实推理通过；完整报告使用新目录，保留原有图片和证据。
- MLX 所有权回归：`./scripts/test-mlx-ownership.sh`；固定源码校验：`python3 scripts/verify-mlx-vendor.py` 与 `python3 scripts/verify-flux2-vendor.py`。不要直接修改 vendor 清单之外的源文件；来源和增量见 Vendor/README.md 与 docs/FLUX2_DEPENDENCY_PATCH.zh-CN.md。
- MLX XCTest：`./scripts/test-mlx.sh [文本模型目录] [图像模型目录]`，默认使用外盘完整 Qwen2.5-0.5B-Instruct-4bit 和 FLUX.2-klein-4B-q8 两个安装目录。脚本校验模型、构建测试、设置 D_TEST_MODEL_DIR／D_TEST_IMAGE_MODEL_DIR／D_TEST_FLUX_FIXTURE，并检查图文执行标记与零失败、零跳过结果。缺失／损坏模型和系统授权造成的启动超时都不能记为测试通过。
- 报告、ADR、README随实际边界变化更新。无需每次手工更新project_tree.txt；若需要目录树应排除.git、缓存和构建产物。
- 真实 MLX 集成需要验证输出、峰值内存、取消后停止和多次加载/卸载。`cacheBytes == 0` 及短轮次阈值检查不证明无泄漏；记录实际活跃分配趋势，未定位的增长保留为待核查事项。原有空模板测试不能作为这些能力的证明。
