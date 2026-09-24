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

## 实施与审核记录（2026-09-24）

源165c544未回退；准备提交`239bb57065ac2d60a8a8cfe8458ea3d72817f72a`，修订2执行基线`af14824f12d7cbaced3d79127bb7fa96fb2ccf35`。三个独立CLI均先只读预检，Lead核对turn_context的模型/effort、cwd、workspace-write写根和network=false；修订2明确CROSS所有权后才实施。共同Git管理目录未授写，Worker未提交；停写后Lead显式暂存。服务端隐藏解析unknown。三者实施在06:59—07:01 UTC有真实时间重叠。

| 子任务/请求与可观察设置 | CLI thread | 候选提交 | 普通返工与归因 |
| --- | --- | --- | --- |
| TAGS，gpt-5.6-sol/high | `01a0d232-f43c-7771-b7cd-a4ebc98fb605` | `cb8af3c9f5d88affead516fd29101c9447ea022e` | 1轮：静态key调用编译问题、同ID注入corrupt的禁用态；未Lead重写实现 |
| RUNTIME，gpt-5.6-terra/medium | `01a0d232-f8d6-7c50-bee2-058155085c0c` | `90dc91769fa0fa76210d622fcbf6eac6a6674c30` | 1轮：观察门闩改有限轮询；保留后端drain门闩和外层进程时限 |
| CROSS，gpt-5.6-sol/high | `01a0d232-fd65-71e0-bb7a-15a69d468fac` | `5131e319fdf79cea87823550b7979a73e70dfda5` | 1轮：音频默认改取真实AudioCreationDraft，避免手填相同值的循环证明 |

Lead实现`ModelNodePresentation`并接入WorkbenchView、N6接线测试、文档与集成；不是Worker独立交付。非实现者`context_code_map`审阅标签、Lead代码和服务清单，`context_rules_audit`审阅runtime/CROSS；只读审阅不冒称独立测试。Lead初版测试闭包缺MainActor限定导致编译失败，修正后发现假引擎未启用文字入口、实际模态切换未发生，补textBackendID并要求切换成功。审阅另发现旧projectWorkbench子树观察器在关闭项目时可能消失，移到稳定外层，新增实际Workbench hosting关闭/打开第二项目断言；第二项目激活本身亦必须成功。这些Lead修复不归因于Worker。

Worker异常审计仅发现预期rg无匹配和新文件diff返回1，无观察到权限拒绝/越界/网络。最初preflight摘要中复用的一句CROSS说明不适用于另两包，IMPLEMENT按各自冻结规格澄清；CROSS未获明确文件归属前暂停，Lead修订2补齐才实施。不是私自绕过。Lead原缺陷复现使用的编译器路径/SDK两次工具纠正与一次文档编辑stdin编码错误均保留日志/变更核对，未改变权限或工程设置。

## N1—N6与审计状态

| 项目 | 实际处理 | 保留边界 |
| --- | --- | --- |
| N3 关闭（代码/持续回归） | missing/valid/corrupt；损坏原值保留，任何普通setTags含清空均拒绝；明确只读提示；nil settings纯内存 | 没有重建或恢复UI，不自动修复未知数据；外部偏好变化不承诺实时跨进程通知，提交必重查 |
| N4 关闭（代码/持续回归） | 实际View调用addDraft/remove；新增成功才清输入，删除/失败保留草稿；Unicode与重开覆盖 | 不增加跨模型草稿保存系统，切模型仍重置 |
| N5 关闭（活动文档） | 当前任务/停点唯一CURRENT_ACTIONS；目标表去旧S0/S6开工句；导航区分历史保留决定；协作规程保留授权与安全 | 历史任务正文/候选证据不倒改、不重新扫描清理 |
| N1 缓解 | text/image直接typed/资源事实、SA3/Wan代表JSON与草稿；图像三项与音频两项受控漂移反证 | 人工设备/精度/范围/其他模型字段仍需维护，不宣称全目录自动同步或统一安装/能力注册 |
| N2 关闭（本轮身份说明/兼容） | 卡片、模型revision、操作、实现、配方、未来实例分开；原标签键不变 | 未创建实例/图schema或通用标识迁移 |
| N6 持续回归已增加 | 真实View共享状态、菜单生成门禁、ABA/导航旧回调、损坏/删除草稿、项目不变、关闭重开复位 | CPU/hosting与真实GUI分别记录；不把呈现状态包装成页面无关应用API |

旧审计：A01/A09/A10仅在文档/状态治理进一步收口；A02、A03—A07保持架构演进责任，本轮提供[扩展约束与实际接线](../BACKEND_EXTENSION_CONTRACT.zh-CN.md)，不标全面关闭。A08/A11/A12的兼容、候选/许可、发行责任保持。无删除代码、无AP1/CORE/I2V接纳、无原件/项目schema改动。

## 验证索引与版本

外部证据统一为`D-Development/AgentTrials/D-UI-READINESS-01/run-20260924T065313Z/`；以下均本轮，不与历史通过数相加。

- `lead/baseline-repro/{source,compile,result}.json`：165c原始TagStore及真实UI editor动作片段，坏数组普通添加覆盖、删除清空草稿两项反例退出1。不是GUI证据；持久新测试在修补后通过。
- `lead/combined-workbench/`：组合ad629ab的Lead测试闭包编译失败；`combined-workbench-r1/`：f8b2968的两条模态断言失败。原输出保留，不删断言；`combined-workbench-r2/`：faca752全包通过。
- `lead/workbench-final/`：代码/测试`34ee0c5e2172a0bc5479960f7d7660567e657a30`，`scripts/test-workbench.sh`，UI 96项、ModelLibrary 23项、DWorkbench 395项记录，其中3项真实模型opt-in跳过（明确列于日志）。CPU/原生hosting通过，不是GPU。
- `lead/combined-runtime/`：faca752，`swift test --scratch-path <run>/cache/runtime`，70项通过；到34ee0c5仅N6测试激活断言变化，runtime代码/测试完全相同。四个新增方法：`explicitSelectionUsesOnlySelectedBackend`、`rejectionsDoNotFallback`、`cancellationDoesNotHandOffBeforeDrainAndRelease`、`ordinaryFailureDoesNotFallbackOrMixResults`。
- `lead/review-summary.json`：非实现者发现、修复和界限；`{tags,runtime,cross}/lead-route-and-scope-audit.json`、phase事件/请求/终态、result.md是路由/权限/返工证据。各包仅一轮修复，无接管，无递归。
- `lead/active-doc-links.json`：限定活动文档链接/必要锚点检查；不是全史扫描。

后端结构演练只证明既有请求形状、显式实现选择与单运行时生命周期，不证明任意新架构、GPU数值、图执行或应用接口已解耦。生产推理路径未变，不触发全模态模型复跑；既有真实模型3项跳过不升级为通过。真实GUI、普通签名独立构建、源入口回归及新上下文接手在下方结案段记录，未产生结果前不宣称完成。

用量：`lead/worker-run-summary.json`记录逐次墙钟及进程终态；原CLI token快照保留，resume累计语义未另行求证，不相加伪造总量。完整Lead归因和订阅实际费用unknown，本样本不证明成本最优。来源是可追溯记录，不是模型身份的密码学认证或质量保证。

## P4构建与原生交互（集成前）

代码/测试版本`34ee0c5e2172a0bc5479960f7d7660567e657a30`，后续本文/CURRENT_ACTIONS及AGENTS历史链接标题仅文档变化。`lead/build-final/`按既有普通开发签名、离线依赖副本和本run独立DerivedData构建成功；未修改签名配置/真实App/钥匙串，codesign严格完整性检查通过。产物为`<run>/cache/DerivedData/Build/Products/Debug/D.app`，不覆盖普通D。

`lead/gui/acceptance.json`及setup/process/reopen-process、项目前后快照：独立UUID `9DDD498A-F57E-4C13-B00D-CC3AB5DE3943`，仅此测试suite预置medium损坏数组。真实App中验证删除旧标签保留中文、emoji和组合字符草稿、继续添加成功、重复失败保留文本；medium显式保护提示且禁编辑，原坏值未覆盖。四模态切换不串标签，生成菜单禁用，发出生成快捷键后项目jobs仍0；返回选择页再打开复位到创作，正常退出再启动保留Unicode标签。浏览/编辑前后项目文件字节相同（SHA256 `76bbc9d8257c7f00807ad349aa83e2b303bcd40cc9f0bcb3890c8b7da1aea464`），隔离库未安装模型；App四关键文件摘要、大小、mtime前后相同。两个自有进程正常退出0，未关闭/替换普通D。

真实GUI不等于真人输入法验收；本轮未要求用户输入、试听或授权。原生路径框一次剪贴板超时，用已观察PathTextField定点setValue恢复；菜单打开时截图不可用，经已有Cancel动作关闭后恢复。均无权限变化；详见GUI记录。H22候选栏跟随仍保留专项UI处理，不在本轮追修。没有推理流程变化，不重跑GPU/真实模型；三项opt-in跳过与发行/候选未验收界限不变。

`lead/tag-regression-index.json`关联原始失败、持久CPU回归和真实GUI。新上下文接手与源入口复验随后追加，不把上述隔离通过预写为源已接纳。
