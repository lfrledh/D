# ADR 0005：由 D 固定和验证必要的 MLX 修复

日期：2026-09-06。状态：已实施；C++ 回归、真实 CLI 和 50 轮释放验证通过，完整 XCTest 执行仍待系统授权后的复验。详细证据见 [修复记录](../MLX_OWNERSHIP_FIX.zh-CN.md)。

## 问题

MLX 0.30.6 的 C++ array 在赋值覆盖旧 descriptor 时，没有执行析构路径中的 siblings 引用环检查。固定模型每轮加载/释放后的 MLX 活跃分配增加 2720 bytes；不依赖 D、仅调用上游 loadContainer 也可复现。最小数组实验定位到了尚未求值的多个输出被覆盖的路径。

这不是 D 的队列许可或 Swift actor 可以解决的问题。用户明确授权根据产品需要升级、修复、替换依赖或自行实现；第三方归属不构成保留已知缺陷的理由。

## 选择

回移 [MLX PR #4453](https://github.com/ml-explore/mlx/pull/4453) 固定 head `5002b5ff6adff93a9a439d012e60773c171ec206` 的小范围生产修复，统一 copy assignment、move assignment、overwrite_descriptor 和析构的释放路径。保留新 descriptor 后再检查旧值的引用环，确保改指自己的 sibling 时不提前销毁仍需要的对象。

只移植有关 hunks，不复制 PR 基线中其余新 API。同步 canonical array.h、array.cpp 及 framework 导出的数组头，保持头文件和实现一致。PR 在核对时尚未合并，因此本项目承担选用此固定补丁的验证责任，不将其标为上游正式版本。

将 MLX Swift 0.30.6 的跟踪源码及两个直接子模块完整展开为 `Vendor/mlx-swift`，约 22 MiB，保留许可证、三份来源 SHA、补丁和逐文件摘要。没有嵌套 Git 仓库。D 的提交锁定本地依赖，Package.resolved 继续锁定其他远程依赖。

旧应用和新集成都显式使用这同一个本地 package，目录 identity 仍为 mlx-swift。上游 LM/examples 的依赖声明保留；验证解析图只有一个 MLX 实现，避免重复 C 符号、分配器与运行状态。纯 DInference/DRuntime 保持零远程依赖。

统一入口为 D.xcworkspace，将本地 MLX 设为 workspace 根 package，明确覆盖传递依赖并消除 package identity 冲突警告。两个构建入口使用独立的 SwiftPM checkout 目录，避免同时解析依赖时互相修改源码。

## 取舍

- 全量升级会同时改变模型支持、生成逻辑和工具链要求，扩大本次内存修复的验证范围；当前也不能假定最新版本已包含这个未合并修复。
- 只修改本机缓存无法通过普通 clone 复现。下载后再临时应用补丁需要额外 bootstrap，并使直接打开 Xcode 依赖隐含步骤。
- 此时维护两个远程 fork（Swift wrapper 和 C++ 子模块），比同仓 22 MiB 的固定快照增加更多发布协调。
- 重写整个加载器或对全部随机占位权重求值会增加维护范围或加载成本；底层所有权修复直接覆盖实际缺陷。

## 验收与维护

对象生命周期回归使用 C++ weak_ptr，覆盖复制、移动、原位覆盖、改指 sibling、自身赋值及共享 descriptor。原版必须复现失败，补丁版必须通过；内存数值对照只是补充证据。

完整重编译 Cmlx 与调用方，运行独立数组/纯模型加载实验、真实 CLI 的正常生成与取消、重复推理、旧应用构建。五轮分配容差从 64 MiB 收紧为 1024 bytes，能检测原来的增长。完整 MLX XCTest 仍须单独实际运行；C++ 测试和 CLI 不能替代它。

每次构建入口先验证 vendor 文件摘要；意外修改报告失败，不自动修复。升级时重新导入固定快照、验证补丁是否已被上游吸收，再执行相同验收。删除补丁的条件是上游版本覆盖这些行为且回归通过；若修复范围扩大或有独立发布需求，再考虑 fork。不得长期默默积累无来源、无测试的 vendor 修改。
