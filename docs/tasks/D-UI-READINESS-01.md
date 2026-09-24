# D-UI-READINESS-01：节点UI开发前收尾

spec_revision 2；contract_revision readiness-v1；2026-09-24。source_base `165c54471c4380eb5482312d6c2c70ab97db48a9`。P0—P4同一有限里程碑，当前停点统一以[CURRENT_ACTIONS](../CURRENT_ACTIONS.zh-CN.md)为入口。run `run-20260924T065313Z`，外部证据`D-Development/AgentTrials/D-UI-READINESS-01/`，具体执行base在各job/准备回执记录，不自引用SHA。

## 范围与目标

已核对源真实路径/HEAD、干净索引与唯一scheme orderHint1→6；上一批165c544仅在23fc受测代码后改两文档；既有AP1/CORE候选引用未变，不续跑。N3/N4在当前源码存在：损坏记录与缺失混同，以及删除调用accept清空draft。本轮不重审全库、不删除历史源码。

完成N1代表性结构事实交叉验证、N2身份关系与稳定标签键、N3/N4标签行为、N5当前状态单入口、N6真实UI接线持续回归；用现有DRuntime验证多实现选择/拒绝/取消/释放；交付后端扩展约束与真实服务接线。说明目录仍非执行协议，不解析文案产生规则。无正式节点/图实例/任意DSL/插件/新模型、无生产推理数值更改、无项目schema/ProjectStore/ProjectSession大重构、无签名/权限改变、无候选自动接纳。

## 冻结行为与分工

### TAGS Worker（Sol/high）

允许仅：`Packages/UI/Sources/DWorkbench/Nodes/ModelNodeTagStore.swift`、`Packages/UI/Sources/UI/Views/ModelNodeViews.swift`、`Packages/UI/Tests/UITests/ModelNodeViewsTests.swift`、`Packages/UI/Tests/DWorkbenchTests/ModelNodeCatalogTests.swift`（仅标签测试段），可新增`Packages/UI/Tests/DWorkbenchTests/ModelNodeTagIntegrityTests.swift`。不改WorkbenchView或描述目录。Lead接线新API。

公开读取契约：`ModelNodeTagReadState: Equatable, Sendable { case missing; case valid([String]); case corrupt }`，`ModelNodeTagStore.readState(for:)`；移除会把损坏当空的`tags(for:)`调用。`setTags`每次重读检查，corrupt抛`ModelNodeTagStoreError.corruptRecord`，包括删除为空也拒绝；保留原键和值。缺失允许写入；合法旧值遇非法新写入保持；nil settings纯内存。键仍`D.ModelNodeTags.v1.`+原descriptor.id，最多24/32 Swift Characters及原裁切不变。不提供重建/自动修复。

`ModelNodeDetail(node:tagState:onTagsChange:)`使用新读取状态；损坏显式提示“标签记录无法读取，已保留原数据，暂时不能编辑”，不能同时显示“尚无标签”，新增/删除禁用。可提取当前View真实调用的局部编辑状态动作做测试；不要独立替身。新增成功清空draft，删除成功保留draft，任何失败保留标签和draft、显示错误；切模型仍重置本地编辑状态。读状态后被外部改坏→普通提交也必须拒绝。测试应先在原缺陷上失败（可先补旧API行为反例保留外部补丁及结果，由Lead运行后再改实现），或提供真实旧行为与新回归差异证据；不可改验收求绿。

### RUNTIME Worker（Terra/medium）

允许仅新增`Tests/DRuntimeTests/BackendExtensionTests.swift`；复用现有ControlledBackend/TestGate/TestPlan等，若必须扩展共享测试支持先报Lead。不修改Sources、Package.swift或既有测试标准。不新建调度器，使用一个真实InferenceRuntime注册两个不同ID的同请求形状受控backend。显式选择只调用选中者；missing/unsupported/invalid与实现专属限制不得fallback。取消时直到execute drain/release完才交接其他实现，错误/排队取消释放同样保持。已有等价测试引用、不机械复制所有场景。同步栅栏而非脆弱sleep，有限timeLimit；本轮是CPU结构演练不是真实模型适配证明。

### CROSS Worker（Sol/high，修订2明确分工）

仅新增`Packages/UI/Tests/DWorkbenchTests/ModelNodeCatalogCrossContractTests.swift`；不改原测试/生产目录。N1文字用TextModelProfiles与TextExecutionCapability，图像用ModelCatalog/三ImageExecutionCapability及固定清单，音视频用已有请求/VideoExecutionCapability或仓库固定JSON。对代表性的模型身份/revision、固定参数/必要端口交叉检查；不存在安全来源的人工字段列缺口，不伪造同值capability作独立证据。预期来自真实资源/值型契约，不把文案parse成执行规则；受控改坏目录副本的revision/必填标签/参数输出，应被相同检查捕获。无MLX依赖，不新造注册平台。Lead负责运行与独立复核。

### Lead

共享接线与N1/N6、全部文档、验证和集成。允许Nodes目录的已有描述值来源/必要纯值事实投影、`WorkbenchView.swift`及必要当前调用的局部节点浏览状态/命令提取、对应新测试；当前新增允许路径为`Packages/UI/Sources/UI/State/ModelNodePresentation.swift`及`Packages/UI/Tests/UITests/ModelNodeWiringTests.swift`。前者必须由真实WorkbenchView使用，不能成为仅测试替身；不新造产品服务包装器。文档仅AGENTS、CURRENT_ACTIONS、PRODUCT_GOALS、REPOSITORY_MAP、MODEL_SUPPORT_AND_RELEASE、MULTI_AGENT_WORKFLOW、本文；确需新增仅`BACKEND_EXTENSION_CONTRACT.zh-CN.md`承载P2/P3接线。具体新增代码路径在实施前追加本任务。

## 资源、授权、验收

受限独立CLI，网络关闭、各自独立物理worktree/branch，写根仅自身树及本run输出/tmp；Git共用管理目录只读、Lead代提交。预检只读返回任务/规格/base/Git身份/允许文件/验收，Lead核验请求与turn_context后同链路IMPLEMENT。每个真正新工作包初交＋最多2轮定向修复，之后最多一次有界Lead接管；每轮900秒。旧任务预算不变。禁止递归，禁止worker全App/GPU/GUI/下载/配置/普通数据写入；编译由Lead串行，worker静态检查仅明确无缓存入口（Python tokenize.open+compile、不执行目标）。未知拒绝立即报Lead，只有预先列明安全降级才可恢复一次。

Lead：真实缺陷反例、组件/接线/来源交叉和受控反证、root运行时CPU、工作台CPU、普通签名独立App构建；隔离GUI验证标签草稿/损坏提示/模型切换与重开；源入口回归。只改展示与测试不重跑全GPU。非实现者检查重要Lead改动；未参与实现的只读新上下文仅从AGENTS→CURRENT_ACTIONS进入作9项接手验收。文档链接/当前状态一致，历史不倒改。

检查前后保护源scheme全文/摘要/index/未暂存状态、源HEAD与候选；不add-A、不stash/reset/restore/清理/改历史/main。普通D/模型/项目与旧证据不动。重资源串行；仅结束自有进程；Mac无需再次询问空闲。隔离GUI失败按观察登记、不能假装真人或真实推理通过。最终组合SHA通过后保留历史合并到隔离集成树，源仅ff接纳；有已授权正常漂移先在隔离树合并复验，未知漂移停止受影响写入。工作分支提交/推送按长期授权，本轮不发布。

## 初始恢复点

P0通过，准备中；源仍165c544且scheme唯一未暂存；暂无写Worker。需要后续：N3/N4实现，N1/N6检查，P2/P3文档及runtime演练，组合/GUI/接手/源接纳。规格和任务修订由Lead单一维护。
