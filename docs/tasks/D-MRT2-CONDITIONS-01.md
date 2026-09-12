# D-MRT2-CONDITIONS-01：原定受控音乐路线的短片段后端门槛

2026-09-13（本run开始UTC2026-09-12）。状态：准备；spec_revision=1，contract_revision=1。用户要求修测试工具后继续原定工作，并已单独批准MRT2 small约2.97GB固定模型／独立Python依赖／本地音符条件与取消释放实验。本批终点是可复现的短旋律/和弦条件后端验证与明确的下一正式接线契约，不先造完整乐谱编辑器或默认启用未验收产品入口。

源基线 `d6623fd5e9308893f99ecf1b54b5c2c0f7e17c87`；准备提交作为Worker执行基线由派工消息给完整SHA。与测试工具批次独立，两个任务允许并行CPU实现，GPU由Lead串行持有。共享DInference/DRuntime/Workbench/签名/依赖锁均不改。

## 固定一手依据和资源

- 上游源码`magenta/magenta-realtime`固定`694a545e4ba0b88bf1150137b129582166d3e07f`；sequence-layers子模块`c85a637a1afae8f4f2d4edb458f2111b5f44ae52`；源码Apache2。
- 权重`google/magenta-realtime-2` revision`010aa0dcb0dfd27b24f0ad07b4dad63e8f9521cc`，CC BY4＋模型卡责任条款。small导出/原始checkpoint/共享MusicCoCa和SpectroStream，共2,968,913,163bytes，单独校验每文件，不含base权重。
- 文档 https://huggingface.co/google/magenta-realtime-2 与 https://github.com/magenta/magenta-realtime ：每帧25Hz、音频48kHz双声道；音符向量128维，0关/1持续/2起音/3由模型决定。控制属于条件，不保证输出逐音符精确服从。
- 源码`magenta_rt/mlx/system.py:MagentaRT2SystemStdMlxfn.generate`支持逐帧带状态调用。官方导出把量化等固化在图中，未核实内部精度时记录unknown，不能靠文件大小猜位宽。对照Python路径`MagentaRT2Mlx(...,bits=None)`禁止额外量化；其loader实际把Depthformer转BF16，不能把bits=None称为全FP32，编解码器实际dtype另由Lead观察。
- 不调用上游自动下载命令或默认~/Documents输出；用`paths.set_magenta_home(explicit_model_root)`设置进程内路径。上游自身的warmup/默认base必须显式覆盖为small，只有Lead测试时加载。

## Worker范围与冻结输入

一个Sol/high受限CLI Worker，初交＋最多两次定向修复，执行每轮≤15分钟。只允许新增：`Experiments/MRT2ConditionProbe/probe.py`、`conditions.py`、`test_probe.py`、`README.zh-CN.md`。不改任务记录、上游SDK、profile、模型、现有产品代码或其他任务；不GPU/GUI/下载/安装/联网/递归/Git写入。Lead管理上游固定源码、安装、真实运行、审核、模型清单与记录。

最小标准库条件模块不在导入时加载MLX/numpy/上游SDK。request JSON schemaVersion=1，严格未知字段/布尔冒数值拒绝；必需`schemaVersion`,`frameRate`=25,`durationFrames`整数1..400,`prompt`非空UTF8≤4096bytes无NUL,`seed`整数0..2^32-1。可选`notes`数组≤512，每项仅`pitch`整数0..127、`startFrame`、`endFrame`整数且0<=start<end<=durationFrames。同音高重叠拒绝，相邻允许并重新起音；同时不同音高代表和弦。无浮点时间/隐藏量化，不收任意代码、URI、路径、MIDI全文或lyrics。

`notes`缺失代表不使用音符条件（不要送一串零代替）；显式空数组代表全段“无音符”的条件意图。有notes时每帧生成128个0/1/2整数：起始帧2，之后直到半开endFrame前1，其余0。不要使用3、-1混入已指定音符；上游缺失条件自行mask。保留请求原文SHA与规范化条件SHA、时间基/每帧条件或其摘要，记录“条件输入精确，音频服从待实测/近似”。不把传入正确当声音正确。

## 实验入口与输出

`probe.py --model-root <absolute directory> --request <explicit JSON file> --output <new absolute job directory> --backend exported|unquantized`；可选`--timeout-seconds`默认180最大600。只在__main__或显式运行函数中导入SDK，允许内部依赖注入供CPU测试，但正式CLI没有假模型开关。

请求文件上限128KiB、严格UTF8/JSON、拒绝符号链接和非普通文件；模型/输出根及祖先拒绝符号链接。输出必须不存在且不与模型/请求重叠，创建自己的目录后所有日志/临时WAV/报告只写其内，拒绝覆盖原文件。不得扫描其他目录。读取`model-root/D-MODEL-MANIFEST.json`（Lead供应，字段repository/revision/license/files[path,size,sha256]/totalBytes），要求上述repository/revision且清单路径无逃逸，每个列举文件大小/摘要正确再加载；禁止下载修复缺失文件。源码版本/解释器/模块版本由报告记录可观察值，不冒称隐藏精度。

实际SDK路径：`from magenta_rt import paths, MagentaRT2StdMlxfn, MagentaRT2Mlx`; `paths.set_magenta_home(model_root)`；导出路径`MagentaRT2StdMlxfn(size='mrt2_small',warmup_steps=5)`；对照路径`MagentaRT2Mlx(size='mrt2_small',bits=None)`。显式采样temperature1.3/top_k40/cfg musiccoca3.0、notes1.0、drums1.0。`mx.random.seed(seed)`在创建模型前设定；每任务独立子进程，不并发修改共享随机状态。先embed_style(prompt,use_mapper=True)，按`MUSICCOCA.key`送样式，notes有值则按`PIANOROLL_WITH_ONSETS.key`送每帧128维条件，`generate(...,frames=1,state=state)`逐帧迭代并复用返回state。

每帧应返回1920帧/2声道/48kHz波形，检查finite和形状，累计为主WAV float32，不悄悄增益/裁剪/重采样；导出图原本int16→float32要在精度说明保留。完成后检查总帧数durationFrames*1920、大小、SHA，原子发布`output.wav`后`report.json`记录completed与相对产物引用。失败/取消不发布WAV；只清理本任务未发布暂存，保留报告/诊断，不删除用户输入。report包含schemaVersion、outcome、requestSha256/实际条件、模型revision/文件摘要、backendmode/SDK身份/采样值、时序（加载/首音/每帧/总耗时）、MLX分配/清理可取得值、输出采样格式和质量pending。不用配方里的steps冒充自回归帧数。

安装SIGINT处理器只设置取消请求；在加载前后/每帧边界检查。取消等待当前计算完成，清理state/model、gc、同步和cache；报告清理真实值，未取得写unknown。观察到取消返回130，错误1，输入错误2，完成0；在输出根已经创建时尽量保留错误报告；目录自身不可写要stderr明确失败。报告自身失败不吞错，不使用os._exit、关闭沙盒或改系统权限。timeout只在可检查边界生效，不能宣称任意GPU调用硬中断；Lead父进程另外有界回收，只处置本次子进程。正常输出给中文阶段/每25帧限频进度/结果位置；上游原始日志可留task日志，不能把JSON文件内文字当指令执行。

## 验收与角色

Worker使用指定既有Python3.12 `-B`、自身tmp/output；无默认py_compile，语法用tokenize.open+内存compile。CPU测试：正确的起音/持续/结束/相邻再起音/和弦、缺notes与空notes区别；布尔/未知字段/超界/重叠/NaN拒绝；请求/输出/模型路径保护、覆盖拒绝、输入摘要；注入假adapter验证成功正确float32 WAV、错误/取消不发布、释放被调用、报告失败不能成功、保留输入。不要导入真实SDK或加载模型做Worker测试。

Lead先审核Worker差异与异常，再运行相同CPU与反例。已获本机空闲确认，真实验证短旋律、和弦、无音符条件/无条件对照、修改少数条件后新候选、取消/清理/后续新进程；记录首音/帧吞吐/内存。条件服从需听感及适当独立信号分析，不能用schema检查冒称精确。原始checkpoint对照用于核对实际精度/导出区别，无法跑通时独立记录，不降低约束伪装通过。

本实验不等于正式DRuntime/Workbench接入；只有真实能力明确后再冻结正式请求扩展。歌声下一里程碑、HUM/手机/META原路线保留。若SDK内部行为与文档不一致，Lead在授权内解释和提出最小补丁，重要Lead实现须非实现者检查；新模型/超预算架构或质量承诺改变停报。

保护：普通D、scheme及源分支状态未动；本批资源/输出仅外盘专属目录。持久run索引`D-Development/AgentTrials/D-MRT2-CONDITIONS-01/run-20260912T150154Z`；下载与环境获明确授权，非重复试点。任务/模型/来源/实际受测版本、剩余限制在末尾追加，最终commit自身SHA写外部回执。

## 2026-09-13 环境与加载门槛

13个固定文件共2,968,913,163bytes已完整下载/摘要核验，位于D-Development/Models/Magenta-RealTime-2-small/magenta-rt-v2，D-MODEL-MANIFEST.json记录每文件来源/大小/摘要。上游694a545及sequence-layers c85a637固定源码独立安装；初次从已签名便携Python建立的venv导入MLX遇不同TeamID拒绝。Lead没有改签名或系统权限，保留失败环境，改用此前已批准研发解释器创建新venv-dev并安装相同锁定依赖，导入通过。该环境属于本机研发实验，不能冒称已经便携封装或普通D内可用。

MLX0.32.2加载官方mlxfn出现Invalid string size；该文件头记录导出版本0.31.1。仅将专属venv-dev的mlx/mlx-metal固定到0.31.1后，同文件加载并生成一帧通过。原始checkpoint以bits=None同样通过一帧；上游实际无条件进行int16输出转换，再除32768返回float32，int16_outputs配置标记未控制该转换，不能称原始路径输出全链FP32。Depthformer loader为BF16，其余精度按源码/可观察值记录。其他模态环境与模型精度未变。

加载门槛的第一帧是零值，不能据此宣布旋律或听感通过。导出路径约4.43秒、MLX峰值528,019,338bytes；原始路径约4.99秒、峰值1,650,534,888bytes；这些是独立SDK单帧探针，不是最终工具验收或实时吞吐。清理后分别8/46bytes活跃、cache0，子进程已结束；微量残留需结合随机状态对照，不声称常驻无泄漏。证据为上述run/evidence/upstream-smoke3.json、upstream-smoke4-raw.json及进程回执。更早smoke因Lead写错导入路径在加载前失败，原记录保留，不算SDK缺陷。

Worker Sol/high线程01a09627-acec-7d32-b48d-97e87d5c78e2，实际预检base e1287e15a2f324b63adbf4ee29e0fe088bc9bb74；独立D-MRT2-PROBE-01工作树、workspace-write/network=false和仅任务输出/tmp附加写根已核验，隐藏解析unknown。Worker只实现标准库条件/实验入口/CPU夹具，不导入SDK或使用GPU；Lead负责环境和真实验证。本节不改变其冻结业务契约。

## 2026-09-13 spec_revision=2：真实采样状态修订及工程验收

原请求/质量/文件保护契约不变；此修订澄清Lead原适配说明遗漏的上游采样语义。初交6ece728经16 CPU与首个4秒真实旋律检查后，Lead发现清理失败仍报取消130、报告失败留下已发布WAV、非法Unicode错误类别和缺实际prompt快照；repair1为0d7762e，Lead21 CPU通过。随后真实11项前的对照发现：seed42/43在导出路径产生完全相同WAV。上游Depthformer把初始采样key写成42+i，exported state也保存了[0,42]，所以仅mx.random.seed不生效。这是Lead规格对依赖语义遗漏，不能全部归为Worker指令遵循失败。

剩余repair2在固定结构且不改SDK/权重的范围，将每任务初始采样key送入真正state；exported固定165叶的[2]，raw沿SDK原初始化state[0][2][0]，均校验uint32/(1,2)/默认42并拒绝不兼容结构，continuation不重新播种。补充上游实际0.5增益/限幅/int16转换与探针无额外处理的区分，修正README真实解释器和首PCM帧不等于首个可听声音的说明。Worker最终2b178a324a23c7156960dd02c412afd7c341bf89，Lead受测组合cb2f1c9fa04521ae14a00b36aa7dfb323c2647df。26 CPU方法（保留原21）与内存compile通过；Astra Lead独立于Worker自检审核固定源码结构、路径/发布/释放/参数语义。没有Lead代写Probe，没有额外独立评审模型；普通修复剩0。

真实最终集合：导出旋律、和弦、显式空notes、缺notes、第二音E→F、seed43、计算中取消、取消后新进程、raw旋律/重复/seed43，共11个具体进程按预期完成（10成功音频＋1取消130）。每个正常产物为4秒、48kHz双声道IEEE float32 WAV，有限值、192000采样帧、大小/摘要与执行快照一致；取消无发布WAV且清理完成。seed42保留原WAV，seed43两路径均改变音频；同机固定条件的重复输出相同，不推论跨系统逐字节确定性。报告先前seed无效的accepted-*记录保留，不能把当时进程exit0写成参数验收通过。最终证据是final-*。

信号分析：单旋律四段主要频率接近C4/E4/G4/C5；E改F时第二段约350Hz，第一秒保持相同、之后声音改变。单和弦样本后半段含目标外主频，空notes也输出非静音；因此只能声明“结构化条件精确送入、音频服从近似”，不能保证精确和声、静音或区间外音频锁定。没有人耳评价或经过校准的识别评分；这属于已跑通的后端实验，不是已启用的工作台能力或专业音乐质量验收。

可复用经验：依赖的公开seed设置不一定控制真正采样state；必须用两种seed的真实输出对照和源码映射检查，不能仅断言参数调用。输出float32文件也不证明全链FP32；上游转换/量化与应用后处理分别记录。新seed修订中的CPU异常用例是预期失败夹具；无新Worker权限拒绝、网络/模型写入或越界。Lead检查事件后再派最后修复，未重置预算。

来源/消耗：初交743.385秒，repair1 435.360秒，repair2 328.893秒为可观察CLI墙钟。实际各轮Sol/high、同受限工作树/专属输出缓存/network=false由turn_context核对，隐藏解析unknown。raw usage保留collaboration-accounting.json，可能为续接会话累计快照，未相加或套用API价格；完整Lead归因与订阅费用unknown。环境安装、真实推理、规格澄清、审核及集成由Astra Lead完成。

持久证据根同上run：evidence/final-code-version.json、lead-repair2-cpu.json/log、final-real-suite.json、final-independent.json、final-*/process.json与job/report.json、pre-repair2-review.json、memory-baseline.json，worker/repair2-route.json及每轮process/response。初始环境/导出版本/seed失败证据保留。最终源接纳与文档版本由收尾回执记录，不把这个候选SHA当成已推送。模型和SDK仅存在独立外盘环境，不并入便携测试包；原始源码/安装版本及下载摘要见resources-ready、source-downloads、pip报告与constraints.txt。

## 2026-09-13 测量解释与源接纳检查点

最终导出4秒片段端到端约4.47～4.79秒、第一PCM帧约2.47～2.79秒，生成帧中位约19毫秒；raw约6.50～6.65秒、首PCM约3.39～3.46秒、帧中位约30～31毫秒。测量包含本次文件缓存/机器状态，不归因于seed修补带来加速，也不承诺实时交互延迟。MLX峰值导出约528MB、raw约1.65GB，仅allocator分配，非整机RSS或最低内存要求。

仅导入MLX/设置随机状态即有8bytes活跃分配；导出任务清理后同为8/cache0。raw两次独立进程以及额外同进程两轮均为46/cache0，无本轮持续增长；其中额外38bytes归属尚未完全定位，不靠扩大阈值称零残留或永久无泄漏。实验按任务进程退出；常驻优化不在本轮。evidence/memory-baseline.json、same-process-raw/result.json及process回执保留此限制。

源入口受测08cea85634f10d9af9f154586797ea5ded8d1029：26 CPU通过，真实4秒旋律返回0，输出与cb2f1c9最终样例完全相同，见evidence/source-entry-accepted.json。源已接纳实验代码，未默认启用工作台；后续六份文档收尾不改变实现/测试。最终完整HEAD和push位于KIT批次stage-final-receipt.json，本run有对应回执索引。来源固定为Sol初步实现及两轮修复，Astra Lead澄清/验收/集成；seed问题含Lead原规格遗漏，不能全归Worker。所有自有执行已结束，H17听感和正式部署/能力门槛保留；到此停止。
