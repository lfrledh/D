# D-NODE-CATALOG-01：模型节点说明原型

修订1 / 2026-09-24；P2026-09-23.1、C2026-09-23.1沿用，当前用户批准本任务，替代上批S6图文组合提案作为下一执行范围。源基线9fde96c625e86add2de8acb5e47ac9a52b71a5dc；run `run-20260923T150725Z`；实际工作树/保护/模型路由与输出在同task外盘AgentTrials。状态：已完成原型、非实现者审阅与隔离验收，已本地接纳；推送结果及最终文档 SHA 见本 run 的 final-receipt.json。

## 目标与非目标

保留项目内图像/文字/音频/视频四页，新增各自“模型节点”列表与模型详情：模型身份、引擎/设备精度、部署/验证边界、每操作输入输出类型及必选/可选/条件必选、推理前参数的默认/可调范围/固定约束、空白用户标签。用户标签可新增删除并本机持久保存。

仅说明型原型，不启动推理/下载/安装、不提供节点连线/组合、无新模型/后端、无现有项目schema/作品迁移、不接纳AP1/CORE/I2V候选、不改签名/权限。参数是可检查规格，不是另一个可运行设置入口；浏览不修改现有文稿或生成参数。节点/端口是创作语义，不暴露所有张量。

模型清单依据源代码实际adapter/profile/登记及版本证据；旧SD/SD3占位、未进入现行adapter的Wan2.2研究不冒充可运行节点。同一模型的profiles分操作/参数说明，非重复模型。已适配、CLI、已有工作台入口、安装状态、机器实测分开；无权重也可查看。16GiB非产品上限；后端无上限不虚构2.0等UI上限。

## 行为表与冻结契约

| 输入/状态 | 操作 | 预期 |
| --- | --- | --- |
| 任一四模态（即使没有该类文档/模型安装） | 打开模型节点 | 只列本模态；点模型详情，不创建文档/任务/下载 |
| 已开详情 | 切模态 | 清掉跨模态选择，仍展示节点列表；旧创作状态保留 |
| 节点详情 | 查看操作/端口 | 每操作单独显示必选/可选/条件必选和格式；输出标签解释为成功执行的必有/可能产物，不当成可勾选输入 |
| 参数 | 查看 | 明确后端可调、原界面固定/未暴露、固定配方；不将字符串说明用于执行校验 |
| 标签首次查看 | 展示 | 空，不预填系统/模型标签；支持中文/emoji/组合字符 |
| 标签输入 | 添加/删除/重开 | 前后空白裁切、拒绝空白/重复、最多24个/每个32个Swift字符；按稳定模型ID隔离，存本机设置不写项目/权重。限制有可读错误，不清空已有标签 |
| 节点页期间 | 菜单生成快捷键 | 不触发背后旧文档推理；离开恢复既有生成行为 |
| 缩窄/滚动 | 操作 | 列表/详情/标签按钮完整可达；不按窗口宽度重建输入控件身份；不修复无关H22 |

共同类型：`Packages/UI/Sources/DWorkbench/Nodes/ModelNodeDescriptor.swift`（Lead准备）。这是展示投影不是通用注册系统。ModelNodeCatalog.entries由DATA实现；UI只接收descriptor与回调。标签存储由DATA实现`@MainActor ModelNodeTagStore`：`init(settings: UserDefaults? = nil)`（nil纯内存）、`tags(for modelID: String) -> [String]`、`setTags(_ tags: [String], for modelID: String) throws`。由Lead将Bootstrap已有隔离UserDefaults注入普通App；UI测试不得写真实用户偏好。

UI公共入口由VIEW实现：`ModelNodeList(entries: [ModelNodeDescriptor], selectedID: String?, onSelect: @escaping (String)->Void)`；`ModelNodeDetail(node: ModelNodeDescriptor, tags: [String], onTagsChange: @escaping ([String])->String?)`。nil返回表示保存成功、字符串为错误；内部编辑成功后状态刷新，失败保留原标签；变更model ID重置草稿。UI不得依赖具体backend/MLX，标签不成为能力/许可声明。

## 分工与边界

Lead：共享类型、WorkbenchView/WorkspacePresentation、D/WorkbenchBootstrap/DApp必要注入，测试/组合审核/文档/集成。禁止无范围改ProjectSession/ProjectStore、工程、依赖、签名和模型。

DATA Worker：仅新增`DWorkbench/Nodes/ModelNodeCatalog.swift`、`ModelNodeTagStore.swift`及对应`Packages/UI/Tests/DWorkbenchTests/ModelNodeCatalogTests.swift`。冻结数据事实由Lead提供并可按引用源码核对，不改变契约。测试检查ID唯一、覆盖/分组/端口分类、重要固定/联合限制、标签为空/隔离/持久/错误保护。

VIEW Worker：仅新增`Packages/UI/Sources/UI/Views/ModelNodeViews.swift`、`Packages/UI/Tests/UITests/ModelNodeViewsTests.swift`。实现原生列表/详情/端口和参数卡/用户标签；已有Liquid Glass控制风格与内容背景，滚动/键盘/无模型依赖。稳定accessibility IDs和纯原生hosting检查。不得改WorkbenchView/公共类型/安装或调用生成。

两个Worker各自独立树/分支/写根、网络关闭、共享Git只读；预检核对模型/目录/权限后同链路IMPLEMENT。DATA用可观察的gpt-5.6-sol/high（多模型语义/持久化），VIEW用gpt-5.6-terra/medium（冻结接口下局部视图）。每任务初交＋最多两轮定向修复，再一次有界Lead接管；实施每轮900秒，预检240秒。Swift完整编译由Lead串行，Worker不构建App/运行GPU/GUI/下载；其输出/cache/tmp仅本run指定目录，不递归。

## 验收与停止

Lead核对事实与源契约，防止参数漏项/造范围/可选误标/注册等同安装。局部CPU及现有工作台回归，必要独立App构建；在已隔离且可用前台做四模态列表→详情、参数滚动、标签新增删除/重开、旧创作仍可回到原页的GUI检查。不因新纯浏览页重跑模型数值；不将hosting/mock当真实UI。不新增生成开关，原路径不受影响。

需要本人操作或锁屏时记集中清单，继续CPU/构建；不能用未知用户实例做测试。字段事实/公共接口歧义、权限异常、数据风险立即报Lead，预算耗尽停，不通过新编号重置。完成时注明CPU/装配/真实UI各自范围，恢复点包括候选/源、个人scheme、进程、版本及下一阶段仅提案。

## 实际交付与范围（2026-09-24）

入口：项目 → 原有图像/文字/音频/视频 → 左侧“模型节点” → 模型详情。共12个模型/变体（图像1、文字4、音频6、视频1）：FLUX.2 Klein 4B Q8；Qwen2.5 0.5B/1.5B/7B/32B 4-bit；SA3 small music/small sfx/medium、MRT2 small、SwiftF0、绮萱+BigVGAN复合歌声节点；Wan2.1 T2V1.3B。模型有多份profile时在同一详情中按操作展示，不复制成多个模型。

身份、固定revision、引擎、设备/精度、真实支持与验证边界、输入输出必选/可选、参数默认/范围/联合限制都可查看。用户标签最初为空，按模型保存于本机偏好，支持新增/删除/重开。参数本轮只读展示；没有新执行入口、安装动作或组合能力。32B App登记与外部CLI实测分开；歌声仅后端/CLI，未混入AP1候选App；Wan2.2研究、72B容量用例、旧SD占位没有冒充已接入节点。

描述目录是源码契约的人工维护展示投影，不是后端注册/动态能力发现或执行校验的替代。后端参数改变时须同步该投影及对应契约测试；静态说明并不证明本机已安装模型或任何机器均能运行。无后端、依赖、签名、工程配置、项目schema或原有创作内容变更。

## 来源、返工与审核

共同执行基线：`f3ecd18daa717d30ac632826f3719df790043175`；原源基线：`9fde96c625e86add2de8acb5e47ac9a52b71a5dc`。两个独立受限CLI工作树，预检与每轮运行请求/turn_context匹配，workspace-write、network=false、仅各自任务树/输出/tmp可写，共享Git只读。隐藏服务端解析unknown。无观察到的权限拒绝、成功越界或用户输入破坏；这不是系统级零副作用证明。

| 责任 | 实现/修复与固定版本 | 实际过程 |
| --- | --- | --- |
| DATA | `gpt-5.6-sol/high`，线程`01a0ced4-79dd-7692-9434-e85defbc2b0c`；初稿`797e5edd7fe8b8c65581549570a85c7a9d10e1ee`，修复1 `311e6072bf916f7e7013dab8519033c330ca1c19` | 初次900秒超时、进程回收，有文件但无完成交付；Lead保留初稿不判通过。一次定向返工纠正模型范围、状态、公开端口及设备事实。Lead资料包部分命名/政策与现状说明也有歧义，不把全部问题仅归为模型能力 |
| VIEW | `gpt-5.6-terra/medium`，线程`01a0ced4-7e80-77d2-98c6-64a4cb97ef80`；初稿`ff20207e746858553dee71ba053fa42a82a6af88`，修复1 `218f89e96bf5c64af667b64f7c8426bc5e1b34b6` | 初次3项hosting检查中2项因错误控件查找失败；非实现者另发现选中行未暴露AX选中状态。一次修复采用实际几何检查并补选中trait；没有删除验收要求 |
| Lead | 共享值类型、`f2854414098ad8681973fbe6c8b3bd2786d637ba`的4处App/工作台接线、组合与验证、文档 | 未代写/重写两Worker实现；提供事实反例并审阅。非实现者`context_fresh_handoff`审接线和最终VIEW，无阻塞；`context_code_map`与`context_rules_audit`审最终DATA图文/音视频，既有发现均关闭。审阅者未执行独立测试，不将其称为独立实测 |

初次实现实际重叠约239秒；DATA初次900.02秒、修复408.96秒；VIEW初次238.87秒、修复143.23秒。各用一轮普通修复，未触发Lead接管。VIEW两次只读工具路径不存在（127）均经Lead查看后纠正，不是权限事件。详见外部`data/`、`view/`逐轮route/request/events/process/audit记录及`lead/*review.md`。

用量：`lead/worker-summary.json`保留CLI原始usage快照；其生成标签不能证明resume后的数值是逐轮增量，**不得把这些快照相加成总消耗**。更正口径见`lead/usage-note.json`。缓存输入是输入的子集，不另加；DATA超时轮缺完成事件，完整Lead归因与订阅费用unknown。本样本证明限定交付，不证明成本最优。

## 验收与证据

外部持久证据根：`D-Development/AgentTrials/D-NODE-CATALOG-01/run-20260923T150725Z/`（工作树之外）。实际组合/源码入口受测版本均为 **`23fc4364c5b04c40db29f25e53a7756611306445`**。其后的本任务结案只改本文与CURRENT_ACTIONS，最终SHA放外部回执，避免自引用。

| 检查 | 结果与限制 | 索引 |
| --- | --- | --- |
| 工作台离线回归 `scripts/test-workbench.sh` | exit0；Swift Testing分别报告UI 90、ModelLoading 23、DWorkbench 387；其中3个显式opt-in真实模型检查跳过，无失败。不能把跳过写成真实生成通过 | `lead/workbench-final/result.json`与`output.log` |
| 本轮新测试 | DATA 8项含登记/端口/约束/标签；VIEW 3项含侧栏210/260、详情480→640→480几何及标签错误行为。均包含于上行，不累加虚构总通过率 | `lead/view-first/`保留先失败；`lead/view-repair1/`及最终整组日志 |
| 完整普通签名App离线构建 | exit0；Xcode27.0/27A266a，Swift6.4 arm64，macOS26；依赖本run独立副本、独立DerivedData，无下载。直接codesign完整性检查通过，沿用既有签名 | `lead/build-final/result.json`；`lead/gui/setup.json`和签名输出 |
| 真实原生GUI | 四模态1/4/6/1列表、无对应文档也可浏览、详情端口/参数滚动、窄窗放大再缩回、生成菜单禁用、中文emoji标签新增/重复错误/跨模型隔离/正常退出重开/删除、返回原图像创作通过 | `lead/gui/acceptance.json`；本会话CUA AX及截图 |
| 输入/产物保护 | GUI前后项目所有文件逐字节摘要一致（仍仅原图像文档、无新任务资产）；签名App四关键文件摘要/大小/mtime不变；两个自有App进程均正常exit0 | `lead/gui/project-before.json`、`project-after-browse.json`、`acceptance.json`、`first-end.json`、`reopen-end.json` |
| 源目录复验 | 快进后以源绝对路径执行`swift test … --filter 'ModelNodeCatalogTests\|ModelNodeViewsTests'`，8+3项通过，未引用旧候选源码 | `lead/source-node-regression/result.json`及`output.log` |

GUI使用独立UUID `D6EB7D6C-87E5-440C-9F29-8FA159F5324C`及本run专属项目；测试标签没有写普通用户偏好。一次文件面板paste超时后检查状态并用原生setValue成功；菜单Escape未关闭时使用已暴露Cancel动作关闭；无权限扩大。没有模型推理/下载、真人IME复测、VoiceOver朗读或发行/公证验收，本次纯展示增量不代替这些结论。

## 接纳与恢复检查点

已将固定组合`23fc4364c5b04c40db29f25e53a7756611306445`快进至源`codex/inference-foundation`，源入口复验通过。开始/快进前/后均核对个人scheme完整差异、内容摘要、索引与未暂存状态：orderHint1→6、SHA256 `ca3635d88aa5a15397b90e528667c66c0e6db7e596176e885c79d194b544206c`保持不变。索引未夹带个人文件；源不称完全干净。14个批准路径，未动工程/后端/签名/普通D产物；Git门槛在`lead/integration-gate.json`与`protection/`。

DATA/VIEW与只读审阅均结束，本轮两个App实例正常退出，构建/测试子进程结束。工作树、候选与旧失败证据全部保留。最终本地/远端SHA、文档仅差异与保护检查见`final-receipt.json`；若推送失败只保留本地交付，不改写历史强推。

下一步只提出：用户审阅本原型的模型与端口表达，结合正在规划的新UI确定节点编辑和组合规则，再签发有限实施规格。本轮不开始组合、不扩张成执行平台，也不自动接纳AP1/CORE/I2V旧候选。
