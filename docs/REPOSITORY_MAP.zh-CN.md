# D 实际仓库导航

核实生产快照：`b334920907de0324bf3e0146bb78433742356a6c`，2026-09-23。本文是**现状地图**，不是重构后的结构；本轮没有修改代码。版本、产物、候选见[当前行动](CURRENT_ACTIONS.zh-CN.md)，目标见[原则](PRODUCT_PRINCIPLES.zh-CN.md)。先按所遇问题选一条路线，不通读全库。

## 实际入口与责任

| 入口/区域 | 实际调用与职责 | 状态/何时阅读 |
| --- | --- | --- |
| `D/DApp.swift` → `D/WorkbenchBootstrap.swift` → `D/AppSessionFactory.swift` → WorkbenchView | 原生App入口，具体runtime/backend及验证闭包装配 | active；调App启动/依赖装配，不把它当已统一模型注册 |
| `Package.swift`；`Sources/DInference` | Sendable值型请求、能力/配置、进度结果、backend协议；无MLX/UI | active；先读请求/返回/所有权，不直接搬模型代码进去 |
| `Sources/DRuntime` | InferenceRuntime、RuntimeConfiguration、ResourceBudgetPolicy：队列、预算、取消、终态 | active；生命周期问题。await不是整次推理锁 |
| `Backends/MLX/Package.swift`、`Sources/DMLXBackend` | MLXTextBackend、MLXImageBackend与Python音视频桥接，MLXExecutionLease | active；加载、校验、执行、释放。目录MLX不表示每个组件都原生MLX |
| `Backends/MLX/Sources/DInferenceCLI` | d-infer命令入口、text/image/audio/video/singing装配 | active CLI；CLI歌声通过不代表普通App已接入 |
| `Packages/UI/Package.swift` | 两个target：DWorkbench→DInference；UI→DWorkbench/DInference | active；不能按UI目录名把服务当展示代码 |
| `Packages/UI/Sources/DWorkbench/State/ProjectSession.swift` | 会话/提交/候选/保存等共享状态；具体text/audio/video控制器参与 | active且有耦合债；不属于本轮退役代码 |
| `Packages/UI/Sources/DWorkbench/Project` | ProjectModels/ProjectStore、清单及媒体持久化；源schema12 | active；AP1/CORE schema15只在候选，不能用其版本解释源项目 |
| `Packages/UI/Sources/DWorkbench/{Text,Audio,Video,Media,Models,Services}` | 文稿、音频/视频草稿、播放/派生、配方、安装/租约、值型应用服务 | active；按功能读控制器与对应存储/测试 |
| `Packages/UI/Sources/UI/{State,Views}` | WorkbenchModel/WorkbenchView及模态视图、原生输入 | active四模态导航＋模型节点说明原型；无节点组合执行 |
| `Packages/UI/Sources/DWorkbench/Nodes`、`UI/Views/ModelNodeViews.swift` | 静态模型能力展示投影、用户标签与详情视图 | 只说明已适配范围，不是推理注册器/安装状态/节点调度；适配变更须同步核对展示和回归 |
| `D/BundledAudioEngine.swift`、音频/视频`Packaging` | engine.json、provider脚本和资源清单的封装/运行时校验 | active部署入口；普通build-local不自动制齐Python引擎 |
| `D.xcworkspace`、`D.xcodeproj`、`DTests`、`DUITests` | workspace聚合App/MLX/Vendor；scheme D/d-infer/DMLXTests，自动收集源码 | active；Sources列表为空不表示无源码 |

## 兼容、参考、研究与候选

| 区域 | 分类 | 本轮决定及证据 |
| --- | --- | --- |
| `Packages/Core`、`ModelLoading`、`TextInference`、`ImageInference` | 旧公共产品/兼容保留，未在新App/CLI依赖图 | 各自Package.swift仍公开库且旧包相互依赖；仓库外消费者unknown。旧ModelLoading还用注入闭包/目录字符串；不按grep无调用删除 |
| `Packages/AIAssistant` | 未实现公共包骨架 | 不能称已有助手；公共产品/外部使用未知，保留 |
| 旧ImageInference的SD/SDXL/SD3部件 | 历史实现/数值参考 | SD3 performGeneration仅结束空流不是可用模型；不据此删除整个公共包。旧包example测试无断言，不作有效验收 |
| `Experiments/Flux2Probe` | 独立参考/仍被测试依赖 | test-mlx.sh和verify-image-cli.py使用其中下载校验器/模型清单，不能整目录删除 |
| `Experiments/MRT2ConditionProbe` | 条件控制研究参考 | 研究证据不等于产品入口，也没有无责任退役证明 |
| `Backends/Video/Python/d_video_wan_attention.py`、`d_video_wan_weights.py` | R9数值/流式部件与测试责任 | 已源接纳部件，不是App I2V；全片参考在外盘，继续保留 |
| `tools/testkit` | 外机离线验证/打包工具 | profiles、模型清单、资源和CLI动态装配；便携CLI证据不是干净Mac App发行 |
| `scripts` | 构建/验证/诊断/开发包工具 | 脚本字符串和复制规则构成调用关系；本轮无确定失效入口删除 |
| `Vendor` | 固定源码、补丁、许可与再现责任 | 当前后端使用；保留完整快照/NOTICE/摘要，局部约束`Vendor/flux2-swift/AGENTS.md`有效 |
| AP1、CORE及视频实验外盘工作树/证据 | 未整合候选或历史证据 | 固定版本在当前行动；不清理、不当作已发布源，不自动续跑 |

**退役删除：0项。** 上述代码未同时满足无入口、无公共兼容、无参考/候选/许可证责任。未知外部调用不是删除依据；活跃代码存在设计债也不叫垃圾。本轮不删除任何测试或失效构建引用。

使用关系核查包含：Xcode `PBXFileSystemSynchronizedRootGroup` 对D/DTests/DUITests自动收集及Info.plist例外；SwiftPM target自动收集与`.process`资源；Bundle.module资源查找；ModelLoading注入/通知/目录名；Python import_module/spec_from_file_location/sys.path与引擎清单/Packaging复制。不能只扫静态import。

## 新增同类模型的最短阅读路线

1. **契约**：`Sources/DInference/InferenceRequest.swift`、`InferenceBackend.swift`及对应`*Request.swift`/`*ExecutionCapability.swift`、`ExecutionProfileReference.swift`。区分真实限制与默认实测profile；estimate不加载，execute停止并drain，release清理。
2. **适配与数值**：`Backends/MLX/Sources/DMLXBackend/MLXTextBackend.swift`/`LocalModelInventory.swift`（当前qwen2/4-bit/group64）；或MLXImageBackend/LocalImageModelInventory/ImageExecutionProfile（当前Klein）。不是改中央类显示名就支持新架构。
3. **目录与安装**：DWorkbench的`Models/TextModelProfiles.swift`/`Resources/text-model*.json`；图像`ModelLibraryTypes.swift::ModelCatalog`。当前entries仅FLUX，文字单独登记，音视频依赖App验证/封装；统一模型安装尚未全面完成。FixedTextModel仍是0.5B兼容入口。
4. **Python族**：对应`*BackendConfiguration.swift`、`*ModelInventory.swift`、`*ProviderProtocol.swift`及`Backends/Audio/Python`/`Backends/Video/Python`、Models、Packaging。检查设备/精度、布局、许可、子进程协议及格式，别将新后端伪装已有profile。
5. **执行与应用**：DRuntime与MLXExecutionLease→ModelLibrary/ModelLibraryFiles/ModelRangeDownload→BundledAudioEngine/AppSessionFactory/WorkbenchBootstrap→`Services/WorkbenchSession.swift`。安装与推理、操作与展示分别决定。
6. **保存与呈现（仅确需时）**：ProjectSession、对应ProjectTextController/ProjectAudioController、ProjectStore、UI/WorkbenchModel/View；不要默认新增一套模态页。相关共享契约由Lead协调。

图像MLX和ModelLibrary各有固定清单，test-workbench.sh要求字节一致；新增模型需同时核对。G5差异表达、联合条件校验、模型事实位置仍有债，见[审计映射](tasks/D-CONTEXT-RESET-01.md#审计状态映射)，本轮没有引入万能registry。

## 验证入口（现有，非本轮全部执行）

| 改动 | 入口与边界 |
| --- | --- |
| 纯契约/运行时 | `scripts/test-foundation.sh`、Tests/DRuntimeTests；无模型 |
| 工作台/模型安装/存储 | `scripts/test-workbench.sh`、Packages/UI/Tests/{DWorkbenchTests,ModelLibraryTests,UITests}；CPU/条件跳过与真机分开 |
| App/CLI装配 | `scripts/build-local.sh`、`scripts/build-mlx.sh`；独立输出/依赖目录，普通构建不等于全引擎部署 |
| 图文真实推理 | `scripts/test-mlx.sh`、verify-mlx-cli.py、verify-image-cli.py；offline-only不能算真实推理 |
| 所有权/上游补丁 | `scripts/test-mlx-ownership.sh`、verify-mlx-vendor.py、verify-flux2-vendor.py；按改动触发 |
| 音视频/Python/包装 | 对应Backends的Tests/Packaging tests和任务中固定verify入口；fixture、CLI、App、真人分别举证 |
| 部署/签名/UI完整性 | `scripts/build-development-app.py`及[DIAG](tasks/D-C01a-DIAG-01.md)/[RESULT](tasks/D-C01a-RESULT-01.md)；离线汇总不能替代真实UI/公证/TCC |

本机输出/缓存设置按当前任务及脚本参数核验；不要从某个工作树的默认相对路径写进另一任务。真实模型回归保留实际输入/seed/profile/权重revision、设备精度、输出、耗时和内存；读旧记录不称重测。
