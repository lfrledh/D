# D-CANVAS-USABILITY-01：节点画布易用性

2026-09-27，r1，实施中。用户批准左节点库、右资产库、标签检索/编辑、拖放及实时连线；四模态简易界面不改。不追加模型、插件、调度器或推理算法。

基线：源01758b81527dc27eb4563bf1b66fd1ceab6647ee；已推送候选e7787e06f5ff409a0293201ee8caf5eb601eb668。本轮沿用空闲Lead候选树/分支codex/node-quality-01，旧QUALITY未完验收保留，不重置修复预算。源个人scheme摘要/索引未暂存状态见本轮before.json；源、旧App、项目、模型与证据不改。

## 当前规格与界面边界

- 左节点库：名称/描述/标签搜索，多标签同时筛选；区分系统事实和可编辑用户标签。操作与已安装模型条目都可加入，模型参数量/量化仅来自明确已核实资料，未知不猜。节点标签用稳定命名空间偏好键，保留旧模型标签键；坏记录只读，增删失败不丢草稿。
- 右资产库：同项目输入和生成资产、预览/类型/名称/标签，搜索筛选、查看和拖入画布。用户标签作为项目元数据；不改原媒体/哈希/来源。必要manifest版本演进备份旧原字节，旧App不能静默吞掉新标签。
- 中央画布：拖动预览位置为卡片/连线共同来源，不逐帧提交；结束仅一次可撤销位置编辑。拖库条目到空白插入、资产到输入节点绑定、输出到输入端口连线，均不自动生成。无效/陈旧/外项目payload拒绝，不读取payload路径。
- 参数与运行结果保持完整，改为清楚的“编辑节点”入口/持续挂载的可折叠底部检查器，不用第四常驻窄栏挤压资产库；空图可新建。高级工具封装/技术ID折叠，能力不删。中文/英文同键，系统玻璃材质、原生拖放，无Web运行时替换。

## 验收与责任

复用同一Store/runtime/Controller。CPU：Unicode标签、损坏保护、保存重开/迁移备份、项目隔离/失败不覆盖；多标签检索且不解析文案执行；拖动0.5/1/1.8缩放与负历史布局、边同步/原图不变、一次撤销、切图/删除/只读拒绝；拖入节点/资产/端口类型保护、不提交隐藏模型任务。UI hosting和正常构建单列，真实GUI须验左搜/拖入/两端连线跟随/撤销/右资产标签保存重开、窗口缩窄可达、完整检查器。未改生产推理无需重跑全模型；QUALITY原视频/音乐实测仍待。个人数据不作夹具，只用新隔离项目。

TAGS Worker允许ProjectModels.swift/ProjectStore.swift局部元数据与版本处理、新WorkflowLibraryMetadata.swift及直接CPU测试；CANVAS Worker只改提取的WorkflowGraphSurface.swift、新纯UI拖放类型及直接测试。Lead拥有Controller/Host/库UI、共享语言包与文档。初交+两次修复+最多一次有界Lead接管，各任务独立记录；Sol/high用于数据安全/原生交互，受限CLI预检后实施，网络关闭、独立树/输出/tmp，无Git写权。重要Lead代码由非实现者审查。

TAGS冻结接口：ProjectAsset.tags: [String]默认[]，存在但损坏严格拒绝；Store.updateAsset添加尾参tags: [String]? = nil（nil不改，[]清空）。manifest18与17原字节迁移备份，不接纳13—15，不改变WorkflowArchive版本。LibraryTags.validate([String]) throws -> [String]至多24/32个Swift字符、trim、原字节不正规化、非法整次拒绝；LibrarySearch.matches(query:selectedTags:title:detail:systemTags:userTags:)纯值搜索（查询按空白分词AND，标签AND，大小写/宽度/重音不敏感）。标签不是执行条件。模型量化/参数量投影由Lead基于实际来源接线。

## 借鉴与增量准备

React Flow的共享交互状态/端口身份、Algolia的分面标签筛选与Apple Transferable原生拖放为参考。React Flow MIT但属Web，swift-flow MIT仍需替换现有展示模型，本轮不直接替换现有执行/存储。不拷贝外部源码、不新增依赖。

- https://reactflow.dev/learn/concepts/adding-interactivity
- https://reactflow.dev/learn/customization/handles
- https://github.com/xyflow/xyflow/blob/main/LICENSE
- https://github.com/1amageek/swift-flow
- https://www.algolia.com/doc/guides/managing-results/refine-results/faceting
- https://developer.apple.com/documentation/swiftui/adopting-drag-and-drop-using-swiftui

Lead先将现有Surface/Card/Geometry原样移动到WorkflowGraphSurface.swift，便于独立所有权；不改变行为。最初准备脚本的stdin UTF-8解析失败发生于执行前、无写入，后改用ASCII脚本和结构化文件补丁，非权限事件。

证据：`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-CANVAS-USABILITY-01/run-20260927T140634Z`。后续追加固定提交、模型/权限预检、实现/修复/审核、真实测试与试用交付。完成候选推送后交用户第二轮试用；不自动发布/main，不将旧未验媒体结果升级。

## 组合审核（进行中）

准备代码dcf66cc5867ad6c2450943ebd4a716788006d114；TAGS候选00ed86072cfdcfc6ecb087ec7d8d2ab220a866d5，CANVAS初交c5cc4db0d4703524b6984973083662ab155a52ec。两个受限Sol/high CLI实施时间确实重叠，预检/turn_context/写根见run各任务route-accepted.json。隐藏服务端身份未知，未使用全访问Worker。初交均只语法解析，Lead负责实际类型检查和测试，未将自检记为通过。

TAGS修复1：查询漏搜标签（仅筛选器搜标签），补“标题无此词、仅标签有portrait q8”反例并修复；保留初交记录。CANVAS修复1：取消/切图后旧手势可能重新创建session；修复2：Swift6 PreferenceKey常量、稳定原点可达性、嵌套复制body的完整端口身份。无权限拒绝/提权记录。预算仍按原初交+2轮，不另编号。

Lead接线由三位只读非实现者检查（非独立测试模型验收）。发现并修正：编辑按钮应选实际nodeID；Asset Task创建前固定插入目标；双sheet播放入口；插入校验失败不应选不存在节点；资产引用刷新失败不留旧投影；模型同revision多安装不宣称当前选择。Lead新增controller反例覆盖目标切换/外项目、负坐标提交与一次撤销、模型种类拒绝、标签保存重开、无推理调用。负坐标展示与提交统一，不把历史布局夹为0。

manifest17→18是资产标签的最小兼容演进，旧文件原字节备份为project.v17.backup.json；旧版App不应打开新格式。用户现有工程本轮不作为迁移夹具。右库标签是项目元数据，未声称媒体文件已内嵌。新增Finder拖文件/导入按钮只走原Store复制与校验，不自动运行节点。

首次组合编译分别发现Lead错误port.kind（契约实际为kinds）和Worker PreferenceKey共享可变状态；失败日志保留在combination-compile/combination-r2，不删改断言。旧migration测试的“当前格式17”按批准schema18改为currentSchemaVersion，旧16/12原字节备份和候选13—15拒绝断言保留。最终受测SHA/GUI/构建/推送待下面补充，当前不宣称阶段完成。

## 工程交付检查点（2026-09-27）

当前受测组合：`ec0027cda72ee7120df6eb7b034cb53d1e2433e8`。`lead/ui-regression-r2`全UI包通过：DWorkbench 621、UI/hosting 180、ModelLibrary 23，合计824项；不叠加先前32项局部检查。第一次全包只有旧本地化菜单断言仍找“模型”，按本轮真实迁移到“更多”更新，中英草稿/选区/参数/控制器身份与零推理断言不改，第二次全包通过。`lead/app-build`相同SHA普通D Nodes正常开发签名构建通过，`lead/app-signature.txt`验证产物完整性通过。

CANVAS两轮修复后，Lead完成一次有界SDK/测试接管：`DataRepresentation(contentType:)`改为本机双向传输签名；Testing宏中的mutating调用先求值再断言，未改变期望；空画布拖入接到真实Controller；节点负落点与首次插入撤销接线统一。TAGS两轮内修复标签查询遗漏和规范等价字节替换；原始失败/修复记录保留。Lead共享接线及这些修正有非实现者只读复核，详见`lead/review-summary.json`；不声称另一个模型执行了全部测试。

普通试用包：R/delivery/`D Canvas Preview.app`；双击同目录`启动新版节点画布.command`，唯一独立D_UI_TEST_SESSION记录在`trial.json`，不要直接双击App本体。使用说明在同目录`使用说明.md`。Xcode入口仍是本候选树`D.xcworkspace`/`D Nodes`，正常Run使用既有资源打包流程，没有手工修改包内实现。

**原生交互尚待**：已请求本人双击隔离启动器，随后Lead验证左库查询/拖入、连接与移动、撤销、右库标签及重开、Finder拖入和窄窗编辑。当前桌面入口不能传隔离启动环境；未改系统权限、未关闭旧Preview，也未通过不隔离启动绕过。CPU/hosting不是实际鼠标拖放；本轮尚未直接观察按住鼠标期间的连线跟随，不将此项写成已原生验收。集中记录H28。

左库搜索词在名称/说明/系统与用户标签中逐词AND；标签筛选AND，用户标签24个/每个32Swift字符，坏偏好保持只读。已登记模型用固定版本映射保留旧模型标签键；未知参数量不猜。右库使用同一Store资产，原媒体/摘要/来源不改，标签随manifest18保存。旧资产无流程引用时须显式加入画布后预览，不在浏览时偷偷改项目；音符等结构数据仍由节点数据检查入口展示。

本轮源始终`01758b81527dc27eb4563bf1b66fd1ceab6647ee`；scheme内容、SHA256 ca3635d88aa5a15397b90e528667c66c0e6db7e596176e885c79d194b544206c、索引blob及未暂存差异均与开始一致，见`lead/protection-after.json`。普通D与旧Quality Preview未替换/关闭，真实用户项目不作夹具。两个写Worker及自身构建/测试命令均结束；只读审阅结束。隐藏服务端解析、订阅费用和完整Lead成本unknown，累计CLI快照未相加。

状态：**工程实现、CPU/hosting及普通构建通过，候选供第二轮试用；原生交互待完成**。先同步候选`codex/node-quality-01`，不推进main，不因本轮UI变更跳过旧QUALITY未验模型/IME路径接纳到源。最终仅文档提交SHA及远端校验写外部`lead/final-receipt.json`，不反复自引用提交。

恢复：从AGENTS/CURRENT_ACTIONS→本记录，核对真实HEAD、源scheme、`trial.json`启动身份/进程与H28回复，再做原生交互。无新增模型或GPU运行，不恢复其他产品阶段。用户第二轮试用后只按具体反馈继续。
