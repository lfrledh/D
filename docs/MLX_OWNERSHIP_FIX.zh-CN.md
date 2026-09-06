# MLX 数组所有权修复记录

日期：2026-09-06。状态：局部依赖修复、C++ 回归和真实 CLI 验证完成；MLX XCTest 已编译，实际执行仍待 macOS 外置宗卷授权后的复验。

## 问题与处理

原固定版本每次加载并释放 Qwen2.5-0.5B-Instruct-4bit 后，MLX 活动分配增长 2720 bytes。独立程序仅调用上游模型加载器、不经过 D 的运行时，也复现相同增长；最小数组实验进一步定位到多输出惰性数组在求值前被覆盖。原始实验见 [分配增长调查](research/MLX_ALLOCATION_FINDINGS.zh-CN.md)。

C++ array 的多个输出通过 sibling 引用相互关联。原版赋值覆盖 descriptor 时，没有执行析构路径中的引用环清理；最后一个外部引用消失后，相关对象仍可互相持有。这个缺陷应在依赖的对象所有权层修复，额外清缓存或改变 D 的 actor 隔离无法解决它。

本次适配了 [MLX PR #4453](https://github.com/ml-explore/mlx/pull/4453) 固定 head `5002b5ff6adff93a9a439d012e60773c171ec206` 的有关修改：复制赋值、移动赋值、descriptor 覆盖和析构经过同一释放函数；先保留新 descriptor，再清理旧对象，避免改指自己的 sibling 时提前释放。生产源码只改两个 C++ 文件及对应的 framework 导出头，共三个文件。

核对时该 PR 尚未合并，因此这是 D 自行验证和维护的兼容补丁，不宣称为上游正式发布。沿用 MLX Swift 0.30.6 的完整固定源码，避免同时改变模型接口和生成逻辑。完整源码约 22 MiB，1811 个文件，作为普通目录提交；三项上游 Git SHA、原始与修复后摘要、许可证及补丁均保存在 [Vendor](../Vendor/README.md)。取舍与移除条件见 [ADR 0005](decisions/0005-owned-mlx-compatibility-patch.md)。

## 构建方式

统一从 `D.xcworkspace` 打开项目。workspace 将本地 MLX 包作为根依赖覆盖，旧应用与新后端解析到同一实现；仅在下层 manifest 中改成本地路径，会与上游声明产生 package identity 冲突警告。此次三个最终构建日志均确认使用 `Vendor/mlx-swift`，没有该冲突警告。

应用与 MLX 命令行构建分别使用 `SourcePackages-App` 和 `SourcePackages-MLX`。SwiftPM checkout 是可变目录；并行构建不能共享同一份 checkout，否则解析器可能删除另一构建正在使用的源码。模型、构建缓存和日志继续放在外置 SSD。纯 DInference/DRuntime 的依赖边界保持不变。

`DMLXTests` 是明确列出测试 target 的共享 scheme。构建生成的 xctestrun 已确认包含唯一的 `DMLXBackendTests`；测试脚本要求成功注入模型目录并检查真实执行标记，空测试计划或启动超时不能算通过。

## 实际结果

环境：Apple M4，16 GiB，macOS 26.6.2，Xcode 26.6，Debug arm64。固定模型 revision：`a5339a4131f135d0fdc6a5c8b5bbed2753bbe0f3`；模型文件在验收前通过摘要校验。修复后后端版本标识为 `0.1.1+mlx-0.30.6.d1.lm-2.30.6`。

| 验证 | 原版 | 修复后 |
| --- | --- | --- |
| C++ 所有权回归，同一测试源码 | 7 组中 2 组失败，复现复制/移动/覆盖遗留对象 | 7 组、36 项检查全部通过 |
| 四种数组模式，各运行 10 次 | 未求值即覆盖的模式每次增长 24 bytes | 40 次释放后的活动分配全部为 0 |
| 仅加载模型，连续 5 轮 | 2720、5440、8160、10880、13600 bytes | 每轮释放后均为 0 |
| 真实 CLI，10 类验收 | 旧版允许宽松内存阈值 | 全部通过；重复运行阈值收紧为 1024 bytes |
| 连续加载、生成、释放 50 轮 | 未做同轮数对照 | 50/50 完成且文本非空，每轮活动分配与缓存均为 0 |
| 旧应用、CLI、MLX 测试 bundle | 初始检查点可编译 | 统一 workspace 构建全部成功 |
| 完整 MLX XCTest 执行 | 外盘访问授权前启动超时 | 待授权后实际执行，尚未计为通过 |

C++ 回归使用 weak_ptr 验证对象真实生命周期，覆盖赋值覆盖、自身赋值、改指 sibling 和共享 descriptor；不仅比较分配器数字。50 轮运行使用 `maxTokens=8`、`temperature=0`，每轮都经历 loading → loaded → generating → drained → released。总用时约 49.6 秒，首块延迟范围 0.884–0.947 秒，MLX 峰值分配范围 322,442,428–322,526,260 bytes。

CLI 验收还覆盖参数与缺失模型错误、预算拒绝、单 token 终止、取消、SIGINT、SIGTERM、输出管道断开。正常生成和中断后的释放观测均回到 0；完整 XCTest 中的队列衔接、部分加载失败恢复等断言仍需由测试 runner 实际执行。

这些结果支持“已修复这个可复现的所有权缺陷”。MLX 分配器计数不包含全部进程 RSS，短文本小模型的 50 轮也不代表所有模型、长上下文、多模态或无限次运行均无泄漏。

## 复验与证据

在 D 根目录运行：

```sh
python3 scripts/verify-mlx-vendor.py
./scripts/test-mlx-ownership.sh
python3 scripts/download-test-model.py --verify-only
python3 scripts/verify-mlx-cli.py
./scripts/build-local.sh
./scripts/test-mlx.sh
```

最后一项需要 macOS 允许 Xcode/xctest 访问外置宗卷；本记录没有把 build-for-testing 成功当作执行成功。50 轮运行可以在 CLI 构建后复验：

```sh
../BuildCaches/D-MLX/Build/Products/Debug/d-infer \
  --model ../D-Development/Models/Qwen2.5-0.5B-Instruct-4bit \
  --prompt 'Answer in one short sentence: What is two plus two?' \
  --max-tokens 8 --temperature 0 --repeat 50 \
  --revision a5339a4131f135d0fdc6a5c8b5bbed2753bbe0f3 \
  --report ../D-Development/Logs/mlx-fixed-repeat-50.json
```

本机原始日志位于同级 `D-Development/Logs`：

- `mlx-ownership-original.log`、`mlx-ownership-fixed.log`：同一 C++ 回归程序的原版/补丁版对照；`mlx-ownership-tests.log` 是仓库脚本的最终通过结果。
- `mlx-ownership-fixed-array.log`、`mlx-ownership-fixed-load.log`：隔离补丁实验。
- `cli-acceptance/summary.json`：10 类验收的退出码、释放分配与时延。
- `mlx-fixed-repeat-50.json`：全部 50 轮的输出、生命周期及分配计数。
- `build-mlx.log`、`mlx-vendor-app-build-console.log`、`mlx-fixed-tests-build.log`：最终 workspace 构建证据。
- `BeforeMLXOwnershipFix/`：修复前的分配与 CLI 记录。旧检查点文档保留历史数据，不能用来判断当前补丁是否生效。

日志和模型保存在外盘，不随源码提交。独立审阅另外核对了全部 1811 个原始 Git blob 与清单、补丁反向检查，以及所有本地依赖路径；提交时按清单精确加入上游跟踪文件，避免 ignore 规则遗漏。
