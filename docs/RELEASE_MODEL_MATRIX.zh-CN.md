# 首发模型能力矩阵

2026-10-02 · D-RELEASE-FREEZE-01 · **候选，尚未功能冻结**。最终代码与证据版本见[本轮记录](tasks/D-RELEASE-FREEZE-01.md)；当前停点仅以[当前行动](CURRENT_ACTIONS.zh-CN.md)为准。

模型能力、D已实现的profile、资源是否就绪、本机实测、Quick/Canvas原生验收分开。下表不是九模型均已交付的声明。16GiB开发机不限制其他Mac的合法请求；预算不足明确报告，不自动换模型、降精度或丢条件。

## 九个冻结目标

| 模型／精确实现范围 | 输入 → 输出与关键控制 | 实现及资源 | 本轮验证／缺口 |
|---|---|---|---|
| **Qwen3.5-9B**；原始BF16及独立MLX Q4 profile | 原生角色消息、按序文字/多图/时间戳视频、工具声明/调用/结果、型号特有思考控制 → raw/reasoning/final/toolCalls；输出上限、seed、采样与上下文预算。非法组合拒绝，不自动执行工具 | MLX LM 3.31.4；原始混合dtype（727 BF16＋48 F32控制张量）与Q4固定独立revision；两者资源已取得，SSD与常驻显式分开 | r2 Q4正式runtime四请求通过：最终JSON、双图明暗顺序、视频描述、工具结果往返42；精确代码2f2855b，1个测试。r3 b347c38原始权重正式Runtime取消→JSON→双图→短视频→工具结果完成，1方法836.707秒，各次active/cache归零。旧视觉后16B残留已由所有权修补关闭，旧失败保留；视频夹具按2fps只采得1帧，回复将其描述为静态图，因此仅证明完整所请求输入和生命周期，不证明时序理解质量；41ad630普通App的Quick/Canvas均真实生成title/answer记录并保存冷重开，原生参数为Q4、思考off、seed42、输出256、显式预算15GiB；不是27B或其他精度的证明。r4另在4bc9b9f原始模型/SSD完成真正4帧时间顺序请求131.489秒，回答先红后蓝，active/cache0；已修预处理时间戳与语言RoPE映射 |
| **Qwen3.8-27B**；原始BF16及独立MLX Q4 profile | 同一VLM消息形状；3.8独立 reasoning_effort/preserve_thinking 映射，拒绝不适用的9B开关；不冒充9B实测 | 已登记与装配，Qwen3.5架构读取3.8实际配置；完整原始55.586GB权重已取得并校验，SSD与常驻显式分开 | r3 b347c38原始BF16正式Runtime取消→JSON→有序双图→工具结果通过，1方法361.288秒，各次active/cache归零；原始线性/注意力块零容差对照通过。r4另在4bc9b9f原始模型/SSD真正4帧时间顺序请求293.433秒通过、active/cache0；未验长上下文极限及同包GUI，不拿9B或Q4替代 |
| **FLUX.2-klein-4B**；原始BF16、既有Q8分开 | 文字＋可选有序参考图 → PNG；尺寸、步数、seed，参考图有共同校验 | 原始Klein 4B为蒸馏模型；新增BF16固定清单，Q8旧路径保留。BF16原件15.980GB已取得/校验；编码器和扩散主干均已SSD逐层接线 | r2源级A/B确认Float32 Steel attention缩放顺序差异；经非实现者复核保留上游实现并绑定新版本唯一严格PNG。生产3周期通过、active/cache归零；旧失败保留。r3 f14bcd0正式Runtime同次通过：加载取消后释放、512²/4步/seed42 BF16完整生成、双参考生成，PNG真实解码、原件不变、各次active/cache归零；不是同包原生UI验收 |
| **FLUX.2-dev**；原始BF16 profile | 文字＋可选有序参考图 → PNG；独立guidance、步数、尺寸和seed，不沿用Klein的固定512 token规则 | 完整原始Pixtral/BF16扩散/F32解码，固定32文件112.823GB已取得校验；逐层SSD保持40文本层/8双48单DiT及原条件 | 原始代表块常驻/SSD数值对照4.351秒通过；完整Runtime取消/50步文生/50步双参考实测进行中。H31已关闭；不能以块级对照宣称整模型通过 |
| **Wan2.1-T2V-1.3B**；既有视频BF16编码/扩散、FP32解码profile | 文字＋负面提示 → 无声MP4；尺寸、帧数、帧率、步数、guidance、shift、seed | 复用既有MLX视频后端和运行环境；不显示I2V端口，不接纳未经支持的首帧 | 历史真实链路保留；r3真实原件经正常内嵌转换桥103.115秒产出1,261张量，生产模型库验证1,262文件通过，原件不变、资源许可释放；r3固定文件副本的普通App准备/登记已验。r4完整原仓额外内容隔离及所需树校验18项CPU通过，实际完整目录登记/重开6.822秒通过；完整原仓原生面板与本包视频生成未验 |
| **LTX-2.5**；单阶段dev完整权重profile | 文字＋可选首帧 → 带音频MP4；独立视频参数与显式扩散权重流式开关；不支持末帧，输入即拒绝 | 固定ltx-2-mlx 0.15.12，扩散核心BF16，其余精度按文件头记录；当前实验性diffusion视频解码器，2.5 audio FF及Gemma4资源校验；不以LTX2.3 Q8替代 | 70.937GB原资源已取得，48层Gemma4/49隐状态分阶段实现已整合并小型数值对照；生产模型库实际准备56.878秒通过。**完整文生/首帧生成尚未完成，冻结门槛未达** |
| **MiniMax H3 Base · FL2VA / 原始BF16** | 文字＋可选首帧／尾帧（分别冻结）→ 带音频MP4；显式流式加载、合法尺寸/帧数、步数、seed | 原始50层公开Base；公开Base本身为CFG蒸馏，不冒称未公开非蒸馏版；不是Ref2VA多参考路线。约144GB资源已校验 | 历史真实生成/取消恢复；本轮修复真实MP4的Store时长误判，保留原件。r2首尾帧为256²两步连通证据，不能替代512²22帧50步完整代表请求；该完整请求与GUI仍待验 |
| **MRT2 small/export-v1** | 意图、可选音符与和弦结构 → 48kHz双声道WAV；seed、1…400个25Hz条件帧 | 真实音符条件编码，非把和声拼进prompt；导出profile最长16秒，固定采样配方，鼓当前不受约束 | 既有真实有条件/无条件生成保留；是近似音高/起音控制，不承诺精确音符、声部或音色；非完整MRT2所有导出/流式能力 |
| **ACE-Step 1.5 XL SFT · F32 / no-LM** | 描述＋歌词/语言、BPM/调式/拍数、独立风格参考音频；cover原声或repaint区间 → 48kHz双声道F32 WAV | 原始XL权重实际F32；MLX扩散/VAE与MPS条件处理。固定官方源码，无模型侧动态代码/自动下载；不接LM，不冒充turbo/base | r3逐张量准备、分阶段编码/解码、全32层F32主干SSD加载已经实测。六秒/50步完整生成、歌词+参考、cover、repaint各357–366秒；正式Runtime取消→释放→完整歌词参考生成通过。原始滑动/全注意力块与常驻输出/cache/RNG严格对照通过。r2的单步冒烟/50步受控停止保留历史，不再是最新能力结论。尚未同包原生App试听，不能由波形有限代替听感质量 |

ACE当前原声与参考输入为48kHz双声道PCM WAV；F32须有限且在[-1,1]，不隐藏重采样或截幅。生成使用0.1秒网格，编辑按原声精确帧时钟；请求时长0.1–600秒。原生解码尾长/短缺分别记录，输出不偷偷裁切到“看似相同”。这些是该profile的明确边界，不是所有音频模型的通用限制。

## 单一执行真相与来源

Quick与Canvas实例化同一个 `WorkflowRegistry` 操作，使用同一端口、字段和请求构造。说明卡片是投影；自然语言detail/default展示串不被解析执行。旧 `d.text.generate`、旧Qwen2.5、LTX2.3和SA3继续兼容，不能把旧成功计为新冻结目标通过；既有标签键不因模型实名改变。

| 家族 | 当前执行来源／固定版本入口 |
|---|---|
| Qwen | `TextModelProfiles`、`WorkflowLanguageRecipe`、`MLXQwenVLMBackend`；9B原始c202236235762e1c871ad0ccb60c8ee5ba337b9a、Q4 8b2b98c00a6b4d291155e4890773ca8f769aee53；27B原始1d4bf0f2ff6012fd82039f2fa52739d0dd7c60c0、Q4 10c35caafbb80f7dc6a7a432cdd11af10a6d4818 |
| 图像 | `WorkflowImageRecipe`、`LocalImageModelInventory`／`LocalFluxDevInventory`、各自后端；Klein BF16 e7b7dc27f91deacad38e78976d1f2b499d76a294，Q8 ef52ee019fd1d0e75ae4deb40476ba65989716d7；Dev 26afe3a78bb242c0a8bb181dcc8937bb16e5c66c |
| 外部视频 | `WorkflowVideoRecipe`、`ExternalVideoExecutionProfile`、`ExternalVideoBackend`；`Backends/Video/Adapters/Resources`中的固定清单。H3 42ed227ee7df40d41602854ae760620d6eb651fe；LTX2.5 e378b7e1b50fcb1795fce74219b40bb0b1ede1e2；实现源码与补丁随准备引擎记录 |
| Wan／MRT2 | 既有`VideoRequest`／`AudioNoteSequence`、对应后端与导出运行环境；模型清单在正常开发资源集，旧真实证据见当前行动历史索引 |
| ACE | `WorkflowACEOperation`、`ACERequest`、`ExternalACEBackend`和薄Python适配；XL d06de46b4622f781cf07f4a013a67d591ca52819，共享编码器/VAE 19671f406d603126926c1b7e2adc169acbcade22，官方源码ca1e85fe9430179831e6bc6be790c332190a3866 |

所有路径仍经过既有安装使用权、DRuntime队列/取消、输入快照及Store发布；普通处理节点不伪装成模型。输出的实际profile、revision、条件摘要和执行参数进入运行记录。新增模型权重不进入App或Git；既有Pitch引擎评估权重、依赖封装和渠道发行责任不被本表解除。

## r2/r3 能力承接与准备边界（历史证据；新增状态见上表）

- `release-model-catalog.json` 通过现有 Models/Resources 载入：九家族、12个固定精度条目、228文件；SHA-256 与 Git blob SHA-1 按来源区分，多仓库依赖使用各自 revision/path。ModelLibrary 沿既有续传、原件校验、目录授权、安装使用权。旧 Klein 索引兼容，不把下载完成等同执行就绪。
- Quick/Canvas共用 `WorkflowLanguageMessageForm`、同一操作/校验及安装身份绑定。选择异步返回带代次保护，重新登记目录取代同身份旧安装；缺失/取消不自动选另一个模型。
- VLM消息保留原生role、媒体顺序、工具调用和结果关联；Qwen9B的enable_thinking、27B的reasoning_effort/preserve_thinking按固定上游分别映射。**JSON提示+最终结果解析验证不是原生约束解码**。raw响应以独立类型化资产保存，不塞进4MiB metadata；64MiB资产解析预算及工具JSON/工作流datum预算仍是明确应用保护限制，超预算失败不静默截断，不宣称无限输出。跨项目复制保留资产字节。
- 文本/图像/MRT2/ACE固定原始目录可经模型库校验导入。视频原始目录下载标为`preparationRequired`，不能领取运行租约；已有准备包仍可从Quick/Canvas显式目录入口登记。H3/LTX2.5无需数值转换的固定配方已增加“准备独立执行包”入口：保留原件、独占暂存、校验后原子发布、取消与关闭等待、登记前核项目归属，不自动切换草稿。5个CPU准备反例及取消登记接线通过；真实H3普通沙盒App的144GB原件校验→独立准备→登记已通过，准备不触发生成/切换草稿；LTX2.5在r2仅CPU配方路径；r4资源取得和真实准备见上表。**r3 Wan转换接线已进入候选**：固定内嵌Torch/safetensors、独立子进程目录访问、逐张量准备、完整清单校验、取消/关闭等待、原子不覆盖发布与登记；旧原件保护。CPU反例通过；b347c38真实内嵌桥与生产校验器已完成，来源、逐张量写回、完整清单及许可释放通过。r3固定文件副本的普通沙盒App点击准备/登记已通过；完整旧仓根路径的原生验收仍待解锁，F03不整体提前关闭。
- Dev有序参考图已在真实端口与能力投影一致；文案不作为执行schema。LTX2.5/Dev资源已齐，尚缺的完整真实模型与原生能力继续验收，不伪装为已支持完整上游功能。
- 选定checkpoint的上游能力与当前实现差距仍是工程责任：更复杂原生模式、未取得资源和未验证精度不能仅靠profile改名关闭。no-LM指未接另一语言规划权重；已有ACE歌词/风格参考/cover/repaint的原始F32真实条件执行已通过，仍须同包原生操作及听感验收。没有新增训练或云端工具。

## r3 原始精度加载实测（历史快照，M4 / 16 GiB）

磁盘GB按10⁹字节，内存“MLX峰值”是框架计数，不是整个进程或系统总占用。RSS、MLX和UMA不能相加；OS swap也不是某任务独占。以下为指定短请求观察值，**不是最低硬件规格或最大可支持输入**；完整参数/阶段记录在本轮R3/lead。GPU仍承担神经网络计算，SSD只改变权重同时驻留范围；常驻路径保留。

| 路线 | 原始资源／加载方式 | 完整代表请求、时间与可观测资源 | 证据与边界 |
| --- | --- | --- | --- |
| ACE XL | 固定清单约21.50GB；逐张量准备，分阶段条件编码/解码，全32层F32主干逐层SSD | 六秒/50步，普通生成、歌词+独立参考、cover和2–4秒repaint分别357–366秒；首个直跑15秒采样RSS最大1.593GB，不覆盖全部驱动内存。正式Runtime取消后完整歌词参考395.419秒，许可归零 | `ace-ssd-*-result.json`、`ace-runtime-real-result.json`、`ace-original-block-control-summary.json`。不是600秒极限、全常驻整模型对照或听感通过 |
| Klein 4B | 15.980GB；原始BF16编码器与扩散主干逐层SSD，解码分阶段 | 512²/4步/guidance1/seed42，完整生成31.363秒；双有序256²参考35.552秒；取消15.876秒。MLX峰值2.301GB，结束active/cache0 | `klein-bf16-real-05/`，f14bcd0；全15个局部检查及原始请求通过，不替代本包GUI |
| Qwen3.5-9B | 19.329GB；727 BF16＋48 F32原始张量，混合状态保留、完整chunk输出投影、逐层SSD | 取消15.667秒后，JSON78.929秒、双图21.880秒、短视频691.483秒、工具结果28.416秒；各次active/cache0，MLX峰值最高8.661GB | `qwen9-original-runtime-final-summary.json`，b347c38；该视频仅1帧采样，模型称静态图，不证明时序理解质量；未验长上下文极限 |
| Qwen3.8-27B | 55.586GB；完整1199个原始BF16张量，逐层SSD、保持混合缓存 | 取消35.449秒后，JSON199.974秒、双图54.032秒、工具结果71.610秒；各次active/cache0，MLX峰值最高6.111GB | `qwen27-original-runtime-final-summary.json`，b347c38；未验27B视频、长上下文极限或本包GUI；与9B不同原始dtype不得混写 |
| Wan原件准备 | 17.546GB原件；内嵌Torch逐张量读取/转换/写回核对，保持既定BF16/F32配方 | 桥接总103.115秒，转换89.010秒、子进程峰值RSS9.466GB；1,261张量/1,262文件，生产校验7.233秒；原件不变、计算许可释放 | `wan-original-real`和`ui-final`，b347c38；是准备/验证，不是新Wan生成、原生按钮或发布登记验收 |

两款Qwen均使用完整原始模型；9B原始控制张量与27B不同，不以参数量直接推断本次峰值排序。该历史记录时Dev/LTX2.5受H31阻塞；账号访问及固定下载现已关闭，r4新增状态见上表。各路线原始块对照与完整请求分开保留，未宣称所有上游模式已验。

## 冻结出口与故意不做

必须补齐：每个正式模型的Quick/Canvas真实smoke及其公开承诺的强输入；Klein数值归因/处理已完成并保留版本约束；完成已取得Dev/LTX完整请求；完成必要大内存实测与新普通App原生操作；共享取消、保存重开、导出按机制复用验证。未完成不得写“首发冻结通过”。

本轮不增加新模型家族、插件市场、通用注册平台、工作流DSL、专业剪辑/DAW、Ref2VA或Wan I2V，也不迁移/删除旧候选。LTX2.5尚未完成真实验收，不从冻结名单删除。开发资源和源码许可记录保留，但不把内部适配测试写成模型商业分发已获许可。
