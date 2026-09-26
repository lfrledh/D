# D-NODE-LANGUAGE-01：通用节点语言与四模态试用

## SCOPES r1：A16 局部运行与历史输入（language-v1-scopes1）

有限新增实现包，非旧PLAN/CHECKPOINT修复预算重置。只新增 Packages/UI/Sources/DWorkbench/Workflow/WorkflowRunScope.swift 与 Packages/UI/Tests/DWorkbenchTests/WorkflowRunScopeTests.swift。Lead持有Run/Controller/Store/UI接线。请求gpt-5.6-sol/high，初交1800秒+最多2普通修复；独立受限CLI，禁网/构建/GPU/GUI/Git写/递归，前端parse可用且缓存仅自己output/tmp。禁止heredoc/here-string/process-substitution；Python使用-c或自己output脚本+PYTHONDONTWRITEBYTECODE=1。未知权限拒绝立即停报。按已审阅契约实现，不另造执行器。

公开 Codable/Sendable/Equatable 值及显式public init：WorkflowGraphSelection = through(UUID), only(UUID), downstream(UUID, includingAnchor:Bool)；WorkflowCallReference(address:WorkflowExecutionAddress,stepID:UUID)；WorkflowHistoricalInput(destinationNodeID:UUID,destinationPort:String,sourceCall:WorkflowCallReference,sourcePort:String)；WorkflowRunScope(version:Int=1,selection:WorkflowGraphSelection,originCall:WorkflowCallReference?=nil,historicalInputs:[WorkflowHistoricalInput]=[],recomputeSelected:Bool=false)。Lead后加WorkflowRun.scope可选字段；Worker不编辑它。

非持久载体均Sendable+public init：WorkflowScopeBoundary(destinationNodeID,destinationPort,sourceNodeID,sourcePort)，WorkflowScopeSlice(plan:WorkflowPlan,boundaries:[WorkflowScopeBoundary])；WorkflowScopeSource(graph:WorkflowGraph,selection:WorkflowGraphSelection,checkpoint:WorkflowPlanCheckpoint)；WorkflowResolvedCall(graph:WorkflowGraph,plan:WorkflowPlan,arguments:[String:WorkflowDatum],externalInputs:[UUID:[String:WorkflowValue]],modelDefaults:[String:String],originCall:WorkflowCallReference)。

WorkflowScopePlanner公开static方法：select(graph:selection:tools:registry=.standard) throws -> WorkflowScopeSlice；rebuild(graph:selection:modelDefaults:tools:registry=.standard) throws -> WorkflowPlan；resolveCall(_ reference:WorkflowCallReference,source:WorkflowScopeSource,tools:registry=.standard) throws -> WorkflowResolvedCall；resolveHistoricalInputs(_ pins:[WorkflowHistoricalInput],destination:WorkflowScopeSource,sources:[WorkflowScopeSource],tools:registry=.standard) throws -> [UUID:[String:WorkflowValue]]。

through/only复用现有Compiler；downstream从完整编译有序plan求后继闭包，includingAnchor明确含/不含锚点，空范围拒绝。保留原step.inputs/signature/嵌套plan；interface只保留所选N01公开名与所选命名输出。所有源不在选区、目标在选区的连接均列boundary，含菱形旁路；选择函数无服务调用。rebuild从独立graph+selection编译后freeze modelDefaults，不裁剪待验checkpoint.plan。

历史pin必须一对一覆盖全部boundary，拒绝漏/重/额外/覆盖内部边；source按完整runID/address/stepID/port精确取.completed或.partial的真实outputs，不使用preview/waiting/draft/latest。source nodeID与port须匹配该boundary原连线来源；改接其他来源须用户先编辑连线。每个source用自身graph/selection/defaults独立rebuild并公共CheckpointValidation验证。冻结完整值且类型/单位校验；目标可用新ready checkpoint（records空），其plan仍要独立对照。来源runID不可重复。历史源自身来源链真实性由Lead在Store按已保存运行顺序检验；本helper不声称密码学身份。

resolveCall只处理已存在、输入已绑定的具体Call记录，不执行控制模板。先独立validate source，再按完整地址沿冻结graph/control/tool查真实所属graph；tool的id/version/digest全核对，最终kind必须call。允许completed/partial/failed/cancelled但失败前未绑定必需输入须拒绝；waiting/rejected不派生为暗中接受。返回该局部graph编译only的冻结plan，externalInputs只含此step的绑定inputs，arguments只投影only接口，N01公开输入用已验证record.runtime node value，不用模板旧默认。以新run/step执行，origin保留旧完整地址。无旧outputs/decision/candidate复用，无父图更新；同模板Map item、Loop iteration身份不串。graph保留原局部身份及签名供Store独立重建；模型用source checkpoint defaults+显式node modelID，不读当前UI。

验收真实Compiler/Executor CPU夹具：菱形downstream全边界/含不含锚点；缺/重复/内部pin拒绝；新run不能改变指定旧run输出；Map同nodeID不同item、Loop轮次及N01实际参数；工具摘要坏值拒绝；派生调用只运行该Call且无父操作；独立rebuild拒绝伪造plan/inputs；编码回读scope；空/未知范围拒绝。用现有纯操作与假服务计数，不写第二调度器。前端parse只证明语法；Lead串行跑CPU。Worker交差异、测试方法、异常、进程及缺口，无文档写权。


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

## STRUCTURED-TEXT r1：语言模型结构化输出解析

限定新增 `Packages/UI/Sources/DWorkbench/Workflow/Models/WorkflowStructuredText.swift` 和 `Packages/UI/Tests/DWorkbenchTests/WorkflowStructuredTextTests.swift`。请求Sol/high，受限CLI、1800秒、初交+两轮普通修复；只前端parse，Lead串行CPU。生产调用方为新N03，模型原始文字先由既有Store保存，解析失败保留原文与错误，不自动修复或伪称原生约束解码。本包不调用模型/Store/UI，不改共享类型。

API `public enum WorkflowStructuredText { public static func parse(_ text:String, as schema:WorkflowDataSchema) throws -> WorkflowDatum }`。仅完整标准JSON，允许两端空白，拒绝markdown围栏、前后说明、多JSON值、重复对象键（包括转义后相同键）、非法Unicode/数字/尾随逗号。Text schema也读取JSON string；原始普通文字模式由调用方直接text。支持Text/finite Double Number/Bool/Enum/Record/List/Optional；Result和Asset schema本轮明确拒绝（模型不能制造已发布资产或执行结果）。数字与Bool严格区分，单位取冻结schema，不猜字符串数字。Record拒绝未知字段，required缺失错误，非required可缺但null只有Optional合法。List保序，生成稳定itemID为1起始索引字符串，<=4096。Optional null=>none(inner)，非null按inner解析。JSON输入<=1MiB、嵌套<=24、总值<=65536、Record<=256；源码编码/字符串Unicode准确。解析前/中有界，不先无界解析再检查；可以局部受控parser，也可安全系统解析加重复key/结构预算扫描，但不能eval/执行或读取URI。输出完整Datum.validate(as:)。错误含字段/索引路径且不泄露本机信息，不吞异常成空。

测试：真实JSON成功Record/List/Unicode/escaped-string/Optional，错类型(bool对number和反向)、非有限/超大数、单位schema、缺/多字段、null、Enum、重名键直接及Unicode转义、尾随文本/围栏、深度/输入/数量、Result/Asset拒绝，相同输入稳定ID。至少一个反例中旧合法值不受影响（纯函数），错误可定位。解析算法由Worker选择，不逐函数指定。


## CHECKPOINT r1：结构化运行记录的纯校验

只新增 Workflow/WorkflowCheckpointValidation.swift 与 Tests/DWorkbenchTests/WorkflowCheckpointValidationTests.swift（根分别 Packages/UI/Sources/DWorkbench、Packages/UI/Tests）。Sol/high，受限CLI预检；初交1800秒+两轮修复。禁止改Controller/Store/Executor/共享类型/文档/工程/模型。只parse；Lead串行测试。无网络/模型/GUI/Git写，不递归。

API public enum WorkflowCheckpointValidation, static func validate(_ checkpoint: WorkflowPlanCheckpoint, expected: WorkflowPlan, registry: WorkflowRegistry = .standard) throws。纯校验：checkpoint.plan 必须精确等于 expected；expected由Lead调用方从冻结graph/tools编译并冻结明确modelID，不能把原checkpoint.plan自身作为受信expected传入。本文件不编译graph/读Store。原规则不改变：plan版本1、深度16/静态4096steps，接口schema/端口名唯一有界，运行records最多65536、路径深度有界、records地址/stepID唯一，全部runID正确；enum分支对应真实计划节点和所选子块，Map itemID属于父绑定List且长度合法，iteration范围与loop类型对应，invoke reference含digest完全相等。父调用记录必须存在。

每record必须能从地址追溯planned node；静态node字段一致，只允许N01具有publicName且接口声明时的dataConfiguration.value按实际公开输入覆盖；schema验证不可跳过。顶层arguments按interface，嵌套实际arguments沿父inputs构成：Branch record.fields或[input]；Map shared+item/value/index且冲突拒绝；Loop shared+state/iteration（读取原Executor语义）；Invoke父inputs转datum。Loop后续state可由前轮体接口nextState输出恢复。先核真实Executor，不凭此摘要猜键名。有歧义暂停告知Lead，不造猜测语义。

校验所有arguments/externalInputs/outputs、record输入输出、dataConfiguration、human材料/草稿/决定的Datum完整性；拒绝不存在的端口或错误类型；在running/queued可缺输出，completed/partial必须完整输出（review的preview仅等待允许）；外部输入只能顶层计划边界外端口，不能覆盖计划内连接。humanTask.id及decision.waitingStepID对应stepID，结果schema有效，用户draft允许不满足最终schema但仍合法Datum；已提交decision须满足schema。人工rejected不能同时含decision。控件draft只是文字仍有1MiB限制。返回副作用零；不运行/存储/改变状态，不让Dictionary重复key trap。

资产引用存在性仍由ProjectStore按已发布资产逐项核，Worker可提供 static func assetReferences(in checkpoint: WorkflowPlanCheckpoint) throws -> [WorkflowAssetReference]，完整收集所有层次（含plan node/data/control/interface规则值、记录inputs/outputs/decision/human）。不得验证文件或访问URL。

测试真实Compiler+Executor产出的简单/Branch/Map/Loop/Invoke/人工等待快照可validate；mutation反例：错runID/plan身份或参数/重复接口/重复address/stepID/不可能分支或item/iteration/toolDigest/静态node被替换/外部输入覆盖/非法Datum/人工task身份和decision类型/深层资产收集。只纯CPU替身，不另写调度器。Caller不把“通过此结构校验”冒称反篡改签名或模型实测。

## 接线中途（非验收）

FORMS两轮修复后CPU通过，AUDIO-PROGRAMS一轮修复后11项通过（补AVAudioFile完整读测试；CAF非整数采样率不显式转换时拒绝，因WAV不能无损表达）。STRUCTURED初交12项通过；非实现者只读审核通过。所有Worker已交还写入权。各实现/失败日志在对应R子目录，不修改历史预算。
Lead添加实际N03/M04—M09/V01操作与纯条件桥接，尚待产品接线。MRT2条件映射保留0休止/1延续/2起音；同pitch重叠按所有唯一起音分段覆盖；过滤零力度，不编码声部/非零力度。原乐谱不变；条件时间25Hz四舍五入，塌缩/越界拒绝。M09要求显式音符（可空），不以无条件生成冒充受控。此策略和共享时间映射有独立只读审核及新增反例。

## CONTROL-FORMS r1：可编辑控制块与公开接口

Worker仅新增 Packages/UI/Sources/UI/Views/Workflow/WorkflowControlForms.swift 与 Packages/UI/Tests/UITests/WorkflowControlFormsTests.swift。Sol/high，独立受限CLI，初交1800秒+两轮修复；只parse不全包构建，Lead测试。不得改Controller/Canvas/Store/共享类型或任务记录，不网络/GPU/GUI/递归/Git写。

生产视图API（UI模块内，Lead装配）：@MainActor struct WorkflowControlEditor:View init(node:Binding<WorkflowNode>,tools:[WorkflowToolDefinition],onOpenBody:@escaping(String)->Void)。slot字符串仅then/otherwise/body/tool，按钮显式调用，不自动运行。编辑现有node.control：branch条件predicate(path/comparison/value)与两侧进入；map continueOnFailure；loop stateSchema/maximumIterations1...1000/until规则；invoke显式选择固定id/version/digest工具，同步dataConfiguration.fields至接口。缺control提供明确“创建局部流程”动作，用通过字段N01 publicName input→N17 return构造可编辑最小body，合法interface；Map body公开item/value/index，返回output；Loop body公开state/iteration，返回nextState（默认原state，loop上限不自动无限），须以真实Executor键名为准。创建并不启动。不以空卡片冒充body。可新增实际使用的纯helper供测试。对于类型/结构编辑，可复用WorkflowDatumEditor通过示例值得schema，允许Text/Number/Bool/Record/List等，拒绝Asset/Result的随意伪造；无效草稿不写回合法node。

另提供 @MainActor struct WorkflowGraphInterfaceEditor:View init(graph:Binding<WorkflowGraph>,registry:WorkflowRegistry,tools:[WorkflowToolDefinition])。真实公开输入name/schema/required，可增删改；输出name/nodeID/port/schema来自显式选择（候选为此graph节点有效端口），可编辑，不猜同名；重复名/无效schema保留草稿并显示错误。输入声明后同步到该公开输入N01的参数由Lead图操作负责，此表单只定义interface。不要重置用户图节点或连接。字段行身份独立UUID，改名不重建输入；编辑完整验证才发布；Graph revision由Lead的Binding setter维护。支持空输入/输出草稿，但执行缺output错误由Compiler报告，不静默选首项。

新文案用既有语言Environment，键workflow.language.control.*；新增en/zh文本建议只输出任务output JSON。所有edit仅值Binding，文件/执行/模型均无调用。Tests实际helper检查创建body可Compiler编译、Branch两侧/Map/Loop结构和变量键、工具digest固定、切换工具接口显式更新、重复字段/错误类型不毁旧值、Unicode稳定行ID。不造第二执行器。Lead负责树状导航、包装/展开工具和运行按钮接线；Worker不修改这些共享所有权。

## 统一运行接线中途检查（2026-09-27，仍未产品验收）

Lead将Controller接到同一PlanExecutor，保持M0目标/单步、候选、确认与保存恢复；默认模型在提交时纯值冻结，实际Call按需租约。补取消发生在产物已保存/模型释放时的回归，恢复不重生成。N02扩大媒体引用，N18类型化导出沿原排他原子发布。独立只读审核指出编码预算需前置、媒体format不可忽略，Lead补前置保守编码预算及真实服务反例。预算不是模型容量限制。局部图编辑路径已提取，真实控制表单尚待接线。

`lead/lead-routing-export-editing-r1`通过本次过滤集合（完整输出保留；Swift Testing 60项、XCTest单列），此前新导出fixture漏填图片尺寸导致一次失败，补齐真实声明后通过。受测为候选e443dcde工作区已知增量，后续提交记录字节映射；不称在未来SHA上测试。CHECKPOINT初交已有3项签名兼容失败，非实现者另找到拒绝preview/控制输出链接/决定输出一致性/公开输入校验缺口，尚待普通repair1；当前不能将其作为已接纳保护。

CONTROL-FORMS初交结束、两文件候选。存在一次`/dev/fd/11`进程替换只读拒绝后未停报、改jq继续的协议事件；没有观察到成功越界或扩大权限，不追改成合规。Lead检查完整事件、任务文件及受限上下文后继续范围内审核。该事件独立于代码质量。Loop轮次参数由Lead按既定state/iteration契约补接，原Worker临时optional写法后续同步；不把未实装变量显示成已运行。

## EXAMPLES r1：四套真实语言样例（新增独立工作包）

允许文件仅新增 `Packages/UI/Sources/DWorkbench/Workflow/WorkflowLanguageExamples.swift` 与 `Packages/UI/Tests/DWorkbenchTests/WorkflowLanguageExamplesTests.swift`。Sol/high，受限独立CLI、1800秒、初交+两轮修复。只parse不构建，Lead串行CPU。禁止改Controller/Store/Executor/Registry/UI、模型/网络/GUI/Git写/递归派工。输出仅本任务目录。

API `public enum WorkflowLanguageExample: String, CaseIterable, Sendable { case data, images, music, multimodal }`；`public struct WorkflowLanguageExampleBundle: Sendable { public var graph:WorkflowGraph; public var tools:[WorkflowToolDefinition] }`；`public enum WorkflowLanguageExamples { public static func make(_ example:WorkflowLanguageExample) throws -> WorkflowLanguageExampleBundle }`。只用当前注册的真实操作、control、类型与公开接口；所有图可编辑且唯一id；模型ID留空由现有Controller提交冻结，无路径/书签/预存模型输出。例子不是特殊执行器，不允许生产分支按样例名字调度。

E01无模型覆盖N01、N05—N14、N17—N18：普通字段/列表数据、提取、排序筛选、index配对、校验报告、真实Branch/Map/有状态有限Loop（nextState变化）、返回；导出需用户选目录。正常默认可完成到返回；坏字段/空列表/单项失败以明确可编辑值构造，不默认失败。可用多个根输出但UI目标建议为末个return。
E02默认2主题×3图：语言规划共享一次，主题列表运行时数量；Map每主题图生成count3（不要再乘外层3），可选共享图ref，N03结构输出/检查，尺寸格式处理应在明确选出图后或列表映射；默认无人工关卡，使用受控已成功集合取项需检查现有操作是否支持，不发明不可执行桥。G01输出collection与Datum list差异遇必要缺口立即报Lead，不私加新操作。至少一个真实Invoke工具承载可展开部分，节点接口不写死两个主题。参考可由N02显式接线，可缺省；所有模型生成仍未验证。
E03导入/录音asset输入→可编辑截取/格式→SwiftF0识别→typed human editMusic显式人工采用（这里用户任务有意选择）、tempo对齐、调性候选、用户明确和弦编辑→M07→M08试听参考→M09真实notes/chords条件、Map3候选。默认4s、恒定BPM/拍号；和弦已给分支无语言前置。保留可接N03建议分支但别伪造小模型质量。至少一段普通Invoke封装复用。未知录音不靠预存识别代替。MRT2目前没有seed别造参数；notes/chords明确传。M01原生录音由LeadUI接线，本包只资产输入。
E04同一发布文字输入分叉文字/图像/受控音乐/T2V，以Record返回资产并含themeID；至少一模型操作每模态，无I2V假边。视频真实参数短小在现有profile，不为本机限制产品上限。编辑模型/配置不自动执行。

依据当前 operations/plan/types和附件02/03必要段落制作；API缺口报告，不造dummy操作。Tests每样例真实Compiler编译、unique/node counts、tools digest/interfaces、公开工具可在不同图多次Invoke、无默认人工（E03明确人工例外）、文字共享不在图像抽卡重复、E03真实notes连接、V01无image条件。尽量实际Executor+fake服务无模型运行E01验证动态列表/Loop，绝不冒充模型验证。样例语言标签可提供 en/zh建议文件，代码标题暂中文可由Lead本地化。回传例子连接/局限与运行目标，而非“GUI已完成”。

## 工具与人工界面接线中途（非GUI/模型验收）

Lead接入局部body导航、真实ControlEditor/公开接口、选区边界检查后Invoke封装、固定工具展开为独立编辑副本/另存、typed人工决定与安全暂停；所有运行仍同一个Executor。人工决定用完整期望task比对，且同一顶层等待点不再在主/历史创建两个可编辑表单。Control表单更新被Controller拒绝却误标Apply成功、dirty进入丢草稿两个问题交CONTROL-FORMS repair1，预算仍初交+两轮。Loop现在明确提供1起始iteration，UI必填，原临时optional断言随契约修正，不是放宽标准。

EXAMPLES初次实现因旧G01集合到通用List缺口按要求停报，无写入；这是共享接口缺口，不计普通逻辑返工。Lead新增明确 `d.value.candidates` 适配操作：output为全部record列表（id/attemptID/十进制seed/status/optional资产与错误），successful为显式过滤后的图片List；不丢失败、不调用模型、不改变旧G01/选择语义。`tool-candidate-bridge`相应CPU/界面类型检查通过，实际GUI/模型仍未验收。续接初交总1800秒预算扣除已用124.42秒，普通修复仍0/2。预检shell误用了zsh path导致一次127，绝对路径只读补读成功；Lead明确分类后核验实际Sol/high/隔离/禁网，未当成权限通过探针。

## 持久化接线与第二轮校验（2026-09-27，仍实施中）

Lead将checkpoint的独立图/工具编译对照接入真实ProjectStore，核对runID与顶层投影；不信任checkpoint.plan自身为expected。真实单步首次保存同步投影。preparingRetry保留已完成/partial父调用下的失败证据，不让下游重试篡改Map已结算项。新增实际Executor反例；旧冷恢复fixture同时更新v2 checkpoint/投影，未放宽验收。`lead/durable-plan-integration-r1`62项/4套CPU通过，起点fbedbe654+本提交已知六文件增量；不是全任务或GUI通过。

CHECKPOINT repair1在Lead CPU有6/7失败（fixture可选nil==nil误触发故障、公开输入输出schema不一致），独立审阅另发现Loop恢复前缀、控制求值失败保存边界。已发最终ordinaryrepair2，仍原任务0次Lead接管；共享retry缺陷由Lead负责。CONTROL-FORMS repair1本机CPU已通过，EXAMPLES续接初交573.37秒完成、无新权限事件、两文件已提交候选bc94274（完整SHA外部Git记录），初交累计扣除此前124.42秒，不重置预算。

源仍130603d23a4da81ba2a9852766f3589695ec9468，个人scheme内容/未暂存状态核对不变。H27 GUI锁屏仍保留；没有新原生或模型验收。所有实现归因按各任务记录保留，不把Lead接线/修复归为Worker独立完成。

## 媒体交互接线复验与 LOCALIZATION r1

Lead新增AudioCaptureHandle（不同于文件描述符的AudioCaptureIdentity），按context/captureID结束并查本次已发布原声。非实现者发现预约等待取消/关闭残留/预览过期副作用/恢复绕过互斥四项，Lead修补并加实际预约边界、项目关闭重开、拒绝停止别的录音回归。`capture-hosting-integration`68项CPU/5套及2项hosting通过；补`admission-durable-regressions`22项/2套通过，含真实Store独立编译校验与深层未发布资产拒绝。hosting第一次失败因旧fixture未显式设置冻结模型身份（错误“请为节点选择模型”），补fixture的明确身份后通过，未放松生产选择。CHECKPOINT repair2的真实Executor快照测试通过（包含在前述组合），2/2普通修复已用；没有接管重写该Worker算法。

新增LOCALIZATION r1有限包：仅可修改 Packages/UI/Sources/UI/Resources/Localization/en.json 与 zh-Hans.json。复用当前语言架构，不改格式/已有语义/用户数据/模型ID。将FORMS和CONTROL-FORMS建议中实际使用的新键补齐中英，并查本轮Workflow UI新键（Canvas/Host/ToolPanel/DataForms/HumanTaskForm/ControlForms），补匹配键。占位符集合严格一致；语言/工作流ID或用户内容不翻译。可以修准确翻译，不擅自删除旧键、改变schemaVersion/locale/displayName；重复键不允许。现有JSON保留原顺序/格式。无法通过资源解决的硬编码文案与错误另列任务output，不改Swift。验收：JSON解析、两包新键一致、占位符一致、无空翻译/重复键/旧键丢失、关键英文表达保持false/unknown/失败/跳过等差异；Lead跑现有语言与hosting测试。请求gpt-5.6-terra/medium，独立受限CLI新会话，初交1800秒+最多2普通修复，不重置其他任务预算。无网络/build/GPU/GUI/递归/Git写；Python只内存解析无默认py_compile，输出/缓存仅任务根。先只读预检，经Lead核验再IMPLEMENT。两JSON以外只输出局部报告，由Lead维护本记录。

## SCOPES、语言包与真实文字中途（2026-09-27，未完成阶段）

源仍130603d23a4da81ba2a9852766f3589695ec9468，scheme摘要/未暂存状态不变。组合0ee7b24c013d1ec368fa7b0e0fb2bcc12e31313a含SCOPES511b66eb与repair1 e813e56；Lead6118745接线与翻译接管。SCOPES初交657.23秒，repair1 200.46秒，均Sol/high受限同线程01a0def1-58d9-77d3-84b1-1e8f68f4c52d；初交一次no-index diff返回1且无诊断不是权限事件。只读审核发现来源所属图及Loop单位缺口，repair1补实际反例。repair2处理中：裸asset(text)不能冒充结构化Text，保留无schema旧端口兼容。不得把helper或CPU通过称为A16原生验收。

LOCALIZATION Terra/medium线程01a0dee6-0853-7930-b296-f876e1d3c773初交169键/locale，a93c17de保留贡献；repair1/2分别36.74/18.58秒主动结束而未做缺少的176动态字段，2/2普通预算已用。无新增权限拒绝，旧heredoc拒绝和获准恢复历史保留。Lead一次有界接管补176键/locale；非实现者核对已有值不变、两语言键相同，改itemID中文为列表成员ID。真实Registry覆盖由红变绿，证据lead/scopes-wiring-r1中该suite。费用与完整Lead归因仍unknown，不宣称Terra独立通过。

Lead补capture第二await取消、活跃Workflow迁移显式拒绝且可恢复、根externalInputs不污染嵌套同UUID节点；分别lead/capture-second-await 16项、workflow-relocation-owner17项、nested-boundary-green-r1 36项CPU。EXAMPLES repair1 c25d2144补坏项真正失败及音乐出口包含全部条件路径，lead/examples-repair1七项CPU。历史证据与本轮模型结果分开。

真实文字受测代码7ca59946a0aa51925a5f65fe35199502e2a6306b，build-r2通过。此前Swift6.4在require闭包直接调用上断言崩溃、随后require复杂可选表达式宏编译错误，拆开表达式解决，不改产品语义。lead/node-real-text使用固定Qwen1.5B8b403126fc14f14cfc99bb4cfa72ecbc129ea677，任务生成及改写真实成功，第三次JSON输出带markdown围栏，按原严格契约失败且raw保存。新fixture只澄清首尾括号要求，不剥离围栏或放宽校验。记录request-step逐项身份、prompt、参数、旧历史和重开，全部require后才写PASS；非实现者审阅，不宣称GUI。真实失败项目位于测试容器NodeLanguageAcceptance/6E1A6E6B-00DA-481B-A9B1-5F1E35880739，根路径见lead/node-real-text日志；后续拷贝到外盘证据，不覆盖原件。

lead/scopes-initial九项之前为七项通过；lead/scopes-wiring初轮55项1个Lead夹具查错不存在template失败；修正选真实Map Call并增加保存恢复，scopes-wiring-r1 55项/4suite通过（0ee7b24c加已知Lead修改，非未来提交SHA）。随后只读审核补派生resume归属、来源合法重试、typed/M0人工等待和面板打开时身份冻结，正在scope-derived-lifecycle复验；这些仍是未接纳候选。GUIH27锁屏未重试，后续四模态/样例完整真实验收未完成，不启下一阶段。


### MEDIA-CHECKS r1：真实图像和视频节点集成验收（2026-09-27）
- 属于本轮 A09/A17/A24/A25/A26/A36；不是新产品阶段。Lead 冻结下列验收，Worker仅实现测试；实际模型由Lead串行运行。
- Worker gpt-5.6-sol/high；仅 `DTests/NodeLanguageImageVideoRealTests.swift`，不修改生产逻辑、工程、断言政策、语言包或本文。初交＋至多两轮定向修复；独立输出/tmp；网络关闭；不接触真实偏好/用户素材/模型内容；不运行构建/GPU/GUI。允许Swift frontend parse（TMPDIR指定、无模块导入）。
- 图像：opt-in 环境 `D_NODE_LANGUAGE_REAL_CASE=image` 和显式 `D_NODE_LANGUAGE_IMAGE_MODEL`。复用 AppSessionFactory/WorkflowServices/Controller 与现有图像配方。运行实际官方 E02（不是复制隐藏调度器），两组各三图，每候选 request/seed/attempt/归属/PNG真实解码必须检查，随后使用一张本次图片作为单参考再生成一次；在项目保存、重开及来源中核对参考身份，不能只比较prompt。尺寸使用本机已验可缩放配方，512×512/4步/guidance1，不改精度。先启动一个独立取消任务，见运行时活动后取消、等待 drain 后执行正常任务，不能把仅排队取消宣称GPU取消。需保存观察到的取消阶段。
- 视频：opt-in case=video，显式 `D_NODE_LANGUAGE_VIDEO_MODEL`；由 Bundle.main 解析视频引擎，通过 AppSessionFactory 与同一 Controller 调用 d.video.generate。256×256、17帧、16fps、4步、guidance5、seed42、既有 profile；真实MP4解码检查尺寸、帧数/时长和帧数据，不能只查扩展名。取消及后续恢复同上；T2V明示无图像输入。
- 每个测试创建全新App容器内自有项目，不修改现有项目；显式资源目录，缺失即失败而非成功skip（未opt-in才disabled）。请参照已有 NodeLanguageRealTests / M0RealWorkflowTests 的生产接线，不碰共享实现；原有模型租约和资源检查不能绕过。模型绑定必须准确，来源必须是实际请求值。
- 测试结束无论成败 shutdown、关闭自有Store；不停止别人进程。保存根路径、模型revision、请求/运行/输出、耗时和状态到自有项目旁；失败也保留产物。正常结论须保存重开并回读。不得声称普通GUI、人工试听、Xcode Run、系统断网或发布通过。
- Swift Testing宏对复杂 optional/coalescing表达式有已观察问题，先求局部值再断言；不是放宽条件。只读源码后发现接口/契约不明须报Lead，不能修改生产代码来过测试。完整参数和写根以对应外部job.json/preflight为准；执行基线为本准备提交。

## A06-REPAIR-GRAPH r1：可展开的有限 JSON 修复工具（2026-09-27）
这是原 A06 尚缺的结构功能，不重置 DATA/EXAMPLES 的修复预算。N03 原 json 模式保持严格失败+raw；Lead新增 N11 可选 validationInputFormat=jsonText，用同一解析器输出 valid/data/issues，缺省编码与旧 typed 行为保留。规则/输入类型错误在解析 catch 之外；不剥围栏、不自动下载/执行文字。新增纯值/界面契约 validation-json-contract-r1 的过滤 CPU/hosting通过（1e70ab1＋本次已知7文件），首次夹具漏传services编译失败已纠正。

新 Worker 包仅新增 Packages/UI/Sources/DWorkbench/Workflow/WorkflowJSONRepairTool.swift 与 Packages/UI/Tests/DWorkbenchTests/WorkflowJSONRepairToolTests.swift。gpt-5.6-sol/high 受限独立CLI，初交1800秒+最多两轮普通修复。禁止递归、网络/GPU/GUI/构建、共享状态或旧样例修改、Git写；只 parse 允许文件，Lead串行CPU。固定纯值API public enum WorkflowJSONRepairTool { public static func make(schema:WorkflowDataSchema, task:String, exampleJSON:String, maximumRepairs:Int=2) throws -> WorkflowToolDefinition }。需先验证schema及exampleJSON，并验证1...2上限。工具公开 content:Text，输出 output:schema，全部由真实N01/N03/N04/N05/N06/N09/N11/N14/N17及existing graph/control组合，不能新增执行器/控制服务/隐藏闭包。所有内含语言节点modelID空待提交冻结，temperature0，maximumOutputTokens768；初次任务及修复任务明确完整目标schema对应exampleJSON，仅作为结构示例不可强制复制内容。

初次N03 Text→N11 jsonText report，Record state={text:Text,check:Report<T>}，Loop直到check.valid==true，最大两次修复。body声明state/iteration，用字段+列表取项提取上一文本和第一问题，再模板成完整修复任务，N03 Text→N11→nextState。可用额外公开共享值传original content/任务；必须显式普通端口，不能隐式读取图名/当前页面。最终取text→strict N11 jsonText→取data并return T，非法最终值不得流到图像。工具保存所有失败文本与轮次，不静默洗JSON；有限循环结束原因与验证成功分开。用户能展开编辑另存该图。Lead负责将该工具接入E02并调整对应新结构期望，不由Worker越界写旧文件。

测试实际Compiler/PlanExecutor，不另造调度器：首次valid只1次模型；围栏invalid后valid恰好2次；持续invalid最大3次失败，无下游成功输出；duplicate/unknown/type错误失败；resume不重复已完成调用；取消与保存故障保留原状态不成为parse修复；输入不同能影响实际context，不把example当固定答案。使用已有fake OperationServices/response资产读取接口。不能运行真实模型或声称GUI通过。先PRECHECK核验目录、Git、模型可观察上下文、写根，再IMPLEMENT；文档Lead维护。

## 真实验收恢复点（2026-09-27）
真实文字node-real-text-r2于f593b051ff483461444317f9d7ad986ca0a2fae9通过，5次请求含同计划headless，原raw/来源/重开保留；不是GUI。全UI包language-ui-combined受测9d51f75dbc6dd215055ac6569d8c219a7a8de778通过（160UI、23独立入口、577Workbench，分组记录不冒充模型）。EXAMPLES两轮结束；Lead a58c2ac对和弦JSON任务及差异fixture有界收尾，11CPU通过，非实现者复核关闭。MEDIA-CHECKS初交+repair1已提交548b7522b3052abdf8952a0198f7b68381a1dae4并合入，余1轮；运行时graph模型首次输出围栏JSON被拒绝，尚无6图通过；独立图像取消观察到运行时活动后drain，不能夸为某GPU内核中断。

音乐node-real-music（13cfd51）及node-real-music-access-diagnostic（1e70ab1）均在Pitch access失败，尚未进入MRT2。第二次确认新创建临时书签被CF判stale；具体grant/环境根因未知，未放宽权限。f8189f4仅白名单原因，非实现者核验无权限变化；11Python测试使用准备环境通过，系统Python无numpy的失败保留。Lead端口归属1e70ab1按冻结owner graph过滤复制工具同UUID，并保持各Map调用；非实现者复核关闭，相关过滤CPU已通过。旧预览pause/close不得控制后来播放器。

源仍130603d23a4da81ba2a9852766f3589695ec9468，仅scheme个人修改摘要/索引/未暂存状态未变；候选未源接纳。H27锁屏GUI阻塞，无新原生录音/试听/断网结论。当前Worker均已交还写入（新A06待预检）；外部证据R=AgentTrials/D-NODE-LANGUAGE-01/run-20260926T150929Z，resources-v2是自有新引擎，未替换普通D。下一步定位临时书签、实现A06工具并完成组合真实验收。

## TEXT-CONTROL-CHECKS r1：A08/A17 真实文字边界验收
只新增 DTests/NodeLanguageTextControlRealTests.swift，gpt-5.6-sol/high，独立受限CLI。初交1800秒+两轮修复，不改其他任务预算。仅读既有NodeLanguageRealTests/Controller/Runtime必要接口及本节；不改生产/共享工程/断言政策/其他测试/文档，不Git写、不网络/依赖/模型/GPU/GUI/全构建，只parse自己的Swift。Lead执行真实模型与构建。

独立opt-in D_NODE_LANGUAGE_REAL_CASE=text-control；复用 D_NODE_LANGUAGE_TEXT_MODEL、已批准Qwen1.5B参数。AppSessionFactory+WorkflowServices+真实Controller，隔离App容器新项目/suite，无模型替身。测试一：真实d.control.branch，输入Bool选择有Qwen的body，未选body指定不存在的modelID（结构合法），实际选择的语言生成完成；resolver/调用记录检查未选ID零解析/准备/提交，不因未安装拦住另一分支。保持正文、固定request/model及parent来源，保存重开。
测试二：同一runtime创建单独文字生成，等待可观察真实运行/首片段（有限超时），cancel，等待任务和drain/release结束，然后成功执行另一文字请求。报告实际观察的阶段，不能把generating笼统称GPU kernel中断；取消后下一任务正常不串旧输出。若生成太快先完成，明确不满足cancel证据，不能伪称取消成功。可用当前已支持较长输出512 tokens及单次可解释fixture，不用无限重试。原文和旧资产不变，结果记录实际状态和调用ID。
两测试均有限等待、finally shutdown/关闭自有项目、不结束普通App。失败也保留证据、成功才PASS；记录elapsed、model revision、run/request、真实取消边界。输出在专属项目旁json；不导出书签/模型权重/个人数据，不声称GUI/离线通过。必须复用既有生产执行器。任何接口或权限未知停报。Lead统一注册/编译（当前DTests自动发现若不支持报缺口），不为写测试私加生产API。

## MUSIC-CANCEL-CHECKS r1：A17 真实器乐取消与恢复
新增原验收尚缺的一项测试，不重置原MUSIC/EXAMPLES预算。Worker Sol/high只新增 DTests/NodeLanguageMusicCancellationTests.swift；初交1800秒＋两轮定向修复；受限外盘树/独立output/tmp，网络关闭，不Git写、不构建/GPU/GUI/依赖、不递归，只parse自己的文件。必读本节、既有 NodeLanguageMusicRealTests.swift（引擎/授权/模型接线）、NodeLanguageImageVideoRealTests.swift（有限取消）；不读全部历史。

opt-in D_NODE_LANGUAGE_REAL_CASE=music-cancel，复用 D_NODE_LANGUAGE_MUSIC_MODEL 与 D_NODE_LANGUAGE_MUSIC_AUTHORIZATION（以现有真实音乐测试实际键为准，若不同沿用实际键并报告）。真实 AppSessionFactory+WorkflowServices+Controller、独立App容器自有项目。使用官方E04的d.music.generate及其普通有类型notes/chords输入，target仅音乐，不运行其他模态/LLM；4秒既有MRT2 small实际音符条件，保留既有模型许可声明注入边界，不能代用户点击。两个阶段：观察runtime.generating或实际进度后cancel，等待自有controller Task退出及runtime active/queue清空；再运行同一图音乐成功，WAV真实解码、时长/有限值/非零/来源条件/资产归属与保存重开核对。调用ID和run不串，取消未发表未完成作品，预先自有文字/值记录与已有资产保持。报告观察的取消phase，不称GPU kernel瞬间中断。模型没进入执行或太快完成则证据不足而非PASS。

所有异常必须cancel并await拥有的Controller Task，再shutdown并关闭自有Store；普通D不动。不可修改生产/现有测试/任务文档/断言。不跳过access stale或默认信任许可；环境不符报Lead。产出项目旁JSON含模型revision、实际取消ID/phase、成功run、elapsed、output摘要；没有GUI/试听/新录音结论。Lead执行构建与串行模型，并由非实现者检查测试。

## 2026-09-27 续接事实
1bc907d8ff7ba2dbcec0499fdc8bdf2c3c79d1c6 仅向隔离子进程保留父App本就具有且等于NSHomeDirectory的 CFFIXED_USER_HOME；不新增HOME、不改书签/权限、无全量环境继承。baseline和HOME-only探针失败，HOME+fixed及生产函数inherited探针通过；父字段存在匹配，非实现者复核通过。node-real-music-access-fixed构建代码1bc，启动记录b9a6c92仅任务文档差异，真实SwiftF0+两和声版本各3次MRT2通过；普通GUI/真人试听仍未执行。d3c8b826的E02用可展开有限JSON检查修复工具；json-repair-initial三个相关CPU suite通过。A06 repair1只补三类实际坏模型响应反例；TEXT-CONTROL repair1修取消阶段、保护夹具及异常清理，非第三轮旧任务。H27仍阻塞GUI，源与scheme未变。

### MEDIA-CHECKS 有界Lead收尾（不记为Worker独立通过）
真实video在App1bc已完成取消/后续生成，但原测试错误要求无任何inputReferences/parents；官方E04明确发布共享文字资产，T2V不收图片不等于无文字来源。Lead一次有界接管，精确改为仅prompt端口、恰好一个.text源、读取其真实UTF8、parents必须等于该源，再与VideoRequest.prompt核对；不改生产、模型、精度或真实MP4断言。旧失败保存node-real-video；非实现者复核及重跑待办。E02报告另记录1...3实际N03调用、raw归属及修复数，0次不冒称发生修复。MEDIA余下Worker修复不与接管串成无限链。

## PROCESS-RECOVERY-CHECKS r1：A15 跨进程检查点恢复
新测试包只新增 DTests/NodeLanguageProcessRecoveryTests.swift，Worker gpt-5.6-sol/high，初交1800秒＋两轮修复。原任务预算不重置。不改生产、工程、现有测试、文档；禁网络/模型/GPU/GUI/Git写/递归，仅读/只parse自己的文件，output/tmp独占。Lead运行分阶段宿主测试与仅自有进程的故障注入。

沿现有App宿主DTests的显式opt-in入口：D_NODE_LANGUAGE_REAL_CASE=process-recovery，D_NODE_RECOVERY_CASE=map|loop|human，D_NODE_RECOVERY_PHASE=produce|reopen，D_NODE_RECOVERY_NONCE=UUID。以nonce构造本App容器内固定项目路径，拒绝其他目录及已存在produce数据；独立确定性InferenceEngine只替代模型计算，复用真实ProjectStore、WorkbenchSession、WorkflowServices、Controller、standard registry。不要造第二调度器。计数engine将submit requestID/phase/input写自有ledger，reopen读同ledger；不是模型验收。

Map两稳定itemID：第一项N03完成已保存、第二项submit进入时挂起。Loop初始state Text0、N03 body确定性返回1/2，until==2；第二轮挂起。produce必须从Store回读验证第一项/轮output/ref/地址已完成，第二项/轮call已持久，再写ready.json包括nonce、case、pid、projectID、runID、受测身份及检查点摘要。之后有限等待，不优雅关闭；真正SIGKILL由Lead对本次xcodebuild创建且nonce/PID/产物身份均核对的专属host发出，并观察进程终止。Worker不能自行kill任何进程。不要靠退出码或手写checkpoint冒充崩溃。

reopen使用同nonce、新PID打开项目，确认旧running恢复为interrupted，已完成输出/媒体摘要/记录不变，ledger无自动新增，再显式resume。先前完成项不得重复submit，被中断项可重试一次；Map最终两个ID和位置、Loop最终state2/conditionMet。保留前后账本、两个PID与源快照；不可删除项目锁文件或回滚原项目。

human：N03 fixture→N15 editText→下游N03。produce等待waiting，编辑草稿后显式await save，回读decision=nil、draft/stepID/address/materials正确，再ready等待故障。reopen保持waiting/draft/无自动submit，按精确expectedTask显式决定；重复旧决定不能改结果/新增submit；decide本身不跑下游，必须resume后下游恰好一次。结束正常close所有自有任务/store/runtime，异常cleanup不能mask原错；ready前错误不得写PASS。各phase有受控时限。仅证明落盘检查点跨进程，不声称未保存内存无损或GUI通过。接口可参考 WorkflowLifecycleTests、WorkflowPlanTests、ProjectStore.open、WorkflowController.load/resume/decideHuman；有未知接口先问Lead，不能改生产过测。
