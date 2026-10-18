# D 性能归因调查 — 2026-10-18

当前阶段：[Phase 2 完整报告](phase-02/REPORT.zh-CN.md) · [三操作时间表](phase-02/timeline.csv) · [全线程排行](phase-02/global-hotspots.csv) · [可复算方法](phase-02/METHOD.md)。Phase 2沿用已复算的全线程/时间切片、调度和部分显示关联；2026-10-19已实现完整App诊断重放器并尝试两次资格试录，均因诊断工具缺陷失败。最终局部修正完成自检/匹配构建，尚无合格三交互重复或因果对照；没有性能修补。以下为Phase 1历史结论，不替代Phase 2的分级。

状态：调查完成，待用户审计与外部独立复核；尚不足以宣布唯一根因或选择正式修补。2026-10-18 用户追加授权将去敏调查文档提交到 GitHub。本次归档只含文档及静态证据摘要，没有生产源码或诊断代码变更，没有构建、合并、部署或替换普通 D。

审阅材料：[数据 CSV](interaction-summary.csv) · [证据与复算口径](EVIDENCE.zh-CN.md) · [只读复核](consultant-review.md) · [当前集中待办](../../FAILURE_AND_PERMISSION_AUDIT.zh-CN.md#d-performance-attribution-01-当前队列)。原始资料保留在受控本地，Git 版不包含用户正文、书签、索引、私有绝对路径或完整系统进程资料。

## 结论及强度

本轮最明确的新证据是：**连续缩放期间，D 主线程实际执行了资料库条目深比较、操作库树构造和重复语言解析；这些工作不只是玻璃 shader 的猜测。** 一个代表栈明确从 `FunctionalLocation.==`（Binding location 比较）深入 `[SharedLibraryBrowserEntry]` 和条目字符串。收起左侧操作库后，`WorkflowOperationTree.make` 仍出现在采样中，说明至少这条操作库计算没有随左栏隐藏而停止。

这支持“画布状态更新牵连无关界面工作”作为下一步优先验证对象，但仍有边界：未锁定具体 Binding；未证明所有隐藏页面都刷新；未证明这组 CPU 工作解释全部卡顿；GPU 光学、系统合成和实际显示帧链尚未完成可靠归属。**没有 FPS、输入到呈现延迟或性能提升百分比结论。**

三条交互路径不同，单节点拖动是有用的正向对照，但不是等工作量基准。节点/平移录制前半段实际活动稀少，缩放段持续活跃；不能把三段总 CPU 时间直接换成速度倍率。左栏收起实验属于显示状态、布局及覆盖面积共同变化的探索性干预。重新展开时用户完成了操作并恢复界面，但采样文件不完整且导出失败，A/B/A 往返验证未完成。

## 1. 固定对象、访问范围与保护

- 调查及此次文档归档的起点 HEAD：`e4aaea7159d2a975b4e3d0ef9b9fca0e72371dc4`；分支 `codex/rendering-workspace-20261017`。调查开工本地/远端一致、索引和工作树干净；后续文档归档开工时，HEAD仍一致，只有本轮CURRENT_ACTIONS与集中待办的未暂存记录，已纳入本次归档。
- 真实生产：`9eae90e4adc4008c3894f09bcd07c71e23701045`。上述 HEAD 相对生产只有三份既有文档，无生产差异。
- 工作树：原任务的隔离修补树，继续同一工作分支；绝对位置保留在私有身份回执。
- App：上述生产的既有独立评审产物；构建相对位置 `native/20261017-07/ReviewDerivedData/Build/Products/Debug/D.app`，未重新构建。
- 独立评审 bundle（精确身份见私有回执）；Apple Development 签名；Sandbox；签名前持久标记 `DReviewLaunchMode=isolated-download-v1`。本轮 deep/strict 验签 exit 0；包内十项摘要开工及结束均吻合原回执。
- 开工没有 D 进程。经核对后仅用原 `review.py --launch` 重开同一包；唯一核实进程（下文代称 `REVIEW_PID`），可执行路径及 READY 的隔离会话、ModelLibrary、Quick 根均已核对。没有按名称绑定或另开同名副本。用户确认已准备画布。
- 用户在调查准备期间新增一个节点。未删节点、回退项目或强制恢复旧四节点图。三种有效交互均要求留在新增后的同一当前流程；节点/视口可有用户手势造成的变化，未执行保存、撤销或强退。
- 普通 D 与旧隔离会话的八项保护摘要前后一致。源树仍为 `01758b81527dc27eb4563bf1b66fd1ceab6647ee` / `codex/inference-foundation`，仅原个人 scheme 路径 dirty，未被编辑。该 scheme 本轮未保存开工字节摘要，不夸称已做前后逐字节比较。
- 本轮仅离线读取固定源码、私有签名/配置/保护证据、隔离会话的特定偏好；采样按核实 PID 附着。未读取或重哈希模型权重，没有模型下载、计算或用户资产外传。
- Agent 的 AX 与屏幕捕获检查均 false；不据此猜锁屏。桌面 API 缺安全 PID 附着，未通过名称启动来绕过；由用户只配合短手势与一次侧栏对照。

私有证据集标识：`D-PERFORMANCE-ATTRIBUTION-01/run-20261018-01`（目录权限 700）。本地保管人可依任务标识定位原始资料；具体文件映射见[证据索引](EVIDENCE.zh-CN.md)。原始 XML/trace 含系统进程、路径等信息，未上传或入 Git。

## 2. 环境、时间窗与采集纪律

macOS 26.6.2 (25G83)，Xcode 27.1 / SDK 27，部署目标 26。受测 UI 为 **Debug / -Onone / DEBUG / D_REVIEW_ONLY**，不是 Release 性能结论。沿用同一二进制，没有诊断包或临时降质。

本机屏幕枚举：1920×1080 逻辑点、2×、最大 120 Hz。最大刷新率不是 D 的实测帧率。采集后的隔离持久偏好为浅色、应用内 glass、local strength=1、有自有背景图片、readability enabled/amount=0.35、lightweight=false。它们是持久配置读回，不是逐段实时画面遥测。有效语言随系统的实际解析值、窗口点尺寸、倍率上下限、可见/总节点与连线数、叠层面积、已访问页集合、当前内存历史规模均 **unknown**。未要求用户反复统计。未主动运行模型，但实际同时 GPU 负载未独立取得；导出的热状态为 Nominal，不能据此宣称没有 GPU 竞争。

模板统一 `Animation Hitches`，`--attach <REVIEW_PID> --no-prompt`。准备后使用 Darwin tracing-started 通知播放开始音，结束音后停止；每次记录 UTC 与单调时钟、命令、退出码。提示音/用户确认只标记请求操作段，不是 NSEvent 或显示时间戳。分析窗取开始音命令完成后 0.5 秒至结束音前 0.5 秒；空闲取中间窗口。没有从 body、刷新回调、堆栈命中或 Metal 完成数换算 FPS。

|段|trace 开始（JST）|录制时长|分析窗，相对 trace 秒|用途与限制|
|---|---|---:|---|---|
|00 idle|16:17:21.097|10.746秒|不进入同场景统计|新增节点以前；仅工具可用性/早期空闲参考|
|01 node|见 timing|约16秒|无|用户未听到 cue，场景改变；保留，不标作有效节点对照|
|02 node repeat|16:23:07.086|16.720秒|3.114–14.120|用户确认完成；活动主要集中约10秒以后|
|03 pan|16:24:58.363|16.730秒|3.856–14.864|用户确认平移完成；活动主要集中后半段|
|04 wheel|见 timing|约16秒|无|用户未及时完成并要求重录；不作为有效缩放对照|
|05 wheel repeat|16:28:52.563|31.762秒|3.675–27.681|用户先确认准备好，25秒操作后确认完成|
|06 idle current|16:30:58.730|12.773秒|2.000–10.773|缩放后同项目空闲；不是与前段完全相同倍率/覆盖面积|
|07 left hidden wheel|16:36:58.195|31.720秒|3.601–27.604|用户确认左栏已收起及操作完成；保存收尾异常，详见第6节|
|08 left restored wheel|见 timing|请求31秒|无有效数据|用户确认展开及操作完成；采样文件不完整且导出失败，不能做复归性能结论|

完整时间戳在私有各 `*.timing.json`、`exports/*-toc.xml`；本目录提供[去敏操作时间线](timing.sanitized.json)、[可读指标](interaction-summary.csv)及[分析口径](EVIDENCE.zh-CN.md)。原分析器 `tools/analyze-traces.py` 留在本地，未作为诊断代码推送。每秒样本分布是完整 trace 的活动覆盖提示，没有限制到有效窗/Running，不能当每秒 CPU 或输入频率。

## 3. 三种交互的当前实测

调度时间由 `thread-state` 真正 Running 区间与窗口相交求和；样本权重来自 `time-profile` 的 Running、已核实 PID、Main Thread。两者来自不同机制，均不是帧率。

|交互|分析窗秒|主线程 Running 秒|主线程 Runnable 秒|主线程 Running 样本权重毫秒|资料库相关 inclusive 样本权重毫秒|
|---|---:|---:|---:|---:|---:|
|单节点拖动02|11.006|1.686|0.0083|1720|6|
|手掌平移03|11.008|1.368|0.0181|1383|16|
|连续缩放05|24.006|13.624|0.0091|13726|2490|
|空闲06|8.773|0.0033|0.0008|1|0|
|左栏收起缩放07|24.003|16.508|0.0172|16636|2981|

不要从此表计算“缩放比拖动慢几倍”或“隐藏左栏使性能变差”：手势覆盖、速率、倍率和可见面积不受精确控制，02/03前半段很少活动。全表是证据描述，保留了不利于比较的条件。该短空闲窗没有主线程持续忙循环；不能推广到其他页面或有模型运行时。Runnable 时间很小，不支持把这几段主要归因于主线程长期等待 CPU 调度；Blocked 的等待原因未被单独识别，不能一律叫 GPU 等待或空闲。

缩放05中的具体 CPU 调用链（inclusive，可重叠，不相加）：

|调用链/子树|权重毫秒|占该窗主线程 Running 样本|能证明什么|
|---|---:|---:|---|
|资料库相关调用|2490|18.1%|缩放期间存在明显非画布语义工作|
|BrowserEntry 数组深比较|717|5.2%|Binding location 比较深入完整条目，不只是ID|
|语言解析相关|1118|8.1%|包含 locale 规范化和文字读取；与资料库等重叠|
|操作库层级 `WorkflowOperationTree.make`|477|3.5%|真实模型/程序操作库构造执行|
|节点卡相关 body 链|494|3.6%|真实字号/控件布局存在，不能等同全部节点绘制|
|背景/玻璃宿主 CPU 链（收窄分类）|325|2.4%|只涉及命名宿主/参数/字段/绘制调用；不是 GPU 成本|
|可读性几何索引|206|1.5%|实际几何/邻接更新成本存在，与上项可能重叠|
|素材条目投影入口|84|0.6%|不能直接等同历史结果重投影|
|明确历史输出/人类名称投影|1|约0.007%|本窗没有明显命中；不能排除大历史场景|

大量工作位于 `CA::Transaction::commit` 的祖先链下；其中含 SwiftUI 布局、比较、语言等后代。**不能把这个祖先的 13261ms 当成独占“渲染提交耗时”。** `layout` 祖先也是同理。原宽泛的 `WorkbenchGlass` 分类会误含普通 GlassSegments 控件值构造，已在可读分析中拆开；不拿粗类指认 shader。

## 4. 调用关系、支持证据、反证与不确定性

以下源码均固定于生产 SHA；行号以该版本为准。[源码定位表](EVIDENCE.zh-CN.md#固定源码定位)提供不可变链接，短文件名在该表中展开。

### 4.1 缩放牵连资料库与 Binding 大值比较：当前优先线索

真实样本：`FunctionalLocation.== → compareValues → Array.== → SharedLibraryBrowserEntry.__derived_struct_equals → SharedLibraryItem.== → utf8.elementsEqual`。它证明比较真的发生了，不是仅看到一个函数名称就推测。

源码入口：`Views/Workflow/WorkflowGraphSurface.swift:633` 每个 wheel 更新父 zoom；`WorkflowCanvasView.swift:328` 非 pan 滚动观察还更新可见中心、插入点与视图状态。`WorkflowCanvasView.swift:490` 构造已访问准备页；捕获的 `libraryContent` 调用 `Views/Quick/DualWorkbenchView.swift:699`。这不要求 Dual 根 body 本身也每次重算。代表符号栈在 [hotspot-stacks.sanitized.json](hotspot-stacks.sanitized.json)；已去进程号、线程地址和未符号化地址。

`SharedLibraryBrowser.swift:320` 的值含完整 Entry 数组；Entry 含 item/facts/tags/metadata/runtimeValue。466–469详情 sheet Bool Binding 明确引用 entries；927–928搜索 Binding 与648属性摘要 Binding经实例 query捕获 self；都是具体候选。条目相等在 `Packages/UI/Sources/DWorkbench/Library/SharedLibraryMetadata.swift:50` 比较完整字符串。样本没有具体 getter，所以不能在这三者中锁定唯一对象；483的 `onChange(of: entries)` 是另一比较入口，但不能拿它解释已有 FunctionalLocation 栈。Swift 编译器实际捕获布局也不能仅凭源码推定。

反证：目录基础投影和分类选择已有语义缓存，zoom不在其输入中；不能称“每个滚轮完整重载模型目录”。本轮观察到缓存调用/值比较/行构造，不等于每次缓存都 miss。相邻层级构造和语言样本也不能被写成数组比较导致了它们。

### 4.2 已访问隐藏内容：一个有区分力的探索性对照

先用05选择热点，再只要求收起左栏，07使用同包同配置录制，右栏/底部/流程要求保持。用户确认收起。07中库相关2981ms，操作树574ms，Entry深比较838ms；这些是包含采样权重，非调用次数。

泛 `SharedLibraryBrowser` 可能来自仍打开的右素材库，不能单凭它证明左栏隐藏更新。但 `SharedLibraryBrowser.swift:518–519` 仅 nodes/programs模式的空搜索构造 `WorkflowOperationTree.make`；右素材模式不走该树。结合左栏保留内容和用户确认，支持“至少操作库树计算在左栏收起期间仍出现”。不能区分模型tab和已访问程序tab，不能推广所有隐藏页。

源码反证/范围：`WorkbenchSidebar.swift:197` 收起仍调用content，`RetainedContentHost.swift:20`仍更新rootView，隐藏不等于停算；但不能反推隐藏还实际绘制。Quick并非所有访问后永久挂载；活动结果面板也只在打开时挂载。没有证明整台工作区所有页面都被刷新。

08已恢复左栏但数据不完整且导出失败，故**没有完成严格A/B/A**。07收尾也有异常；其TOC/数据成功导出、窗口调度覆盖完整，仅支持上述有限观察。不比较05/07总CPU升降，不给“关侧栏无效/更慢”结论。

### 4.3 材质、几何、系统绘制

节点拖动主要发布 `WorkflowCanvasNodeDragPresentation.offset`（GraphSurface:1560），图命令结束才提交。平移每tick调用原生clip.scroll，非Observable tracking且pan期间不回传父滚动观察（ViewportInteraction:378；GraphSurface:266/586）。这反驳“每个pan tick都显式重建父工作区”，但不排除后代几何通知、宿主更新及原生绘制。

每个背景表面订阅自身/祖先几何通知（LocalBackground:472），更新可读性索引并可能替换光学host参数；实际样本含这些路径。反证是同geometry早退、离屏host释放、无readability消费者早退、空间桶及字段缓存。不是每帧解码/模糊背景，也不是每像素固定五次距离查询。缩放重新布局真实字号和控件；不是单纯把节点位图拉大。

没有单独切换材质、readability、shadow或shader。本次先测出了较明确的CPU外溢，再选侧栏实验；不因原猜测而执行无判别力的全部材质矩阵。当前GPU成本仍未知，不能因背景CPU样本占比小就排除GPU瓶颈。后续若获准诊断，须把host/几何与GPU像素开销分开，不能用透明度归零造成整个光学host消失来宣称纯shader因果，也不能作为产品降质交付。

### 4.4 历史规模、活动、命中与可见面积

真实素材入口可遍历runs并构造输出，命名/调用别名也可能扫描记录；但当前明确历史输出符号几乎没有命中。存储历史规模及当前内存页集合未取得，不做“大历史已经排除”。未修改项目历史来做规模测试。

活动关闭不等于完全没有waiting摘要扫描，但输出面板本身条件挂载。本轮没有显著活动热栈，不能推广到运行中工作台。

连线仍会构造全量路径后在原生层按可见区域画；命中缓存命中前也存在过滤/排序。反证：pan复用已捕获目标，拖节点期间移除wire hit receivers，布尔路径已有缓存。因此不能称“pan每tick重算所有精确命中”。当前样本没把它识别为主要CPU热点，未做单独几何/paint开关。

倍率、挂载/可见节点数、覆盖面积未精确测得，不能判断节点总数、肩部像素数和层叠面积各自贡献。没有把简单画布结果推广到大图。

## 5. 输入、提交、GPU与呈现：取得和未取得的边界

|层|本轮证据|不能声称|
|---|---|---|
|输入|用户确认的独立手势段、cue时间、实际生产输入栈|精确事件数、输入队列延迟、输入到呈现延迟|
|主线程|PID精确过滤的Running样本和调度状态；具体库/语言/几何子树|把inclusive样本叫函数调用次数、连续阻塞时长或FPS|
|布局/几何|实际SwiftUI/AG/原生geometry栈与固定源码|精确body/layout次数，确定的反馈循环|
|内容/材质绘制|主线程绘制/背景参数链；原始Metal相关表存在|完整GPU归因、每节点像素成本、与模型GPU共存通过|
|提交/显示|hitches-updates包含D PID，另有surface/swap/frame lifetime表|已完成完整工作台帧、实际FPS/帧时间p95|

呈现表不是空的：存在从D update到swap/surface的潜在join线索。但另一些表没有PID；同一更新有多行/层次，同一交换也涉及不同surface。数据中还出现长于整个录制的边界lifetime（如31.76秒trace中的132秒行）。未核实单表字段语义、display/connection、重用及匹配率前不能把所有surface swap数当D帧数。这部分在工具/存储异常后停止追加Instruments导出；原始数据保留，状态为未完成归属，非“桌面FPS已通过”。

## 6. 原始资料、命令及异常

- `traces/00…08.trace`：原始录制，08不完整，不删除失败材料。
- `exports/*-toc.xml`、`*-data.xml`：02/03/05/06/07可读导出；文件含私密环境，留本地。
- `reports/*-analysis.json`、`*-example-stacks.json`、`hotspot-stacks.json`：指标与代表栈；`interaction-summary.csv`便于顾问比较；`data-integrity.json`验证主线程调度覆盖与分析窗一致。
- 每段 `*.command.json / *.timing.json / *.log / *.result.json`；07例外在 `07-left-hidden-wheel.wrapper-result.json`，08底层-6、shell250。
- `preflight-commands.json`、`private/build-configuration-evidence.txt`、`private/protection-end.json`：身份、构建配置和保护证据。

|命令组|结果|
|---|---|
|签名/远端读回/Xcode/模板枚举/原生前置|exit0；AX、screen capture为false，不是通过GUI权限|
|00、01、02、03、04、05、06录制|exit0；01/04操作标签无效，00场景不同|
|07录制包装器|exit1：录完后等待保存90秒超时；仅给本次拥有的xctrace发SIGINT；随后日志明确文件已保存。底层最终exit未由异常分支保留，不补猜0|
|07 TOC及数据导出|各exit0；31.720秒，time-profile19503行、thread-state196654行；分析窗调度覆盖吻合。保存异常仍保留|
|08录制|底层exit-6（SIGABRT），shell250；没有App崩溃结论|
|08 TOC及数据导出|各exit10：malformed / instrument run data missing；不能使用|
|02/03/05/06 TOC及数据导出|各exit0|
|分析/保护检查|完成；无本轮构建/组件测试/模型测试，不沿用旧测试数冒充本轮实跑|

08收尾后shell报告 `no space left on device`。随后只读df显示内盘约3.2GiB可用、外盘149GiB；所有本轮trace/导出位于外盘，合计约4.1GiB。没有采集崩溃诊断证明空间不足是-6唯一原因，也没有开工内盘空闲量可作精确消耗差。没有删除、移动或清理任何用户/旧证据文件；没有停止D。已停止额外采样及Instruments导出，不把修复工具或用户清盘设为本轮报告前置。

## 7. 排除强说法、未证实项及下一决策

可排除或不获当前证据支持的说法（两者需区分）：

- 当前证据不支持把全部卡顿归给玻璃：Binding数组比较、库树和语言CPU负担已实测，但各自对呈现卡顿的因果贡献尚未分离；不能据此反向断定优化玻璃一定无效。
- “收起左操作库后它一定完全停算”：07仍采到操作树；限定于该模式和本段。
- “pan每tick必然重建全部父UI／重解码模糊背景／每像素恒定五查询”：源码已有反证。
- “新节点库基础投影每次必然重新读模型目录”：已有缓存；本轮不能证明miss次数。
- “07/08成功完成了A/B/A或得到真实FPS”：07收尾异常、08不可用、帧归属未完成。

仍未证实：具体Binding捕获源；隐藏模型tab与已访问程序tab的各自贡献；历史规模斜率；节点总数/可见面积/材质参数独立因果；输入延迟；D的完整呈现帧节奏；GPU瓶颈与模型共存；Release与Debug差别。

独立顾问应先复核本报告、固定源码和代表栈，再与用户讨论修改范围。最小后续判别建议是：仅在隔离诊断副本逐一缩窄常驻Binding捕获（保持搜索/详情/标签的真实语义），观察FunctionalLocation下的Entry深比较是否消失；另行辨别retained内容更新与可见绘制。不能用只比较数量/ID、忽略内容变化的equatable、关闭功能或降质作为结论。此处是后续范围建议，**本轮未实施，也未授权正式修补**。

环境受阻项与真人事项已分开进入既有集中待办：Agent负责存储前置、精确遥测、帧链及必要可控实验；用户只需在独立复核后讨论范围，不需再试新包或完成工程排错。原滚轮/平移性能缺陷保持OPEN，不由光标/未就绪节点的历史接受记录关闭。

## 8. 复核与归档

本报告已由非实现者只读审查；因果强度、分类与08数据状态的意见均已修正文案，记录在[只读复核](consultant-review.md)。它不取代用户指定的外部独立顾问或体验验收。

调查采集结束时未提交或推送；随后用户明确授权文档归档与 GitHub 推送。本目录是该次归档的去敏报告，不是新性能候选。调查原件及失败数据保留在本地，生产仍为本页列出的完整 SHA，未修改 App 或诊断代码。

今后的调查、审计与研究材料归入 [docs/investigations](../README.md)，一项调查一个任务目录。当前授权和待办仍分别以 CURRENT_ACTIONS 与集中待办为准，不在本目录新增另一份全项目当前状态。原评审启动器保留在既有本地交付入口，本次没有新 App；不要仅为查阅报告重复启动实例。
