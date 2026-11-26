# 首发模型能力矩阵

## 2026-11-25：全局低内存覆盖

目录仍为20个准确配置，没有删支持项或换精度。以下按源码、阶段/独立provider及普通App分别列证；LTX2.3 BF16已取得本轮f928普通App完整请求及冷开证据，不外推其他型号。N25见CURRENT_ACTIONS。默认预算仍为物理内存减去max(4GiB,1/4)，本机12GiB；不是实时空闲内存。新建任务使用automatic，旧缺字段/fixed/明确手选保持原义；普通估算满足预算直接执行，否则才通过原ask/allow/deny及单次决定处理方案。

| 当前配置 | 普通路线 → 低驻留路线；节省/仍驻留 | 预算依据、代码与实际证据边界 |
|---|---|---|
| Qwen3.5-9B BF16 | 完整语言层 → 原BF16逐层；embedding/head、KV及必要视觉组件保留 | 既有QwenVLM预算/原dtype路线沿用；新全局/默认接线有契约验证，准确BF16历史分层GPU沿用；本型号默认12GiB新普通请求未重跑，大常驻未验不代替低内存。 |
| Qwen3.5-9B Q4 | 完整量化语言层 → 原packed层；量化参数、KV/视觉组件保留 | 既有精确Q4路线沿用；f928普通App新请求782E3801以automatic/默认12GiB直接resident完成，无确认，估算12,504,421,920B、MLX峰6,220,432,180B；保存冷开保持。此会话显式thinking off，不冒称默认思考问题已解。另修嵌套EOS漏读。 |
| Qwen3.8-27B BF16 | 完整层 → 原BF16逐层；KV/共享/必要视觉组件保留 | 15GiB历史真实请求有效，不外推本轮默认12GiB；请求规模仍进入估算。 |
| Qwen3.8-27B Q4 | 完整层 → 原packed层；共享/KV/视觉组件保留 | 既有分层与身份检查沿用；不把9B结果代为27B实测。 |
| FLUX Klein4B Q8 | staged整塔 → 原Q8文字/DiT逐层 | 新增原U32 packed、F32 scales及混合dtype读取；真实原文件短文字/DiT逐值、dtype和RNG对照相同；f928普通App显式Layered、默认12GiB完成512²/4步/CFG1/seed42（46C24A90），PNG444,571B且解码为512²；保存正常Quit冷开准确记录保持。预算估算2,223,340,544B不是实测峰值。 |
| FLUX Klein4B BF16 | staged整塔 → 原BF16文字/DiT逐层 | 既有估算包含共享、单层、激活及VAE；原有效证据沿用，本轮Q8适配不替换它。 |
| FLUX Dev BF16 | staged整塔 → 原BF16分层 | 既有实现与完整普通请求沿用；本轮不重跑未变采样器。 |
| MiniMax H3 FL2VA BF16 | 常驻 → 既有流式 | 新建fixed改automatic，冻结fixed保留；原完整普通App请求沿用，新建automatic和旧fixed兼容有全目录/请求组件验证；默认12GiB下本型号新普通GPU未重跑，不外推LTX代表。 |
| LTX2.5 BF16 | 常驻 → 既有Gemma4/DiT流式及错峰 | 保留原Gemma4路径；新Gemma3补丁顺序检查不改Gemma4数值。 |
| Wan2.1 T2V1.3B BF16 | 整T5/DiT → 原混合dtype逐层；共享/latent及原VAE分块保留 | 新按1261张量真实shared+maxBlock、请求tokens/workspace、VAE几何估算。320×192、17帧、50步完整provider459秒，MLX峰4,065,559,570B，RSS峰2,842,198,016B，释放active26/cache0；非普通App。11月26后继4a5acad5已补FP32原生conv3d及中间/时间cache物化边界：固定latent 832×480/17帧最大绝对差3.3557415e-5（原容差3e-4）；同尺寸50步/CFG6/shift8/seed42完整后端1491.678秒、MLX峰11,683,316,522B，12GiB分层成功。该实测范围准入v2估算12,524,191,744B；原13GiB常驻路线及其他几何保守规则不改。普通cf93489a后继已由原始目录经UI复制/准备/添加，默认12GiB automatic→allowOnce完成同代表请求7A4C788E：1963.788秒、MLX峰11,683,316,522B；17帧MP4全解码/播放、正常Quit/冷开同记录及早期加载取消后子进程结束通过。大常驻路线与其他尺寸不外推。N26/wan/full-request-r1/summary.json及ordinary-wan/full-success-cf.json、cold-reopen-cf.json。最终74599686沿相同a122引擎资源，已保存成果普通播放、桌面正常冷开/项目重开播放通过；本次组合复核没有重新推理。 |
| MRT2 small/export-v1 | 固定图 → 编码解释器顺序释放，去预热state重叠 | 最小路线直接用于同一固定图，不伪造第二精度或逐帧权重加载。3GiB+PCM工作区估算保留；4秒/100帧同seed输出逐样本相同，RSS峰1,504,903,168→857,227,264B，MLX峰约0.49GiB。f928普通App从模型库准确选择后自动最小路线，4秒/100帧/seed45正常生成39BADF73；48kHz双声道float32 WAV1,536,044B，播放到192000帧，保存正常Quit冷开再播放；默认12GiB、估算3,225,833,472B，无额外确认。 |
| ACE1.5 XL SFT F32/no-LM | 常驻 → 既有原F32分层 | 原ask/允许一次/保存冷开证据沿用；不增加LM或改变采样条件。 |
| Qwen2.5-0.5B Q4 | 常驻 → 原Q4逐层 | 新按准确分片shared+maxBlock、全KV及分块prefill工作区估算；真实原文件分块prefill/两次cache decode逐值与RNG相同；非普通App。 |
| Qwen2.5-1.5B Q4 | 常驻 → 原Q4逐层 | 同一固定Qwen2实现，逐准确manifest准入；不得以0.5B数值记录冒称本型号GPU通过。 |
| Qwen2.5-7B Q4 | 常驻 → 原Q4逐层 | 真实7B原Q4独立head、分块prefill/完整KV两步decode逐值/RNG一致；另两分片夹具含共享/独立head和替换拒绝。非普通App，不能外推32B。 |
| Qwen2.5-32B Q4 | 常驻 → 原Q4逐层 | 同上，最大层/共享及上下文仍可超过预算；不换小型号。 |
| Stable Audio Small Music | 整T5/DiT → 原F16逐层；共享、latent及F32 codec保留 | 新固定NPZ形状预算shared+maxBlock/codec，保留时长工作区；6秒/8步CFG6同seed完整WAV逐字节相同，MLX峰1,746,234,946→490,235,634B。取消/同尺寸替换恢复mtime反例通过；普通App待验。 |
| SwiftF0 0.1.2 CPU | 原有小型CPU有界路线 | 399,114B准确ONNX；真实CPU当前最长120秒合成输入产出7500帧，进程RSS峰641,695,744B。修原256MiB偏低估算为256MiB+每输入样本256B，最大759,955,456B；满足默认12GiB，不造双加载器。此为真实CPU provider，非普通App/GPU。 |
| LTX2.3 BF16 Full | 整Gemma3+connector/DiT → 原BF16 Gemma3分片逐层、49状态物化、释放后connector、既有DiT流式 | 新阶段估算max(真实shared+maxLayer+完整states+workspace,connector+states+workspace,DiT/VAE请求工作区)。真实1024token编码MLX峰2,021,629,962B、connector8,075,320,348B，非整App峰值。f928普通App默认12GiB/global allow自动选择streaming v2，固定512×320/25帧24fps/30步CFG3seed42完成，H.264+48kHz双声道AAC全解码、保存正常Quit/冷开播放通过。App记录1470.388秒；5秒采样child RSS最大3,914,727,424B不是精确峰值，独立sample footprint峰8.6G。开发父进程ffmpeg sandbox-inherit失败保留，不是普通App失败。 |
| LTX2.3 Q8/Gemma3 Q4 | 整Gemma3Q4+connector → 原packed逐层与错峰；DiT仍原Q8 | 同一分片读取适配实际2分片及过时index，不改原文件；小48层BF16/Q4数值/RNG/释放反例通过；真实原Q4正提示/空负提示1024-token全部49状态逐值、dtype及RNG与原常驻相同，编码MLX峰7,775,519,272→713,400,368B；同进程RSS为累计，不作两路线RSS比较。历史Q8普通GPU/保存冷开有效，新增文字路线待普通包复验。 |

预算定位：Qwen3.5/3.8四配置按`QwenLayeredResourceEstimate`分别累加准确shared/maxLayer、完整KV增长与recurrent/convolution状态、512行projection、视觉输入/工作区及allocator；不以一个固定GiB替代上下文。Klein/Dev由`LocalImageModelInventory`按准确权重、分层shared/maxLayer、图像工作区及VAE估算。H3/LTX由`ExternalVideoBackend.estimate`取各阶段最大值，仍计宽×高×帧工作区；LTX2.3另读准确Gemma3分片/connector。ACE由`ACEResourceEstimate`按原F32层、条件/embedding、两份VAE、时长mask及CFG/KV分支估算。旧Qwen2、Wan、SA3新增实现分别见`LocalModelInventory`、`MLXVideoBackend`、`AudioModelInventory`；均保留输入工作量。以上是准入估算，不是实时可用内存或已测峰值。

MRT2和SwiftF0明确只有经优化/核验的固定最小路线，当前仍为`InferenceBackend`而非替代plan提供者；预算足够直接执行、不额外弹确认。其余18配置的规划接口已接入，不代表18种都在本轮普通App/GPU重跑或任意请求均能满足12GiB。

本轮新音频/视频方案的值型契约只改加载组织，参数/提示词/seed/准确型号及保存记录保持；运行前/取得执行权后/发布前仍验证文件身份。MRT2/SwiftF0已经是小型最小工作集时，满足预算正常执行，无需人为制造“低内存确认”；若实际请求仍超预算，必须保留具体不足，不能以此表当成任意预算保证。源码检查、组件、真实provider、普通App及用户质量判断分别报告。

## 2026-11-24：LTX2.3普通原始文件添加补证

本轮接续旧完整包/断源/运行证据，另核普通用户取得路径。正常70af App通过“添加本地模型”分别选择model与text_encoder原始目录、明确复制到模型库；App自行识别准确型号、生成内部清单、完整校验并发布，未要求用户运行脚本或选旧准备包根。Q8为26原文件＋清单36,826,797,226B；BF16为28原文件＋清单72,577,188,481B。源inode/尺寸/mtime未改，目标非链接且独立inode；新增安装ED2D448A…、B0AD8B5A…。证据N24/native/raw-{q8,bf16}-*（N24见当前行动）。

原始分离结构本身不能被现有执行器原位使用，界面明确只提供包含必要整理的独立副本；已准备完整包的原位能力继续保留，没有第三种隐含整套“运行缓存”。两条准确版本/精度不替换。70af原生发现准备包执行身份与下载revision混用导致noRoute，37f已修准确catalog workflowIdentity；正常Q8选用及受控失联→同安装重新校验/选用通过。949普通App从新ED2D安装完成Q8真实GPU请求：256²、9帧/24fps、2步、CFG1、seed42、明确允许一次streaming；新run 57B4AD14…完成，H264/AAC结果74,180B、SHA256 01dc30f…f4c。e937仅补低内存确认框的准确型号显示，不冒称重跑GPU。BF16新B0AD安装在949正常选用；最终冷开/播放证据见任务。旧完整包断源与GPU证据保留，不冒充本轮原始添加。

BF16导入/文件准备/选择不受GPU预算阻塞。当时26.58GiB是旧整塔实现估算，不能作为物理下限；11月25已明确低内存实现缺口并继续补齐，当前进展见上表。常驻路线的大内存硬件未验单列，Q8不替代BF16。

## 2026-11-20：LTX2.3具名未验分支补证

普通4d636d5c，现有准确资源，不重跑全矩阵：

| 分支 | 本轮实际路径 | 仍缺 |
|---|---|---|
| LTX2.3 Q8＋Gemma3 Q4 | 27必需文件/36,826,797,244B完整副本，关闭管理器后后台完成；隔离本轮测试源后原有校验通过。256²、9帧/24fps、2步、CFG1、seed42、STG0，明确允许一次，真实GPU149.8秒，run B500FF8C-9078-4499-B4BE-0E4A6FBDDC71。H264/AAC完整解码、74,180B、SHA256 01dc30f145a3aac082d02809d38cef216dce4f707283a7702bd1fe5a78734f4c。保存、正常Quit、冷开同run/asset，源仍隔离。 | 低步数噪声只证明准确执行链，不是质量；不扩大到其他条件。 |
| LTX2.3 BF16＋Gemma3 BF16 | 29文件/72,577,188,499B完整独立副本、断本轮源、校验、保存/正常Quit/冷开通过。model rev cfc837526e56abf8657823a0ae192eec3a40177d，encoder rev b8b9b412cb795bd6115fdce8c9a0ef0d1664db3a。 | GPU未开始：最低方案28,536,034,184B（26.58GiB），本机16GiB/执行预算12GiB；准入准确拒绝并保存原诊断。此为当时未补全Gemma3低内存路线的拒绝，不是物理下限；11月25继续原BF16分层与错峰实现及默认预算验证。常驻路线较大内存硬件未验单列。 |

当前不是旧“SSD不足”：复制前重新核容量及峰值，原始模型不动。Q8首个AX数值未提交绑定的30步请求正常取消，保留为工具设置失败，不计2步验收。N20/review/q8-native-summary.json、bf16-native-summary.json保存准确安装/run及冷读；本轮后继仅展示/日期/随包说明变化，推理链有效证据按影响沿用。


2026-10-02 · D-RELEASE-FREEZE-01 · **候选，尚未功能冻结**。最终代码与证据版本见[本轮记录](tasks/D-RELEASE-FREEZE-01.md)；当前停点仅以[当前行动](CURRENT_ACTIONS.zh-CN.md)为准。

模型能力、D已实现的profile、资源是否就绪、本机实测、Quick/Canvas原生验收分开。下表不是九模型均已交付的声明。16GiB开发机不限制其他Mac的合法请求；预算不足明确报告，不自动换模型、降精度或丢条件。

## 2026-10-31接续时的原生增量证据

下表补充已有矩阵，不把历史成功改成当前包重跑；后文r2/r3/r4的“本包”指各自固定版本。当前候选及未验仍由[唯一入口](CURRENT_ACTIONS.zh-CN.md)和D-I020负责。

| 精确范围 | 已有可复用证据 | 本轮边界 |
|---|---|---|
| Qwen3.5-9B Q4，revision `8b2b98c00a6b4d291155e4890773ca8f769aee53` | 5f0b28b4普通App同权重automatic→本次同意layered；真实停止/长度前缀、步骤保存失败→只保存恢复；ff83/8101冷开 | 原始BF16/27B不由Q4替代；本轮未改推理，沿用[部分输出记录](history/UI-TASK-THROUGH-20261030.md#部分输出统一外框resize与打赏2026-10-30收口中) |
| MRT2 small/export-v1，Quick文字生成 | 5d7adde1普通App：4秒/100条件帧、seed45、notes/chords缺席，192000帧/48kHz/双声道float32输出，播放/保存/导出/冷开 | 不把文件格式称计算dtype，不重下模型或重跑此未改链路 |
| ACE-Step1.5 XL SFT F32/no-LM，Quick generate歌词 | 5d7adde1普通App：5.2秒/2步/seed42/en、同F32分层，无source/reference；249600帧/48kHz双声道FP32，保存/导出/冷开 | 2步只验证链路，不是质量；3ff正常App已补automatic询问→拒绝不推理→允许一次同F32/layered生成→显式入库/播放/冷开，默认仍ask；两run一asset/摘要不变。未重复50步历史矩阵 |
| Quick音频输入与候选 | 6d5f293f真实SCIM、跨模式Undo/Redo、候选及播放器VoiceOver；精确资产引用及选中状态保持 | 沿用[原生补验](history/UI-TASK-THROUGH-20261030.md#quick-audio-simplify-copy-20261029交审)，不称全App辅助功能认证 |

MRT2/ACE实际运行ID与产物、导出、冷开对应关系均见上述Quick音频记录。其余旗舰原始精度及正常产品入口缺口继续保留，不能因本轮补两项服务就整体标首发冻结。

## 2026-11-16 LTX2.5普通App完整链补验

准确`ltx-2.5-dev-bf16-full-v1@e378b7e1b50fcb1795fce74219b40bb0b1ede1e2`，现成原位20文件70.937GB执行包；825正常开发沙盒App实际704×480、97帧/24fps、30步、CFG3/STG1、seed42、无首帧/negative空、明确15GiB streaming。run4566DBC2…完整完成，资产929AA71A…/版本0DB12A6A…，239852B，视频97帧/音频48kHz双声道均完整解码；SHA256 `dd9a05eb7a983050e3b38559e2242d559611cf84f2e1a09c50c8e57f8f7a81b3`。provider自报9328.5秒，冻结run创建至资产发布9361.606秒，边界不同且均非UI性能。源文件inode/大小/mtime保持。

保存→正常Quit40067→同825冷开43274准确run/资产/运行数保持；后者再正常Quit。最终781普通QA冷开45419实际点击原生播放，00:01/00:04可见红杯；仅修目录就绪投影，推理/资源与825相同，没有重跑155分钟模型。再次保存/正常Quit，准确run和摘要不变，无新运行/工作流绑定。`run-20261116-resume-closeout/G-LTX825-{validation,cold-validation}.json`、`I-781-quit-and-no-bindings.json`及N16-G19/I01/I02-r6。此为所列代表请求链，不是全部条件/质量/常驻大内存路线或用户听感通过。

## 九个冻结目标

2026-11-16 普通App补验（下表r2/r3/r4历史原文不倒写）：5d8ced39完成Qwen3.8-27B原始BF16的真实请求、一次低内存许可、输出保存和正常Quit/冷开，准确attempt/内容保持；严格QA副本沿用原31文件，不以Q4替代，原目录的开发附加项被执行准入拒绝另记。cd5c7d77完成H3原始BF16普通Quick请求（512²/22帧/24fps/50步/CFG1/seed42、明确streaming/15GiB）；准确run673F79C3…，视频资产4CABD988…、SHA256 cd264514…fdc6d，22帧512²及32kHz双声道完整解码。保存→正常Quit26354消失→27319冷开，同一run/输出字节，无重新推理。旧5d的fresh-bookmark stale准入失败由视频子进程容器上下文修补解决，原失败保留。以上不是真人画质/试听、全部输入模式或其他模型通过。原始证据见`run-20261116-resume-closeout/G-27B-*`与`G-H3-cd5-{start,completed,cold}.json`；H3进度文件有缓冲，不能把运行中文件尾部当即时阶段或FPS。

2026-11-16 af7普通App补Dev原始BF16：准确revision26afe3a7…、512²/50步/CFG4/seed42/无参考图、15GiB显式分层，完整run D2C8375E…与PNG 4D470BC7…真实完成、全解码、保存/正常Quit/冷开逐run及内容身份保持；PNG SHA256 8129bb86…8182。G-Dev证据与N16-G10/G11/G12实图，不扩到参考图全部模式或用户画质接纳。下表历史“新选项原生未验”保留当时边界，当前这个无参考代表链已补。

| 模型／精确实现范围 | 输入 → 输出与关键控制 | 实现及资源 | 本轮验证／缺口 |
|---|---|---|---|
| **Qwen3.5-9B**；原始BF16及独立MLX Q4 profile | 原生角色消息、按序文字/多图/时间戳视频、工具声明/调用/结果、型号特有思考控制 → raw/reasoning/final/toolCalls；输出上限、seed、采样与上下文预算。非法组合拒绝，不自动执行工具 | MLX LM 3.31.4；原始混合dtype（727 BF16＋48 F32控制张量）与Q4固定独立revision；两者资源已取得，SSD与常驻显式分开 | r2 Q4正式runtime四请求通过：最终JSON、双图明暗顺序、视频描述、工具结果往返42；精确代码2f2855b，1个测试。r3 b347c38原始权重正式Runtime取消→JSON→双图→短视频→工具结果完成，1方法836.707秒，各次active/cache归零。旧视觉后16B残留已由所有权修补关闭，旧失败保留；视频夹具按2fps只采得1帧，回复将其描述为静态图，因此仅证明完整所请求输入和生命周期，不证明时序理解质量；41ad630普通App的Quick/Canvas均真实生成title/answer记录并保存冷重开，原生参数为Q4、思考off、seed42、输出256、显式预算15GiB；不是27B或其他精度的证明。r4另在4bc9b9f原始模型/SSD完成真正4帧时间顺序请求131.489秒，回答先红后蓝，active/cache0；已修预处理时间戳与语言RoPE映射 |
| **Qwen3.8-27B**；原始BF16及独立MLX Q4 profile | 同一VLM消息形状；3.8独立 reasoning_effort/preserve_thinking 映射，拒绝不适用的9B开关；不冒充9B实测 | 已登记与装配，Qwen3.5架构读取3.8实际配置；完整原始55.586GB权重已取得并校验，SSD与常驻显式分开 | r3 b347c38原始BF16正式Runtime取消→JSON→有序双图→工具结果通过，1方法361.288秒，各次active/cache归零；原始线性/注意力块零容差对照通过。r4另在4bc9b9f原始模型/SSD真正4帧时间顺序请求293.433秒通过、active/cache0；未验长上下文极限及同包GUI，不拿9B或Q4替代 |
| **FLUX.2-klein-4B**；原始BF16、既有Q8分开 | 文字＋可选有序参考图 → PNG；尺寸、步数、seed，参考图有共同校验 | 原始Klein 4B为蒸馏模型；新增BF16固定清单，Q8旧路径保留。BF16原件15.980GB已取得/校验；编码器和扩散主干均已SSD逐层接线 | r2源级A/B确认Float32 Steel attention缩放顺序差异；经非实现者复核保留上游实现并绑定新版本唯一严格PNG。生产3周期通过、active/cache归零；旧失败保留。r3 f14bcd0正式Runtime同次通过：加载取消后释放、512²/4步/seed42 BF16完整生成、双参考生成，PNG真实解码、原件不变、各次active/cache归零。r3 dd00普通App的Quick/Canvas原始BF16/SSD生成与冷重开已验；r4本包原生操作未验 |
| **FLUX.2-dev**；原始BF16 profile | 文字＋可选有序参考图 → PNG；独立guidance、步数、尺寸和seed，不沿用Klein的固定512 token规则 | 完整原始Pixtral/BF16扩散/F32解码，固定32文件112.823GB已取得校验；逐层SSD保持40文本层/8双48单DiT及原条件 | 原始代表块常驻/SSD对照通过；d3afbfb3正式Runtime取消→完整50步文生→50步有序双参考同方法5524.332秒通过，512²/CFG4/seed42、每次active/cache0，已查看PNG。dba33e6两张实际产物分别通过Store发布/重开/安全导出。非原生GUI；H31已关闭。2026-10-07的9b6c982b补通Quick/Canvas既有SSD选项，CPU真实控制器捕获与Store重开通过；默认staged/后端计算不变，新选项原生操作未验；见[派生接线映射](UI_CAPABILITY_WIRING.zh-CN.md) |
| **Wan2.1-T2V-1.3B**；既有视频BF16编码/扩散、FP32解码profile | 文字＋负面提示 → 无声MP4；尺寸、帧数、帧率、步数、guidance、shift、seed | 复用既有MLX视频后端和运行环境；不显示I2V端口，不接纳未经支持的首帧 | 历史真实链路保留；r3真实原件经正常内嵌转换桥103.115秒产出1,261张量，生产模型库验证1,262文件通过，原件不变、资源许可释放；r3固定文件副本的普通App准备/登记已验。r4完整原仓额外内容隔离及所需树校验18项CPU通过，实际完整目录登记/重开6.822秒通过；完整原仓原生面板与本包视频生成未验 |
| **LTX-2.5**；单阶段dev完整权重profile | 文字＋可选首帧 → 带音频MP4；独立视频参数与显式扩散权重流式开关；不支持末帧，输入即拒绝 | 固定ltx-2-mlx 0.15.12，扩散矩阵BF16＋原始290个F32调制表，其余精度按文件头记录；当前实验性diffusion视频解码器，2.5 audio FF及Gemma4资源校验；不以LTX2.3 Q8替代 | 70.937GB原资源已取得，48层Gemma4/49隐状态分阶段实现及小型数值对照通过；生产模型库准备56.878秒通过。原始F32表的错误拒绝已精确修补。6328d9c实际首层求值后取消/释放→原始704×480/97帧/24fps/30步文生8118.298秒→首帧条件8801.697秒，同方法16970.227秒通过；两份AV完整解码、Store发布/重开/导出均通过。Lead已查看三帧，合成首帧的平面红色区域在后续帧仍可见，控制效果和通用画质不作扩大结论。**本包原生操作及真人音频未验，冻结门槛未达** |
| **MiniMax H3 Base · FL2VA / 原始BF16** | 文字＋可选首帧／尾帧（分别冻结）→ 带音频MP4；显式流式加载、合法尺寸/帧数、步数、seed | 原始50层公开Base；公开Base本身为CFG蒸馏，不冒称未公开非蒸馏版；不是Ref2VA多参考路线。约144GB资源已校验 | r4 dba33e6正式Runtime完整512²/22帧/24fps/50步：文生1267.116秒、首尾条件2004.600秒，同一方法3271.875秒通过，每次许可归零；实际AV完整解码、原件保护及各自Store发布/重开/导出通过。Lead已查看三帧，仍非同包GUI或真人试听。最大阶段分配9.454GiB，不是全进程RSS；r2两步记录只保留为历史 |
| **MRT2 small/export-v1** | 意图、可选音符与和弦结构 → 48kHz双声道WAV；seed、1…400个25Hz条件帧 | 真实音符条件编码，非把和声拼进prompt；导出profile最长16秒，固定采样配方，鼓当前不受约束 | 既有真实有条件/无条件生成保留；是近似音高/起音控制，不承诺精确音符、声部或音色；非完整MRT2所有导出/流式能力 |
| **ACE-Step 1.5 XL SFT · F32 / no-LM** | 描述＋歌词/语言、BPM/调式/拍数、独立风格参考音频；cover原声或repaint区间 → 48kHz双声道F32 WAV | 原始XL权重实际F32；MLX扩散/VAE与MPS条件处理。固定官方源码，无模型侧动态代码/自动下载；不接LM，不冒充turbo/base | r3逐张量准备、分阶段编码/解码、全32层F32主干SSD加载已经实测。六秒/50步完整生成、歌词+参考、cover、repaint各357–366秒；正式Runtime取消→释放→完整歌词参考生成通过。原始滑动/全注意力块与常驻输出/cache/RNG严格对照通过。r2的单步冒烟/50步受控停止保留历史，不再是最新能力结论。本人已试听固定六秒/50步文件并确认播放正常；由afplay播放，不是同包原生App入口验收，波形检查也不代替听感质量 |

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
- Dev有序参考图已在真实端口与能力投影一致；文案不作为执行schema。Dev完整代表请求与产物Store闭环已通过，LTX2.5完整请求状态见上表；各自原生能力继续验收，不伪装为已支持完整上游功能。
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

必须补齐：各正式模型约定模式的完整代表请求、强输入及正常产品接入；共享Quick/Canvas构造用契约检查，两入口各保留代表原生操作，独有接线另补，不将全部GPU次数翻倍。Klein数值归因/处理、Dev/H3/LTX完整代表请求已完成并保留版本及模式约束；这不证明全部上游模式或通用生成质量。本包原生操作及尚未覆盖的大内存独有路径明确保留，后者不扩成所有旗舰整模型常驻要求；共享取消、保存重开、导出按机制复用验证。未完成不得写“首发冻结通过”。

本轮不增加新模型家族、插件市场、通用注册平台、工作流DSL、专业剪辑/DAW、Ref2VA或Wan I2V，也不迁移/删除旧候选。LTX2.5上述代表普通App链已于11月16日补齐；其他条件和用户质量接纳仍分级保留，不从冻结名单删除。开发资源和源码许可记录保留，但不把内部适配测试写成模型商业分发已获许可。

2026-11-24最终交付补记：5a409bdd正常Finder冷开后通过UI重开专属QA，同一949 Q8新运行和资产保持，普通播放器时间线再次0→0.375；原始文件添加/复制70af、路由与失联恢复37f、真实GPU949、两轮文字/图像e937、最终显示/保存冷开5a分别记录，未把后续显示差分写成重新推理。最终生产/Archive/18图与剩余条件见[当前行动](CURRENT_ACTIONS.zh-CN.md)。
