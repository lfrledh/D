# D-NAV-ASSET-01 — NAV2 / spec revision 1

状态：准备。Lead维护此规格；Worker不得编辑。批次NAV-20260911；源fee074c70fb39bd9a99d146b708d6d80fd2d820e；实际共同执行SHA见preflight-request，包含本规格。请求gpt-5.6-terra/medium。

目标：实现本项目只读资产投影与浏览器，API冻结：
public enum ProjectResourceID: Hashable, Sendable { case media(UUID), document(UUID) }
public struct ProjectResourceItem: Identifiable, Equatable, Sendable，public let id: ProjectResourceID, title: String, mode: CreatorMode?, mediaType: String, originDocumentID: UUID?, textPreview: String?。
public enum ProjectResourceCatalog，public static func items(in manifest: ProjectManifest, mode: CreatorMode, includeOtherModes: Bool) -> [ProjectResourceItem]。
@MainActor public struct ProjectResourceBrowser: View，init(manifest: ProjectManifest, mode: CreatorMode, availableModes: [CreatorMode], assetURL: @escaping (UUID) -> URL?, onOpenDocument: @escaping (UUID) -> Void)。自身选择/筛选state，不改业务。默认本模态，切模式/项目reset全选/preview；assets-filter-other Toggle，resource-<media/document>-<UUID>行，asset-preview。known recorded MIME分类（image/png,jpeg,tiff, audio/wav/x-wav/wave/x-caf,mpeg,flac等已知表），unknown保留在全部，不按后缀/所属doc猜。文本doc正文是真文稿行，不编路径/摘要。来源优先实际job.documentID，或实际sourceAssetID/所持audioDraft来源，需确认存在/对应可用mode才能显示explicit打开来源；不要让来源不存在自动指向activeDocument。
只使用manifest值+授权已解析assetURL做本地预览。PNG/JPEG等NSImage读取需限定常见图像且文件体积预算（如32MiB），没有URL/文件不读到明确不可用；文字显示限定长度正文；音频先提供实际metadata说明而不自动播放，未知格式明确原因，不下载/URI/QuickLook插件执行。选择/过滤仅更新本View state，不调用存储/导航，只有explicit打开来源callback。先展示真实文件/文稿引用，不做副本/转换/采用/引用操作。可使用ProjectResourceItem额外默认字段用于metadata，但冻结字段不改。
验收真实manifest投影：混模态文件、本模态默认/全部unknown、名同ID类型不同、无job/丢失origin、不误按owner分类、文稿Unicode预览、不读取未知URL；callback仅explicit打开，过滤/预览不触发。布局窄sidebar约200时无水平溢出，详情可滚动。测试不构造依赖新包/新app，只本地CPU/NSHostingView。

仅允许文件：
Packages/UI/Sources/UI/State/ProjectResourceCatalog.swift
Packages/UI/Sources/UI/Views/ProjectResourceBrowser.swift
Packages/UI/Tests/UITests/ProjectResourceBrowserTests.swift

必读AGENTS.md、此任务、CreatorMode.swift、WorkspacePresentation.swift；ProjectModels.swift及现有局部视图/测试按需读。不要读取全部历史。非目标：共享会话、工作台装配、存储、生成、权限签名、新依赖、任务记录。Worker禁止commit及递归派工。

目录：/Volumes/CodexProjects/Codex/D-Worktrees/D-NAV-ASSET-01。仅本工作树及/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-UI-HIERARCHY-01/run-20260911T001411Z-implementation/D-NAV-ASSET-01/worker-output、/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-UI-HIERARCHY-01/run-20260911T001411Z-implementation/D-NAV-ASSET-01/tmp可写，网络false。不写共享.git、源树/应用/模型/旧证据。正常输出worker-output；TMPDIR/CLANG_MODULE_CACHE_PATH/PYTHONPYCACHEPREFIX/XDG_CACHE_HOME都在此tmp。无需全包构建；可CPU静态检查/本文件Swift解析，测试由Lead串行跑原SwiftPM离线入口。SwiftPM内层沙箱拒绝则停报，不禁用/提权。Python仅tokenize.open+compile内存检查，不默认py_compile。预授权安全降级仅同一已授权tmp内路径；未知权限事件立即暂停Lead，不能自行绕行。

首次仅PRECHECK：返回任务修订、实际cwd/root/commonGit/HEAD/branch、允许文件和验收摘要，暂停。Lead核对CLI实际模型/effort/workspace-write/networkfalse/writeRoots后同线程IMPLEMENT。实现初交+最多2修；最多900秒，阻塞及时返回。结果在回传消息/worker-output：文件、变更原因、检查/异常、剩余风险、自有进程状态。规格和验收不许降级。


## NAV2 候选交付与预算结果
Terra/medium线程01a08dd8-edd5-7960-a480-1564cffa5b49，实际请求/上下文目录、受限写根和禁网匹配。初交后Lead指出边界/覆盖缺口；修复1测试夹具参数错误导致编译失败；修复2类型问题解决但窄窗几何测试失败。普通两修用尽，失败候选8f6d10cd6467661b1288cf4992d18f244db2c6c3保留。
Lead一次限定测试收尾采用每个宽度独立NSHostingView，并按筛选真实重置先清空后显式选择；断言未删、生产代码未重写，3方法通过。候选7d411f279fe99dad83b93c8ab8dcc9ef94b9f6d6已合入隔离NAV树；Sol/high followup非实现者检查接受该测试差异。归因为Terra生产实现及两修、Lead测试收尾，不是Terra独立成功。初实施00:26:01—00:29:56 UTC，与壳层Worker真实重叠；各轮耗时保存process.json，实际订阅费用unknown。原生最终资源筛选/预览仍等待完整NAV GUI验收，不以离屏测试替代。
