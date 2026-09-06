# 正式图像核心 B2：调用和边界

B2 将已验证的分阶段 FLUX.2 计算接入 `DInference → DRuntime → DMLXBackend`。文本与图像由同一个运行时排队，在进程内共用一个 MLX 重推理许可。没有新增生产框架包；旧 SwiftUI 应用仍使用旧生成入口，尚未接入这一链路。

## 支持范围

| 项目 | B2 固定值或规则 |
| --- | --- |
| 模型 | `mzbac/FLUX.2-klein-4B-q8` |
| 模型提交 | `ef52ee019fd1d0e75ae4deb40476ba65989716d7`，完整 18 文件清单 |
| 图像计算源码 | `Vendor/flux2-swift`，上游 `959a4af7c0721c800851c84431ffd3fa1f353f1f` 加三个最小补丁 |
| 图片 | 512×512，4 步，guidance 1；其他值明确拒绝 |
| 可调整输入 | 非空提示词、UInt64 seed |
| 文本条件 | 聊天模板后的完整 token 数不超过 512；不足补齐到 512，超过明确报错，不截断 |
| 资源准入 | 估计 8 GiB；固定硬件验证为 M4／16 GiB |
| 推理并发 | 同一运行时一次一个重任务，取消后等待计算及清理结束再交接 |
| 模型取得 | 推理只读取本地安装。下载仍是独立工具／未来应用操作 |

8 GiB 是包含余量的准入估计；内部 10 GiB 的 MLX allocator 设置控制分配调度，并非进程 RSS 硬上限。MLX 指标不包括全部 CPU、系统与 Metal 内存。

## 命令行复现

在 D 仓库根目录运行，模型、缓存、日志和作品默认使用仓库同级外盘空间：

```sh
./scripts/build-mlx.sh
python3 Experiments/Flux2Probe/download_model.py \
  --manifest Experiments/Flux2Probe/model-manifest.json \
  --destination ../D-Development/Models/FLUX.2-klein-4B-q8 --verify-only

../BuildCaches/D-MLX/Build/Products/Debug/d-infer \
  --capability image \
  --model "$(cd ../D-Development/Models/FLUX.2-klein-4B-q8 && pwd)" \
  --prompt 'A red ceramic teapot on a wooden table beside a window, soft morning light, detailed studio photograph.' \
  --seed 42 \
  --artifacts "$(cd ../D-Development && pwd)/GeneratedImages" \
  --report "$(cd ../D-Development && pwd)/Logs/image-run.json"
```

`--artifacts` 是应用提供的作品根目录；CLI 会先创建它，后端每次在里面创建“请求 UUID + 私有 UUID”的独立任务目录。后端 ID 为 `mlx.image.flux2-klein`。图片通过 JSON Lines 写到 stdout，进度与生命周期写到 stderr，完整请求、参数、产物引用、终态、取消延迟与内存记录写到 report。文本模式默认不变，仍将文本写到 stdout。

`--repeat 3` 连续验证三个独立任务；`--cancel-after-steps 1` 在收到第一步完成事件后请求取消。信号和消费者是异步的，可能已进入下一计算段；正在执行的 GPU kernel 不保证立刻中断。取消不会被记作成功，任务槽要等到 `release` 完成才归还。

应用调用时构造 `MLXImageBackend(configuration: .init(artifactDirectory: existingRoot))`，和 `MLXTextBackend` 一同注册到一个 `InferenceRuntime`。提交普通 `ImageRequest`，消费 `progress` 和 `artifact`，最后读取权威 `outcome()`。不要自己再并行调用旧 MLX 推理；执行许可无法约束不使用它的第三方／旧代码。

## 资源与文件所有权

1. 准入只检查请求、文件列表、文件身份、配置与 tokenizer 等元数据，不加载模型。
2. 执行取得许可后，对全部 18 个文件流式重算 SHA-256。检查前后身份与目录变化，不采用文件名或 revision 标签代替内容校验。
3. 分词先检查完整长度，再加载文本编码器；编码完释放编码器，再加载扩散模型；扩散结束释放模型与条件，再加载 VAE 解码。准备初始噪声时上游 API 需要短暂加载 VAE，沿用已验证计算并将其限制在独立作用域。
4. 每任务独立持有随机状态。模型初始化和各计算调用使用同步随机作用域；在生成初始噪声前重置该任务的 seed，避免初始化消耗随机数改变作品。没有更改全局 seed。
5. `execute` 返回／抛错前同步 GPU 与 CPU stream；`release` 再清除 Flux2 attention mask cache、MLX 空闲缓存并恢复 allocator 设置，最后归还许可。
6. PNG 先在私有临时文件中写入、flush、完整读取并用 ImageIO 解码核对，再以不覆盖已有文件的方式发布。只传文件引用，不向公共接口泄露 MLXArray。
7. `release` 绝不删除图片。宿主在后端空闲（例如队列全部结束或 shutdown）后显式调用 `cleanupUnpublishedArtifacts()`；它仅处理此 backend 实例跟踪的未发布文件，核对文件身份，不扫描或递归删除用户作品根目录。

已发布 PNG 即使遇到消费者抛错或通知失败仍会保留。CLI 在写 stdout 之前记录产物引用，断管不会使图片失去报告索引。发布后发生目录 flush／访问故障也不能回滚删除已有文件；错误提供已发布目录用于诊断。

安装目录要求只含固定清单文件，不接受符号链接、额外权重、下载状态或 `.DS_Store`。从准入到校验末尾有修改检测，但其他进程仍可能在校验完成后修改文件；应用应把安装版本视为不可变目录，更新时安装到新版本位置，不能原地修改正在使用的模型。这里没有声称可防止其他同权限进程的任意竞争写入。

## 验证入口

```sh
./scripts/test-foundation.sh
./scripts/test-mlx.sh
python3 scripts/verify-mlx-cli.py
python3 scripts/verify-image-cli.py
```

`test-mlx.sh` 的第一可选参数是文本模型目录，第二可选参数是图像模型目录；缺失／损坏固定模型直接导致验收失败，不能用跳过真实测试代替通过。真实测试共用串行测试容器，避免不同 suite 同时接触进程级 MLX 状态。

图像 CLI 验证器支持 `--offline-only`，只运行参数与帮助检查；完整模式包含三轮同进程、取消、SIGINT、SIGTERM、断管和预算拒绝。报告目录必须是新的，已有图像和证据不会被清掉。

原始图像 B1 仍保留在 `Experiments/Flux2Probe`，作为历史对照，生产实现不依赖该实验的可执行程序。数值 fixture 直接测试生产计算 helper，来源与补丁见 [依赖记录](FLUX2_DEPENDENCY_PATCH.zh-CN.md)。

## 下一阶段

可靠出图 Alpha 将复用旧界面，接入上述公共请求与运行时，再补模型安装状态、外盘授权、任务列表、作品自动保存和重启恢复。B2 的任务图片目录与 CLI 报告不是完整作品库或项目文件。参考图编辑、批量创作、节点编辑和 AI 助手仍按后续路线推进。
