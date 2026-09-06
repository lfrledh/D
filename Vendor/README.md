# MLX 固定源码与局部补丁

`mlx-swift/` 是同仓本地 Swift package，identity、package 名和产品名仍为 `mlx-swift` / `MLX` 等原有名称。它由 **D 的 Git 提交**锁定；本地包不会在 `Package.resolved` 中获得独立远程版本。D 的应用与 MLX 集成应解析到这一份源码，纯 DInference/DRuntime 不依赖它。

## 原样快照

从三个固定 Git 提交直接读取全部跟踪 blob，保留文件内容和 Git 可执行模式，将两项 gitlink 展开为普通目录。基线共 **1811 个文件、23,200,811 字节**，没有复制 `.git`、SwiftPM checkout 状态或构建缓存，也没有裁剪上游文档和测试。

| 来源 | 提交 | 在快照中的路径 | 原始许可文件 |
| --- | --- | --- | --- |
| [mlx-swift 0.30.6](https://github.com/ml-explore/mlx-swift/tree/6ba4827fb82c97d012eec9ab4b2de21f85c3b33d) | `6ba4827fb82c97d012eec9ab4b2de21f85c3b33d` | `.` | `mlx-swift/LICENSE` |
| [mlx](https://github.com/ml-explore/mlx/tree/185b06d9efc1c869540eccfb5baff853fff3659d) | `185b06d9efc1c869540eccfb5baff853fff3659d` | `Source/Cmlx/mlx` | `mlx-swift/Source/Cmlx/mlx/LICENSE` |
| [mlx-c](https://github.com/ml-explore/mlx-c/tree/a1290d221f92bd020af805b7d14207eee4ec973b) | `a1290d221f92bd020af805b7d14207eee4ec973b` | `Source/Cmlx/mlx-c` | `mlx-swift/Source/Cmlx/mlx-c/LICENSE` |

三项顶层许可均为 MIT；其完整文本保留。嵌入第三方代码的许可、`ACKNOWLEDGMENTS.md` 与 `Source/Cmlx/vendor-README.md` 也随原样快照保留，不能只用本表代替这些 notices。原 `.gitmodules` 作为上游文件保留，但其中 gitlink 已展开；普通 clone D 不需要为这个 vendor 执行子模块初始化。

## 三文件补丁

补丁来源为 [MLX PR #4453](https://github.com/ml-explore/mlx/pull/4453)，作者 `tudalex`，固定研究 head 为 [`5002b5ff6adff93a9a439d012e60773c171ec206`](https://github.com/tudalex/mlx/commit/5002b5ff6adff93a9a439d012e60773c171ec206)。2026-09-06 核对时该 PR 尚未合并。本地补丁是向上述旧 C++ 提交的适配，不表示上游已经发布了这个修复。

[`patches/mlx-array-ownership.patch`](patches/mlx-array-ownership.patch) 让数组赋值和 descriptor 覆盖经过同一释放路径，以解除失去外部引用的多输出 sibling 环；只改三个文件：

- `Source/Cmlx/mlx/mlx/array.cpp`
- `Source/Cmlx/mlx/mlx/array.h`
- `Source/Cmlx/include-framework/mlx-array.h`：同步相同头文件变更，保留 Swift framework 包装和导入路径。

[`mlx-swift.files.json`](mlx-swift.files.json) 列出全部源码的来源、Git blob、原始 SHA-256、补丁后 SHA-256、大小及模式；[`mlx-swift.provenance.json`](mlx-swift.provenance.json) 固定三上游提交、PR head、补丁摘要及三个修改文件的前后摘要。未修改文件的前后摘要相同，因此原样基线和 D 的增量修改可以明确区分，无需存储两套完整源码。

在一个干净的原样展开副本中，从该副本根目录应用完整补丁：

```sh
git apply --check /absolute/path/to/D/Vendor/patches/mlx-array-ownership.patch
git apply /absolute/path/to/D/Vendor/patches/mlx-array-ownership.patch
```

这些命令用于重建原始快照上的补丁，不要对已经打补丁的当前目录重复执行。隔离数组和纯模型加载实验的通过不自动代表整个应用已完成验收；当前集成结果另见 D 的研究与交付记录。

## 校验、维护与回退

在 D 根目录执行：

```sh
python3 scripts/verify-mlx-vendor.py
```

验证器不访问网络、不编辑或自动修复文件。它核对 provenance 引用的清单与补丁摘要、全部 1811 个源码的类型/模式/大小/摘要、缺失文件与意外新增文件或目录。包根的 `.build`、`.swiftpm` 和各目录的普通 `.DS_Store` 被视为本机产物忽略；这不是整个机器环境的完整性证明。`--vendor PATH` 可以用同一清单验证一个隔离副本。成功状态写 stderr，stdout 保持空，便于构建脚本返回二进制路径。

维护范围限定在已复现的所有权问题；不在这里发展另一套推理 API。升级时重新取得三个固定上游提交的跟踪文件，保留许可和 notices，重新判断该补丁是否仍需要，生成新的完整前后清单，再运行独立分配探针、真实 CLI、MLX 测试及旧应用构建。升级不能只修改版本字符串或在缓存中临时补丁。

上游正式包含修复且 D 的回归验证通过后，可移除本地包覆盖，恢复一致的官方精确依赖并更新解析锁文件，随后移除已无使用者的快照。回退以 D 的检查点提交为单位；保留来源与实验记录。当前无需创建用户 GitHub fork。

本目录包含上游自己的 `.gitignore`。首次提交应根据文件清单精确加入源码，避免上游 ignore 规则漏掉原来已跟踪的文件；也不要对整个目录使用无差别强制添加，将本机 `.swiftpm` 或 `.build` 一并提交。
