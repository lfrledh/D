# FLUX.2 固定依赖与本地增量

D 的图像后端使用同仓 `Vendor/flux2-swift`。上游来源为
[mzbac/flux2.swift](https://github.com/mzbac/flux2.swift/tree/959a4af7c0721c800851c84431ffd3fa1f353f1f)，
固定提交 `959a4af7c0721c800851c84431ffd3fa1f353f1f`，原始 Git tree 为
`3f46b9d8581879ff21ef60b2f916c60e2e9b6210`。许可证为 Apache-2.0，原文保留在
`Vendor/flux2-swift/LICENSE`。

快照从固定提交的 Git blobs 提取，完整保留上游 206 个跟踪文件，共 41,852,259
字节；没有裁剪、子模块、模型大权重、`.git` 或本机依赖缓存。上游的小型数值
fixtures、tokenizer fixture、示例、测试、脚本及说明均保留。最大的 safetensors
是约 15.7 MB 的 prompt embeddings fixture，不是已下载的 4B 模型权重。
补丁后仍为 206 个文件，共 41,856,374 字节。

## 三项增量

| 补丁 | 修改文件 | 行为与边界 |
| --- | --- | --- |
| `Vendor/patches/flux2-local-mlx.patch` | `Package.swift` | MLX 从远程范围改为 `../mlx-swift`，与 D 的文本后端使用同一份固定 MLX 源码。其他依赖范围保持上游值；宿主负责统一锁定实际版本。 |
| `Vendor/patches/flux2-runtime-cache-release.patch` | `Sources/Flux2/Support/Flux2AttentionMaskCache.swift` | 新增公开 `Flux2RuntimeResources.clearCaches()`，仅包装现有 attention mask cache 的 `clear()`。 |
| `Vendor/patches/flux2-tokenizer-no-truncation.patch` | `Sources/Flux2/Models/TextEncoder/Flux2QwenTokenizer.swift`、`Sources/Flux2/Pipeline/Flux2KleinPromptEncoder.swift`、`Tests/Flux2Tests/Flux2QwenTokenizerTests.swift` | 为分词入口和 Klein prompt encoder 增加默认 `true` 的 `truncation` 参数；`false` 拒绝完整模板 token 序列超限，并增加三项回归测试。 |

`clearCaches()` 不是调度器或 GPU 同步操作。调用方必须独占 Flux2 执行，先等待
所有推理工作和 GPU evaluation 完成，再清理缓存；最后按宿主的所有权约定清理
MLX allocator cache、记录内存并归还执行许可。它不释放仍由调用方持有的模型和
数组，也不保证进程 RSS 或 MLX 活跃分配归零。并发创建 mask 时可能在清理返回后
重新填充缓存，因此不能用内部字典的锁代替整次推理的独占权。

`Flux2QwenTokenizer.encode(..., truncation: false)` 让底层模板分词使用
`truncation: false, maxLength: nil`，随后用完整 token 数检查有效长度
`min(本次 maxLength 或实例 maxLength, 实例 maxLength)`。超限抛出
`Flux2TokenizerError.promptTooLong(index:tokenCount:maxLength:)`；索引从零开始，
数量包含聊天模板和 generation prompt。拒绝发生在创建 MLXArray 之前；短输入
仍按原方式 padding。省略参数或传 `true` 时保留原有截断行为。

宿主可以先单独加载 tokenizer 并调用严格分词，拒绝后不必加载数 GB 权重；
通过检查的 token batch 可交给已有的 `Flux2KleinPromptEncoder.encodeTokens`。
直接调用 `encodePrompts(..., truncation: false)` 也会向下传递严格模式，但该
encoder 的模型可能已经由调用方加载，不能把此便利方法当作加载前检查。

## 离线来源和补丁校验

```sh
python3 scripts/verify-flux2-vendor.py
```

`Vendor/flux2-swift.files.json` 记录每个文件的 Git mode、上游 blob SHA-1、
上游/当前大小和 SHA-256。`Vendor/flux2-swift.provenance.json` 固定完整清单摘要、
上游 commit 原文及每项补丁摘要和修改范围。校验器不依赖网络或本机 checkout：

1. 验证每个当前文件的完整 SHA-256、大小和执行位，拒绝缺失、额外源文件和 symlink。
2. 按补丁逐 hunk 反向还原五个修改文件，核对上游 SHA-256 和 Git blob 标识；
   其余 201 个文件必须与上游一致。
3. 从全部上游 blob 和 mode 重建 Git tree，并验证记录的 commit 对象摘要确实
   等于固定 revision；因此完整来源清单也受提交标识约束。

与已有 MLX 校验入口一致，后续 Xcode/SwiftPM 可能产生的快照根 `.build`、
`.swiftpm` 及 Finder 的 `.DS_Store` 作为本地产物忽略，不属于待提交源码清单。
普通检出不需要初始化子模块，也不依赖外盘研究 checkout。添加快照到 Git 时应按
清单添加全部 206 个文件；父目录或上游 ignore 规则不能成为遗漏 fixture 的理由。

补丁的 hunk、摘要、大小或源码变更时必须一起更新来源记录，不能单改 SwiftPM
缓存。回退时可按逆序反向应用三个补丁，重建上述上游 Git tree；但独立回退本地
MLX 路径会破坏 D 当前的统一依赖安排。升级上游后，只有确认其提供等价的清理和
拒绝截断行为、并重新通过宿主生命周期验证，才能移除对应增量。

此文记录已实现的源码和来源保证。新增 Swift fixture 回归覆盖完整计数/批内索引、
恰好边界及默认截断兼容、空提示的模板 token 超限；是否编译和实际执行通过，以
后续构建与测试日志为准。离线源码校验通过不代表真实图像推理或内存验收通过。
