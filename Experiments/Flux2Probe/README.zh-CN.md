# B1：FLUX.2 Klein 图像硬件探针

这是固定模型的可执行实验，用来验证 D 下一条图像推理链路的数学路径和本机资源需求。它尚未接入 `DInference`、`DRuntime` 或旧 UI，不是新增的生产框架库。完整结果见 [硬件报告](../../docs/IMAGE_PROBE_RESULTS.zh-CN.md)，旧路径问题见 [源码审阅](../../docs/research/IMAGE_BACKEND_REVIEW.zh-CN.md)。

## 固定输入与来源

- Swift 实现：[mzbac/flux2.swift](https://github.com/mzbac/flux2.swift/tree/959a4af7c0721c800851c84431ffd3fa1f353f1f)，提交 `959a4af7c0721c800851c84431ffd3fa1f353f1f`。MLX 仍使用 D 的同仓固定修复版；其他解析结果保存在本实验 workspace 的锁文件中。
- 权重：[mzbac/FLUX.2-klein-4B-q8](https://huggingface.co/mzbac/FLUX.2-klein-4B-q8/tree/ef52ee019fd1d0e75ae4deb40476ba65989716d7)，提交 `ef52ee019fd1d0e75ae4deb40476ba65989716d7`。18 个运行文件共 9,426,536,934 字节，文件大小和 SHA-256 固定在 `model-manifest.json`。
- 参数：512×512、4 步、guidance 1、timestep scale 0.001、完整 512 token 文本条件、默认 seed 42。提示词固定为窗边木桌上的红色陶瓷茶壶。
- 使用公开底层模型、去噪和解码 API，保持上游数学运算。两个 internal schedule 便捷函数按固定源码摘录；出处见 Swift 文件顶部，Apache-2.0 文本保存在 `UPSTREAM-LICENSE`。
- 量化权重仓库的该提交没有 model card 或许可证文件。官方基础模型 [FLUX.2-klein-4B](https://huggingface.co/black-forest-labs/FLUX.2-klein-4B) 标为 Apache-2.0；这不等于量化仓库附带了同一文件。本实验只记录来源与本地验证，不将 9.43 GB 权重提交或随产品分发。

## 构建、下载与验收

在 D 仓库根目录执行，所有构建缓存、权重和输出默认位于同级外置 SSD 目录：

```sh
./Experiments/Flux2Probe/build.sh
python3 Experiments/Flux2Probe/download_model.py \
  --manifest Experiments/Flux2Probe/model-manifest.json \
  --destination ../D-Development/Models/FLUX.2-klein-4B-q8
python3 Experiments/Flux2Probe/validate.py
```

下载器使用标准库，最多 4 连接，精确 HTTP Range、断点保留、完整文件摘要验收后原子发布。拒绝符号链接、额外模型/配置文件和未知下载状态，不执行远程模型代码。每个目标目录同时运行一个下载器。`--verify-only` 完全离线、不写入目标目录；中断会取消排队任务，活跃网络读取仍受请求超时限制。

`validate.py` 使用全新带时间戳的日志目录，先重新校验全部模型文件，再顺序执行：tiny 数值对照、同进程三轮完整生成、第一步求值后主动停止。正常三轮使用同一 seed，比对 PNG 摘要、实际形状和释放后活跃分配；停止场景检查后续步骤、解码与后续轮次没有启动。仅 `summary.json` 同时包含 `complete: true` 和 `passed: true` 才表示这组实验全部结束且满足断言。程序读取并校验实际报告与产物，不能用构建成功替代运行。

可通过 `--binary`、`--model`、`--fixture`、`--reports` 指定其他绝对位置。构建支持 `D_DEVELOPMENT_ROOT` 与 `D_FLUX2_BUILD_ROOT`；使用覆盖路径时应把相应参数传给验证器。不要只复制二进制而遗漏相邻的 Metal 资源。

## 单次运行与观测边界

二进制 `--help` 给出参数；`--repeat` 只接受 1…3，后续输出名在扩展名前添加 `-2`、`-3`。程序提前检查所有目标，不覆盖已有文件。`--stop-after-step 1` 返回 130，代表主动停止已求值的第一步；它不是生产运行时取消或信号处理的验收。

文本编码器、Transformer、VAE 分别由同步函数作用域拥有，阶段出口先求值，只让结果数组跨越。为复用上游潜变量准备 API，短暂加载一次约 168 MB VAE，准备后释放，解码阶段再单独加载。每步求值和取消检查发生在明确边界，不能中断正在执行的 GPU kernel。

报告分别记录 MLX 活跃分配、缓存和区间峰值，以及 Darwin 进程生命周期 RSS 高水位。两者不能相加。10 GiB 的 MLX `memoryLimit` 是分配调度设置，不能保证进程不超过该值；父进程每秒采样 RSS，默认 13 GiB 阈值、900 秒超时，触发时终止并回收隔离的子进程。该保护不是生产后端的预算准入实现。

固定上游版本存在没有公开清理入口的静态 attention mask cache；报告如实保留残留分配，并用同进程固定负载的重复观测检查趋势。稳定三轮不证明所有形状、长期运行或整个进程无泄漏。tiny 对照使用上游已跟踪的 float32 参考数据，不能替代真实 q8 模型质量和完整精度一致性评估。
