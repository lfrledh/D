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

## 当前恢复点

准备中；源/M0候选不变。执行基线在外部job/route记录；Worker未获实施前不写。下一动作核验两路预检，再并行模块实现，Lead接模型绑定。结案更新CURRENT_ACTIONS、实际导航、扩展约束及本任务记录；不复制旧阶段为当前。
