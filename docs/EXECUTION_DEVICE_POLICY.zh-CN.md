# 计算设备原则与效率修复清单

修订DEVICE-2026-09-16.1；状态：**用户明确要求，当前有效**。Lead维护。静态核查源`74384bb4c4eddc0fe075f4b705b1a3f2824103a3`；首图视频候选`0f2797cab421e9c5dd52e75f85dddfe5a8414d96`另列，不能当作已接纳App。实际后续版本/结果见CURRENT_ACTIONS、任务与外部回执。

## 2026-09-16 本人返回后的优先级调整（当前有效）

用户要求：GPU功能路径跑通后推进下一产品阶段，性能优化列入待办。DEVICE-r1的GPU功能/取消/数值证据继续有效；E01的端到端速度、跨框架传输、GPU驻留与规模对照转为后续优化，不作为AP1或其他无依赖产品工作的前置。E02—E06继续登记，不因延期被记成已修复；未来模型适配仍遵守GPU首选、CPU显式备选原则。

本次调整不豁免I2V原有画面/运动质量和完整跨设备数值阻塞，不把GPU可运行等同I2V可交付。先集中办理AP1 H22/H23并按原门槛接纳；性能优化另按实际用户等待时间与首发风险排期，不继续无边界微基准。

## 决定与边界

在模型、算子、许可及既定精度/质量支持范围内，**首先实现有最高有效性能的路径，当前重型神经网络优先GPU；CPU保留为用户可明确选择的兼容/参考备选**。NPU/Apple Neural Engine只在实际适配、设备支持及端到端测量成立后参与选择；不能从名称、模型格式或芯片存在推出支持或更快。不能为了便于当前16GiB开发而永久固定CPU；也不能把文件读取、tokenizer、PNG/音频封装、微小控制操作都迁移GPU来追求标签。

新功能默认推荐已验证的GPU路径。确有完整测量证明某个支持的CPU/NPU/混合路径更高效，应记录模型/硬件/规模及理由后选择，不以单次微基准代替。用户强制选择不支持的设备应明确拒绝；不会悄悄换CPU、降低精度、改模型/尺寸或上传远程。自动模式只有在适配器事先声明且用户策略允许时才可回退，必须记录原因和实际路径；本次I2V GPU候选禁止隐式CPU算子回退。

旧CPU数值参考可继续作为参考/兼容路径，历史通过事实不改；它不是正式GPU性能目标。旧文档中的“CPU唯一实现/CPU先行”不再作为未来产品默认。旧失败、许可、精度、验收标准和已耗修复预算保留，新设备功能明确单列，不借机重置旧算法修复。

### 偏差来源

已定位的具体旧决策在`docs/tasks/D-VIDEO-I2V-01.md`原“精度”、IMAGE及RUN章节：先用原版PyTorch CPU/FP32建立数值参考，随后冻结`CPUImageVAE`与`…cpuvae-v1`为唯一候选执行路径，并注明慢CPU解码。它确实是神经网络VAE，不是MP4读取。CPU参考的验证价值保留；把该首轮取舍延续为未来唯一产品方案，现在由用户最新设备原则明确替代。歌声CPU也来自分阶段接口/数值先行选择，不能因此被当作长期性能最优结论。修正的是后续实现/默认取舍，不倒改原记录、精度和失败事实。

## 可维护的最小契约

- 设备偏好、backend支持集合、当前环境可用性和实际执行记录分开；不在UI放尚未支持的NPU或全模型CPU按钮。
- 按组件记录请求/解析设备、运行时/版本、计算精度、CPU回退是否禁用/发生、可观察依据；有值未知就明确unknown。请求GPU、权重位于GPU、真实算子调度是不同证据。
- 新UI最终在兼容模型的专业执行设置中提供推荐/明确设备选择，沿现有公共请求与运行快照接线；不另建万能调度框架。候选I2V当前仅CLI显式profile选择，尚无该App入口。
- 同一模型的CPU/GPU配置不能复用误导性名称：旧`…cpuvae-v1`仍CPU，新`…gpuvae-v1`明确GPU。输入profile必填不被新默认暗改；“推荐”不改变旧配方。此选择仅VAE，文字编码/DiT另记MLX GPU。
- MLX当前设备为CPU/GPU，不虚构ANE开关。CoreML的computeUnits允许框架选择设备，并非保证整图只跑某单元；NPU声明要有相应执行证据。
- 设备同步、进程/资源所有权、取消和错误清理继续可靠；不能为速度删除drain/release、文件保护、数值检查或清理。MLX驻留/分配设置不代表同时限制PyTorch MPS。

## 当前实现核查与修复登记

P1为优先关闭的契约/硬编码问题；P2为需测量后判断的优化候选；不是所有CPU使用都已证实低效。

| 项目 | 已核实情况与证据入口 | 处理与状态 |
| --- | --- | --- |
| E01 首图视频VAE（P1） | 候选`Backends/Video/Python/d_video_i2v_image.py`的`CPUImageVAE/_create_vae`固定CPU FP32；`d_video_i2v_run.py`两次实例化。T5/DiT已明确MLX GPU，VAE不是普通视频文件解码器。 | 本轮先真实核MPS支持，新增GPU首选/CPU显式profile候选；原CPU工作区修补保留。接线/验收状态见I2V任务，整体画面/运动质量仍未通过，不默认启用App。 |
| E02 歌声（P1） | 已接纳`Backends/Audio/Python/d_singing_qixuan.py`的ORT会话固定CPU、1线程、顺序执行/禁图优化；BigVGAN权重、输入、网络也固定CPU FP32。App源尚未装配SingingBackend。 | 优先将许可明确的BigVGAN独立计时并验证MPS原精度数值/听感/释放，保留CPU；ORT/CoreML provider另核支持与条款，不能为加速擅自改写/转换受限声库。未修复、未声称GPU可用。 |
| E03 设备选择/报告（P1） | `Sources/DInference/InferenceRequest.swift`及图文配置无统一设备偏好/实际设备字段；SA3、MRT2、旧T2V依赖MLX默认GPU，没有显式执行设备证据。Swift MLX `Device.swift` TaskLocal默认GPU；未发现图文NN强制CPU。 | 后续窄契约贯通请求→适配器→结果；先固定实际GPU作用域和记录，再开放已验证CPU备选。CPU全模型覆盖和NPU均未验证；不批量加空参数。 |
| E04 估算准入/硬件容量（P1政策复核） | `Sources/DRuntime/InferenceRuntime.swift`估算超过预算会加载前拒绝；`ResourceBudgetPolicy`是物理内存减余量。App图文无显式覆盖入口，16GiB上1536²可因估算16GiB>12GiB预算被拒绝。 | 旧ALIGN明确保留，不能倒写历史违约。与用户“建议不代表上限、容量测试允许实际尝试”要求重新接线风险提示/显式尝试和真实失败；不删除表示范围/文件保护，也不承诺捕捉系统杀进程。待修。 |
| E05 缓存/编译/启动（P2待测） | 图文默认cache64/256MiB、配置至1GiB；SA3三阶段`compile_=False`及固定decode分块；MRT2 LiteRT条件编码无显式GPU delegate，5次warmup，每40ms同步/转NumPy。 | 先拆加载/编译/条件编码/推理/拷贝/清理耗时，比较冷启动与重复任务、内存/换页/取消。不直接删同步、扩大常驻或假定compile更快。当前MRT2 MLX导出直接返回PCM，旧raw SDK CPU codec不算现行瓶颈。 |
| E06 HUM音高（P2/后续测量） | SwiftF0/封装固定ONNX CPU；历史10.899秒原声分析0.33–0.36秒，非本轮重测。 | CPU固定应开放未来适配，但先量完整启动/传输/识别收益；GPU/ANE支持unknown。保留内部评估权重许可边界，不抢占重型CPU歌声与VAE。 |

辅助CPU工作：FLUX权重读取/转换、NumPy整理、PNG/WAV/MP4封装、AVAudioConverter、普通正弦音符试听不等于“AI改用CPU”。单重任务许可、分阶段卸载、完整校验属于现有可靠性约束；优化需独立对照，不因这次要求移除。

代码定位：图文`Backends/MLX/Sources/DMLXBackend/{MLXTextBackend,MLXImageBackend,MLXDiagnostics}.swift`、`Vendor/flux2-swift/.../Flux2WeightsLoader.swift`；音频`Backends/Audio/Python/{d_audio_sa3,d_mrt2_export,d_singing_qixuan,d_pitch_analysis_backend}.py`；视频`Backends/Video/Python/d_video_run.py`；历史HUM测量`docs/tasks/D-HUM-PITCH-01.md`。两名只读核查者分别审图文与音频，Lead核视频/原则，未将审核当新模型实测。

## 验证与性能口径

每个迁移先验证同模型/固定权重/输入/seed/精度/公式，再分别记录CPU组件、真实目标设备、数值/质量、取消后下一任务、失败/输出保护和产品入口；不改变已有黄金参考或容差来过关。算子支持不等于完整模型支持；完整模型支持不等于最快或可交付。吞吐、首结果、加载/编译、跨框架拷贝、关闭耗时、峰值和换页分别测，冷启动与warm分列。模型已加载的重复调用不冒充普通任务间热启动（现行会卸载）。

本轮外部证据：`D-Development/AgentTrials/D-DEVICE-AUDIT-01/run-20260916T105115Z`。真实Torch2.7.1/MPS FP32、CPU fallback关闭，conv2d/3d小算子通过；完整原版VAE320x192/17解码与固定CPU参考比较，3133440点0超限，原atol/rtol均3e-5，首帧/全部RGB最大1。单次加载1.05秒、decode24.14秒；不是端到端速度结论。参数/输出mps:0，释放后活跃张量0，但driver仍约6.46GB至进程退出；不可用CPU RSS0.40GB冒充总GPU/全机峰值。模型、源码、latent和CPU参考前后摘要不变，进程回收。

随后同一已加载实例连续两次解码：MPS为28.39/36.00秒，CPU工作区候选为20.09/19.40秒，均满足原数值门槛（CPU差0）。这是小样、非随机顺序、非端到端的有限测量，已足以否定“换MPS必然更快”，尚不足证明所有规模/机型的排序或归因缓存/换页。GPU有效性能仍是E01未完成部分；不能据功能可运行宣称已达效率目标。CPU返回NumPy及GPU→CPU传输与纯decode计时边界不同，另有进程启动/校验成本须在正式CLI比较。

首探针因Lead误取upstream摘要而非已补丁摘要，在加载前拒绝；保留失败，以既有受测code-before与PROVENANCE.patched_sha256核正，新探针通过。未改任何生产代码/黄金参考/标准。完整结果、后续实现与版本见本run最终回执及I2V任务。

### 固定实现结果（非产品整体接纳）

DEVICE-r1受测`ba978d508c91db55f11fc008bec25ccf6baf0f1a`已实现两个显式VAE profile；151组件方法、2个独立先失败后通过的反例、真实GPU/CPU编码解码、GPU两边界取消、恢复与CPU CLI均通过。源仅同步文档，代码留独立候选，完整记录见I2V任务“DEVICE-r1设备选择收口”。没有声称GPU更快、整个I2V质量通过或App按钮已可用。后续修复继续按E01—E06状态推进，不把这次设备功能完成当全部效率问题关闭。

## 技术依据（2026-09-16按需核实）

- [PyTorch 2.7 MPS环境变量](https://docs.pytorch.org/docs/2.7/mps_environment_variables.html)：启用MPS fallback会对不支持算子转CPU；本次GPU验证显式禁用。未改fast-math或内存水位绕过限制。
- [Apple CoreML设备与性能诊断](https://developer.apple.com/videos/play/wwdc2022/10027/)及[compute units](https://developer.apple.com/documentation/coreml/mlcomputeunits)：允许设备与实际分区需区分。
- [ONNX Runtime CoreML provider](https://onnxruntime.ai/docs/execution-providers/CoreML-ExecutionProvider.html)仅作为候选入口，未据其存在宣称当前声库或SwiftF0支持ANE。

更新触发：设备适配/默认策略/测试环境或性能证据变化。读取时机：新模型选型、性能诊断、精度/驻留/并发改动、加入设备选择入口。Lead维护状态与决策，Worker只在冻结任务范围实现，按task/run记录来源。
