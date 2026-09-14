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
