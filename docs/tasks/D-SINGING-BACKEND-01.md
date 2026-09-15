# D-SINGING-BACKEND-01：旋律与歌词的歌声薄后端

当前状态：SING1/PREP1输入准备及R1-TIMING1离线时序组件已验收并源接纳；原样声库已取得，匹配声码器适用依据及H20工具链仍待处理，真实WAV/R2与D-MUS02未完成。初始源基线 `347cdfeafe042b1df8db3657adaa04e11ffba6e5`，源分支 `codex/inference-foundation`。规格 SING1 / PREP1 / spec1；执行基线记录在派工 JSON，不自引用。

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


## 2026-09-15：R1续行6秒乐句至mel实测与剩余门槛

用户批准继续真实歌声后端。源/既有Lead规划树起点均为 `55336d63d90eff814043f33043dc96318e30d9a7`，未提交差异仅源个人scheme。新证据R=`D-Development/AgentTrials/D-SINGING-BACKEND-01/run-20260915T073451Z-r1-continuation`，旧run不覆盖。H21相关线程一次只读复核无外部回复；限定2个vocoder核查结果在`vocoder-alternatives.json`及MUSIC_ROADMAP最新节，不安装/下载替代、不新增对外联系，不把源码MIT外推至所有权重或把频谱维数相同当兼容。

### 本次实际输入与实现边界

新外部自编样例6秒：0–0.5休止；“啦”C4 0.5–1.5/D4 1.5–2（同字两音）；2–2.5休止；“呀”E4 2.5–4；“啦”G4 4–5.5；5.5–6休止。显式`zh/l zh/a`、`zh/y zh/a`来自原bank各阶段字典，没有自动G2P；原库synthetic金样例不修改。既有源`d_singing_prepare.py`真实CLI输出与Lead事前手写expected逐项相同，原phrase/pronunciation语义及字节保留；见`phrase-fixture/*`、`prepare-result.json`、`prepared/prepared.json`。这是新数据经过旧生产入口，不是修改生产模块。

只读代理核定固定OpenUtau `9699944ead5a3b27b59bdf5a35f73fada8c11b7b`的调用事实，精确位置在`phrase-mapping-review.json`。duration按休止分两组，word_div分别[2,1]/[2,2,1]，word_dur分别[43,129]/[43,129,129]；首SP原始预测舍去，首辅音保留原始时长，其余按作品锚点比例分配。两处前置辅音必须仍落在各自0.5秒预留休止内，否则立即停止，不裁剪或改变源音符。SP的语言为0，中文为3，各模型音素编号独立。

D选择在完整0–6秒作品轴补齐SP，再加首尾各8模型帧；所有边界累计量化，原note/lyric记录不变。全帧pitch_pred原始半音→variance、全帧转Hz→acoustic，包含SP，不误用显示曲线的voiced mask。这些是本次显式实验装配选择，不声称与OpenUtau完整路径等价；没有WAV就不能说休止静音或音频边缘裁剪通过。固定规格`phrase-probe-spec.md`／外部脚本`probe-phrase-upstream.py`的摘要见`phrase-probe-precheck.json`，非实现者预审`phrase-probe-review.json`无阻塞，要求父进程保护并保证PYTHONOPTIMIZE=0；实际执行具备这些条件。

### 实际结果

| 检查 | 证据支持的结果 |
|---|---|
| 语法/既有入口 | 源准备CLI exit0、stdout空，手写expected一致；新实验源码用tokenize.open＋内存compile，无目标pyc，不调用Apple工具链。 |
| 原模型计算 | 一次CPU实验完成两组duration encoder/head共4次、pitch encoder/head、variance encoder/head及acoustic共9次调用；所有声明形状/类型与有限值检查通过。不是9个独立歌声测试。 |
| 时间保全 | 首“啦”辅音约0.415741秒开始，“呀”约2.404690秒开始；两者均在源预留休止内。元音/后继辅音以作品锚点分配，一字两音只保留一个元音；phone和note总帧均533。原作品6秒；含内部padding模型跨度约6.188118秒，不能写成已交付音频时长。 |
| 实际输出 | mel `[1,533,128]`，范围约−12.0634至1.03957，标准差约2.49985；仅记录观察值，无音质阈值/唱准保证。Lead另读回9个NPZ核名称/形状/有限值、累计边界和帧总和；不是另一个模型执行测试。 |
| 资源与保全 | 既有Python3.12.14/ORT1.22.1 CPU、单线程、禁优化文件保存。子进程9.167秒，父进程9.584秒；全子进程RSS高水位832339968字节，含导入/摘要/加载/计算。180秒受控超时预置，本次正常exit0并回收；没有运行取消/强杀/重复释放，不能证明这些路径通过。31原文件、原包、三个fixture及prepared共36个输入后验均不变。 |

运行与完整帧表见R/`model-phrase-run/{launched,process,result,protection-after}.json`；外部脚本SHA256 `36b2cd9fede765ec6ef301e8a700df6e8e72e28265cb55475a4b0eb48450fde7`；父进程环境明确PYTHONOPTIMIZE=0、-B、自有tmp/cache，仅本次子进程终止/回收权限。没有声码器、WAV、扬声器/GUI/GPU、Swift或普通D操作。`lead-phrase-output-check.json`另存输出摘要，原31文件/原包沿用上run固定摘要，未改模型/精度。

### 来源、状态及后续

本轮两个既有代理只读：调用语义核查；替代材料核查及独立预审。Lead负责新数据、一次性外部实验、真实执行、读回复核、文档和集成，没有实施Worker或生产代码重写；一试成功，无修复重试，不刷新PREP1旧初交/修复1预算。可归因实验墙钟如上；本轮完整Lead token/订阅费用unknown，不重算历史费用或由此宣称成本最优。

**阶段状态：R1上游语义/数值准备推进；完整歌声后端仍受阻，未完成。** 不用相同类别mel探针无限替代真实WAV出口。当前明确缺口为匹配vocoder适用许可、完整短WAV与改歌词/音高/时值对照、取消/错误/重复释放、正式provider与R2；H20本人Xcode协议阻塞Swift/应用，不要求再次批准开发下载。下一事件恢复先核相关回复/材料/源，依据充分后固定质量与失败矩阵、受限Worker实施薄provider、非实现者审核、Lead串行真实验收。R1/R2通过后，下阶段仍是歌声工作台候选试听/采用拒绝/保存重开/安全导出；不启动高级音乐编辑、其他新模态或新的协作试点。

只修改任务、当前行动、音乐路线与集中待办四份现有文档，代码仍对应上次受测 `3186aba2762850152d285afa50dc7ed7e9e3eef6`；新数据实际调用源版本55336d6完整值如上，外部实验按独立脚本摘要关联，最终文档SHA/本地接纳/推送写R/`final-receipt.json`。源个人scheme完整内容/摘要/索引/未暂存状态保持，未暂存它；旧产物/作品与模型原件不动。自有准备CLI和模型进程均已结束，两个本轮只读工作完成；工具另列历史`creative_workflows_research`为pending_init，本轮未派该任务、未观察其写入、没有把它宣称已结束或建立系统写锁，详见恢复回执。


## 2026-09-15：R1-TIMING1 离线时序组件（规格1，执行前冻结）

用户暂不能操作Mac，批准先完成当前可独立进行的工作。上游真实接口及两组数值已有依据，现在将其可独立验收的时长逻辑变成后端内部组件；覆盖此前“材料等待期间不做任何实现”的调度结论，不降低R1真实WAV或R2门槛。task_id仍D-SINGING-BACKEND-01，slice/contract R1-TIMING1，spec_revision=1，source_base=1d3305ef0e8b0538aa9f78fc1a9fb9509f9b9d61。run为D-Development/AgentTrials/D-SINGING-BACKEND-01/run-20260915T095325Z-timing；执行基线在timing/job.json记完整SHA。

目标：验证后的作品/显式发音→不可变duration请求→已有预测的锚点对齐→音符/音素共享累计帧表。只用标准库，不新增CLI、序列化协议、模型注册、运行时或UI入口，不加载模型、不写WAV、不猜G2P/音高/音色曲线。六秒/533帧/0.5秒context/8补帧仅为已测样例。组件不是通用所有DiffSinger模型或所有发音法兼容声明；实际tensor IDs、F0、声码器、静音/音频裁切、质量和生命周期仍待R1。

### 文件所有权、入口和不变量

Worker只新增 `Backends/Audio/Python/d_singing_timing.py` 和 `Backends/Audio/Python/tests/test_singing_timing.py`。Lead维护本节及自编/实测记录小夹具 `Backends/Audio/Fixtures/Singing/timing-v1.json`；不改变已有prepare/helper/旧夹具/测试/Swift/工程/依赖/模型。新模块导入复用 `prepare_singing_plan` 和 `ContractError`，不得复制/弱化旧校验；不使用assert作为输入校验。不在模块导入或函数中做文件、环境、网络、子进程或模型操作。

两个冻结函数（具体内部结构由实现者决定）：
- `build_duration_groups(phrase, pronunciations, vowel_indices, *, sample_rate, hop_size, context_ticks)` 返回不可变plan，公开 `.groups`，每group公开tuple `.symbols/.word_div/.word_dur/.ph_midi`。plan保留不可变源身份/revision、时轴及后续对齐需要的数据；不持有可变原输入别名。一次build捕获的plan供同一推理调用使用，外部异步候选/版本失效由未来runtime负责，不将本函数宣称为候选状态管理。
- `align_duration_predictions(plan, predictions, *, head_frames, tail_frames)` 返回不可变result，公开tuple `.phonemes/.phoneme_durations/.note_durations/.note_midi`、整数 `.frame_count/.source_duration_ticks` 和 `.source_intervals`。每个source interval公开 `.phoneme/.start_tick/.end_tick/.unit_id`，单位是微秒，允许Fraction精确有理数；SP间隙unit_id=None。source_intervals不含模型首尾补帧；note_midi对真实休止及补帧保留None，禁止为未来pitch模型猜填音高。真实声学静音并未因此获得保证。

复用旧严格phrase/pronunciation校验；vowel_indices是与lyricUnits同长的list，休止恰None，有声恰一个非bool整数索引，落在该unit音素数组内。这表示一个显式元音锚，后继noteIDs属于同字延音；不重复音素、不从音素名字推断锚。多个独立元音锚/自动发音分析不在这个profile内。sample_rate/hop_size是显式正整数，最多Int32.max；context_ticks显式1…600000000整数；head/tail为0…Int64.max整数。bool、等值float、未知类型均拒绝，所有生成帧计数须落在Int64内，不分配逐帧数组。新profile仍须另行实测，参数化不等于支持所有采样率。

### 时长模型请求规则

按源休止拆分连续有声units；每个group首插一个模型context SP，其余符号依unit原序连接。第一个真实元音的音素索引（含SP）及后续每unit元音索引组成锚点；word_div是[0→首元音、相邻元音、末元音→group末尾]的音素数。令anchors为各unit首note的startTick，最后补末unit最后note的endTick；首再插groupStart-context_ticks。定义I(t)=trunc(t*sample_rate/(1000000*hop_size))，向零截断。word_dur是相邻I端点之差，不是独立区间floor，负context起点不可用Python负数整除代替；各项须>0。context只供encoder，不能增加来源可用休止。ph_midi按word_div分段填充：context段（首SP及首元音前的辅音）用首unit首note pitch；其后每个元音锚间段用该起始锚unit的首note pitch。因此下一unit锚前辅音属于前一锚间段，第二实测组为[64,64,64,64,67]；不能按词法所属unit填成[64,64,64,67,67]。延音的后续音高仍留在源notes，不改source。

### 预测对齐与累计帧规则

predictions为与groups同长的list，每项为与symbols同长的list；元素仅Python int/float（非bool），严格正、有限，长度错误/NaN/Infinity/0/负数拒绝。模型数组调用者应显式tolist，不引入numpy依赖。首context SP预测校验后舍去，不占作品轴。

对每组：首元音锚前的真实辅音保持预测帧×hop_size/sample_rate换算的原始时长，反向放在该元音源起点之前；允许窗口仅该组之前连续源休止（或作品0），不能借用虚拟context。超出立即ContractError，不能增加前导作品、裁剪预测、借前组声音或悄悄压短辅音。恰好落在允许窗口起点可接纳；零长剩余SP不生成。

首元音及后续音素按相邻元音锚/组末尾之间的预测权重比例铺满对应源区间（包括下一unit的锚前辅音）；首元音必须仍对齐其unit首note起点，末锚为最后unit最后note的endTick。一字多音仅延长同一元音所在锚区间。各有声组外的原作品空隙补显式SP，保留原作品0…durationTicks覆盖；同组后的源休止不被吞并成音素。

采用精确有理数计算/累计边界：整数预测精确保留，float用as_integer_ratio/Fraction(float)保留传入的二进制精确值，不先str转十进制、不经float中间和/比值。不独立round每段或先用近似秒数再凑总长。定义 `q(t)=round_half_even(t*sample_rate/(1000000*hop_size)+1/2)`；q(0)=0。body音素/音符帧数为相邻q差；任一正源区间压成零帧立即拒绝，不改最短1/合并/排序。head/tail在body量化之后独立加入（为SP与None音符，仅>0才出现）；不能把奇数head放进half-even舍入改变body。总帧=头+q(sourceDuration)+尾，phone与note总和相同，source_intervals不被量化值覆盖。没有FitDurationSum、音频裁切或零F0策略。此D内部装配规则对旧8帧实测例应严格匹配，不声称完整OpenUtau路径等价。

### 验收与反例

- Lead固定timing-v1.json：两组duration输入与已记录实测完全相同；预测对齐的phone[8,36,8,129,35,8,117,12,129,43,8]、note[8,44,86,43,43,129,129,43,8]、总533一致；源六秒与补帧分离。原文件/原dict不变、输出不可变；原dict事后修改不能改变plan结果。
- 合成边界：无前导休止且首unit为元音可通过；有辅音但无可用休止拒绝；恰占可用休止可通过、超一微小量拒绝；多个/首尾休止、单/多音素、同字多音、音高0/127、Unicode/大小写UUID别名不改原值。
- context改变仅改变duration encoder context项，不改变源休止或对齐窗口；head/tail=0及奇数值只影响补帧，总长无漂移。参数显式48000/480及长于6秒的输入，不能按开发机内存/固定样例拒绝。
- 独立截断与累计半偶舍入各有非整数/恰半边界用例；微小音符/音素量化压零拒绝、无最低帧数修补；多个区间不会因逐段舍入累积误差。
- 参数bool/float/负/0、无元音锚/索引越界/错误组数/预测长度/布尔/非有限/非正值分别作为单错反例；无效原phrase或过期pronunciation仍被旧契约拒绝。失败不改输入、无文件副作用。
- Worker自行实现局部测试；Lead另用冻结表、真实记录和变形/反例核验，非实现者读代码/证据。源接纳前在具体组合SHA运行新组件+原17方法prepare/真实CLI及相关既有CPU回归，不运行Xcode、GUI、真实模型或再做mel实验。模拟模型输出检查与引用旧真实预测分开。

### 运行与预算

一个受限gpt-5.6-sol/high实现Worker（时轴/兼容/精度边界需要明确处理），另一个现有只读代理核契约/审核；Lead管理共同文件、反例、组合和推送。模型/effort/cwd/sandbox以本次请求及可观察turn_context分别验证。Worker工作树D-Worktrees/D-SINGING-TIMING-01；网络关闭，写根仅该树和R/timing/output、R/timing/tmp，共同Git/源/模型/旧证据只读且禁敏感访问。预检不实现，Lead发IMPLEMENT后写。不得派生/提交/改规格。

只用既有外盘Python3.12：`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-VIDEO-V0-01/run-20260913T152419Z/venv/bin/python -B`；语法tokenize.open＋内存compile，不exec目标、不默认py_compile。实际单元运行的TMPDIR/D_TEST_TEMP_DIR/cache只在本run批准目录，-B/PYTHONDONTWRITEBYTECODE防目标pyc。未知权限/身份/副作用立即停报，预期受控失败夹具另记。每次≤15分钟，初交+最多两轮普通修复、必要一次有界Lead接管；新切片预算不能刷新PREP1已发生的初交/修复1历史。未经许可WAV、音质/取消/生命周期、Swift/provider和App仍未完成，不自动启用歌声能力。

派工前非实现者规格核查发现ph_midi文字与既有实测不一致、float精确解释未写清；Lead在首次IMPLEMENT前固定为锚间赋值与二进制精确Fraction，未改金样例/旧证据，不计Worker返工。两项属于说明歧义，不能记成模型实现失败。


## 2026-09-15：R1-TIMING1组件验收与源接纳（歌声阶段仍进行中）

用户暂不能操作Mac，Lead选择同一R1内已就绪的纯数据实现，不催解锁、不再询问已批准下载。源从 `1d3305ef0e8b0538aa9f78fc1a9fb9509f9b9d61` 经隔离准备 `00674d914fc71cec1e21178478c03063efac6f00`、Worker候选 `08a54960a8619bc16319d3ea93446dda3576b04d`，快进至本轮实际组合/源受测 `3940c9cfa39f89be1feaef8ee1c005f14c2516b1`。后续本次结案仅四份文档，最终SHA及远程结果写R/`final-receipt.json`，不冒称重新测试结案提交。R=`D-Development/AgentTrials/D-SINGING-BACKEND-01/run-20260915T095325Z-timing`。

真正新增的内部能力：两函数构建不可变duration请求并对齐模型预测，复用旧严格准备器；context、真实源休止、最终head/tail分开。音素按显式元音锚排列，锚间音高与词法来源各自保留；正源区间压成零帧或辅音越界明确拒绝。使用二进制精确Fraction与累计边界，输出只到音符/音素时序，不分配逐帧张量。模型采样率/hop、context和补帧由显式参数输入；6秒/533帧与48kHz/24秒为不同层次的夹具验证，不宣称真实声库支持全部配置。plan只限由builder产生的内部对象，不是外部可反序列化可信协议；异步候选/版本失效仍由后续runtime处理。

| 验证入口/类别 | 本轮结果与限制 | 证据 |
|---|---|---|
| 新永久测试＋旧prepare真实CLI | 最终10＋17方法通过；初交为9＋17。Lead按非实现者建议新增一个11行phoneme零帧永久反例，生产实现未改 | `candidate-unit`、`combined-unit`、`source-unit`；各次独立执行不累加 |
| Lead独立检查 | 39场景通过：真实上游预测记录金值、上下文/休止窗口、奇数/零补帧、端点截断与半偶边界、二进制微小越界、不可变和词法来源、48kHz/长于6秒、异常输入。只读取已有预测，不再调用模型 | `lead-timing-check.py`、`{candidate,combined,source}-independent`；函数文件/进程tripwire不等于全系统副作用证明 |
| 既有音频CPU | 31方法通过，断言和生产助手未修改；没有Swift/真实生成/GUI回归 | `{candidate,combined,source}-audio-regression` |
| 语法/审阅 | tokenize.open＋内存compile通过，生产代码无assert验证；两份源码及模块顶层/调用副作用由Lead和非实现者检查。新源码目录无本轮pyc | `lead-source-review.json`、`nonimplementer-review.json`、`test-enhancement-review.json` |

一个实际受限CLI实施Worker，线程 `01a0a483-cbbb-7081-86c1-e5d093b3fe1b`，请求及两轮可观察turn_context均为 `gpt-5.6-sol/high`；工作树 `D-Worktrees/D-SINGING-TIMING-01` / `codex/d-singing-timing-01`，写根仅该树及R/timing/output、tmp，网络关闭，共同Git/源不在写根。初交通过，普通修复0；未使用Lead生产接管，PREP1既有初交/修复1历史未改。Lead贡献为契约/夹具、独立检查、一个永久测试、审核与集成；两个现有只读代理分别核查调用/实现及规格/验收设计，没有另一个实现者重写。角色/模型来源不是质量证明，隐藏服务解析unknown。

审阅者派工前找出ph_midi文字歧义和float解释缺口；独立检查预审另改进对象比较、IO证明范围、嵌套不可变/来源和半偶边界，均在首次对应执行前修正。审阅者一次误用系统Git管道触发既有Xcode许可提示：管道退出0，Git子码未单独记录，因此没有把它当成功读取；未接受协议或运行构建，之后停止该入口。见`reviewer-environment-event.json`，与Worker无关。Worker只有rg无缓存匹配返回1的预期检索结果，未观察到权限扩大/越界；Lead另一次/bin/sed路径错误127已用/usr/bin/sed纠正，无副作用。不得把这些环境操作与代码质量或许可解除混算。

可观察Worker预检66.709秒、初交388.418秒。`usage-observation.json`按阶段保留CLI报告的usage，不把缓存输入/推理输出再次加到总计，不将跨阶段快照盲目相加；完整Lead归因和实际订阅费用unknown，不重算旧试点、不由单一样本推断性价比最优。

恢复检查点：源本轮受测3940c9c完整值如上，个人scheme内容SHA256 `ca3635d88aa5a15397b90e528667c66c0e6db7e596176e885c79d194b544206c`、完整差异、索引blob与未暂存状态逐项保留，源索引干净且只剩该个人修改。Worker及自有CPU检查进程均正常退出/回收；没有启动模型、GPU、GUI、普通D或操作既有作品。原模型/旧证据与两个工作树均保留；历史creative_workflows_research条目仍pending_init，不宣称已终止或获得系统写锁。证据`source-pre-ff.json`、`source-post-ff.json`、`source-acceptance.json`、最终回执。

H20用户暂不能操作，继续清单；本轮只读复核H21既有线程仍仅SENT，无新联系/声码器下载，不声称已扫描所有邮件。**只完成可独立验收的时序组件，整个歌声阶段未完成、没有默认开放新产品入口。** 下一动作仍为取得匹配vocoder适用依据后完成真实短WAV与歌词/音高/时值对照、取消/失败/资源释放，再经H20恢复后做R2运行时接线。本阶段通过后才提议歌声候选试听/接受拒绝/保存重开/安全导出；不以高级文本或完整歌声编辑器阻塞既定HUM必要纠错/普通试听/MIDI及I2V位置。

## 2026-09-16：R1替代声码器与使用资格方向

用户明确不等待外部回信作为唯一前置，采用实际条款/用途确认与替代路线。详情由MUSIC_ROADMAP最新节单一维护；旧邮件/等待/未许可材料状态不倒改，责任声明不授予新权利。当前原歌声R1/R2范围继续有效，没有自动启动完整歌声UI、音乐编辑器或新产品阶段。

本轮Lead取得固定BigVGAN模型95a9d1dcb12906c03edd938d77b9333d6ded7dfb、MIT及关联许可证；仅generator和必要源码资料共489134059字节（另补上游第三方许可证），不下载训练优化器或改声库。外盘R=`D-Development/AgentTrials/D-SINGING-BACKEND-01/run-20260915T160500Z-vocoder-alternative`的`download-manifest.json`逐文件核官方Git blob/LFS SHA，`dependency-install/pip-report.json`固定实际依赖/下载摘要；全在任务deps，不改既有venv或全局Python。源码加载明确本地、weights_only、CPU FP32、禁用CUDA扩展，不在线加载或上传素材。

先行试验用两种源/目标原STFT对同一自编0.5秒校准WAV；源自然log-mel取exp，以32帧块、NNLS history10/maxiter200还原非负幅度，再投影目标频带。源滤组零支持FFT频段明确填零，目标sqrt(s²+1e-9)和log floor1e-5来自固定参考；欠定和源log floor信息损失保留，不能称无损兼容。非实现者预审发现librosa默认优化历史会用约8.7GB工作区，Lead在首次执行前明确有限块/历史；未发生该超额分配。

CPU实验正常结束60.356秒（含导入/首次缓存/加载等），三次原generator分别输出两个22016帧校准WAV及一个272896帧/44100Hz/单声道float32歌声WAV。最后一次声码器16.741秒；进程RSS高水位2791030784字节，不等于独立模型峰值。533帧保留原头尾补帧，约6.188秒不冒充恰6秒作品。三个文件有限非零、无饱和样本；原模型/源码/输入逐项前后摘要不变，自有子进程正常回收。

本人通过afplay实际试听歌声，回复“能听清人声和旋律，没有明显破音”；`human-listening.json`绑定WAV SHA caa02b185e661f8b535b11811415f41aa48405273765313a31a615835f112a82，播放器正常退出。新模型调用/近似投影/本人听感是本轮真实证据，原准备/时序组件未重写，尚未完成改词/音高/时值、取消/失败/资源恢复及生产provider/统一运行时/GUI。不能将先行结果计作完整歌声阶段或替代整个音质标准。

来源：Lead外部实验与材料准备，两名现有代理只读查许可/入口/公式/资源，没有新实施Worker或消耗旧PREP1/TIMING1修复轮次。生产源仍a892aad21eb325b46d65f9d6818def5b5065495b代码；文档版本另记外部回执。资格对话框计划复用AudioModelUsePermission，但需要在真实歌声运行入口检查，不交付空界面冒充功能。

## RENDER1/spec1：原歌声阶段的正式Python渲染切片（2026-09-16）

任务仍D-SINGING-BACKEND-01，子工作包RENDER1、contract SING-RENDER1/spec1；源基线9b3932081e48c68ed02593dc1bf64d5b37fdb6c8，准备后执行SHA以run/job.json完整值为准。不是PREP1/TIMING1重试或新歌声App阶段。先行外部四条件研究验证实际输入/输出，生产实现由受限Sol/high Worker负责；Lead准备固定材料/契约/独立反例、审核及后续Swift接线。首次交付+最多两次明确修复，必要一次有界Lead接管，旧预算不刷新。

### 唯一实施所有权

Worker仅可新增 `Backends/Audio/Python/d_singing_render.py`、`d_singing_qixuan.py` 与 `Backends/Audio/Python/tests/test_singing_render.py`、`test_singing_qixuan.py`。不得改既有准备器/时序/共享发布、验收夹具/源manifest/任务规格/Swift/依赖/签名/工程/其他任务。Lead维护 `Backends/Audio/Fixtures/Singing/qixuan-bigvgan-profile-v1.json` 和原样 `Backends/Audio/SingingVendor`。不下载或触碰原权重；真实模型仅Lead运行。测试可以注入受控引擎/manifest校验器，必须标为夹具，不把假hash当真实权重通过。保留实现选择，不要求按外部探针函数逐行抄写。

### 冻结输入与资格，不把声明当新许可

独立CLI参数恰 `--request <file> --bank-directory <dir> --vocoder-directory <dir> --vendor-directory <dir> --profile <file> --output-directory <newdir>`，均显式绝对路径、普通文件/目录、无任意分量symlink；禁止自动发现/下载/启动App。source request最多2MiB，严格JSON（复用d_audio_contract.decode_strict_json）；输出新目录必须不存在、父存在，与任何输入文件/目录及vendor/profile无包含或相交关系。错误不能覆盖既有输出/原件或删除未取得所有权的目录。

request恰键 `schemaVersion,runID,profileID,phrase,pronunciations,vowelIndices,qualification`。version严格整数1非bool/float；runID规范小写UUID字符串；profileID恰qixuan-2.7.0-bigvgan-44k-approx-v1。phrase/pronunciations复用prepare_singing_plan，vowelIndices复用build_duration_groups；不重新弱化其UUID/Unicode/一字多音/休止/数量/600秒准备预算规则。没有自由prompt、自动拼音、seed、任意参数袋或未支持参数；不静默忽略未知字段。作品输入保留原语义、版本和ID；变更另新run/输出，原件不动。

qualification准确键 `confirmedApplicable,purpose,bankArchiveSHA256,bankTermsSHA256,vocoderRevision,vocoderLicenseSHA256`；confirmedApplicable必须真正true，其他材料身份必须匹配固定profile，purpose仅internalDevelopment/personalCreation/commercialCreation。该值由有权调用方在展示适用条款后提供，不由provider生成、代确认或推断；资格不符在重加载前失败。用途/条款/材料变化旧确认失效。当前只是受明确允许使用的绮萱原样包＋MIT BigVGAN；不能把这个字段用于绕过别的NC限制或证明软件分发权。D自身开发/分发与用户作品用途分开。

profile生产信任锚SHA256=15489802b768fdd5c447325d5483b293601e63db54f46e84eb1c7b84df010a39，source-manifest生产信任锚SHA256=e3f9f9eb2a3cad99b5f75501cbc8b5fd6504257d0c26a69c2f1c817d2c7d0000；两者作为实现常量，不能被CLI参数/环境变量/测试选项覆盖。job记录用于审计，不是唯一信任根。--vendor-directory指向SingingVendor；其中source-manifest.json路径相对其bigvgan/。CLI拒绝非同摘要profile/manifest，严格验证列出的每个bank/vocoder/source普通文件大小和SHA（固定源manifest同样绑定），无缺/改/软链；不扫描附加文件或执行模型JSON中的指令。模型原件和请求/配置的身份+摘要在读取前后及结果发布前再次确认；异常/取消也做保护检查。大文件按块读取计算hash，不把多个模型/文件整份复制到内存。源代码来自明确vendor目录，不用配置触发任意代码导入；Python依赖属于已验证调用环境，provider不安装依赖。重库导入前设置sys.dont_write_bytecode及自有TMPDIR/XDG_CACHE_HOME/MPLCONFIGDIR/NUMBA_CACHE_DIR、离线HF变量；实际缓存路径须在本次拥有目录。拒绝既有同名vendor模块来源不符，明确检验bigvgan/activations/env/utils/alias_free_activation子模块的实际__file__/__path__位于绑定原件，不让sys.modules或其他路径抢占；退出恢复本调用改变的临时环境和sys.path。不要求把完整Python依赖环境当不可信插件执行。

### 实际计算契约

公共可测函数建议 `render(request_path, bank_directory, vocoder_directory, vendor_directory, profile_path, output_directory, *, progress, checkpoint) -> dict`，内部结构可自定；`d_singing_qixuan`保持加载/推理职责，不管全局作品/GUI。checkpoint可在任意已标边界抛专用取消异常。运行记录与终态由render单一发布。

复用已验build_duration_groups及align_duration_predictions：44100Hz/hop512/context500000 ticks，head/tail各8模型帧。每个duration group分别原样CPU ORT linguistic→duration；预测须正且有限、shape/dtype/输入输出名称严格匹配，align只处理给定原模型预测，不改作品。pitch/variance/acoustic按先行已核公开接口；分别10/20/20steps、depth0.6为此固定profile，输入/权重不转换或优化另存。ORT1.22.1、CPU单线程、禁图优化/回退/arena/mem pattern/profiling，每段session释放后下一段。字典/语言编号分模型独立查；SP语言0；note_rest单列，未发声的MIDI只作为内部填充值使用最近有效值（开头用首个有效pitch），不能写回源或宣称休止已经静音。原预测pitch全帧转Hz进入acoustic，不编造seed可控或确定性。pitch初值全帧为首个有效MIDI，expr全1、retake[1,N]全true；variance breathiness/voicing初值全0，retake[1,N,2]全true；两路variance预测裁到[-96,0]，acoustic gender全0、velocity全1。steps为int64标量[]，depth为float32标量[]。输入/输出形状与原始接口对照索引为外部conditions_probe.py（SHA256=cdbab7aaace54a42473c4ac90c270f22e7bc212c488aaf0049b4e2147d6560e5），可按任务索引读取，不要求复制其结构。

acoustic mel [1,N,128] float32；vocoder与之不是精确兼容：exp自然logmel→Slaney 40..16000/2048/128非负幅度恢复→Slaney0..22050重投影。冻结NNLS块32帧、history10、maxiter200；零支持FFT频段置0，目标先sqrt(s²+1e-9)再滤组相乘/log(max1e-5)。全段相对残差定义为||A·S-exp(mel)||₂/max(||exp(mel)||₂,1e-20)，平方和跨块累计后开方；S是支持外频段置0后的NNLS幅度。librosa.util.nnls不提供完整优化状态，不能声称已证明收敛；求解异常或运行/收敛告警直接失败。必须记录该残差并在>0.10/非有限时失败，禁止放大迭代/忽略失败以迎合数据。该0.10是先行校准后、实施前的兼容预算，不替代音质/音高门槛。加载原BigVGAN FP32/CPU、use_cuda_kernel=False，weights_only严格state、remove_weight_norm仅运行内存；不修改权重文件/生成优化模型。原源码forward含±1clamp，记录饱和样本数；不额外归一化、拉伸或修音。

输出原模型N*512 samples；去前8*512，保留roundHalfUp(durationTicks*44100/1000000)样本，验证后端确有足量样本，尾部仅去模型补帧/量化多余样本。nativeFrameCount严格指原WAV样本帧数N*512（不是mel帧数）；saturatedSamples统计交付裁剪片段中abs(sample)>=1的样本数。显式记录原/输出帧数与裁剪，不默默把约6.188秒称为6秒作品。不承诺局部改词/音高/时值只影响局部PCM，只有输入条件精准保留。

### 输出、失败、取消与文件安全

输出目录排他创建0700，内部tmp/cache全部自有；任何目录已存在则拒绝，不采用自动清空。进度stdout JSON Lines每条恰type=progress、runID、stage，stage按顺序validation/duration/pitch/variance/acoustic/vocoder/publish，每段计算前后checkpoint，NNLS每块也checkpoint。CLI SIGTERM/SIGINT仅设置取消标志，下一checkpoint退出；当前C计算可能先完成，不能声称瞬断。结果提交点为result.json排他发布且回读/同步完成；最后一次取消检查在发布result之前。提交前取消要资源释放、保护检查后退出130，不发布成功result；提交后迟到取消不撤回结果，不再checkpoint，完成正常通知退出0（通知失败则1）。诊断stderr。正常/错误关闭重库资源，不保留跨任务全局model。

只交付 `output.wav`（44100Hz单声道float32 WAV）与 `result.json`。两文件在自有目录用已验publish_exclusive排他发布并真实回读（WAV格式/精确帧数/有限非零/摘要；JSON严格解析并核源关联），result最后发布；只有完整result才表示可接纳结果。失败保留自有未发布现场供诊断，不扫描/删除作品；已交付result/WAV不因后续stdout通知失败删除。CLI成功stdout最后恰type=result、runID、resultPath="result.json"，exit0同时要求通知完成；stdout错误exit1且文件保留，stderr也不可写不能改变错误码，不os._exit或退出120。

result准确顶层 `schemaVersion,runID,profileID,status,source,model,audio,execution`；version1、status=rendered。source准确 `phraseID,phraseRevision,requestSHA256,durationTicks`；model准确 `bankArchiveSHA256,vocoderRevision,vocoderSHA256,bankTermsSHA256,vocoderLicenseSHA256`。audio准确 `path,encoding,sampleRate,channels,frameCount,sha256`（path output.wav、encoding float32LE-WAV）。execution准确 `precision,seedControl,nativeFrameCount,trimHeadSamples,outputFrameCount,projectionRelativeResidual,saturatedSamples,stages`，precision="Qixuan original ONNX CPU; BigVGAN FP32 CPU"，seedControl="unsupported"；stages数组元素恰name/seconds（有限非负）。不得把input绝对路径/账户/确认信息/Agent日志写入结果。

初始参数/文件/资格/输入契约失败exit2；模型/计算/报告/输出、运行中保护变化或资源收尾错误exit1；取消130；正常0。缺依赖、坏模型不冒充输入静音。内部异常向调用者保留有效错误上下文，不吞掉所有异常或以空输出替代。发布前取消不得成功；完整发布后通知失败保持有效文件，但退出1。checkpoint异常与原文件保护失败同时发生，报告保护失败，不能用取消掩盖。

### 冻结验证入口与范围

Worker用唯一已指定Python -B；tokenize.open+compile内存语法检查，不py_compile。测试cache/tmp仅job.tmp；网络/模型/GPU/GUI/Xcode/全库构建/全局配置/commit禁止。不得导入完整模型库来做纯契约测试；依赖延迟加载。允许stdlib/numpy局部CPU与受控假运行器/最小张量、已有准备/时序测试。完整模型由Lead串行。

必须持久覆盖：金样例/中文空格路径/组合字符/一字两音/休止及输入不变；bool/float版本、未知字段、坏UUID、未知/空音素、不符元音锚、过期版本、资格false/用途或材料身份不符；profile/源/模型变动、坏/缺材料、符号链接/目录相交/已有输出、失败/取消不覆盖输入和哨兵。Fake渲染只证明编排，不能据此测数值或真实声库许可。

完整CLI退出测试覆盖正常、取消、报告不可写、stdout/stderr失效、通知失败后的有效文件保护；不得只测main返回值。取消duration/pitch/variance/acoustic/vocoder边界与NNLS块、取消后可重跑；异常结束/超时由宿主测试，原件保护独立。数值小测试验证幅度而非功率、epsilon位置、目标尺寸/裁剪、有限值/空音频/饱和计数、投影残差超限单独拒绝，不放宽golden。复用之前fixture/冻结条件，不更换测试基准消除失败。

Lead在固定候选上重做真实baseline/改词/改音高/改时值、只听可辨歌词和明显噪声不是全部音质门槛；真实播放/帧数/中段音高及休止噪声分别核验。先行pYIN仅测量不自称校准正确率；四组固定实测使用librosa.pyin(fmin=150,fmax=1000,sr=44100,frame_length=2048,hop_length=512,center=True)，时间坐标按帧中心sample/44100；音符25%..75%半开区间为稳定窗，休止20%..60%为RMS取样窗。音符有finite正Hz且voiced_flag真才有效，每窗有效覆盖≥80%、abs(median(cents))≤50且p95(abs(cents))≤100；cents=1200*log2(measuredHz/440*2**((69-midi)/12))。空窗/无有效帧不能通过，不选取有利子窗。休止窗RMS≤0.005；交付片段不得有连续44个abs(sample)>=1的样本，所有饱和样本数另记。未知语言/表情/所有声库不在本profile承诺。每任务原件前后保持、计算结束、错误/取消恢复必须真测。质量失败不能只靠本条允许的局部CPU通过接纳。

RENDER1仅独立Python生产入口；R2共享Swift契约/统一运行时接线由Lead协调，在RENDER1验收后继续同一阶段，不把文件probe当R2。歌声资格弹窗和正式App产品闭环按真实入口接入，当前不新增空菜单或标记整个歌声完成。

## 2026-09-16：RENDER1通过，BRIDGE1统一运行时接线（当前规格）

本节接续原R1/R2，不开新产品阶段、不刷新PREP/TIMING/RENDER预算。用户已实际听到R0替代声码器pilot的人声和旋律、无明显破音；PC-NSF NC材料未下载，外部答复不再是本路径前置。MIT BigVGAN与原样绮萱的mel频带不同，明确为近似重投影，不能宣称原配声码器音质或通用商业分发已获许可。实际使用声明必须绑定材料摘要、条款、用途；普通App将来在真实生成入口显示确认，不加无连接的免责声明菜单。

RENDER1候选 `9edd33979e9c5ae12d511907df2feb3e976bd207` 已通过Lead独立53个CPU方法、七个完整CLI反例加一个直接方法取消检查、两个来源/末端路径反例、真正无-B启动检查，以及四个真实条件、三个阶段边界取消和一次重新生成。结果为6秒或6.5秒单声道44100Hz float32 WAV；六秒约42秒，子进程整体RSS高水位约2.78GB，不能称纯模型占用或通用泄漏证明。输入、原权重及固定vendor前后摘要一致，自有子进程已回收。音准/休止/饱和指标通过不代替歌词咬字听感。证据 `D-Development/AgentTrials/D-SINGING-BACKEND-01/run-20260915T163855Z-render/lead/render-acceptance.json`；完整四文件历史和两轮修复保留，Sol/high实施，Lead制定反例、复验及代提交，两个只读非实现者审查，不冒称其执行了模型测试。

### BRIDGE1/spec1契约及所有权

Lead已准备DInference的独立SING1值类型、`.singing`/`.audioSingingGeneration`、仅对已证实输入修改保留失败的运行时分支、旧工作台明确拒绝尚未装配的歌声任务、可选mono WAV校验。没有App歌声注册/按钮、项目schema或签名变化。SING1值保留九字段pronunciations、原UUID拼写/Unicode和Int64；材料revision/profile/symbol按UTF8身份比较。旧AudioRequest、stereo默认与普通取消行为不改。配置SingingBackendConfiguration是显式本地部署值，不执行I/O或自动确认条款。

一个受限Sol/high Worker：BRIDGE1，网络关闭、独立工作树和output/tmp，执行基线/线程/写根见本run的bridge/job.json及preflight-observed.json。只允许新增：

- `Backends/MLX/Sources/DMLXBackend/SingingRequestWire.swift`
- `Backends/MLX/Sources/DMLXBackend/SingingModelInventory.swift`
- `Backends/MLX/Sources/DMLXBackend/SingingProviderProtocol.swift`
- `Backends/MLX/Sources/DMLXBackend/SingingBackend.swift`
- `Backends/MLX/Tests/DMLXBackendTests/SingingWireTests.swift`
- `Backends/MLX/Tests/DMLXBackendTests/SingingBackendTests.swift`

上述是实现所有权，不授权修改既有公共文件/测试、Python、固定profile/vendor、CLI/UI/存储、工程/依赖锁/签名/文档或共享Git。Lead管理共享变更；先只读预检，Lead核实际路由后才IMPLEMENT。初交+两轮针对性修复，必要一次有界Lead接管；每次最多900秒，不因工具延时重置代码预算。未知权限/身份/副作用暂停报告；受控夹具按预期。不得递归、下载、模型或GPU/GUI/全应用构建、提交或push。

必读本节及上方RENDER1/spec1的输入/输出/保护/提交点语义（不用完整历史）；源值SingingRequest/InferenceRequest/InferenceRun、SingingBackendConfiguration、LocalProviderProcess、AudioFileSystem/AudioJSONParser/AudioWAV以及MLXMRT2Backend所有权模式。Task.run输出/缓存固定到bridge/tmp；只读配置/原始输入无副作用；Swift只能在指定module-cache下做新文件parse（不声称typecheck），实际MLX编译/CPU套件由Lead串行运行。无默认py_compile；Python仅既有外盘解释器-B和tokenize.open+内存compile，不执行被检目标。按需参考现有MRT2BackendTests夹具设计，不复制真实模型或整个历史。

### 冻结外部接口

`public enum SingingRequestWire`：
- `decode(_ data: Data, model: ModelReference, vocoder: ModelReference, memoryBudgetBytes: UInt64? = nil) throws -> InferenceRequest`
- `encode(_ request: InferenceRequest) throws -> Data`

使用现有AudioJSONParser，whole≤2MiB、depth32，逐对象准确键/逐字段类型；特别是每个整数字段用requiredInteger，不能AudioJSONValue树相等冒充严格数字检查（该相等将1与1.0视同），不能用JSONDecoder默许1.0/1e0。root沿RENDER1准确七键，lowercase canonical runID成为outer UUID，原source ID大小写保留。缺失midiPitch不是null休止；schema/计数/时间/元音索引不能bool。构造后common validate。编码只变JSON空白/键序，不规范化Unicode/ID、不改值；无未知prompt/seed/default确认。输入本身语义与固定profile准入分开。

`public actor SingingBackend: InferenceBackend`，`init(configuration: SingingBackendConfiguration) throws`；descriptor id=`audio.singing.qixuan`、version=`1`、capabilities只audioSingingGeneration。公开init不提供测试跳过开关。内部测试可注入受控已验证夹具inventory/transport边界，但公共执行路径始终做全部固定profile校验，不接受环境变量/CLI绕过。

estimate只读、无模型导入，验证固定profile/manifest摘要和准确声明的31 bank/3 vocoder/18 vendor文件；原包保持完整，不展示人物图。outer model revision等于bankArchiveSHA256，vocoder revision及声明与profile相符，声明confirmedApplicable必须真，purpose必须明确。所有URL为绝对本地且任何分量无symlink；artifact root与所有输入分离，输入根之间可以重叠。源码、助手、解释器文件、profile、vendor manifest及材料必须可读并封存。固定profile与vendor SHA来自Lead配置，不可调用参数覆盖。禁止扫描发现/安装/下载/外部URI访问。

资源估算明确estimated：例如2×声明材料总字节+1GiB框架工作余量+有界逐帧/PCM工作区，以溢出安全算法说明系数；不是实测RSS，无16GiB/6秒上限或按硬件静默改精度。DRuntime沿调用方显式预算处理，不改全局资源政策。

### 运行与交付规则

沿用LocalProviderProcess、共享MLXExecutionLease和executing/releasing/lease状态，CPU歌声也占一个重任务许可，不声称其数学由MLX执行。该现有许可是跨runtime互斥而非等待队列：另一runtime占用时明确失败，释放后可以重试；同一runtime队列等待release。acquire之后即使输出目录创建失败也到release才放行。release不删已交付文件/诊断目录。

一次execute冻结、重新校验输入，再获得许可，排他创建UUID专属run目录及tmp/cache；request.json排他写，子输出root必须尚不存在，命令恰RENDER1六对参数。启动配置-B、PYTHONNOUSERSITE=1、仅必要PATH/LANG、任务TMP/XDG/NUMBA/MPL目录、offline环境，无继承PYTHONPATH。600秒默认timeout，45秒取消grace，参数必须有限正数。

**drain后无条件保护复核**：成功/异常/取消/timeout/消费者错误均对执行前完整读取的输入做FD/内容/命名身份复核，保留原错误上下文。现有AudioFileSystem.readRegularFile内部会Task.checkCancellation，不能原样用于取消后必须完成的保护检查；采用本地窄streaming seal助手（不新建通用I/O框架），所有路径组件no-follow、首尾fstat、关闭后命名路径/目录身份一致，摘要逐块计算，不把全部权重装进Data。封存失败不伪造未读材料证据。真正观察到变化抛`inputIntegrityChanged`，DRuntime和CLI不得将其变成cancelled。普通错误/取消沿既有语义。

stdout读取沿LocalDedicatedPipeReader有界分块ack/drain，协议总≤16MiB、单行≤2MiB、depth32。准确七个progress按序只一次（validation,duration,pitch,variance,acoustic,vocoder,publish），runID匹配；终端准确三键type/result、runID、resultPath=result.json且只一次、不接受之后数据/未知字段。消费者错误应触发stop、排空双管道和child；进度不是成功证据。不要重写共有transport。

child结束后独立读取result.json/WAV，严格键/类型/来源/原始request SHA/材料与精度/seedControl=unsupported/阶段名顺序/有限非负耗时/残差≤.10/实际饱和计数/音频digest。准确44100mono float32、非零、全部有限、字节/frame/sample count一致。native=(Q(durationTicks)+16)*512；Q(t)=ties-even-round(t*44100/(1000000*512)+1/2)，用整数商余数精确实现；head4096；delivered=half-up-round(durationTicks*44100/1000000)。反例5120000ticks→Q442/native234496/delivered225792。不stretch、normalize、pitch-correct。使用AudioWAV expectedChannels1/requireNonzero真，旧默认stereo不变；读回后命名路径仍绑定实际被验证对象。结果中的音频路径仅output.wav，不当路径导航指令。源phraseRevision必须精确Int64，不能Double丢精度。JSON元数据声称成功不是WAV实测。

只有排空、所有保护和产物验证完成才emit artifact与返回InferenceResult。metadata提供profile/precision/sourcePhraseID/sourcePhraseRevision/requestSHA256/recordPath/seedControl，不附账号/条款确认或私密日志到音频产物。最后阶段取消可使host cancelled但已由child提交的文件必须保留；不承诺host/child最终状态永远相同。未经UI装配，不落入ProjectStore旧image默认路径。

### BRIDGE1验收

Lead先编译共享准备和组件测试再派工；Worker在冻结范围实现并交付代码+CPU测试设计，不自行弱化标准。测试要有正常/错误正反例，不能只断言mock预置值或通过跳过固定profile来冒称真实材料校验。

1. 严格wire roundtrip保持9字段、ID拼写/Unicode/Int64.max/null；bool/1.0/1e0/重复键/未知字段/深度大小/过期phrase/混合休止/乱序拒绝；资格不默认。
2. config/descriptor、固定profile+manifest真实字节准入、material缺失/错摘要/符号链接/输出重叠/零负timeout/无效模型revision；estimate无子进程/无写入，预算随请求规模变化不绑定开发机。
3. 实际受控子进程协议正例、重复/错序progress、伪成功/缺失/损坏record/WAV、未知path、输出错digest/声道/时长/原request/模型版本/1.0字段拒绝；stdout/stderr/consumer失败和timeout均drain回收。
4. 原始输入变更+取消明确inputIntegrityChanged；普通取消保持cancelled。自己测试目录内修改，不触碰真实材料。cancel→child drain→release→下一任务；共享许可跨runtime拒绝重叠且释放后可执行。
5. Lead固定版本真实phrase通过InferenceRuntime及开发CLI，取消后恢复、相关旧音频回归，构建App/CLI组件。人听音准/歌词另记，不把CPU fixture/编译当完整App歌声可用。App前端仍下一批准阶段。

后续CLI独立所有权仅在backend API就绪后签发；不让实现者同时改共享状态或让两个互相等待的任务假装并行。Lead共享实现另由非实现者只读复核，最终组合及源入口重验，保留源个人scheme、候选与全部历史证据。


## 2026-09-16 CLI1：公共接口已编译，独立入口接线

BRIDGE1初交3d91ab6f7c44ed812890e6c3485f4b020ade00a7的生产公共类型已实际编译；测试因命名遮蔽失败，源码保护阻断由BRIDGE1修复1处理。当前API签名冻结，修复不改变它，故CLI1可从此明确候选并行写独立4文件。这个候选基线不等于已验收或源接纳，组合必须先合入BRIDGE1修补并通过整体验收。执行base/route和写根见R/cli/job.json；R为run-20260915T163855Z-render。CLI执行模型Terra/medium，原有BRIDGE预算不变，CLI自身初交＋两轮修复。

# CLI1/spec1 — frozen developer entry contract

Same D-SINGING-BACKEND-01 R2 stage. Thin explicit developer CLI, no App menu/dialog/storage registration. Source and execution SHA supplied in job; never infer a SHA from this draft. Four allowed paths only: Backends/MLX/Sources/DInferenceCLI/{CLIOptions.swift,DInferenceCLI.swift,CLIReport.swift}, scripts/verify-singing-cli.py. Shared backend/core/Python, signal facility, other tests, package/locks, docs and Git readonly. No recursive work, network/install/models/GPU/GUI/build; Lead handles compilation and real validation. Worker may memory-compile its Python test and Swift parse only with job tmp/module-cache. Initial + two targeted repairs; no resetting budget.

## Behavior

Add capability `singing`, backend ID `audio.singing.qixuan`. Require explicit absolute `--singing-request`, `--singing-python`, `--singing-script`, `--singing-vendor`, `--singing-profile`, `--singing-vocoder`, `--model`, nonempty `--revision`, existing absolute `--artifacts`, explicit positive nonoverflowing `--memory-budget-mib`. Revision/material eligibility belongs to backend admission (execution failure 1), not duplicated strings in CLI. `--repeat` omitted/1 only. `--timeout-seconds` finite positive, default600. Accept report and inspect; inspect means readonly estimate, no child/no new artifact root/run/cache. Singing artifact root must exist; never create it to satisfy an invalid path.

Parse capability before requiring a text prompt. Singing rejects explicitly supplied prompt (including empty), prompt-file, seed, steps, guidance, old text/image/audio/video controls. Other capabilities reject every singing flag, preserving their old options/output behavior. Help remains help. No silent inherited values reported as used.

Read request regular local file with every path component no symlink, <=2MiB, bounded FD read, before/after identity, named-path recheck, valid source encoding handled by strict JSON decode; don't merely Data(contentsOf:) unbounded or JSONDecoder. Pass exact data to SingingRequestWire.decode(model:..., vocoder: ModelReference with fixed vocoderRevision, explicit memoryBudgetBytes). Store typed InferenceRequest, return it unchanged for execution/inspect; keep original runID, phrase/phones/qualification. No auto qualification/pinyin/prompt/seed, no run UUID replacement. The backend freezes exact serialized bytes for its own request digest; don't promise whitespace-equivalent source file SHA is that digest.

Instantiation maps explicit paths to SingingBackendConfiguration. Reuse InferenceRuntime, execution events and shutdown. Do not add another runner. Ordinary invalid args/wire/common semantic errors -> CLIArgumentError ->2; fixed materials/admission/execution/timeout/protection ->1; distinction: nonempty but wrong outer --revision is admission1, while a qualification.vocoderRevision conflicting with the supplied fixed vocoder reference is already rejected by shared validate and therefore2; normal cancellation130. After shutdown, record signal but retain1 when an actual InferenceFailure.inputIntegrityChanged exists in run failure; ordinary signals remain130. Match the typed failure, not its description text. stdout/stderr handling and published-file retention follow existing CLIOutput; no os._exit or bypass.

## Destination protection on success AND error paths

Main computes reportDestination BEFORE parse and may write after parse fails. For singing-related invocation, fail closed on ambiguous/repeated capability, model, report, artifact or singing path flags; don't take the first occurrence and overwrite a later input. Derive protections even if capability missing/invalid or other parse error: whenever any singing option is present, no unsafe failure report.

Singing artifacts disjoint from bank/vocoder/vendor roots; provider/helper directory; interpreter directory; profile and request files. Report outside artifact root and all protected roots, not equal to any explicit input; resolve existing symlink aliases for collision detection, separately reject input symlinks. Both --key=value and separated syntax work. An unsafe report destination means no report write, preserving actual CLI error. Test preexisting sentinel/source bytes before/after. No global change to unrelated modes' destination policy. Do not scan arbitrary parent directories, read keys, mutate model inputs, or use private test bypass in public code.

## Report and tests

Keep schema1 and old capability report shape. Encode singing options with only applicable local deployment fields, capability, explicit budget, timeout, report/inspect and repeat1; exclude inherited prompt, seed42, steps4, image/audio/video defaults. CLIRunReport retains typed request, outcome/failure/artifact/progress. Local CLI reports are development evidence, not media metadata exports; no claim all local paths are stripped from these reports.

New verify-singing-cli.py explicitly takes absolute CLI binary, request, deployment inputs and fresh output directory; no search/download/build. A documented CPU/offline mode runs complete CLI processes using controlled copied requests and existing fixed materials (hash reads, no inference), not wrappers replacing exit codes. Every subprocess timeout bounded, drain/reap own children, record actual command/exit/stdout/stderr and before/after source protections to output dir; no overwrite. Real model checks remain explicit Lead-run and not silently invoked by default.

Frozen cases: no-prompt valid inspect0/no runs/no artifact contents; runID retention checked in actual generation report (inspect deliberately has no runs or typed request; do not claim runID proven by its estimate); explicit empty prompt, seed, wrong-mode singing flag, repeat2, timeout NaN/zero, budget overflow rejected2; schema1.0/1e0/bool and duplicate-key inputs rejected2; missing request/incomplete argv2; readable profile/material mismatch1; parser-error report=input, report under bank/vendor/runtime/artifact, duplicate capability/path aliases preserve originals; safe error report remains allowed; singing report no pseudo defaults. Lead independently verifies real runtime generation, signal cancellation+recovery, output failure retention and old CLI no regression. Do not manufacture fixture claims about real model/rights/Gatekeeper/GUI. If a test cannot exercise an internal typed failure through public CLI without actual unsafe mutation, leave that case to existing backend/runtime CPU fixtures and cite the gap; never expose public fault injection.

Before any repair Lead reviews prior run exceptions/scope. Worker pauses on unknown permission/identity/side effects, reports ambiguity rather than guessing. Results identify actual code hashes, methods/outputs, unexecuted checks, owned process status. Lead accepts only verified versions and explicitly stages scoped files after write handoff.

Lead readonly pre-dispatch review: inspection exposes only estimate, so runID evidence belongs to real execution. Outer revision admission vs shared qualification/reference validation errors explicitly separated. No production changes or acceptance reductions.
