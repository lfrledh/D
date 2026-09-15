# D-SINGING-BACKEND-01：旋律与歌词的歌声薄后端

状态：获准推进；本轮先交付可离线验收的输入准备切片，真实歌声仍受声库许可/下载与工具链门槛约束。源基线 `347cdfeafe042b1df8db3657adaa04e11ffba6e5`，源分支 `codex/inference-foundation`。规格 SING1 / PREP1 / spec1；执行基线记录在派工 JSON，不自引用。

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
