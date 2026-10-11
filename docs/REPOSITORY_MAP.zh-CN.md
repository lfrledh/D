# D 实际仓库导航

2026-10-11有限核实，结构基线 `708e35f4531b0dfe2ec7a0ca1a11b335b12496c4`。当前任务/候选/停点只有[当前行动](CURRENT_ACTIONS.zh-CN.md)一个入口；表格定位实现，不证明原生或全模型已验。

| 入口 | 当前职责与边界 |
|---|---|
| `D.xcworkspace` / scheme `D`；`scripts/build-local.sh` | 正式开发构建入口，外层 workspace 锁；依赖准备不等于模型安装、签名或发行通过。 |
| `Packages/UI/Package.swift`；`scripts/test-workbench.sh` | DWorkbench/UI与对应测试。CPU夹具不运行模型，但集成测试仍编译MLX依赖。 |
| `D/DApp.swift`、`WorkbenchBootstrap.swift`、`AppSessionFactory.swift` | App注入模型/运行时/授权，未建立新注册平台。 |
| `Sources/DInference`、`Sources/DRuntime` | 值型契约与现有准入/取消/drain/release；UI不拥有推理资源。 |
| `Backends/MLX`及音视频后端；`Vendor` | 具体实现、CLI、资源及许可；不把CLI可调用等同App路径已验。 |
| `Packages/UI/Sources/DWorkbench/State/ProjectSession.swift` | 项目/共享操作身份和应用生命周期；仍有耦合债，本轮不拆分。 |
| `Packages/UI/Sources/DWorkbench/Project` | `ProjectStore`、`ProjectModels`和现行格式20；旧格式兼容/迁移责任保留，不用旧schema12/16解释现存项目。 |
| `Packages/UI/Sources/DWorkbench/Quick`、`Chat`、`Workflow` | Quick草稿、聊天与有界图执行；Workflow子目录Operations/Models，Controller/Services共用Store/runtime。 |
| `Packages/UI/Sources/DWorkbench/Nodes` | 模型说明展示与标签；不是执行注册器，不从说明字符串生成规则。 |
| `Packages/UI/Sources/UI/Views/Quick/DualWorkbenchView.swift`、`Chat/ChatWorkbenchView.swift`、`Workflow/WorkflowHostView.swift` | 共享外壳、实际输入/阅读与节点展示。RetainedContentHost、原生输入和局部拖动保护保留。 |
| `Packages/UI/Sources/DWorkbench/Media`、UI的`Localization`/`Resources/Localization` | 媒体编码/来源与语言数据；资源/静态说明不替代实际执行能力。 |

2026-09-24基础表、09-26增量及10-08展示路线完整保存在[整理前导航](https://github.com/lfrledh/D/blob/bb821f1fe31a263d33b1feeb33ee3cf3e7294d74/docs/REPOSITORY_MAP.zh-CN.md#L3-L33)。它们只解释当时的schema12/16、CLI/App与无图→有图变化；现行表不删除旧包、schema来源或兼容责任。固定历史与反向索引见[历史页](history/README.md#non-ui-20261011)。

## 兼容、参考、研究与候选

| 区域 | 分类 | D-CONTEXT-RESET-01历史保留决定及证据 |
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

**D-CONTEXT-RESET-01历史退役删除：0项。** 上述代码未同时满足无入口、无公共兼容、无参考/候选/许可证责任。未知外部调用不是删除依据；活跃代码存在设计债也不叫垃圾。D-UI-READINESS-01没有重新普查或删除这些代码。

使用关系核查包含：Xcode `PBXFileSystemSynchronizedRootGroup` 对D/DTests/DUITests自动收集及Info.plist例外；SwiftPM target自动收集与`.process`资源；Bundle.module资源查找；ModelLoading注入/通知/目录名；Python import_module/spec_from_file_location/sys.path与引擎清单/Packaging复制。不能只扫静态import。

## 新增同类模型的最短阅读路线

1. **契约**：`Sources/DInference/InferenceRequest.swift`、`InferenceBackend.swift`及对应`*Request.swift`/`*ExecutionCapability.swift`、`ExecutionProfileReference.swift`。区分真实限制与默认实测profile；estimate不加载，execute停止并drain，release清理。
2. **适配与数值**：`Backends/MLX/Sources/DMLXBackend/MLXTextBackend.swift`/`LocalModelInventory.swift`（具体架构/精度按现行固定资源与实现核对）；或MLXImageBackend/LocalImageModelInventory/ImageExecutionProfile（当前Klein）。不是改中央类显示名就支持新架构。
3. **目录与安装**：DWorkbench的`Models/TextModelProfiles.swift`/`Resources/text-model*.json`；图像`ModelLibraryTypes.swift::ModelCatalog`。文字、图像和音视频已有各自固定资源/安装及App装配；实际支持以当前能力矩阵为准，不从旧FixedTextModel兼容入口推断支持上限，亦不宣称统一注册已完成。
4. **Python族**：对应`*BackendConfiguration.swift`、`*ModelInventory.swift`、`*ProviderProtocol.swift`及`Backends/Audio/Python`/`Backends/Video/Python`、Models、Packaging。检查设备/精度、布局、许可、子进程协议及格式，别将新后端伪装已有profile。
5. **执行与应用**：DRuntime与MLXExecutionLease→ModelLibrary/ModelLibraryFiles/ModelRangeDownload→BundledAudioEngine/AppSessionFactory/WorkbenchBootstrap→`Services/WorkbenchSession.swift`。安装与推理、操作与展示分别决定。
6. **保存与呈现（仅确需时）**：ProjectSession、对应ProjectTextController/ProjectAudioController、ProjectStore、UI/WorkbenchModel/View；不要默认新增一套模态页。相关共享契约由Lead协调。

图像MLX和ModelLibrary各有固定清单，test-workbench.sh要求字节一致；新增模型需同时核对。G5差异表达、联合条件校验、模型事实位置仍有债，见[审计映射](tasks/D-CONTEXT-RESET-01.md#审计状态映射)，没有通用registry；具体应用接线和扩展责任见[后端扩展与服务接线](BACKEND_EXTENSION_CONTRACT.zh-CN.md)。

## 验证入口（现有，非本轮全部执行）

选择工作量以[唯一测试政策](TESTING_POLICY.zh-CN.md)为准。首发候选r4的局部已用入口：`swift test --package-path Packages/UI --filter 'ModelWanPreparationTests|WorkflowModelReadinessTests'`（安装/投影）；`python3 -B -m unittest discover -s Backends/Video/Tests -p test_app_video_driver.py`（受控provider）；workspace的`DMLXTests`用`build-for-testing`后按精确Swift Testing方法`test-without-building`（模型/生命周期）。这些简写不包含环境准备：实际命令及外盘scratch/cache/tmp、有效筛选、opt-in变量均在当前任务R4/lead对应`*-command.json`，不能省略隔离目录直接复制运行全部测试。无匹配/跳过不算通过。

实际新模型产物可复用`WorkflowMediaStoreTests.realImagePublishesReopensAndExports`和`VideoAVMediaInspectorTests.realSmokeOutputPublishesReopensAndExports`做Store发布/重开/来源/导出；后者可显式读取原`InferenceRequest`，不将旧2步夹具参数套给新50/30步结果。这是CPU/媒体文件验证，独立于模型和普通App。新外部视频provider需经`Backends/Video/Packaging/prepare_external_video_engine.py`正常打包，再由`scripts/prepare-development-resources.py`登记；Xcode `D Nodes`从同树本地配置嵌入，不能手补构建后的App。

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
