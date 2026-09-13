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

下载、独立环境安装及真实资源窗口已集中询问，尚无批准回复；不提前下载/安装/加载。不把以往音频下载授权外推到视频。媒体CPU工作不依赖这项批准。

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
