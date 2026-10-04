# MLX 固定源码与局部补丁

`mlx-swift/` 是同仓本地 Swift package，identity、package 名和产品名仍为 `mlx-swift` / `MLX` 等原有名称。它由 **D 的 Git 提交**锁定；本地包不会在 `Package.resolved` 中获得独立远程版本。D 的应用与 MLX 集成应解析到这一份源码，纯 DInference/DRuntime 不依赖它。

## 原样快照

从三个固定 Git 提交直接读取全部跟踪 blob，保留文件内容和 Git 可执行模式，将两项 gitlink 展开为普通目录。基线共 **1748 个文件、23,089,400 字节**，没有复制 `.git`、SwiftPM checkout 状态或构建缓存，也没有裁剪上游文档和测试。

| 来源 | 提交 | 在快照中的路径 | 原始许可文件 |
| --- | --- | --- | --- |
| [mlx-swift 0.31.4](https://github.com/ml-explore/mlx-swift/tree/dc43e62d7055353c7f99fa071a4e71d29dfddc44) | `dc43e62d7055353c7f99fa071a4e71d29dfddc44` | `.` | `mlx-swift/LICENSE` |
| [mlx](https://github.com/ml-explore/mlx/tree/ce45c52505c8158ea48d2a54e8caae05efd86bfe) | `ce45c52505c8158ea48d2a54e8caae05efd86bfe` | `Source/Cmlx/mlx` | `mlx-swift/Source/Cmlx/mlx/LICENSE` |
| [mlx-c](https://github.com/ml-explore/mlx-c/tree/0726ca922fc902c4c61ef9c27d94132be418e945) | `0726ca922fc902c4c61ef9c27d94132be418e945` | `Source/Cmlx/mlx-c` | `mlx-swift/Source/Cmlx/mlx-c/LICENSE` |

三项顶层许可均为 MIT；其完整文本保留。嵌入第三方代码的许可、`ACKNOWLEDGMENTS.md` 与 `Source/Cmlx/vendor-README.md` 也随原样快照保留，不能只用本表代替这些 notices。原 `.gitmodules` 作为上游文件保留，但其中 gitlink 已展开；普通 clone D 不需要为这个 vendor 执行子模块初始化。

2026-09-30更新：为Qwen3.5/3.8 VLM采用官方MLX Swift0.31.4候选；固定Git blob逐文件核对，原所有权补丁原样适用，尚待本轮编译/真实模型回归。旧版本的验证不会倒记为新版本通过。

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

验证器不访问网络、不编辑或自动修复文件。它核对 provenance 引用的清单与补丁摘要、全部 1748 个源码的类型/模式/大小/摘要、缺失文件与意外新增文件或目录。包根的 `.build`、`.swiftpm` 和各目录的普通 `.DS_Store` 被视为本机产物忽略；这不是整个机器环境的完整性证明。`--vendor PATH` 可以用同一清单验证一个隔离副本。成功状态写 stderr，stdout 保持空，便于构建脚本返回二进制路径。

维护范围限定在已复现的所有权问题；不在这里发展另一套推理 API。升级时重新取得三个固定上游提交的跟踪文件，保留许可和 notices，重新判断该补丁是否仍需要，生成新的完整前后清单，再运行独立分配探针、真实 CLI、MLX 测试及旧应用构建。升级不能只修改版本字符串或在缓存中临时补丁。

上游正式包含修复且 D 的回归验证通过后，可移除本地包覆盖，恢复一致的官方精确依赖并更新解析锁文件，随后移除已无使用者的快照。回退以 D 的检查点提交为单位；保留来源与实验记录。当前无需创建用户 GitHub fork。

本目录包含上游自己的 `.gitignore`。首次提交应根据文件清单精确加入源码，避免上游 ignore 规则漏掉原来已跟踪的文件；也不要对整个目录使用无差别强制添加，将本机 `.swiftpm` 或 `.build` 一并提交。

## FLUX.2 图像依赖

`flux2-swift/` 是固定的 Apache-2.0 源码快照，包含上游全部 206 个文件。D 的局部补丁包含统一本地 MLX、显式缓存清理、严格分词、分阶段生命周期和原始 BF16 SSD 逐层加载。完整来源、许可证、前后摘要和维护条件见 [FLUX.2 依赖记录](../docs/FLUX2_DEPENDENCY_PATCH.zh-CN.md)；运行 `python3 scripts/verify-flux2-vendor.py` 离线核对。实际模型权重保存在项目外，未提交到 Git。

## MLX LM 3.31.4：本地集成与原始 BF16 分层加载

`mlx-swift-lm/` 保留官方 `bd4b7434e6bdb588c7ef55706ff8904cb7fd4c57` 全部跟踪文件和 MIT 许可。`mlx-swift-lm.files.json`记录固定上游/当前SHA256，新文件明确标为D局部添加；完整可重放差异为`patches/mlx-lm-local-integration.patch`。旧`mlx-lm-presampled-frames.patch`仅为历史子集，不能与完整补丁叠加。

变更包括同仓MLX依赖、显式预采样视频保真、prepare状态传递、可抛错的token迭代/流以及Qwen原始BF16逐层加载。后者按需求读取全部解码/视觉层，保留原始键转换、混合注意力cache和多轴位置；不支持量化权重时明确拒绝，不静默降精度。文件/索引在延迟读取前后检查，损坏配置在构造前报错，取消等待producer结束。常驻路径保留；用于对照的逐层求值仅在测试显式开启。

2026-10-02补充实例独立的 `ModelFileSelection`：固定目录的权重、索引、tokenizer、processor与生成配置只读已登记文件；额外sidecar不参与执行，选中的必要文件失败仍报错。没有固定清单的调用继续原严格路径，不能把已知清单变成全局模型白名单。此项不改变张量、精度或采样；完整补丁已在固定上游独立重放并核对全部跟踪文件摘要。

本地细小BF16模型的13项对照/边界测试通过，涵盖非平凡图片/视频位置、逐段预填充与decode/cache精确对照、文件变动和取消；这不是完整9B/27B权重或GUI验收。真实模型与App证据以当前任务记录为准。更新依赖时重新判断局部补丁适用性，不在SwiftPM缓存内悄悄打补丁；回退保留Git历史及原始权重。

## MCP Swift SDK 0.12.1

`mcp-swift-sdk/` preserves all 100 files from official commit `a0ae212ebf6eab5f754c3129608bc5557637e605`, including Apache-2.0 licensing and upstream tests. `mcp-swift-sdk.provenance.json` records original hashes. The only code patch, `patches/mcp-session-injection.patch`, exposes the existing URLSession initializer so D can reject redirects before forwarding tool parameters. Protocol, JSON-RPC and SSE remain implemented by the official SDK. Never patch SwiftPM caches.

Existing Package.resolved files lock transitive dependencies, including the upstream documentation plugin branch. That plugin is not invoked for chat operation. On updates, check upstream session injection support, replay this narrow patch and test zero outgoing requests to 307/308 targets, cancellation and connection. Cancellation is advisory, not proof of server completion. D does not provide roots, sampling or elicitation permissions; explicit calls only. Build and live transport evidence remain in the active task record.

## SwiftStreamingMarkdown：聊天代码换行

`SwiftStreamingMarkdown/`保留固定官方提交`5f7c04e0558df6146f90d482edb62cb456986bda`的全部生产Sources及Package/LICENSE/README/SECURITY（MIT）。它是生产子集，不含上游示例、工具和30MB快照测试；Package移除了相应测试依赖/target。依赖版本不变，Equatable宏继续按既有信任校验。`SwiftStreamingMarkdown.provenance.json`记录原始/当前摘要，`patches/markdown-code-wrap.patch`可重放。

局部补丁仅给现有CodeBlockConfig/CodeBlockView增加默认关闭的换行展示开关；保留高亮、原始代码复制及解析器。选择依据：固定库只提供横向ScrollView且无公开代码块替换入口；用小补丁复用成熟渲染而不再解析Markdown。升级时检查上游是否已支持、核局部补丁并运行字体/原文/代码宽度回归；不得修改SwiftPM缓存。实际运行证据见CHAT-PRODUCT任务记录。
