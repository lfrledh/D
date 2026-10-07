# 当前行动与接手点

最后核实：2026-10-07。当前任务、基线、候选、阻塞与下一动作只从本页进入。历史记录不自动授权续跑。

## 当前授权：完整文字聊天专题 CHAT-PRODUCT-20261003

**持续工作条件（2026-10-07，最新指令）**：本人现可操作Mac，已做Finder拖入对照并确认原生缺陷；Lead已局部修补并准备同一动作复验，不重办旧输入/语音/权限。若再次锁屏只停对应桌面操作。旧输入、英语/朗读及未变模型证据复用，F26实调/凭据继续批准延期。仍为F01–F36；UI v0.2只归档和接线准备，不实施视觉或全局重构。

用户已批准 F01–F36、S00–S06 同一批实施。 2026-10-03再次授权连续续作：先用已有采样与可控流修候选菜单/交互迟滞，将停止固定在输入区主操作；允许S00/S01隔离组合验证，不等待旧布局全部修好。按本清单完成S02–S06（含显式采用部分回答继续），可靠切片正常接纳main后继续，不以阶段回执终止整项。需求冻结，不新增功能/模型/平台；Liquid Glass只沿用系统控件与语义层级，不全面视觉改版。唯一功能状态见 [聊天清单](CHAT_FEATURE_LEDGER.zh-CN.md)。先 S00 长流/停止、正常项目包选择和新候选/旧参数重现，再 S01 布局、S02 编辑与上下文、S03 资料/记忆/备份、S04 联网工具、S05 受限代码/MCP/成果/语音、S06 组合验收。可靠切片通过普通 App 门槛后正常接纳 main，不以整个专题完成为前提；不硬合失败长流。

2026-10-04用户补充决议已原位进入[唯一聊天清单](CHAT_FEATURE_LEDGER.zh-CN.md)：F26通用搜索服务边界、F31两语言本地识别与[功能完成后的质量审计](CHAT_FEATURE_LEDGER.zh-CN.md#post-function-quality-review)。该次只更新需求和现状；本轮已恢复代码和原生续作，先完成菜单/迟滞/主停止优先级，不启动全局重构；不把文档更新计作能力实现。

本专题早期起点核实候选 `40d51ee73f72eb54407e6eedbd693c9ba67068e4`、main `f31dced209855722d2f04cc0fc8c5f6712396120` 均干净且与远端一致。旧 inference-foundation 与个人 scheme 不动。A、H22、菜单、宏信任、HF 及自然视频本人结果复用；新存储和聊天宿主按影响另验。旧 B 失败和已耗预算保留；用户现明确批准这些已知缺陷继续收口，不再沿用旧停工排程，不伪造旧预算未使用。

Lead 持有共享 Runtime/WorkflowServices/ChatController/Store；文件面板和纯展示在独立受限任务树实施。早期S00/S01历史证据目录 RCP=`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261003T115108Z-chat-product`。完整 Lead 成本与订阅费用 unknown。早期S00代码完成CPU和签名构建，曾通过项目列表、真实1024-token接收和坐标停止→下一请求；当时菜单忙循环和生成中AX迟滞阻塞接纳。S01缩放焦点反例后来修复并通过hosting、与S00组合。以上是早期门槛来源，已被下述c16普通App复验和main接纳推进；最新S02–S05接线、R证据目录及剩余状态以以下恢复检查点为准，F01–F36范围不取消。

### 本轮：本人拖入反例与定点修补（2026-10-07）

- 起点`b5fee359cd7c344b901b26a01dd6025b3b1d912a`；新代码`d1ab5f71340bd4dcf764a80449e1d40be3306e05`，main仍`90819739e99b366d7cdb2f549c129eea28728206`。RDrop=`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261007T121440Z-human-drop`。真人在abd5输入框松开numbers.csv后，草稿出现完整路径、附件为零；绿色加号短现不等于导入成功。失败AX/截图及项目快照已保存，不再仅归为工具命中未知。
- 最小修补：仅聊天composer启用NSTextView文件拖放子类，按AppKit的dragOperation/perform钩子将真正file URL交现有importURLs；普通文字拖放/粘贴仍走原生路径，文件不插正文，marked/只读/拆除后不接收，不换输入系统或改Store/模型。Lead实现，非实现者只读复核。
- 验证：19方法/3suite通过，包括文件完整destination方法链、普通文字及路径/URL字符串与原生控件对照、组字/Undo及既有显示保护。首次测试stub编译和allowsUndo夹具缺失分别留证，修正夹具后重跑；不是用服务检查冒充跨窗操作。普通签名App构建与四关键文件/签名核对通过，App `RDrop/gui/D Chat Drop d1ab5f71.app`；真实修后Finder拖入、预览/保存冷开**待当前现场完成**。不运行模型。
- 失败草稿留在任务副本31890403会话；修后使用同项目9C77F56E会话及固定草稿，不覆盖旧样本。`lead/human-drop-failure.json`、`file-drop-code-review.json`、`file-drop-final-tests.json`、`file-drop-app-version.json`、`fixed-before-human.json`。原三项紧凑hosting仍是独立工程余项，未修改或重跑，不因此宣称转段。推荐启动器仍3cc；本轮仅定点修补测试包。

### 历史：解锁后的阅读与拖放验收（2026-10-07）

- 起点`90bb9303883f3fda6c0608fb6116a18f8958b813`；本轮最终代码/普通签名App **abd5f67ad01b5afb30d45ce1445b5bb313567014**。RDesktop=`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261007T104034Z-desktop-resume`；事实索引`lead/desktop-native-result.json`，最终仅文档/远端SHA与保护见`lead/desktop-resume-receipt.json`。main保持`90819739e99b366d7cdb2f549c129eea28728206`，候选尚未接纳。
- **已完成原生检查及小修**：旧9b6候选两个可见Apple链接的确认/取消保持位置，Bottom到末条、滚轮停止稳定；实际保存样例是24节而非旧文字中的40节。发现切换会话丢失长消息内部位置，1d5补只在导航时捕获的临时几何与版本门禁，两个内部位置往返通过。854搜索首次停表格、第二次才到标题；abd5按实际边缘/尺寸做有界校正，最终普通App第一次搜索即到标题/链接，取消后不跳，Section3切会话往返和输入x/Undo通过。没有更改Store、原文、模型请求或新增生成。
- **测试与剩余分开**：新增真实AppKit几何方法及会话/版本纯值方法分别通过；最终搜索修补经非实现者定点只读审阅并普通签名构建/原生反例通过。原5项动态hosting本轮2过3败，三项紧凑视口底部留白28.31–28.54点超过原28点断言；保留600ms后增加稳定采样仍失败，不改阈值、不当作误报。无效的hosting按钮驱动没有切会话，不计通过，patch/失败日志保留。不是同一组全绿或全部F05关闭。
- **拖放仍待有效命中**：已摆好Finder和输入区、使用公开drag；源窗跨窗尝试未形成附件，目标窗负坐标尝试报windowNotFoundAtPosition，仍无法确认接收前命中，不判产品拒收。不用选择器/粘贴/导入函数替代；一次本人最短对照只留原H32，当前不要求操作。Dev既有SSD选项已实际选择并冷重开保持，无新GPU运行。
- **交付与保护**：推荐启动器仍3cc71bee；新App仅定点候选，路径见[试用指南](RELEASE_FREEZE_TRY.zh-CN.md)。原18个项目文件、CSV摘要/mtime、原会话所有字段及个人scheme内容/索引/未暂存状态保持；新增两个空会话只在任务副本。全部自有D正常退出，Finder已回桌面；Terminal控制被工具安全策略拒绝，未绕过，已结束的启动器窗口可能仍在。历史17446旧子进程本轮查到并正常退出，纠正旧父进程回执的不完整记录。
- **精确接续**：原三项紧凑hosting仍属工程问题，须按已有几何/最后行证据定位，不能靠round或放宽28点；F19先完成有效跨窗接收证据再验预览/冷开。已通过的外链/内部恢复/搜索反例与Dev选择证据复用。未达到视觉转段或完整功能冻结，不把工程余项转给本人、不启动新UI。

### 历史：无桌面收口与UI接线准备（2026-10-07）

- 核实起点 **67ac49f3e54f22a3e78e1b6ffc77d38705821615**；本轮代码/最终CPU受测版本 **9b6c982b8c7188164279abc6760fef6f7a97c376**。候选分支`codex/release-freeze-01`；main保持 **90819739e99b366d7cdb2f549c129eea28728206**。RPrep=`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261007T061930Z-no-desktop-ui-prep`，最终仅文档提交、远端、保护和进程见`lead/no-desktop-ui-prep-receipt.json`。
- **实际小修**：FLUX.2-dev在R4已有SSD文本/DiT逐层消费者，但R3共享定义/recipe仍拒绝该值；本轮打通现有Quick/Canvas入口，保留默认staged、原始精度、步数/尺寸/条件约束。不改后端计算，不增加模型。Lead实现，非实现者定点审核；补正测试夹具关闭顺序并真实重开Store。
- 验证：合法256²反例在旧实现失败；修后9个CPU方法通过。审阅后仅改生命周期夹具，重跑该1方法通过（不是累计10项）；覆盖双入口staged/SSD实际请求捕获、非法值拒绝、缺值兼容、保存重开。首次SwiftPM入口被既有缺失pin阻塞，未安装/改锁；改用现成离线Xcode测试入口。普通签名App构建33.770秒、签名/副本四关键文件一致，**未启动、无GUI/hosting/GPU**。旧Dev真实50步/双参考/取消证据复用，不记作本轮新推理。`lead/dev-route-red-valid.*`、`dev-route-green.*`、`dev-route-reviewed.*`、`candidate-version.json`。
- A/B：复用阅读候选与既有审阅，当前代码未发现可独立确定的新缺口，**没有再改滚动/加日志**。文件URL接收后已有会话/Store保护、复制与取消边界；这不能证明Finder命中。静态接线与既有证据索引见`lead/independent-boundaries.json`，没有重复服务测试或用导入函数替代真实拖放。
- C/D：[九模型能力/消费者/节点/Quick及新区域接线映射](UI_CAPABILITY_WIRING.zh-CN.md)已完成，区分真实字段、单位、默认、联合条件、安装和既有验证；[用户UI设计v0.2](D_Quick_Generation_UI_Design_Decisions_v0.2_2026-10-07.md)原文归档。不是新的执行注册表，也不把准备项变成冻结门槛；27B已有四帧视频实测、LTX的F32调制表准确保留。
- 新审计包`RPrep/delivery/D Chat Candidate 9b6c982b.app`含旧2cd阅读候选及本轮Dev入口修补；**唯一推荐启动器仍指3cc71bee**，不拿构建代原生通过。Xcode当前树编译9b6代码，两者不同版，见[试用指南](RELEASE_FREEZE_TRY.zh-CN.md)。未接纳main，未功能冻结、未达到视觉转段。
- 精确接续仅在桌面条件改变后：①固定40节项目两个可见位置的链接→确认→取消，分别量定位/确认/取消位移，并复核新Reader的Bottom/搜索/会话恢复和已有5项hosting；②先确认工具跨窗坐标与Finder按住→移动→释放命中，再验附件/预览/重开、原文件不变及不自动发送。工具仍不能排除落点时才留最短本人对照。Dev选项与保存可并入受影响原生检查，不重跑模型或增加转段门槛。集中入口仍是[原H32队列](FAILURE_AND_PERMISSION_AUDIT.zh-CN.md)。

### 历史：Finder拖放与长文阅读定点续作（2026-10-07）

- 起点 **28abc23a58d11558c6baed9c87ef13e8679e13f2**；新代码候选 **2cd9a588dd6d2c6a1f567019222bf3290d847c17**，尚未接纳。RDrag=`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261007T004102Z-drag-reading`。最终候选/远端与保护见 `lead/drag-reading-receipt.json`；main仍 **90819739e99b366d7cdb2f549c129eea28728206**。
- F17已分清一次真实反例：普通滚轮停止后位置稳定；链接已在画面内，坐标点击→确认→取消，从开头跳到COPY-20（滚动条0.00621→0.45161），没有为找屏外链接执行AX点击。确认框出现可见，但截图只含表单，不能单独量出弹出时的底层位移。删除持续ScrollPosition绑定的单变量诊断保持原文位置（0.015822→0.015805）；仅改top锚点仍失败（跳Section18/19），两个诊断均不交付为修好。
- 新候选仅将原有主动跳转交给SwiftUI ScrollViewReader，首可见消息用只读可见性记录，保留懒布局、用户跟底意图、搜索/恢复票据及末消息Bottom。原旧Reader同时绑定scrollPosition；新候选没有该双路径，不是无依据恢复旧版。Lead实施、非实现者定点只读审阅；原生是否消除跳位/是否保持Bottom仍待验，不能据此关闭F17。
- F19：现有工具公开App.drag，但跨窗目标坐标/接收命中未建立可靠证据，窗口菜单定位还发生invalid element。没有附件出现，不能判D拒收；没有用选择器/粘贴/直接导入代替。34字节CSV的SHA/大小/mtime、原会话全部内容均与开始一致，没有自动发送。证据 `lead/drag-reading-evidence.json`、`drag-protection-after.json`。
- 候选普通构建与测试入口编译结果见 `lead/reader-final-signed-build.json`、`reader-final-tests-build.json`。Reader首次打开固定项目时工具报告锁屏；**新的5项hosting/普通App阅读与Bottom路径未执行**，不得沿用旧通过来判新滚动代码通过。仅已结束本轮自有App；本轮Finder/Terminal测试窗口因锁屏未完成关闭，恢复桌面后先核身份清掉自己的已结束窗口。
- 下一步：恢复桌面后Lead先在固定40节项目核可见链接取消的两个位置、Bottom/搜索/会话恢复与现有5项hosting；然后有据定位Finder→输入区拖放并验预览/重开。若工具仍无跨窗命中证据，唯一最短本人对照是一次实际文件拖入；不要求本人重做阅读定位、组字/试听。没有模型运行、新权限或视觉改版。
- **推荐包仍为3cc71bee**，唯一启动器不变；同树Xcode现在构建未接纳2cd9a588候选，两者不再同版，详见[试用指南](RELEASE_FREEZE_TRY.zh-CN.md)。两项尚未关闭，未达到视觉转段/完整功能冻结；F26继续批准延期。

### 历史：输入响应与视觉转段收口（2026-10-06）

- 起点 `d096dd5664beb593656fe16247eaead7c42c7332`；本轮实现/测试及普通App代码 **3cc71beecf13e70c7d6bce106172996c07daa210**。RQuality=`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261006T130047Z-quality-transition`。最终文档/候选远端、保护与进程写 `lead/quality-transition-receipt.json`；main保持 `90819739e99b366d7cdb2f549c129eea28728206`，没有把尚缺原生门槛的整个候选合入main。
- 输入：每次编辑重复查询系统声音约63ms，改为首次、系统声音变化及App激活时刷新缓存。修后对应局部body约0.17–0.25ms；固定编辑窗口中大于100ms的trace组15→0，窗口外另有139.5ms事件保留，不冒称按键到像素延迟。没有关自动保存、改历史或重建输入器；本人确认基本正常。
- 滚动覆盖：5项真实Controller/hosting及同次链接校验通过；replay验证跟底/末条，非replay真实离底、Bottom点击与末条可见，保护断言保留。9230冷开/搜索原生通过复用，旧无效滚轮失败不抹去，也不再作为当前无限停点。
- 具体尾项：普通App已补从选中消息分叉、自定义选段模板→PDF引用草稿、库成果采用、真实reasoning-only通道展示、CSV/SVG预览及系统默认朗读暂停/继续/停止。正常关闭重开后分支2消息、未发送草稿与2附件仍在；来源6消息/3attempt保留。跨项目83字节explicit-copy是10月5日既有副本，本轮只验采用，不冒称新复制。证据 `lead/native-tail-summary.json`。
- **剩余两项**：长单条40节Markdown在滚动/外链确认返回时跳到Section18/19；无卡死/数据丢失，但原因及真人/工具差异未明。两种局部实验均未改善，已撤去自有实验改动、保留patch与失败证据，最终包不含它们。Finder跨窗拖入一次未形成附件，工具坐标不足，仍缺有效拖入/预览/重开证据，不判生产拒绝。最短现场区分留[唯一集中队列](FAILURE_AND_PERMISSION_AUDIT.zh-CN.md)，本人当前不能操作，不催办；不重跑模型或已办授权。
- 唯一启动器原位指向 **D Chat Product 3cc71bee.app**；同树 `D.xcworkspace / D Nodes / My Mac / Debug`，普通签名最终构建39.955秒成功，交付副本与受测包四关键文件一致。路径和用法只维护在[试用指南](RELEASE_FREEZE_TRY.zh-CN.md)。自有测试窗口已正常退出，旧包/失败证据保留。
- **本轮尚未达到视觉转段/完整功能冻结**；不是被F26阻塞。Lead实现与原生操作，非实现者只读核对；没有新的写Worker或独立模型原生测试。全局质量重构、推理优化和Liquid Glass仍未启动。


### 本人集中验收补记（2026-10-06）

起点cbd4df7c73be3881a8b7f20a0ed0243b15535f6d；同一9230a6cd普通App，无生产改动。RHumanNow=`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261006T115611Z-human-queue`。英语en-US本人确认转写正确，Lead显式追加草稿、原录音/来源附件保存，正常退出重开仍在，无自动发送；Samantha系统朗读本人确认正常。旧失败保留，不说明其根因已修。输入/删除仍明显迟滞，约100ms不是测量；下一工程动作是核draft更新/保存实际负担。本人无需再重复本次检查。旧五会话/资产及个人scheme保护不变，自有App正常关闭；首次CUA绑定额外启动同版本实验包已留证并结束，不计验收。main保持90819739；最终仅文档/候选远端见本次`lead/human-closeout-receipt.json`。未功能冻结。

### 历史恢复检查点（2026-10-06，解锁后的Bottom与独立原生尾项）

- 起点c590b2a3460a342663d08cdc92cdb4f1e6c92512；本轮两行修补/受测生产代码 **9230a6cdabf40b540b17401d39b9ac64181cd265**。RNow=`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261006T110535Z-unlocked-bottom`。最终仅文档/远端、保护及进程见`lead/unlocked-closeout-receipt.json`。main仍90819739e99b366d7cdb2f549c129eea28728206；本轮推送候选，不把代表原生通过写成整个组合已接纳。
- 两项原replay已执行：初次被测试临时根`/var`安全校验拒绝，不是滚动结果；任务自有xctestrun明确注入既有`D_TEST_TEMP_DIR`后达到滚轮。两例同步boundsChanges=0、极值不变，未观察到先移动再回拉；**离底前置仍失败，不计通过**。原断言保留，没有猜换事件路由；`lead/driver-fixture-root.*`。测试驱动缺口与真实鼠标证据分开。
- 37b30普通App实际上滚/Bottom、离底会话往返通过，但随后搜索`Reply only OK.`卡死，留主线程sample。只改两处搜索定位`.center→.top`，目标UUID/ticket/跟随/保存不变；非实现者只读复核，普通签名构建通过。相同搜索命中→继续上滚/Bottom、跨会话命中、输入x/Undo及正常退出/冷重开后Bottom均可操作，历史与草稿保持。**原稳定冷开反例和本轮搜索失败在该包的代表路径通过**，不声称Apple内部唯一根因或所有滚动组合均通过；`gui/search-top-native-result.json`。
- F24个人记忆新增/启用/编辑/忘记/冷重开实际通过：隔离个人存储保留1–4版，项目不混入；未来读取恢复关闭。预览只显示估算，未新增模型记忆生成证据。F29普通App在途10秒夹具4.49秒时停止→断开→重连42→冷开保留两终态，通过；不自动采用，不声称远端副作用撤回。`gui/personal-memory-native.json`、`gui/mcp-native-result.json`。
- 唯一启动器原位改指向同签名内容 **D Chat Product 9230a6cd.app**，同树Xcode为同代码；旧ff20、0219、37b30包及失败证据保留。只是本轮开发试用入口，不是功能冻结。没有模型生成、真人组字/试听、全局重构或新UI。
- 下一精确动作：修正两个hosting事件驱动的有效离底覆盖（原断言不删），再核清F11短任务、F16通道、F19代表跨项目/拖放等既有具体缺口；已通过F24/F29及本轮原生路径不无因重跑。本人事项仅原H32体验、F31英语/朗读、F26凭据；当前不催办。用户项目、旧源scheme与main不动，自有App/服务均已结束，未新建Terminal。

### 历史恢复检查点（2026-10-06，无桌面Bottom定点续作）

- 起点 **856bb1ed811a33ca2498d25d7c49fbaa49cd9a8d**；本轮代码/测试 **37b30df22b11af1e8b5b621845fc935c7eca2369**。RFollow=`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261006T071736Z-bottom-no-desktop`；最终文档/远端版本与保护核对见 `lead/followup-receipt.json`。main仍 **90819739e99b366d7cdb2f549c129eea28728206**。
- 两项旧replay失败保留：滚轮前后offset相同、最终距底20点，但旧记录无法排除同一调用中先移动再回拉。直接调用 `scrollWheel` 不是正常窗口事件路由/真人等价输入；phase数值正确，旧目标仅取首个匹配。测试内现拒绝多目标，并同步记录选中clip的位移极值/次数；不改派发策略或行为断言，**未在本轮执行窗口测试**。不能将驱动不足当生产通过，也未证实生产拉回。详见 `lead/followup-evidence.json`。
- 修补一个可确定的独立缺口：异步恢复等待后重新取当前会话/分支，避免同会话换回答后向旧leaf滚动；ticket及搜索门禁保持。两项纯值测试通过（2.524秒），最终测试驱动编译通过（20.464秒）；纯值执行后仅observer queue由.main改nil，生产和所执行方法完全相同。非实现者定点审阅已收口；**这不关闭Bottom原生卡死**。
- **产物不混淆**：唯一推荐仍ff20f2bc，已知Bottom反例；旧0219f61b诊断App保持原样，不包含本轮修补。当前同树Xcode代码为本轮候选，尚无对应新普通签名App/原生通过记录；只编译UITests，不替换启动器。F13、F24/F29服务及其他有效证据复用，没有新模型/同质测试。
- 下一动作只在桌面条件改变后执行[唯一H32队列](FAILURE_AND_PERMISSION_AUDIT.zh-CN.md)的最短实验：先区分驱动无位移与位移后回拉，再用原保存项目冷开、实际滚动/Bottom验证行为，不生成模型。搜索/恢复/焦点、记忆管理及MCP等既有具体原生尾项保持；不重开已通过事项。本轮可独立执行工作已到精确停点，无桌面轮询或新的UI/全局重构；未功能冻结，不接纳main。

### 历史恢复检查点（2026-10-06，基本可用性收口，原生门槛仍开放）

- 起点 **fb77019ef40846b8b15972c8eede12f340c94d96**；新的**未接纳滚动候选代码 0219f61b204928feb83d36718a8bf4f0d46f5068**。只改 ChatWorkbenchView 的滚动所有者/跟随意图及原 hosting 测试驱动，不改模型、Store、历史和输入器。非实现者发现的恢复门禁缺失已补；不是已修好 Bottom 的结论。
- RBasic=`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261006T024827Z-basic-usability`。单一 UUID ScrollPosition 保留懒加载；跟随仅按用户滚动阶段改变，尺寸变化沿系统锚点处理。受控 replay 原来完成后距底116/177点，现为20点；新短流返回末条/历史、既有跟随策略、恢复ticket及输入pane焦点共4方法通过。两项 replay 的合成滚轮记录中前后offset相同（内部瞬态见上方续作），离底前置失败；断言未删，不能以4项通过抵销失败。详见lead/bottom-protection-tests、located-wheel-tests与bottom-readonly-review.json。
- 普通签名App构建通过（33.285秒），源码摘要与上述代码对应；CUA首次读取即明确Mac locked，**本轮未执行普通App冷开/鼠标验证**。只结束刚启动且未操作的自有实例90106，未重试解锁、未向本人请求操作。main **90819739e99b366d7cdb2f549c129eea28728206**、唯一推荐ff20包/启动器均不变；同树Xcode现在构建未接纳候选，两者不可混称同版。候选最终文档/远端SHA见RBasic/lead/basic-usability-receipt.json。
- F13核对真实冻结messages/parameters/inputs，没有矛盾指令；保留单次软格式返回schema而非对象的失败、原输出及既有人工采用→Canvas证据，不重生成。F01/F19/F34、输入热点、CSV及已有模型证据复用；没有新模型运行、泛增日志、全局重构或视觉改版。
- 下一步先修正/说明 hosting 滚轮驱动边界，再在桌面可用时用**现有保存项目、不生成模型**做上滚→Bottom→末条/响应、离底/恢复/搜索及焦点保护。原生尾项只补具体缺口：跨项目/拖放附件、短任务与搜索跳转、个人记忆管理、MCP在途停止/重连、通道展示；F24/F29最短步骤见唯一H32。英语、朗读听感和搜索凭据继续后置。未功能冻结，不硬合失败组合。

### 历史恢复检查点（2026-10-06，解锁后的原生补验）

- 起点/本轮源快照 **3d6c4fa4c21e65a9f9b21fd37618815f24f85e09**；有效生产代码/推荐普通App仍 **ff20f2bcfbf13b57836d62fd695954b726f4a010**。本轮新滚动实验未通过，已撤回本轮自有两文件改动、保存外部补丁；最终提交只更新下列事实，不替换App。main仍 **90819739e99b366d7cdb2f549c129eea28728206**，不硬合Bottom失败组合。
- RUnlock=`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261006T002853Z-unlock-native`。ff20普通App实际完成项目成果选择取消→添加→预览→移除→再加→冷开；移除仅待发引用，32字节原成果/版本及原历史不变。非实现者只读核对磁盘来源。证据gui/attachment-cold-reopen.json、lead/asset-native-review.json。三类非空草稿和图像参考冷开保持；仅一组已有Qwen3.5-9B Q4短冻结重现用于在途归属：文字运行时切图像，OK仍归原会话，原node/messages/inputs/system/seed、草稿和两个附件保持，其他分类没有新运行。gui/inflight-category-final.json；非全排列/非拖放验收。
- **Bottom工程缺陷仍开放，但已不依赖再生成或本人操作**：ff20在同一保存历史中冷开→上滚→Bottom也稳定复现（无生成，进一步排除分类切换必要性）；两份sample集中于GraphHost事务/懒布局，不能声称Apple唯一内部根因。仅去动画不卡但没到末条；单一ScrollPosition edge方案原生到OK但3项hosting失败；last-message方案send通过、replay跟底/离底前置仍失败，2项位置策略通过。没有放宽断言，未接纳实验。lead/bottom-experiment-decision.json、bottom-position-tests.*、bottom-message-tests.*，gui/bottom-{ff20-failure,no-generation,cold-no-category,position-native}.json。
- 下一工程动作从已有冷开反例和上述三种差分接续：缩小完整App与hosting的阅读位置/懒布局及原生滚动事件差异；先验证确定假设，不加泛日志、不重复模型请求。F01/F19/F34新增代表原生证据已原位写唯一F表；其余未验范围保留。英语后置/原声、系统朗读和输入主观体验、搜索凭据仅留原队列。
- 自有84335/84630/84846卡死时正常Cmd+Q无效，留证并核实路径后SIGTERM，不能称正常退出；后续冷开实例及两个实验App正常退出。本轮未新开Terminal，编译/测试/模型均结束，最终进程/个人scheme/远端SHA见RUnlock/lead/unlock-native-receipt.json。未功能冻结/发行，不启动全局质量或视觉改版。

### 历史恢复检查点（2026-10-06，输入热点与原生尾项）

- 起点候选 **0f33808a4195b8f09ad06f5a09e352da4a9be5c4**；当前代码/构建 **ff20f2bcfbf13b57836d62fd695954b726f4a010**。本轮实际原生App为 **b8b5ebcbee286c6f750d5166b107c35ee2573336**；ff20只新增“添加附件→本项目成果与素材”直接入口及保护测试，签名构建通过但因再次锁屏未启动/实点。main仍 **90819739e99b366d7cdb2f549c129eea28728206**，不硬合未关闭Bottom的组合。最终文档/远端SHA写本轮R/lead/native-tail-receipt.json。
- R=`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261005T141348Z-native-tail`。输入路径差分确认隐藏Workflow随每次编辑重复读取固定模型注册；b8只缓存固定身份，不缓存安装/就绪。实际paste/delete trace：该布局约123.7–130.8ms→4.5–5.3ms，旧14次Microhang、新两trace均0；不是像素/IME延迟保证。SpeechPanel另有约63–68ms墙钟、仅约1ms CPU的区间，阻塞归因未知，未猜改。证据lead/typing-fixed-analysis/findings.txt；原生旧包/b8代码、命令和区间均有记录。
- **Bottom仍开放**：新增受控真实列表/紧凑高度、隐藏Workflow/父状态、真实共享库投影三组差分，分别2方法通过和1方法通过；未复制调度器或改生产滚动。b8普通App一次冻结短请求重现后上滚→Bottom响应，不能消除旧间歇失败；gui/bottom-b8-native.json。下一实验只在新失败时核实时视口/面板/分支与现有诊断，不泛加日志或反复生成。
- 原生尾项：CSV原文件→统计20→显式采用；非空附件预览/排序/冷重开；字号/换行/输出格式保留；结构JSON真实模型返回不合schema的原始结果如实保留，人工版本→字段title→Canvas并保存，返回聊天不运行；答案嵌套版本菜单经鼠标展开＋键盘选择；三类非空草稿/图像参考→文字的状态保留。精确范围见唯一F表及R/gui/{native-csv-attachments,format-display,structured-field,nested-versions,category-nonempty}.json，不外推全部格式或在途交接。
- 新项目成果选择入口复用已发布asset/version和既有附件API，只加入待发草稿，不生成。1方法实际通过；首次属性名编译失败和一次过滤器0方法均保留，不算通过。非实现者审阅通过，ff20普通签名构建30.346秒；原生列表→选择→采用/取消与三类草稿最终冷开待桌面恢复。唯一启动/Xcode见[试用指南](RELEASE_FREEZE_TRY.zh-CN.md)。
- 锁屏发生在正常Cmd+Q前，旧b8自有PID78554仍存在；未强杀、未假称退出，未新开Terminal。构建/测试/trace已结束，模型短请求已正常完成。旧源个人scheme、普通App、模型/原录音和历史证据保持；新包单独复制，入口拒绝双开。恢复先核已有测试进程与项目保存状态，不重开已办本人项。未功能冻结，不启动全局质量/Liquid Glass。

### 历史恢复检查点（2026-10-05晚，英语后置与原生续验）

- 起点fab6762ce6fb7b052353298e7e85e083e86c7183；新测试提交 **eba9c370dfe0ce5c672bc0955ee7365ce0afdba0**。仅既有ChatPresentationTests和UITests测试scheme；生产App仍 **cc404e4e3889c8035714075c9dd86f3a2cff233d**，唯一启动/Xcode不变。main仍90819739e99b366d7cdb2f549c129eea28728206，不硬合当前Bottom失败。最终文档/候选远端SHA写RHuman/lead/continuation-receipt.json。
- RHuman=`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261005T121357Z-human-queue`。普通话本人录音→本地转写→Lead审核采用草稿/保存通过，不自动发送。英语No speech was recognized，按本人新指示后置；不重试、不索要新权限。3份本轮原声核对清单摘要保持，失败UI未暴露精确录音ID。F26凭据仍未准备。
- cc404普通App补收藏/分支首项（鼠标+Return）、冻结请求全文/参数/来源查看与脱敏复制、四分类空态往返/聊天草稿保留。证据gui/{request-inspection-share,category-roundtrip,cold-branch-bottom}.json；不是所有菜单、非空多模态附件或在途任务通过。
- **Bottom未修**：真实原请求短重现已完成落盘，随后上滚→Bottom导致71206主线程约98%CPU；sample指向SwiftUI懒布局phase/prefetch更新，尚非唯一根因。同包冷开切分支正常；一次有目的官方SwiftUI trace下同短重现也正常，均不能将失败关闭。没有继续加日志、改变模型/输入或猜改生产滚动。输入/删除主观迟滞约200ms仍待定位。
- eba9补实际reproduce→跟底→上滚→Bottom hosting：旧send方法在xcode3通过2.306秒（该整次因当时replay夹具失败）；新replay在xcode4单独通过2.638秒，没有拼成同轮全过。最终文件对应final-tested-files.json；早期source摘要在夹具修正前，不能冒充最终版本。非实现者复核无新增阻断，组件通过不关闭原生卡死。
- 自有71206卡死后核路径SIGTERM结束；72005/73712正常Cmd+Q。CPU/trace命令结束，未新开Terminal；保留测试项目/录音、原件、旧证据和个人scheme。下一步仍在同一F01–F36：依据已有采样收窄Bottom与输入迟滞，继续独立未验原生入口；英语/搜索按唯一集中队列，不重开旧本人事项。未功能冻结，质量重构/视觉统一后置。

### 历史恢复检查点（2026-10-05晚，集中验收与语音授权崩溃）

- 起点候选1c2c6b54ba61ff2c6dbbb942669d760c521d9472干净，main仍90819739e99b366d7cdb2f549c129eea28728206；源个人scheme保持。RHuman=`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261005T121357Z-human-queue`。
- 4102普通App完成会话菜单首项“重命名”→保存并重开保留；本人确认可以选字，但输入/删除主观约200ms迟滞，未作计时，不以完整IME通过关闭。旧H22候选不随动仍按本人决定接受；没有新滚动或输入猜测补丁。
- 点击本地语音授权后69919实际崩溃：default-qos回调继承MainActor，dispatch_assert_queue_fail。用户报告及本机Speech SDK明确的非主队列语义相符。**cc404e4e3889c8035714075c9dd86f3a2cff233d**只修授权completion的Sendable边界并增加后台四状态回归，不改权限、识别/取消或存储。10方法通过（基线＋同内容未提交文件，摘要见tested-files.json）；非实现者窄审通过，正常签名构建36.338秒。CPU不冒充真实识别。
- 修补App已正常启动并重开原隔离项目，OS报告Speech已允许，不重置授权或重复弹窗；两语言实际转写、采用和朗读继续原队列。唯一入口原位指向cc404e4e副本，同树Xcode保持。F09/F12及其他未受影响证据复用；Bottom/输入迟滞与剩余原生路径未关闭，main未硬合，未功能冻结。

### 历史恢复检查点（2026-10-05，F09/F12真实集成）


- 起点候选d8fd464c0efe4a55ba858aea420fc3aab1867433；本轮实际受测 **4266579ab5fe449ab9cdd38a474153684f5c0b56**。只增加真实集成测试及既有DWorkbenchTests的Xcode入口，未改生产Runtime/Store/输入/滚动；App代码仍 **4102cff1bf3f61251e725e31a8ad38842cdd8901**，四关键文件与唯一启动器保持，见[试用指南](RELEASE_FREEZE_TRY.zh-CN.md)。main仍90819739e99b366d7cdb2f549c129eea28728206，未硬合原生关键缺口。
- RReal=`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261005T063244Z-real-chat`。lead/real-chat-evidence.json、real-chat-summary.json：实际1方法通过/0跳过，2次真实短生成，整组238.85秒。9B/27B完整BF16、固定revision、SSD分层、15GiB显式预算，同一问题；释放交接、归属、选用后的上下文与关闭重开通过。F12编辑模板实际39 token、默认31，完成真实执行传递；准确范围只更新[唯一F表](CHAT_FEATURE_LEDGER.zh-CN.md)F09/F12。
- 默认scheme原先无testables及显式scheme未登记包的构建失败均留证；登记现有UI包/测试scheme后实际编译并核xctest非App宿主。没有新runner、生产后端依赖或测试平台，没有下载/GUI/桌面探测/旧长生成。Lead编写，既有只读非实现者窄审指出模板夹具需使用有限语法，已在任何生成前修正；未改产品限制。
- 源01758b81527dc27eb4563bf1b66fd1ceab6647ee与scheme内容/索引/未暂存保持；模型只核清单文件stat及小配置摘要，未再全权重hash。自有编译/测试进程结束，Runtime两次drain/release；细节见RReal/lead/protection-after.json。最终文档/远端SHA和App对应写RReal/lead/real-chat-receipt.json，不自引用反复提交。
- 当前已识别的这两个独立真实集成缺口已补，不重复上轮CSV/MCP或只读盘点。剩余Bottom、菜单和附件/四分类/字段等原生路径需新现场证据；F26真实凭据与F31系统授权/两语言转写仍在[唯一集中队列](FAILURE_AND_PERMISSION_AUDIT.zh-CN.md)。**无桌面条件持续**，不再加Bottom日志/猜补丁；等待本人明确改变条件再按既备最短实验接续。未功能冻结，质量重构/视觉统一后置。

### 历史恢复检查点（2026-10-05，无桌面连续收口）

- 起点候选 `53d4cdc442d84b676e048b1da5636a555ddabad3`，新代码/受测文件对应 **4102cff1bf3f61251e725e31a8ad38842cdd8901**。main仍 `90819739e99b366d7cdb2f549c129eea28728206`（生产af0103b5）。最终仅文档/远端SHA写本轮R/lead/no-desktop-receipt.json；不将未关闭Bottom的组合硬合main。
- R=`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261005T040538Z-no-desktop`。本轮没有探测桌面、启动App、GUI/hosting、模型生成或本人操作；无桌面条件继续有效。唯一入口及同树Xcode见[试用指南](RELEASE_FREEZE_TRY.zh-CN.md)。
- Bottom复用旧主线程采样并核对真实回调：未证实重复scrollTo循环，动画中几何回调可能改变跟随状态也不能解释布局卡死。只补默认关闭的隔离DEBUG诊断，最多512事件＋截断标记，记录实际命令/目标/几何/版本，不记录正文或改滚动/焦点。非实现者定点审核通过；**原生故障仍未关闭**。最短后续实验在原H32队列，不反复长生成。
- CSV新增实际文件导入→原始字节统计→采用/来源→冷重开的服务检查；MCP新增直接disconnectMCP→等待当前调用→阻止抢连→取消归属→再连接检查。两受影响suite报告11方法：10执行通过、1真实服务集成显式跳过；已有真实SDK/App证据复用，新增两个方法均通过。首测CSV夹具选错内部发布类型的失败保留，修正为产品导入入口，没有修改产品限制或断言。
- 无依赖接线核查没有确认新的生产缺实现：附件/恢复实例/字段/记忆/临时/交换沿用现有真实接线及有效检查，不重复开发或新增假入口。真实跨模型比较仍是模型集成待验，不能用已有同模型比较或假引擎关闭。其余原生剩余精确状态继续只在[F清单](CHAT_FEATURE_LEDGER.zh-CN.md)。
- Lead实现诊断和测试，三个既有只读Agent核对各自边界，没有新写Worker；源scheme内容/索引/未暂存保护不变。CPU与构建的自有进程终态、App对应、审核及最终保护见R回执；未枚举或处置其他进程。完整Lead用量/订阅费用unknown。
- 下一动作须先等本人明确改变条件：Lead只用同包与既有小项目完成菜单首项、Bottom最短诊断，再做剩余附件/格式/字段/工具/四分类原生路径。F26本地凭据、F31授权/两语言转写及新宿主真人检查只留[唯一集中队列](FAILURE_AND_PERMISSION_AUDIT.zh-CN.md)，当前不催办。未功能冻结，不启动全局质量审计或视觉统一。

### 历史恢复检查点（2026-10-05，解锁验收后再次锁屏）

- **main保持90819739e99b366d7cdb2f549c129eea28728206**（生产代码af0103b532ed4b14a35518c3cd5aae7727dcf327）。候选生产代码 **1b00d37a55277a1de0c6cf149d3ee5f3b4766bd6**，工作树/分支仍为 `D-RELEASE-FREEZE-01/codex/release-freeze-01`。最新文档/远端完整SHA见下述R/lead/unlocked-receipt.json。保留候选，未因CPU通过硬合仍有原生关键缺口的组合。
- R=`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261004T145523Z-continuous-closeout`，E=`R/gui/unlocked-20261005`。此前四项修补、af人工版本及旧菜单/长流/H22/HF/宏/视频证据沿用。唯一App/启动/Xcode见[试用指南](RELEASE_FREEZE_TRY.zh-CN.md)，F01–F36状态只维护于[聊天清单](CHAT_FEATURE_LEDGER.zh-CN.md)。
- **原锁屏门槛实际推进**：1ebe普通App完成1057pt主操作、962pt可关闭Inspector；重新导出会话包→独立恢复→正常退出/冷重开，4份记忆历史及17份媒体保留，媒体同字节/独立inode，恢复后未来记忆读取授权仍为空。见E/recovery-data-check.json及compact截图，不重写旧失败包。
- 1ebe普通App真实Qwen知识重排完成，两个片段ID各一次、原始JSON及输出资产保存；临时会话显式保存单一Markdown成果→Canvas→结束，临时缓存移除、所选成果保留，不自动运行Canvas。671普通App完成置顶/标签/归档恢复/软删除恢复、词法搜索命中、上下文排除回纳、默认系统提示词只影响新会话、单位/时区、WASI Python取消→后续42、Mermaid预览两版本/重开旧版/放弃未保存。具体范围在E三份native-*.json，不外推未验路径。
- **已修真实反例**：在首字前停止后，空assistant错误阻断下一次发送。671b290475bc703016fb8ab0919d7881850efe10只在下一请求投影跳过真正空且无产物的cancelled/failed assistant，历史/user/tool/非空partial保留；54方法/2suite，非实现者审核，671普通App原失败会话再次发送实际得到OK。另发现根菜单第一操作“重命名/收藏”不可见；1b00采用AppKit标准标题占位、保持旧tracking保护，15菜单方法及1动态hosting方法通过，普通签名构建通过；**新菜单鼠标复验被再次锁屏阻断**。
- **未关闭工程缺陷**：671真实短完成后一次点击Bottom导致主线程SwiftUI布局忙循环；留样后只结束核实的自有实例56752。冷开同项目Bottom可用，受控同host O→OK、真实取消诊断、双栏及实际非底→底几何通过（5afa416a测试）；没有复现唯一根因、没有猜测性滚动生产补丁，不能用这次绿测试关闭卡顿。lead/empty-cancel-native-hang.sample.txt、dynamic-bottom-inspector.log。
- 最后1b00已启动，但在Open面板选择隔离项目时CUA明确报告再次锁屏。自有58949尚未打开项目/提交任务，核路径后SIGTERM结束，不称正常退出；56752异常结束后重开的671实例已正常CmdQ。CPU/build/只读审阅均结束，无新Terminal。见lead/unlocked-app-stop.json。
- 下次解锁后Lead自行：同包实点会话重命名、消息收藏和子菜单首项→既有小夹具附件/四分类/Canvas回流/CSV→格式/显示设置；继续Bottom实际反例定位。不得重做上述已通过同路径或长生成。F26两家本地key、F31首次Speech/本地转写及试听、新聊天组字仍在[唯一集中队列](FAILURE_AND_PERMISSION_AUDIT.zh-CN.md)，本人暂不便不催办；工程失败不归给本人权限。
- 本次Lead定点实现、既有只读非实现者复核；没有新写Worker，旧失败/预算/来源不改。完整Lead用量及订阅费用unknown。未功能冻结、未正式发行，下一质量审计/视觉统一不启动。
- 保护源 `D/codex/inference-foundation@01758b81527dc27eb4563bf1b66fd1ceab6647ee`，个人scheme SHA256 `ca3635d88aa5a15397b90e528667c66c0e6db7e596176e885c79d194b544206c`、索引及未暂存保持；main/候选/旧证据保留。

### 历史恢复检查点（2026-10-04，解锁原生检查与审计同步）

- Lead树 `D-RELEASE-FREEZE-01/codex/release-freeze-01`；本次起点 `7caebde0c9c662ffd60c4b99e9aa81002d5bba27`（代码e80fc15e）。本次新增代码 **c16ab4015193d90def32a7cc6629dde9136b6f5c**，仅修原生聊天菜单的重复重建/尺寸失效及跨周期迟到动作，保留S00–S05组合成果。F01–F36仍按[唯一清单](CHAT_FEATURE_LEDGER.zh-CN.md)，不称专题完成。
- **已推送候选供审计，main未接纳**：起点7caebde已推送；本轮最终文档/远端完整SHA见RN/lead/audit-receipt.json。main仍 `f31dced209855722d2f04cc0fc8c5f6712396120`；原生发送/主停止门槛未过，不硬合。源01758b81527dc27eb4563bf1b66fd1ceab6647ee及个人scheme内容、索引、未暂存状态保持。
- RN=`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261004T023138Z-chat-native-audit`。e80普通App已直接从文件列表打开项目，候选菜单554ms展开，明确区分新候选/原请求重现，冻结请求检查器打开/关闭通过；发送后UI两次超时，主线程采样在SwiftUI布局并命中菜单重建。只证明可疑反馈路径，未证明唯一根因；磁盘仍11次旧attempt，不能据此断言发送函数从未进入。原1024token/模型证据沿用，不重复生成。
- Lead定点修补与非实现者只读复核：反例先红后绿，最终14方法通过；周期重开及idle迟到动作两项审阅反例另留失败，未改断言。普通签名构建exit0/28.331秒，交付复制/签名/四关键文件一致。**Mac再次锁屏，c16新包尚未启动，原生反例未关闭**；唯一启动器及同树Xcode见[试用指南](RELEASE_FREEZE_TRY.zh-CN.md)。
- 旧63889在本次开始前已结束；本次96263卡顿后正常CmdQ超时，经精确路径核验仅对该自有隔离实例SIGTERM，进程已结束；不称正常drain/保存通过。最终pgrep无D；自有CPU/build完成，新包未启动。旧非本任务helper未处置，Terminal状态未知。原始长流项目摘要未变，测试副本保留；证据RN/lead/protection-end.json和owned-app-stop.json。
- R=`D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261003T150039Z-chat-continue` 中的三受限CLI任务、CPU/网页/MCP/WK/Store证据复用，来源及未停报事件保持；本次只有Lead写菜单、只读非实现者复核，未创建写Worker。F28仍未实现，先前自动安全审核拒绝的具体理由unknown，不裸跑宿主、不换名绕行；不从范围移除。费用与完整Lead归因unknown。
- 下一动作：解锁后用c16唯一隔离包复验相同项目的菜单/发送/输入区主停止，再继续新资料/导入/备份等原生路径；若仍迟滞改查滚动与布局反馈，不重复同因长模型。本人不能操作，本次不催组字/试听；新聊天宿主与本地Speech只留[集中队列](FAILURE_AND_PERMISSION_AUDIT.zh-CN.md)。这是审计检查点，未完项仍在同一已批准专题内。

## 历史：先修可靠性，再加入最小聊天（2026-10-03，已被上述新授权替代）

用户批准继续同一 D-RELEASE-FREEZE-01，起点 main/candidate `3a2801abab22273256923ce1f3c14407515f20ce`。批准顺序：A1 普通沙盒备份与独立恢复、A2 冷启按需模型就绪 → 两项真实 App 门槛通过并独立接纳 main → B 最小文字聊天；Q 视频质量独立。**A 的 G1/G2 已通过，独立修补基线 f31dced209855722d2f04cc0fc8c5f6712396120 已接纳并推送 main；B隔离候选原生验收部分通过、长流失败，暂停接纳**；下列上一批停点是历史事实。A受测8511718c472e788a8dcfc088eea0fde9dad050b3；独立原生证据RC/lead/a-native-gates.json、集成回执RC/lead/a-integration.json。B包含常驻四分类，文字为聊天，另三类复用；Q固定自然样本获本人确认，未宣称全部质量或冻结通过。

当前 B 已完成实现、CPU和普通签名构建，但**原生长流可靠性未通过，暂不接纳main**。实际App/原生版本`7754a2b70f3e761ef30b45fe3c5ba76bf12b817a`，与CPU受测`55fcbaa74921007a3768ed8d94a4c896e2989297`只有文档差异。定向DWorkbench45方法/5suite、UI呈现5方法复用，不重复计数；本人启用固定EquatableMacros后构建exit0/79.033秒，没有跳过宏校验。四分类实际可达，图像/音频/视频控件与草稿往返已核；新聊天完成Qwen3.5-9B Q4的TXT+PNG多轮、编辑产生分支、旧路径返回、系统预设、回答存素材并显式送Canvas。没有以量化GUI样例代替原始精度或27B验收。

最新缺陷：两次长回答均因`consumerTooSlow`结束为partial，分别保留633/562字符；不是length正常结束，也没有证明原生停止成功。切会话控制调用曾迟滞56.30秒；disk选中叶正确，旧AX内容只是未滚到底，不能误判分支丢失。Runtime沿用256事件有界队列，WorkflowServices在MainActor消费/更新预览；具体迟滞来源尚未通过时序定位，不归咎模型或16GiB。没有扩缓冲、降低断言或新增补丁。core初交+两修复及唯一Lead接管已使用，UI剩一轮普通修复；本缺陷跨消费/界面边界，不能擅自当作UI额度继续改Runtime。证据RC/lead/b-native-long-stream-failure.json。

本人集中事项已办理：宏信任、Qwen登记、切回聊天及取消当时的Go To/导出面板均完成；本人观察可能存在自动操作重试叠加；两份新的LTX/H3自然视频本人确认正常，固定样本质量通过，旧近静音首异常层仍未知。H22/菜单/资格不重开。改为逐步确认一个文件面板后，普通App的Markdown/纯文本导出、聊天备份→独立恢复→冷重开通过：2会话、9消息、5次尝试及6份资产保持，含失败部分回答与新的未发送Unicode草稿；原件/备份不变。长Markdown合成样例的表格、公式、代码块、跳底、原文复制通过；不是模型输出质量。证据RC/lead/b-native-final-acceptance.json。

保留另一个原生限制：冷重开时列表中的.dproject呈灰色；输入完整路径后Open启用且成功打开。非实现者核对A/B面板代码、Info.plist和文件类型/权限无差异，原因尚未定位；不能把数据恢复通过写成所有文件入口通过。原生停止、视频附件往返、最小尺寸设置/非法数值往返及聊天宿主真人组字仍未验，不重开已关闭的H22。当前没有必须本人立即办理的事项。

**停点**：B长流门槛失败，不接纳main；按已耗core预算不再自行追加修改，UI剩余额度不能覆盖共享消费者问题。下一最小项是定位事件消费/主线程迟滞并有限修补，再验长流与停止；文件面板只做对应的选择过滤诊断。待用户审计后决定该有限续修，当前不启动。B审计包保留，A为唯一推荐稳定入口，main仍`f31dced209855722d2f04cc0fc8c5f6712396120`。本次仅追加记录；最终候选/远端SHA见RC/lead/b-native-closeout-receipt.json。自有95339/96335/96473均正常退出，当前无D进程，自有Finder窗口关闭；Terminal受工具策略限制未操作。源个人scheme、App四关键文件和原始小项目/备份保护见同一回执。
证据 RC=`D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261003T035843Z-stabilize-chat`。H22/菜单/失联恢复保持，不重复本人操作；旧失败和预算保留。新增有限续修及角色、范围、门槛见任务记录末节。没有新的登录或模型资格事项；不发布 Release。

## 上一批历史停点：D-RELEASE-FREEZE-01 / D-DISCUSSION-FREEZE-20261002

**集中本人操作已办理；有限原生收尾部分完成。** H22按本人复验关闭，模型嵌套菜单修补通过本人操作。MRT2引用/独立复制、Quick失联文件恢复/收纳/冷重开、Canvas草稿保存重开已完成。原生手动备份返回I/O失败，独立恢复未验；不再以锁屏或权限审批解释工程缺口。当前无需新增登录、组字或试听，集中清单见[唯一待办](FAILURE_AND_PERMISSION_AUDIT.zh-CN.md)。

- 本次起点main：`a3c5b091de6e5af5bad0a1365d09ff80306d0cef`。
- H22修补/本人受测：`9baaacbc74855aaa84fa03868e62a1676d882250`；菜单修补/本轮最终App及原生受测：**`35f373ad4973a0f1dee91c68ddb9f440f25c6520`**。后续仅文档和真实截图；最终候选、main/远端完整SHA见RH/lead/final-receipt.json，不把文档SHA写成重新执行测试。
- 实施与同树Xcode：`/Volumes/CodexProjects/Codex/D-Worktrees/D-RELEASE-FREEZE-01`，`codex/release-freeze-01`；main接纳树同级`D-DISCUSSION-MAIN`。唯一推荐启动器、同树D Nodes Run见[试用指南](RELEASE_FREEZE_TRY.zh-CN.md)。旧候选保留，不自动接纳AP1/CORE/I2V。
- main为公开开发集成线，获准经相称检查正常快进/推送；公开主线、试用、功能冻结、发行分开。旧main备份已在前轮完成，不重复，不强推、不改许可证、不发Release。
- 保护源`/Volumes/CodexProjects/Codex/D`仍为`codex/inference-foundation@01758b81527dc27eb4563bf1b66fd1ceab6647ee`。个人scheme orderHint1→6未暂存，SHA256`ca3635d88aa5a15397b90e528667c66c0e6db7e596176e885c79d194b544206c`；结束保护与进程核对见最终回执。

RH=`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261003T015601Z-human-closeout`。
RN为同级`run-20261002T160047Z-native-closeout`；R=`run-20261002T062206Z-discussion`；R4=`run-20261001T162316Z-r4`；R3=`run-20261001T040512Z-low-memory`。大日志/产物不入Git。

## 历史批次的已完成、失败与未验

| 范围 | 当前证据 | 结论边界 |
|---|---|---|
| H22 | Quick多行字段复用已有原生编辑器，固定draft/field所有者；先红后绿，UI5/Quick19通过；本人确认组字可用、鼠标不再闪回 | 候选窗不随动经本人Finder对照接受为当前系统行为；不是所有系统/输入控件保证，不重复要求本人 |
| 原生模型菜单 | 35f373仅跳过完整相同的ModelLibrarySnapshot发布，保留真实状态变化；本人确认高亮/选择/文件面板正常 | 本次FILES有限Lead接管已使用，旧失败不抹去 |
| 模型引用/复制 | MRT2外部登记后复制6个必要文件至独立模型库，逐文件摘要一致、inode独立，ordinary-note.txt留在原件不进安装；本人完成隔离设置资格声明；Quick/Canvas当时均可用 | 没有重新推理。冷启动仍显示未知/待核验，现有完整资料库sheet才触发显式校验；非35f补丁引入，仍需改进初始化接线 |
| F1/F2原生 | Quick原位导入88字节PNG，另有命名Canvas；只移动本轮夹具后从Quick条目直接到缺失位置页，同内容重定位、Finder显示、复制入项目、正常退出重开/核对通过 | 原件与项目副本摘要一致、独立inode，Canvas没有串入Quick素材。只验证该小文件，不代表NAS/全拖放矩阵 |
| 备份/恢复 | 未保存Canvas标记在备份预检中保存；NSSavePanel后报`ProjectBackupError error 4`，未发布备份，正常重开文字保留 | error4为io关联错误，但UI隐藏具体操作/errno；最强源码风险为仅有target授权却在parent建兄弟stage，restore同类。本轮不追加第三轮或另一Lead接管。原生独立恢复未执行 |
| CPU/构建 | H22 UI5/Quick19；菜单UI2（含Quick组字）/ModelLibrary64/Readiness2分别通过。普通签名35f构建exit0，50.3787秒；非实现者分别审核 | 不相加成全套通过率。前轮RN UI18/Workbench42复用，未改文件服务。两项旧offscreen hosting失败保留 |
| README | EN→中文、双语标题/页内跳转；新增35f真实脱敏Quick截图，截图保留冷启待核验状态 | 不是模拟画面，不凭截图判生成或冻结通过；本次未在Xcode GUI点Run |
| 视频质量 | 本人：H3文生正常，LTX无声/红块持续，H3合成首尾难判断。只读PCM核实近静音；上游candidate已含红块，D没有后叠图；条件CRF33不是33帧叠加 | 未定位所有质量原因，未做新自然首尾生成/试听，不判模型固有限制。质量任务需下一有限修复，不重问旧样本 |

## 历史批次的预算、保护与恢复

本次FILES续修受限Sol/high初交+两次修复完成入口/核对/展示；Lead一次有界接管用于本次菜单。该额度已使用，新备份失败仅定位留证；原FILES-UI更早耗尽历史不刷新。H22为本人反例后批准范围内的Lead定点修补，非实现者审核；不能归为Sol独立通过。完整Lead用量/订阅费用unknown，不重算旧样本。

所有本轮Worker/CPU/build结束；自有测试App已正常退出，Finder自有窗口关闭。旧重复启动事故已留证并处理，不把归档当终止。工具不允许控制Terminal，因此无法确认/关闭启动器终端窗口，必要时本人关闭标题对应已完成窗口，其他终端不动。准确PID、App摘要、个人scheme内容/索引/状态见最终回执。

恢复先核真实HEAD/index、保护对象、运行状态与回执，不按聊天猜版本。本次只移动合成reference.png，模型源/旧项目/旧App/候选/外盘证据保留；不清理。

**下一最小工程项**：针对备份目标授权/同卷临时发布及可解释错误作有限修补，并补普通App备份→独立恢复；同时明确冷启就绪刷新触发。需延续旧失败、明确新增有限预算，不能绕过沙盒。视频质量继续保留独立证据，不为同一提示盲目重跑。

**本轮停在用户试用与冻结判断。** 当前不是功能冻结通过或正式发行；没有新增聊天/富文本/联网/模型平台。Pitch内部评估权重、无权重分发、首次使用/依赖封装/升级恢复/渠道等[发行责任](MODEL_SUPPORT_AND_RELEASE.zh-CN.md)继续保留。
