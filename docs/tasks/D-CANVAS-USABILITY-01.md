# D-CANVAS-USABILITY-01：节点画布易用性

2026-09-27，r1，实施中。用户批准左节点库、右资产库、标签检索/编辑、拖放及实时连线；四模态简易界面不改。不追加模型、插件、调度器或推理算法。

基线：源01758b81527dc27eb4563bf1b66fd1ceab6647ee；已推送候选e7787e06f5ff409a0293201ee8caf5eb601eb668。本轮沿用空闲Lead候选树/分支codex/node-quality-01，旧QUALITY未完验收保留，不重置修复预算。源个人scheme摘要/索引未暂存状态见本轮before.json；源、旧App、项目、模型与证据不改。

## 当前规格与界面边界

- 左节点库：名称/描述/标签搜索，多标签同时筛选；区分系统事实和可编辑用户标签。操作与已安装模型条目都可加入，模型参数量/量化仅来自明确已核实资料，未知不猜。节点标签用稳定命名空间偏好键，保留旧模型标签键；坏记录只读，增删失败不丢草稿。
- 右资产库：同项目输入和生成资产、预览/类型/名称/标签，搜索筛选、查看和拖入画布。用户标签作为项目元数据；不改原媒体/哈希/来源。必要manifest版本演进备份旧原字节，旧App不能静默吞掉新标签。
- 中央画布：拖动预览位置为卡片/连线共同来源，不逐帧提交；结束仅一次可撤销位置编辑。拖库条目到空白插入、资产到输入节点绑定、输出到输入端口连线，均不自动生成。无效/陈旧/外项目payload拒绝，不读取payload路径。
- 参数与运行结果保持完整，改为清楚的“编辑节点”入口/独立检查器，不用第四常驻窄栏挤压资产库；空图可新建。高级工具封装/技术ID折叠，能力不删。中文/英文同键，系统玻璃材质、原生拖放，无Web运行时替换。

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
