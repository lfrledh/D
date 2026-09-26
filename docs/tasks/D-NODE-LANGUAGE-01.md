# D-NODE-LANGUAGE-01：通用节点语言与四模态试用

状态：实施中，规格 r1 / language-v1，2026-09-27 JST。用户明确批准 S0—S4 连续实施；不公开发布、不推进 main、不自动接纳 AP1/CORE/I2V。

## 基线与证据

- 源：`codex/inference-foundation`，`130603d23a4da81ba2a9852766f3589695ec9468`。
- Lead：外盘 `D-Worktrees/D-NODE-LANGUAGE-01`，`codex/d-node-language-01`。源工作文件不用于实现。
- R：`D-Development/AgentTrials/D-NODE-LANGUAGE-01/run-20260926T150929Z/`（相对 `/Volumes/CodexProjects/Codex/`）。用户交接 12 个文件全部摘要核对并保留在 R/attachments；其中 01/02/03 是范围、节点和 A01—A36 验收要求，不是通过记录。
- 源个人 scheme 仍未暂存，SHA256 `ca3635d88aa5a15397b90e528667c66c0e6db7e596176e885c79d194b544206c`；索引 `9c76916bdc97c2d4298cefe64e0b0fae3380573e`。保护副本和完整差异在 R/evidence/baseline.json。
- 本轮受测/最终版本尚未产生。旧集中验收以原任务回执为准，不算本轮通过。

## 范围与责任

N01—N18、G01—G03、V01、M01—M09 均交付有界可配置版本。四套可编辑样例 E01 数据控制、E02 图文候选、E03 哼唱与和声、E04 四模态素材。至少两个真实版本化工具、同计划无画布入口、检查点/局部运行、普通 App 与 Xcode Run。

共享契约、Store 版本、Controller/解释器、运行准入、App/工程装配由 Lead 统一协调。Worker只改冻结的局部文件；不各造模型库/Store/调度器。旧 M0 操作 ID、确认等待、seed/count、项目和资产保护保留；未选分支不准备模型。用户内容与当前参数/实际运行快照分开，媒体值按固定版本引用，不使用 Any 或 eval。

音乐 M04 是已有 SwiftF0+分段，不是 Basic Pitch；M09 必须传入真实25Hz音符条件；V01仅Wan T2V。既有精度不改。Pitch当前包含399114字节内部评估权重的耦合按附件§7保留、明确披露，不能据此分发或宣称无权重包。

## 执行与预算

按 C2026-09-23.1，写Worker独立外盘工作树/分支，受限 CLI workspace-write，网络关闭，仅自身树及本run output/tmp/cache写入；Git共享管理目录不授写。预检后核对客户端 turn_context，再 IMPLEMENT；共享文件由Lead单一所有。读源码用只读原生调查，不能当作写隔离证明。

每个新有限工作包初交+最多两轮针对修复，之后最多一次有界Lead接管；旧任务预算不刷新。每轮修改授权前先查异常/保护。默认15分钟，确需较长任务事先写明。重构建/GPU/GUI串行，CPU预算也受约束。无字节码Python编译使用tokenize.open+compile，不exec目标；所有测试缓存落指定目录。敏感/未知越界立即停相关任务。

## PACK r1：开发资源可重建入口

请求 `gpt-5.6-sol / high`，本机可观察设置核对后执行。目标：固定清单的本地资源准备与构建前复制；无安装、下载、重签、全App构建或GUI权限。

允许文件仅：`scripts/prepare-development-resources.py`、`scripts/embed-development-resources.py`、`scripts/tests/test_development_resources.py`。工程phase、签名设置和现有build脚本由Lead接线，Worker不得修改。

输入显式本地 JSON 配置，schemaVersion=1，engines 为四项精确键 `AudioEngine.dengine` / `MRT2MusicEngine.dengine` / `VideoEngine.dengine` / `PitchEngine.dengine`，值为本机已准备引擎目录绝对路径。准备命令 `--config PATH --output PATH`：只读输入引擎，校验引擎 manifest/路径不逃逸、不得与输入重叠；产生独立资源集和带逐文件摘要的开发资源清单。相同输入重复调用可验证后复用，未知或不同现有输出拒绝，不清目录。此工具只暂存已准备引擎，不自行执行准备器/下载/安装。

复制命令 `--prepared PATH --destination PATH`：只把四引擎复制到新构建包的 Resources/Engines，复制前完整验证清单，路径安全、限制文件数量/总量。相同内容重用；冲突拒绝不覆盖未知文件；不得改输入、签名、系统或用户数据。跨文件失败报告具体位置和未完成状态，不宣称原子四包。跟随引擎内部相对symlink仅当目标仍在本引擎中（保留链接），外部或绝对链接拒绝。允许Python.framework内部链接。路径含空格/Unicode正确；安全参数，不shell执行。

CPU临时夹具：四引擎、重复准备、缺一项、坏manifest、清单hash冲突、源/destination重叠、符号链接逃逸、重复embed不改文件、目标已有陌生引擎拒绝。真正引擎+构建签名前接线由Lead另验。正常退出0；输入/校验/写入失败2，并保留可诊断错误；stdout异常不能误报成功。输出报告与原文件保护独立。仅标准库，无第三方依赖。Worker提供差异/结果，由Lead提交，不编辑本规格。

## 验收与恢复

A01—A36逐项记录 CPU/hosting、模型、GUI、本人录音/试听，不把旧结果、CLI或编译冒充新的四模态画布闭环。GUI与模型资源默认Lead管理，无需再次问空闲。新的本人操作/锁屏阻塞入集中清单，继续独立工作。

S0已核实外盘/源/索引/无已知执行进程，既有源构建App以全新固定隔离UUID启动，实际看见空项目选择页，然后正常退出；只证明基线可启动，不证明新增节点。受限CLI旧可执行路径失效，当前实际入口为 ChatGPT.app 内 codex-cli/CodexCLI.app；需本次预检元数据确认。桌面工作树工具绑定内盘空仓库导致指定SHA无效，未改源；改用已授权真实外盘 Git 创建隔离树，未动源checkout。

下一动作：核定值/控制/存储接口，派限定实现，串行组合验收。当前没有正式产品验收通过；不得提前接入源或称阶段完成。

## DATA r1：标准确定性数据操作

共享契约 `WorkflowData.swift` 与 `WorkflowNode.dataConfiguration` 由Lead冻结。Worker只新增 `Workflow/Operations/WorkflowDataOperations.swift` 和 `Tests/DWorkbenchTests/WorkflowDataOperationsTests.swift`（根均 Packages/UI/Sources/DWorkbench 或 Packages/UI/Tests）；不得改共享类型、Registry、Builtins、UI、Store或任务记录。请求gpt-5.6-sol/high；独立预检后才实现，初交15分钟。只能内存CPU/指定tmp小夹具；不能构建整个Swift包（Lead串行执行）。允许swiftc前端语法解析不产生目标文件，测试命令留给Lead。

接口：`enum WorkflowDataOperations { static let operations: [WorkflowOperation] }`。新ID均version1：`d.value.input/template/record/field/list/filter/select/pair/validate/return`。N02/N03/N18及控制由其他责任方接线，不伪装实现。参数只用现有WorkflowScalar，复杂配置用已冻结WorkflowDataConfiguration。所有输出`.data`，媒体可通过Datum.asset携带。返回端口固定output；配对另返回leftUnmatched/rightUnmatched；report校验固定output Record{valid:Bool,data:Optional<schema>,issues:List<Text>}，失败不包含非法data；strict参数可throw。

- input：无输入，config.value优先，缺失拒绝；公开参数由未来调用绑定替换冻结值，不读UI。definition默认节点应能编辑。
- template：可选fields Record输入，config.value为后备Record；parameter template 默认空字符串；只`{{field}}`安全代入Text/Number/Bool/Enum，缺字段准确报错，不eval。不得把用户替换值中模板标记再次解释。
- record：config.fields声明输入端口名/类型/required；实际输入优先，config.value的Record.fields作后备；没有config时空Record合法。动态端口由Lead registry.definition(for:)投影，Worker定义可以inputs空，不建另一注册表。
- field：input Record，config.path与config.schema声明结果类型；缺字段拒绝，显式none保留，类型不符拒绝；不把不存在当nil。
- list：config.schema为元素type(不是list type)，config.items为固定成员，config.fields为可连接命名端口。parameters mode=items|concat（默认items）；items每输入作为单成员，稳定ID为端口名；concat只拼一层，各成员ID保留，冲突拒绝；不能隐式展开嵌套列表。
- filter：input List，config.rules依次全满足，config.path非空才稳定排序，parameters ascending=true、limit=4096；无排序保持输入顺序，允许limit0。缺字段/单位错拒绝（exists规则可判false），未用AI评分；输出保留itemID。
- select：input List；parameters method=id|index(default id), itemID="", index=1；index为1起始，id空不默认第一项；未知ID/越界拒绝。
- pair：left/right均Record列表，config.path匹配键，双方唯一且同类型Text/Number/Bool/Enum，重复键拒绝；1对1，按left顺序，不按完成顺序、不笛卡尔积；output列表item record{left,right}，itemID用leftID；leftUnmatched/rightUnmatched分别原类型列表（显式保留未匹配，不静默丢弃）。
- validate：input值，config.schema必需；strict=false默认；报告失败原始输入不作为合法data，但原context保留可用于修复。issues稳定定位，success data可直接是符合optional的非none值。
- return：input任意合法Datum，name="result"只是公开输出名元数据，当前output照常传值；不写外部文件。

各节点先验证输入Datum完整性与数量/单位。输出不得调用模型或发布资产；不为纯程序租模型。测试直接execute真实operation，fake services只在任何误调用时失败：Unicode模板、输入包含{{x}}不二次替换、缺字段、嵌套/空列表、异构拒绝、重复itemID/配对键、单位不符、稳定排序、显式选择、report/strict差异、数据无副作用。允许局部实现选择；歧义先回Lead，不自行扩范围。

## PLAN r1：唯一结构化计划编译和解释器

共享类型 `WorkflowPlan.swift`、`WorkflowData.swift`、WorkflowTypes/Operation由Lead持有；使用当前已登记WorkflowOperation，不另建InferenceRuntime/Store/GPU队列。只新增 `Workflow/WorkflowPlanCompiler.swift`、`Workflow/WorkflowPlanExecutor.swift` 与 `Tests/DWorkbenchTests/WorkflowPlanTests.swift`。请求gpt-5.6-sol/high，初交最多1800秒（结构化控制实现），两轮修复上限不变。Worker不编译全包/不GPU/不GUI/网络，前端parse允许，Lead串行测试。源码可读当前Registry/Controller，但不得修改。

冻结接口：`public struct WorkflowPlanCompiler` init(registry:WorkflowRegistry = .standard)，`compile(_ graph: WorkflowGraph, tools:[WorkflowToolDefinition] = [], target: UUID? = nil, only:Bool = false) throws -> WorkflowPlan`；`static func digest(_ tool:WorkflowToolDefinition) throws -> String`用sorted JSON SHA256。compile无任何服务调用；按现有registry.plan拓扑但完整graph时包含所有节点。已知控制节点由node.control准确结构，静态检查所有局部图和工具身份/版本/digest、接口、重复名、schema；仅Call执行时获取资源。递归工具拒绝；合法嵌套至少2层，depth<=16、总体plan steps<=4096、loop1...1000；Map最大输入4096是数据边界。未选分支缺模型安装不能编译阻塞，不验证具体模型文件。

`@MainActor public final class WorkflowPlanExecutor` init(registry:WorkflowRegistry = .standard, executeCall: @escaping @MainActor (WorkflowExecutionContext) async throws -> WorkflowOperationResult, save: @escaping @MainActor (WorkflowPlanCheckpoint) async throws -> Void)。public private(set) checkpoint:WorkflowPlanCheckpoint?；`execute(_ checkpoint:WorkflowPlanCheckpoint) async throws -> WorkflowPlanCheckpoint`，`requestPause()`、`requestStop()`（只置协调标志，实际GPU取消由Lead/controller调用services.cancel，回调在返回前确保drain/release）。不自行另开Task或GPU线程。每节点输入绑定前后、终态、每item/iteration与等待都保存快照。safe pause在当前Call返回/释放后停，不启动下一步；save失败保留内存已完成record与saving状态并throw，再次execute(checkpoint)只补保存，不重做终态。外部输入checkpoint.externalInputs明确提供，缺失不自动运行其他节点。

执行地址 runID + node/branch/item/iteration/tool 的结构数组，实际stepID首次创建后持久不变；同模板各次调用独立，禁止仅nodeUUID缓存。命名body输入由N01节点parameters["publicName"]读取同名arguments，覆盖本次节点dataConfiguration.value；必填interface校验、缺必需参数拒绝，默认literal不改变原图。

控制规则：Branch对input Datum用predicate，选中子图arguments为inputRecord.fields或["input":datum]；只运行一侧。Map input List、shared可选Record；每item body arguments = shared.fields + item/value/index（index单位nil、1起始，保留itemID地址），冲突键拒绝；默认body返回output，或唯一命名输出；每项结果输出List<Result<T>>，稳定父itemID、失败位置，continueOnFailure决定停止；T取body.interface.output.schema，不猜失败值；空列表合法。Loop input State、shared可选；初始及next state验证stateSchema；先判断until，满足可零次；body arguments state/shared；body必须返回state（或唯一output），每轮完成后保存；输出output=终态，exitReason=枚举conditionMet/iterationLimit/failed/cancelled，不能上限冒充条件满足。失败/取消写明确loopExit并停止相应调用。Invoke根据固定reference展开已编译body，把具名inputs映射arguments，返回具名输出，不复制模板UUID作为调用身份。

Call复用executeCall回调；outputs校验并标完成，旧collection有失败则partial；旧reviewText/choose保持waiting，不自动决策；humanTask保存typed task等待。恢复遇到已完成记录直接使用；waiting无decision停止，typed human已明确decision且schema合法才输出，rejected停止不空成功。旧决定解释由Lead接线，Worker不得变旧语义。top-level interface命名outputs从明确node/port收集，无interface时返回最后step outputs。所有缺输入错误定位node/port/address；无字符串eval。对record/schema定义检查用实际类型。source map为每planned node原UUID+graphID/revision，实际调用地址保存在records，不能假称复制图为tool。

CPU测试：未选分支执行计数0；Map不同长度/稳定ID/一失败保位置；同工具双调用和至少一层nested tool不串；坏工具digest/recursive拒绝；Loop零次/满足/耗尽/失败/停止区分；每轮保存重开不重算；暂停不多调、保存失败不重算成功Call；边界外输入缺失拒绝；typed human等待恢复/拒绝不空成功。用受控executeCall，不绕过生产解释器。任何契约缺口回Lead，不改共享文件或降低标准。

## PLAN r1 歧义澄清（实现前）

冻结工具接口由编译器验证命名端口，编译器局部拓扑检查可取代不识别工具输出的旧registry.plan；不是另造调度器。effect只是描述，资源仍归executeCall/runtime；普通输出核端口/kind及Datum完整性，接口输出再核完整schema。only无target拒绝，externalInputs不得与已规划来源冲突。保存失败重试必须传executor.checkpoint；旧值不得导致重跑。人工拒绝映射cancelled并保留明确原因。深度统计全部块/工具嵌套，展开步数按每个调用实例计，不按唯一模板。具体发出记录在R/plan/implement-prompt.txt。

## 准备增量与中途结果

- 68d6e0e为记录准备，8b0d2d5为值型准备，3031ebc为计划/控制元信息；均未接入源。新存储清单分配17，继续拒绝候选13—15；旧16迁移先备份，不改原流程快照/资产。流程archive2承载新结构；未知字段只读保留。不是全项目迁移授权，只测试隔离fixture。
- R/lead/data-initial-tests：DATA原10测试通过，额外只读审查发现模板扩展预算与短路筛选单位校验缺口，进入repair1。显式none嵌套是Lead共享类型修补，不归Worker独立成功。
- R/lead/store-format-tests：首次新测试遗漏.dproject扩展而被Store拒绝，修正测试输入；r1四项通过。不是修改保护规则过测。
- PACK初14自测通过，非实现者指出stdout退出和NUL路径错误，进入repair1。PLAN已通过预检，实现中。路由均为受限CLI gpt-5.6-sol/high；隐藏服务端解析unknown。

## MUSIC r1：确定性音乐值与程序（不调用模型）

允许新增且仅三文件：`Packages/UI/Sources/DWorkbench/Workflow/Music/WorkflowMusicData.swift`、同目录`WorkflowMusicPrograms.swift`、`Packages/UI/Tests/DWorkbenchTests/WorkflowMusicProgramsTests.swift`。请求gpt-5.6-sol/high，初交1800秒；不改Registry/Store/UI/共享WorkflowData，不注册新引擎、不下载、不联网、不GUI，不文件渲染/播放。Worker只前端parse；Lead串行CPU测试。

公开纯值API由此冻结：WorkflowMusicClock(seconds,quarterNotes)；WorkflowNoteEvent(id:String,pitch:Int,start:Double,end:Double,velocity:Double)；WorkflowTempoMap(beatsPerMinute:Double,firstBeatSeconds:Double,numerator:Int,denominator:Int)；WorkflowNoteSequence(version=1,clock,notes,duration,tempo:WorkflowTempoMap?,sources:[WorkflowAssetReference])。WorkflowChordEvent(id,root:Int=0…11,quality:WorkflowChordQuality,octave:Int,inversion:Int,start:Double,end:Double)，quality major/minor/dominant7/major7/minor7/diminished；WorkflowChordTrack(version1,chords,duration,tempo,sources)，时间为quarterNotes。全部Codable/Sendable/Equatable，公共init；validate、datum()、init(datum:)。Datum为严格的版本化Record（format与version、clock/单位字段、typed列表），不改全局Datum枚举；schema可静态访问。空序列允许，非法/重复ID、越界音高、非有限值、混时间、非法单位必须拒绝。上限4096音符、256和弦、120秒或512拍；velocity0…1、pitch0…127；BPM20…300，拍号分母2/4/8/16、分子1…16；firstBeatSeconds允许负弱起但有界±120。保留源，不原地覆盖。

WorkflowMusicPrograms提供：
- align(sequence:tempo:snap:)throws->WorkflowNoteSequence：秒→拍，snap为none/quarter/eighth/sixteenth，步长1/0.5/0.25四分拍；不吸附保留时间，吸附首尾nearestAwayFromZero，塌缩音符延长一格且报实际边界；可保留负起拍。返回tempo，原值不改。M05。
- keys(sequence:)throws->[WorkflowKeyCandidate]：root:Int,mode:String,score:Double,algorithm:String。使用明确的时长加权音高类与大/自然小音阶契合率（在音阶权重1、非音阶0，主三和弦另0.25奖励，除总duration*1.25），稳定排序，最多6候选；少于3个音符或3音高类返回空表示不足；非概率、不冒称心理学标定/自动决定。M06。
- chordNotes(track:pattern:)throws->WorkflowNoteSequence，pattern sustained/arpeggio：12平均律octave以MIDI C4=60，转位把低音依次上移12，arpeggio每0.5拍顺序轮播末尾截断；duration半开，返回beats+tempo，不自动增写旋律。M07。
- render(sequence:sampleRate:)throws->Data：48000默认，可16000/44100/48000，单声道Float32 WAV；秒或带tempo的拍，负时间显式拒绝要求先截取；sine+5msattack/20msrelease，最多32同时发声，超限拒绝；峰值超0.95全段等比例缩放，保留关系，不逐样本硬削波；最大120秒/4096notes/累计100M音符样本计算，预估后再分配，Task取消定期检查。合成参考音，不称钢琴。M08。
- midi(sequence:)throws->Data：SMF0，960 ticks/quarter，tempo元事件（秒序列用120只编码时间），原velocity，off在同tick on前，同pitch重叠明确拒绝（不合并），安全VLQ/长度，负时间拒绝，末尾保留duration；不是MusicXML全量实现。

验证：秒拍往返原映射、弱起/吸附/塌缩、C大调与相对小调是候选非真值、短空不足、和弦构成/转位/分解时序、polyphonic合成有限且WAV真实解码/无文件原件、超预算预检、同时间noteoff优先/MIDI结构、所有纯值Datum roundtrip及非法版本/单位/ID拒绝。函数签名中snap/pattern可定义对应publicenum，额外局部helper自由；涉及共享接口歧义先回Lead。本包不注册操作；Lead之后把真实操作接服务和存储。

## FORMS r1：真实可调用的节点数据和人工任务表单

只新增 `Packages/UI/Sources/UI/Views/Workflow/WorkflowDataForms.swift`、同目录`WorkflowHumanTaskForm.swift`、`Packages/UI/Tests/UITests/WorkflowDataFormsTests.swift`。gpt-5.6-sol/high，初交1800秒，受限CLI预检。只语法parse；Lead编译/hosting/GUI。不得改Canvas/Controller/Store/语言包主文件、共享类型或本任务；语言新键及en/zh建议输出到任务output JSON由Lead合入既有包。

冻结接线：`@MainActor struct WorkflowDatumEditor: View` init(value:Binding<WorkflowDatum?>,allowsTypeSelection:Bool=true)，有类型Text/Number(unit)/Bool/Enum(选项及值)/Record表单，List/Optional也可递归编辑，Asset/Result只读预览，不用JSON作为唯一入口。允许选择类型是明确用户动作，未提交无效文本留本地草稿/错误，不把数字打半截变0。深度最多8层UI，超出保留只读数据。实例切换按身份重置由调用者.id(nodeID)；中文输入不要每次重建整个树。用户输入不当翻译键。

`WorkflowNodeDataEditor: View` init(node:Binding<WorkflowNode>,availableRecordSchema:[WorkflowRecordField]=[])。N01接value；N04模板字段后备；N05可增删命名输入字段/type/required/固定后备；N06字段菜单从availableRecordSchema展开有界路径，空schema时允许显式填写但不能猜字段；N07元素类型、固定items稳定ID增删/上下序、输入ports，明确一层concat由既有parameter控制；N08/N11规则与schema，N10配对键。普通scalar参数已有Canvas控件，不复制所有模型表单。输出写回实际node.dataConfiguration，空配置不自动启动，不保存文件。必要纯值form状态/helper写同文件且被真实View使用；invalid编辑保持原node不静默清空。

`WorkflowHumanTaskForm: View` init(task:WorkflowHumanTask,onSaveDraft:@escaping(WorkflowDatum?)->Void,onSubmit:@escaping(WorkflowDatum)->Void,onReject:@escaping()->Void)。提交前resultSchema验证；只明确按钮调用onSubmit/onReject，选择/编辑只保存draft；editText可用原生文字编辑、singleChoice/multipleChoice列出materials List的稳定itemID选择、approve Bool、editMusic先用真实Record/数值表单(音乐专用增强由Lead接)。不默认第一项；未知任务schema明确错误，失败不丢草稿，task.id改变才重置，不能跨等待ID回调。按钮可accessibilityIdentifier定位。

三层展示主要由Canvas接线；此包只可编辑动作/数据与等待面板。所有新文案走Environment dLanguageStore.text(key,fallback)，键前缀workflow.language.form；不能另外建翻译引擎。Tests检查实际使用的formstate/helper的无效输入保护、stable itemID、显式人选/拒绝/类型验证、中文/组合字符。Hosting只编译由Lead跑；Worker不得启动App/系统权限/写真实偏好/下载或递归派工。

## 中途组合核验（2026-09-27）

- DATA初交+repair1+repair2由Sol/high实现；第二修复补“前置false不能隐藏后置缺字段”，Lead复验14项DATA、4项值、5项存储通过。MUSIC初交13项XCTest通过，独立审阅另发现整数上界、ID长度与时间原点反例，repair1处理中；不是全音乐验收。
- 值预算调整为最多65536个值（类型定义仍16384、深度24、每List4096），使已冻结4096音符的6字段结构可往返；旧16k值预算与音乐上限冲突。需新预算边界测试，不放宽媒体/精度。
- 当前资源从已有离线依赖重新准备并按既有开发身份签入，四个清单验证成功。第一次SA3准备选错不存在vendor目录，创建前拒绝，r1按实际固定Vendor路径成功；证据R/delivery/engine-preparation*.json。
- Xcode27脚本沙箱只给普通output literal路径，子目录复制两次拒绝；未禁用沙箱。根据SwiftBuild一手源码改为只读校验＋原生Resources复制，保留沙箱和原有身份，不改Team/entitlements/系统权限。目录复制只作用新构建产物；Release排除此开发资源。旧embed工具仍供显式隔离目标使用，不用于扩大脚本权限。
- PLAN初交前端parse通过但Lead类型检查发现局部effect名称遮蔽；非实现者发现保存失败/Map/等待恢复缺口，集中repair1，未接纳。FORMS实现中。所有已结束Worker事件摘要无已观察越界；过程详情在对应R子目录。

## AUDIO-PROGRAMS r1：截取与规格转换

IMPLEMENT AUDIO-PROGRAMS r1 after verified preflight. Exact taskbase c9ea056e6f6c479c692f28fca070b3d4b1646028; same two allowedfiles; gpt-5.6-sol/high restricted settings observed by Lead. Read relevant Audio/PitchInputPreparer.swift,AudioMediaInspector.swift,AudioTypes.swift; preserve original pipeline.
Frozen API: public enum WorkflowAudioPrograms, static func transform(at source:URL, registered:AudioAssetMetadata, range:AudioFrameRange?, sampleRate:Int?, channels:Int?) throws -> Data. Missing range=whole; missing rate/channels preserve source. Explicitrate only16000,44100,48000, channels1or2. Input source is Store-owned exact frozen snapshot; still inspect before and after and match registeredhash/format. Policy generated for model/program origin elseoriginal; input finalduration <=120s for thisprogram, bytes existingpolicy, finitePCMonly. Half-open Int64frames exactrange, reject empty/outofbounds, no clamping. WAV output mono/stereo float32 littleendian, preservinggain, no normalize/pitchchange, no automatictrim. Stereo->mono arithmeticmean L+R/2; mono->stereo duplicate. Same rate no resampler: exactsource intervalframes. Ratechange use AVAudioConverter highquality similarPitchInputPreparer (do not change thatfile) with boundedstreamingbuffers and explicit drift<=1outputframe; expected count basedselectedframes not fullinputduration. Durationpreservewithin1sample; no nearest-neighbor/naivelinear resampler. Output <=120s and knownbytes; checkalllimits before largealloc, Taskcancellation whiledecode/convertercallback/encode. Partialread,conversionerror,noProgress,sourcechanged mustthrow. Do notfollow symlinksource, existinginspector/safefile conventions. No writes by productionfunction; tests ownsyntheticfiles in D_TEST_TEMP_DIR or own temporarydir only, no sourcefile overwrite except explicittest-ownedcounterexample.
M02 uses this with range only; M03 rate/channels plus optionalrange; both callerpublishes via existingStore, youdoNOT modifyStore/Registry/UI/services. Do not callmodel/runtime/GUI or adddependencies. Helpersallowed samefile; necessary synchronization matchesexistingMutex pattern, no unsafe/uncheckedSendable.
Tests use actual WAV fixture + AudioMediaInspector readback output: half-open region/ramp exactframecounts, empty/outofrange, invalidrates/channels, stereoaverage/duplicatedmono, 44.1/48->16 and16->48 duration/pitchofknownsine (sampledomainchecksnotear), unchangedbytes/hash, corrupt/nonfiniteinput, cancelled task, too longbudget. Reasonabletolerancesdocumented; don't mirrorimplementationonly. Lead runsCPUwholepackage, Worker swiftc-frontend-parse only. Record implementationdiff,commands,allfailureevents,ownedprocesses; no Gitwrites,recursiveagents,network,globalsettings. Twoordinaryrepairroundsbudget.
