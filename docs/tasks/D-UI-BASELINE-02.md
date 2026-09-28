# D-UI-BASELINE-02：原生双入口与共享资料库

2026-09-28 · r2 · 隔离实现与分层验收中。用户批准U0—U4连续实施，不公开发布/main。基线源01758b81527dc27eb4563bf1b66fd1ceab6647ee；已推前端395378116d39899d138df797b4e39bd1aea917a4。复用原候选物理树，新分支codex/ui-baseline-02；旧分支/证据保留。

## 本轮事实与保护
附件所有摘要已核对；持久只读副本R/reference-package。浏览器file导航被策略拒绝，未绕过。用户明确回复“允许先按截图和规格实施”，替代本轮HTML浏览器走查前提；不能记成实际原型交互已验。已查看两张1440×1004参照并读完整任务/验收和书面规格。

R=/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-UI-BASELINE-02/run-20260928T123204Z。源唯一个人scheme未暂存1→6、SHA256 ca3635d88aa5a15397b90e528667c66c0e6db7e596176e885c79d194b544206c、index blob9c76916bdc97c2d4298cefe64e0b0fae3380573e；before.json/副本记录。不得暂存/还原/清理。真实项目、模型、普通App、旧候选不迁移/覆盖；只用隔离试用记录。旧H28/QUALITY责任不倒写通过，不重置预算。

## 固定产品契约
顶部快速生成/工作流平等，共享资料库。快速当前一个模型：实名/精度/真实准备状态，左输入右结果，高级折叠；持久快速记录不要求命名项目。按模型/模式保留草稿；提交归属固定；页面切换不取消、不串结果。设置带图与结果带图两命令都不运行。保留普通长文稿/会话兼容入口，不强迫走图。
画布左紧凑共享库、中真实画布、右检查器；任务摘要底部，详细历史按需。同模型实例ID隔离、实名不被注释覆盖、真实端口/连线/撤销。默认不双资料栏+底部全表。窗口860×580仍能关闭/运行/返回；输入法键盘优先编辑器。
共享库从现有注册/模型安装/工具/资产投影：系统输入、输出、素材类型、角色、就绪分开；用户标签不改能力。标签稳定ID、批量编辑/撤销、手工分类多重归属有限嵌套、智能分类保存有限规则并动态查询；无新数据库/调度器/算法。来源未知不伪造准备。素材预览不先改图。原权重/媒体不移动、不复制来分类。

## 实施/所有权
Lead：根路由、展示状态、Quick持久记录/显式服务、模型准备、共享投影、真实Store接线、语言包、文档与验收。可复用WorkflowServices单次executeCall，不创建隐藏大图/第二运行时。
META受限Worker：仅新增Packages/UI/Sources/DWorkbench/Library/SharedLibraryMetadata.swift、Packages/UI/Tests/DWorkbenchTests/SharedLibraryMetadataTests.swift。给当前共享库消费的纯值查询和小型版本化元数据持久化；不得改ProjectStore/schema/旧标签。Lead负责接线/迁移决策。
CANVAS受限Worker：仅WorkflowCanvasView.swift、WorkflowGraphSurface.swift、WorkflowCanvasTransfer.swift、新UI/Views/Workflow/WorkflowNodeIdentity.swift、直接Tests/UI/WorkflowBaseline02Tests.swift。两栏+右检查器、实名/边交互、固定关闭、视口/选区恢复；不得改Controller/Store/runtime/Host/root/语言JSON。Lead合并统一本地化。
二者共同准确准备SHA由外部job.json补充。默认gpt-6-sol/high（当前原生Swift/状态复杂度；工具声明支持），独立CLI预检核实模型/写根/网络关后IMPLEMENT；单任务20分钟因有限UI切片，初交+最多2轮明确修复+一次有界Lead接管，旧任务预算不刷新。只读非实现者审关键Lead代码。

## 权限与验证
每任务只写自己树与R/task/output,tmp，网络关闭、不写共享Git、不构建App/GPU/GUI。允许xcrun swiftc -frontend -parse具体文件（无目标输出），测试由Lead串行。语法与行为分开。未预授权拒绝停报；不提权/另造缓存绕路。正常输出/临时目录预先固定。Lead串行CPU/hosting、正常签名构建、真实GUI和四模态短冒烟；不改签名/权限/全局设置，不把组件当原生。UX01—R02完整表见R/reference-package/02_ACCEPTANCE.md，逐项状态见R/lead/acceptance-results.json；不得静默缩范围。

## U0—U4与交付
U0基线/映射；U1尽早真实双入口原生闭环；U2资料整理；U3既有模态/下载导入；U4真实鼠标/键盘与三尺寸、资源/保存、最终普通构建。旧入口映射和实测版本后续追加。最终一个D UI v0.2 Preview及持久隔离启动器、同树D.xcworkspace/D Nodes Run、同尺寸对照、事件证据、逐项结果。UI_NEXT只收后续提案，未明确批准不扩展。U0准备时尚未完成新UI；以下为后续实际进展，不覆盖最初停点。


## r2 实际实现与审阅（2026-09-28）

本轮已在上述候选树实现原生双入口、Quick按模型草稿与独立尝试、共享资料库、固定工具/素材带入、紧凑画布与检查器。采用现有SwiftUI/AppKit、真实WorkflowServices、单个共享运行时与ProjectStore；未嵌入HTML或加入模拟模型。新Quick/共享资料整理是现有Store旁有版本的记录，不是第二套生成/资产系统。命名项目和自动创作拥有各自Store；跨项目引用显式复制并记录来源，模型和媒体不会因为分类而搬动。

### 实际允许路径与所有权补充

- Lead：D/DApp.swift、WorkbenchBootstrap/WorkbenchApplicationDelegate；UI/State/WorkbenchModel；UI/Views/Quick/两文件、SharedLibraryProjection、WorkflowHostView；DWorkbench/Quick/QuickGeneration、ProjectModels/ProjectStore、ProjectSession、WorkbenchSession、WorkflowServices/Controller、WorkflowModelBookmarks、WorkflowMusicOperations；对应QuickGenerationTests/ProjectSessionTests、DTests/QuickGenerationRealTests、en/zh-Hans语言包与本任务/当前入口/试用/集中清单。
- 三个写任务均经现行受限独立CLI预检，`gpt-6-sol / high`；自己的树与输出/tmp，网络关闭、共享Git不写。配置与可观察上下文吻合；隐藏服务端模型解析unknown。具体文件与完整执行基线由R/{META,CANVAS,LIBRARY}/job.json、spec.txt、route-accepted.json追溯。
- META初交+1修复，在SAVE物理树完成并由Lead提交1a6c81e；结束写入后复用该树给LIBRARY，未同时写。CANVAS从984bd9f与META并行；LIBRARY从1a6c81e与CANVAS后续并行。各自分支保留。
- CANVAS初交+2修复结束，最终ebdb7fa；Lead有界修补两个SDK编译差异（CGFloat.infinity、非optional AX方法）。两项hosting仍失败，不能再给第三轮Worker或把未验控件写成可用。
- LIBRARY初交期间heredoc缓存写入被拒绝，Worker曾自行继续；Lead发现后终止自有CLI，记录R/LIBRARY/lead-incident.json、incident-resolution.json。未把旧行为追改合规；检查无观察到成功越界/权限扩大后，按显式限定恢复原初交，随后两轮修复至c560606。Lead接管修复撤销/外部删除标签后的陈旧筛选ID并增加反例，相关测试通过。详情保留在事件证据，未重置预算。
- Lead负责共享接线和重要保存保护，不能归为Worker独立成功。两个非实现者只读审阅逐项指出并复核模型能力投影、保存/引用保护、退出/最近项目、工具拖放问题；不是另有独立测试执行。摘要R/lead/review-summary.json；实际测试由Lead串行。

### 行为与已知边界

Quick提交冻结模型/输入/参数，切入口/模型不会取消或改派结果；失败尝试可从冻结输入重试并生成新ID；保存失败只重试保存。设置带画布与结果带画布是分开命令，不运行模型。不可解析旧记录进入只读保护，不自动当空记录重建；未加载坏记录也不阻止关闭应用。退出先完成自动创作的可撤销预检，再关闭命名项目。最近项目取消/失败不再仅凭旧manifest误判成功；恢复提示保留。

固定工具拖入无graph的工作区可新建一个流程并一次撤销；未知版本拒绝，不留下幽灵选中。资产跨项目复制复核内容与来源，并复核异步目标没有变化；结构化结果中的引用一起验证。共享运行时产物发布与项目发布各有所有权，不删除已交付图片。

资料库能力来自真实类型/固定目录投影，用户标签不改变能力。标签/分类/智能查询为有界元数据，重命名使用稳定ID、删除/撤销清理过期筛选；支持动态查询、多重分类和独立预览。未接新快速路径的SA3/歌声仍如实显示独立入口/不支持新路径，非虚构可用。未附新权重或更改现有精度。

**仍未关闭**：CANVAS离屏AX两控件无法触发（未分离查找失败/performPress拒绝），不能归因锁屏；整个原生鼠标、三尺寸、同尺寸对照及用户试用等待H29。新快速参考当前偏重导入和结构值入口，专业音符/区域编辑的完整可达性、历史实名展示、跨项目素材空画布拖放须在原生走查时逐条核对，不能仅以有控件宣布满足。旧H28/QUALITY、H22输入法跟随和历史性能/音视频质量责任保留，不以新UI覆盖。

### 已执行检查与失败保留

- `42aeeec84a3606d0dda89f508760b329278ebff8`：UI包完整检查，DWorkbench 647/81 suites与模型库23/1 suite通过；UI 201/31 suites中两方法、四断言失败，日志R/lead/full-ui.log。失败方法为WorkflowLocalizationTests.hostedCanvasSwitchPreservesDraftSelectionParametersAndControllerIdentity与WorkflowMediaPresetTests.actualCanvasHostsMediaInspectorsWithoutRunning。技术详情未打开后的字段缺失是级联，50/100的短路表达式未求值，不能算另两个实际参数错误。
- `1b080a7b7ef37e48f724dcfb8d0f9ec7acbb3bc3`：QuickGenerationTests、ProjectSessionTests、SharedLibraryBrowserTests 31方法/3 suites通过（R/lead/focused-final），含新增工具空图插入/撤销、非法最近ID保持原项目。CPU不替代GUI。
- Swift 6.4真实测试编译在嵌套require及“require后直接调用异步闭包”处崩溃；将条件与调用分别赋值，保留同断言。app-test-build2/3失败，4/5通过。首次真实测试宿主/测试签名不一致；复用已有DevelopmentSigning.xcconfig的build6通过，没有修改签名设置。一次方法筛选实际选到0 tests，由外部PASS标记检查拒收，改为唯一suite选择。原失败与空执行日志保留。
- 真实图像测试的初次resolver漏传既有Klein配方，被执行层明确拒绝，未加载推理；测试按生产ProjectSession补同一配方，未改生产规则。build7受测`89fa56b`的完整值及后续真实结果由R/lead相应result.json记录；本段不提前宣布通过。

### 恢复/验收入口

R/scripts/run-check.py固定输出/tmp/超时、只回收自身进程。UI包使用已有离线scratch；App使用同一候选D.xcworkspace与既有资源配置，D scheme build-for-testing；普通交付使用D Nodes正常构建。R/scripts/run-quick-real.py选择DTests/QuickGenerationRealTests，实际生产Quick控制器+AppSessionFactory，逐模态独立测试记录、GPU串行；不是鼠标GUI、试听或艺术质量验收。

R/lead/acceptance-results.json按原UX01—R02列全；原生未验不能据CPU升级passed。完整最终源码/产物/签名、模型实测及源保护、进程状态在final-receipt.json；本文不为写自身SHA反复提交。源仍01758b8，个人scheme摘要/索引和差异由保护记录逐项核对；候选未快进接纳，AP1/CORE/I2V不动。

预算记录使用逐进程墙钟与每phase原始用量证据；不累加累计token快照、不换算订阅费用。完整Lead与订阅成本unknown。本轮不宣称低成本最佳或所有普通交互通过。接下来只完成本批准范围剩余验收/缺陷，不启动新的产品阶段。


### 当前实际停点：2026-09-28 受测代码89fa56be3237f7be2955b3d6834e8110c3e87e07

- `focused-final2`最终相关31方法/3 suites通过；与完整测试42aeeec的范围不相加成全量最终通过。
- `quick-real-{text,image,music,video}-final`分别1项真实测试通过。模型固定版本见R/lead/real-summary.json：Qwen1.5B4bit约1.47秒、Klein512²/4步约26.04秒、MRT2无音符4秒约3.34秒、Wan320×192/17帧/4步约107.28秒。此耗时从会话创建后到生成/导出/关闭前后，不是模型纯计算基准或首音延迟。没有降精度、更换模型或扩大内存硬门槛。每项验证冻结输入、生成中切草稿、资产可读、空闲状态、结果入图不运行、导出和重开；非真实鼠标/听感。PNG另由Lead看图确认红茶壶输出。
- `normal-app-final`在相同代码正常构建D Nodes通过；完整复制到`R/delivery/D UI v0.2 Preview.app`，不是手补运行时。diagnose-app只读检查签名完整性、既有sandbox与identifier通过，未证明Gatekeeper/公证/TCC/GUI。`final-delivery-identity.json`记录二进制/资源封印摘要及稳定试用身份。
- 非实现者在89fa56b对最后窄差异复核无新增P1/P2；服务错误展示已闭合。原CANVAS两个hosting失败与原生锁屏仍独立保留。R/lead/review-summary.json补最终结论。
- CUA收尾真实返回Mac锁屏、无法自动解锁（R/gui/blocked.json）。因此U1—U4的原生可用性、同尺寸截图和用户试用没有完成；不因真实模型通过宣布v0.2已验收，不快进源。阶段状态：**部分完成，隔离开发候选可供恢复验收；不是交付验收通过**。
- 唯一推荐入口/完整步骤见[当前试用](../NODE_LANGUAGE_TRY.zh-CN.md)及R/delivery/使用说明.md；旧Early/Canvas/Quality包保留但不作当前推荐。当前新增UI控制不得当作已验版本替换源。
- 恢复：先核源01758b81527dc27eb4563bf1b66fd1ceab6647ee、候选最终文档SHA、scheme真实摘要/未暂存、已结束Worker与自有进程；解锁后续同一批准范围H29。普通代码/构建工作无需用户逐条转发；若控制缺陷需要超出既定修复预算，具体说明剩余问题，不能暗开第三轮或以新编号刷新。


## 2026-09-29 解锁后原生验收与一次有限宽度修补

状态：**部分完成，锁屏已解除；审计候选仍有工程与验收缺口，未源接纳**。本节是当前停点，上面的2026-09-28锁屏/待批准记录原样保留。R1=`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-UI-BASELINE-02/run-20260928T144932Z-native`。输入候选HEAD `2b816bb9fa2e719a5e30cc3e9071c6a9cec24942`（生产包89fa），本次受测代码 `e4fe2f3e405d59a977d715464ab1c583341f8ae0`。源仍01758b81527dc27eb4563bf1b66fd1ceab6647ee；两者不是同一接纳分支。

### 实际发现、授权与最小修改

原生发现资料库左侧裁切。非实现者确认SharedLibraryBrowser紧凑内容240点，WorkflowCanvasView外层220点且clipped；原任务边界两侧数字冲突，属Lead整合责任。CANVAS/LIBRARY原预算已用完，因此未私开第三轮；用户明确批准“一次额外有限修补”，仅将WorkflowBaseline02Policy.libraryWidth的220改240（e4fe一行）。没有新写Worker、模型/存储/签名/权限变化。剩余缺陷不自动取得额外修补授权。

非实现者baseline02_canvas_review核对固定差异、两个result及日志：21项/2 suites和普通D Nodes正常构建确实执行并退出0，无重叠；此21项不含原两失败方法、也不直接断言裁切，因此原生观察单列。Lead同时实施与运行验证，不声称独立模型执行了测试。完整Lead用量及订阅费用unknown，不重算历史成本。

### 原生结果与范围

| 检查 | 实际结果、版本与边界 |
| --- | --- |
| 双入口/资料库/退出返回 | 正常从Finder启动固定启动器，Quick/Workflow与完整资料库可打开返回；原生截图在R1/gui。并非所有弹层/全部路径已验 |
| 真实Quick文字 | 89fa中原生导入现有Qwen1.5B4bit、输入提示、48token、点击生成后切Workflow并返回；看到真实结果。run839E8B28-AF46-4E0B-9A7B-0D0CBD2D8F3C；历史输入冻结，没有被后续草稿覆盖。四模态控制器旧证据不升级为本次四模态GUI |
| 连线与状态 | 89fa实际点击文字边查看source/target/type/not-run；断开后Undo恢复同一边。文字技术详情可打开。未覆盖音视频详情/全端口拖连/键盘矩阵；原hosting失败继续保留 |
| 重开 | 同一df754b88-0763-480b-864c-74c40057c7e8身份正常退出89fa，再从新启动器打开e4fe；Quick真实结果、人类输入草稿、已保存流程恢复。标签/分类/智能查询的完整重开矩阵未实测 |
| 宽度 | e4fe在1440×900、1024×768、实际860×612点下左侧搜索/说明不再裁切。请求860×580被现有最低高度限制；不记成精确580通过。两种批量菜单可打开但标题“批…”仍省略 |
| 拖放 | 50/100/180%下CUA资料库行拖动未观察新增；＋可在可见画布添加，内部节点能移动/撤销。本人100%对照答“有预览，但未新增节点”，失败得到确认；没有把替代动作标成资料库拖入通过。50%图外ScrollView空白与图内容接收区不同，记录为可能边界，不未经证实判全部根因 |
| 本人IME | 用户答“候选窗不跟随，选字正常，未观察到丢字或重复。”当时普通包89fa。H22跟随未修复；本次宽度修补不改变IME。无需再重复同一检查 |

受测e4fe：R1/lead/compact-width-tests/result.json与output.log，21项/2 suites通过；normal-width-app正常D Nodes构建通过。新App从构建产物完整复制，app-identity.json记录四关键文件摘要/签名/稳定试用身份；未在包内手补资源。真实模型执行/CPU/hosting/GUI/本人反馈不相加成一个总通过率。

### 交付、剩余责任与恢复

最新唯一启动器是R1/delivery/启动v0.2工作台.command；同一工作树D.xcworkspace/D Nodes可正常构建。本次未再次实际Xcode UI Run。R1/lead/acceptance-results.json保留UX01—R02完整条件，每项分别列状态与未覆盖；不是删减必做项。R1/lead/native-continuation.json为本次实际观察；native-progress.json保留为初期快照，不代表最终结果。

H29已不再被锁屏整体阻塞，但未全验：原两hosting失败、资料库拖入/全部缩放滚动反例、全元数据交互、其余三模态原生Quick、准备失败恢复、性能和用户R02路径尚未通过。H22是工程缺陷；没有新密码/系统权限/设备申请。旧H28/QUALITY责任保留，AP1/CORE/I2V不动。可向GitHub同步审计候选，不能快进源或宣称本阶段交付通过。

最终仅文档HEAD/远端、scheme内容/索引/未暂存前后核对、旧/新App摘要及进程状态写R1/lead/final-receipt.json。源个人scheme仍由保护快照逐项核对，不纳入任何提交。候选/旧证据/试用数据保留。本次真人拖放区分已收齐；没有新的本人操作/权限请求。限定修补完整复验未通过，停止该项进一步修改，停在用户审计试用边界；任何尚需修补按真实失败和已有预算处理，不以新编号重置。

收尾实例：原生保存显示成功后正常退出。随后一次绑定窗口AX读取又显示空白Quick窗口（未编辑/生成），不能当作重开成功证据；再次正常退出，CUA库存显示D不运行，最终再用任务级进程查询核对。此工具/生命周期异常原样记入R1/lead/native-continuation.json，不修改或清理真实偏好来消除现象。


## 2026-09-29 r3：用户明确批准已知缺陷收口

新授权：将上轮列出的已知缺陷修补收口，自主测试；本人输入法/解锁/操作只进入集中待办，离机不催问。它明确允许继续上轮已停的缺陷，但不追改CANVAS/LIBRARY旧修复预算与失败，不新增产品范围。基线 `ebb88c76baac5adff4d9aeaeda2028d75166f652`；源01758b8及scheme保护保持。R2=`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-UI-BASELINE-02/run-20260928T160457Z-defect-close`。

本次范围：①资料库有拖动预览但不插入，覆盖50/100/180缩放与内容/视口坐标、取消/撤销；②H22坐标更新的真实接线，保持marked text/选区与回调归属，最终真人中日IME留集中清单；③原两个hosting失败，定位框架/测试/产品因素，不删断言或把实际触发改为直接调用业务方法；④与本轮直接相关的窄栏菜单省略/最低可操作布局。上轮退出后bound AX再显空窗是已知工具调用副作用风险，本轮正常退出后仅用库存/自有进程核对，不改产品来掩盖。

Lead负责实现和串行测试；两个非实现者并行只读检查拖放/hosting与IME/Apple契约，结束后审固定差异。复用现有隔离候选，不新建主会话、不派全访问写Worker。对每个已确认根因作一次局部修补及最多两轮有明确失败原因的本轮定向返工；若需要改存储/推理/系统权限或大范围重写，停止相关项。历史计数原样保留，绝不用r3证明旧预算通过。

允许文件：Workflow/WorkflowCanvasTransfer.swift、WorkflowGraphSurface.swift、SharedLibraryBrowser.swift、WorkflowCanvasView.swift；必要的既有TextSelectionEditor.swift、TextSourcesQuestionEditor.swift与D/WorkbenchApplicationDelegate.swift；对应UITests的WorkflowBaseline02Tests、WorkflowLocalizationTests、WorkflowMediaPresetTests、SharedLibraryBrowserTests、TextSelectionEditorTests、TextSourcesQuestionEditorTests及DTests/WorkbenchInputGeometryTests。确有当前调用者时允许一个局部输入几何辅助/拖放回归文件；不得触及ProjectStore/schema/运行时/模型/工程签名。四份现行记录和R2证据由Lead维护。发现范围需要扩充先说明依据，不静默扩大。

原失败先保留/复现；测试只写R2/tmp、lead、cache及既有独立scratch/DerivedData，离线依赖，无真实用户项目。生产推理未改则不机械重跑全模态GPU。最终普通包另存R2，旧包/试用记录保留；组件、hosting、原生、真人分别报告，真人未验不能宣布H22完全关闭。候选推送遵从既有授权，源仅接纳已验组合，本轮不公开发布/main。

### r3 修补与锁屏恢复检查点（2026-09-29）

状态：**局部修补已保存，缺陷收口未全部完成**。受测代码`e546762dd9cafd46d0b99d8f360331393a7e95e6`；本节之后最终文档提交见R2/lead/final-receipt.json。源仍01758b81527dc27eb4563bf1b66fd1ceab6647ee，候选继续codex/ui-baseline-02；不源接纳、不宣布H22/H29通过。

| 项目 | 已确认原因/改动 | 证据与剩余 |
| --- | --- | --- |
| 输入几何 | 主队列更新在tracking模式迟到，且只访问root responder，漏掉attached sheet。改为default/tracking/modal RunLoop并在交付时重新取当前sheet与responder；无文本提交、无缓存旧焦点 | 新2方法在旧实现失败；最终5方法通过，含sheet关闭后一次回到root、两个嵌套模式、关闭取消、Unicode/选区/undo保护。`geometry-before`、`geometry-after`、`geometry-final`；**不等于真人候选窗已跟随** |
| 拖放拒绝 | 本机新SDK将节点/端口闭包选择成Void新重载，丢弃Bool返回。明确4处节点/端口/标签/分类的CGPoint/Bool，表面增加自身矩形命中区域 | 编译成功、不再出现对应unused-result警告。真实provider原始data、Transferable、String均通过；提取由实际行调用，传输行为未变。**尚未证实资料库拖入100%失败的根因或修复，50%图外空白仍待定位** |
| 两项hosting | 原地复现；显示/key窗口、NSApplication初始化、公开AX子树诊断与单独运行均未解决查找，实际本地树只见AppKit承载控件，没暴露目标SwiftUI虚拟按钮 | 诊断修改撤除，原测试/断言逐字保留；`canvas-regressions`49项中47通过、2方法4断言失败。不能将旧原生文字详情/连线通过扩大成音视频或此包GUI通过 |
| 原生/启动 | 旧R1包再次拖入无新增。诊断启动器带输出重定向返回LaunchServices -10810，未进入指定session；工具getApp随后另启了无session诊断实例，仅看到默认Quick，未编辑/生成，正常退出 | `native-stop.json`、`diagnostic-start.log`。不将其当正确隔离验收；之后CUA明确报告Mac锁屏，停止GUI。只读进程确认无D。**-10810原因未确认，不能直接归因锁屏或缺权限** |

最终普通D Nodes构建`normal-final-app`成功。新包R2/delivery/D UI v0.2 Repair.app从普通构建完整复制，未手补内容，签名检查通过；四关键文件摘要见app-identity.json。唯一下一次集中验收入口R2/delivery/启动v0.2修补验收.command（语法通过，尚未原生启动）；不带诊断重定向，沿用df754b88-0763-480b-864c-74c40057c7e8试用身份。旧R1包四关键文件与其历史摘要一致。

49项执行在提交前固定工作内容，UI生产及UI测试与e546762dd9cafd46d0b99d8f360331393a7e95e6完全相同；之后仅加强输入几何测试，再于上述完整SHA编译、执行5项并普通构建。未重跑GPU/模型，因为执行/数值/存储路径未改。没有把49和5相加成全项目通过率；原34条验收状态复用R1并在R2补增量，不自动全绿。

Lead实施；baseline02_canvas_review、baseline02_services_readonly只读复核，未另造独立测试结论。后者指出sheet空交付/RunLoop等待证据缺口，Lead已加强测试并复验；没有生产返工轮次或新Worker预算重置。此前两个hosting工程接管的失败保持。本轮语法编译曾因beginSheet async重载失败，改明确completionHandler:nil后通过；不是生产根因或权限事件。模型/订阅精确成本未归因，不重算历史。

恢复顺序：核对源/候选HEAD、个人scheme和任务进程；解锁后先确认启动器实际启动成功、进程路径与D_UI_TEST_SESSION正确，再绑定工具，避免getApp隐式另启无session。补实际drop命中/provider/scope证据，完成拖入/缩放/Undo与控件UI对照后继续工程修补；需要本人仅解锁、必要时手动启动和一次中文/日文候选跟随。**两项hosting属于Lead工程/测试问题，不能交用户点击当作修好**。窄栏批量菜单省略与完整原生矩阵仍保留。无新权限申请，不启动下一阶段。全部候选、源个人修改和证据保留。
