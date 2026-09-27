# D-NODE-QUALITY-01：工具链确认与有限质量改进

2026-09-27，规格 r1；状态：实施中。源基线 `01758b81527dc27eb4563bf1b66fd1ceab6647ee`。用户本轮批准工具链核实后改善输入法候选位置、历史保存响应、视频质量与音乐能力表达；优先官方实现，音乐提供可组合的基础能力，不固化用途。

## 边界与责任

Lead 工作树 `D-Worktrees/D-NODE-QUALITY-01`，分支 `codex/node-quality-01`。源个人 scheme 未暂存修改继续保护；旧候选、项目、普通 App、权重与历史证据不改。证据 R：`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-NODE-QUALITY-01/run-20260927T114101Z`。准备 SHA 由派工回执记录。

本轮不增加模型、模态、节点执行器、专用音乐调度器、项目版本、依赖或签名方案。不改变精度、控制输入与原件保护，不用画质承诺替代实测。现有运行时、Store、语言包、模型输入继续复用。每个新写任务初交＋最多两轮修复，再最多一次有界 Lead 接管；旧任务预算不刷新。写 Worker 使用已验受限 CLI、独立树、网络关闭；Lead 串行持有构建/GPU/GUI。重要 Lead 改动由非实现者审阅。

## SAVE 工作包（r1，冻结）

目标：成功提交后的下次读取复用已经完整验证的不可变快照，减少重复解码/全历史验证。不是跳过提交校验或保证所有保存为常数耗时。此前只缓存读取结果的决定在本轮有针对性扩展，历史验收不倒改。

允许文件仅 `Packages/UI/Sources/DWorkbench/Project/ProjectStore.swift`、`Packages/UI/Tests/DWorkbenchTests/WorkflowValidatedReadTests.swift`。读取真实 Store/Archive/Controller 与相关测试即可；禁止改其他生产、规格、断言政策、项目 schema 或界面。

约束：只在持久提交成功后记录已归一化、已验证、实际编码的值；失败不发布新缓存。每次命中前仍检查目录/会话、外部清单、指针、读取安全、长度/SHA/确切字节及资产清单。完整提交校验、未知字段只读、原子发布、32 MiB 上限、检查点与 fsync 原样保留。不引入后台保存、数据库、隐藏计数器或性能阈值。

冻结反例：

1. 成功保存后第一次读取前，同长度篡改快照，读取和再次保存均拒绝且不覆盖。
2. 同期外部清单变更、文件缺失、目录移位、已关闭 Store 均不得返回旧缓存。
3. snapshotDurable/beforeManifest 注入失败，清单/旧状态不变，新候选不可见；原有同 asset ID 重试语义保留。
4. 非法新图、伪造历史/检查点仍拒绝；资产清单变化使旧缓存失效。
5. Unicode/组合字符/emoji、可选字段、UUID 键、嵌套控制与工具的提交后值等于关闭重开的解码值；unknown 字段保护继续通过。
6. opt-in 基准只在历史项目独立副本运行，记录冷读、连续真实编辑保存及保存后读，历史数/字节/耗时；不写原项目，不把读取耗时当保存耗时。

Worker 请求 `gpt-5.6-sol/high`：有存储安全风险，规格清楚，范围两文件。初次实施上限 20 分钟。仅 CPU/静态检查，若嵌套构建沙箱拒绝，立即回报，由 Lead 在既有资源下测试，不禁用沙箱。输出/临时仅本 run 的 SAVE/output、SAVE/tmp；共享 Git 管理区不可写，不自行提交。预检后 Lead 核对模型、目录、权限再批准实施。

## H22 与媒体有限调查/实施门槛

H22：先检查真实 AppKit 字符屏幕坐标与窗口移动/缩放，区别坐标错误与缺少失效通知。优先已有窗口 delegate/AppKit 输入上下文，不重建编辑器，不丢 marked text、selection、undo；真人中文/日文候选跟随另验，不能以 hosting 代替。允许的后续生产范围仅现有窗口连接/相关输入组件及直接测试，具体修改前追加定位证据。

视频：对照官方 Wan 非蒸馏模型建议，检查低步数验证配置与正常创作配置的区别；仅在现有支持范围内显式选择参数并作固定输入对照，不静默改变旧图。音乐：核实 MRT2 接受的结构化音符/时序/提示及近似服从边界，展示真实可调用能力，保留用户自由组合；不追求某一示例的精确再现。最终具体文件与参数在事实核清后追加。

## 工具链已核实

Xcode 27.0 (27A266a)：Agent 的 Codex 已下载但界面仍要求登录；ChatGPT in Xcode 已开且已登录。两者不共享本主会话历史。当前桌面工具表没有原生 Xcode 项，但本主会话已通过官方 `xcrun mcpbridge` 成功调用 XcodeListWorkspaces 与 XcodeListSchemes，返回隔离工程及 D/D Nodes/DMLXTests。外部工具权限为已有 Always，观察到限定项目/约一天 grant；未改全局 Codex 配置或登录 Agent。

打开隔离 workspace 时 Xcode 自动修改两份工程元数据，已捕获差异并仅在关闭自有 workspace 后按创建时已知内容恢复；源个人修改未动。调用、权限、自动变化与关闭证据见 R/toolchain/summary.json。连接可用于后续工程问题/测试/日志读取；此处不证明所有 Xcode 工具均实测可用，也不等于另一个 Agent 已接手。

## 接纳与恢复

各组件 CPU/构建、真人 IME、真实视频/音乐以及源组合验证分别记录；性能保留前后同数据实测，艺术效果单独判断。手动/锁屏阻塞进入集中清单。最终仅快进接纳已验组合到既有工作分支，显式暂存，保留来源及证据；不发布/main，不清候选。待补实现、测试、审阅、版本及停点。

## MEDIA 工作包（r1，冻结于官方对照后）

官方 Wan 原始1.3B非蒸馏建议50步，CFG6/shift8起点；当前节点4步是链路预设，不代表普通画质。MRT2现有1.3/40/3/1与锁定官方CLI一致，不在本轮改其推理协议。来源：Wan-Video/Wan2.1 的 generate.py/text2video.py 与 Magenta MRT2官方控制说明、锁定694a545e的mlx_commands.py。只读定位结果保留；本轮不修改采样器、精度、provider或旧请求回退。

MEDIA只允许下列文件：
- 新 `Packages/UI/Sources/DWorkbench/Workflow/WorkflowVideoPresets.swift`（当前UI实际调用的纯值参数预设，不是注册平台）。
- `Packages/UI/Sources/DWorkbench/Workflow/Operations/WorkflowLanguageOperations.swift`、`WorkflowMusicOperations.swift`。
- `Packages/UI/Sources/DWorkbench/Workflow/WorkflowLanguageExamples.swift`。
- `Packages/UI/Sources/UI/Views/Workflow/WorkflowCanvasView.swift`。
- `Packages/UI/Sources/UI/Resources/Localization/zh-Hans.json`、`en.json`。
- 新 `Packages/UI/Tests/DWorkbenchTests/WorkflowMediaPresentationTests.swift`、新 `Packages/UI/Tests/UITests/WorkflowMediaPresetTests.swift`。

行为：新视频节点和新E04采用320×192/17帧/16fps/50步/CFG6/shift8；UI可显式应用三个普通参数预设：连通性256²/17/16/4/5/5、完整短预览320×192/17/16/50/6/8、官方480p起点832×480/81/16/50/6/8。均不自动运行，不按16GiB限制用户；预算由用户明确填写。已有节点/历史及缺字段的执行回退不变。预设只原子更新列明七项参数，保留modelID、seed、提示、负面提示、内存预算及其他数据，支持原有撤销；只读/运行中不可应用，旧回调不能修改别的图。说明4步仅查链路、短预览不是成片保证、大配置未在本机本轮验证。

MRT2音符端口改为可选，直接复用现有 WorkflowMRT2Condition.make：无音符且无和声产生notes=nil不约束；显式空音符产生notes=[]关闭音高但不保证静音；和弦输入独立可用。不新增特殊调度或输入mode键，不改变既有连线。UI清楚展示25Hz/40ms、音高/起音/延续、同音声部合并、非零力度未编码、鼓当前不受约束、有限WAV/48kHz/双声道≤16秒及固定采样值。能力说明不是执行schema。

验收：三个预设参数正确、只显式应用/不启动/不改模型提示等、保存重开与撤销保留；旧节点含4步不被读/展示改写。无音符/空音符/真实音符/单独和弦的实际操作请求不同且保留父资产；现有例子编译、语言包对等、真实hosting挂载。后端请求/解析/保护不改。Lead串行实际比较同模型/提示/seed/几何/引导/shift的4与50步短视频，检查完整解码/耗时/峰值并看图；新无音符模式做真实短生成。未测的更大预设不称已验证。

请求gpt-5.6-sol/high，初交20分钟，禁止重构建/GPU/GUI/网络/安装，Lead统一测试；独立MEDIA树及本run/MEDIA/output、tmp可写，共享Git不可写。初交与两轮修复预算，不改契约。Lead保持共享文档与最终接纳所有权。

## H22 候选与证据范围

Lead 在 `D/WorkbenchApplicationDelegate.swift` 复用实际窗口连接，move/resize/screen/backing/live-resize-end转发后合并一次布局后坐标失效通知；新 `DTests/WorkbenchInputGeometryTests.swift` 验证当前焦点、窗口隔离、屏幕矩形、marked text/selection/undo。本轮无手算候选窗、重建编辑器或强制提交。

R/ime/geometry-r3.json 的原生矩形随窗口移动正确；该独立探针没有保留非空marked range，故只证明普通字符坐标，不能当作组合输入或候选跟随验收。H22具体根因仍需新普通App真人确认；实现使用Apple公开invalidateCharacterCoordinates补足窗口布局之外的通知，尚不宣称已修复。第一次外部探针CGFloat类型歧义仅编译失败，无App/项目副作用。准备复用已有独立引擎目录的忽略本机xcconfig，未改签名身份。

## 实施与复核检查点（2026-09-27）

SAVE：受限Sol/high初交＋一轮修复；候选e614d1bc2cff41ddb493ec0ebf5286aa4be5e955。非实现者检查提交后缓存、真实UUID工具检查点与UTF-8字节保留。初交末尾尝试ps被拒后立即停报；未观察到提权或成功越界，后续明确不再使用ps。详见R/SAVE/permission-review.json。没有把拒绝写成实现质量失败或默认放行。

MEDIA：受限Sol/high初交＋两轮修复；最终b6c6450fb151cd9a66ea98070f8562a1acdcaf0b。第一轮澄清已有冻结语义的错误文案并补真实Store重开；第二轮将嵌套Swift Testing宏拆成局部前置值，保留断言，原因是实际类型编译失败。普通修复额度已用完；非实现者已检查第一轮实际语义和持久化，第二轮为Lead检查的等价编译修正。无权限拒绝。工作树/模型/网络关闭和写根见各route/context记录，隐藏服务端解析未知。

Lead负责H22 AppKit通知、真实模型验收入口和组合；H22非实现者指出并修复同一NSWindow关闭后重连时helper未恢复，保留原delegate。3dd32ae81bf5f899e6289f297ed213053fdd6f6f的3项原生组件测试通过，包含marked text/selection/undo、当前焦点、五类通知及重连；不等于真人候选窗已跟随。测试统计先区分AppKit自己的通知与本helper发起通知，再由最终副作用注入记录，真实调度只有一份。

组合版本ca0ff7a5869bad417ed9ddc6e3a724ba0296c77e已通过UI包测试编译、App测试构建及Workbench 611项CPU检查；UI hosting、真实视频/音乐、普通组合GUI继续执行。不存在以静态解析代替编译或模型运行的结论。

历史保存同一H27-Nodes独立副本（17次运行、约2.44MB、5次真实编辑保存）对照：未合缓存代码ced8036的保存中位0.7983秒、保存后读1.0961秒；合入4438f92后0.7911秒和0.001401秒。优化的是重复纯验证/解码；冷读和完整写校验仍有成本，不保证所有项目或GUI变成常数时间。原项目不写，证据R/lead/save-comparison.json；8项保护测试前后均通过，未放宽篡改、失败和外部变更规则。

真实模型验收入口新增DTests/NodeQualityRealTests.swift，仅opt-in：普通装配/Controller/Store中的独立节点，固定video除步数外完整请求/14GiB预算/step身份，music无输入时notes=nil；严格媒体解码、运行时释放、保存重开和资产摘要。宿主启动前D_UI_TEST_SESSION隔离；使用既有模型与原用途授权，不调用云端。非实现者检查测试语义后由Lead执行，不能称独立模型已执行测试。

输入法普通包为R/delivery/D Quality IME.app，代码3dd32ae，正常D Nodes构建并校验签名，独立85dc7354-a17f-4d33-b66e-09c1e6f1ebb3设置。终端UI受工具策略阻止，未换入口绕过；用户双击启动器。一次保存面板焦点冲突由用户说明是同时使用Mac，随后本人创建专属IME-Quality项目，不列为产品保存缺陷。真人中文/日文移动与缩放结果待回。

构建环境事件：第一次XCTest宿主与测试bundle团队不匹配，后续使用已有DevelopmentSigning.xcconfig统一测试签名；普通包重新构建，未修改签名配置。外部xctestrun脚本一次假设错误schema抛KeyError，未启动测试，改按实际DTests键读取；无扩大权限。R/lead/中保留失败和成功，不覆盖旧日志。


MEDIA一次有界Lead接管：组合UI hosting的4条纯SwiftUI文字AX断言失败；R/lead/media-hosting-diagnosis实际仅读到原生字段与菜单，和既有WorkflowLocalizationTests:234所记录的离屏限制一致。非实现者建议按证据层分开。保留失败日志，将hosting限定为实际检查器挂载/视频音乐切换/无运行无改图，并继续预设纯值/动作/双语言文本/保存重开检查。四条原显示要求未取消，改为本轮普通GUI必验：三个workflow-video-preset-{connectivity,fullPreview,official480p}按钮的实际标签及MRT2能力标题；完成前展示验收不得称通过。Lead没有重写生产媒体逻辑，修复来源不能记为Sol独立通过。

## 用户要求的进度同步与试用交接（2026-09-27）

用户要求先同步GitHub再自行试用；授权此次将未完成验收的进度明确保存到`codex/node-quality-01`，不把候选快进接入源、不改main。开始核对源01758b81527dc27eb4563bf1b66fd1ceab6647ee与候选948a08ceac42897a9143223512485e13630fc313，源仅个人scheme未暂存，候选干净；远端源同01758b8，尚无同名候选分支。没有活动Git hooks或配置过滤器。本次未追加实现、Worker修复或重跑历史模型/成本统计。

以948a08c执行普通D Nodes build，成功且正常资源阶段校验现有四引擎。新`R/delivery/D Quality Preview.app`与独立UUID启动器不覆盖旧IME包；签名完整性、关键文件摘要和启动器语法结果见R/lead/progress-preview.json。本次没有启动新包，当前用户IME窗口未操作；试用不等于真实模型验收通过。非实现者只读核对入口、Debug隔离与资源接线，未声称它另行构建或运行模型。

本次提交只更新当前行动、试用说明与本任务记录；普通包构建版本948a08c、组件受测版本ca0ff7a/8125d94与推送后最终版本分别记录，不把文档提交说成重新实测。最终提交/远端与源个人文件保护核对存R/lead/progress-sync-receipt.json。源码之外的本机App、模型、项目和大证据不上传GitHub。

恢复检查点：源保持01758b8、个人scheme及索引保护；候选代码未变，源码进度同步结果以外部回执为准。写Worker全部结束；本次普通构建与打包进程完成后不运行重模型，用户自行试用。仍需四项媒体原生显示、视频4/50真实对照、无音符音乐及H22真人反馈，之后按原门槛完成源接纳。阶段状态仍为实施中，不因本次推送重置预算或关闭待办。
