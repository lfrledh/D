# D-SINGING-WORKBENCH-01：有限歌声创作闭环
状态：机器可执行验收通过，H22原生/本人验收待办；尚未源接纳新入口或推送。2026-09-16，SW1.1。源基线4ff70c5bd951898296d6e0c2eda0fdba8dee6275。
用户批准本阶段，当前不在Mac旁。源个人scheme不进入任何工作包；源/产品未通过GUI前不接纳，候选保留。
证据：/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-SINGING-WORKBENCH-01/run-20260916T001115Z。上一阶段正式代码91ca5897d0047842b12941c7f4fae55daa9a9762，4ff只增加6份文档，上一审核/源复验索引已核验。

## 目标及边界
项目→音频内提供有限歌声草稿（音符/显式休止、歌词单位、显式音素/元音锚）、材料选择/用途资格确认、生成、试听/采用/拒绝、修改后新候选、安全保存重开/WAV导出。复用AudioCreation与ProjectAsset/Job，不新增包或绕过运行时的执行路径。
不含自动多语言G2P、完整DAW/谱面排版、新声库/算法/精度、视频修复或组合工作流。现有600秒协议上限是声明，开发机6秒实测不作为产品上限。资格声明不授予权利；不得预填已确认或由代理点击真实资格。真人项进集中清单，当前完成CPU/装配/可隔离headless，不能以其代替GUI。

## SW1行为表（Lead冻结）
- 草稿未写完→保存/重开：保存原始UTF8及稳定ID，不先做生成验证、不丢半写数值。
- 编辑→提交：精确十进制秒到微秒（最多6位小数，不用Double/40ms），连续覆盖时轴；音高MIDI0…127整数；空音高不是休止；显式rest才null。中文/组合字符不归一化。
- 歌词单位→多音：明确noteIDs、音素序列和0基元音锚；休止一个note、空歌词、SP、null锚。不静默猜音素或忽略条件。
- 任何输入字节/材料/profile/用途变化→新的内容revision；A→B→A仍不同。保存revision与内容revision分别管理；选择/拒绝不改内容revision。
- 提交→不可变request和内容revision绑定；旧回调可保留历史产物，不得采用到另一个文档或已改草稿。采用需同文档completed未拒绝且内容revision相符。旧产物不删除，可明确历史试听/导出。
- 生成前材料双目录原子选择；取消任何一侧保留旧完整选择。先状态“已选择，生成前校验”，不是已校验。用途/材料指纹确认后才后端全量验证/执行；不造占位已确认请求。
- 取消/失败→drain/权限结束后才下任务；清单失败保留草稿/已发布WAV及旧作品。歌声mono44100 float32、half-up样本数、output/output.wav及result.json与request关联，不能用旧audio立体声/380秒策略。
- v12→v13备份原始清单后迁移；旧音频/文本/图像/视频不改变，新增字段缺省不等于已确认。
- 原生输入控件在缩放时保持identity；布局不生成任务/改草稿。

## 分工与权限
Lead：共享AudioCreationDraft、ProjectSession、WorkbenchSession、AppSessionFactory/Bootstrap、ProjectModels/Store协调、接口、资格、backend访问授权、总验收集成。写Worker一任务一物理worktree/分支；网络false、workspace-write，仅worktree+自有output/tmp；共享.git只读；无递归。Sol/high用于纯数据/部署风险；之后稳定view可Terra/medium。
每包初交+最多2轮明确修复，必要1次有界Lead接管；环境/身份/未知权限事故立刻暂停。每轮先审异常和保护再发修复。预检不得实现，Lead核实turn_context模型/effort/cwd/写根后同thread授权。900秒每轮。既有历史预算不变。
Worker只允许局部CPU/内存compile、Swift语法或限定无依赖DInference/DWorkbench测试；缓存/输出固定task tmp，不默认py_compile，不在仓库生成缓存。禁止全App构建/GPU/真实模型/GUI/网络/安装/签名/权限/源分支/commit。Lead只在Worker交回写权后显式提交。准入拒绝不可绕过；安全降级仅无bytecode检查及唯一已授权tmp。

## DATA（SW1-DATA.1）
允许新增：
Packages/UI/Sources/DWorkbench/Audio/SingingCreationDraft.swift
Packages/UI/Tests/DWorkbenchTests/SingingCreationDraftTests.swift
其余只读。输入契约Sources/DInference/SingingRequest.swift；参考MusicCreationDraft只借原文保存，不借40ms转换。
冻结公共类型（public Codable Sendable Equatable，各有public完整init默认可用）：
SingingNoteDraft: id UUID, startText String, durationText String, pitchText String, isRest Bool。
SingingLyricDraft: id UUID, text String, noteIDs [UUID], phonemes [String], vowelIndexText String（空代表null，仅休止允许）。
SingingCreationDraft: id UUID, contentRevision UUID, phraseRevision Int64（默认1）, language String（默认zh）, durationText String（默认6）, notes [SingingNoteDraft], lyrics [SingingLyricDraft]。
static var example: Self：简单6秒“啦/呀/啦”含休止，明确普通音符和zh音素；示例不是资格声明，若无法确认真实符号则返回给Lead不猜。
public func hasSameEditableRepresentation(as: Self)->Bool：id/稳定子ID及所有编辑字节/引用/顺序比较，排除contentRevision/phraseRevision；Unicode字节比较。
public func makeRequest(profileID:String, inventoryID:String, inventoryRevision:String, symbols:[String], silenceToken:String, vocoder:ModelReference, qualification:SingingUseQualification) throws -> SingingRequest：只映射已有字段/验证，保持id及phraseRevision、先校验数值再SING1.validate，原草稿不变。
public func validateStorage() throws：只结构预算、ID唯一、原文大小/NUL/数组有限，不要求时值合法/完整歌词引用。4096音符/4096单位/262144总歌词字节、8192总音素及单符号128字节；这些是SING1输入预算，不自行收窄模型范围。内容revision由宿主维护，类型不自动修改。
准确测试：0.01=10000、1微秒、负/NaN/exponent/>6位小数/overflow拒绝、600边界、空不是rest、单音/一字多音/休止/不完整保存、UTF8组合等价但字节不同、ID/revision稳定，qualificationfalse报错。先看真实baseline符号（只读本任务提供的6秒输入）再示例。
测试可用swift test --package-path Packages/UI --scratch-path <自有tmp>/swift --filter SingingCreationDraftTests，显式CLANG_MODULE_CACHE_PATH/SWIFTPM_MODULECACHE_OVERRIDE到tmp，若工具沙箱拒绝停报，Lead执行，不自行--disable-sandbox。

## PACK（SW1-PACK.1）
仅允许：
Backends/Audio/Packaging/prepare_singing_engine.py
Backends/Audio/Packaging/package_singing_app.py
Backends/Audio/Packaging/tests/test_singing_packaging.py
Backends/Audio/Packaging/singing-runtime-lock.json
D/BundledAudioEngine.swift
Backends/Audio/Tests/BundledAudioEngineChecks.swift
前4可新增，后2最小扩充singing family，旧family规则不变。
只读参考prepare_pitch_engine/package_pitch_app/prepare_engine/package_audio_app；运行测试只受控fixture，禁止复制真实env/构建App/签名模型测试（由Lead执行）。
SingingEngine.dengine / kind d-singing-engine；provider/d_singing_render.py；model-manifests/qixuan-bigvgan-profile-v1.json；vendor=SingingVendor。必需4个helpers d_audio_contract,d_singing_prepare,d_singing_timing,d_singing_qixuan及d_audio_access。可选新d_singing_app.py由Lead后接入，当前不要引用不存在入口，prepare允许明确wrapper目录后Lead修订。
Python3.12独立runtime+固定当前sitepackages，不打包venv/pyvenv.cfg，不含模型权重/个人路径/缓存。公开CLI explicit --python-root --site-packages --provider-directory --vendor-directory --profile --output；固定依赖从已批准环境dist-info元数据核对，不导入/读模型，不下载。许可证跟随。engine清单相对路径，拒绝软链、额外文件/错摘要/既有输出/重叠输入输出；普通失败报告不得覆盖输入。安全调用子进程不shell插路径。
仅singing容器预算8MiBmanifest/32768files/2GiBaggregate/512MiB每文件（只读实测当前约21601files819MB，无stdlib），不作为RAM限制。旧family4MiB/10000/1GiB不改。
借用现有可移动Python的验证/打包函数与签名流程，不复制整套框架；最终包移到中文空格目录后由Lead验证真实import。当前原venv依赖Homebrew不能宣称独立；无法重用既有stdlib/动态库规则要上报，不偷偷放宽。
package_singing_app只创建副本，不改变source App；按既有签名流程显式identity/输出与报告，调用时由Lead协调。CPUfixture mock证书不是真签名。
测试缺依赖/错误版本/错hash/链接/输出碰撞/输入保护；更新Swift fixture覆盖singing resolve与旧family界限。不要测试迎合实现或改旧断言。将待Lead完整部署验证清楚列回传。

## 验收/恢复
局部DATA/PACK/STORE/VIEW CPU → Lead组合workbench/core/backend及App编译 → 固定现有歌声材料headless真链路/取消/来源/保存读回 → 非实现者审核 → 真人资格/IME/试听与普通沙盒GUI → 才允许源接纳/推送。
本轮用户离开：不重复催解锁，当前候选所有可独立工作先完成；真正本人项集中H22（登记前核重号）。
当前仅创建Lead候选worktree，源HEAD/个人文件完整保护，尚无Worker实现/新产品默认入口。最终SHA/日志写外部回执，不自引用amend。

SW1.1 erratum（首次实施前）：PACK真实入口为d_singing_render.py（已读实际源码），非d_singing_run.py；DATA示例音素啦=zh/l zh/a，呀=zh/y zh/a，元音锚1，休止SP；来源上一真实baseline，仅借音符/发音，不借资格true。

## ACCESS（SW1-ACCESS.1，独立于DATA/PACK；Lead冻结）
允许修改：Backends/MLX/Sources/DMLXBackend/SingingBackendConfiguration.swift、SingingBackend.swift、SingingModelInventory.swift；
允许新增Backends/Audio/Python/d_singing_app.py、Backends/Audio/Tests/test_singing_app.py；
允许直接测试修改Backends/MLX/Tests/DMLXBackendTests/SingingBackendTests.swift。
其余只读（特别d_singing_render.py/d_audio_access.py/AudioProviderAccess.swift/算法/供应商/资料/包/全局/任务文档）。
配置新增accessBootstrapRoot:URL?=nil、confirmDeployment:(@Sendable () throws -> Void)?=nil。providerScript仍renderer；App模式固定同目录d_singing_app.py，不增加任意入口。CLI nil保持行为。Inventory inspect/seal额外wrapper/accesshelper、独立bootstrap目录，重建validatedConfiguration保留两个字段。部署confirm应在estimate/启动前及drain后调用，修改来源优先错误不能被取消/清理覆盖。
execute：request封存后、启动前AudioProviderAccess.prepare(root,runID,dirs:[bank,vocoder,run])去重；cwd bootstrap而非尚未授权的外盘run。执行参数-B wrapper --access-manifest <path> --access-run-id <uuid> -- <renderer原六对flags>；传原私有cache/offlineenv。run返回/抛错已drain；输入后验、部署复核和finish均尝试、cleanup只一次、保存原始错误与已证实inputIntegrityChanged优先。启动前失败清理已创建bootstrap，处理完才发布artifact；sharedlease仍release才让出。
wrapper先只解析字符串，核request与output/在同一run、grant恰是去重bank/vocoder/run，调用acquire_file_access才读外盘。复用render、_signal_cancellation、_write_descriptor与错误助手，不修改算法。七progress透传并核runID，访问释放成功后唯一result终态；不能先renderer.main成功再处理释放。信号覆盖授权/render/释放/通知，发布后不再取消checkpoint。授权/结构失败2；runtime/释放/通知失败1；普通提交前取消130；已发布WAV保留。无os._exit，无shell拼用户路径。
测试CPU受控CFadapter/renderer，pre-access不读材料、错ID/额外grant、部分获取失败释放、释放失败无成功终态、完整CLI关闭输出退出码。Swift依赖fixture覆盖argv/env/cwd、三目录/去重、启动失败/取消/timeout/consumer drain→保护→cleanup→release；不伪造真实沙盒。Worker不运行MLX/全package构建；可内存compile及Python局部fixture，Swift完整测试由Lead串行。
此包Sol/high，单独worktree/模型/预检/write roots；初交+2修复+一次有界接管，同通用900秒。精确输入参考AudioProviderAccess/现renderer/main、MLXAudioBackend访问模式，最新用户范围只在本任务内。

## STORE（SW1-STORE.1）
唯一所有者获准修改Packages/UI/Sources/DWorkbench/Project/ProjectModels.swift、ProjectStore.swift、Audio/AudioTypes.swift；
新增Audio/SingingResultFile.swift、Tests/DWorkbenchTests/SingingCreationStoreTests.swift；必要直接更新Tests/DWorkbenchTests/ProjectMigrationTests.swift以新增v12→v13原字节备份场景（不得删除旧断言）。其它只读；不改AudioCreationDraft/SingingCreationDraft/ProjectSession/任何backend。
已存在接口：AudioCreationProfile.singing、AudioCreationDraft.singing:SingingCreationDraft?、singingPurpose:SingingUsePurpose、singingMaterialsID:UUID?，DATA字段/方法见本任务。不完整草稿保留。Lead管理内容revision，Store负责权威对比/保存冲突/采用门禁。
ProjectJob新增singingDraftRevision:UUID?（init默认nil，旧decode缺省nil）；currentSchema13/readable1...13，更新所有显式版本白名单/CurrentTextSourcesFields，v12原字节project.v12.backup.json先安全发布再迁移。只校验草稿结构/定义ID/phraseRevision>0/用途类型/有限数据，不把可保存未完成稿强制变成合法request，不预填资格。verifyUnchangedManifest纳入全部新原文UTF8和新字段。旧模态迁移及生成行为不改。
enqueue增加capturedSingingDocument:ProjectDocument?=nil（排在现参数最后）；只有.singing用capture。必须同documentID、audio创作/无原声/operationgenerate/profile.singing；captured.singing.makeRequest使用request自身profile/inventory/symbols/voice/qualification后等于singing，purpose相同，contentrevision存在且savedmaterialsID非nil。捕获只来自已保存文档，不能让任意future/sibling snapshot授权：当前文档与capture的内容revision、材料ID/用途必须相同；保存新内容后旧任务不得混入。登记job绑定contentrevision。
saveAudioCreation：内容revision改变清除该文档过期选择/采用引用，仅保留资产历史；采用必须same doc completed nonrejected且job.singingDraftRevision==draft.singing.contentRevision。选择可听旧历史，但不能采用；清单验证区分选择合法历史与采用当前。拒绝仅改保存revision，不能改变内容revision；ABA不失效由Lead维护。
complete/.singing：唯一audio/wav；路径严格Tasks/<lowercase run UUID>-<nonce UUID>/output/output.wav，原run所有权。三层目录以ProjectFiles fd/nofollow保护，不用仅prefix。固定mono44100 float32，framecount为(durationTicks*44100+500000)/1000000（无Doubleties-even）；校验非空/摘要；result.json需固定schema1/runID/source phraseID+revision+duration/requestSHA、audio path/sha/frames/format、model/qualification tuple及execution字段和7stage与现后端格式一致；不得仅因为存在WAV即成功。后台已验证的result.metadata.recordPath转为项目相对路径；其他元数据保留来源，不重复schema。
复用StrictAudioJSON(在MusicConditionFile.swift)防重复键、bool/decimal当整数等；参考SingingProviderProtocol/RequestWire的只读契约。SingingResultFile内部定义有限DTO/用Core已有struct重建同一canonical SING1提交JSON（JSONEncoder sortedKeys/withoutEscapingSlashes），绑定expected job.requestSHA；无DMLXBackend依赖，不改核心。
recover仅处理已登记对应run，固定output/output.wav+result.json均存在且全部校验后登记；不扫描未知目录、不自动重跑，不删除失败文件；已completed/registered不重复，WAV缺record不得completed。复用现taskOwner验证而不是扩大目录扫描。resultMetadata保存相对recordPath，项目移动后可读。
AudioInspectionPolicy新增singingGenerated，最大600秒、256MiB（44100monoF32<106MiB）；原generated380秒/256MiB保持。贯穿inspectionPolicy、complete、重开、导出；源路径/媒体保护不回退。Lead在playback显式用新policy。
验收CPU（Worker新测试/Lead最终跑）：未完成歌词音符UTF8保存重开；完整fixture歌声登记/采用拒绝/修改后旧candidate拒绝采用；另一个文档/capture失效；reject不改内容rev；迁移原字节备份及失败保护；mono format/half-up1us边界；波形有无record/损坏/软链/outsidepath；安全导出碰撞保护；保存失败/恢复不覆盖已发布原件；不伪造真实模型或600秒实测。fixtures依据固定真result结构，可引用旧backend测试内容但不能改其黄金输出。
Worker Sol/high独立目录，只内存检查/局部CPU；SwiftPM内层沙箱已知在DATA拒绝，本包不再尝试SwiftPM，由Lead串行执行。可swiftc -frontend -parse（指定toolchain完整路径/tmp cache）但只语法不声称typechecked；Python不导入目标检查。初交+2修复+一次有界Lead接管，900秒，超范围/契约不清停报。

## VIEW（SW1-VIEW.1，稳定DATA/AudioCreationDraft接口）
允许修改Packages/UI/Sources/UI/Views/AudioCreationView.swift、State/AudioCreationActions.swift；新增Views/SingingConditionEditor.swift、Tests/UITests/SingingCreationViewTests.swift。不改WorkbenchView/WorkbenchModel/ProjectSession/Store/任何模型或包。Terra/medium，独立worktree/预检/初交+2修复/900秒，沿用通用边界；已知嵌套SwiftPM拒绝，不运行SwiftPM，Lead组合测，最多语法检查与fixture分析，不GUI。
复用现有AudioCreationView三种presentation与AnyLayout，不能在宽/窄时换编辑控件identity。新增public supportingSinging(_ enabled:Bool)->Self、currentSingingCandidates(_ ids:Set<UUID>)->Self（默认空集合，singing adopt failclosed）。既有init兼容。profilePicker出现“歌声”（singingSupported或现草稿profile.singing以能打开旧稿），素材原声source存在则不可切入歌声；.singing选择一次原子修改draft（生成操作、清editRegion、singing nil时.example，不改来源/保存/确认或生成）。因DATA独立修复默认示例会更新，不自写另一示例。
歌声controls不显示/要求通用prompt、seed、steps、guidance、strength；显示SingingConditionEditor(Binding<SingingCreationDraft>, isBusy:Bool)和用途Picker绑定draft.singingPurpose，默认personalCreation并非已确认。用途中文：个人创作/商业创作/内部开发评估。解释“音符和歌词由你决定；当前发音需显式填写，音色/演唱近似；不提供可控seed”。模型按钮复用actions.chooseModel，宿主负责两个原生文件夹/取消/资格，不在View调用后端。
编辑器最小垂直可滚动组：总秒数；音符行（稳定UUID：开始秒、时长秒、MIDI0…127、显式休止），新增/移除；歌词单位行（原文TextField、明确关联连续音符选择，显示音符序号不暴露UUID；可将一个字关联多音；音素逐项TextField原文数组+添加/移除；元音位置从0计字符串，休止应空）。禁止每击键split/join吞输入、自动G2P、静默量化/修正/丢弃孤立引用；未完成原文可保存，生成时Core验证。不更改host-ownedrevision或材料ID。删除音符不默默删歌词，给可理解的关联提示，用户修正。对不会产生误清空的显式操作可自主安排。
AudioCreationButtonHandler分支.singing：source=nil、operationgenerate、singing存在/validateStorage通过及hostAllowsGeneration即可尝试提交（严格生成校验在宿主，不能伪造qualification做预览校验），空prompt不阻止；pending旧inpaint字段不影响新歌声。状态提示区分“可编辑/保存，生成前检查音符发音与资格”与已生成，不能声称材料验证成功。
候选歌声：currentSingingCandidates不含ID时可历史试听/导出/拒绝，显示“条件已改变的历史候选”，采用按钮禁用；拒绝/忙/宿主防护原样。扩充adopt helper默认isCurrent=true参数供旧调用不变，song有效性由新参数明确传入，不只视觉disabled。候选不可createFrom到SA3声源编辑（mono当前不支持），原音频功能保持。
控件accessibilityID前缀singing-，StableID利于后续GUI。局部CPU检查行为：空prompt歌声走真实action、nil/原声/编辑operation拒绝、busy/旧candidate不采用、purpose编辑不生成、view构造/presentation接口兼容；已有Audio/Music tests只读。新的数据类型已存在，不构造假模型/授权。


## 2026-09-16 机器验收与候选检查点

本阶段已获用户批准，用户离机。有限歌声创作数据/界面、材料选择与用途资格、运行时接线、严格结果登记、候选处理、保存重开及独立部署已实现；不扩完整DAW/自动G2P/新声库。**机器验收通过不是普通沙盒GUI或整阶段完成。源只同步本节状态文档，新代码保留隔离候选，H22完成后才能接纳/推送。**

### 实际版本与职责

源生产基线 `4ff70c5bd951898296d6e0c2eda0fdba8dee6275`；Lead工作树 `D-Worktrees/D-SINGING-WORKBENCH-01`，分支 `codex/d-singing-workbench-01`。主要组合受测 `194107c02f2668c5e306f6f42e9fe5f3a67f95d6`。随后 `c14bba663661a68ca243562c838ebd45cb26d8d4` 仅改部署测试中的重复局部变量名称四行，正式代码不变；26项部署检查使用此测试文本实际编译并执行，核心66项也在此树通过。最终文档版本见外部 `final-receipt.json`，不冒称在后加文档SHA上重跑过所有检查。

DATA/PACK/ACCESS/STORE由受限独立CLI的Sol/high实现，各用一轮普通修复；VIEW由Terra/medium初步实现＋两轮修复，未独立满足全部测试覆盖，Lead执行一次有界补齐（真实binding/action测试、少量internal测试入口）。共享ProjectSession/材料资格/App装配、组合真实harness与验证由Lead负责，不算Worker独立成功。两个原生只读非实现者完成相应审阅；这不是他们重新执行了测试，也不是另一模型做过GUI验收。角色、请求与观察到的模型/强度、独立目录、执行时间和权限记录见每包 `job.json`、预检/各轮过程与路由记录、`lead/worker-rounds.json`；隐藏服务端解析unknown。Worker各自写根+任务输出/tmp，networkfalse，共享Git管理目录只读。Lead在写权交回后显式提交/合并，没有递归或全访问Worker。

### 验收与证据

以下相对路径均相对于本任务证据根 `D-Development/AgentTrials/D-SINGING-WORKBENCH-01/run-20260916T001115Z`，每项 `result.json`含实际命令、目录、解释器、退出状态及时间；不得把历史/重复运行相加成总通过率。

| 检查 | 实际结果与边界 | 证据 |
|---|---|---|
| 工作台完整CPU | Swift报告DWorkbench 386项记录，3项旧文字实机条件测试跳过，不计通过；其余执行无失败。UI逻辑95、模型库23无失败。新歌声草稿/保存/会话/绑定、挂起资格取消、恢复新稿与旧材料绑定、迁移、失效、保存错误均执行 | `lead/workbench-full`；新歌声Store18项组合中亦执行 |
| 核心/后端 | 核心66项；相关歌声/SA3/MRT2后端67项通过。后端文件与上述组合相同，按摘要复用，不重复跑所有模型 | `lead/foundation`、`lead/mlx-compile`、`lead/mlx-unit` |
| Python/部署 | ACCESS＋PACK共20个CPU方法通过；真实CLI断管/只读描述符/真正关闭输出FD均保留退出错误。Swift部署26个受控夹具通过，包括已观察软链变化与无法读取的不同分类 | `lead/python-combined`、`lead/pack-swift-final3`、`lead/pack-swift-run-final` |
| App/真实测试装配 | Xcode27.0、macOS26.6.2、M4/16GiB；正式App独立无签名编译成功，未启动/替换普通D。独立macOS26 test-only harness编译成功，不抬高DMLX的macOS14要求，不新增生产包依赖 | `lead/app-compile2`、`lead/harness-compile-final`；`Tests/SingingWorkbench` |
| 真实歌声工作台 | 正式ProjectSession→DRuntime→SingingBackend→App访问wrapper→可移动Python→真实权重→ProjectStore；原稿生成、音高60→67再生成、采用/拒绝/恢复、旧候选拒绝采用、保存重开、安全历史WAV导出/碰撞保护通过；第三次在新run实际进度后取消并drain，既有两份作品与采用保留。单个测试流程90.161秒，进程92.722秒 | `lead/real-run/result.xcresult`、`lead/real-workbench-output/summary.json`、保留项目及Tasks |
| 产物独立核对 | 两个6秒/264600帧/44100Hz/mono/F32 WAV，音高、休止、时长、记录、摘要通过原冻结RENDER1规则；无饱和样本。未改旧校验器/阈值；旧脚本摘要d7d66073e34dbf29a5480ff70968bdbe3eee348de36371aa9a3c66767abde69f | `lead/qa-baseline`、`lead/qa-pitch`及对应JSON |
| 运行包/输入保护 | 最终21347文件运行包迁到中文空格目录；真实导入614个已观察映像均为包内/Apple系统。真实生成前后运行包、31声库文件、34声码器目录文件摘要/大小/mtime不变；输出/原输入分开，内存settings不写用户偏好 | `lead/engine-relocation-result.json`、`protection/real-input-before.json`/`real-input-after.json` |

真实测试内部明确使用已授权开发用途，不点击或伪造App用户资格对话框。最终包是 `lead/移动 歌声/SingingEngine.dengine`，模型仍在既有外盘材料目录；源App构建尚未完成普通签名封装/沙盒GUI，须H22窗口由Lead办理，不把裸编译App当可发布安装包。固定声库/声码器/转换精度不变；600秒是协议范围，不是本轮长时实测。没有新全模态/高配/GUI/逐样本真人听感结论。

### 失败、修复与局限（保留历史）

- DATA的嵌套SwiftPM沙箱拒绝后停止，无扩大权限；Lead统一执行CPU。ACCESS初预检和PACK成功命令中的缓存告警曾继续，违背旧“未知事件停报”要求；后续纠正/保护核对保留，不倒改为合规。PACK初轮900秒超时、Lead终止并回收后才R1接续；未知外部进程不按归档视为已停。没有观察到Worker成功越界或权限扩大，但不主张全系统写锁/密码学模型证明。
- STORE初交CPU绿仍发现真实原生帧、波形与记录替换/跨profile采用缺口；按反例一轮修正后独立审阅关闭。VIEW两轮仍缺直接测试，Lead接管补齐，不能归为Terra独立完成。共享保存/材料与资格取消由Lead实现和验证。
- Lead初次组合测试把带目录尾斜线URL与普通URL直接比较，已改为核对实际标准路径，并保留收到的URL证据；数值/源目录约束未变。部署测试最后重复局部变量名已修正；没有删断言或降低标准。
- 独立部署扫描v1误把Mach-O安装ID/通用架构标题当成加载依赖；v2按LOAD/RPATH分离，发现上游wheel残留构建机搜索路径。动态614映像证实这次导入未加载包外第三方库；不宣称所有延迟导入/其他Mac/恶意预置构建目录均已验证，发行前bundle搜索路径加固另列。原静态失败报告保留。
- 首次App命令沿用测试coverage选项而被Xcode拒绝；明确移除测试专用选项、指定本轮结果目录后完整编译通过。独立swiftc需显式新SDK；不改全局设置。Xcode曾生成系统临时错误报告/性能诊断（包括现有pipe reader的QoS等待告警），不能声称工具绝无系统临时副作用；无新应用数据/源代码变化。
- 成本记录只保存各轮可观察墙钟与原始运行记录，未把累计token快照相加、未重算历史样本；完整Lead归因、隐藏路由与实际订阅费用unknown，本批不证明成本最优。

### H22与恢复检查点

已完成：候选实现、代码审阅、组件/完整工作台CPU、真实headless闭环及独立数值、取消、输入/导出保护、App编译。未完成：普通签名封装后的沙盒GUI、实际用途确认/取消、中文组字缩放、正式样本人耳试听。H22在集中清单；用户回来时一次办理，不重复询问机器空闲/下载许可或唤醒锁屏。

源生产代码仍4ff基线，只允许同步这次状态文档；源个人scheme原内容/摘要 `ca3635d88aa5a15397b90e528667c66c0e6db7e596176e885c79d194b544206c`、索引blob `9c76916bdc97c2d4298cefe64e0b0fae3380573e`和未暂存状态保留。普通D/既有作品/旧证据未操作。所有本批自有执行、模型与测试进程结束后才写最终回执；其他历史pending_init不据此宣称结束。候选/证据不清理，未推送。

恢复先读 `final-receipt.json`，核当前源/候选HEAD、索引、个人改动、进程和H22，再用隔离签名产物/项目处理GUI。通过后按既有规则合入已解释的源文档快照、复验必要入口、快进接纳并推送工作分支；不跳过冻结GUI门槛。下一产品提案仍为HUM识别结果的必要纠错→普通音符试听→MIDI导出，复用已存音符数据，不再增加歌声高级编辑器，不以视频高级修复/所有文本增强为前置；本轮未启动。
