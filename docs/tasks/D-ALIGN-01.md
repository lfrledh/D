# D-ALIGN-01：能力声明与既有工作台对接

- 状态：**2026-09-14有限阶段候选验收通过：组件、普通沙盒图文音频、取消恢复、保存重开与原生UI通过；待下方记录源接纳与推送结果。**
- task_id：D-ALIGN-01；spec_revision：implementation-r1（UI歧义补充implementation-r2）；contract_revision：ALIGN1。
- 规划核查基线：`88227688d5ba1e27670fe5972f83f980b978df02`；指导修订：P2026-09-13.1。
- 实施source_base：`aa277f965629591a23f80f7f4baf3b081cd8de2a`；初始执行基线：`6228a26b38c3835e768a0d2c5ee9ce0adc306bf7`；run_id：`run-20260913T104905Z`。恢复按末尾停点，不再从规划基线启动。
- 权威方向：[指导原则](../PRODUCT_PRINCIPLES.zh-CN.md)；实际源码与历史通过分开，本文不改变已验收精度、签名或权限。

## 目标与有限出口

用户在现有项目→模态工作台中，看见当前模型真正可用的操作与范围，能够选择已经适配的文字长度/图像尺寸配置；请求、候选、保存重开记录真正选定的值。小机默认不再成为所有Mac的隐蔽上限。以同一能力来源连接后端和UI，成为之后组合积木/新视频后端的基础。

完成标准不是造好整个可组合平台：只落实最小能力声明、文字/图像两条实际接线、音频现状的准确呈现及相关回归。音频medium的普通应用部署切换、新模型、视频运行、节点/脚本编辑器、自由布局编辑器、RAG、歌声/HUM识别、全媒体/移动端不在本阶段。已有固定值被分类不等于全部解除。

## 1. 现有资产与真实落差

| 范围 | 当前事实/代码 | 本阶段处理 |
| --- | --- | --- |
| 契约 | `Sources/DInference/InferenceBackend.swift`仅描述ID/版本和粗粒度能力；`InferenceRequest.swift`已有类型化请求 | 增窄能力值型描述，复用现有请求，不造通用端口/参数字典 |
| 资源 | `Sources/DRuntime/ResourceBudgetPolicy.swift`已按物理内存保留max(4GiB,25%)；`InferenceRuntime.swift`按估算拒绝 | 不重做已修预算、不改drain/release；显示推荐、估算和当前准入的区别 |
| 文字 | `D/AppSessionFactory.swift`默认配置；`MLXDiagnostics.swift`2048/1024；`TextDraftSession.swift`请求默认256 | 用显式执行配置与草稿选择接线；现有2048/256保留为明确预设，不静默截断 |
| 文字边界 | `MLXTextBackend.swift`32768/8192；`LocalModelInventory.swift`qwen2/量化/128GiB权重；`TextModelProfiles.swift`固定0.5/1.5/7/32B | 声明当前支持；不伪称128GiB为硬件限制，不自动增加72B/模型族/精度。上限迁移或扩大另列契约变更 |
| 图像 | `ModelLibraryTypes.swift`/`ProjectSession.swift`固定512；`ImageExecutionProfile.swift`已有256…2048、32倍数，仍4步/guidance1/4Bq8 | 接通同一已实现profile及实际宽高到草稿/请求/保存；默认512，新增范围逐项验收 |
| 音频 | `AudioBackendConfiguration.swift`有sm-music/sm-sfx/medium；`BundledAudioEngine.swift`普通路径绑定sm-music；MRT2 small固定16秒/512音符 | 能力声明区分backend支持与当前宿主可用；medium不可因枚举存在就显示可执行。现有三操作/音乐条件只回归 |
| 文件/时限 | `PNGRecipeCodec.swift`32MiB/16MP；`ProjectResourceBrowser.swift`32MiB/20MP；`AudioTypes.swift`原声64MiB/120秒；音频默认600秒 | 登记目的/来源/拒绝理由，不删除安全预算，不扩大长媒体处理或改超时机制 |
| 跨平台 | App最低macOS26.2，核心package14，UI26.0 | 如实说明，不修改部署目标/签名，不承诺Intel或全Mac兼容 |

历史证据复用：D-SCALE-01、D-TEXT-PROFILES-01、D-PORTABLE-KIT-01、D-KIT-USABILITY-01、D-T0-WORKBENCH-01、D-MRT2-WORKBENCH-01、D-AUDIO-CLOSE-VIDEO-01。现场大配置只对其具体版本有效；≥96GiB未验收。本轮文档没有重新执行这些检查。

## 2. Lead 先冻结的最小契约

能力描述只含：操作/契约ID，backend/模型revision/profile，输入输出角色/类型，类型化参数范围与合法组合，控制精确/近似/不支持，执行/取消形式与错误。复用已有文字、图像、AudioRequest和条件类型；未知版本拒绝执行但保留已存作品查看。

DWorkbench组合“声明＋当前已安装/部署实现＋机器信息＋可引用验收记录”，产生当前能力快照。模型实际要求、D实现范围、实测范围、推荐值和准入结果是独立字段；`untested`不能等同`unsupported`。硬件信息不污染模型静态声明，设备变化不覆盖用户值。

UI和提交校验使用同一来源；backend继续独立检验，描述与执行不符必须失败并报明原因。不要把UI字符串反向解析为规则。profile在提交时不可变；不通过修改正在执行的backend实例配置切换任务，App/CLI均显式装配。

字段命名和具体Swift类型由Lead在准备工作树冻结后派工；不是先写完实现让Worker照抄。不得以文档中的“有扩展点”替代真实调用链与反例。

### 最小行为表（阶段获批后作为验收语义）

| 原状态/输入 | 动作 | 必须发生 / 反例 |
| --- | --- | --- |
| 新草稿/旧项目没有新选择字段 | 打开 | 保留旧512/短文本等行为；清楚显示所用预设，不自动扩大任务 |
| 大内存机器，用户此前选定512或短输出 | 恢复 | 保留用户选择；推荐可变，执行值不自行变化 |
| 合法已适配尺寸/文字配置 | 选择并提交 | 保存实际值与profile快照，UI/准入/后端一致；不可显示1024却执行512 |
| 提示超过所选输入额度，含中文/emoji/提示包装 | 提交 | 按真实token规则说明超出，原文不变；不能按字符数冒充token或静默截断 |
| 切换模型/profile后旧值不兼容 | 选择 | 保存旧草稿，标出需调整项，用户确认调整后再执行；不静默改精度/尺寸 |
| 生成期间修改文稿/选区/条件或切换文档 | 结果到达 | 绑定原请求/版本候选，显式过期，不覆盖当前内容；复用T0保护 |
| 当前宿主只有SA3 small，backend枚举含medium | 查询 | medium显示未部署/当前不可用的原因，不宣称机器内存不足或假启用 |
| 内存估算超当前准入预算 | 提交 | 明确这是估算拒绝、尚未加载；保持当前产品准入。本阶段不把普通模式改成无限试探 |
| 移动/折叠参数区、改变窗口大小 | 操作 | 不提交任务、不改变请求/草稿值；保持输入法/焦点，不能裁掉主控件 |
| 接受/拒绝/撤销、取消、保存失败、退出重开 | 操作 | 复用既有候选/原件/持久化语义；已保存作品和实际配置不丢失 |

已有测试包的显式容量探测继续独立存在，不能通过改普通准入门槛“制造”高配验收。是否将可控试探引入产品需另立有界行为规格。

## 3. 工作拆分、顺序与所有权

这是排期提案，不是已签发的Worker任务；没有活跃实施run。人数按就绪度和工具资源决定，不因以下表行数全部同时启动。

| 顺序/工作包 | 工作与文件边界（派工前冻结精确清单） | 负责/依赖 |
| --- | --- | --- |
| A0 共享准备 | `Sources/DInference`最小能力类型；现有session注入接口、配置选择与保存字段契约；必要CPU反例 | Lead；先核对实际类型/文件；不增加空库 |
| A1 文字接线 | `Backends/MLX/Sources/DMLXBackend`文字配置/能力，`DWorkbench/Text`有限请求配置与直接测试 | Sol/high候选；依赖A0；不改共享ProjectSession/Store/App装配 |
| A2 图像接线 | 图像profile/能力与独立配置投影/测试；保留4Bq8数值与形状约束 | Sol/high候选；依赖A0，可与A1并行；共享文件由Lead处理 |
| A3 音频声明/参数区 | 先为已有SA3/MRT2建立真实能力投影；之后接通UI条件区，分别签发不重叠文件范围 | Terra/medium候选；稳定契约和夹具就绪才开始；不切换内嵌引擎 |
| A4 装配与持久化 | `D/AppSessionFactory.swift`、`UI/State/WorkbenchModel.swift`、`DWorkbench/State/ProjectSession.swift`、`Project/ProjectModels.swift`、`Project/ProjectStore.swift`以及CLI装配 | Lead单一协调；profile按请求冻结；不与Worker并写 |
| A5 组合/接纳 | 分支整合、编译、回归、真实小配置、必要GUI与独立代码审阅 | Lead排队；重要Lead实现由非实现者审核 |

存储先复用当前已存在字段；若新选择需持久字段，只允许必要、明确版本的兼容扩展和备份/旧项目夹具，不重排媒体、不借机建立工作流或布局格式。无法证明旧项目保护则停止相关接纳。全局ProjectSession、ProjectStore、模型库、工程与依赖锁不由多个Worker同时修改。

实施沿用受限CLI、每任务独立外盘工作树/写根/缓存、显式模型与可观察核验、网络关闭、禁止递归、初交+两次修复和一次有界接管；旧预算不刷新。独立审核与自测分开。精确子任务ID、时限、允许路径和run记录在阶段获批、接口冻结后建立；本轮不制造空Worker分支。

## 4. 验收与停止标准

1. CPU：每个实际profile的合法/非法/互斥/未知值；描述与后端校验一致；16/32/64/96/128/192GiB合成机器推荐不篡改支持范围或用户选择，溢出/无效值有界。合成内存仅证明策略算术。
2. 接线：文字显示的输入/输出配置真正进入后端；图像显示的宽高/profile真正进入请求和实际记录；音频声明不误报medium已部署。保存重开恢复新旧草稿、候选与配置。
3. 回归：T0中文/组合字符/emoji、迟到候选、接受/拒绝/撤销/保存失败；图像原默认数值及取消交接；SA3/MRT2既有生成/条件、候选/文件保护。按实际受影响入口选用`test-foundation.sh`、`test-workbench.sh`、现有MLX/CLI/audio CPU套件；不改断言或黄金样例。
4. 构建：现有离线依赖，独立DerivedData/产物，Lead串行；无签名编译只证明装配。App、CLI、测试包的共享能力来自生产定义；便携测试编排仍在`tools/testkit`，不混入App。
5. 真实验证：资源/授权窗口重新核对；现有获准小文字模型至少证明一个非默认配置实际生效，包含越界提示；既有图像512回归和资源允许的一个非默认尺寸；音频保持现有小配置回归。全流程记录实际参数、生成、取消/释放、候选与保存重开，不以mock替代。
6. 原生UI：项目→模态操作不绕路，配置切换可理解，窗口缩放/输入法不回归；普通D和用户项目不被替换。缺真实验证时分别标组件/装配/产品状态，未验收新路径保持隔离，不默认覆盖既有行为。
7. 非实现者审阅实际改动与独立反例，组合固定SHA通过后才接纳；源入口相关回归、个人scheme内容/摘要/索引/未暂存状态再次核对。最终文档版本与受测代码分开。

大内存机器、扩大模型/量化/长上下文、长音频、媒体流式优化和旧系统兼容不是本阶段必须实测项。它们进入能力/限制登记并保留后续验证入口，不作为所有用户永久禁用的理由。下载/安装、新费用、签名/权限、主分支/发布不由阶段计划自动授权；可用模型和实际GPU/GUI窗口未知时记录最小阻塞，继续无依赖CPU工作。

## 5. 出口后的工作位置

- **首个新模态提案：视频V0薄后端。** 使用ALIGN1的真实能力/条件/资源边界，固定一种候选与完整编码链，验收文件、时基、取消/释放；不等任意布局编辑器、全音乐或高级文字完成。现有研究保留，下载/许可/新精度另核。
- 可组合下一切片：用已有操作做一个可保存的小组合与两种呈现，验证布局改变不改执行；在有实际复用证据后再增加步骤编辑。图像局部修改、视频镜头、资料研读是设计反例，不要求本阶段实现三套界面。
- 音乐/歌声/HUM、资料检索、RAW和跨工具交换保留在目标表。只有新增实际能力时扩自己的类型/适配/控件；不以图像或文本全部远期功能为前置。

## 规划时的恢复与交付说明（已由下方实施停点替代）

当前仅计划完成：没有实施、构建、GPU/GUI测试或新模型。恢复先读CURRENT_ACTIONS与D-GUIDANCE-01结案，核对真实源HEAD、索引/个人修改、活动任务、当前授权和ALIGN1准备状态。批准后先A0，未批准不发IMPLEMENT。

阶段最终交付应包含：用户可操作的变化、能力/推荐/实测区别、代码和组合/源受测版本、文档后最终SHA、保护状态、未验收配置、非实现者审核、来源/返工与下一单一产品出口。证据存于外盘任务目录，不只保留在工作树。


## 2026-09-13 实施记录（当前有效）

用户已批准本阶段，覆盖上文历史待批语句。source_base为 `aa277f965629591a23f80f7f4baf3b081cd8de2a`；集成工作树 `D-Worktrees/D-ALIGN-01`，分支 `codex/d-align-01`。run_id为 `run-20260913T104905Z`，外盘证据 `D-Development/AgentTrials/D-ALIGN-01/run-20260913T104905Z`。源仅有个人scheme未暂存修改，开始摘要 `ca3635d88aa5a15397b90e528667c66c0e6db7e596176e885c79d194b544206c`，不转入任务分支。

### ALIGN1 / spec_revision implementation-r1

公共请求冻结：`ExecutionProfileReference(identifier:revision:)`；`TextExecutionSelection(profile:maximumPromptTokens:)`。TextRequest末尾新增可选execution，ImageRequest末尾新增可选executionProfile；缺字段旧调用沿用宿主旧配置，未知引用可查看但不可执行。新工作台提交一律显式填入选择。输出长度仍只由maxTokens表达。

新增值型声明按各模态分文件，Worker不得修改共享ExecutionProfileReference或InferenceRequest。`ExecutionContractDescription`只承载语义ID、输入输出角色、控制保真与取消需drain；不是执行器/插件框架。

文字：`TextExecutionCapability`公开profile、maximumPromptTokens、maximumOutputTokens、contract，init(maximumPromptTokens:maximumOutputTokens:)；static profile引用 `qwen2-text` revision1；validate(TextRequest) throws和resolvedPromptTokens(for:) throws由相同规则实现。后端property `public nonisolated let executionCapability: TextExecutionCapability`。最大适配32768/8192仍为实现保护；宿主配置2048/1024保持旧默认，新App显式最大宿主+每请求较小选择。

图像：`ImageExecutionCapability`公开profile、minimumWidth/maximumWidth/minimumHeight/maximumHeight/dimensionMultiple/maximumPixelCount/steps/guidanceScale/maximumTextTokens/contract；static verified512、scalableKlein4B及validate(ImageRequest) throws、estimatedPeakBytes(width:height:) throws。沿用已有profile标识和全部数值/估算规则，定义成为单一源；ImageExecutionProfile兼容包装。后端同名executionCapability为宿主范围，请求在范围内解析独立profile；strict宿主不得承诺scalable。结果记录实际解析profile。纯值生成选择 `ImageGenerationSettings(width:height:executionProfile:)` 在DWorkbench/Models下，默认512/verified512，request(prompt:seed:capability:) throws先校验。不得添加模型/步数/精度开关。

音频：在DInference建立`AudioExecutionCapability`，profile、contract、maximumDurationSeconds、sampleRate、channelCount、operations、noteControlFidelity（类型复用现有AudioOperation，若名称不符先报Lead）；两个后端公开executionCapability，来自当前configuration。宿主未注入实例则不宣称部署。SA3参考变体/局部重绘和MRT2音符条件是近似控制，不宣称严格锁音/和弦。不得改实际音频执行协议/算法/模型部署。

文稿配置 `TextGenerationSettings` 为DWorkbench值型，maximumPromptTokens、maximumOutputTokens、profile、static legacy=2048/256/qwen2-text r1；TextDraftDocument增加generationSettings默认legacy。配置改变生成新文档revision，使旧选区/异步候选失效；所有edit/accept/undo正文重建保留配置。controller公开updateGenerationSettings(_:)并走既有串行保存；保存失败保持正文/旧文件。候选仍会话内存，退出前接受/拒绝原规则不变；不宣称候选跨重开恢复。旧archive缺字段向后读取，保留未知profile供查看，执行时拒绝；不得弱化现有archive/schema检查。

共享ProjectSession/ProjectStore/ProjectModels/WorkbenchModel/AppSessionFactory/CLI由Lead单一维护。Worker不改UI/其他任务文档、工程配置、锁文件、Vendor、签名权限、runtime、脚本入口、源树及保护文件。分工精确允许路径在各子任务记录中。

预先声明工具：只读显式Xcode Git；不调用系统git包装器。CPU编译由Lead串行；Worker允许无输出的Swift frontend parse检查（不是类型检查）、Python以tokenize.open+compile内存检查，不导入/执行目标。禁止默认py_compile。所有输出、TMPDIR、D_TEST_TEMP_DIR、缓存固定每任务output/tmp；未知权限拒绝暂停报Lead，预授权唯一缓存切换可记录后恢复一次；不禁用沙箱/网络/质量规则。初交+最多两轮有因修复，必要一次有界Lead接管，超限停报。

Lead验收不依赖Worker自测，需核心/工作台CPU、离线MLX/App装配、组合实际模型/GUI及非作者审查。真实资源另询问用户当前空闲窗口。缺关键真实验收时留候选，不默认启用源新路径。


### A0准备复核/语义澄清

三Worker以 `6228a26b38c3835e768a0d2c5ee9ce0adc306bf7` 共同执行基线启动，实际CLI上下文验证了请求模型/档位与各任务cwd+output/tmp受限写根、network=false；服务端隐藏解析unknown。文字/图像Sol high，音频Terra medium。2026-09-13用户新确认已保存退出普通D且空闲，可测试；原始答复与时间另存本run。

controlFidelity明确表示语义输入的服从程度，文字/图像提示均approximate；宽高/预算的严格校验另表述。此前字段粒度不足属于Lead规格澄清，不追罚Worker。音频初稿Int→Double类型问题修复1；文字初稿旧inventory入口兼容和null不能视为缺字段的反例进入修复1。所有旧预算延续。

Project schema7、text archive2为必要兼容扩展，v6原字节备份后升级，当前格式缺配置不伪装旧数据。旧archive测试未知版本改成99、浮点/指数版本拒绝在1和2上均保留，未降低验收。文字候选只在会话内，当前接受/拒绝后离开语义不变。准备只读复核指出不兼容步数/guidance的fork会丢值：Lead改为明确阻止直接复用，保留原作品；不增加新参数支持。


## 2026-09-13 候选停点与验收证据

本轮用户重新确认普通D已保存退出、其他AI/GPU空闲，可串行测试；没有新增下载、权限、签名或模态。source_base与源HEAD仍为 `aa277f965629591a23f80f7f4baf3b081cd8de2a`。集成候选实际最新受测代码 `c59c5e0869687f765e444349fedf602ec456339a`，目录/分支同上。只文档收尾后的完整SHA在本run的 `final-receipt.json`，不自引用反复提交。**本阶段尚未通过出口，原工作分支未启用这些新路径。**

实现已覆盖：DInference类型化能力与显式profile；现有backend按每请求预算/尺寸验证、估算、执行并记录；工作台配置跟随草稿及schema7/text archive2安全恢复；音频只显示所注入实例的真实范围；UI数字编辑错误阻止按钮和快捷键经共享服务提交。推荐只为未实测内存启发式，不改用户值/量化或模型。

| 检查 | 实际版本/结果 | 本run证据 |
| --- | --- | --- |
| 核心CPU | `c5c7f3848aa1f3c10264ce0529b4e336de53c82d`，51项通过；后续仅UI/相关测试/记录变化，核心源码一致 | cpu-combined-core/result.json、stdout.log |
| 完整MLX构建及真实图文回归 | `3cf32168f643bfab7ac0113693038b3e9ab2dcb3`，121项、零失败/跳过/预期失败，约629秒；含固定512数值、12个分阶段取消用例、图文交接、consumer/损坏恢复/释放对照 | mlx-build、mlx-regression/summary.json、marker-check.json、results.xcresult |
| CLI构建/原文字进程回归 | `c5c7f384…`，构建通过，10类原冻结CLI进程验证通过 | cli-build-r2、cli-text-regression/reports/summary.json |
| 新文字配置真实执行 | 同CLI代码，原输入实际2564 token；4096输入限额完成16token输出，同输入2048限额明确失败，无截断 | text-expanded、text-existing-limit、selected-profiles/lead-checks.json |
| 新图像尺寸真实执行 | 同CLI代码，scalableKlein4B、512×768、4步/guidance1/seed42；PNG实际解码通过，约52秒，峰值6,309,409,880 bytes，release active/cache均0。Lead看图为正常竖幅狐狸/雪景；不是用户审美验收 | image-portrait/report.json、selected-profiles/lead-checks.json |
| 初始工作台CPU | f4e957d完整SHA见request，322项通过；不移用为后续UI版本通过 | cpu-initial-workbench |
| UI初次组合/修复 | 7915f6d构建失败：profileName混合return；repair2后1ec0a2d编译通过，328项中1项私有NSTextField层级假设失败 | cpu-combined-workbench、cpu-combined-workbench-r2 |
| Lead接管后完整工作台 | **`c59c5e0869687f765e444349fedf602ec456339a`：编译通过，328项中1项失败**。已改为真实SwiftUI控件几何/滚动检查，输出字段未完全进入180高测试视口（ExecutionSettingsViewTests第90行）；未判明是滚动触发同步、坐标测量还是产品布局，不能说仅为测试问题 | cpu-final-workbench/result.json、stdout.log、stderr.log |
| 普通App装配/GUI/本轮音频真实生成 | **未执行**；因组合门槛失败留候选。已备独立离线App缓存和构建请求，未启动本轮应用/打包，不借用此前音频GUI通过 | native/request.json标PENDING；resource-confirmation.json |

本机M4/16GiB；没有把合成64/96/128/192GiB推荐或枚举能力当作跨机验收。`3cf32168…`到最新候选的backend/core/CLI代码相同，具体blob比较见最终receipt；工作台失败状态单独保留，不叠加历史测试制造总通过率。CLI初次构建参数误带仅测试支持的-enableCodeCoverage，Lead改正调用后成功；属于Lead编排错误，不是实现失败。

### 来源、预算与审核边界

- 三个初始独立实施包真实时间重叠（UTC10:54:23…10:56:53）：文字Sol/high、图像Sol/high、音频Terra/medium；UI在共享契约就绪后由独立Terra/medium接续，未为并行共享存储写入。记录见四份任务文档和 `worker-execution-summary.json`。
- 文字初交+repair1，仍余1轮；图像初交+一次语义澄清修复，仍余1轮；音频初交+类型修复1，仍余1轮。UI初交+2轮修复+**一次Lead有界接管**已用完；不以本次暂停/新名字恢复预算。UI repair2一次cwd拼写错误在进程创建前被拒绝，Worker按规则暂停，Lead核查后在同轮剩余时间内改正路径；无成功越界或扩大权限。
- Lead亲自完成共享接口、App/CLI/状态/保存接线、独立反例及UI最后修补，不记作Worker独立完成。没有改Git人类作者或逐函数模型标签。
- 首次独立CLI审核因Lead在其读取期间推进集成HEAD而作废，没有有效结论；记录审核调度责任。随后在固定detached `D-ALIGN-REVIEW-01` 重做read-only Sol/high审核，最终结果追加下方；不再修改该审核树。原生只读建议记录不冒充构建或实际操作验收。
- 本批每次运行耗时、模型与可观察受限路径有记录；resume终端usage为可能累计快照，未盲目相加。完整Lead归因及订阅货币成本unknown；不据此宣布多代理已更便宜。

### 当前限制的准确表述（候选实现，未默认启用）

文字宿主32768/8192为当前适配器保护，还须满足实际模型总context；普通模型目录仍Qwen2.5 0.5/1.5/7/32B 4-bit，未新增72B。图像宿主256…2048、32倍数；菜单512/768/1024仅快捷预设，仍Klein4Bq8/4步/guidance1/512文本token。普通SA3仍sm-music120秒/44.1kHz双声道；medium380秒属于可配置后端范围，不代表普通App已部署。MRT2当前small导出16秒/400条件帧/512音符/48kHz，近似控制，不代表模型理论天花板。16GiB不是产品上限，≥96GiB和范围全组合仍未验收。

内存准入仍物理内存减max(4GiB,25%)，单重任务；估算拒绝不同于实际加载失败。提示/权重/媒体文件读取保护、600秒音频默认超时、现有macOS部署目标未改，不以解除固定UI默认值为由删除安全约束。

### 恢复检查点与最小下一动作

停止产品代码修改，保留所有候选/工作树/证据；不接纳源、不push、不启动视频或新一批。原个人scheme摘要/内容/索引/未暂存状态和普通D四文件在最终receipt核对；普通D未关闭或替换，本轮没有启动GUI实例。所有写Worker和测试父进程已结束；最终只读审核结束状态随receipt核对，不能仅凭归档推断进程结束。

下一动作须针对剩余布局失败取得新的有限修补授权：先复现并解释确切视口/滚动证据，再最小修补，保持几何/可达性标准及修复范围；通过CPU、非作者审阅后才继续隔离普通App、真实图文音频/GUI保存重开验收和接纳。不要重做已通过模型基准、扩展前端或重置旧Worker预算。当前故障不是Mac权限不足，不需要用户提供密码/全盘访问。


### 固定候选非实现者审核结论

Sol/high独立read-only会话 `review2/route-observed.json` 已完成（约549.6秒），固定detached快照 `c59c5e0869687f765e444349fedf602ec456339a` 首尾不变、干净，无构建/测试/写入；报告 `review2/response.md`。共享文档版本/异步候选/图像请求冻结、旧项目保护、真实profile传递未发现其他可行动缺陷；这不是执行验收通过，已失败的布局检查依然阻塞。

审核另发现 **ALIGN-AUDIO-EARLY-VALIDATION / P2**：普通sm-music实例声明最长120秒，但现有AudioCreationButtonHandler只检查正时长，121秒仍可显示准备并提交，后端库存验证才拒绝。本轮对该校验路径没有改动（原基线已有），音频Worker冻结范围明确只显示能力、不改现有验证，因此不追罚Worker或扩大其预算；但它与“前端/提交同源”的总体目标仍有缺口，不能宣称已全部统一。保留为待澄清的有限接续项：把现有120秒拒绝提前到冻结请求/按钮状态，不扩大时长、模型或运算。未经接续范围明确不在本停点偷偷改代码；报告/处置证据 `review2/lead-disposition.json`。

## 2026-09-13 用户续行授权与 Lead 收尾

用户明确要求继续本阶段直到完成。本次沿用 task_id，保留初交、修复预算耗尽与上一停点；不追记 Terra 独立通过。Lead 定点处理文字参数面板真实滚动验证及已知音频时长提前校验缺口，不改变既有模型、精度、操作/时长上限。新证据目录：`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-ALIGN-01/run-20260913T131843Z-continuation`。复用已验证核心/后端的相同代码证据，补组件、普通独立 App、真实工作台及组合审核后才集成/推送。音频校验从实际注入能力读取上限，生成取请求时长，变体/重绘取原声时长，超限不排队、不改变输入或媒体。源基线 aa277f965629591a23f80f7f4baf3b081cd8de2a，续行候选 3ac7be6ebe5cd4c8f7b50180c38045eaefc6c4f5；个人 scheme 与源索引已核对保持。

### 续行工程结果与当前人工停点

固定受测代码 `a2d7aa2f3ed3ec74cdfa9dd501a83ddc3062fe36`：53核心、329工作台方法通过；普通App/测试构建通过，6宿主方法通过。新增缩放反例在未修代码中280×140视口下字段仍156..180而失败，修后116..140通过；原320×180检查单独/全套重跑本身可过，不能把原偶发失败描述成已证实的生产滚动缺陷。音频120/121、无排队与输入保护通过。非实现者 `/root/align_continuation_review` 在独立detached快照完成只读审阅，无新增发现；未执行独立测试。前次Sol审核与所有失败保留。

XCTest nativeUI本次未进入测试：系统coreautha要求“XCTest 正在尝试 Enable UI Automation”密码确认，runner初始化超时，退出65。未算UI0/0通过，不改变测试标准/系统权限；已单次Glass并请求用户只在系统窗口确认。普通沙盒重建与内嵌音频封装、codesign完整性及诊断通过；真实GUI和音频本轮仍待执行。新产物/独立launch已准备但尚未启动。证据目录 `/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-ALIGN-01/run-20260913T131843Z-continuation`，原普通D四文件与源scheme/索引保持。

### 系统确认后原生复验（2026-09-13）

用户回复“已确认”，同版UI九项实际执行：七项通过，两项在原生GoToWindow的长路径输入失败。保留`native-tests-r2`实际7/9；附件显示完整长路径仅输入至UUID中间，8秒后仍缺尾部，并非项目读写/迁移失败。Lead只调整`DUITests.swift/openFixture`的事件发送：同一路径连续分32个Character发送，利用XCTest每次调用的idle同步；不重试丢失尾部、不改原完整路径相等和打开项目断言、不用剪贴板、不改App。该新增测试驱动文件属于本次必要验收修正；真实输入法/用户交互仍单列。


## 2026-09-14 完整候选验收（同一阶段续行）

用户本人确认系统提示后，Lead完成必要原生测试驱动修补。产品源码受测 `a2d7aa2f3ed3ec74cdfa9dd501a83ddc3062fe36`；原生测试驱动受测 `7632d06084e1499a01a8b2223e939d9491d75151`。两者之间只含原生测试文件与文档；独立非实现者检查该测试差异，未发现降低断言或改变项目路径。`native-tests-r3`同次9/9、零失败/跳过，327秒；r2的7/9及首次授权初始化失败原样保留。

证据根 `D-Development/AgentTrials/D-ALIGN-01/run-20260913T131843Z-continuation`。核心53通过；工作台套件报告329通过、其中可选 `approvedInstalledWeightsRemainUnchanged` 因未设D_TEST_TEXT_MODEL跳过，不能记零跳过；宿主6通过。源接纳后显式选择已授权0.5B目录补该CPU校验。MLX完整121、原CLI10类、2564-token输入4096成功/2048拒绝及512数值/取消/释放沿用原run不可变后端证据，具体blob对应 `evidence-reuse.json`，不重复相加。

普通开发签名、App Sandbox、内嵌SA3/MRT2引擎的独立产物（不是调试后端注入）完成：

- **图像**：真实512×768、seed42、4步/guidance1生成并解码；任务与PNG宽高一致，Lead目视正常竖幅狐狸/雪景。无效数字禁止按钮/快捷键提交，保留已保存参数。
- **文字**：普通工作台显式4096/128；空值、非整数、溢出均阻止提交。中文、组合字符、emoji完整选段真实改写；接受前原稿不变，改额度使旧候选失效，拒绝/重新生成/接受/撤销恢复原始Unicode。小模型输出改变emoji，不能当专业写作质量通过；4096短文GUI与旧2564-token长输入证据分开。
- **音频**：SA3实际能力120秒/44.1kHz双声道；121秒保留输入、显示错误、不排队。6秒真实生成/试听/采用/保存/导出，WAV 264600帧float32，有限非零PCM。MRT2实际16秒/48kHz双声道；导入4秒100帧、60/62/67音符条件，真实生成192000帧。下一任务取消成为cancelled且无产物，再生成成功，额外候选拒绝但未删除。首次取消点击因任务已完成而失效，不计作取消通过；后续立即取消的独立job提供实际证据。
- **文件/恢复**：同名导出即使在系统提示确认后也由应用拒绝，原目标摘要/大小/mtime不变。正常退出0后以同一隔离会话重开，从最近项目恢复两种音频模型、采用/拒绝、音符与时长；文字原稿和4096/128、图像512×768/seed42均保持。documents/assets/jobs语义与四份媒体SHA/大小前后相同；只有正常活动文档/项目版本元数据可变。
- **窗口**：实际缩窄后参数入口转popover，滚动可到输入/输出额度与操作；放大后原稿/参数未变。未重新要求真人IME/听感，不把自动输入当人类输入法验收；沿用先前真人检查，当前组件/原生回归覆盖本次差异。

精确输入、模型revision/清单、计时/分配及结果位于 `gui/image-result.json`、`gui/text-live.json`、`gui/audio-live.json`、项目Tasks/result.json，最终 `gui/acceptance.json`。SA3峰值约1.61GB、清理后active18bytes/cache0；MRT2约0.528GB MLX峰值/1.52GB进程峰值、清理后active8bytes/cache0。保留微量active及测量口径，不宣称零分配或无泄漏保证；SA3与既有两轮18bytes稳定记录一致，精确归属仍unknown。取消后新任务完整完成与后端生命周期旧回归分别说明。

当前剩余边界：≥96GiB/所有尺寸组合、medium普通部署、麦克风设备、人类音乐服从/纯配器、视频后端与完整可组合平台均未验收。本阶段未下载模型、改精度/签名/权限、替换普通D或启动下一产品任务。两次本轮GUI实例均正常退出0，源scheme及普通D四文件保护保持。首次SA3选择误用了面板当前目录，明确缺权重报错后通过完整路径纠正；没有更换模型或绕过文件校验。

来源仍为Sol/high文字/图像、Terra/medium音频/UI初步实现；Lead负责共享接线、独立反例、音频提前校验、窗口测试与原生输入驱动收尾、真实验收。旧UI预算耗尽事实不变，用户续行后由Lead收尾，不追记Terra独立通过；当前只读复核是非实现者代码审查，不是独立测试运行。订阅费用及完整Lead耗用unknown，不重算历史累计usage。

失败经验：原生长路径输入应保持完整路径断言，以有界分段事件发送改善驱动可靠性；控件几何测试应在真实缩放后验证可达性。系统确认、测试输入失败与产品缺陷分别记录，不以绿色计数覆盖先前失败。源集成/推送版本与恢复点追加下方，最终提交自身SHA仅存外部回执。
