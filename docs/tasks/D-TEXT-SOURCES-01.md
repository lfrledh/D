# D-TEXT-SOURCES-01：文字资料问答基础

状态：规划就绪，实施未开始；plan revision 0.1，2026-09-14。本文件不是已经签发的 Worker IMPLEMENT 任务。归属 D-P08，遵循 PRODUCT_PRINCIPLES P2026-09-13.1；不替代 T0 已验收行为。

## 目标、起点和有限出口

用户选择本地 TXT/Markdown 中的资料和片段，提出问题，得到可以查看依据的回答候选；接受前不改正文，取消、来源变化和保存失败不破坏原件。保存的是此次实际使用的资料快照、问题、上下文和回答，而不是重开后从已改变文件重新拼出一份“历史”。

核查代码基线：源 codex/inference-foundation / b15be1175b80f265752f79eb45c6f3981ca13283。本计划所在文档提交不改变产品代码；最终源版本见 D-Development/AgentTrials/D-OFFLINE-PLAN-01/run-20260914T061406Z/final-receipt.json。实施前重新核实实际完整 SHA，再填写 batch/run、执行基线、contract revision 和逐文件授权；不从短 SHA 推算。

D-IMAGE-REFERENCE-01 的 14af48c22e9dbe7ee715b171308276347fab0f68 尚待 H18 GUI；它不是本任务已接纳基线，其 schema9 不可假定已可用。文字基础工作不依赖这项验收。锁屏期间先完成资料/上下文/候选记录的服务与离线验收；最小界面和完整用户保存闭环在可控制窗口时验收。分别记录组件、真实文字调用、装配和产品闭环，未验收界面不默认接管已有路径。

不包括：目录监视/全盘扫描、PDF/Office/OCR、向量库/embedding/重排、联网搜索、自动工具执行、完整聊天系统或写作平台、音乐模型、PNG 元数据、I2V。Markdown 按纯文本资料读取，不执行 HTML、代码、附件或外链。没有新增模型、依赖或外部服务预算。

## 已核实的复用基础与缺口

| 现有位置/符号 | 实际能力与本任务处理 |
| --- | --- |
| Sources/DInference/InferenceRequest.swift：TextRequest；Backends/MLX/Sources/DMLXBackend/MLXTextBackend.swift：execute | 已有文字请求、流式返回和实际 tokenizer/context 检查。继续复用；资料组织不进入 MLX 后端，不为“研读”新增一套推理内核。 |
| Packages/UI/Sources/DWorkbench/Text/TextDraft.swift：TextRewriteSelection、TextDraftDocument | 现有选区关联文档/修订/原文，UTF-16 范围必须落在 Swift Character 边界。正文与生成配置已保存，不等于保存了全部回答来源。 |
| 同目录 TextDraftSession.swift：requestRewrite | 当前操作是“指令＋选段→替换候选”，候选有失效和接受保护。复用状态/所有权思路；资料问答不能仅换提示词就宣称已有问答及来源归档。 |
| 同目录 ProjectTextController.swift、TextDraftArchive.swift | 现有模型接线、保存队列和文本归档可复用。候选及此次实际上下文仍需明确持久化。 |
| Packages/UI/Sources/DWorkbench/Project/ProjectStore.swift：saveTextDraft、记录任务的 .text 分支；ProjectModels.swift | 稳定源为 schema8；正文保存入口存在，通用作品任务记录拒绝 .text。Lead 必须解决问答记录的正式归属和兼容，不能直接套用图像作品记录。 |

## 派工前由 Lead 冻结的行为

下面是本阶段验收底线。具体 Swift 类型、序列化版本、数值上限和文件所有权由 Lead 在有限准备后冻结，仍不清楚时不发实现指令。

| 输入/状态 | 应有行为 | 必须拒绝或避免的反例 |
| --- | --- | --- |
| 显式选择文件/片段 | 严格解码约定的 UTF-8（含 BOM 策略），保留原字节及摘要；来源 ID、版本、片段坐标和展示名分开 | 同名文件混为同源；悄悄替换非法编码；自动读取 Markdown URI。符号链接及大小/数量边界沿用原件保护约束并明确测试。 |
| 中文、emoji、组合字符和 CRLF | 选择范围落在既定字符边界；显示定位与原始快照间有明确映射 | 用字节偏移冒充字符选区；规范化换行后仍沿用旧偏移；片段内容与坐标不一致。 |
| 资料送入模型 | 顺序与选择明确，冻结真实问题、资料快照、组装上下文及执行配置；资料只作为数据 | 将资料中的“忽略规则、访问地址”等文字当作应用/代理指令，执行代码或联网。 |
| 输入过长/输出预留不足 | 按实际 tokenizer 和模型配置检查，明确报告需缩减哪些内容；用户确认的缩减形成新快照 | 用字符数宣称 token 数；静默漏掉选中片段；把本机内存作为所有 Mac 的永久上限。 |
| 输出包含引用 | 来源 ID/版本/片段必须能对应此次实际输入，保留可查看的原文；缺失/错误引用明确标为未验证 | 只因格式像引用就判真；从未提供的来源补写依据。结构可验证不等于论断属实，不承诺自动证明答案正确。 |
| 生成期间修改资料/问题/目标文稿 | 异步结果绑定原快照；旧候选可查看但不能应用到变化后的目标，重新生成须新修订 | 把另一文档/新选区当旧目标；接受时才读取磁盘资料冒充当时依据。 |
| 接受/拒绝/取消/错误 | 原文接受前不变；接受是显式编辑，撤销有版本保护；取消等待既有运行时停止/释放 | 取消按钮先放行第二重任务；流中断当成功回答；拒绝/错误清掉已保存正文。 |
| 保存、冷重开、源文件移动/修改 | 归档恢复原快照、回答与实际配置；新文件状态另行显示。发布失败保留已有作品，错误明确 | 老版本读取后丢掉关键新字段；半写文件覆盖旧作品；通过绝对路径“恢复”变过的来源。 |

归档决策属于必要准备：在既有文本/项目结构内明确来源与回答记录的权威位置、版本门槛、原子写入和恢复；参考 TextDraftArchive 的边界，但不为了并行另造第二种项目体系。不向 schema8 添加会被旧版静默忽略的权威字段，不与尚未接纳的图像 schema9 抢占版本。需要共享格式演进时，Lead 在隔离集成区统一定兼容方案和测试，再允许接线。

资料字节数、选中片段数、单回答记录体积等是解析和存储保护预算；必须预先给出正常/上限/超限用例。模型上下文、输出额度及资源建议取自实际配置，不能用解析上限反向固定模型能力。普通记录不包含账号、密钥、书签或无需公开的绝对路径。

## 工作包与资源安排

这是顺序和职责提案，不是已建立的 Worker 会话。先准备一份共享值型契约和最小独立夹具，审核后通常可并行两包；没有就绪接口就保持串行，不以人数为目标。

| 包 | 职责与候选模型 | 依赖/独占边界 |
| --- | --- | --- |
| Lead 准备 | 确定记录归属、坐标/失效/错误语义、预算、序列化兼容及独立验收反例 | 共用接口、ProjectStore、ProjectTextController、工程注册由 Lead 单一协调；先核对源码，不提前实现全部局部函数。 |
| SOURCES | 显式资料快照、解码、片段定位和原件保护；Sol/high | 输入与路径安全较高风险。准备后指定 DWorkbench/Text 下实际新文件与直接测试，不能自由修改整个目录或存储中心。 |
| CONTEXT | 有界上下文组装、来源标识/引用核对、确定性记录编解码；Terra/medium | 只依赖冻结值型契约及内存夹具，避免依赖 SOURCES 尚未完成的实现。清楚列出伪引用/空值/错版本/Unicode 反例，模型调用不在此包。 |
| 接线与组合 | 已有 TextRequest/运行时调用、候选生命周期、正式保存和最小文字界面 | 前两包契约稳定后安排局部 Sol/high 或 Lead；共享存储/状态仍一名负责人。仅必要 UI，不新建用途专属工作台框架。 |

实际模型请求/运行设置、独立工作树/写根、唯一输出/缓存/临时目录及网络关闭均在各次派工核验。已用路由的历史证据不替代本次。允许文件逐项列出，默认禁止触及图像候选、其他任务、签名/权限、依赖及用户文件；Worker 不自行改共享验收标准。

沿用初交＋最多两轮针对性修复及一次有界 Lead 接管；每轮先核查异常和保护，再发返工。重要 Lead 实现由非实现者审阅。已有图像任务预算不受本计划影响。重构建/真实模型/GUI 由 Lead 排队，用户不在不等于机器需再次申请空闲；实际权限或隔离不足仍暂停对应动作。

## 验收和停止点

1. 局部 CPU：正常与损坏文本、同名不同内容、编码/坐标/换行/组合字符、源修改/丢失、预算边界、引用伪造/缺失、取消/过期/错误、拒绝覆盖与写入中断。测试目标绑定具体代码版本。
2. 集成：资料→冻结上下文→回答候选→显式接受/拒绝/受保护撤销→保存冷重开；从生产服务入口验证，不只测独立 JSON 往返。旧 T0 与旧项目保持兼容，并运行相关回归测试；新格式不静默丢字段。执行现有核心/工作台检查及必要独立构建，无下载更新。
3. 真实模型：使用已批准且完整校验的本机 Qwen 文字模型和小型合成资料，验证真正收到的上下文、取消/恢复及产物记录。固定模型/revision/实际参数/来源快照，保存答案和无资料依据时的反例。模型回答错误如实保留，不能把生命周期通过写成专业研读质量通过；不临时下载更大模型掩盖问题。
4. GUI：解锁后验证最小文字入口、来源查看、候选处理、保存重开及错误反馈；锁屏时记集中待办，不能用 mock 或编译关闭此项。人工内容质量评价与自动引用结构检查分开。

离机期间的明确出口是已审阅的服务/记录及离线证据；没有完整 GUI 验收时，产品状态保持“基础组件/装配已验，用户闭环待验”，未验收路径不默认启用。是否可先接纳不影响旧入口的增量，取决于冻结边界与组合回归，不能提前把整阶段写成完成。最终达到有限闭环后结束，不继续扩展高级文字功能。

## 后续位置与恢复

H18 参考图 GUI 与 H09 麦克风仍由集中清单管理，不因本任务重编号或关闭。用户回来时优先办理这些实际本人事项，再安排本任务新增的前台验收（如果届时已有待测产物）；现在不把尚未实现的文字 UI 当作现有锁屏故障。

下一独立音乐入口保留 HUM 短单声部文件→可编辑音符/普通试听：先核定候选、许可证、已授权素材和本机资源，新下载另列具体批准；不以麦克风或文字高级功能为前置。随后安排歌词/旋律控制的专门歌声里程碑，TTS 不替代演唱。I2V 需要独立模型支持，现有 Wan T2V 不能只新增参考字段冒充支持。此处只明确依赖出口，不启动这些任务。

本轮没有产品实现、修复或测试运行；Lead 使用两项只读核查确认可复用入口和替代方向，没有把模型自述算作实现路由验收。规划恢复时读 CURRENT_ACTIONS 和本文，再核实源 HEAD/索引/个人 scheme、图像候选、已知任务进程和实际权限；实施前补齐未冻结的类型/存储决策和精确工作包，不直接把此草案当运行手册。


## 2026-09-14 实施授权与冻结契约 TS1

用户已批准本阶段开始。本节覆盖上方“规划/未实施”状态；保留原计划作为历史。源77396f45fdd741c0f05f1d39cde95b23e353c4a0，Lead候选codex/d-text-sources-01；R=D-Development/AgentTrials/D-TEXT-SOURCES-01/run-20260914T063313Z。准确准备SHA见各Worker request，避免自引用。H18候选不改；用户离机，GUI留集中待办。

### 共享决策

- TextSourcesTypes.swift是Lead维护的最小值型契约。资料UTF-8原字节内嵌保存；可去BOM解码但不改原字节、不正规化Unicode/CRLF。范围沿用Character对齐UTF-16，排除空选区。明确选择文件/片段，不读取链接、URI、Markdown代码或外部指令。
- 每源1…512KiB、最多8源/32片段/16回答，问题16KiB、组装prompt512KiB、来源归档8MiB、项目原32MiB上限继续。超限明确拒绝，不静默删资料/历史；这些是存储/解析保护，不是模型token额度。实际token由既有后端核定，不在工作台用字符估计冒充。
- 资料与回答记录作为ProjectDocument.textSources与textDraft并列，正式仍一次原子提交project.json。T0正文/归档v2不改。项目文字版本10，明确接受1…8、10且拒绝未实现9；v8升级前保留原字节project.v8.backup.json。v10文字缺textSources/null是损坏，旧版才可迁移为空。未来图像9合并必须另协调新版本，不能悄悄扩充已经发出的10语义。
- 资料問答采用=向当前正文末尾添加回答（非选段替换），有非空原文时用两个换行分隔。请求冻结目标正文id/revision、来源/片段/问题、输入修订与实际TextRequest。任一输入/正文改变，旧回答仍可保存查看但不可采用；生成结果返回不能覆盖新问题。拒绝保持历史标记；撤销只针对本会话最近一次且正文仍是其采用修订，撤销和状态一次保存；重开保留历史，不承诺跨会话撤销栈。
- 引用语法[S1]…[Sn]按提交片段顺序；只声明与本次实际输入位置相符，不声明语义真实。无引用/未知引用均明确未验证；有无效引用禁止采用，可查看/拒绝。合法引用也不自动采用。模型温度0.2/topP0.95，输出和输入token额度沿正文的实际配置。模型身份保存profile ID+精确revision，不保存本机绝对路径。metrics白名单：promptTokens/generationTokens/promptSeconds/generationSeconds/stopReason/upstreamStopReason/modelRevision/randomSeed/weightBytes/estimatedPeakBytes/executionProfileIdentifier/executionProfileRevision/maximumPromptTokens/maximumOutputTokens；最多各512 UTF8字节，其他provider字段不进入一般记录。
- 生产归档encode与decode必须调用完整验证：所有当前和历史来源摘要/UTF8/名称、片段坐标和原文、ID唯一、数量/大小、请求prompt须重建逐字节一致；请求参数有限且合法，modelID不为路径/URL，历史targetDocumentID与所属文字文档一致（Store校验）。严格整数schema1；布尔/浮点不能冒充版本，未知版本/null/漏必需字段拒绝，JSON嵌套深度32预算。JSONDecoder合成decode本身不代表验证通过。

### 首组Worker冻结授权

所有任务读本节、AGENTS安全/资源规则、TextSourcesTypes.swift，以及各自列出的必要参照；不要重读所有历史。初交+最多两轮定点修复；遇权限异常先停报，只有预先声明的唯一输出/缓存入口可恢复一次。公共类型/本文/Store/Session/工程/依赖/源和图像候选均禁写，不递归，不commit。每次受限CLI的cwd、model/effort、写根、实际运行设置由Lead核验再发IMPLEMENT。

SOURCES（D-TS-SOURCES-01 spec1 TS1，Sol/high）：仅可新增Packages/UI/Sources/DWorkbench/Text/TextSourceReader.swift、Packages/UI/Tests/DWorkbenchTests/TextSourceReaderTests.swift。公开API `TextSourceReader.read(at: URL) throws -> TextSourceSnapshot`，`TextSourceReader.excerpt(from: TextSourceSnapshot, range: NSRange? = nil) throws -> TextSourceExcerpt`（nil=全篇）。read仅明确绝对本地txt/md/markdown扩展，大小写不敏感；拒绝URL query/fragment、软链（含父路径）、目录/FIFO/设备、非法UTF8、空/超限；逐级文件描述符O_NOFOLLOW/O_CLOEXEC只读，不扫描父目录、不写原件、不取得系统权限；读前后文件身份/大小/修改时间变化明确失败，封闭自有FD。现有只读文件安全写法可参考ProjectStore.swift私有ProjectFiles，不修改它。测试真实临时文件、Unicode/空格路径/BOM/CRLF、损坏编码/边界/链/特殊文件、源未变和重复读取身份；不更改真实文件权限。Snapshot及Excerpt验证已由共享值提供，仍须调用，不复制弱实现。

CONTEXT（D-TS-CONTEXT-01 spec1 TS1，Terra/medium）：仅可新增Packages/UI/Sources/DWorkbench/Text/TextSourcesContext.swift、TextSourcesArchive.swift，以及Packages/UI/Tests/DWorkbenchTests/TextSourcesContextTests.swift（后二路径分别沿前述Sources/Text与Tests目录）。公开API：`TextSourcesContext.makeSubmission(notebook: TextSourcesNotebook, target: TextDraftDocument, modelID: String, modelRevision: String?) throws -> TextSourcesSubmission`；`TextSourcesContext.citations(in: String, submission: TextSourcesSubmission) -> TextCitationAssessment`（公开value含validLabels:[String]、invalidLabels:[String]、summary:String，未引用必须summary明确未验证）；`TextSourcesArchive.validate(_ notebook: TextSourcesNotebook) throws`、`encode(_:) throws -> Data`、`decode(_:) throws -> TextSourcesNotebook`。独立纯值/标准库实现，不依赖Reader、不运行模型。prompt依输入顺序有清晰指令/资料数据边界并要求[S序号]，问题/片段按原字节拼入，绝不静默截断。无源/片段/问题不能submit；空notebook可以归档。归档采用schema_version1有界envelope而非另建项目格式。上节验证底线全部覆盖，反例至少含假引用、无引用、同名异源/错revision/摘要/片段、Unicode和prompt篡改、错版本类型/漏字段、数量/字节限制、不规范化输入。来源解析后的码点位置用共享Excerpt.validate；不要创建shell/URI/文件读取或第三方依赖。

局部检查：Worker允许已有swiftc对自己代码/测试作typecheck，模块缓存只能自有tmp；需要导入DInference可只读R/Build-UI/arm64-apple-macosx/debug/Modules。用相同模块编译时包含共享TextSourcesTypes/TextDraft/TextGenerationSettings及自己的文件。可在自有output生成enable-testing模块再typecheck Testing测试；不运行SwiftPM内层沙箱/完整构建/GPU/GUI。行为测试由Lead在交回之后用现有swift test生产入口执行，Worker回传必须准确标注typecheck不等于测试执行。无字节码检查只用内存compile；禁止默认py_compile和安装下载。

Lead接线/组合待首组交回后按TS1推进，共享存储、迁移、控制器与最小UI单一协调。所有输出独立R/<worker>/output、tmp，不写共享Git。需要变更公共契约先停报；Lead提供明确修订，旧迟到结果不自动集成。阶段完整GUI不可运行时保存候选及明确入口、不开默认产品开关、不合并未经完整门槛的新路径。

TS1派工前澄清：Notebook.revision表示每次持久状态变更，inputRevision只在问题/来源/片段变化时更新；Submission.notebookRevision冻结inputRevision。追加结果/采用/拒绝不改变inputRevision，不能让候选因自身完成而过期。源正文修订另检。持久冲突/无变化比较使用问题/prompt/回答UTF8字节，不能只凭String的规范等价。共享类型非实现者审核发现ZWJ文件名和哈希前预算两项，Lead在派工前修补；不占Worker修复轮。


### TS1-VIEW1：独立只读资料/回答界面（2026-09-14，Lead签发）

D-TS-VIEW-01 spec1 TS1-VIEW1，Terra/medium。此任务与Reader/Context实现独立，只依赖已冻结TextSourcesTypes值。只允许新增Packages/UI/Sources/UI/Views/TextSourcesView.swift和Packages/UI/Tests/UITests/TextSourcesViewTests.swift。不修改WorkbenchView/Model、ProjectSession/Store、公共类型、本文、其他任务、签名/工程/依赖。Lead负责最后装配和权限入口。本文件这份额外任务节由Lead单一维护。

提供public @MainActor TextSourcesView及TextSourcesViewActions。init参数：notebook:TextSourcesNotebook, partialAnswer:String, isRunning:Bool, isCancelling:Bool, isSaving:Bool, canAsk:Bool, canUndo:Bool, errorMessage:String?, canAccept:@escaping (TextSourceAnswerRecord)->Bool, citationSummary:@escaping (TextSourceAnswerRecord)->String, actions:TextSourcesViewActions。Actions public init与let closures：importSource:()->Void, removeSource:(UUID)->Void, useExcerpt:(UUID,NSRange?)->Void, changeQuestion:(String)->Void, ask:()->Void, cancel:()->Void, accept:(UUID)->Void, reject:(UUID)->Void, undo:()->Void, save:()->Void。nil范围表示全文，选择片段必须Character对齐UTF16，回调身份对应被展示Source。业务检查/文件面板/模型/保存由caller负责，UI不读文件、不调用后端。

最小面板用于现有文字模态的资料问答工作方式，不增加顶层页面。显示资料列表/原始来源摘要、只读可选中文本（可在此新文件用NSViewRepresentable NSTextView isEditable=false，不改现有编辑器）、“使用全文/使用选中片段/移除资料”，问题输入、生成/取消/保存/撤销，回答候选/采用/拒绝及提交时来源片段。原件只读，历史回答只读；引用summary必须显式显示，不将结构核对说成事实验证。采用按钮必须同时尊重caller.canAccept和未运行/保存；没有来源/问题则callercanAsk=false。不自动触发import/generate/adopt，不将资料/回答Markdown当可执行富内容或打开链接。

沿用原生macOS26玻璃按钮/系统工具栏，内容区清楚可读。窄宽用可换行/纵向和滚动布局，不使用导致裁切的固定总最小宽度，不替换IME问题输入控件来切布局。不要把API/内存预算/UTF16数值放用户主界面。选区在切换资料或版本时失效；禁止一份资料的旧选区触发另一份的操作。可定义同文件纯选择状态帮助器并对中文、组合emoji、旧id/revision及越界写真实行为测试；不写仅匹配文案/实现行数的测试。

仅已有swiftc typecheck、own output/tmp，DInference/DWorkbench模块只读R/Build-UI/arm64-apple-macosx/debug/Modules；SwiftUI/AppKit工具链已有。No SwiftPM/GPU/GUI启动/模型/网络/下载/配置/递归/commit。未知权限或缺失工具先停报；用绝对rg /Applications/ChatGPT.app/Contents/Resources/rg，显式Git /Applications/Xcode.app/Contents/Developer/usr/bin/git。初交+2修复预算，typecheck不是行为/GUI验收；Lead后续运行生产组合测试。原界面接线与真实GUI仍未启用，不能把这个局部View写成产品完成。


## 2026-09-14 离线候选收尾／H19待验（非整阶段完成）

当前状态：**服务/CPU、离屏装配、真实CLI与普通隔离构建已验；真实工作台用户闭环、引用格式可靠性未验收。候选不默认启用，未合入源产品代码，未推送。** 用户离机期间不再探测锁屏/麦克风，不请求重复空闲授权。本任务不因锁屏重新编号，也不继续下一产品阶段。

### 版本、产物与证据

- R=`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-TEXT-SOURCES-01/run-20260914T063313Z`，所有原失败/修复/成功证据保留，不覆盖。最终恢复索引R/final-receipt.json；原任务允许范围延续TS1/TS1-VIEW1。
- 源起点77396f45fdd741c0f05f1d39cde95b23e353c4a0；源本轮只有三份状态/目标/集中待办文档提交2486d71e48dd02fe06f2dca160e62fde9d878471。源不含本批产品实现、schema10或新默认入口。该已批准文档快照在候选中保留历史合入，未来恢复不用旧源SHA覆盖新状态。
- 本轮组合最终受测/普通App构建388a227cef10801ce2077889c1a81aecd68d6548。其后只变四份Markdown（本文及三份源状态文档），代码/测试/夹具/工程入口一致；最终候选完整SHA写外部回执，未在文档提交上重跑测试，不为自引用amend。
- CLI构建595cc561da2b19a9bc414021caff9aed7d5b6980，二进制SHA256 278124e95181dbf66cff8adc9098a854a917d24c22b6c40f10c432dd96a0942f；到最终受测版CLI/后端/核心/Vendor没有差异。资料上下文准备0.5B用fa213a6d1833fb201a060e998350708c944a0ce3，1.5B用eb67932a5bec5314149386b503c7572cd8468e0f；相应资料处理/存储之后未变，后续仅界面装配及测试修正。真实答案归档0.5B实际bf5248df404fce07040a13e1574c40ff760f5631，1.5B为最终受测388a227。
- 普通隔离产物R/`D Text Sources Workbench.app`，构建沿既有签名配置；完整性验证、读取sandbox=true通过，不触及钥匙串/签名设置、不启动App。此文字测试包未封装新音频/视频引擎，不等于整个多模态分发包。R/app-artifact.json含四关键文件摘要、大小、mtime及签名只读命令。

### 实际实现及边界

Reader通过显式路径/只读文件描述符读取已选UTF-8 TXT/Markdown，拒绝软链/特殊文件/损坏编码/超限/读中变化，保留原字节、名称/ID/修订/摘要及Character对齐UTF16片段。Context生成确定性上下文，不截断、不解析执行Markdown或URI；Archive在编解码时对当前与历史快照、prompt、ID/范围/预算/版本做同一完整验证。

ProjectTextSourcesController复用已有InferenceEngine：提交前冻结输入/目标修订，生成只写候选；取消等待运行时结束，保存失败保留完整未发布回答，不拿截断流当成功。采用=显式追加正文；输入/文档已变或引用缺失/无效不能采用。采用/撤销的正文和状态通过ProjectStore一次发布；保存期间晚到编辑不会被覆盖，未保存大回答保留完整submission/answer/metrics且可清理当前未用资料后重试。单会话撤销有修订保护，不宣称跨会话撤销栈。

ProjectSession集中协调模型lease、输入校验前后的版本、正文flush、资料保存/关闭和项目移动后的runtime重绑。模型profile ID用不含路径的opaque身份及固定revision记录，执行metrics只取TS1白名单，历史不暴露模型绝对路径/书签。新schema10迁移1…8且备份原清单，拒绝候选图像schema9及损坏/漏字段；未来图像+文字组合需统一新版本，不能把两个分支直接视为已兼容产品。

资料问答是文字模态中的工作方式。来源/问题/候选在画布，右侧复用同一模型与输入/输出额度；不复制整套问答到参数栏。问题输入框在宽窄切换时保持原生控件身份，来源选区绑定来源ID/修订；历史引用按提交片段序显示当时名称/修订/摘要。D_ENABLE_TEXT_SOURCES默认非1，现有选段改写入口保持默认。只读NSHostingView布局不是GUI操作或真人IME验收。

### 验收矩阵（每条结果绑定自己版本，不相加成一次总通过）

| 检查 | 实际结果与边界 | R下证据 |
| --- | --- | --- |
| 生产工作台SwiftPM完整回归 | 最终388a227：406方法/57套件报告零失败；3个opt-in方法在这一整次跳过，随后/此前独立启用并留版本，不能称同次零跳过 | full-ui-combined-acceptance/{request,result}.json、stdout.log；acceptance-summary.json |
| 核心DInference/DRuntime | 同版62方法/10套件通过，无模型；后端未改，未机械重跑图像/音频/视频 | core-regression |
| 来源/归档/生产流程反例 | Unicode/CRLF/BOM/非法编码/软链；当前与历史预算和类型；伪/缺引用、过期、取消竞态、原稿保护、写失败/保存重开/移盘runtime等在完整套件覆盖 | TextSourceReaderTests、TextSourcesLeadContractTests、TextSourcesStoreTests、TextSourcesFlowTests；早期失败保留 |
| 渲染组件 | 原生问题输入身份、窄宽可滚动、完整Workbench唯一问答控件、旧改写独立、两模式参数可达；未启动前台 | sources-render-check原失败；sources-render-lead-finish、sources-shell-cooperative及最终套件 |
| 固定权重/真实上下文 | 0.5B/1.5B完整profile.verify；各2问题使用真正Context.makeSubmission。总套件跳过的既有0.5B权重未变检查另1项通过 | real-preparation*实际目录见receipt；fixed-text-protection；real-text*/source、submission、prompt |
| 真实CLI | 0.5B有依据问答、缺依据、取消、token超限、恢复5场景；1.5B两问2场景。实际退出0/130/1与各自预期一致，drained→released，末次active/cache均0 | real-lifecycle-summary.json；real-text与real-text-1p5各cli-report.json，非全库基准 |
| 真实回答保存冷重开 | 两个模型各2份实际回答经生产ProjectStore归档/重开，原始CLI request.ID、精确prompt/参数/revision/实际metrics关联；这是真实CLI结果导入，非工作台直接真实调用 | real-answer-persistence2（bf5248）、real-answer-persistence-1p5（388a227）；TextSourcesRealEvidenceTests |
| 同runtime重任务交接 | 真实首chunk取消，drain/release后下一排队任务才load，1项通过零跳过；资源正常释放 | mlx-queue-build、mlx-queue-enumerate、mlx-test-list.json、text-queue.xctestrun、mlx-queue-real、mlx-queue.summary.json/xcresult |
| 普通App构建 | 最终388a227既有签名Debug独立构建成功，副本签名完整性和sandbox声明通过 | app-assembly-final、app-artifact.json；不是GUI/TCC/Gatekeeper/公证验收 |
| 真实GUI/可采用回答/专业质量 | **未通过/未执行**：H19等待前台，真实模型引用缺口另列下文；不以CPU采用夹具或导入CLI结果替代 | gui-acceptance-plan.json；源集中清单H19 |

真实模型固定revision：Qwen2.5-0.5B-Instruct-4bit a5339a4131f135d0fdc6a5c8b5bbed2753bbe0f3；Qwen2.5-1.5B-Instruct-4bit 8b403126fc14f14cfc99bb4cfa72ecbc129ea677。问答用实际2048/128 token、temperature0.2、topP0.95、seed42；这是小样例配置，不是产品永久上限。0.5B正常约1.2—2.4s、峰值约0.39GiB，1.5B约1.1—1.2s、峰值约1.0GiB；CLI加载到完成，不等于GUI首字体验或大模型容量结论。

**质量事实**：有依据时两模型能答出蓝桉/京都，但没有规定的[S1]；缺预算时0.5B编造100000000日元，1.5B说明资料未提供。回答/失败原样保留，不后补引用、改seed筛掉失败或称语义已自动验证。当前真实样例因此不可采用；后续需以版本化提示/样例验证解决引用服从问题，不能把“需要解锁”当作唯一缺口，也不通过放宽采用条件越过TS1。新模型下载另行授权，本轮未下载/安装。

### 协作来源、失败与有限接管

| 工作包 | 请求/可观察运行设置及候选 | 过程 |
| --- | --- | --- |
| D-TS-SOURCES-01 | gpt-5.6-sol/high；8e955a97fe0662cc831c4d8467b02ac7c3faa537 | 初交通过；预检针对ZWJ名称询问，Lead按既定字符语义澄清后实施；没有伪造第一轮已跑行为测试 |
| D-TS-CONTEXT-01 | gpt-5.6-terra/medium；69f429e60cfa09419a4bb6b98a0b1809e4b5a644 | 初交+2修复；先修历史预算/metrics/引用信任，再补历史数量/空问题。repair1因日志文件名与绝对测试路径澄清暂停/续行一次，同一额度；预检rg不在PATH后按已安装实体重试。未提权 |
| D-TS-VIEW-01 | gpt-5.6-terra/medium；916e7bdc5dad524ab26988108e1464d86a7025c0 | 初交+2修复处理权威问题状态、来源选择/历史引用及布局；Lead在eb67932a5bec5314149386b503c7572cd8468e0f有界接管，修宽窄切换替换原生输入框，原反例先4断言失败后通过；不归为Terra独立通过 |

每Worker独立外盘分支/工作树，workspace-write限定任务+唯一output/tmp，network=false，Git共享管理目录不授权写入；Worker交回后Lead显式提交/串行合并。三个实施包中观察到最高两个同时实施，非三包全程并发。请求与运行turn_context的cwd/model/effort/沙箱核对见R/{sources,context,view}/final-runtime-evidence.json；运行线程、每轮开始/结束/异常/usage见原记录。隐藏服务端解析unknown，不拿模型自述作证。

Lead亲自写共享契约、Store/Controller/Session接线、独立反例和最后装配，非实现者video_contract_review与video_deployment_plan只读检查这些改变，不声称其执行测试或GUI。修正了输入revision与状态revision混用、晚保存覆盖新正文、未保存完整回答丢失、cancel等待者串入下一任务、移盘runtime及宿主首次await前快照。初次类型/测试准备编译错误、真实CLI startedAt误当数值导致解析失败均有原证据，修的是Lead测试/接线，不计入Worker实现成功。

最后装配b673fea修正画布/参数栏重复问答，不属于对VIEW第三轮派工。新布局测试同步RunLoop占用MainActor与已有自动滚动测试产生时序干扰：组合首次两case失败，同一生产代码单测通过；9e15477将新测试等待改为协作式Task.sleep后组合及最终完整回归通过，所有几何/身份断言保留；未证明SwiftUI内部唯一成因。旧ProjectSession模型移除测试遇rebind.verifying中间状态，388a227改等待最终同一“移除”后置条件，原10s超时/lease/数据断言不变；非实现者确认不是放宽标准。R/nonimplementer-reviews.json记录审核边界。

原始每轮usage保存，不把resume累计快照简单相加；没有重算旧批费用。配置/模型路由可观察、隐藏解析/订阅实际费用/完整Lead归因unknown。一次样本只证明可协作交付候选，不证明成本最优。来源标签不改人类Git署名，也不把Lead接管写回Terra独立验收。

### 可复用经验与恢复检查点

同时读取文字画布与参数栏的组合视图不能只靠局部View测试：检查实际控件实例数量，确保同一个编辑操作只有一个权威输入入口。异步测试应等待它最终断言的同一状态，不能用较早的“不能生成”状态代替“删除已观察到”；布局等待不能阻塞其他MainActor任务。正常实现与测试事件分开记录，不全部归为权限问题。

已完成：三个局部包、共享保存/生命周期、组合回归、两个已装模型真实CLI及结果持久化、真实取消交接、普通隔离构建、非实现者审核。未完成：真实工作台到模型操作、真实可采用引用回答、GUI/IME/保存失败前台验证；不存在自动在后台继续跑下一批的承诺。

源2486d71e48dd02fe06f2dca160e62fde9d878471只含新文档；候选位置/最终SHA见回执。源个人scheme ca3635d88aa5a15397b90e528667c66c0e6db7e596176e885c79d194b544206c、索引blob9c76916bdc97c2d4298cefe64e0b0fae3380573e与未暂存orderHint1→6保持；普通D四关键文件、原作品/模型、图像候选14af48c22e9dbe7ee715b171308276347fab0f68保持。本批自有Worker/CPU/构建/模型进程均已结束；没有启动GUI，因此也没有关闭普通D或让工具自动重启它。最后具体保护摘要及代码一致性见R/protection/end.json与final-receipt.json，不声称建立系统写锁。

下一动作：用户回来按集中清单处理H18/H19，H09只提醒设备；先核Git/进程/实际签名产物/隔离UUID及此契约，读R/gui-acceptance-plan.json后执行。引用服从问题按明确剩余质量范围处理，不以未证明的样例默认开放，也不再次派预算耗尽Worker。通过完整门槛后才在隔离区协调图像/文字版本、源复验及按当时授权接纳/推送。HUM文件识别与专门歌声保持独立后续，不以高级文字完工为前置。

## 2026-09-14 CLOSE1：有限引用质量、归档兼容与解码缺陷收尾（执行中）

用户批准扩大同一闭环内的内容。源2486d71e48dd02fe06f2dca160e62fde9d878471、本候选864ffd99a6c3f8061d97d15fda444f8c19200182、图像14af48c22e9dbe7ee715b171308276347fab0f68均核对，R=`D-Development/AgentTrials/D-TEXT-SOURCES-01/run-20260914T085345Z-close`。本轮HUM只有薄后端选型/契约规划；GUI仍H18/H19，用户未回来，不重复探测。

固定EVAL2的8类×2次1.5B＋2次0.5B诊断已完成：1.5B仅3类内容/引用归属满足，标签存在不等于语义正确。另用原获准且全清单校验的7B完成同模板8类×2次容量对照（CAPACITY2），7类内容满足，Unicode仍失败；不可据小模型封顶产品。精确prompt、原答案、实际随机seed、退出/释放与失败均在R，未重调提示或删除失败。更正历史口径：文字不接受CLI --seed；实际每任务随机状态在metadata.randomSeed，options默认42并非实际文字seed。首次--seed参数拒绝、7B8GiB估计拒绝与12GiB合理预算恢复分别保留，未改变精度/系统权限。

### CLOSE1-L：Lead一次有界收尾范围和门槛

已完成只读审核并以固定依赖2.30.6的原样NaiveStreamingDetokenizer在CPU复现：e→e+组合音符与👩→👩‍💻被Character计数差分丢字（R/upstream-proof-run，两例失败）。没有原生成token时不把这次模型输出错误全部归因于该缺陷。优先复用既有generateTokenTask（与generateTask共用generateLoopTask、TokenIterator和任务句柄），局部用严格UTF8前缀差分解码；不复制整套模型库、不修改SwiftPM checkout，不另造推理器。保留当前工具调用检测、生成终态/取消/drain/release，前缀回写明确失败；完整结束交付tokenizer实际最后解码结果，临时U+FFFD等待，不以Character边界吞掉组合标量。完整token缓存受实际请求输出额度约束；较长输出性能另测，不缩小已有上限。

允许Lead修改：Backends/MLX/Sources/DMLXBackend/MLXTextBackend.swift；新增同目录IncrementalTextDecoder.swift及Backends/MLX/Tests/DMLXBackendTests/IncrementalTextDecoderTests.swift；为实际固定tokenizer/生命周期验证只追加对应MLX测试；TS1的TextSourcesTypes/Context/Archive、直接TextSources测试和必要小fixture；本文、CURRENT_ACTIONS/PRODUCT_GOALS/FAILURE_AND_PERMISSION_AUDIT/MUSIC_ROADMAP。若提示升级，必须逐submission保存模板版本，缺字段仅v1、null/未知/错类型拒绝，v1原字节重建保留；新v2只使用已冻结CAPACITY2模板，保持资料原文/标签按excerpts顺序，不修改采用规则。schema10/归档1尚未接纳，旧读者拒绝新prompt而不能静默丢历史，需实证；图文组合11只规划，未验收前不合并。

本轮由Lead亲自修补与运行，非实现者只读复核，不重新派实施Worker，也不把它写成Terra独立成功。CONTEXT此前初交+两次修复不清零，本段使用一次有界Lead收尾；不追加无限提示/模型试错。先固定CPU反例与旧归档，修补后检查组合Unicode/tokenizer与实际CLI、旧文本取消/恢复/终态、归档迁移及普通App编译；若完整范围无法通过，保留停点。新依赖/权重/权限、签名改变、其他模态模型或GUI不在此收尾执行中。原产物、源个人文件、旧证据保护不变。

CLOSE1测试澄清：首轮新路径23方法中22过/1失败，失败是新增tokenizer往返测试误要求声明NFC的模型保留输入分解音符字节；流拼接与整段decode检查本身通过。Lead核固定0.5/1.5/7B tokenizer.json的NFC声明，非实现者candidate_compatibility_scope同意将该新测试首例预期明确为预组合Café，并保留字节比较、分解标量/ZWJ/前缀回写的所有独立反例；没有修改原TS1保存/引用/接受或既有测试标准。原失败日志保留为失败，不回写通过。源码/提示保存仍原字节，模型normalizer不得写回原文。

### CLOSE1-L 结果与停止点（2026-09-14）

状态：**质量/解码/历史兼容候选已完成有限验证；完整默认调度仍有两项问题，H19未执行，因此不接纳产品代码、不推送。** 不再追加CONTEXT/VIEW实现轮，也不将有界Lead收尾重记为Terra独立通过。源仅接纳四份规划/状态文档到3ae61f252621f0629f89d8546474f818bf565867；候选保留这个源快照的合并历史，最终候选自身SHA写R/final-receipt.json。

#### 原因、修补与精度边界

固定mlx-swift-lm 2.30.6（7e19e09027923d89ac47dd087d9627f610e5a91a）的NaiveStreamingDetokenizer用String字符数量截增量，码点追加进已有组合字符时被漏掉。直接抽取旧类型的CPU反例实际失败：分解重音和👩‍💻分别丢码点；证据R/upstream-detokenizer-proof、upstream-proof-run。本地薄适配改用同一SDK公开generateTokenTask和全前缀decode，按UTF-8前缀提交完整新增标量，等待未完成FFFD尾，不能解释的前缀回写明确失败；保留ToolCallProcessor、原生成任务取消/drain、终态和资源清理。没有改SwiftPM检出、固定依赖、模型权重、精度或产品长度上限。backend版本0.1.2。

解码器不正规化保存内容。固定Qwen tokenizer自身声明NFC，相关模型编码/解码预期与原文件字节保存分别验。完整前缀每token重解码会增加长输出CPU成本；当前短回归不证明8192长输出性能。SDK generationSeconds现不包含下游解码/工具处理，旧/新该值不能直接当端到端吞吐比较；CLI墙钟仍记录全链。既有ToolCallProcessor对未闭合工具标记的缓冲行为未改，本次没有把它宣传为所有可能文本的全字节交付认证。

sources.v2只采用先于实现冻结的EVAL2模板；按excerpts顺序标记和列出可用来源，不后处理或补造引用。每份submission保存模板身份，新v2明确编码；缺字段仅legacyv1，null/未知/错类型拒绝。v1沿用原prompt并省略新增字段，避免原来接近8MiB的合法历史因版本字段膨胀而超限。Archive1/项目10仍是未接纳候选；旧读者不能读新v2，但会明确拒绝而非丢新字段后保存。未来图像schema9与文字10只有各自产品门槛通过后才用新11组合，本轮没有合并它们。

#### 版本与实际证据

| 检查 | 版本/实际结果 | R下证据 |
| --- | --- | --- |
| 固定模板原型/容量评估 | 原CLI595cc561…；1.5B八类各两次，五类内容/来源失败；0.5B两诊断保留；7B同样八类各两次，旧解码Unicode未全，七类满足 | evaluation-r2-plan/summary、capacity-r2-plan/summary及逐次原报告；旧结果不重写 |
| 修补后真实7B | CLI构建96547971db6383ac7f0f02f05fc844bcfb30dd91；16次正常结束，八类内容/来源预期各两次满足，Unicode标题完整；MLX最终active/cache均0；峰值约4.31–4.37GiB，非整机峰值 | postdecoder-plan.json、postdecoder-summary.json、postdecoder-results；全部原答案由Lead与只读非实现者核对 |
| 字符/终态/真实0.5B生命周期 | 8dcde88df5c7f1a822740537a8f28b978433efd5：23方法/4套件通过；包含真实tokenizer、工具边界、取消交接、重复加载释放、加载失败和接收方抛错后清理 | mlx-decoder-final、text-decoder-final.xcresult、text-decoder-summary.json；保留原22通过/1错误新预期的失败轮 |
| 新版资料/历史定点 | f1e43f9f39ec44e855ef45fad96ccb7818317f45定点通过；此前复制SwiftPM模块缓存绝对路径不匹配在编译前失败，改独立新scratch，未清理旧证据 | ui-version-tests（失败）、ui-version-fresh（通过） |
| 完整工作台默认调度 | ec5ef2fe7a7be4f337a349f8918c1bd5d1a3432f：414方法/58套件，两项失败，三opt-in跳过 | ui-full-final，原日志保留 |
| 同码显式串行完整工作台 | ec5ef2f：414方法/58套件零失败，三opt-in跳过；日志核对方法及布局参数确实依次运行。不能称默认并发通过或两缺陷已修 | ui-full-serial；只读review核调度而非只凭help默认值 |
| 生产prompt与保存 | ec5ef2f：八固定prompt摘要全部对应评估前模板；16真实CLI的TextRequest/提示字节与生产提交一致，原答案/真实seed指标与旧v1回答经ProjectStore保存冷重开；原稿不变 | actual-answer-persistence、production-persistence；这是CLI结果绑定/导入，不是GUI生成 |
| 实际旧新读者 | OLD/Build-UI的388a227构建对象写8MiB合法旧归档，当前读者仍读/编；旧读者拒绝v2和混合archive/project，输入清单字节不变 | old-boundary-write、old-boundary.json、old-reader-compatibility；compile-probe的源/对象摘要留档 |
| 普通隔离App | ec5ef2f构建/签名完整性通过，与前候选entitlements相同；R/D Text Sources CLOSE1.app未启动，无新音视频引擎封装声明 | app-assembly-final、app-artifact.json |

代码路径：MLX改动b02e521e3a6376e4a365870adcc10376f0a81baa；MLX最终测试8dcde88；CLI实际9654797，SHA256 a7bcffe40909b4714f29a5d6bc0ee472e3d918301e31a3010d11a9f65479899c；生产prompt/完整工作台/App受测ec5ef2f。后续至最终候选仅四份来源文档合并及本文追加，不再宣称新文档SHA重跑全部测试。完整SHA/文件对应在R/close-acceptance-summary.json和final-receipt.json。

7B是已批准便携测试包现有固定revision c26a38f6a37d0a51b4e9a1eb3026530fa35d9fed，未新增下载或安装。一次8GiB任务预算低于9.422GB估计在加载前拒绝，依据既有显式预算机制改12GiB后串行验证，未改精度/输入输出额度，M4/16GiB不是产品上限。文字实际randomSeed取result.metadata；旧CLI options.seed默认42不是文字实际seed（显式--seed被文本CLI拒绝）。没有以选seed排除失败样本。

**质量不是自动保证**：7B八类短合成样例内容/来源预期满足；冲突回答最后“无法确定”总结句未逐句带标签，标点位置也不完全照示例，不宣称严格逐句格式100%。0.5B幻觉、1.5B串引用/信息缺失原样保留；专业研读、复杂长资料、广泛注入防御、全部Unicode/模型/Mac未由这些样例验收。引用结构校验和采用门槛未放宽，仍提示语义未验证。

#### 默认完整回归的剩余风险（不是缺用户授权）

1. AlignmentPersistenceTests.schemaSixBacksUpRawBytesAndDefaultsOnlyMissingFields在故意中断迁移后立即重开报“此项目已被另一窗口或应用实例打开”。现有ProjectStore.open的transfer=false失败路径只close锁FD，正常close/deinit已有显式LOCK_UN以防子进程pre-exec副本延长锁；日志紧邻另一个posix_spawn测试，符合竞争假说，但没有故障瞬间FD/errno证据，不能把具体因果写成已实测。相关代码/fixture不在本次diff。
2. ExecutionSettingsViewTests问答参数模式首次测量底部237超过180视口。原实现一次yield后scroll，测试固定0.3秒；并发MainActor异步测试可能交错。后续缩放及同码串行通过，支持首次布局时序问题，未证明根因或修补。没有放宽等待、删断言或将串行结果回填首轮。

本轮有界范围不扩为ProjectStore/布局重写，不再重复跑绿色样例掩盖失败。下一有限收口需针对失败锁所有权/首次滚动分别做确定反例、最小修补、非实现者审核与默认组合回归；通过后再恢复H19普通沙盒。H18可独立按已有图像候选验收，不被这两个文字问题冻结。用户回来集中只需解锁办理实际前台/新系统提示及确认H09设备是否已到；不要让用户为工程问题扩大权限。

#### 来源、消耗与恢复

本轮Lead实施及验证，candidate_compatibility_scope、hum_backend_readiness只读核代码/样例/HUM方案；没有新的实施Worker、独立运行的评审模型测试或旧预算重置。审核发现旧编码容量膨胀已由Lead收口并以实际旧writer验证；保留原初实现/修复/接管链。新测试错误预期、缓存路径、命令参数/选项和一次只读证据字段误读均见R/operational-events.json，不能混算为Worker实现缺陷。各运行墙钟/实际seed/工具摘要可观察；完整Lead token、模型隐藏解析与订阅实际扣费unknown，不重算历史费用或据此认定成本最优。

恢复检查点：源仅文档3ae61f2、候选代码ec5ef2f及后续仅文档完整SHA见R/final-receipt；H18仍14af48c22e9dbe7ee715b171308276347fab0f68。源scheme摘要ca3635d88aa5a15397b90e528667c66c0e6db7e596176e885c79d194b544206c、索引blob9c76916bdc97c2d4298cefe64e0b0fae3380573e/未暂存保持；普通D四关键文件/已批准7B及旧证据保护在R/protection。所有自有测试/构建进程结束，未启动任何GUI或关闭用户应用；恢复仍须核实际状态。

HUM准备已写入源MUSIC_ROADMAP：短单声部文件→连续音高/自由时间音符候选→保存冷重开/导出；SwiftF0优先评估、Basic Pitch备用，具体固定revision/权重/依赖与许可核定及单独授权后才实施。H09不是文件识别的前置，专门歌声独立紧接，不以文字高级功能全部完成为条件。本轮没有新增识别模型、音符编辑器或组合平台。
