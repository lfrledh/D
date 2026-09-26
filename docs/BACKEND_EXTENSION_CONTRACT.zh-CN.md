# 后端扩展约束与新UI服务接线

## 节点边界整理增量（D-NODE-BOUNDARY-01，已本地集成）

以下是已本地集成M0与节点边界的实现范围，不将未整合AP1/CORE/I2V升级为已实现。当前版本、测试、接纳及同步状态只见[当前行动](CURRENT_ACTIONS.zh-CN.md)。本节替代下文在2026-09-24所作的“尚无节点执行”时态；其未覆盖模态/发行责任继续有效。

- `Workflow/Operations`：文字、图像、资产三个具体操作模块，`WorkflowBuiltins`仅静态装配。共用`WorkflowOperationSupport`校验；`WorkflowRegistry`拥有类型/端口/版本/连接校验。新增同类操作需实现并登记，不修改调度器。操作ID、定义版本、节点实例UUID、模型内容身份、安装ID继续分开。
- `Workflow/Models`：`WorkflowModelBinding`每运行节点独立绑定identity/reference/backendID/图像recipe及release；`WorkflowModelBookmarks`仅私有授权偏好，不是第二模型安装器。`WorkflowServices`按nodeUUID保存绑定；指定身份缺失时拒绝，不使用当前页面模型。空ID首次明确运行冻结默认，运行中不重读默认。
- `ProjectSession.openWorkflow/registerWorkflowModel`仍是应用装配与授权协调点：图片复用ModelLibrary安装使用权，文字和旧图片通过LocationAccess独立运行租约。选择回调捕获controller/graph/node及旧绑定，取消/换项目/删节点/更改绑定不误写。相同revision重定位是显式操作；私有书签不进流程与媒体。
- `WorkflowImageRecipe`将当前Klein请求/参考profile选择移出通用执行服务；增加另一实现仍需真实适配、App注册、能力校验和数值/资源测试。现有WorkbenchSession的音视频入口并未统一为任意模型平台，DInference图像能力仍为已支持Klein家族。
- `Media/ImageCodec`与`ImageCodecRegistry`独立登记格式签名、UTI、编码/透明度规则；`WorkflowImageProcessor`共用几何、输入预算和编码后回读。默认PNG/JPEG，resize默认PNG属于该操作合同。静态模块化不承诺动态二进制插件/随意安装第三方代码，也不证明RAW已支持。
- 定义中的`modelKind`/`interaction`供真实调用者选择模型入口、资产输入或人工决定，不根据操作ID前缀或自然语言文案猜执行。值型字段和执行ID不是翻译键。文件重分组不改变已存图、参数、端口和资产身份。

### 显示语言边界

`UI/Localization`负责语言包校验、回退、选择与显示投影；`UI/Resources/Localization/{en,zh-Hans}.json`是内置词表，`LanguageSettingsView`负责显式导入。App的WorkbenchBootstrap注入生产容器或独立测试suite/目录；纯组件默认不写真实偏好。默认跟随系统，也可选择语言；选择改变显示，不设置视图`.id(language)`、不重建工作流、不改变数字参数的输入Locale。

包是UTF-8 JSON：`schemaVersion`整数1、`locale`语言标识、`displayName`名称、`strings`命名键到文字的字典。512KiB/2000项/单值4096字符/键160 ASCII字符；版本、类型、占位、大小不符时拒绝。`system`为保留选择值；内置包和已导入同locale不自动覆盖。缺键依次回退同语言内置、英文、调用方fallback；未知规范键保留并报告但不执行。命名占位如`{count}`只替换一遍，不能传入代码/printf/HTML，不访问包中URI。

译者从内置英文文件复制键与占位到新的locale，修改displayName及显示文字；不要翻译模型/操作ID、参数枚举原值、用户图名/节点名/正文、路径、hash、来源记录。通过“显示语言”显式导入并选择；失败不会覆盖已有包。已保存的显式语言失效时只在内存回退跟随系统，保留原偏好与坏文件；显式选择必须精确匹配已安装标识，不悄悄换同语系的另一地区包。只有跟随系统使用语言族回退。正式应用不将授权书签、设备身份或密钥混入语言文件。

本批覆盖画布通用控件、节点定义的显示投影及语言入口。旧模态页、模型说明页、大部分服务String错误和执行计划仍可显示中文，是已列出的逐步迁移责任；不能按中文自然语言反解析错误/计划来假装已全部国际化。新增UI文本应使用稳定命名键并同时补中英词条/占位检查；新增结构化错误可逐项投影，不能把历史错误整套改写成执行协议。RTL、全部语言排版、专业翻译及所有旧页国际化未验收。

### 保留的扩展成本

同类节点增加模块与登记已可局部实现；新模型家族/新控制条件/新媒体类型仍需要窄契约、适配、存储/预览和真实验证。当前流程值类型限于文字/图片/候选集合/回执，不能宣称音视频已能任意连线。普通程序无需伪装模型。模型准备、数值、取消、人工等待、资产发布和失败保存仍复用单一运行时/存储所有者。窗口布局和模块拆分都不能替代这些验证。

---


状态：现行工程约束＋源码导航；不是已经实现的统一服务或节点协议。2026-09-24核对源`165c54471c4380eb5482312d6c2c70ab97db48a9`及D-UI-READINESS-01有限增量。当前任务/版本/证据/停点只看[CURRENT_ACTIONS](CURRENT_ACTIONS.zh-CN.md)与[任务记录](tasks/D-UI-READINESS-01.md)。不解析说明字符串执行，不授权正式节点、插件、候选接纳或发布。

## 2026-09-24源基线说明（历史核查）

以下“本轮/当前/尚未”均指UI-READINESS当时的源能力。M0及本批候选的节点实例、执行和模型绑定以上方增量为准；接纳状态只查CURRENT_ACTIONS。未覆盖的音视频应用接线和发行责任仍有效，不因本次整理取消。

### 身份与事实来源

| 概念 | 当前例子/来源 | 不能混同 |
| --- | --- | --- |
| 说明卡片ID/标签键 | `ModelNodeDescriptor.id`；原有`D.ModelNodeTags.v1.`＋原ID | 它是现行偏好稳定键，不是未来图中节点实例。`medium`等旧值不升级为全局公共ID；若未来改卡片ID，保留独立旧键或显式兼容映射及迁移测试 |
| 模型身份/权重版本 | TextModelProfiles、ModelCatalog；Audio/Video Models固定JSON中的repository、revision、文件摘要 | 同名模型不等于相同权重/架构/许可证，catalog标题不是身份 |
| 操作 | 文字生成、图像生成/参考图、音频生成/变体/重绘等请求语义；部分已有ExecutionContractDescription | 一个模型可提供多个操作；普通转换/用户选择不必伪装AI模型 |
| 后端实现 | InferenceBackend.descriptor.id/version；AppSessionFactory/CLI显式装配 | 同一操作可以有多个实现；不能按Input类型忽略backendID或静默fallback |
| 执行配方 | ExecutionProfileReference及各模态typed capability；含精度/设备/算法/合法联合条件 | 配方不等于模型，也不等于卡片。例如SA3变体、Wan配方、歌声CPU/MPS路径分别核实 |
| 未来节点实例 | 用户方案尚未决定，尚无持久类型 | 同一模型可出现多实例，复合节点可协调多个实现；不把卡片ID直接当实例ID，不预定最终粒度/图schema |

`ModelNodeCatalog`是人工展示投影。`defaultValue/acceptedValues/detail/dataType`是文案，不能转成执行schema。执行必须用DInference请求验证、实际capability、固定资源与适配器校验。安装完成、软件已有实现、特定环境实测、进入某App、此刻可执行是不同维度；现有`availability`只说明范围。

代表交叉检查：`Packages/UI/Tests/DWorkbenchTests/ModelNodeCatalogCrossContractTests.swift`核对文字登记/typed默认、FLUX固定清单与三图像配方、SA3/Wan固定模型JSON及请求形状；受控篡改目录副本的revision/必填属性/步数被同一比较器拒绝。`scripts/test-workbench.sh`还核对图像安装/后端两份清单字节一致。字符串比较只是防展示漂移，不参与执行。音频专属限制、设备/精度文案、MRT2/SwiftF0/歌声完整目录尚未统一自动投影；不要把代表检查写成全部说明自动同步。

### 目标边界与实际差距

目标依赖：未来节点UI/现有UI/CLI/助手 → **明确输入的应用操作** → DWorkbench输入绑定/项目资产/人工决定/保存来源 → 已装配实现及就绪校验 → **同一个DRuntime资源所有者** → 具体后端加载/条件处理/计算/产物/释放。

当前已经有值型请求、直接后端和运行时；应用入口多仍读取当前页面状态。`WorkbenchSession`是依赖装配容器，不是任意操作注册器；`WorkbenchModel.generateCaptured`的导航保护有价值，但不是页面无关API。本轮`ModelNodePresentation`只管理说明页、旧回调和菜单门禁，不包装成新执行服务。普通程序操作可复用资产/应用语义，不申请不存在的模型租约；不另造调度器。

| 必须保持 | 后续实现的可检验条件 |
| --- | --- |
| 展示不控制计算 | 切页/筛选/折叠不改执行参数、不加载权重；注册不等于安装/加载，无模型也能浏览 |
| 输入显式且保护不丢 | 应用命令接收project/document/asset身份与版本、参数、实现；仍验证授权/租约/过期/原件/保存，不用当前选中页补缺参 |
| 同类实现可扩展 | 同操作同形状新后端通常新增适配/装配/资源/测试，不向ProjectSession追加用途分支或WorkbenchSession逐模型字段；当前部分工厂仍需修改，不假称已实现通用注册 |
| 差异局部、有类型交换 | 架构映射/精度/专属条件/合法组合/资源估计/生命周期归适配；不降成万能提示词或参数袋。latent/embedding需家族、格式、版本兼容，不仅名字/shape相同 |
| 单一重资源所有权 | 排队、取消传播、drain/release沿用运行时；不一节点一常驻模型/进程；人工等待不占重资源。已发布产物不得被release删除 |
| 真相和副作用明确 | 真实执行值用于来源；失败、未完成产物、保存重试有所有者；就绪失败可解释；不自动执行下载来的代码 |
| 新语义可合理扩展 | 新条件/结果/流式/远程可增加窄类型/协议/预览/持久化规则，不承诺任意未来模型只改配置 |

同家族新权重仍需固定资源登记与验证，不自动兼容checkpoint。同操作新架构需要独立适配、运行环境、装配和真实数值/资源/取消验收。新条件需要准确类型/数量/联合验证；新产物允许格式/预览/交换的必要改动。已有操作的新组合原则上修改实例/模板与参数，不新增“某用途后端”。静态编译装配可先行，不承诺热加载、任意第三方脚本、任意ComfyUI或跨设备分布式执行；不因解耦就每模型拆包或微服务。

### 当时源服务接线清单

下表文件均仓库相对路径；PS=`Packages/UI/Sources/DWorkbench/State/ProjectSession.swift`，Store=`Packages/UI/Sources/DWorkbench/Project/ProjectStore.swift`，Backend=`Backends/MLX/Sources/DMLXBackend/`。App统一装配`D/AppSessionFactory.swift::makeSession`；CLI装配`Backends/MLX/Sources/DInferenceCLI/DInferenceCLI.swift`。精确入口以符号定位，行号会变化。

| 能力/请求→输出 | 后端/CLI无UI调用 | 当前应用入口与隐式输入 | 所有权及新UI接线结论 |
| --- | --- | --- | --- |
| 文字TextRequest→textDelta、终态/统计 | `MLXTextBackend.execute`；qwen2-text/1、四档TextModelProfiles；可直接调用 | PS.`rewriteText`/`askTextSources`读取当前text/reference；`loadActiveDocument`建立控制器与保存闭包 | `ProjectTextController`/`ProjectTextSourcesController`候选/过期/撤销/保存可复用；session级textModelLease；TextDraftSession与控制器管取消。应用提交需提取显式文档/版本/选区/模型快照，不能把当前页代理直接接成任意节点 |
| 图像ImageRequest→PNG引用 | `MLXImageBackend.execute`；verified512/scalable/reference Klein配方 | PS.`generate`读取当前doc/prompt/seed/settings/reference/selectedModel，首个await前冻结 | ModelLibrary.acquire的每run ModelUsageLease（受管理模型）或legacy LocationAccess租约；PS.`admit`/`finish`/`removeActive`与Store负责队列记录/保存重试/产物。`adoptAsset`按asset所属job/document执行可直接复用；生成需显式输入边界 |
| 声音AudioRequest→44.1kHz双声道F32 WAV | `MLXAudioBackend.execute`，SA3 sm-music/medium/sm-sfx固定配置，generate/variation/inpaint | PS.`generateAudioCreation(contextID:documentID:)`仍核对当前context/doc并读当前draft/source/model/backend；普通App sm-music | `AudioCreationDraft.makeRequest`与类型/采样帧范围校验可复用；audioModelLease为session访问租约，PS/Store共同持久化；候选编辑/提交需显式草稿快照，不能暗换profile |
| 器乐AudioRequest＋noteSequence→48kHz双声道WAV | `MLXMRT2Backend.execute`；mrt2-small-export-v1 | 同PS音频入口，`AudioCreationDraft.makeRequest`按当前profile选conditionedMusic；仅generate | musicModelLease/统一runtime/PS/Store复用；音符精确数据与近似音响不同。MRT2不支持变体/重绘，不因共用AudioRequest就借SA3回退 |
| 音高PitchAnalysisRequest→pitch JSON | `PitchAnalysisBackend.execute`；SwiftF0 CPU ONNX；原声身份/区间/revision/hash固定 | PS.`analyzePitch`/`cancelPitchAnalysis`/`decidePitchAnalysis`读取当前原声及结果 | Store.`preparePitchInput(documentID:runID:)`、`decidePitchAnalysis(assetID:documentID:accept:)`显式方法可复用；原声→16kHz派生由Store负责；App包内模型。PS动作需显式源/result身份；源已有音符服务不等于AP1纠错UI已接纳 |
| 歌声SingingRequest→44.1kHz单声道WAV | `SingingBackend.execute`及CLI singing；Qixuan CPU＋BigVGAN CPU/MPS明确profile、歌词音素/元音锚/资格确认 | **源App没有歌声装配**：WorkbenchSession/AppSessionFactory无对应入口；Store.enqueue/complete明确拒绝singing | ExecutionControl/SignalMonitor＋Runtime负责取消释放、任务目录/报告。无源App安装租约/候选采用闭环；未来需有限App/数据接线与候选审阅，不能假装已有音频表单即可接 |
| 视频VideoRequest→无声MP4 | `MLXVideoBackend.execute`；Wan2.1 T2V，typed VideoExecutionCapability | PS.`generateVideoCreation(contextID:documentID:)`和候选修改仍依赖当前context/draft/reference/backend | videoModelLease/统一runtime/PS/Store；`VideoCreationDraft.makeRequest`可复用。生成/候选需显式文档/版本；Wan2.2 I2V不在当前源App，R9部件/外盘latent不等于完整生成 |

直接可复用的是**各自现有契约范围**：DInference请求/能力、DRuntime提交/句柄/取消/终态、ModelLibrary有限安装与使用租约、上述Store显式存储方法、文字控制器、音视频草稿校验、媒体预览及配方值类型。新UI须沿相同保护接入，不能跳过应用资产保存层把后端文件当已保存作品。说明目录及其参数字符串只供展示。

### 随UI实施必须提取的最小边界和反例

| 当前入口/缺口 | 最小后续修改，不在本轮实现 | 必须失败或保持的反例 |
| --- | --- | --- |
| PS.generate / WorkbenchModel.generateCaptured读取当前图像页 | 接收显式项目/doc版本、model选择、ImageRequest/引用快照；共用原admit/finish/保存重试 | A排队后切B或A改版：不得把A结果写B；不能在新页面读新参数代替已提交值 |
| PS.rewriteText/askTextSources及loadActiveDocument保存闭包 | 将显式文稿版本/选区/资料/控制器绑定传入应用操作，保留过期/接受/撤销与Store校验 | 组合字符选区正确；原文修改、换项目、迟到候选不能覆盖；保存失败不丢已存在作品 |
| PS.generateAudioCreation与updateAudioCreationDraft | 明确profile、source身份/摘要/帧区间、doc版本；保留两类后端选择及租约 | MRT2变体拒绝；SA3重绘无source/区间拒绝；旧profile回调不抢新模型或改新文档 |
| PS.analyzePitch/decidePitchAnalysis | 显式原声版本/区间/result关联，复用Store派生与采用 | 原声已变/候选来自另一录音拒绝；识别失败仍保全原声 |
| PS.generateVideoCreation/候选修改 | 显式VideoRequest/doc版本/模型与产物提交；继续复用现有生命周期 | 过期context拒绝；不支持I2V不能降为T2V提示；取消后release完成再排队 |
| 歌声CLI→App缺口 | 用户UI方案与首发范围下审阅AP1/CORE历史，补真实装配、schema兼容、资格/来源及保存 | 不能用singing伪装普通audio绕过Store拒绝；不能静默GPU失败转CPU，不能仅CLI通过就启用App |
| 模型准备分散 | 在真实新增支持时统一窄的实现选择/就绪/租约输入，不新造空平台 | 没安装可浏览；卸载不能破坏已租用任务；取消/项目关闭先drain后释放访问；用户原件不覆盖 |

候选采用是人工决定，不能由生成完成自动替代。保存失败时计算结束不等于作品保存，文件归属和重试仍按现有应用服务处理。新UI应显示队列/执行/正在取消/释放/终态与保存失败的区别。未统一的应用API限制工程接线，不阻碍用户设计交互，也不允许承诺“换界面即可发布”。

### 当时结构演练与证据边界

`Tests/DRuntimeTests/BackendExtensionTests.swift`复用一个真实InferenceRuntime及ControlledBackend，明确两个实现ID；测试选择、不支持/不存在/非法/实现专属限制拒绝、排队取消、drain/release和普通失败不fallback。这是已有TextRequest形状的**CPU结构扩展验证**，不是新模型兼容、真实GPU数值、任意图组合或完整应用解耦。执行版本/结果及门闩时限审阅见当前任务；不新建运行时或生产注册平台。

`ModelNodeWiringTests`复用实际WorkbenchView使用的ModelNodePresentation、ProjectSession、fake engine、隔离UserDefaults和真实标签编辑方法，检查说明页不提交、离开恢复、ABA/导航旧回调拒绝、项目不变与损坏保护。原生hosting与真实GUI分别记证据；不能用fake engine结论冒充真实模型。

### 当时UI方案与持续发行责任

待用户决定：节点粒度/操作分组、连接手势与数据查看、暴露哪些内部步骤、候选/批次/快捷键、图保存版本体验及首发节点范围。当前说明页继续只读能力盘点，用户标签例外可编辑；本轮不决定上述体验。

先用户UI方案→必要显式应用接线/节点数据执行→同一整合包真实组合与编辑恢复→模型自助准备/无权重部署/干净Mac首次使用/升级恢复/渠道验收→用户明确发布授权。AP1/CORE/I2V缺口、SwiftF0包内权重及许可unknown、歌声/HUM责任、最终包安全/硬件/外部用户验收见[发布支持表](MODEL_SUPPORT_AND_RELEASE.zh-CN.md)。没有批量重写后端，没有新增节点执行器，也没有取消首发责任。
