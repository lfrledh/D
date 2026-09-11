# D-NAV-SHELL-01 — NAV2 / spec revision 1

状态：准备。Lead维护此规格；Worker不得编辑。批次NAV-20260911；源fee074c70fb39bd9a99d146b708d6d80fd2d820e；实际共同执行SHA见preflight-request，包含本规格。请求gpt-5.6-sol/high。

目标：实现无存储副作用的原生SwiftUI壳层。公共API（不能自行改签名）：
@MainActor public struct ProjectChooserView: View，init(recentProjects: [RecentProjectSummary], isBusy: Bool, onNew: @escaping () -> Void, onOpen: @escaping () -> Void, onRecent: @escaping (String) -> Void, onModels: @escaping () -> Void)。项目首页新建/打开/最近记录；不扫描/恢复目录；使用existing accessibility IDs new-project/open-project/open-model-library，最近项recent-project-<id>。
@MainActor public struct ProjectWorkspaceShell<Sidebar: View, Editor: View, Inspector: View>: View，init(projectName: String, mode: CreatorMode, availableModes: [CreatorMode], hasInspector: Bool, taskCount: Int, onMode: @escaping (CreatorMode) -> Void, onBack: @escaping () -> Void, onTasks: @escaping () -> Void, onModels: @escaping () -> Void, @ViewBuilder sidebar: () -> Sidebar, @ViewBuilder editor: () -> Editor, @ViewBuilder inspector: () -> Inspector)。顶项目名/返回项目/项目任务/模型库；次层独立顶部模态栏；布局sidebar200左右/editor可伸缩/inspector约290。参数只在hasInspector；窄宽先参数popover，再sidebarpopover，不能裁切，不强设总minimum超过860。mode为输入value，点击只callback，不乐观本地切换。IDs creator-mode-image/text/audio、back-to-projects、open-project-tasks、toggle-inspector、toggle-creations。
@MainActor public struct ModalityDocumentList: View，init(documents: [ProjectDocument], mode: CreatorMode, selectedDocumentID: UUID?, onSelect: @escaping (UUID) -> Void, onCreate: @escaping () -> Void)。只列本模态文档/空态/新建，选行callback。ID document-UUID；保留image new-document，text new-text-document，audio new-audio-creation。
全部只是展示，不引入WorkbenchModel/ProjectSession/文件IO。液态玻璃用项目现有原生API，内容中性；尊重reduceTransparency、reduceMotion。可加入internal observingLayout测试hook，不能为测试伪造布局。验收纯回调与真实NSHostingView布局，860/1024/1440、长中文emoji、空态、只supported modes、禁用、弹出参数可达；不依赖必须存在特定NSScrollView私有层次的假设。所有SwiftUI测试mainActor串行，避免后台GUI抢前台，不启动NSApplication或强制activate。

仅允许文件：
Packages/UI/Sources/UI/Views/WorkbenchNavigationViews.swift
Packages/UI/Tests/UITests/WorkbenchNavigationViewsTests.swift

必读AGENTS.md、此任务、CreatorMode.swift、WorkspacePresentation.swift；ProjectModels.swift及现有局部视图/测试按需读。不要读取全部历史。非目标：共享会话、工作台装配、存储、生成、权限签名、新依赖、任务记录。Worker禁止commit及递归派工。

目录：/Volumes/CodexProjects/Codex/D-Worktrees/D-NAV-SHELL-01。仅本工作树及/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-UI-HIERARCHY-01/run-20260911T001411Z-implementation/D-NAV-SHELL-01/worker-output、/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-UI-HIERARCHY-01/run-20260911T001411Z-implementation/D-NAV-SHELL-01/tmp可写，网络false。不写共享.git、源树/应用/模型/旧证据。正常输出worker-output；TMPDIR/CLANG_MODULE_CACHE_PATH/PYTHONPYCACHEPREFIX/XDG_CACHE_HOME都在此tmp。无需全包构建；可CPU静态检查/本文件Swift解析，测试由Lead串行跑原SwiftPM离线入口。SwiftPM内层沙箱拒绝则停报，不禁用/提权。Python仅tokenize.open+compile内存检查，不默认py_compile。预授权安全降级仅同一已授权tmp内路径；未知权限事件立即暂停Lead，不能自行绕行。

首次仅PRECHECK：返回任务修订、实际cwd/root/commonGit/HEAD/branch、允许文件和验收摘要，暂停。Lead核对CLI实际模型/effort/workspace-write/networkfalse/writeRoots后同线程IMPLEMENT。实现初交+最多2修；最多900秒，阻塞及时返回。结果在回传消息/worker-output：文件、变更原因、检查/异常、剩余风险、自有进程状态。规格和验收不许降级。
