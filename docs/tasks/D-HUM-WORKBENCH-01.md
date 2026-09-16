# D-HUM-WORKBENCH-01：有限音符纠错与交换工作台

状态：HW1-CLOSE2机器验收通过，H23普通运行/真人验收待办；候选未接纳。2026-09-16；规格/契约 HW1；batch 同 task；run `run-20260916T054351Z`。
源基线 `3898e1d020cbc356417e04e7c9f761db1a910725`；上一受测代码 `8bfca7803613a46d78e77bc5fce1462167e92087`，其后仅五份结案文档。执行准备 SHA 写外部派工记录，不自引用。

## 目标与边界

在项目→音频→已保存原声→音高识别中，保留分析后修正单个错音、删除误识别、撤销，普通音色试听、MIDI导出并安全保存重开。原声、模型轨迹与人工解释分开；不把改音符写回模型置信度。复用 HX1 编码/安全发布，不改 backend、权重、识别参数、音符时值、节拍或量化；不做加音符、谱面、DAW、歌声入口、跨模态编排。

## 冻结行为表

| 原状态/输入 | 操作 | 结果 |
|---|---|---|
| 已接受且原声版本一致 | 改一个音符 MIDI 0…127 / 删除 | 新人工解释 revision，原子保存后更新UI，原始轨迹/声文件不变 |
| 未接受、拒绝、跨文档、原声/选区或未提交输入已改变 | 编辑/试听/导出 | 不执行，旧结果保持；重新保留有效分析 |
| 当前解释revision与按钮捕获版本不符 | 迟到编辑/保存面板回调/试听完成 | 拒绝或丢弃，不操作新文档/新解释 |
| 操作无效（越界index/音高、重复删除、改已删除音符、无效同值） | 编辑 | 明确失败，不新增revision或吞错 |
| 有人工操作日志 | 撤销 | 撤销最后一条，仍创建新revision防ABA；保存重开后也可撤销 |
| 没有操作/全部音符已删 | 撤销/试听 | 前者不可用；全部删除允许保存，试听/MIDI明确无音符不可用 |
| 保存失败/取消发生提交前 | 编辑 | 内存与已存解释不变；不得覆盖原声或旧清单 |
| 发布后才报告错误/取消 | 导出 | 已交付文件保留，说明状态，不删除 |
| 导航、改原声、开始识别、停止试听 | 在制试听 | 取消编码，等待退出再清自有临时文件；迟到播放不得启动 |

时间基固定为原分析选区相对16k样本。最多256条撤销操作为本编辑器有限保护，非模型或Mac内存上限。不截断历史；满额明确需先撤销，不静默遗失。轨迹生成算法和现有HX1 MIDI/WAV字节行为不变。

## 数据/格式所有权（Lead）

歌声隔离候选 `c01d47e1fd8f406b35c2f9a4bdf759c6faaa95d9` 已占用schema13且H22未通过。本候选使用schema14；读取1…12及14，明确拒绝13而非丢弃歌声字段。v12迁移先保存原字节备份；旧读者拒绝14。之后歌声接纳须在隔离合并中统一13→后续格式迁移及HUM字段，不能将本批误称已兼容歌声13。现源不提前升级。

`PitchDocumentState`可选`noteEdits: [PitchNoteEdits]?`，每个已接受分析asset至多一份。Lead负责manifest强验证、Store、Session、WorkbenchView/Model和迁移。不存在记录时用原分析，首次revision为analysisAssetID；每次成功编辑/撤销新UUID。原声draft revision不因人工解释变更；旧分析及其改动保留但过期禁止新操作。

## Worker DOMAIN：Sol/high

仅可修改：
- `Packages/UI/Sources/DWorkbench/Audio/PitchNoteEdits.swift`（新）
- `Packages/UI/Sources/DWorkbench/Audio/PitchMIDIFile.swift`
- `Packages/UI/Sources/DWorkbench/Audio/PitchNotePreview.swift`
- `Packages/UI/Tests/DWorkbenchTests/PitchNoteEditsTests.swift`（新）

冻结公共形状（可自由选择内部实现）：
- `PitchNoteEditAction: Codable, Sendable, Equatable`，`case setPitch(index: Int, midiNote: Int)`、`case remove(index: Int)`。
- `PitchEditedNote: Sendable, Equatable, Identifiable`，`id: Int`为原始解释index，`note: PitchNote`为当前音高/原时值；`isPitchEdited: Bool`。原始confidence保持且只代表识别分数。
- `PitchNoteEdits: Codable, Sendable, Equatable`，`analysisAssetID: UUID, revision: UUID, actions: [PitchNoteEditAction]`，只读属性；`init(analysisAssetID: UUID)`初始revision=assetID、actions空。
- `func notes(result: PitchAnalysisResult) throws -> [PitchEditedNote]`完整验证日志和result，≤256、稳定index、顺序/时值不变，删除不重排id；允许最终空。
- `func applying(_ action: PitchNoteEditAction, result: PitchAnalysisResult) throws -> PitchNoteEdits`；`func undoing(result: PitchAnalysisResult) throws -> PitchNoteEdits`；无动作撤销抛错。每次返回新revision且输入不变。
- 允许Lead用JSONDecoder解码后强制notes校验，非法/过长日志不能被当空。
- 新编码重载 `PitchMIDIFile.encode(result: PitchAnalysisResult, edits: PitchNoteEdits)` 与 `PitchNotePreview.encodeWAV(result: PitchAnalysisResult, edits: PitchNoteEdits)`；复用原编码算法，禁止造新result/改frames模拟纠错。旧入口保持字节等价；新入口无改动输出也等价。不得接受未校验任意note列表公开入口。MIDI不额外嵌入私密数据，人工来源由项目记录。

必要测试：改错/删除/撤销/保存JSON重开回放，稳定index（删0再改1），ABA revision变化，边界0/127及-1/128，重复删除/同值/越界，损坏/过长日志/无动作撤销，全部删除，原result不变，旧/空edit编码字节等价，改pitch后独立MIDI事件及WAV读回频率/休止。纯CPU，不播放。

## Worker VIEW：Terra/medium

仅可修改：`Packages/UI/Sources/UI/Views/PitchNoteEditorView.swift`（新）及`Packages/UI/Tests/UITests/PitchNoteEditorViewTests.swift`（新）。不依赖DOMAIN尚未生成的类型。

定义public `PitchNoteEditorRow: Identifiable, Equatable`，只读`id:Int,midiNote:Int,startSeconds:Double,endSeconds:Double,isEdited:Bool`及public初始化；public `PitchNoteEditorView(rows:[PitchNoteEditorRow], canEdit:Bool, canUndo:Bool, isPreparing:Bool, isPlaying:Bool, status:String?, onSetPitch:@escaping(Int,Int)->Void,onDelete:@escaping(Int)->Void,onUndo:@escaping()->Void,onPreview:@escaping()->Void,onStop:@escaping()->Void,onExportMIDI:@escaping()->Void)`。

所有行可访问（LazyVStack，不截前12）。每行清楚音名/MIDI、秒区间，升降半音按钮及删除；上下限禁用，允许明确pitch选择可自行决定。全局撤销、普通音符试听、停止、导出MIDI；canEdit=false所有变更/启动禁用，停止在isPreparing/isPlaying可用；预览/导出还需rows非空且未准备；准备时编辑/撤销禁用。展示自动保存、改动属于人工解释、普通合成音色不还原原声，空列表可撤销恢复。不要暗示可AI修声/量化/歌声。原生SwiftUI/.glass、ViewThatFits或可换行布局，最小宽度不硬塞长HStack，不新增持久化/IO/Task/device/网络。行为门禁提取internal纯函数供测试，回调也核验门禁而不只是disabled。

## 执行、审核与验收

两个实现任务独立外盘工作树、共同准备SHA；不递归，共享Git只读，Lead停写后显式提交。请求/实际model/effort与workspace-write核验后才IMPLEMENT；网络false，唯一写根工作树及各run/output/tmp；无GPU/GUI/模型/安装/签名/配置/全构建。无授权路径读取失败/异常环境先停报，不能猜替代路径；只读索引用明确rg路径。Swift局部parse允许确切Xcode toolchain swiftc、`-module-cache-path`任务tmp；禁止py_compile，用tokenize.open+compile内存检查。行为测试由Lead串行完整包执行；Worker可写测试、不通过改标准过测。每任务初交+两轮针对性修复；随后一次有界Lead接管，重要实现非实现者审核；旧歌声/I2V预算不改。

Lead验收：全UI包回归（旧3条件跳过单列）、组合Session流程/迟到/取消/保存失败、Store migration/unknown13/来源/原件摘要、Apple MIDI/WAV独立读回、App隔离编译。当前本人离机，普通签名GUI/原生输入/人工试听未完成就登记集中清单并保留候选，不默认启用或虚报完整阶段已接纳。不为界面变化重跑未变模型，不下载新材料。

证据：`D-Development/AgentTrials/D-HUM-WORKBENCH-01/run-20260916T054351Z`；请求/路由/进程/差异/测试/审核/版本及保护均按原规程，旧证据不覆盖。普通D、个人scheme、歌声候选不修改。恢复先核实际Git与任务状态；最终自身SHA写外部回执。


## 2026-09-16 机器验收停点（不等于阶段完成）

受测代码 `7dcb6aa67c6e15623d1c977297453d04a9595a2f`，候选位于 `/Volumes/CodexProjects/Codex/D-Worktrees/D-HUM-WORKBENCH-01` / `codex/d-hum-workbench-01`。源生产仍为 `3898e1d020cbc356417e04e7c9f761db1a910725`，本轮不接入代码、不推送。最终候选/源状态文档SHA见本run `final-receipt.json`，不在本文件自引用。

已实现：接受的分析→按稳定音符index改半音/删除/撤销；ProjectStore原子持久化后才刷新；旧页面/解释/选区回调拒绝；原声与轨迹保持；独立普通音色试听、停止/取消/导航释放；修正结果安全MIDI导出。v12→14保留原清单备份，拒绝独立歌声13，不宣称跨候选格式兼容。

| 检查 | 本次真实结果/证据（本run下） |
|---|---|
| 定向Session＋编辑器检查 | `lead/host-layout-final/result.json`：同7dcb6aa，exit0；8个UI方法＋1个Session方法通过。设备为注入CPU夹具，不发声；实际WAV经正式媒体读取器读取 |
| 完整UI package | `lead/combined-cpu-final/result.json`：同7dcb6aa，exit1。DWorkbench报告394项、无失败，其中3个既有模型条件项跳过，不计通过；ModelLibrary23通过；UI95项有1项失败 |
| 唯一组合失败 | `lead/combined-cpu-final/stdout.log:411`，`PitchNoteEditorViewTests.swift:113`缺少`pitch-note-row-79`几何回报。不是得到矩形后越界，也未证明用户窗口必然截断；组合验收仍失败，不能被定向通过抵消 |
| App装配 | `lead/app-build/result.json`、`lead/AppBuild.xcresult`：同7dcb6aa，Xcode27.0/27A266a，独立产物、离线既有依赖、CODE_SIGNING_ALLOWED=NO，exit0，58.477秒。只证明编译，不证明普通签名或沙盒运行 |
| 数据/交换与故障 | 上述完整包包含人工日志回放/ABA/上限/原件不变、MIDI经Apple事件解析、WAV经AVAudioFile及频率读回、全部删除/撤销、过期/跨文档、v12迁移备份/13拒绝、保存前冲突/取消和发布后错误、拒绝覆盖、试听错误/取消/导航清理；通过，不是重新运行识别模型 |
| 未执行 | 普通签名GUI、生产默认Caches路径下播放、同一实际窗口连续缩放/滚动、真人普通音符试听、外部软件打开MIDI；H23集中办理。没有新GPU/模型/录音/权限/GUI操作 |

原件检查不放宽。试听cache先遇`/var`符号链接拒绝，改realpath又被Foundation将`/private/var`标准化回`/var`导致“路径不安全”；证据`lead/host-diagnosis`、`lead/host-recovery`和`lead/path-probe.txt`。最终仅将自有可丢弃试听移至应用Caches目录；CPU测试显式注入外盘任务目录。按inode清理自有文件，未知替换/旁文件不删除。创建文件失败时可能留空的UUID缓存目录，是已知非阻断清理欠项，不扫描清理。生产沙盒默认路径仍须H23验证。

## 来源、预算、审核与失败经验

准备基线 `360b67ecd55c92424e1782bf0099af318f76de6c`。DOMAIN请求/实际可观察为Sol/high，独立线程`01a0a8c0-33de-7482-88fe-ad13b2381b5d`，初交`bca474a…`（完整值见Git与domain/candidate.json）；VIEW为Terra/medium，线程`01a0a8c0-33de-75f2-b55a-4c4937dc2248`，初交`bc89f9f0c914a50126dd6487b7aceb78d177e645`。两者真实实现重叠约122秒，目录分别为本候选路径加`-DOMAIN`/`-VIEW`；workspace-write仅自身树/output/tmp，共享Git不可写、网络false。预检/每轮观察见对应目录的process/observed JSON；服务端隐藏解析unknown。没有新的可观察权限拒绝/权限扩大事件。

DOMAIN零普通修复。VIEW两轮：repair1 `756fbbde15164fdf7c95ba849e4ab4ea58432680`修`canUndo`参数遮蔽；repair2 `1e16ddbb4542d683ba28b01e1638a8544ee1791f`补实际控件/末行几何证据。第二轮是Lead原`fittingSize`指标不足引出的验证补充，不把该指标不足归为已证明的布局缺陷。Lead有界接管修第二轮异类型scroll id（统一稳定Int），定向通过但完整组合仍缺末行回报：本轮停止该任务修补，不再派工/改名/扩大预算。

Lead拥有Store/Session/迁移/装配与直接测试：修正保存后错误说明、试听资源所有权、分析admission登记前await、实际controller输入ABA失效；两次Lead测试宏编译错误及两次cache路径失败均保留在`lead/combined-cpu*`、`lead/host-*`。这些不是Terra独立成功。`/root/singing_license_resolution`和`/root/singing_repo_integration_scope`按固定版本作非实现者静态复核；最终7dcb6aa静态无新增阻断，但他们没有另跑测试，末行组合失败仍成立。审阅摘要见`lead/stage-evidence.json`。

可复用经验：SwiftUI的理想尺寸不是可见性证明；一次Task.yield与固定0.3秒也不证明布局就绪。恢复时先按宿主代次记录“viewport/首行就绪→滚动发出→末行回报”，有界等待后保留原矩形断言，区分就绪、目标定位与观测缺失。当前仅有时序假说，未确认根因；不以单独通过、延长sleep或降低断言结案。

逐次运行墙钟及原始CLI用量保存在`lead/delegation-summary.json`；resume快照可能累计，不相加、不声称每轮增量。cached input包含在input内，不能重复加；完整Lead归因及订阅费用unknown。本样本不证明某模型普遍胜任或成本最优。

## 恢复检查点与首发位置

本次Worker及Lead测试/构建进程均有正常终止回执；没有归档替代进程回收。源schema与现有普通D未变；个人scheme仍未暂存，内容SHA256 `ca3635d88aa5a15397b90e528667c66c0e6db7e596176e885c79d194b544206c`，索引blob `9c76916bdc97c2d4298cefe64e0b0fae3380573e`。歌声候选仍`c01d47e1fd8f406b35c2f9a4bdf759c6faaa95d9`，未修改。

下一动作是本阶段一次明确的布局同步定位与组合复验收尾，须保留已消耗预算；不能直接换任务ID继续修。通过后H23完成普通签名/隔离项目的改音符→试听→停止→删除撤销→保存重开→MIDI，以及实际窗口缩放。H22与H23在本人返回时一起安排，但数据格式13/14的最终整合必须先在隔离区统一迁移并复验，不能直接合并互相的格式版本。

首发路线不变：有限HUM及歌声基础闭环→原预算内I2V缺口→一个实际能力组合→陌生用户首用/部署/恢复/发行准备。本阶段不启动这些后续任务，不把未验收入口默认启用，不把普通合成试听说成神经乐器或歌声。


## 2026-09-16 用户批准继续：HW1-CLOSE2

本轮明确批准继续下一步直至完成，不逐项停等；恢复原任务的布局同步定点收尾，不另编号、不重置旧Terra两轮及Lead接管历史。Lead亲自修改编辑器内部测试滚动入口及直接测试，非实现者静态复核；正常生产不新增自动滚动/调度器。保留真实控件边界断言，以同一宿主320→800→320的viewport就绪→顶端→末行的实际观测替代单次yield和固定等待。随后完整包与独立App编译；H23/H22真人部分仍集中办理，不在未验收时接纳生产。

起点：源`4cbef97c06c99938668413abc2949e99bdcdf9c7`仅较3898e1d增加五份上轮状态文档；候选`5a90f3fdc4a9e9a600390b192b88a1e44a02c4e7`较受测7dcb6aa仅任务文档。两处身份/保护已核对，证据新run `run-20260916T063026Z-layout-close`，旧证据不覆盖。允许本轮最终同步状态文档及本地候选；未通过普通GUI不默认开放新入口。


## 2026-09-16 HW1-CLOSE2工程收尾完成，H23待本人返回

本次用户续行授权已落实，未新建实现Worker或重置旧预算。Lead在原任务候选继续定点修补；同一受测版本`96f8fcdce8c4a60624d12338ffa9d83f2429c42e`的完整UI包和普通开发签名App均通过，前述7dcb6aa组合失败已由本次有效结果关闭。**机器验收完成不等于原生产品全闭环完成**：H23实际运行/试听未执行，代码仍不接入生产或默认启用。最终候选/源文档SHA与提交状态见新run `run-20260916T063026Z-layout-close/final-receipt.json`。

修补仅涉及`PitchNoteEditorView.swift`及对应测试：删除按宽度触发的测试自动滚动任务，不再假设一次yield完成布局；内部可选同步滚动命令默认无调用，离开清除。测试用同一NSWindow/NSHostingView完成320→800→320，每阶段等待当前viewport、滚顶部并观测工具栏/首行，然后滚末行。原坐标边界断言保留，等待只是有界deadline，未通过就失败；不修改数据、存储、音高算法、模型、试听生命周期或生产签名设置。

初次同步修补`df2c196e151df44ff281ed39fbca8682aa80604e`完整包exit0，但非实现者发现其缓存几何可能误通过，因此未据此结案。最终96f8fcd要求每个目标都有本次滚动序号之后的新回报，并加入旧/缺失观测反例。实测三个阶段最后一行分别为(16,403,288,87)、(16,403,768,87)、(16,403,288,87)，同一host；命令前序号41/138/211，目标观测分别均大于该值。完整记录在`lead/combined-cpu-fresh/stdout.log`。这些是离屏原生宿主几何，不是真人GUI或输入法结果；旧失败与初次测试证据缺口保留。旧缺失回报与布局未就绪的时序假说一致，但不宣称已重现每次旧失败的唯一内部根因。

| 验收 | 版本、方法与结果 |
|---|---|
| 完整CPU/离屏宿主 | `96f8fcd…`，`lead/combined-cpu-fresh/result.json`，exit0，63.122秒。DWorkbench报告394项、无失败，其中3个既有模型条件项跳过；UI96、ModelLibrary23均无失败。上述新鲜观测反例含于96项，不累加旧运行虚构总通过率 |
| 普通开发签名App | 同96f8fcd，既有`scripts/build-local.sh --offline`、独立OrdinaryDerivedData/日志、原机本地签名配置；`lead/ordinary-build/result.json` exit0，57.655秒。未改配置/Team/bundleID/entitlements，不下载依赖，不替换/启动普通D |
| 签名只读交叉检查 | `lead/signature/results.json`：已有diagnose-app报告exit0、直接codesign完整性exit0；Info与签名identifier一致first-test.D，观察到Apple Development链、app-sandbox=true，get-task-allow=true；后者不是“沙盒关闭”。未执行Gatekeeper、公证、TCC持久性或实际沙盒文件操作 |
| 原件/个人修改 | 普通D四个关键文件摘要/大小/mtime前后相同；源scheme字节、未暂存状态及index与上次相同；歌声候选c01d47e1fd8f406b35c2f9a4bdf759c6faaa95d9保持。见protection及最终回执 |

普通签名产物已放本run `lead/OrdinaryDerivedData/Build/Products/Debug/D.app`，包含可校验的D.debug.dylib摘要；这是H23后续使用的隔离产物，不替代普通D，不应使用真实作品测试尚未接纳的schema14。实际App默认缓存路径、原生控件/持续缩放/滚动、试听/停止、改错/撤销/导出/重开仍须隔离项目验收；真人只需确认普通音符变化和实际窗口表现，系统真有提示时再本人处理。

非实现者`/root/singing_repo_integration_scope`先指出旧观测误通过，再静态复核96f8fcd无新增阻断；其没有执行测试。Lead负责本轮全部修改及真实检查；历史Sol/Terra贡献和失败保持。根模型使用本会话现有设置未切换，未额外读取模型运行身份证据；本轮完整token/订阅费用unknown，不重算历史CLI快照。所有本轮构建/测试/诊断子进程已结束，无后台继续任务。

恢复：先读本run回执/`lead/acceptance.json`与保护状态，再核当前Git；H23在本人返回时集中办理，H22不重复催办。下一有限提案是统一歌声13/HUM14的候选格式与兼容迁移，随后同一隔离音频测试版集中H22/H23，避免连续两次更新项目格式；之后再按首发路线处理I2V缺口/一个实际组合/首用发行准备。本轮没有实现该迁移或启动下一批。
