# D-NODE-BOUNDARY-01：节点扩展边界与显示语言

2026-09-26；spec_revision 1 / contract_revision boundary-v1。用户批准实际边界整理、命名/文档和可加载语言包架构。源仍58603870719a52ff07b6bb6e4d6d09e02c23901a；候选起点bbf508024a80250b9e4b468e1f5713b7b13dcc13（M0）。本批独立工作树D-NODE-BOUNDARY-01/分支codex/d-node-boundary-01；不改M0候选。M0 T15真实断网仍未执行，不改记完成，不将它随新批带入源。AP1/CORE/I2V不接纳。

## 有限目标与责任

- 模型节点按自己的操作/模型身份解析，多个同类节点不借当前页面模型；保留旧modelID、已发布数据和既有runtime/租约。相同操作可选具体实现，拒绝缺失/不兼容，不fallback。既有图文实际适配与数值不变，不接新模态。
- 静态能力模块归拢当前操作定义、执行及格式实现；共享注册/Store/运行时保留。文件按职责归入Workflow/Operations、Workflow/Models、Media等实际目录，不为改名批量移动公共核心。
- 中英显示＋外部纯JSON语言包，显示键与operationID/模型ID/参数值/用户正文彻底分开。覆盖本批画布chrome、定义投影及语言入口；原有各模态页面和服务String错误/计划的全面翻译另记，不反向解析中文文案。无插件市场、热代码加载、新运行时、项目大迁移或发行。
- Lead独占WorkflowTypes/Operation/Services/Controller/Registry/Builtins/ProjectSession及App装配、Package.swift和文档。CODEC、I18N独立Worker在专属树写限定文件，暂停/结束后Lead合入。

## 模型行为冻结

每个执行节点使用operationID＋其modelID确定绑定；准备期按节点保存绑定。空modelID仅在首次明确运行时解析当前默认并冻结进运行快照，非空ID绝不偷偷改写。项目ModelLibrary和LocationAccess继续负责安装/授权；文字登记复用既有校验与书签，已选其他模型不可使已绑定节点改用新模型。运行占用到drain/release后才释放，准备失败释放已经获取的全部租约。同一图A/B模型交替、未知ID拒绝、配置变化/关闭/取消、历史模型缺失和重开保护必须检查。模块缺失保留原图数据并明确只读/阻塞，不删除作品。GUI选择回调冻结nodeID/项目，不按回调到达时选中项绑定。

## I18N 工作包（r1）

允许：Packages/UI/Sources/UI/Localization/LanguagePack.swift、UILanguageStore.swift；Sources/UI/Resources/Localization/en.json、zh-Hans.json；Sources/UI/Views/LanguageSettingsView.swift；Sources/UI/Views/Workflow/WorkflowCanvasView.swift；Tests/UITests/UILocalizationTests.swift、WorkflowLocalizationTests.swift（上述均在Packages/UI）。不得改HostView/WorkbenchView/App/Package.swift/共享契约/服务/存储/文档。读取实际Canvas、UI package、现有hosting测试；不全读历史。

公共装配API：@MainActor @Observable public UILanguageStore，init(settings: UserDefaults? = nil, directory: URL? = nil, preferredLanguages: [String] = Locale.preferredLanguages)；selection只读、effectiveLanguageIdentifier只读、availableLanguages（Identifiable，id/displayName）、select(_ identifier: String) throws（system为跟随系统）；text(_ key: String, fallback: String, arguments: [String:String] = [:]) -> String；importPack(data: Data) throws -> String。public LanguageSettingsView(store:)；EnvironmentValues.dLanguageStore: UILanguageStore? 默认nil，Canvas无注入仍用原中文fallback，不崩溃、不写真实偏好。Lead注入生产/测试suite及应用容器目录。实现可加私有辅助，不改上述含义。

包schemaVersion=1，locale、displayName、strings[String:String]；纯JSON≤512KiB，≤2000项，每项≤4096字符，key≤160字符，只接ASCII命名键。UTF8/版本/值类型/locale/占位验证失败不改变当前语言和旧包。命名占位{count}只作一次字面插入，不printf/代码/HTML/网络；已知键占位集合须匹配内置英文，未知规范键可保留但不使用并报告，不依赖已安装模块才能读包。缺键按选中包→内置对应语言→英文→调用fallback；内置中文/英文键与占位齐全。外部包不能覆盖内置语言，重复外部locale默认拒绝，不覆盖用户旧文件；先验证再以原子不覆盖方式保存到明确directory，再发布状态。损坏已保存包可见错误并安全fallback，不静默删数据。nil目录/偏好纯内存。外部不保存源绝对路径，不自动访问URI。

切换仅更新显示，不.id(language)重建View/controller/task、不改输入数字Locale、不翻译node.title/图名/项目名/参数原值/模型名/提示/路径/来源JSON。以稳定operation/field/port ID查展示key；不要按中文原文搜索替换。controller原progress/error/plan原样显示，尤其不解析planLines。UI自有状态枚举/类型/按钮可翻译，AX identifiers固定。资源通过Bundle.module。默认跟随系统，系统无支持语言回退英文。语种切换不承诺RTL/专业翻译全面验收。

至少测试缺键fallback、非法版本/占位/大小/重复导入失败不改旧包或偏好、重开恢复和隔离suite、字符串中的Unicode/百分号/占位值不二次解释。实际hosting待确认草稿/选择/缩放切换语言不丢、不执行、保存ID/参数不变，窄宽长文本操作可达。Worker仅写测试，不运行Swift构建，Lead串行执行。

## CODEC 工作包（r1）

允许：Packages/UI/Sources/DWorkbench/Workflow/WorkflowImageProcessor.swift；新增Packages/UI/Sources/DWorkbench/Media/ImageCodec.swift、ImageCodecRegistry.swift（必要实现小文件只能位于这两个文件）；Tests/DWorkbenchTests/WorkflowImageProcessorTests.swift、ImageCodecRegistryTests.swift。不改Builtins/Registry/Services/Store/UI/Package/文档。

把PNG/JPEG格式身份、签名检测、编码选项/alpha和质量规则从processor封闭enum分离，提供静态可注入codec登记。沿用ImageIO/CoreGraphics、原PNG/JPEG字节识别/UTI/编码后回读和像素保护；不引新格式或降限制。不要求每codec一个package。现有process(Data,operationID,parameters)兼容；可加默认codecs: ImageCodecRegistry = .standard，提供public static standard和public可注入构造、格式ID列表供Lead组装参数选项。codec实现与登记可以独立增添，processor不按png/jpeg名称分派专属行为，通用几何/预算/原件保护仍共享。保留现有png/jpeg参数值、质量、白黑底、EXIF/sRGB/尺寸/64MiB/32Mi像素等冻结行为，证据metadata不谎称精确保留原色彩。

必需反例：重复ID/UTI与歧义签名拒绝，禁用JPEG时明确拒绝不改PNG，不支持/损坏/多帧拒绝，非法参数不产生输出，alpha与背景、尺寸/方向/格式回读与原有测试一致。只用小合成夹具；不实际RAW，不网、不GPU。模块扩展测试使用明确fixture codec即可，不能称新生产格式支持。

## 执行/验收/保护

两Worker Sol/high（gpt-5.6-sol），跨SwiftUI/安全数据或ImageIO边界；各初交＋最多2针对性修复，15min每轮；之后一次有界Lead接管，历史M0预算不重置。CLI显式workspace-write/network=false、独立树+output/tmp，禁止共享.git写、网络/构建/GPU/GUI/递归。预检先只读，Lead核验运行元数据后IMPLEMENT；仅受控检查/失败夹具不算未知权限事故。拒绝先停报，禁止猜路径绕过。Lead每轮检查异常/保护再派修复。

证据在D-Development/AgentTrials/D-NODE-BOUNDARY-01/run-20260926T045011Z。不缓存到源树，重构建/真实图文/GUI串行独立输出。按影响执行UI包、模型绑定/codec/lang专属反例、现有M0实际图文回归、普通签名App语言与模型选择GUI；锁屏/本人动作进H清单，不伪称通过。重要Lead实现经非实现者审核；被测代码/最终文档SHA分开。未验新路径不默认覆盖源。只显式暂存，保护源scheme和原作品，不reset/clean/stash/rewrite/main，不关闭未知App。

## 准备时检查点（历史）

准备记录0580c6114a102045ea983ffcc0ef750e6ddcba05；源/M0候选不变。后续实施已发生，以下结果替代“待预检”状态。原r1规格/权限和已消耗预算不倒改。

## 2026-09-26 实施、审核与验证结果

状态：**代码/CPU/装配及真实模型回归通过；普通App原生补验和M0离线依赖待完成，未接纳源。** 受测组合`76bd5963c779c74268c69fa6a4851533768ea4c3`。最终文档提交自身SHA只写外部`lead/final-handoff.json`，不反复amend。当前基线和下一动作唯一入口为CURRENT_ACTIONS。

### 实际改动

1. `Workflow/Operations`按文字、图像、资产归拢定义与执行；共享验证保留在WorkflowOperationSupport，Builtins仅静态装配；移除空行操作仅移动文件，类型/ID不变。
2. `Workflow/Models`新增运行绑定与Klein配方、私有授权记录；ProjectSession复用ModelLibrary/LocationAccess解析准确模型，WorkflowServices按节点UUID持有模型。图中同类节点可选择不同已登记模型；关闭等待/取消/准备失败均保留资源责任。模型选择回调捕获图/节点/操作/旧绑定，不能串到后选节点。
3. PNG/JPEG差异移入Media/ImageCodec与静态登记；共用几何/像素预算、单帧保护与回读，校验真实MIME/尺寸/方向/位深/色彩。新策略仍限当前ImageIO能力；没有凭此宣称RAW或任意解码器已支持。
4. UI/Localization及Resources/Localization建立中英和数据语言包；App统一注入，设置和工具栏均可进入，画布按稳定ID投影显示。原工作流参数、ID、正文、用户命名、来源JSON不翻译、不迁移。
5. 文档导航区分源基线、M0和本批候选；历史2026-09-24接线表明确加日期范围，不再冒充全部当前状态。没有清理旧公共包/候选、批量改名核心或升级图schema。

### 派工与来源

| 部分 | 请求与可观察设置 | 实施/修复/Lead介入 |
| --- | --- | --- |
| CODEC | gpt-5.6-sol/high；线程01a0dc10-82f3-7462-9b28-38079442b502 | 初交7dfd5a3，非实现者发现MIME/方向/质量边界后修复1为3b2d1bd；初交479.5秒、修复250.3秒，未用修复2 |
| I18N | gpt-5.6-sol/high；线程01a0dc10-830a-70d2-a769-b4f6edbdbe3c | 初交＋修复1归入ceb9be1（有界读取/hosting）；修复2为6237999（AppKit编译）；854.1/387.0/168.1秒。Lead有界接管完成失效语言精确回退及hosting观测修补，不记为Sol独立通过 |
| 共享绑定/装配/测试 | Lead；不以自述推断服务端身份 | Lead实现；m0_execution_review非实现者审阅并给出关闭等待、重定位与实际request断言建议；boundary_i18n_review审阅语言/codec及Lead关键修补 |

两Worker初交实际重叠约479秒，各独立工作树/分支/受限CLI写根，network=false，未授予公共.git写权限，由Lead逐项提交。创建/运行元数据在`i18n`/`codec`的request、route-accepted、audit文件；隐藏服务端解析unknown。普通预算保持初交+最多2修复，I18N已耗尽普通修复后一次Lead接管，不再另编号刷新。

I18N初交可选shell进程替换比较被`/dev/fd`权限拒绝，未成功越界、未扩大权限，停止该比较并在交付报告；Lead逐条读事件并保留`lead-permission-event-review.json`。修复2的两次搜索退出1是SDK路径检索无匹配，非权限拒绝；无运行构建/网络。线程结束与进程退出分开记录，所有写Worker进程均退出0。

用量只列可观测各轮墙钟；CLI事件含线程累计快照，未相加当增量。完整Lead成本/任务订阅扣费/准确token归因unknown，不用API价格补造，也不据单批认定成本最优。

### 验证矩阵

同一受测代码76bd5963；每项原始命令/环境/HEAD/退出在本run对应result.json。

| 检查 | 本次实际结果 | 证据/边界 |
| --- | --- | --- |
| 完整UI包 | 127 UI、23 ModelLibrary、459 DWorkbench通过 | lead/combined-ui-final；含隔离suite、坏包/占位/超限/符号链接/FIFO、格式反证、节点生命周期、hosting |
| App测试构建 | 通过 | lead/app-build-final；不等同普通签名GUI |
| 真实双文字模型 | 通过，测试4.50秒 | lead/real-model-bindings：Qwen0.5B a5339a4131f135d0fdc6a5c8b5bbed2753bbe0f3 与1.5B 8b403126fc14f14cfc99bb4cfa72ecbc129ea677；改变普通默认后，同进程项目重开，检查实际request目录/revision与资产modelIdentity，不只检查快照标签 |
| 原有真实图文主链 | 通过，测试86.16秒 | lead/real-m0-regression：Qwen0.5B＋Klein4B q8 ef52ee019fd1d0e75ae4deb40476ba65989716d7，512²/4步/guidance1/seed42、43、44；文字改写、3候选、明确采用、JPEG导出、保存重开、文字/图像取消释放、独立文稿请求/来源对照 |
| 普通独立App | 构建及codesign完整性通过；沙盒开启，无temporary-exception | lead/regular-app-build、regular-app-manifest.json；独立DerivedData-Regular，未启动GUI |
| 原生GUI/外部包文件选择器 | **未执行** | CUA确认锁屏，lead/gui-blocked.json；H26 |
| 真实断网 | **未执行** | H25/M0 T15；本轮offline flags防依赖联网，不证明网络确实断开 |
| 新模态/音视频/RAW/任意插件/干净Mac发行 | **未执行且本批未改变相应后端** | 不做全模态GPU重复基准，不将组件测试外推发布 |

完整失败留档：combined-ui-1因新增hosting用裸NSObject访问AX而编译失败；修复2后combined-ui-2有两个测试观察问题。文件URL尾部目录斜杠不同但实际执行路径确为new-copy，focused-boundary-3打印实值，按标准化路径核对并明确排除old-copy。离屏公共AX能看到“添加样例/模型”，不暴露所有SwiftUI绘制按钮；Lead改用同一host切换前后精确中文双项→英文双项，保留编辑器/草稿/选区/图/无执行断言，非实现者确认符合原观测要求。focused-language-4原失败保留，最终组合全过；没有删断言/降低模型精度/拿mock代替真实推理。

waiting人工确认编辑器还经历中英切换及820↔1320宽度，保持同一编辑器/Unicode草稿/选区/无自动决定和推理。它是离屏hosting，不证明原生输入法/所有控件布局。

### 使用及扩展方法

- 本批源码：`/Volumes/CodexProjects/Codex/D-Worktrees/D-NODE-BOUNDARY-01/D.xcworkspace`；scheme D。打开源码不是启动已验发行版。
- 试用使用本run独立普通App及`lead/Launch-Boundary.command`（产物验签后生成）。入口为项目内“流程画布”；选具体改写/图像节点，在modelID处选择已登记模型或显式导入文件夹。显示语言从工具栏地球图标或D设置进入。M0基本可编辑样例用法见M0_TRY，但该文的旧App路径仍指旧M0版本。
- 语言包从`Packages/UI/Sources/UI/Resources/Localization/en.json`复制结构，换locale/displayName并翻译strings值。导入后显式选择；缺词回退，已有同locale拒绝覆盖，坏包不删除。示例：`{"schemaVersion":1,"locale":"fr","displayName":"Français","strings":{"workflow.action.save":"Enregistrer"}}`。包只含文字数据，不安装/执行代码。
- 同类操作通常新增Operations下实现和Builtins登记；新增ImageIO格式实现新增codec并登记/测试；新的模型家族仍需真实适配/资源/契约/数值测试，不能只加卡片。新UI文案新增稳定键及双语/占位检查。具体规则见BACKEND_EXTENSION_CONTRACT，不另建泛用平台。

### 恢复检查点

源58603870719a52ff07b6bb6e4d6d09e02c23901a和M0候选bbf508024a80250b9e4b468e1f5713b7b13dcc13均保留。本批候选包含M0；T15和H26补验前不推进源。个人scheme哈希ca3635d88aa5a15397b90e528667c66c0e6db7e596176e885c79d194b544206c/index9c76916bdc97c2d4298cefe64e0b0fae3380573e继续未暂存；原件/模型/旧App未操作。最终核对在lead/final-handoff.json，恢复先查实际Git/进程/权限再续。

写Worker已结束，非实现者源码审阅与新上下文接手均执行；后者只从AGENTS/CURRENT_ACTIONS起读，准确找到源/候选差别、语言覆盖和H25/H26，指出准备检查点未替代，已在本节修正。最终构建/自有进程/保护核对完成后记录外部回执。下一动作仅补集中验收，再接纳本批；不自动新增节点或发布。

### 普通产物与最终停点

独立普通App：本run `cache/DerivedData-Regular/Build/Products/Debug/D.app`，受测代码76bd5963；构建55.02秒，codesign deep/strict验证通过，沙盒true，既有开发签名get-task-allow与原权限保留，无临时测试例外。四个关键文件的SHA256/大小/修改时间及entitlements在`lead/regular-app-manifest.json`。`lead/Launch-Boundary.command`已生成但未执行，使用每次独立D_UI_TEST_SESSION；不会覆盖普通App。其隔离偏好用于试用，不把项目书签混入普通偏好，重开项目仍可显式选择。

本批GPU/构建/测试自有进程均已完成；没有后台等待解锁或断网脚本。下一步是本人返回时集中补H25/H26，满足依赖后接纳组合；目前保留候选，不推进源、不推送、不删除分支或证据。新上下文恢复必须读CURRENT_ACTIONS并核对真实状态；旧试用说明不替代本批普通App证据。
