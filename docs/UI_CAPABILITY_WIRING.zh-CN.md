# Quick UI 实施接线映射

2026-10-08增量：本页仍是能力/消费者的人工索引，不是第二执行协议。当前展示由[UI-PRESENTATION-REBUILD-01](tasks/UI-PRESENTATION-REBUILD-01.md)接续，依据设计v0.3；下方模型表沿用原核对范围，不自动升级为本轮实调。

| 本轮呈现位置 | 既有动作/所有者 |
|---|---|
| 顶部中央四模态；右上模式/设置 | DualWorkbenchView；captureChatReading/navigate；统一SettingsContext |
| 左上聊天菜单 | Chat/Single与临时聊天切换，仍用原Quick/Temporary owner |
| 左浮动面板；会话标题旁历史按钮 | 模型与下一次参数；同面板模型/会话切换，不改历史配置 |
| 中央空态与输入旁选择模型 | 原共享选择器；不隐式下载或发送 |
| 底部完整输入组件 | 原NSTextView稳定session ID、原附件/粘贴/URL与共享素材导入、发送/停止/保存重试 |
| 麦克风按钮展开持续语音区域 | 原ChatSpeechPanel、原project/chat控制器，保留隐藏实例 |
| 右浮动面板 | 原资料/成果/工具/请求检查，右边圆钮恢复 |

以上为代码接线，视觉与行为实际结果只见任务回执。
## 1. 真相来源与使用方法

1. 输入/字段/操作版本：[WorkflowTypes.swift](../Packages/UI/Sources/DWorkbench/Workflow/WorkflowTypes.swift) 的 `WorkflowOperationDefinition / WorkflowPortDefinition / WorkflowFieldDefinition`；下列模型操作现均为definition version 1。操作ID不是模型revision、安装实例、后端版本或未来节点实例ID。
2. 准入：[WorkflowRegistry.swift](../Packages/UI/Sources/DWorkbench/Workflow/WorkflowRegistry.swift) 的 `validate` 与各operation闭包；联合媒体/数值限制仍在真实请求消费者，不由标题、帮助文案推导。
3. 应用冻结/调用：[WorkflowServices.swift](../Packages/UI/Sources/DWorkbench/Workflow/WorkflowServices.swift) 的 `prepare/languageRequest/generateImages/generateVideo`；[AppSessionFactory.swift](../D/AppSessionFactory.swift) 将实际模型适配器接入既有Runtime。`ReleaseModelDescriptors`是定义投影，不是安装发现或运行许可。
4. 身份、固定权重revision和已有真实验证：[首发模型矩阵](RELEASE_MODEL_MATRIX.zh-CN.md)。本页不复制大段实测日志，也不将旧CLI/Runtime通过升级成当前App通过。
5. UI：[QuickGenerationView.swift](../Packages/UI/Sources/UI/Views/Quick/QuickGenerationView.swift) 从definition生成字段，[ChatWorkbenchView.swift](../Packages/UI/Sources/UI/Views/Chat/ChatWorkbenchView.swift) 以相同文字配置生成角色消息。节点、Quick、Chat共用能力，但不是同一个交互工作面。

当前字段结构只含id/title/kind/default，端口含type/required/assetListKind；**尚无完整数量/条件依赖/语义角色/单位/展示分组声明**。以下单位和组合是对consumer的核对，不可解析本页为执行规则。下一阶段应扩展现有值型描述及展示投影，不新建一套Quick契约。模型已知上游能力、D实际消费、安装/材料准备、已验范围分别展示；模型未准备不等于未支持，未验证不等于已可用。

## 2. 冻结九模型的能力—后端—入口

下表“输入”中的端口为现有有类型绑定；省略可选文本端口时使用字段后备值，最终请求仍必须合法。媒体个数不是端口数。输出均经现有Store发布；预览、采用和导出是后续显式动作。

| 模型 / 节点操作 | 输入与条件、输出 | 后端与消费位置 | 当前Quick入口及验证边界 |
|---|---|---|---|
| Qwen3.5-9B / `d.model.qwen35-9b` | task/content文字；可选有序images(PNG/JPEG)和video(MP4或有序列表)。简单task/content与非空messagesJSON互斥；JSON消息须引用全部输入。输出text或结构化response；json是提示+后验解析，非约束解码 | `MLXQwenVLMBackend` / `qwen35-vlm@1`；`WorkflowServices.languageRequest` → [QwenMessageMapping](../Backends/MLX/Sources/DMLXBackend/QwenMessageMapping.swift)。9B只接受enableThinking；effort/preserve非默认拒绝 | 文字Chat及Quick单次表单/Canvas。原始BF16、Q4是不同准备配置；原始真实双图/视频/JSON/工具记录见矩阵，不宣称所有上下文长度通过 |
| Qwen3.8-27B / `d.model.qwen38-27b` | 同类4端口；27B额外接受reasoning_effort/preserve_thinking；thinking=off不能配非默认effort | 同一VLM实现，由实际inventory/modelSize决定模板规则；共享profile不意味着型号能力相同 | 同上；原始BF16双图/JSON/工具/四帧时序视频及F09比较证据复用；长上下文极限/同包GUI等未验范围不补造 |
| FLUX.2-klein-4B / `d.image.generate` | prompt或promptText；ref为可选有序图/列表，不丢尾项。输出候选PNG；固定4步、guidance1；目标256…2048且32倍数 | `MLXImageBackend`；无参考scalableKlein4B，有参考referenceKlein4B；[WorkflowImageRecipe](../Packages/UI/Sources/DWorkbench/Workflow/Models/WorkflowModelBinding.swift) → ImageRequest | 图像Quick/Canvas，默认staged，可选ssdLayered；BF16/Q8分开。已有原始BF16/SSD真实请求及历史普通App证据复用 |
| FLUX.2-dev / `d.image.flux2-dev` | 同类2端口；有序参考实际编码；PNG；目标256…2048且16倍数，steps≥1、guidance有限非负 | `MLXFluxDevBackend` / `flux2-dev-bf16-v1`，原BF16编码/扩散及F32解码；[LocalFluxDevInventory](../Backends/MLX/Sources/DMLXBackend/LocalFluxDevInventory.swift) 及后端encode/denoise消费staged/ssdLayered | 本轮移除R3遗留的SSD共享入口拒绝，默认staged不变。现有Runtime完整50步/双参考/取消证据复用；新增双入口CPU到引擎捕获通过，**新的App选项原生操作未验** |
| Wan2.1-T2V-1.3B / `d.video.generate` | prompt；无首尾帧。输出无音轨MP4。尺寸16倍数、4n+1帧；seed UInt32；steps≤1000、guidance>0及预算按实际契约 | `MLXVideoBackend` / `wan21-t2v-1.3b-bf16-v1`；[VideoExecutionCapability](../Sources/DInference/VideoExecutionCapability.swift)，`WorkflowServices.generateVideo` | 视频Quick/Canvas；已有完整T2V及历史普通App，不能标I2V；通用VideoRequest有帧字段不表示Wan支持 |
| LTX-2.5 / `d.video.ltx-2.5-dev-bf16-full-v1` | prompt＋可选单张firstFrame PNG（经尺寸校验），拒绝lastFrame；32倍数、8n+1帧；含伴随音频MP4 | `ExternalVideoBackend` → [ltx_plan.py](../Backends/Video/Adapters/ltx_plan.py)；完整原始dev单阶段（扩散矩阵BF16，保留290个F32调制表），CFG/STG及显式streamWeights | 视频Quick/Canvas；既有固定自然视频/音轨本人结果复用。当前子模式不代表整套LTX上游全部能力，不能把首帧叫通用多参考 |
| MiniMax H3 Base / `d.video.minimax-h3-fl2va-bf16-full-v1` | prompt＋独立firstFrame/lastFrame，各0或1PNG；24fps、22…362且5+17n帧、面积≤768×1344；guidance=1、负提示空、shift=1；含音轨MP4 | `ExternalVideoBackend` → [h3_plan.py](../Backends/Video/Adapters/h3_plan.py)，完整BF16 FL2VA Base；[ExternalVideoExecutionProfile](../Sources/DInference/ExternalVideoExecutionProfile.swift)及[WorkflowVideoRecipe](../Packages/UI/Sources/DWorkbench/Workflow/Models/WorkflowVideoRecipe.swift) | 视频Quick/Canvas；既有文生/首尾自然样本及本人确认复用；非Ref2VA，不新增该能力 |
| MRT2 small/export-v1 / `d.music.generate` | prompt＋可选notes/chords；真正转换为25Hz音符条件，不是拼入prompt；1…400帧（≤16秒）；输出audio | `MLXMRT2Backend`；[WorkflowMRT2Condition.make](../Packages/UI/Sources/DWorkbench/Workflow/Operations/WorkflowMusicOperations.swift)；非零力度/声部身份不编码、同音合并、鼓不受约束 | 音频Quick/Canvas；既有条件与听感证据复用。精确结构输入不等于声音精确服从；不是歌词或通用音频参考槽 |
| ACE-Step1.5 XL SFT / `d.music.ace-step-1.5-xl-sft` | prompt、lyrics文字，独立风格reference/编辑source音频；generate/cover/repaint；后两项必须source，repaint另需区间；输出audio | `ExternalACEBackend`，原始F32 no-LM；[WorkflowACEOperation.request](../Packages/UI/Sources/DWorkbench/Workflow/Operations/WorkflowACEOperation.swift)、[ACERequest](../Sources/DInference/ACERequest.swift)、[AudioRequest](../Sources/DInference/AudioRequest.swift) | 音频Quick/Canvas；既有50步四模式及试听证据复用。模式/歌词/区间现是通用字段；尚无播放器可视化区间编辑，不因设计举例标为已实现 |

图像参考的冻结RGB8每张256…2048、32倍数（[ImageReference](../Sources/DInference/ImageReference.swift)）；不能把Dev目标的16倍数当作参考尺寸。参考列表保序，拒绝旧单张与列表同时给入（[ImageRequest.resolvedReferences](../Sources/DInference/ImageRequest.swift)）；现有端口没有单独的最大图片数声明，数量与资源拒绝归真实consumer，不在本页捏造。

Qwen视频由当前后端按2fps取帧，超过maximumVideoFrames预算报错，不悄悄取前64帧。工具声明/模型tool-call结果不是自动执行工具；现有工具仍走独立授权边界。

## 3. 初始字段、单位与适用性

下面是当前definition新建值，**不是用户旧草稿、历史请求、性能建议或模型能力上限**。`modelID=""`须绑定实际安装；所有`memoryBudgetGiB=0`均交运行时策略，正数按2³⁰字节/GiB。旧记录中缺失字段仍按已有兼容回退，不改写历史。精确限制以第二节消费者为准。

| 路线 | 当前字段默认值及重要作用条件 |
|---|---|
| 两款Qwen（各19项） | `task="请写一个简短的创作提案。"`，`outputMode="text"`；`maximumPromptTokens=2048`、`maximumOutputTokens=256`（token）；`temperature=0.7`、`topP=0.95`（采样标量）；`modelID=""`；`minimumPixels=0`、`maximumPixels=0`（每图像素数，0用模型配置）、`maximumVideoFrames=64`；`chatTemplateOverride=""`（空用模型模板，非空Jinja≤64KiB）；`memoryBudgetGiB=0`、`loadingStrategy="resident"`（另可选ssdLayered）；`messagesJSON=""`、`toolsJSON=""`；`thinking="model"`、`reasoningEffort="model"`、`preserveThinking="model"`；`seed=""`（未指定，非空为UInt64十进制）。思考三项适用差异见第二节，不能同名照抄。来源：`WorkflowLanguageOperations.makeLanguage`＋[WorkflowLanguageMessageForm](../Packages/UI/Sources/DWorkbench/Workflow/Operations/WorkflowLanguageMessageForm.swift)。Chat初始化另用response、清task/messagesJSON，发送前构造有序消息并冻结seed；不是要求用户写JSON |
| 两款FLUX（各10项） | `promptText=""`；`width=512,height=512`（像素）；Klein `steps=4,guidance=1`，Dev `steps=50,guidance=4`；`seed="42"`（UInt64）；`count=3`（1…8独立候选）；`memoryBudgetGiB=0`、`loadingStrategy="staged"`（两者均可选ssdLayered）、`modelID=""`。来源：[WorkflowImageOperations.makeGenerate](../Packages/UI/Sources/DWorkbench/Workflow/Operations/WorkflowImageOperations.swift)。Quick改count=1，用独立`QuickDraft.attempts`重复提交；默认attempts=1 |
| Wan（12项） | `promptText="A small boat on a calm lake."`、`negativePrompt=""`；`width=320,height=192`，`frameCount=17,frameRate=16`（fps），`steps=50,guidance=6,scheduleShift=8`；`seed="42"`、`memoryBudgetGiB=0,modelID=""`。源自[WorkflowVideoPresets.fullPreview](../Packages/UI/Sources/DWorkbench/Workflow/WorkflowVideoPresets.swift)，不是connectivity或service兼容fallback。scheduleShift无秒单位 |
| LTX（13项） | 同上后备prompt，`negativePrompt=""`；`width=256,height=256,frameCount=9,frameRate=24,steps=30,guidance=3,stg=0`；`seed="42",streamWeights=true,memoryBudgetGiB=0,modelID=""`。STG有限非负；recipe的scheduleShift固定1。seed UInt32。来源：[WorkflowExternalVideoOperations](../Packages/UI/Sources/DWorkbench/Workflow/Operations/WorkflowExternalVideoOperations.swift) |
| H3（11项） | 同上后备prompt；`width=256,height=256,frameCount=22,frameRate=24,steps=20,guidance=1`；`seed="42",streamWeights=true,memoryBudgetGiB=0,modelID=""`。没有negativePrompt/STG/scheduleShift字段；recipe写空/无/1，不能放假控件。Swift契约seed UInt64。来源同LTX |
| MRT2（4项） | `promptText="Solo piano, clear melody."`、`durationFrames=100`（25Hz条件帧=4秒，不是音频采样帧）、`seed="42"`（UInt32）、`modelID=""`。固定配方temperature1.3/top-k40/MusicCoCa CFG3/音符鼓CFG1没有用户可调字段，不冒称可调默认。来源`WorkflowMusicOperations.music`与[AudioSynthesisParameters](../Sources/DInference/AudioSynthesisParameters.swift) |
| ACE（20项） | `mode="generate",promptText="Solo piano.",vocal="instrumental",lyricsText="",language="en"`；`bpm=0`（未指定）、`keyScale=""`（未指定）、`meter="auto"`（另2/3/4/6，仅拍数非任意拍号）；`duration=5.2`秒；`memoryBudgetGiB=0,loadingStrategy="resident"`（另ssdLayered）、`steps=50,guidance=7`；`coverStrength=1,noiseStrength=0,repaintStrength=1`（0…1）；`startFrame=0,endFrame=48000`（48kHz采样帧，右端不含）；`seed="42"`（UInt32）、`modelID=""`。歌词只在vocal=lyrics采用，器乐+非空歌词拒绝；reference/source必须48kHz双声道；cover采用前两strength，repaint采用后者及区间；编辑时duration取原声精确帧时钟，不用表单秒数。来源`WorkflowACEOperation` |

`count/attempts`是应用串行的独立请求，不是模型内部batch；MRT2结构条件是配套控制，ACE描述/BPM/歌词为独立请求字段，不能全降成prompt。缩放/格式转换属于软件后处理；未适配蒙版或控制组件不能因为本页出现“图像”就提供假入口。

## 4. 已确认差距与下一阶段处理

| 类别 | 本次判断与准确落点 |
|---|---|
| 后端已有、共享入口遗漏 | **Dev SSD已局部修补。**R3 e7728a0e在尚未实现时拒绝；R4 271ac840加入真实逐层consumer/估算，遗漏了共享definition/recipe及旧拒绝测试。此次同时补定义、校验、recipe，默认/精度不变；本轮新控制器请求回归与旧真实Runtime证据分开，App入口待桌面 |
| 有字段但当前模型/模式不适用 | Qwen9B effort/preserve给非默认会明确拒绝；ACE cover/repaint的strength按mode只构造适用editOptions，歌词条件有互斥检查。这些不是“假控件生效”。未来应以当前模式标明未采用，保留草稿；不删除consumer拒绝 |
| UI位置难找，非未实现 | Quick把task/promptText放主区，大部分其他字段进Advanced；缺共享角色/单位/分组描述。视频首尾与音频source/reference不能靠filetype合并。下一阶段只重排和注入纯展示信息，复杂校验继续复用 |
| 操作对象提示不足 | Quick底部全局isRunning控制原run，但切分类后的顶部/结果已指新draft；“取消生成”未直接标运行归属。底层没有改停错对象，未来活动入口/停止文案应显式标原模型/模态/run，保留单一所有权，不另建队列 |
| 模型切换与隐藏输入 | Quick按operationID+modelID保留独立草稿；异步导入commit核原draft/node/inputs，不覆盖新选模型。现有Chat保持附件，执行时按实际能力校验；并非已实现v0.2的兼容参数继承或“未采用材料”视觉状态。不能无依据清空材料，也不静默只传第一项 |
| 当前检查没有发现的类别 | 未确认其他“UI显示字段但后端完全不消费”的生产缺陷；这是九条当前路径的源码结论，不代表任何未来参数自动接通或所有上游能力全适配 |

后续UI负责展示全部已适配能力；本表不是把缺口改名profile便算完成。原有发布责任、AP1/CORE/I2V边界仍由[支持与发布差距](MODEL_SUPPORT_AND_RELEASE.zh-CN.md)维护，不在此重开或偷偷取消。

## 5. 新UI区域到现有组件/对象

以下路径除明确标注外从`Packages/UI/Sources/`起。源码符号优于易漂移行号。v0.2尺寸/断点/动画/会话列表位置仍待原型，不在本轮写死。

| 新区域/动作 | 复用入口与实际所有者 | 关闭、取消、错误和实施分类 |
|---|---|---|
| 红绿灯/窗口留白；右上模式切换；中央四模态 | `UI/Views/Quick/DualWorkbenchView.navigate`、现有模式/分类Picker；`DWorkbench/Quick/QuickGeneration.selectCategory` | 导航只改展示，不提交/取消/加载。未来主要是现有入口重排，系统窗口控件不重画，不能销毁业务草稿 |
| 左模型、安装/就绪、参数、控制 | `QuickGenerationView`、`QuickGenerationController.definition`、`DualWorkbenchView`模型准备与readiness刷新；Chat配置在`ChatWorkbenchView`/`ChatController` | 对象是**下一请求配置**。复用实名安装/模型库；高频模型切换需更浅入口。分组/单位/条件适用需新增展示元信息，不从自然语言解析 |
| 底部草稿、附件、语音、发送/停止 | `ChatWorkbenchView.composer`；`TextSourcesQuestionEditor`；`ChatSpeechPanel`；`ChatController.send/cancel`。非文字复用Quick输入绑定/运行方法 | Chat按session保存草稿与附件，Quick按draft；语音审核后采用不自动发送。保留现有编辑器身份、marked text/Undo。Stop作用于已提交活动run，不清正文；待资源释放后恢复发送。重新排布，不复制四个隐藏编辑器 |
| 中央消息/结果 | `ChatWorkbenchView.messageCard/conversation`；`QuickGenerationView.runCard/QuickAssetPreview` | 对象是**当前查看的历史结果**，按冻结记录显示；不能用当前左侧参数替换历史。音视频AVPlayer离开时暂停是现行行为，未来播放策略另定；不等于取消推理 |
| 右侧资产、候选、参考采用 | `DualWorkbenchView`的`SharedLibraryBrowser`回调；Quick `setInput/moveInputAsset/removeInputAsset`；Chat `addAttachment/addSharedAttachment`；同一Store | **选中/预览/加入请求/删除源**是不同动作。移除待发引用不删原件。导入逐项错误就近、已发布资产不因晚到绑定拒绝而删除。未来侧栏位置/页签需原型，非新资产库 |
| 编辑/比较/来源详情 | `ChatWorkbenchView`单一details队列、`ChatSheetQueue`、消息/attempt身份；Quick preview状态 | 打开时固定目标，普通关闭只关展示；取消编辑保留旧版本。不以hover控制持续编辑存在。未来持续操作面板参与布局，具体形态待原型 |
| 任务反馈/保存重试 | Quick `QuickRunRecord.draft`、Chat activeSessionID/attemptID、既有WorkflowServices与Runtime；`retrySave` | **在途任务**与当前配置/选中素材分开，显示真实排队/取消中/保存失败。重试保存复用产物，不自动再生成。项目退出经ProjectSession.close/drain，不复用普通关闭按钮语义 |
| 外观设置 | `ChatDisplayPreferences`/`ChatDisplayPreferencesPanel`已有主题、字号、宽度、换行、快捷键 | 玻璃/独立动效/轻量外观/实时预览未实施。未来按公开SDK/系统无障碍核对；不能把文字整体opacity当背景透明度，不能为美化改输入/历史语义 |

## 6. 复用夹具与缺口（仅下一UI阶段的受影响回归）

- **长单条文本/链接取消**：RDrag沿用的`Markdown-controls.dproject`，40节已保存合成回答；无需模型生成。当前F17原生候选仍待验；消息UUID不是消息内部阅读点，不新增全文定位引擎。
- **组字/Undo与窄窗**：既有`ChatPresentationTests.realWorkbenchResizePreservesInspectorComposition`等宿主及本人中文/日文证据；未来重排后需要受影响复验，不能以AX填字代替组选字。旧通过现在不重做。
- **混合附件/异步切换**：34字节`numbers.csv`＋已有小PNG，`QuickGenerationTests`的导入ticket、`ChatTests.attachmentPreparationDoesNotWriteAfterProjectExit`及Store副本保护。服务接收不是Finder命中证据；F19独立待验。
- **跨模态在途、旧结果与不兼容材料**：复用`QuickGenerationTests`分类草稿/运行归属和有序输入失败夹具、RUnlock既有在途分类原生记录。待设计验证“当前配置/查看结果/选中素材/在途任务”四对象标识，而非九模型全排列。
- **低动效/高对比度/窄窗**：目前没有v0.2玻璃与动画实现，无法将旧截图作为新效果通过；后续使用合成状态核可达性/布局和系统设置。只列准备缺口，本轮不新增外观测试平台。

当前实际状态、精确外盘R目录、唯一推荐包及下次桌面动作仍只见[当前行动](CURRENT_ACTIONS.zh-CN.md)、[集中队列](FAILURE_AND_PERMISSION_AUDIT.zh-CN.md)、[试用入口](RELEASE_FREEZE_TRY.zh-CN.md)。本页准备完毕不表示F17/F19已验，也不自动开始视觉改版。
