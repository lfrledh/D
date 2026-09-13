# D-VIDEO-V0-01：一条可靠的短视频薄后端

状态：2026-09-14用户批准实施；隔离准备中，未接入源、未验收、未推送。规格 `stage-r1`；媒体契约 `media-r1`。源基线 `cc663f7a9e54bb9506b4fdb40e8e7d7198742a8f`，执行准备SHA由外部派工记录填写，避免自引用。

## 终点与阶段跨度

提供显式参数的纯文生视频请求，经现有单重任务运行时得到经过独立解码校验的无声MP4与实际运行配方。先命令行，不启用工作台视频入口。模型请求、进度、取消/drain、资源释放和产物文件交付属于同一闭环；时间线、首尾帧、I2V、编辑器、音轨合成、新音乐模型不在范围。

上一ALIGN批证明可以把契约、后端、持久化/界面和回归合成阶段，但布局返工及真实验收需足够审核容量。本阶段适度扩大纵向交付，限制为一个新模型；媒体/模型可并行，数值修正与真实生成仍是先后门槛，不把不确定性同时扩至UI。阶段完成不等于视频产品或所有Mac验收。

## 证据与起点

- Lead工作树 `/Volumes/CodexProjects/Codex/D-Worktrees/D-VIDEO-V0-01`；分支 `codex/d-video-v0-01`；源 `codex/inference-foundation`。共享Git仅Lead写。
- 外部证据 `/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-VIDEO-V0-01/run-20260913T152419Z`，下称R；保护副本/完整差异见 `protection/start.json`。个人scheme为唯一未暂存差异，开始SHA-256 `ca3635d88aa5a15397b90e528667c66c0e6db7e596176e885c79d194b544206c`；不暂存、不还原。
- ALIGN终点由实际 `stage-final-receipt.json` 核实，源/远端cc663f7。原受测d3a80942df49f7719a6ea335a05cb7dfc273c812到cc663f7仅结案文档；复用上一阶段证据，不重新审计全库。
- 普通D、模型原件、历史日志不改。更新源前后核对HEAD、索引及scheme内容/摘要/差异。源仅快进接纳已验收组合；禁止stash/reset/restore/rebase/cherry-pick/squash/amend/清理/强推。

## 模型候选与门槛（尚未实测）

候选Wan2.1 T2V-1.3B，官方权重revision `37ec512624d61f7aa208f7ea8140a131f93afc9a`，完整必要文件17,567,083,322字节。来源 [官方权重](https://huggingface.co/Wan-AI/Wan2.1-T2V-1.3B/tree/37ec512624d61f7aa208f7ea8140a131f93afc9a)，Apache2；适配参考 [mlx-video固定MIT源码](https://github.com/Blaizzy/mlx-video/tree/87db56a51758fefb748a359b90a5283bb8ba4837)；官方算法参考Wan2.1 `9737cba9c1c3c4d04b33fcad41c111989865d315`。

2026-09-14用户已分别批准指定下载/独立环境/视频BF16与FP32数值验证，并确认普通D退出、其他AI/GPU空闲；批准来源见R/authorization.json。现正在下载/安装，尚未加载。不把以往音频下载授权外推到视频。媒体CPU工作不依赖这项批准。

已核实源码风险（不是本机推理结果）：
1. 参考MLX实现把T5 BF16全权重升FP32，单编码器临时约22.7GB；转换又保留源副本。需保留BF16存储，按层转换/释放并测峰值，禁止静默Q8降级。
2. 参考MLX VAE整段两次上采样输出4T，官方因果缓存首帧语义为4T−3；17帧请求可能输出20帧。须先对照1/2/5 latent→1/5/17，不以裁掉3帧代替修复。
3. tokenizer硬编码在线目录及静默截断不符合D契约。固定本地分词器；正负条件分别检测特殊token在内512上限，过长明确拒绝。
4. RoPE、T5注意力及采样器需独立小张量数值对照，跨框架seed不同不能假称逐像素确定。

待数值门槛通过才冻结真实profile：832×480、17帧/16fps、50步、UniPC、shift8、guidance6、seed42；17帧MP4时长为17/16秒。文本/扩散BF16、VAE FP32；不得降低现有图文音频精度。更多几何/帧数通过模型与adapter声明，不以M4/16GiB作产品上限；超预算显式测试配置与实际加载失败分开记录。未支持I2V/音频必须拒绝。

## 共享职责

Lead拥有DInference契约、能力、CLI装配、DRuntime兼容、测试策略、模型profile、项目明确拒绝video及全局文档；DRuntime不加入媒体细节。Worker只写准确清单，分别受限CLI、独立外盘树/输出/缓存，网络关闭；请求与turn_context均核验模型/档位。原生只读调查不作为写隔离证据。

首个就绪包MEDIA使用Sol/high：AVFoundation时间基、Swift6并发、文件发布/取消有较高风险。模型包须先解决VAE/T5契约及下载批准，未就绪不凑并行。CPU独立工作允许并行；重型构建/推理仅Lead排队。每包初交+最多两轮针对性修复，之后至多一次有界Lead接管；重要Lead实现非实现者审阅。15分钟执行时限不重置预算；权限/身份/未知副作用先停报。

## MEDIA：冻结实施规格 media-r1

任务标识 `D-VIDEO-V0-01/MEDIA`、run `R/media`；独立执行树/完整准备SHA在job.json与preflight证据。只实现：
- `Backends/MLX/Sources/DMLXBackend/VideoArtifactWriter.swift`（新文件）。
- `Backends/Video/Tests/VideoMediaChecks.swift`（新文件，自包含CPU行为检查）。

不改 `VideoFrameSequence.swift`、本任务规格、任何其他Swift/工程/依赖/脚本/签名/用户文件。读取 `VideoFrameSequence.swift`；文件安全可按需参考 `ImageArtifactStore.swift`，不能修改它。不安装依赖，不读取用户资产。Swiftc直接编译这两个生产文件和一个检查文件，不构建全包/MLX/App。输出和缓存只在R/media/output与R/media/tmp；显式 `-module-cache-path`。模块仅Foundation/AVFoundation/CoreVideo/CoreMedia/VideoToolbox/CryptoKit/Darwin，无第三方依赖。

冻结调用入口（内部enum VideoArtifactWriter，值型输入输出，真正async抛错）：
```
static func encode(_ sequence: VideoFrameSequence, to destination: URL,
                   limits: VideoMediaLimits) async throws -> VideoMediaInspection
static func inspect(_ url: URL, matching sequence: VideoFrameSequence,
                    limits: VideoMediaLimits) async throws -> VideoMediaInspection
```

输入是子进程已结束后、私有任务目录中的完整RGB8 raw文件。描述值见现有VideoFrameSequence，整数fps p/q，top-down RGB、无padding/alpha。仅这两个入口读指定文件，不扫描目录、不执行/启动进程、不联网、不触碰GUI/模型。媒体层支持正数整数几何/帧数，由编码器如实拒绝不支持配置；模型要求如4n+1不放这里。caller传入帧内存/输出字节/时限预算，全部校验有限正值，不把开发机内存硬编码成上限。

媒体规则：
- 完整raw字节数精确N×W×H×3，整数溢出先拒绝；拒绝额外/不足字节、目录、符号链接、身份/mtime/摘要变化。每次仅读一个帧，流式SHA256，不整片Data读入。
- 输出为H.264 MP4，一个视频轨、零音轨、无旋转/翻转。软件编码供此CPU入口使用，禁止额外GPU/Metal计算；VideoToolbox明确关闭硬件编码。禁止B帧；码率由像素/帧率推导且校验，不宣称无损。
- V0把神经网络输出的RGB8显式解释为full-range Rec.709 display RGB；实际转YUV且写709 primaries/transfer/matrix，保持上下/通道顺序。这是解释政策，不证明训练源色域。不得贴标签冒充做过色彩转换。
- 第i帧PTS=i×q/p，样本时长q/p，完整片尾N×q/p；1帧必须有时长。使用真实sample duration或等价可靠终止，不以最后一帧起始时间当总长。fps 30000/1001保持有理数，不取整。
- `encode`在caller已有独立目录内创建自有随机暂存/私有子目录，完整编码并独立读取验证后才排他原子发布到显式destination。不创建/修改外部用户目录，不覆盖已有文件/目录/符号或硬链接。父目录身份前后检查、目录FD锚定发布；路径交换不能写入未知替换目录。只删有身份凭据的自有未发布文件，发布后即使flush/回报失败也保留已发布结果并说明位置。
- `inspect`独立使用AVAssetReader完整解码，验证全部帧的PTS/count/end、尺寸/track/codec/color/方向/无音频；不只检查AVAssetWriter completed或文件非空。digest属于MP4本身，不写回自引用。
- deadline覆盖等待ready/finish/读取；取消停止并drain所有本次AV工作、关闭FD后抛CancellationError；timeout单独VideoMediaError.timedOut。工具不得创建子进程。错误不交付成功；报告/发布失败不得删原件。Swift6隔离靠单一所有者，不新增unchecked Sendable/nonisolated unsafe以压诊断。

行为与冻结验收：
| 输入/操作 | 必须结果 |
|---|---|
| 64×64、1/2/17帧、16fps | 解码帧数一致；时长分别1/16、2/16、17/16 |
| 3帧30000/1001fps | 样本PTS/总时长按精确有理数；误差至多容器一个timebase tick且报告实际值 |
| 红绿蓝黑白灰+上下非对称角标 | 从解码中央色块验证通道/范围，每通道绝对误差≤12（8bit），灰阶单调；方位角标不倒置。边缘不参与压缩色差断言 |
| 中文、emoji、空格路径 | 正常编码/读回，输入摘要及已有文件保持 |
| 错摘要、raw截断/尾随、无效/溢出参数、符号链接 | 明确失败，无输出发布 |
| 已存在目标、同inode硬链接目标、目标目录 | 拒绝覆盖，旧文件字节/摘要不变 |
| 预取消、任务中取消、极短正timeout、输出字节预算不足 | 失败/取消分类真实，原件保持、无假成功；任务工作结束后返回 |
| 损坏MP4、错尺寸/帧数期望 | inspect失败；不改变MP4 |

测试临时目录通过唯一 `D_TEST_TEMP_DIR` 下创建独立子目录；不在仓库生成缓存/产物。受控失败夹具是获准测试，不等于权限事故。实际沙箱拒绝/未知副作用必须先停报；唯一预批缓存入口已显式提供，不能临时猜别处。响应含命令、结果、允许文件、异常/未覆盖、进程状态；不要改规格或自行commit。

Lead额外核查真实命令和API语义、检查是否以函数返回替代完整异步结束、独立输入保护与颜色/时间反例。媒体CPU通过只证明媒体交付，不是模型生成、GPU、GUI或视频产品验收。

## 恢复检查点

已完成：起点/历史结案/保护核对、隔离Lead树、固定上游只读调查、媒体接口与冻结任务。未完成：实施Worker预检/代码/CPU验收；模型下载审批/适配/数值与真实生成；组合审核/源接纳/push。源与普通D不变。模型/资源问题已集中询问，未答复不执行相关操作。下一动作：准备提交、媒体受限CLI预检；Lead推进可独立契约。最终SHA及各运行时间/可观察模型/用量仅按证据填写，隐藏解析和订阅费用unknown。


## VAE：冻结实施规格 vae-r1

任务 `D-VIDEO-V0-01/VAE`，stage-r1，独立工作树/完整基线见R/vae/job.json。Sol/high，初交+2针对性修复，15分钟每轮；Lead负责真正MLX数值执行，不能通过改容差/参考消除失败。

只可改 `Backends/Video/Vendor/wan21/vae.py`，只可新增 `Backends/Video/Tests/test_wan_vae_reference.py`。禁止改任何其他文件、原始参考源码、权重、规格、Git元数据、环境/依赖/权限；不联网/下载/安装/派工。读取该固定vendor，按需只读R/source/wan-official/wan/modules/vae.py 与本节。不导入整个上游包。源码许可证/来源由Lead保存，Worker仅回传改动摘要，Lead补patch manifest。

目标：修复Wan2.1 T2V的因果解码，与官方首帧/跨latent缓存匹配，保留原参数key与FP32运算。不是Wan2.2、编码/I2V或新VAE框架。

冻结接口：保留 `WanVAE.decode(z)` -> `[B,3,4T-3,H*8,W*8]` clipped [-1,1]；新增 `WanVAE.decode_chunks(z)` iterator，T>=1，每次给首块1帧、以后4帧，单次调用cache私有，不跨任务复用，提前关闭生成器时释放缓存。`decode`可组合这些块，正式runner使用chunks以减少完整帧驻留。层级 `Decoder3d.__call__(x, feat_cache=None, feat_idx=None)` 支持官方缓存；Resample上采样首块sentinel/后续cache语义按官方实现，不能把全量4T裁到4T−3。RMS_norm的F.normalize等价规则也需核对极小输入：norm=max(sqrt(sum(x*x)),1e-12)，不是sqrt(max(sum,1e-12))。

`decode_tiled`旧非因果假设不得继续被误用：该入口在这个窄T2V vendor明确抛NotImplementedError说明空间/时间tiling尚未数值验收，不静默忽略配置或保留4T错误。正式V0不依赖tiling；后续更大尺寸可独立实现，不以本机RAM作为模型上限。不得修改未纳入T2V的encode逻辑或宣称I2V已修复。

测试仅生成小合成张量/小层参数，固定随机输入，从官方Torch CPU实现得到独立参考，经轴转换载入MLX。不得让参考调用待测函数。脚本通过显式 `D_WAN_REFERENCE_VAE` 读固定官方文件；MLX vendor路径显式 `D_WAN_VENDOR`，避免加载旧工作树。测试命令由Lead在已批准独立venv执行，Worker仅用tokenize.open+compile内存语法检查，不运行MLX/模型/GPU；所有测试代码须设Torch CPU、MLX CPU及小线程数以便Lead先做小对照。不加载真实权重。

冻结断言：
- `CausalConv3d`/上采样Resample/ResidualBlock/Decoder3d的cache首步及后续，权重按真实O,I,D,H,W→O,D,H,W,I及Conv2d轴顺序转换；不能为通过倒改官方文件。
- 1/2/5 latent帧分别产出1/5/17帧；独立相同输入对照全部帧而不只shape。小维度Decoder与官方，FP32 `atol=3e-4, rtol=3e-4`，显式记录最大绝对误差；零/极小norm另按期望验证。
- 一次decode与chunks组合一致；重复调用/提前停止后新调用不串cache；帧间连续性与官方输出一致，不以音视频播放器肉眼代替。
- T=0、无效rank/channel拒绝，不返回假空片；NaN/Inf若触发异常需明确，不把坏帧作为数值通过。
- 测试用官方导入不执行CUDA训练/预训练加载；依赖若缺由Lead处理，不Worker安装。

回传修改、内存编译结果、未执行数值门槛、风险/异常与本任务进程状态。只有Lead实际对照后才可接纳。该任务不是整个video runner；模型转换/T5/DiT/采样器/媒体/Swift接线归Lead或后续明确包，不改它们。

## NUMERIC：冻结实施规格 numeric-r1

任务D-VIDEO-V0-01/NUMERIC，stage-r1，Sol/high。只改Vendor/wan21下text_encoder.py、attention.py、rope.py、transformer.py、wan_2.py、scheduler.py；只新增Backends/Video/Tests/test_wan_numerics.py。config.py、vae.py、PROVENANCE、转换器及其他文件禁写。准确前缀Backends/Video/Vendor/wan21/。独立工作树/完整SHA/运行根见R/numeric/job.json。无GPU/真实模型/环境/网络/安装/Git写；Worker只做tokenize.open+compile内存检查，Lead执行小Torch/MLX CPU对照。初交+2修复，重要边界问题先问Lead。

目标是固定1.3B纯T2V数值，保持现有调用形状与参数名称，不增加模型家族或采样器功能。T5权重BF16；DiT主体BF16、时间分支/Head/modulation/原FP32 norm保留FP32；VAE不在此包。Lead负责严格加载与生命周期。

已确认待改：T5 norm采用官方先FP32归约/乘输入、转weight dtype后乘weight的舍入顺序；QK及bias遵守BF16层的舍入，softmax单独FP32，再转回，不将整个T5升精度。DiT patch与text Linear在调用前转权重dtype。RoPE cos/sin保持FP32，从小NumPy FP64角度生成，不引入MLX float64或BF16缓存；时间sinusoid同官方FP64角度后FP32。UniPC order2/flow/bh2/shift8，schedule按官方取整顺序，未经验证的其他scheduler不对外暴露。

测试读固定官方R/source/wan-official/wan/modules/{t5,model}.py及wan/utils/fm_solvers_unipc.py。可用AST抽取所需官方定义(避开CUDA wrapper及无关依赖)，或只对非数值ConfigMixin/register_to_config/SchedulerOutput做小stub；不得重写数学公式作为参考，也不能改官方文件。依赖已安装Torch/MLX/numpy/einops；不增加diffusers依赖。测试通过D_WAN_VENDOR和D_WAN_REFERENCE_ROOT显式路径，设Torch CPU/MLX CPU、小线程，固定小张量共享输入/权重。

冻结验收组：
- patchify与官方Conv3d坐标/权重、unpatchify顺序，包含非对称输入；FP32 atol/rtol3e-5。BF16应保持输入前转cast，不以形状测试代替值。
- RoPE三个轴、Head/time/norm小共享权重对照；FP32 atol/rtol3e-5，时间整数0/1/499/999，RoPE含非零不同轴。cached/uncached crossKV等价。
- T5小norm/attention/完整block：两种mask维度、posbias、FP32与BF16及极小值；FP32 atol/rtol3e-5，BF16 atol/rtol0.02，报告各组maxabs/relative/dtype和finite。BF16原生舍入差异不等于可静默用FP32 logits代替。
- UniPC完整50steps/shift8/order2与短4steps：完全相同timesteps，sigma atol1e-7，共享每步小FP32模型输出和初始噪声，逐步样本atol/rtol3e-5；重复新scheduler不串状态。不用同seed声称跨框架噪声一致。

如果容差不满足，交真实失败和实现/官方差异，不改容差不改参考。不运行真实权重、不执行CUDA wrapper，Worker自身仅检查语法；Lead独立执行/审核。正常缓存/临时输出仅R/numeric/output和tmp，预先已确定；未知权限/副作用暂停，不重复pgrep。回传代码、解释、内存编译、异常与自有命令状态。
