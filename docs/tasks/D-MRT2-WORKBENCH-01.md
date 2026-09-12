# D-MRT2-WORKBENCH-01：短旋律条件器乐工作台

日期：2026-09-13。计划修订 planning-r1；状态：规划与协作规则已形成，产品实现/部署/GUI尚未开始。用户要求规划继续下一阶段，并取消项目层面的子代理人数上限；不是音乐所有远期能力、无限执行或新依赖下载授权。本文确定阶段范围与验收，不把拟议接口签名当作已存在代码。

## 1. 基线与可复用成果

- 核验源：`/Volumes/CodexProjects/Codex/D`，`codex/inference-foundation`，`fc6dbe3bc2b325e2d1441e49e8765ab679f02298`。上阶段源受测 `08cea85634f10d9af9f154586797ea5ded8d1029`；08→fc6仅六份结案/路线文档。既有审核/推送回执已复用，没有重跑历史验收。
- 本批 Lead 工作树：`/Volumes/CodexProjects/Codex/D-Worktrees/D-MRT2-WORKBENCH-01`，分支 `codex/d-mrt2-workbench-01`，从完整fc6创建，独立索引、相同common Git；不是内盘空仓库。实施从后续实际准备SHA签发，不硬编码本段为未来基线。
- 个人scheme为源唯一未暂存修改，orderHint 1→6，开始摘要 `ca3635d88aa5a15397b90e528667c66c0e6db7e596176e885c79d194b544206c`；内容/索引条目/完整差异和保护副本进入本轮证据，不携入本工作树、不暂存。
- [APP1](D-AUDIO-APP-01.md)已有SA3普通沙盒工作台提示/变体/重绘、试听候选、采用拒绝、安全保存重开与导出证据；[MRT2实验](D-MRT2-CONDITIONS-01.md)已有26 CPU、真实短旋律/和弦/条件修改/seed/取消恢复及数值检查。两者组合仍是新工作，不把实验出声写成App接线通过。
- MRT2固定模型revision `010aa0dcb0dfd27b24f0ad07b4dad63e8f9521cc`、源码 `694a545e4ba0b88bf1150137b129582166d3e07f`；现有独立MLX0.31.1环境/已批准权重可复用。导出图内部精度unknown，上游gain/clamp/int16转换已披露；float32 WAV不等于全FP32计算。SA3/图像/文字精度不改。

## 2. 一个有限的用户闭环

在“项目 → 音频”中选择已就绪的器乐引擎，输入短旋律/和弦条件、风格提示与seed，生成候选并试听；修改几个音符后再生成，对比两个候选，明确采用或拒绝，保存重开后恢复条件与来源，安全导出WAV。原件和已有采用结果始终保留。输出为48kHz双声道混音波形，不是MIDI、独立声部或可精确逐音符重写的音轨。

初始交互：内置可理解的短旋律示例与简明音符行（音名/开始/持续时间），支持相同起点形成和弦；可在高级入口导入/导出严格版本化的条件文件。时间输入明确采用40ms格，不暗中四舍五入；失败保留输入并解释修正方式。参数区仅显示所选后端真正支持的选项。复用现有模态栏、资产过滤和原生Liquid Glass风格，不改导航层级，不建完整钢琴卷帘或乐谱排版器。

本阶段不做MIDI/MusicXML通用解析、DAW、分轨、实时神经监听、歌词演唱、HUM识别、手机、更多模型安装或向便携测试包加入MRT2。短片段支持不宣称任意速度下八小节。正式条件闭环后，下一产品目标为专门的旋律+歌词演唱候选；HUM短单声部文件转录可在独立接口就绪时另行推进，不等全部文本/META功能。H09等设备，H17听感待配合，均保留原清单。

## 3. 接线前必须解决的实际差异

|已核实代码事实|本阶段决定与准备出口|
|---|---|
|`Sources/DInference/AudioRequest.swift`和`AudioCreationDraft.makeRequest`要求steps/guidance/strength；当前是SA3参数语义。|请求用值型参数族明确区分扩散配置与MRT2固定配置，结构化音符条件单列。不得将音符降为prompt、把帧数冒充steps或默默忽略SA3参数。Lead冻结兼容初始化/序列化/错误行为后派工。|
|`AudioProviderProcess.validateMetadata/validateArtifact`、`AudioModelInventory`、Python `d_audio_contract`均核对SA3固定模型/精度/44.1kHz；不是任意音频provider。|复用进程所有权/超时/drain/产物发布思想；MRT2使用独立provider身份、固定清单及有版本协议。不放宽旧SA3检查来接纳任意模型/格式。两种后端继续同一个重任务调度入口。|
|`ProjectStore.complete/expectedAudioFrames`及恢复检查有44.1kHz限定；实际MRT2输出48kHz。|按冻结执行profile核对输出采样率、声道、帧数和来源。MRT2保持原48kHz，SA3保持原44.1kHz；不偷偷重采样。逐项核查保存、重开、采用与导出，不只改一处常量。|
|`AppSessionFactory.makeSession`普通入口单个`.smMusic`；打包器的依赖白名单仅覆盖原引擎。|先证明固定MLX0.31.1/MRT2/LiteRT依赖在独立应用内引擎中可部署，再接路由。SA3环境不升级/降级；不加载开发venv冒充可移动部署，不全盘放行依赖。|

部署门槛包括固定来源清单、离线依赖闭包、中文/空格移位、移除对宿主开发路径的依赖，以及沿用现有签名/沙盒的隔离产物验证。历史TeamID加载失败保留；若现有依赖/授权不能支持，记录具体缺口，不关闭库验证、改权限或引入未授权下载。Lead先做这项高风险准备，避免UI全部完成后才发现部署无路。

## 4. 派工前冻结的行为

以下语义已确定；具体Swift签名、wire schema和项目兼容实现由Lead在一次有限准备中落实并用CPU反例验证，然后给各Worker共同完整SHA/contract_revision。没有准备SHA不发实现授权。

|输入/事件|必须结果|关键反例|
|---|---|---|
|提交音符条件|冻结项目/文档/草稿revision、模型/引擎/profile、实际prompt、条件内容及摘要、seed、时长/时间基；后端消费结构化数据。|生成期间更改第二音或提示词，旧任务仍使用原快照，不从当前UI重读来源。|
|缺省条件、空音符、非法条件|缺省=不施加音符条件；空数组=显式全零，均不承诺静音；UI“按旋律生成”要求非空。高级文件保留二者区别；非法输入可见拒绝。|布尔值冒充数字、同音高重叠、未知字段/版本、超界时间、非40ms格均不得静默修正/降为prompt。|
|音符与波形时间|固定条件profile为25Hz整数半开帧，波形为48kHz，每条件帧1920 PCM帧；两个时间域分别命名。|不能把条件frame=25当音频sampleRate，也不按SA3的44,100计算输出长度。|
|模型规模/时长|初始获验profile来自现有small实验，验证4/8/16秒和边界。400条件帧是本切片支持/解析界限，放在明确profile中，不作为所有Mac/音乐模型上限。更长/更大配置标为未适配，不假称内存不足。|硬件预算给估算/风险与实际失败；不得仅因本机16GiB把所有Mac限制为small，或把静态拒绝当容量实测。|
|seed/精度|MRT2 profile使用UInt32含边界，原SA3范围保持；保存实际值。随机state仅每任务初始化一次，结构不匹配拒绝；同任务续段不重置。|旧SDK固定42不能由全局随机种子掩盖；不同seed实测应能影响既定样例，不要求跨硬件逐字节确定性。|
|修改条件后重生成|生成新的完整片段候选；保留旧条件/候选和采用记录。UI明确“近似旋律控制”，修改后续声音可能变化。|锁定音符数据不等于锁定音频；不显示未实现的区外采样不变承诺，不借用SA3 inpaint验收冒称MRT2重绘。|
|完成/迟到结果|候选绑定原run/document/context；原件直到明确采用前不变；旧上下文不得采用到当前其他文档。|已切换文档、改revision或已取消时到达的结果不得自动覆盖/自动采用。|
|取消/失败|持续“正在取消/释放”直到计算和子进程结束，之后才放行下一重任务；保留错误上下文。|提前显示取消成功但进程未退、失败报告发布成作品、取消后误删原件均失败。|
|采用/拒绝/保存/重开/导出|复用既有显式决策与安全发布。保存条件草稿、实际执行快照、候选归属/采用状态；旧项目仍可读。导出拒绝覆盖。|未完整输入也可保留草稿；外盘断开/写盘失败不得破坏旧清单，已经生成但未保存产物显示可恢复状态。|

公开导出沿用现有隐私策略，不把本机绝对路径/书签/账号/开发Agent日志写入媒体。复杂新项目格式与全媒体META不属于本阶段；必要兼容字段和版本迁移由Lead单一协调，旧清单备份与恢复反例不可跳过。

## 5. 按依赖分波次执行，而非按人数凑任务

计划三个实现工作包，加一个按风险启用的只读审阅角色；实际同时活跃量由就绪度决定。本批暂预计准备期0—1、实现期最多3个写Worker、接纳期收敛为审核/测试；这是本批容量安排，不是新的永久人数上限。部署未过时只做不依赖部署的数据契约，不能假装三个任务已经就绪。

|波次/工作包|拟分配|范围/所有权候选与依赖|
|---|---|---|
|P0 公共契约和部署门槛|Astra Lead；必要非实现者Sol/high检查|`Sources/DInference/AudioRequest.swift`相关值型契约、固定profile/清单、`D/AppSessionFactory.swift`路由设计与`Backends/Audio/Packaging`部署策略归Lead。先做有限可运行准备，不重写整个音频框架。确需重要Lead实现由非实现者检查。|
|W1 MRT2正式provider/桥接|Sol/high|准备后精确签发`Backends/Audio/Python`内新增MRT2实现及`Backends/MLX/Sources/DMLXBackend`对应新适配/局部测试；不能编辑旧SA3精度/协议、共享打包器或App装配。复用固定probe语义，正式代码与`Experiments`仍分开，生产不导入实验目录。|
|W2 条件草稿/保存辅助|Sol/high|准备后签发`Packages/UI/Sources/DWorkbench/Audio`新增条件草稿/校验/快照及对应CPU测试；不改`ProjectSession`、`ProjectStore`、全局模型库。存储策略由Lead冻结并接入共享文件，避免与W3交叉写。|
|W3 条件输入与候选呈现|Terra/medium|依赖冻结视图状态/操作接口，只改`Packages/UI/Sources/UI/Views/AudioCreationView.swift`及获准局部条件视图/呈现测试；不直接写项目、不拼模型请求、不决定精度/条件语义。简明行输入与真实能力提示，不承担完整音频工作台重写。|
|I 装配/非实现者审阅/组合验收|Astra Lead；Sol/high按风险只读审核|Lead单一改`ProjectSession`、`ProjectStore`、`WorkbenchSession`、应用路由/工程注册及跨层生命周期。逐个固定候选合入专属集成分支，验证最终组合；不以各包自测相加代替。|

表中是经核查的拆分范围，不是对整个目录的写授权；每包签发前枚举确切文件与测试入口。W1/W2可在共同契约稳定后并行；W3只在状态接口足够稳定、无需等待其他Worker决策时加入。若共享装配仍耦合则推迟W3，不靠增加代理吞吐掩盖设计问题。当前未使用Luna：没有值得单独派发且纯机械的产品任务。

模型选择依据：W1跨语言/进程/数值，W2序列化/数据兼容风险较高；W3被契约限制为局部交互，Terra可保留实现选择。全部显式路由核验；每任务初交+两轮修复，符合既有规则时一次有界Lead接管；旧probe两轮已耗尽的历史不刷新，本阶段是正式产品适配而非再让旧probe隐性返修。新发现旧缺陷单独归因并服从剩余预算。

## 6. 验收门槛

1. **契约/组件**：内存内编译检查/局部CPU与核心/工作台受影响测试；冻结空值、数值类型、seed、25Hz/48kHz、超界/坏版本、旧SA3快照和旧项目夹具。测试策略由Lead制定，Worker不能改标准/删断言/放宽黄金结果。缓存/临时输出独立；不把AST当完整编译。
2. **provider/部署**：真实CLI入口、参数实际消费、坏清单/SDK state/协议/波形失败、报告写失败、超时/取消/子进程回收、中文空格移位；独立校验输出，不让工具仅验证自身。部署检查分别报告无签名编译、普通沙盒包和真正启动，不要求额外权限来伪造通过。
3. **组合/回归**：对组合SHA编译并执行相关测试；SA3 44.1kHz、MRT2 48kHz的生成结果、采用、持久化重开、导出与错误恢复分别验证；文档切换/revision变化/晚到结果、磁盘/外盘/拒绝覆盖为必测。若改到共同运行时，扩大到受影响图文生命周期，没改的不机械重跑全模型矩阵。
4. **真实模型**：Lead串行固定旋律/和弦、空/缺省、修改第二音、seed42/43、短片段与profile边界、取消再运行、重复加载/释放。记录输入/权重/实现/计算路径与精度、输出、耗时、首次PCM/取消延迟、RSS与MLX分项。48kHz/帧数/有限值/实际seed由机器判断；不以放宽阈值解释未知残留，不把合法WAV称专业音质。
5. **真实产品/人类**：隔离普通沙盒App中输入→两候选→比较→采用/拒绝→保存退出重开→导出；生成期间改条件/切文档、取消/错误与保存失败均不损原文稿/原件。用户试听旋律可辨、候选差异可理解且无明显爆音/断续；H17加入同一次集中配合，不重复条款。若只是CPU/mock/编译通过则入口不默认启用，状态如实保留。

现有权重/已授权依赖复用，不下载新模型，不改Team/bundle ID/entitlements/TCC/钥匙串，不关闭普通D。真实模型/GUI前核对当时资源与隔离，不沿用旧“空闲”答复作为无限窗口；需要人时按用户要求短提示音并集中询问，未能完成事项进现有清单。资源门槛不阻塞独立CPU工作。完成具体组合验收后本地接纳，源入口复验，再按既有阶段授权提交/推送工作分支；不推进main/master。

## 7. 本次规划证据与恢复点

外部持久目录：`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-MRT2-WORKBENCH-01/run-20260912T161353Z-planning`。包括source-before/identity、scheme副本、两份request/route-observation/process/response，以及最终planning-receipt。模型身份依可观察turn_context，不用自述或隐藏服务解析作证明。

- 后端只读核查：Sol/high，thread `01a09666-3ed7-7261-b9e1-1e49a085a043`。
- 工作台只读核查：Terra/medium，thread `01a09666-3ee1-7ea1-8aa3-392eb1b49be3`。
- 两者实际cwd/HEAD/read-only沙箱及请求/可见模型一致；都未获实现/测试授权。这是规划核查，不是产品实现并发或额外模型验收。模型服务端最终解析unknown。
- Lead核对44.1kHz限定和专用参数，采纳事实定位；未采纳Terra的“可把条件并入prompt”建议（不满足用户已明确的结构化控制），也未采纳所有工作必须串行的建议。后续任务直接写“禁止降为prompt”和冻结状态接口，减少执行者需要猜的决策；规划建议偏差不混记为已实现代码失败。
- 本轮无产品代码/测试/模型/GUI变化；没有重算历史费用。规划耗时/进程结束证据逐份记录；完整Lead归因和订阅费用unknown，不以本次两个审查任务推断成本最优。
- 下一动作：恢复时核对源/个人修改/进程与本计划；先落实P0公共契约及独立部署门槛，再签发明确IMPLEMENT任务。H09/H17及高配边界仍保留；不把计划提交当作正式MRT2工作台已经交付。最终文档SHA写外部回执，不在本文自引用提交。

## 2026-09-13 实施启动：implementation-r1 / contract-r1

用户已批准继续直到本阶段完成，并确认本阶段真实验收前普通D已保存退出、其他AI/GPU空闲、隔离版可间歇使用前台及播放短样本。源和集成树均从`974477ef34a6708b9b4b90f7c79c19ae23ff716c`恢复；源个人修改与索引核对一致。新证据目录为`D-Development/AgentTrials/D-MRT2-WORKBENCH-01/run-20260912T163022Z-implementation`，旧规划证据不覆盖。

P0已由Lead实现值型参数分族：`AudioRequest.parameters`为`AudioSynthesisParameters.diffusion(AudioDiffusionParameters)`或`.mrt2FixedV1(AudioNoteSequence)`；旧初始化器及flat JSON保持，原字段读取改用明确的`diffusion`，MRT2不提供伪steps/guidance/strength。新增`init(prompt:seed:noteSequence:)`，`noteSequence`可查询，`outputSampleRate`按族为44100/48000。`AudioNoteSequence`含schemaVersion1、frameRate25、durationFrames1...400、可缺省notes；元素pitch/startFrame/endFrame，canonicalNotes按pitch/start/end排序，与原probe一致。新请求JSON额外`parameters:{kind:"mrt2FixedV1",sequence:{...}}`，禁止混入旧扩散字段；旧编码不增加该key。原SA3准入显式要求diffusion。上述源码是共同契约事实，不复制成另一套Worker类型。

核心首轮37通过；工作台首次编译发现3处旧测试直接读strength，已仅迁到diffusion.strength保留期望。随后增加“旧请求不得丢弃notes”反例/严格字段检查，最终准备SHA及重新检查结果写外部准备回执，不冒称先前37绑定新增代码。

部署只读Sol/high thread `01a09675-0e52-7b83-85aa-169f7e5ee9f7`的可观察身份见本run/deployment/route-observation.json；其结论已复核：开发环境非editable、无pth/link，但导入闭包带入JAX/Flax/librosa等，本阶段采用固定源码导出路径的轻量适配，独立引擎，不放宽原SA3包校验。只读查询误用了系统Git包装器，一个命令块触发7条`/tmp/xcrun_db-*`拒绝后仍继续读取，未遵循立即停报规则；未观察到提权/成功越界，实际readonly沙箱保留，Lead也遗漏了在此临时任务重复写明已知显式Git入口。该事实记录在permission-event-audit，不追改合规。后续任务显式使用`/Applications/Xcode.app/Contents/Developer/usr/bin/git`；不得再用包装器或探测越界写。

### P0-E：导出运行路径适配（就绪后独立Sol/high）

这是部署前置的有限实现，和W2条件数据可独立进行；不假称尚未过部署的W1正式桥接已就绪。允许路径仅`Backends/Audio/Python/d_mrt2_export.py`、`Backends/Audio/Tests/test_mrt2_export.py`、`Backends/Audio/MRT2_EXPORT_PROVENANCE.md`。固定来源为先前已批准的本机SDK源码`.../D-MRT2-CONDITIONS-01/run-20260912T150154Z/source/magenta-realtime/magenta_rt/{mlx/system.py,musiccoca.py,config.py,mlx/model.py}`；保留Apache来源/改动说明，Lead另提供LICENSE。不得修改SDK/依赖环境、Experiments、其他provider或任何Swift文件。

冻结API：`ExportedMRT2(model_root: pathlib.Path, prompt: str, seed: int)`每实例一个任务，导出`generate_frame(note_frame: tuple[int,...] | None) -> numpy.ndarray`（1920×2、float32）、`identity() -> dict`、`close() -> dict`。导入模块不初始化MLX/模型；无全局模型/随机state缓存。构造只支持固定small官方导出、warmup5、temperature1.3/top_k40、cfg musiccoca3/notes1/drums1。仅依赖已有NumPy/MLX/LiteRT/SentencePiece与标准库；不得带入magenta_rt/JAX/Flax/sequence_layers/librosa。按原SDK text encoder/mapper(seed0)/RVQ与graph参数次序精确移植；先前proto可能截断超127个小写SentencePiece token，本适配必须明确拒绝，不能记录完整提示而只算前段。mapper seed0与请求采样seed分别记录。

固定export state共有165个leaf，采样key为index2、uint32(1,2)默认[0,42]；先核对结构，再仅对每任务初始state置请求seed，续帧不重置。warmup使用独立默认state不污染实际初态。原图已经gain/clamp/int16；仅按SDK转float32/32768，不额外增益/裁剪/重采样。输出形状、dtype、有限性检查；close同步、释放引用和cache，失败保留错误不宣称released；不能用os._exit或吞异常。identity包含固定源/图路径配置、模型revision、MLX版本/实际转换和未知内部精度。路径不得隐式下载或fallback到另一个model root。

验收：CPU可用受控fake模块检查参数顺序/shape/负条件、缺省与全零差别、seed/state guard、跨帧state、长prompt拒绝和close失败，不导入真实MLX。实际MLX/同seed参考输出对照/不同seed/取消由Lead独占执行，CPU不能替代。运行Python使用-B与task tmp；语法仅tokenize.open+compile内存检查。初交+2针对性修复，900秒每轮；未预期权限/模型/目录差异立即停报，不能因只读查询退出0忽略拒绝提示。

### W2：条件草稿与严格条件文件（就绪后独立Sol/high）

允许仅`Packages/UI/Sources/DWorkbench/Audio/MusicCreationDraft.swift`、`Packages/UI/Sources/DWorkbench/Audio/MusicConditionFile.swift`、`Packages/UI/Tests/DWorkbenchTests/MusicCreationDraftTests.swift`。禁止改AudioCreationDraft、ProjectStore/ProjectSession、导航/应用/后端/任务规格。共享接线Lead负责。

冻结API：`MusicNoteDraft: Codable,Sendable,Equatable,Identifiable`有可变`id:UUID,pitchText:String,startText:String,durationText:String`及默认id初始化器。`MusicCreationDraft: Codable,Sendable,Equatable`有`notes:[MusicNoteDraft]`、`hasNoteCondition:Bool`（false→absent，true空rows→explicit empty），`init(notes:hasNoteCondition:)`、`static var example:Self`、`func makeSequence(durationText:String) throws -> AudioNoteSequence`。文字字段与UUID序列原样保存，编辑草稿可暂时无效；提交才校验。pitch输入只接0...127整数或音名如C4/C#4/Db4，固定C4=60，不猜八度；时间为秒的十进制字符串，仅允许非负/正且精确40ms倍数，以十进制整数运算检查，不Double近似或四舍五入。有限字符串长度、最多512行，不溢出、不接受NaN/Infinity/符号花样；按既定条件边界核验同音高重叠。

`MusicConditionFile.decode(_ data:Data) throws -> (draft:MusicCreationDraft,durationText:String)`；`encode(_ draft:MusicCreationDraft,durationText:String) throws -> Data`。外部文件仅schemaVersion/frameRate/durationFrames/可选notes（元素pitch/startFrame/endFrame），无prompt/seed/路径/URI，不执行/联网；≤128KiB、深度≤8，拒绝重复key/未知字段/布尔冒数值/小数冒整数/坏UTF8/null notes/坏版本/越界。可以实现局部小型严格解析，不能建立通用新JSON框架。解码后UUID新建，保存重开UUID保持；语义encode→decode完整，nil与[]区别保留；禁止把音符并到普通prompt。

验收至少覆盖中文/组合字符原样草稿、合法C4/升降音/和弦/相邻音、0.04与0.03/0.0400000001、负/巨大数溢出、跨界/重叠/513行、坏输入仍可Codable保存、缺省/空条件、8层以上/重复key/布尔/1.0版本/未知字段/过大/坏UTF8、安全roundtrip。Worker可写Tests但不改标准。已知SwiftPM嵌套沙箱由Lead执行，不让Worker先撞权限；Worker只可用显式swiftc及任务module-cache做局部typecheck（有就绪DInference模块时），或只交代码及未执行测试。初交+2修复，900秒/轮；外部模型/GUI/network禁止。

每个写Worker先从本任务準备提交建不同外盘工作树/分支，precheck只读动作→Lead核验turn_context模型/effort/workspace-write实际写根及源保护→同线程IMPLEMENT；输出/tmp和缓存仅本run的该Worker目录，common Git不可写，Worker不commit。精确路径/基线/runtime证据写外部request，不猜工具参数。当前两实现均未派出，下一动作是完成P0准备检查与签发。


### 实施检查点：P0准备与W2接纳前

P0受测提交`1bf4017e6f63049deed139dcd9e797b8e253c664`：38核心、291工作台CPU通过，证据implementation/prepared-checks.json。Sol/high非实现者审查thread `01a09682-4fc6-7180-9ccd-549c16eb2448`无阻断发现，建议独立513合法事件反例与source/region/wire断言；Lead已补测试，待组合重跑。该审查request的base字段误沿用父974，实际prompt/查询对象为1bf，route-observation已明确纠正元数据，不改旧记录。

W2线程`01a09681-693a-7e30-b07a-1153dc6d15bb`、P0-E线程`01a09681-64b0-7d92-93c4-2a374b49e0a8`均独立Sol/high受限workspace-write，网络关闭；实际policy将cwd列为隐含写根，extras仅各自output/tmp，源和common Git未授写。W2初交只三新文件，已完成生产/测试typecheck，未自称执行SwiftPM；初次Testing/framework宏路径错误经只读定位后在自有缓存通过，无权限拒绝。P0-E预检因Lead PATH缺少rg正确停报，一次显式rg重预检通过；初次实现因工具显示输出截断暂停，Lead确认是显示上限而非进程警告，批准窄范围分段只读恢复，延续剩余初交时间，不重置实现预算。

Lead独立运行环境打包已只选现有固定mlx/metal0.31.1、numpy2.3.5、sentencepiece0.2.2、ai-edge-litert2.2.0，剔除未使用训练SDK及安装来源路径记录；中文空格emoji目录中-I隔离导入通过，sys.path仅新运行目录。尚不代表模型/签名部署通过。新增8打包CPU检查通过，最终日志待固定组合SHA重跑。新打包器不改原SA3打包器行为。

Lead共享接线候选正在实现：AudioCreationProfile区分两类，music草稿独立；WorkbenchSession额外可选music后端注册入口，原SA3不变；按冻结请求44.1/48kHz存储核验。项目schema6通过原安全迁移保存v5字节备份，以免旧App忽略新条件后覆盖；旧1...4迁移仍保留原备份。当前提交为候选准备，W2尚待并入后编译，音乐provider/应用部署/UI/真实验收仍未接纳。源974及个人scheme保持，具体候选SHA写外部记录。

### contract-r2：正式provider与视图就绪边界

P0-E候选`a076c8e38ba22fa127c1defdd2db3ca2395df3ae`在独立移位Python内已真实生成seed42/43，原final-melody同输入同seed逐样本一致、不同seed输出改变；证据deployment-runtime/export-real-results.json。这是当前机器同路径数值对照，不要求跨硬件逐样本一致。MRT2运行实际读取六项graph/state/text资源，共1,042,112,092 bytes；已批准13项下载中的raw/audio编码检查点是实验资源，不是此正式profile必需项。固定六项SHA清单见Backends/Audio/Models/mrt2-small.json，既有下载不删、不改。

全套存储检查发现一次关闭后重开锁未释放；单独检查通过。Lead新增真实posix_spawn短子进程反例，未修补版稳定失败，确认项目锁描述符继承机制。仅给项目锁打开和relocated复制加入close-on-exec，原反例及移位分支通过；证据lock-regression-before/after.log，不以随机重试掩盖。全套待重跑，重要Lead改动需非实现者审核。schema6沿用原持久备份机制，不允许旧App忽略新条件后覆盖。

#### W1-P：D-MRT2-PROVIDER-01（Sol/high）

仅允许新增Backends/Audio/Python/d_audio_mrt2_backend.py、Backends/Audio/Python/d_audio_mrt2_contract.py、Backends/Audio/Tests/test_mrt2_backend.py。不得改导出适配、旧SA3、Swift、模型清单、包装器、规格。依赖准备SHA的d_mrt2_export.ExportedMRT2；可引用d_audio_contract的严格JSON/安全文件/publish_exclusive/json_bytes及d_audio_access.acquire_file_access，不调用旧44.1kHz验证器、不导入SA3入口或完整SDK。Python只用已有依赖。

CLI必需--request、--job-directory、--model-directory、--manifest、--vendor-directory。可选--access-manifest/--access-run-id必须成对；--inspect校验身份/六项SHA后输出inspection，不导入MLX。本入口只mrt2-small-export-v1，无source、access-source-directory或任意profile选择。路径不得重叠，常规非symlink文件，请求≤1MiB、清单≤2MiB；job必须已有且为空。使用原发布防覆盖语义，不扫描其他目录或删除失败产物。

Frozen request是AudioRequest音乐JSON加schemaVersion1/runID（规范小写UUID），完整且仅含schemaVersion/runID/operation/prompt/durationSeconds/seed/parameters。parameters仅kind=mrt2FixedV1和sequence；sequence仅schemaVersion1/frameRate25/durationFrames1...400/可选notes，每项pitch/startFrame/endFrame。同DInference的整数、未知key、nil与[]、UInt32语义；prompt非空非空白无NUL、UTF8≤4096，durationSeconds等于durationFrames/25。拒绝重复key、非有限、布尔冒整数、整数版本写成1.0、深度>16、SA3字段。条件按pitch/start/end排序，128维每音符起始帧=2，后续至end之前=1，其余=0；缺省整帧None，显式空为全零，不输出3。

权重按repo内mrt2-small.json的固定schema/repo/revision/六项path-size-sha256逐项校验，可取消；不得相信自报revision。每任务一实例，构造前后及每条件帧检查取消；记录首PCM/总耗时、进程RSS和MLX active/cache/peak，分项不混淆。任何生成退出都close，close.released非true则失败。SIGINT/SIGTERM请求取消，正常清理后130；契约/配置/输出交付失败2，推理失败1，成功0。不os._exit，不在清理前交付result；stderr正常INFO不是失败。

采用AudioProviderProcess现有schemaVersion1 JSONL envelope与progress阶段名：validating/encodingText/denoising/decoding/publishing/cleanup。denoising此处进度单位是条件帧，不冒充扩散steps。result artifact固定job/output.wav、sha256、byteCount、frameCount=durationFrames*1920、sampleRate48000、channels2、encodingfloat32。标准IEEE float32 WAV，无额外gain/clip/重采样。独立核验有限/帧数/解码后原子发布；result.json与唯一terminal相同。metadata至少request完整快照、profile、modelRepository、modelRevision、weightManifest（固定files数组）、sdkRevision、condition（规范排序sequence和明确notesMode）、conditionSHA256、engineIdentity、timingsSeconds、mlxAllocations、cleanup。condition摘要为sort_keys紧凑UTF8 JSON；engineIdentity去除model_root/graph_path/state_path/resource_paths等绝对路径，其余事实来自已执行实例。close及书签作用域release成功后才交付terminal；release失败不能先报success。

CPU可显式注入fake engine/小清单，不给正常CLI增加fake环境变量或跳过SHA开关。main(argv, *, engine_factory=ExportedMRT2)可作CPU注入入口。测试覆盖类型/边界/重叠/空缺/2与1音符编码、seed冻结、进度取消、构造/生成/close失败、NaN/坏WAV、已有输出、终态唯一、断管和访问release顺序；真实CLI至少缺参/坏请求/不可写输出/坏模型。测试不载入真实MLX。初交+2修复900秒/轮；Lead再做真实验证。工具显示截断可分段只读恢复，不是权限事件豁免。

#### W3：D-MRT2-VIEW-01（Terra/medium）

仅允许Packages/UI/Sources/UI/Views/AudioCreationView.swift、同目录MusicConditionEditor.swift及Packages/UI/Tests/UITests/MusicCreationViewTests.swift。禁止改共享Actions、WorkbenchView/Model、ProjectSession/Store、DInference。依赖AudioCreationDraft.profile（stableAudio/conditionedMusic）和可选music、稳定UUID音符草稿。AudioCreationView新增supportingMusic(_ enabled: Bool)->Self，默认false，由Lead注入实际可用性。Actions的可选importCondition/exportCondition无closure时不显示入口。

在音频创作内部选择“声音生成/编辑（Stable Audio）”或“旋律器乐（MRT2）”，不加顶层模态。音乐不可用时显示说明但不接纳新生成；已有音乐草稿可查看保存/导出。来源文档不允许转音乐profile，提示新建无来源创作。显式切入音乐时operation.generate、editRegion=nil，music缺省才填example，保留prompt/seed及隐藏的旧参数。音乐仅显示提示、seed、时长、音符行和条件开关，隐藏steps/guidance/strength/variation/inpaint。

提示“近似旋律控制，每次生成新的完整片段；48kHz混音，不是分轨；时间按0.04秒对齐”。音符行音名或MIDI整数/开始秒/持续秒，可同起点和弦；增删/示例/高级文件入口，最多512行，非法文本保持。普通按旋律生成空行由ButtonHandler拒绝；高级文件nil/[]保存保留，不承诺空条件静音。isBusy时编辑/导入/profile/model禁用，取消可用。视图不执行文件或模型操作。

保留候选试听/采用/拒绝/撤销采用/导出与原按钮ID。48kHz候选不显示会进入SA3参考路径的“基于此新建”；44.1kHz原行为保留。窄参数面板/最小窗口要响应布局，不截断；稳定accessibilityIdentifiers供Lead验收。状态只走Binding/actions，不手改revision或decisions。Worker仅局部CPU逻辑反例/显式typecheck，无SwiftPM/GUI。Lead组合编译与真实窗口验收。初交+2修复900秒/轮；权限、冻结契约和来源规则不变。

#### W1-S：D-MRT2-BRIDGE-01（Sol/high，contract-r3）

允许仅新增 Backends/MLX/Sources/DMLXBackend/{MRT2BackendConfiguration.swift,MLXMRT2Backend.swift,MRT2ModelInventory.swift,MRT2ProviderValidation.swift} 和 Backends/MLX/Tests/DMLXBackendTests/MRT2BackendTests.swift。禁止改已有 SA3／共享进程、App／Workbench、包与工程、清单、Python 和任务规格。Lead 提供 AudioWAV.validateOutput(...expectedFrames:,expectedSampleRate: Int = 44_100)，MRT2明确传48_000，SA3默认不变；非正 expectedFrames 应报错不能 UInt64 陷阱。

公开 MRT2BackendConfiguration:Sendable 的 initializer 参数为 pythonExecutable/providerScript/vendorDirectory/modelManifest/artifactDirectory（URL），licenseAcknowledged=false、timeoutSeconds=600、cancellationGraceSeconds=15、accessBootstrapRoot:URL?=nil、confirmDeployment:(@Sendable()throws->Void)?=nil、modelUseAcknowledged:(@Sendable()async->Bool)?=nil；公开固定 registeredModelRevision=010aa0dcb0dfd27b24f0ad07b4dad63e8f9521cc。MLXMRT2Backend actor 遵循 InferenceBackend，descriptor id=mlx.audio.mrt2/version1/audioGeneration，init(configuration:) throws；estimate 不加载权重或询问许可，execute 真正计算前检查明确使用许可。只接 AudioRequest.mrt2FixedV1，reject SA3/source/inpaint/wrong revision；nil与[]不合并。不把 MRT2 伪装为 SA3 profile 来复用其 validator。

模型清单严格六项，schema/profile/repo/revision/path/size/SHA与固定 Backends/Audio/Models/mrt2-small.json 一致（license仅记录原文）；使用 AudioJSONParser 拒绝重复/布尔/错误版本。正常 admission 检查六项大小/regular identity，实际 SHA 由正式 Python 校验；execute 前后 confirmUnchanged 防止混用。可单独实现解析 API 注入明确小夹具测试，但正常配置不得有跳过固定清单开关。请求/layout验证复用 AudioFileSystem 的基础安全函数，不改共享函数。root必须现有absolute local、无symlink、artifact与model/vendor/provider/manifest互不重叠；timeout/grace有限正。保守估计为3 GiB加3倍PCM字节，标estimated，并非本机测量或额外内存硬上限。

复用 AudioProviderProcess（完整等待子进程和两读端结束）、AudioProviderAccess、MLXExecutionLease.shared。execute/release状态与旧MLXAudioBackend相同；全局许可持有至runtime release，取消/消费者异常仍drain，终态和清理失败不得success。独占run目录 UUID-UUID，0700 job/tmp/cache与exclusive request.json，不扫描删除原件或已发布产物。配置书签时仅 model/run 目录、成对access参数；初始cwd access目录。环境冻结TMPDIR/缓存/PYTHONDONTWRITEBYTECODE等到自有run，PATH=/usr/bin:/bin。配置确认在launch前和退出后，access.finish在失败和成功都调用，异常不吞。

请求 JSON 使用 AudioRequest 音乐编码加 schemaVersion1、runID小写UUID，其余不改；CLI参数严格沿W1-P，不传profile/source。result.json由 AudioProviderProtocol.parseResultSnapshot独立解析，等于 stdout terminal，再逐项核对request快照、profile/repo/revision、六项weightManifest、sdkRevision=694a545e4ba0b88bf1150137b129582166d3e07f。condition形状明确为{sequence:{schemaVersion:1,frameRate:25,durationFrames,可选notes规范pitch/start/end排序},notesMode:absent|explicitEmpty|notes}；缺省不含notes，空为[]。conditionSHA256为该对象sortedKeys无空白UTF8（全ASCII字段/整数，不涉及浮点规范化）。engineIdentity至少核验固定profile/model_revision/sdk_revision、prompt、sampling_seed=请求seed、mapper_seed=0、state_leaf_count165、sampling_key_state_index2、warmup_steps5、temperature1.3、top_k40、cfg_scales及输出转换/真实版本、closed/released；具体既有key和值以已接纳 d_mrt2_export.identity 为准，不能凭名称猜。禁止残留绝对模型路径key。cleanup必须released=true且无error，timings/allocations仅校验存在、有限非负或明确unknown，不拿它们推导准确内存承诺。允许真实工具附加诊断字段，不允许已核验关键事实缺省成通过。

WAV完整字节/有限float32/48k立体声/帧数durationFrames*1920/SHA核对后才emit.artifact。结果metadata记录profile/modelRevision/conditionSHA256/precision（内部graph精度unknown，输出float32）/recordPath。不能给出未观察的内部精度承诺。

CPU至少严格请求/清单/布局、nil与[]、版本/请求/seed/condition/cleanup元数据反例、48k WAV以及错误声道/帧数/非有限/负expectedFrames、完整进程成功/取消/超时/消费者失败与release后再次运行。可用受控fixture和已有进程测试辅助，不加载真实MLX；任何新fake hook只能内部测试注入，生产无开关。所有输出缓存在本任务写根。Worker不运行SwiftPM/嵌套沙箱或完整构建，不尝试当前宏typecheck已知权限失败；可交编译未验收代码由Lead执行批准的编译/CPU检查。静态diff与内存内Python compile可用。禁止GPU/GUI/network/Git写入，初交+2针对性修复各900秒；其他停止规则不变。Lead按具体SHA补真实模型/运行时/普通沙盒App验收。

#### implementation-r3 检查点

c1335110262a44cef1b7f5e681b105779cc38cad 已通过38核心、302工作台、10导出适配、8打包CPU检查，证据 prepared-r2-checks.json；不同类别不合并为产品通过率。Sol/high非实现者共享审查01a096a1-2482-7573-92bc-4c7b4de36bec未发现阻断，运行上下文只读已核验。W3 Terra初交仅三允许文件，显式typecheck遇嵌套编译器sandbox_apply拒绝并立即停报；Lead预置macOS14目标也与现有26模块不符。无权限扩大、无Worker重试，此为环境准备缺口，代码尚待Lead编译/GUI，不占普通修复次数。源974和个人scheme未变。
