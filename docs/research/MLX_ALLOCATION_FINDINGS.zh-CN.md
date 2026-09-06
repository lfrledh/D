# 锁定 MLX 版本的分配增长复现

日期：2026-09-06。MLX 0.30.6 / mlx-swift-lm 2.30.6，Apple M4，Debug arm64。

## 结论及范围

固定 Qwen2.5-0.5B-Instruct-4bit 每次加载、释放后，MLX activeMemory 增加 2720 bytes。独立于 D 的程序仅调用上游 loadContainer 并释放、不做生成，也得到完全相同的五轮序列：2720、5440、8160、10880、13600。无需 DInference、DRuntime 或 DMLXBackend 即可复现，排除了这些层作为此序列的必要条件。

这是可重复的依赖问题，当前没有修复。模型的大块权重能释放、缓存归零，不等于无泄漏。此计数只覆盖 MLX 分配器，不包含全部 CPU 图对象或进程 RSS，不能把 2720 bytes 当作总内存增长的上界，也不能据此保证无限次加载稳定。

## 最小对照

[MLXAllocationProbe 源码](../../Backends/MLX/Sources/MLXAllocationProbe/Probe.swift) 直接依赖上游 MLX 模块，不依赖 D。每个模式运行十次，helper 返回后同步 CPU/GPU 并清缓存。

| 模式 | 操作 | 每次活跃分配增量 |
|---|---|---:|
| 0 | uniform 数组创建后释放 | 0 |
| 1 | 再量化，三个惰性输出直接释放 | 0 |
| 2 | 量化输出在求值前被新数组覆盖 | 24 bytes |
| 3 | 先求值三个输出，再覆盖 | 0 |

四个模式同一进程按顺序运行，模式 3 保持此前模式 2 留下的 240 bytes，并不回收已经遗失的图。`_updateInternal` 仅用于这个诊断程序重现上游权重更新动作，不用于生产后端。

模型有 169 个量化组。源码分析显示，168 个 Linear 的初始化图各持有四个 f32 常量，Embedding 的图另有六个；`168 × 16 + 24 = 2712` bytes，加本轮 RNG key 的 8 bytes，与 2720 精确吻合。字节分解是基于源码的解释，直接实验证据是上述独立数组对照和仅加载模型的序列。

## 上游依据与处理决定

锁定版本的 Module.update 经 MLXArray._updateInternal 调用数组赋值；惰性量化具有多个输出，其 siblings 互相持有。覆盖时未经过析构释放路径，与 [MLX PR #4453](https://github.com/ml-explore/mlx/pull/4453) 描述的底层引用环一致。2026-09-06 查询时该 PR 仍开放；不据此声称当前最新版本已修复。

本检查点保留锁定依赖、实测记录和独立复现程序。没有修改外部 SwiftPM checkout，也没有为全部随机占位权重额外执行昂贵求值，或复制整个模型加载器来掩盖底层问题。后续依赖升级需先复跑此 probe，再复跑真实取消、失败恢复和连续运行验收；问题解决前不把本后端宣称为通过长期内存稳定性验收。

## 复验

在仓库根目录执行；构建和模型都使用同级外盘目录。模型应先通过 `scripts/download-test-model.py --verify-only`。

```sh
cd Backends/MLX
xcodebuild -scheme mlx-allocation-probe -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath ../../../BuildCaches/D-MLX \
  -clonedSourcePackagesDirPath ../../../D-Development/SourcePackages \
  -onlyUsePackageVersionsFromResolvedFile CODE_SIGNING_ALLOWED=NO build
../../../BuildCaches/D-MLX/Build/Products/Debug/mlx-allocation-probe
../../../BuildCaches/D-MLX/Build/Products/Debug/mlx-allocation-probe \
  ../../../D-Development/Models/Qwen2.5-0.5B-Instruct-4bit
```

本机原始记录：同级 D-Development/Logs/mlx-allocation-probe.log 与 mlx-load-only-probe.log。仅加载模式使用一个位置参数；无参数执行数组对照。
