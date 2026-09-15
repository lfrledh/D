# D-SINGING-BACKEND-01：旋律与歌词的歌声薄后端

状态：SING1/PREP1输入准备切片已验收并源接纳；真实歌声仍受声库许可/下载与工具链门槛约束，D-MUS02未完成。源基线 `347cdfeafe042b1df8db3657adaa04e11ffba6e5`，源分支 `codex/inference-foundation`。规格 SING1 / PREP1 / spec1；执行基线记录在派工 JSON，不自引用。

证据 R=`D-Development/AgentTrials/D-SINGING-BACKEND-01/run-20260915T004329Z`；Lead 集成树 `D-Worktrees/D-SINGING-BACKEND-01` / `codex/d-singing-backend-01`。

## 授权、有限出口与真实停点

用户要求继续原定下一阶段，离开 Mac 期间将本人操作计入集中清单。沿既有隔离、预算、审核/快进接纳/工作分支推送规则，不修改签名、全局配置或权限；新权重/依赖仍需具体授权。无人值守时不启动录音、不反复催解锁。

本阶段目标是明确旋律和歌词输入，经专门后端生成短歌声；不是 TTS、声克隆、完整DAW或高级谱面。本轮已有权重不能证明歌声能力。可先完成真实可用的“有版本乐句＋显式发音→严格校验→DiffSinger variance 输入准备”CLI，无模型、GPU或新依赖。输出是条件，不是音频；不得登记可生成的 backend、默认开放 App 新入口或将此结果写成整个 D-MUS02 已完成。

新环境事件：`/usr/bin/python3`启动前提示 Xcode 许可未接受，退出69，未执行准备脚本。Apple工具链/Swift构建暂停，不代用户接受；既有独立外盘Python3.12.14与直接Git仍可用，后续CPU检查仅用它。事件见R/xcode-license-block.json。本次没有新增Swift/API枚举/项目schema或封装，避免未经编译的运行路径进入源。Swift值型请求与正式provider在条件/模型语义明确、工具链恢复后继续本任务，不换编号刷新预算。

## 已核资料与选择边界

OpenVPI DiffSinger固定源码 `336cf01b57f2ad44c6b37a79cf33993043291759`：[variance](https://github.com/openvpi/DiffSinger/blob/336cf01b57f2ad44c6b37a79cf33993043291759/inference/ds_variance.py)、[acoustic](https://github.com/openvpi/DiffSinger/blob/336cf01b57f2ad44c6b37a79cf33993043291759/inference/ds_acoustic.py)、[部署/推理](https://github.com/openvpi/DiffSinger/blob/336cf01b57f2ad44c6b37a79cf33993043291759/docs/GettingStarted.md)。只读核查，未安装其源码或训练依赖。当前源码Apache-2.0，与声库和vocoder许可分别核验。

已核variance输入为 `ph_seq/ph_num/note_seq/note_dur/note_slur`，duration/pitch/variance预测后声学模型得到mel，再由vocoder得到waveform。当前`.ds`使用`note_slur`，不是旧MiniEngine的`is_slur`。本轮不伪造`ph_dur`/F0，不把音素数值、模型图或私有路径放公共作品类型。下面发音清单只是后端显式准备输入，不预定前端编辑器需要显示音素。

候选：作者绮萱 `Qixuan_v2.7.0_DiffSinger_OpenUtau.zip` 420707627字节，SHA256 `fe8ee7c95883d327a2b7facbbe832a7a53e1344918dc791ca83fc23b08034110`；要求社区vocoder `pc_nsf_hifigan_44.1k_hop512_128bin_2025.02.oudep` 52760610字节，SHA256 `ba7d43142d41f6900c8264b5662ca7125a50feb8760bb8b9615c61a8f5e6902e`。合计473468237字节，解压量/运行内存未知。大小/摘要来自[声库release](https://github.com/yqzhishen/qixuan-diffsinger/releases/tag/v2.7.0)和[vocoder release](https://github.com/openvpi/vocoders/releases/tag/pc-nsf-hifigan-44.1k-hop512-128bin-2025.02)，不是本地文件校验。

[声库条款](https://github.com/yqzhishen/qixuan-diffsinger/blob/593bf442441cfa33a025f63a909b500c57a4a962/terms_of_use/Terms_of_Use.zh-CN.md)允许自定义推理，禁止转换/修改权重等；[vocoder许可](https://openvpi.github.io/vocoders/)为CC BY-NC-SA 4.0。内部商业产品研发是否适用NC未确认，用户批准下载不能代替权利授权。先核清此项再办理具体下载，未将候选冻结为产品选型。暂无真实图接口/CPU兼容/音质/性能证据；现有ONNX Runtime可评估，不默认重装。使用原样发布模型，不计划训练/转换/量化/修改权重。

## SING1：冻结输入与输出

输入一 `phrase` 是严格UTF-8 JSON object，准确必需键：`schemaVersion,id,revision,ticksPerSecond,language,durationTicks,notes,lyricUnits`。version恰为整数1；ID为规范UUID（大小写不敏感按UUID身份比较）；revision为1…Int64.max整数；language当前仅`zh`（本适配器语言范围，不是所有歌声模型限制）；ticksPerSecond恰1000000，本切片用整数微秒，不能套MRT2的25Hz或HUM的16kHz。durationTicks为1…600000000整数。

`notes` 为1…4096个按原顺序的单声部事件，准确键 `id,startTick,endTick,midiPitch`，pitch为整数0…127或显式null休止；start/end为整数，第一项start=0，后一项start=前一项end，最后end=durationTicks，0≤start<end≤durationTicks。缺口必须显式休止，拒绝重叠/倒序/隐式填充/静默排序。phrase、note、unit三类定义ID均须为带连字符的规范UUID，按UUID身份全局不重复；所有引用按UUID身份比较，保留原拼写。

`lyricUnits` 为1…4096个，准确键 `id,text,noteIDs`。unit ID唯一且不与note/phrase ID复用；noteIDs非空，所有unit依次拼接后必须精确等于notes的ID序列，每个note正好归属一个unit。一字多音用同一unit引用连续几个音符，不能把音素重复拼到每个音上。休止unit恰一个null note、text恰空字符串；发声unit所有note有pitch、text去空白后非空。每text≤4096UTF-8字节、总≤262144字节，禁止NUL，不做Unicode归一化或自动分字。发声/休止不能混在一个unit；至少一个发声unit。微秒、600秒和数量上限是此准备器的有界输入契约，不是已实现推理/硬件上限；新profile可另立，不根据本机16GiB静默改输入。

输入二 `pronunciations` 是严格object，准确键 `schemaVersion,phraseID,phraseRevision,language,inventoryID,inventoryRevision,symbols,silenceToken,units`。version整数1，phraseID/revision/language与phrase一致；inventory ID/revision为非空≤256UTF-8字节、不含空白或NUL的标识，不能冒充实际权重摘要。symbols为1…8192个唯一非空token，每token≤128UTF-8字节、无空白/NUL；silenceToken恰SP且在symbols。units与phrase的lyricUnits同序同数量，准确键 `unitID,phonemes`；unitID对应，phonemes为非空已知token数组，总≤8192。休止phonemes恰[SP]；发声不能含SP。不自动汉字转拼音、不猜多音字/未知音素、不联网取词典。外部manifest不被执行；清单来源可核对不等于真实声库字典已验。

输出一个JSON对象，准确键 `schemaVersion,status,adapterProfile,sourcePhrase,pronunciations,dsSegments`：version1；status恰`prepared`；profile恰`diffsinger-variance-ds-v1`；sourcePhrase/pronunciations保留输入语义值、所有原始ID拼写与Unicode；dsSegments是单元素数组。该元素准确键：offset=0.0、text=所有发声unit原文以单空格连接、lang=zh、ph_seq=各unit音素空格连接、ph_num=各unit音素数量空格连接、note_seq=各音符的12等律音名（60=C4，69=A4，用#）或rest、note_dur=(end-start)的秒数精确六位小数、note_slur=每unit首音0其余1。只使用整数商余数格式化时长；不转模型帧/不量化。验证sum(ph_num)=ph_seq的音素数，len(ph_num)=unit数=count(note_slur中0)，len(note_seq)=len(note_dur)=len(note_slur)=notes数；音素数、unit数和音符数彼此不要求相等。未包含模型输出、ph_dur/F0、隐私路径/账户或代码Agent记录，不报告generated或rendered。

## Worker PREP1 允许范围与执行

Lead单一维护本规格与 `Backends/Audio/Fixtures/Singing/{README.md,phrase-v1.json,pronunciations-v1.json,expected-ds.json}`；这是自编合成金样例，不能改来迎合实现。一个受限 `gpt-5.6-sol/high` Worker，仅允许新增 `Backends/Audio/Python/d_singing_prepare.py`、`Backends/Audio/Python/tests/test_singing_prepare.py`。没有实现就绪的第二任务，不造空后端/空UI或另开封装。只读研究/审核按需使用现有代理，不等同受限实施链路。

公开可测试入口 `prepare_singing_plan(phrase:dict, pronunciations:dict)->dict`，严格校验后无副作用返回上述对象；不修改传入数据。实现可自选内部结构。真实CLI参数 `--phrase <绝对路径> --pronunciations <绝对路径> --output <绝对新文件>`，只读两个各≤1MiB的普通文件；复用原 `d_audio_contract.py` 的通用严格JSON/文件/拒绝覆盖助手（只读使用，不能使用其SA3参数/WAV固定值）。读取拒绝重复键、未知/缺失字段、布尔/浮点冒整数、非有限、异常深度/大小、符号链接/非常规文件；所有目录分量不得为符号链接。输出父目录必须已存在，目标必须未存在且与输入不重叠；原子、不覆盖发布到授权目标，不建/扫其他目录、不跟随URI、不改输入/已有目标。仅在读/校验完整成功后写输出，不留伪成功文件。

CLI退出0仅表示成功保存prepared JSON，2表示参数/数据/文件错误。stdout不用于协议/日志，保持空；简短stderr说明失败，stderr不可写时仍保留退出2，不能被退出刷新改码。正常不输出虚构生成成功。完整进程退出由真实CLI测试核查；不os._exit、不吞掉全部异常掩盖错误、不申请新权限。复用安全助手时核其前置条件，禁止从未准备的随意目录删除临时文件；失败只清理本次拥有的未发布临时文件。

运行目录/独立分支/执行SHA/output/tmp以R/prep/job.json为准。网络关闭，写根只有任务工作树和自有output/tmp，公共Git只读；不读用户录音/模型/应用/密钥或无关日志，不改源/规格/工程/依赖/签名；禁止递归、commit和push。唯一Python：`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-VIDEO-V0-01/run-20260913T152419Z/venv/bin/python -B`。禁止调用/usr/bin/python3、Swift/Xcode或所有构建；已知Xcode许可拒绝不再探测。语法使用tokenize.open +内存compile，不执行该模块；行为测试明确运行，TMPDIR/D_TEST_TEMP_DIR及所有缓存位于任务tmp。预检只读，Lead核路由后发IMPLEMENT。

## 冻结验收、预算与未完成项

- 正常金样例的result[dsSegments]精确对照expected-ds.json数组；另验完整六键封装、status/profile和原phrase/发音清单值/ID/Unicode保留；同一歌词跨多个音不重复辅音，显式休止和音名八度正确；边界pitch0/127、seed不凭空增加。
- 拒绝旧/未知version、bool或小数冒整数、缺失/未知键、重复JSON键、NaN/Infinity、无声全休止、负/零时长、重叠/缺口/乱序/总时长不符/超限。
- 拒绝重复/跨域ID、孤立/多重/错序note映射、混合休止歌词、空白发声歌词、未知音素、重复symbols、延音分组/原文版本不匹配；中文/组合字符/emoji不被改写。
- 真CLI正常及中文空格目录，缺损/超大/深层/符号链接/错误输入、同文件输出/已存目标/不可写输出、无stderr/无stdout；完整退出码与源/哨兵摘要前后相同。故障夹具只用本任务文件/描述符，不修改系统或真实作品权限。
- Lead用独立反例/金样例/变形测试复核（平移pitch+12、延长同字末音、一字多音与逐字分开、UUID大小写别名、值为1.0等），独立读取源码并核查副作用，不仅采信Worker绿色自测；非实现者只读review后，组合固定SHA重跑CPU，从源入口复验后接纳/推送。

初交+最多两轮普通修复，必要一次有界Lead接管，不换ID/模型重置；每次执行≤15分钟。每轮前核权限异常与保护状态；未知权限/身份/副作用停报，预先批准的故障夹具与事故区分。历史Xcode阻塞是Lead环境事件，不计Worker代码修复。

未完成门槛独立保留：权重许可/用户下载授权、实际包内ONNX图与运行环境、薄provider及统一取消/释放、真实WAV/音准/咬字/听感/耗时内存、普通沙盒封装/UI。仅CPU条件转换验收后可接纳这一离线模块，不默认启用未测渲染路径；不能称整个歌声阶段完成。用户回来集中处理清单；无需等待其在场才完成本切片。

## 2026-09-15：初交审核与修复1（保留失败）

一个实际实施Worker：D-SINGING-PREP-01，独立外盘树/分支，gpt-5.6-sol/high，CLI 0.154.0-alpha.6.2；请求与3次可观察turn_context一致、workspace-write网络关闭，源/共同Git不在写根。线程`01a0a28c-5c48-7242-b4b0-45a867ebd039`，运行来源R/prep/*-observed.json。隐藏服务解析unknown；没有第二个实施任务，不为并行造工作。

预检首次rg路径误写、exit127，唯一一次预检纠正后通过；初交末尾检查误用zsh只读变量status，改任务变量后通过。两者为工具使用错误，非文件系统权限突破；无观察到成功越界/权限扩大。Lead的route观察器把全部非零命令列issues，初次自动assert因此停住，逐项分类后继续，不把非零忽略为成功。只读审阅者另一次误用系统Git shim触发已知Xcode许可，后用明确直接Git核版本；没有接受许可/运行构建。Lead准备契约时三处歧义先由非实现者指出并在派工前消除，见R/spec-review.json。

初交候选`04fd4935498b74d6b8fdadda36fe227517d03c05`仅两新增文件。Worker与Lead各执行10单元；Lead42独立场景通过，仍不接纳：非实现者发现新调用把任意已有目录交给旧publish_exclusive，O_EXCL临时重名失败后其finally会删除未取得所有权的既有partial。Lead在R/candidate-collision固定token和自有哨兵重现，进程exit1、sentinel_exists=false；仅破坏受控测试哨兵，未触及源/用户作品。旧绿色检查不能抵消这个缺陷。

修复1限定新增准备器和直接测试，原通用助手不在Worker修改范围。要求先留下永久反例的失败，再修所有权取得与清理；保留发布后的文件和原输入。同步加强已有数字UUID大写、混杂JSON等持久测试；冻结规格不变。独立测试方案的六处可产生误判/覆盖缺口在执行前经另一只读审阅发现，Lead修正外部driver后才运行；见R/independent-test-plan-review.json。这是验收设计改进，不是实现者放宽规则。

通用助手在其他调用中的所有权前置条件与潜在同类问题仍属已知技术债，本次不声称全库文件发布已修复；后续复用须先核调用目录/所有权，必要另作共享助手的有界修复和调用方回归。不能把这项开发问题列成需要用户授权的Mac权限问题。

## 2026-09-15：条件准备切片验收与源接纳

Sol/high初交＋修复1完成实现，Lead冻结契约/合成金样例、独立反例、审核及集成；未代写生产实现，未使用第二轮修复或Lead接管。非实现者对初交发现静态碰撞缺陷，修复候选`ca4ca4b49a88cbfa9abda22ca9809c3962816fc3`重新只读审阅后无本轮阻塞。请求与可观察运行设置一致；修复执行基线是初交`04fd493...`完整值见上节，runner/job保留的base是最初准备SHA，并非修复从旧代码开始。证据R/prep/lead-repair1-event-review.json、nonimplementer-repair1-review.json。

修复在新模块内以成功排他创建取得临时文件所有权，解决静态重名误删，保留原输出与发布后同步失败时的已交付文件。异常/finally清理核inode；成功路径直接unlink，因此不宣称所有删除均经过inode守卫或能对抗并发恶意目录/文件替换。公共旧助手未改；现有SA3/MRT2要求初始空job，应用宿主另以排他mkdir创建独立0700目录，CLI只检查空目录，故暴露面不同但不是已修复证明。P2共享助手定点修复仍需调用方回归，见R/shared-helper-impact-review.json。

集成树合并保留全部历史，受测组合`790d5dc5230ee229a413505922fc00c1f8d2792c`。源从`347cdfeafe042b1df8db3657adaa04e11ffba6e5`快进到同一SHA，并从源目录真实调用同一代码复验，不仍指向Worker树。最后仅四份文档更新；最终源SHA/推送结果见R/final-receipt.json，不为自身SHA反复提交，不把后续文档版本写成重新测试。

| 检查 | 实际结果与版本 | 独立证据 |
|---|---|---|
| 两文件语法 | tokenize.open＋内存compile通过，不生成目标pyc、不使用Apple工具链 | prep/repair1-events.jsonl；Lead独立driver另编译实现 |
| 永久单元/真实CLI | 修后17方法通过；包含先失败后通过的静态碰撞、Unicode/ID/映射、输出保全与完整CLI退出 | repaired-unit；combined-unit；source-unit，各自独立执行不相加 |
| Lead独立反例 | 同一42场景修后/组合/源各42通过、0失败；覆盖等值float/bool、单错重复键/非有限/深层、中文空格路径、只读及真正关闭FD、目录/输入/输出保护 | repaired-independent；combined-independent；source-independent/cases/summary.json |
| 独立碰撞复现 | 初交exit1且哨兵消失；修后/组合/源exit0、哨兵原字节保留且不生成目标 | candidate-collision（保留失败）；repaired-collision；combined-collision；source-collision |
| 既有音频CPU | 原21方法在组合及源各通过；未修改其断言/助手 | combined-audio-regression；source-audio-regression |
| 真歌声/应用 | 未运行新模型、WAV生成、音质/取消/资源、Swift构建或GUI；无新App能力 | H20/H21与source-acceptance.json；不算跳过即通过 |

全部检查使用已有外盘Python3.12.14，具体命令、cwd、时间、子进程退出及环境见各目录request/result.json；临时/缓存分别在独立run子目录。组合与源的实现、测试、四份夹具摘要完全一致。四个fixture文件是一组Lead自编金样例，不是四个真实模型样本；42独立检查与17永久测试有语义重叠，不加总成产品通过率。

可观测CLI进程耗时：预检约45.10秒、一次纠正约17.85秒、初交402.35秒、修复1为265.94秒。逐次CLI usage快照保存在R/current-run-usage.json，resume可能报告会话累计，因此不直接累加，cached input不再加到input；未声称任务级精确token增量、完整Lead归因或订阅费用。实现模型路由与有限交付已证实，单个样本不证明最优成本或所有歌声/Swift任务胜任。

恢复检查点：本轮自有CLI/测试进程均已结束，研究/非实现者审核只读任务结束；工作树/分支/历史证据保留，无后台继续承诺。源索引干净，唯一未暂存个人scheme仍orderHint1→6，SHA256`ca3635d88aa5a15397b90e528667c66c0e6db7e596176e885c79d194b544206c`、索引blob`9c76916bdc97c2d4298cefe64e0b0fae3380573e`和完整差异一致；没有暂存该文件。普通D、原作品、签名与既有模型没有被本轮启动/构建/改写；未新增录音、权重或环境。

下一动作：Lead先核H21合法材料边界，再于用户返回时集中办理具体下载/环境授权；H20由本人阅读确认Xcode协议后复核工具链。之后沿本任务继续实际图接口/短WAV/取消与资源验证，不能刷新PREP1已耗修复预算。原发布前/后分类和各模态基础→有限组合→发行收尾顺序保持，不自动开展高级歌声编辑器、I2V或下一批。状态是“准备模块已接纳；完整歌声后端待条件”，不是D-MUS02已完成。

## 2026-09-15：真实短歌声阶段实施顺序（SING1/RENDER-PLAN1）

用户要求继续推进并明确下一阶段。当前核验源为 `e47b86abc8c1375f260204dafdefe1f779cf42d7`；[共享发布修复](D-AUDIO-PUBLISH-01.md)已接纳并推送，已关闭上文保留的P2历史问题，歌声准备器现复用修后的共享实现。最近实际代码验收版本是 `3186aba2762850152d285afa50dc7ed7e9e3eef6`，到上述源仅有结案文档变化。本次只补本任务及CURRENT_ACTIONS，不重跑已验收CPU、不实施渲染、不改旧预算；本节是实施顺序与验收准备，不是未知模型图的冻结规格。

**下一阶段出口：一份明确旋律和歌词，生成真正的短歌声WAV；修改一个条件后得到独立新结果，且取消、失败和清理可靠。** 先做薄后端及统一运行时，不先做谱面编辑器、声克隆、完整DAW或新调度框架。应用候选试听、采用、保存重开与导出是随后紧接的装配出口；仅Python渲染通过不算统一后端完成，也不算App已经会唱歌。

### 两个门槛分别处理

| 工作段 | 开始条件 | 本段实际交付与停止点 |
|---|---|---|
| R1 材料检查与真实短句渲染 | H21取得适用使用依据，以及具体材料下载/独立运行环境授权 | 核对原样声库/vocoder摘要、许可材料、模型图与字典；实现条件→预测→声学→波形的最小provider，生成可解码WAV并通过本段反例。可使用已有独立Python，不等待H20；未获准依赖不安装。 |
| R2 统一后端接线 | R1真实语义和结果已确认；H20由本人确认协议后工具链复核可用 | Lead冻结最小值型请求/输出与失败协议，复用现有运行时和子进程生命周期；从正式入口验证歌声、取消后下一任务及既有音频回归。没有编译和实测就不注册为可用能力。 |
| 下一装配出口 | R2通过且可安全进行应用验收 | 在既有声音候选/项目机制接简明条件入口、试听、采用、保存重开与安全导出；另列真实产品验收，不作为R1实现模型图的前置。 |

H21具体询问草稿及权利拆分仍由[音乐路线](../MUSIC_ROADMAP.zh-CN.md#h21最小询问草稿未发送)与[集中清单](../FAILURE_AND_PERMISSION_AUDIT.zh-CN.md#当前集中待办2026-09-14)维护，未发送询问、未取得新材料。只取得适用内部研发依据时可在该范围开展R1，分发/商业输出问题独立保留；用户一般性“继续”不是代第三方授予许可。H20仅影响Apple工具链/Swift与应用，不阻塞已获准独立Python渲染。两个门槛当前均未关闭。

### 先明确的行为与必须等待材料的事实

- 输入仍是有版本的作品乐句、歌词和显式发音；准备器保存原始语义，不自动把HUM自由音高解释成最终乐谱。首轮验证中文、一个合法原样声库和匹配vocoder，使用自编约6秒短句；这只是测试profile，不是所有Mac、所有声库或作品长度的产品上限。
- 后端仅负责校验、加载、计算、进度、文件交付和释放；候选比较/采用/项目保存归DWorkbench。复用 `Sources/DInference/InferenceBackend.swift`、DRuntime、`LocalProviderProcess.swift` 与已修复的 `d_audio_contract.publish_exclusive`。不照搬SA3专用报告字段/latent假设，不把歌声塞进MRT2的25Hz条件，也不从现有AudioRequest的44.1/48kHz分支猜测歌声采样率。
- 每任务冻结输入版本与实际参数；修改歌词/音高/时值后另建任务和产物，原件及上一结果不覆盖。当前拟支持整句重新渲染，不承诺只改变指定音频区间，更不承诺区间外PCM相同。作品条件精确保留与声音近似服从分别记载。
- **材料检查后、派实现前才能冻结：** 图输入输出名称、shape/dtype、音素字典与编号、预测时长/F0时间基、mel与vocoder匹配、采样率/声道/尾部处理、可用执行设备/精度、随机性和可设置参数。prepared `.ds` 不是已验证ONNX张量契约；未知能力不虚填默认值，不静默补音素、改调、量化或换权重。额外依赖/模型转换如有必要，先按原授权边界处理。
- 输出以WAV文件引用及可关联记录交付：源乐句/发音版本、实际模型与vocoder固定标识/摘要、实际执行参数/精度、媒体格式/帧数/时长/文件摘要、运行状态与资源记录。公开媒体不混入Agent提示词或私有路径。文件校验与发布后才成功，成功作品不因release删除。

### 分层验收，不先替模型编造音质结论

| 类别 | 必须覆盖 | 判定与证据 |
|---|---|---|
| 条件与旧行为 | 原准备器完整回归；休止、一字多音、未知音素、非法/过期版本、不支持条件 | 原冻结CPU/真实CLI判定保持；反例必须可单独失败，不能靠其他错误顺带拒绝。 |
| 真实声音 | 自编短句；同句仅改歌词、仅改音高、仅改时值的独立对照 | 真正解码WAV，帧数/格式与报告一致、PCM有限且非全零；记录音高/八度、起止/时值偏差、可辨歌词和明显噪声。信号检查不等于唱准/唱清；人耳听感另列，不承诺逐像素/逐采样点确定性。 |
| 质量门槛 | 首批材料探针的范围与参考、自动指标定义及人耳清单 | Lead在正式适配实施/接纳前，根据模型实际声明和先行探针固定可检查标准；记录未校准项。不能等看到候选失败后降低阈值，也不能只用退出0宣布有用歌声。 |
| 生命周期 | 加载/预测/声学/声码器边界取消、错误退出/超时、取消后再生成 | 计算和子进程/管道确实停止与清理后才交接；不承诺GPU瞬间中断，不能仅按钮变更。 |
| 文件与失败 | 缺失/损坏/不匹配材料、写盘失败、已有目标、结果格式错、消费者失败 | 明确失败或取消，源输入与既有结果不变；只有任务拥有的未交付临时文件可清理。沿共享发布已验规则，不改旧断言。 |
| 资源与集成 | 冷启动/重复短句/失败后恢复；R2中的音频与其他重任务交接 | 记录加载、首个可用音频、总耗时、吞吐、CPU/RSS及可测设备分配/缓存、取消清理时长；不可测项unknown。峰值低或cache=0不单独证明无泄漏；模型/精度与本机实测范围分开。R2再按影响复验现有SA3/MRT2及统一执行所有权。 |

### 派工与当前恢复点

Lead负责材料/质量判断、真实图契约、共享Swift类型和装配；接口就绪后由一个受限Sol/high Worker实现模型适配，独立审核可同时准备反例，重推理由Lead串行。准确允许路径、模型可观察设置、依赖/执行基线和测试预算在发IMPLEMENT前记录，不先给整个后端目录修改权。只有另有独立、可验收工作时再增加Worker。本次一个现有代理只读核查范围，无实施Worker、无新模型身份或隔离机制验证。

PREP1初交＋修复1的历史及剩余预算不变；新渲染切片在原任务内明确范围与执行记录，不能用它重试已超预算的旧缺陷。当前就绪度：准备器和共享保存已完成；真实图/音质/渲染/Swift接线尚未实现，两门槛解除前不继续造辅助脚本或未测接口。HUM必要音符修订、普通试听/MIDI及I2V保留独立路线，不以全歌声编辑器为前置，也不在等待中自动改换任务。

本次规划基线/保护与审核证据位于 `D-Development/AgentTrials/D-SINGING-BACKEND-01/run-20260915T044415Z-render-plan`，最终文档SHA/推送与恢复状态由其中 `final-receipt.json` 记录。个人scheme原字节、索引和未暂存状态须保持；普通D/用户作品/签名/模型未操作。恢复先核源HEAD和清单答复；最小下一动作是办理H21适用材料依据及具体授权，H20可独立办理，不承诺后台继续运行。

## 2026-09-15：长期开发下载授权与R1材料接口核验

用户明确批准既有H21询问发送，并长期批准阶段内开发模型下载及独立环境必要依赖，只有必须在Mac附近操作的事再询问。阶段目标审批、隔离/数据/精度/原修复预算不变，不代第三方扩展许可。Lead已通过已连接邮箱发送限定询问，返回SENT；没有附件、工程/录音外发或费用承诺。邮件内容/响应与联系元数据仅在外部R=`D-Development/AgentTrials/D-SINGING-BACKEND-01/run-20260915T060900Z-materials`的`h21-sent.json`，不复制个人邮箱/线程ID进Git。

许可只读复核确认：可按绮萱v2.7.0明确允许新推理程序的条款，限定取得原样完整声库并读取调用所需外部接口；不涉及内部图/权重分析、转换/优化文件写出或角色图展示。NC vocoder仍等待相关权利方适用依据，未取得/运行。因此R1“材料检查”部分独立前进，没有以一个配套组件为由冻结全部工作，也没有将下载授权等同使用权。

实收原包420707627字节，SHA256与上文官方资产一致；35条ZIP条目/31文件，解包540817652字节，拒绝异常路径/链接/覆盖，完整原包保留。许可PDF SHA256 `092973bd06414c97593e642bf14e2fbf03d0308f7b2d8ad43d59f7ba03a1f313` 与官方同版资产一致；本次未展示人物图。完整文件摘要/配置分别在`original-file-manifest.json`、`archive-configs.json`，原包和31文件前后摘要均一致。

复用HUM阶段已有Python3.12.14/ONNX Runtime1.22.1/numpy2.4.3；没有安装新依赖或调用Xcode。Lead一次性证据探针使用正常session外部`get_inputs/get_outputs`，CPU单线程、禁图优化/禁保存优化模型、独立进程/任务临时和缓存、每进程45秒受控超时。7进程实际均退出0，未调用`run()`、未读取内部节点/权重参数。源码及每次命令/退出/接口形状证据在R/`inspect-model-interface.py`、`interfaces/*/{process,result}.json`及`interface-probe-summary.json`；该探针不是新增产品工具。

| 实际组件 | 已核实的外部接口摘要 | 不能据此假定的语义 |
|---|---|---|
| 时长linguistic → duration | tokens/languages/word_div/word_dur → encoder_out/x_masks；再输入ph_midi → ph_dur_pred浮点 | 字与音素、时长归一与帧舍入/边界补偿仍须核对公开调用实现，不能直接用浮点预测当最终整数时长 |
| 音高linguistic → pitch | tokens/languages/ph_dur → encoder_out；note_midi/note_rest/note_dur、pitch/expr/retake/steps → pitch_pred | note_midi为float，retake为`[1,n_frames]`bool；输入曲线单位/初值/重复采样行为未实测，不能凭名称填0 |
| 表现力linguistic → variance | 独立语言编码输入；pitch/breathiness/voicing/retake/steps → breathiness_pred/voicing_pred | retake为`[1,n_frames,2]`bool，与pitch不同；音素表不可跨阶段复用整数编号 |
| acoustic | tokens/languages/durations、f0/breathiness/voicing/gender/velocity、标量depth/steps → `[1,n_frames,128]`float mel | 配置声明44100Hz/hop512/自然对数Slaney mel、匹配指定vocoder；depth上限0.6不等于应默认0.6；没有实测推理精度/速度/声音 |

7个接口可读不等于7个真实演唱测试；session读取最大RSS约79–673MiB含加载和校验，不是推理峰值或产品内存预算。没有音频输出、音质/取消/重复推理/正式运行时/GUI验收，没有实施Worker或生产重写。两个现有只读代理仅复核许可范围和材料接口；没有重新验证模型路由、重算旧token/费用或消耗PREP1修复轮次。

当前源起点 `31fcaf870248c96883ff10e815a9c81eaac01084`；只在既有Lead隔离规划树更新五份文档，生产代码仍对应已受测`3186aba2762850152d285afa50dc7ed7e9e3eef6`。最终源SHA/推送/保护/进程状态见R/`final-receipt.json`，不将后加文档冒称重新运行CPU回归。邮件和大材料只在外盘证据，不入Git；普通D、原作品、个人scheme原字节/索引/未暂存状态保留。

下一动作仍属本阶段：后续恢复先核相关邮件答复、许可范围、源与材料摘要；允许范围明确后无需再次询问开发下载，取得匹配vocoder、固定公开调用语义和先行质量标准，再派正式provider实现。外部等待项H21与本人Xcode协议H20分开，阶段未完成，不自动进入下一阶段或声称后台已继续。


## 2026-09-15：R1上游原样模型数值探针（不含声码器）

上节接口读取完成后的追加进展，仍使用同一R。用户的长期开发授权与声库允许原样推理/新推理程序的依据独立于NC声码器；本次不取得/运行声码器、不改变权重、不读取内部节点/参数、不展示人物图。固定官方OpenUtau调用参考 `9699944ead5a3b27b59bdf5a35f73fada8c11b7b`，但未证明它与声库发布版本绑定；具体路径/符号/单位见R/`official-call-semantics.md`。四份原始音素表各149键、编号不通用；实际模型声明的steps/depth为标量，不能照搬参考C#包装器的单元素数组。各阶段使用独立原始字典和编码器，不修改配置中未被该调用路径使用的旧variance文件名。

Lead先冻结R/`numeric-probe-spec.md`，SHA256 `e9a4a8a63218db8423daefc8cdb5ec94ec732731517f81431e45fbbcee3473a6`，再编写外部一次性数值探针 `probe-upstream.py`，执行源码SHA256 `637b8aa8fe9fd83cb5b3fca878e4441168cc4309b1aca2865d6d2f04fe91cf5e`。非实现者只读预审指出推理尝试标志应在真实调用时设置、原件后验应由父进程在退出/超时回收后执行；两项在第一次运行前修正，见`numeric-probe-review.json`。这是证据实现的预审纠正，不是生产Worker修复轮次或歌声后端接管；PREP1旧初交/修复1和预算不改。

| 本次验证 | 实际输入、结果与边界 |
|---|---|
| 自编夹具 | 三个`zh/a`元音，每字一个音素/音符，MIDI60/64/67；无辅音、休止、连音或padding。每个锚点86帧，共258帧，44100Hz/hop512约2.995374秒；不是原计划六秒完整歌词质量样例，也不经过prepared CLI。 |
| 时长 | 原始预测81.36216/89.04409/87.07842帧，随后按单元音锚点归一为86/86/86；不把对齐后的时值写成模型原始预测。 |
| 音高/表现力 | 音高用半音传给variance，换算Hz传给acoustic；音高分段中位数60.12212/64.04909/66.98911，仅为观察，无准确率/唱准门槛。variance retake为`[1,258,2]`，与pitch不同；steps分别10/20/20、acoustic depth0.6，其他显式中性条件见规格。 |
| 数值检查 | duration encoder/head、pitch encoder/head、variance encoder/head、acoustic共7段顺序完成；输出名称、类型/形状、有限值等预置检查通过。mel为`[1,258,128]`，范围约−11.463至0.657，标准差约1.989；不是可播放音频，不证明音质。 |
| 时间/资源 | 既有Python3.12.14/ORT1.22.1/numpy2.4.3、CPU单线程、禁优化文件保存。子进程全程4.876秒，父进程观察5.344秒，macOS RSS高水位817086464字节；包含导入、摘要、加载及计算，不是纯渲染峰值、GPU预算或泄漏证明。随机seed可控性仍unknown。 |
| 文件/进程 | 输出独占新目录，180秒超时/5秒宽限与自有进程回收预置；本次一试成功、exit0、未超时、已回收。原包及31原始文件后验全部一致。未执行取消/强杀路径，不把配置了超时写成这些路径已验收。 |

实际命令、环境、PID/退出、完整逐段形状/时间与保全见R/`numeric-probe/{launched,process,result,protection-after}.json`，各段NPZ保留为外盘证据，不入Git、不覆盖已有结果。源码未导入/执行目标生产模块；未启动GPU、GUI、Xcode、普通D、扬声器或安装依赖。阶段仍待匹配vocoder适用许可后生成WAV、完整短句与条件修改/取消/失败/重复释放验证，再做R2接线，不能将这次上游通过登记为完整歌声能力或阶段完成。

源/规划树追加前均为 `600411647db4022d9fd77b1cc4ba018f15fc1272`；本次只更新本任务、CURRENT_ACTIONS、MUSIC_ROADMAP与集中待办四份文档。上次生产代码受测仍为 `3186aba2762850152d285afa50dc7ed7e9e3eef6`，不为文档变更重跑旧CPU。最终文档SHA、推送和新增文档审阅在R/`final-receipt.json`，先前`local-integration.json`/`push.json`保留6004116材料快照不覆盖。当前限定邮件一次只读检查尚无外部回复，不承诺后台监控；H20仍待本人Xcode操作，H21是外部许可等待而非再次向用户要下载批准。

恢复检查点：已完成原样声库取得/保全、7接口读取、公开调用核对及一次上游数值链；未完成vocoder/WAV和R1/R2验收。个人scheme原字节/完整差异/索引及未暂存状态保留、源索引干净，当前自有模型子进程已结束；模型、工作树、失败历史和原证据保留。恢复先核源HEAD、许可答复和材料摘要，沿本阶段继续，不自动进入下一产品阶段。
