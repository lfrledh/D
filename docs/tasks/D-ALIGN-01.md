# D-ALIGN-01：能力声明与既有工作台对接

- 状态：**2026-09-13用户已批准实施；A0准备中，尚未验收/接纳**。
- task_id：D-ALIGN-01；spec_revision：1（计划）；contract_revision：ALIGN1（语义提案，Swift符号派工前冻结）。
- 规划核查基线：`88227688d5ba1e27670fe5972f83f980b978df02`；指导修订：P2026-09-13.1。
- 实施source_base/base_sha/run_id：尚未建立。开始时核对本轮文档结案后的真实完整HEAD，不用本段旧基线自动开始，不创建实施Worker。
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

## 恢复与交付

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
