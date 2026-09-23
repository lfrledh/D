# D-NODE-CATALOG-01：模型节点说明原型

修订1 / 2026-09-24；P2026-09-23.1、C2026-09-23.1沿用，当前用户批准本任务，替代上批S6图文组合提案作为下一执行范围。源基线9fde96c625e86add2de8acb5e47ac9a52b71a5dc；run `run-20260923T150725Z`；实际工作树/保护/模型路由与输出在同task外盘AgentTrials。状态：规格冻结、实施准备。

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
