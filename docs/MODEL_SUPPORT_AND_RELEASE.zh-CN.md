# 当前模型支持与首发收口

核实日期：2026-09-23；生产快照`b334920907de0324bf3e0146bb78433742356a6c`。以下复用明确版本的既有验收，本轮只读核对，没有重跑全模态。源/产物/候选身份见[当前行动](CURRENT_ACTIONS.zh-CN.md)，产品承诺见[目标](PRODUCT_GOALS.zh-CN.md)。静态代码中的旧awaiting标签若与运行记录不同，登记为展示/能力目录债，不在文档整理时改生产逻辑。

“App”指已有源入口和指定隔离开发签名产物证据，不意味着用户普通D已替换或公开安装包完成。模型要求、适配支持、实际受测、硬件建议、用户选择分别表达；登记型号不等于全配置验收。

## 已支持到什么程度

| 类别／固定模型 | 已有实际能力 | 证据边界与未支持 |
| --- | --- | --- |
| 文字：mlx-community/Qwen2.5-0.5B/1.5B/7B/32B-Instruct-4bit | 四档登记；文稿选段改写、候选接受/拒绝/撤销/保存；TXT/Markdown片段问答和来源 | 0.5B App改写；1.5B短改写/取消；7B M4/16GiB统一App资料问答完整闭环；32B M4 Max便携CLI短文、26455-token输入/重复/取消恢复。不能说32B App或128K已验。仅qwen2、flat affine4-bit/group64；小模型问答存在幻觉/串引用，不能保证专业写作/音乐理论 |
| 额外容量试验：Qwen2.5-72B-Instruct-4bit | 便携CLI已加载并产出少量文字 | 用户手停，两次均无完整终态成功；不在App四档登记，不是已验72B，也没有OOM证据 |
| 图像：mzbac/FLUX.2-klein-4B-q8 | App文生图、单参考PNG改图、候选比较/采用、保存重开/PNG导出；4步/guidance1/512-token条件 | 支持宽高256…2048且32倍数；本机512²/768×512/512×768，M4 Max CLI1024/1536/2048²及2048重复通过。无mask/strength/局部锁定、多参考、LoRA、RAW或任意JPEG；参考服从近似，非其他FLUX家族 |
| 声音：stabilityai/stable-audio-3-optimized sm-music | App提示生成、WAV参考变体、采样帧区间重绘；44.1kHz双声道float32 | 本机6秒三操作/取消恢复；M4 Max CLI6/30/120秒。不是音符精确控制或TTS；区外PCM保持只对应受测6秒重绘 |
| SA3 medium／sm-sfx | 后端固定profile；medium真实CLI本机6秒、M4 Max6/30/120/380秒 | 普通App仍sm-music；medium App部署未验，sm-sfx未找到真实推理验收。不能据旧表写medium未实测 |
| 器乐：google/magenta-realtime-2，mrt2-small-export-v1 | App风格＋音符条件→器乐候选、试听/采用拒绝/保存/WAV；48kHz双声道 | App真实4秒/取消恢复；声明上限16秒、400条件帧、512音符、40ms时间格并不全实测。音符/配器近似，已有额外伴奏，不保证纯钢琴/分轨/严格和声；非歌词演唱 |
| 音高：SwiftF0 0.1.2 CPU ONNX | 内部评估App原声选区→独立16kHz派生→音高/近似音符→候选/JSON/保存；录音另属原生采集 | 7类样本与约10.899秒原声三次分析；低音220Hz片段识别不可靠。16ms…120秒支持范围非全质量验收；模型独立分发许可unknown。音符纠错/普通试听/MIDI App属于AP1候选，服务已接纳；不是ASR/TTS |
| 歌声：Qixuan v2.7.0 DiffSinger OpenUtau＋nvidia/bigvgan_v2_44khz_128band_512x | 旋律、中文歌词、显式音素/元音锚→44.1kHz单声道WAV；源backend/CLI已验CPU及MPS声码器配方 | Qixuan ONNX仍CPU，BigVGAN GPU FP32可选，mel近似重投影非原配声码器；短6/6.5秒及取消恢复，H24 GPU试听通过。AP1 App6秒生成/候选/重开已验但未源接纳；新GPU资源与AP1统一App未组合验收。无自动全语言发音/seed或长句质量保证 |
| 文生视频：Wan-AI/Wan2.1-T2V-1.3B | App文本/负文本→无声H.264 MP4、预览/采用拒绝/保存重开/安全导出 | CLI832×480/17帧/50步；App320×192/17帧/16fps/50步/seed42。可见运动但有模糊变形噪点；无I2V、音轨或时间线；非其他Wan checkpoint |
| 首图视频：Wan-AI/Wan2.2-TI2V-5B | 隔离候选；R9已实现GPU注意力与全30块流式部件，固定1216×736/121帧完整正负首步通过 | 825权重及重复/取消恢复通过；完整一步约14分钟。CORE外盘50步参考于9月22日正常结束并保存latent，但未解码/全片画质/完整D条件适配/App验收；首步部件在源不等于源App支持I2V，非全部Mac配置 |

### 版本与证据

Qwen固定revision依尺寸0.5/1.5/7/32/72B分别为 `a5339a4131f135d0fdc6a5c8b5bbed2753bbe0f3` / `8b403126fc14f14cfc99bb4cfa72ecbc129ea677` / `c26a38f6a37d0a51b4e9a1eb3026530fa35d9fed` / `2938092373e5f97b95538884112085364c2da315` / `36a74b07390031bb18c9f12fb7c06699bc6273c4`。FLUX `ef52ee019fd1d0e75ae4deb40476ba65989716d7`；SA3 `da6edc54ddba10bfd79a077102ded687f80e882b`；MRT2 `010aa0dcb0dfd27b24f0ad07b4dad63e8f9521cc`；BigVGAN `95a9d1dcb12906c03edd938d77b9333d6ded7dfb`；Wan2.1 `37ec512624d61f7aa208f7ea8140a131f93afc9a`；Wan2.2 `921dbaf3f1674a56f47e83fb80a34bac8a8f203e`。SwiftF0 ONNX SHA256 `fa91bb45512b90339cf4b00a599ba8fe3a253c46419fcfe6b46df77a8a8336a5`。

- 源接口：`Packages/UI/Sources/DWorkbench/Models/TextModelProfiles.swift`、`Backends/MLX/Sources/DMLXBackend/LocalModelInventory.swift`、`AudioExecutionCapabilities.swift`、`Sources/DInference/ImageExecutionCapability.swift`；静态登记中旧awaiting不覆盖更新的实际证据，不能把它当全功能通过。
- [统一App](tasks/D-MULTIMODAL-BASELINE-01.md)受测/接纳 `aba1326f72f33ada028e35a8e799ef04965e7afa`，包括7B问答、参考图、SA3/MRT2、Wan；[文字质量](tasks/D-TEXT-SOURCES-01.md)、[参考图](tasks/D-IMAGE-REFERENCE-01.md)。
- 外机证据：`D-Development/AgentTrials/D-PORTABLE-KIT-01/run-20260912T142949Z-field-review/现场测试报告.zh-CN.md`，包`3fb99d334fc0217191814cc5fb5d04523ea2b1ef`、CLI`f743909647c83cb99d4d9f0dee0a939f80388576`。8次日志均报告M4 Max、36GiB/macOS26.6.1；用户记忆48GB，差异未解。32条通过覆盖24种case；不是32个独立型号，也没有96GiB以上实机。现场音频取消未命中/恢复未启动。
- [HUM](tasks/D-HUM-PITCH-01.md)源受测`9c8e7247b090f617517d043eda3e3124abd2f2e7`；[歌声设备](tasks/D-SINGING-DEVICE-01.md)源受测`dc849c6327e59f1a297d598362a5d15b09d53279`；[AP1](tasks/D-AUDIO-PROJECT-01.md)候选受测`54721d91a535e71d01c9caeba86c04277fbbb933`。H23/H24已关闭；H22用户延期UI重构，不是修复通过。

## 距离首次发布

已不是“从零补四模态引擎”，主要工作转向**剩余视频门槛、已有候选整合、一个实际组合，以及陌生用户可独立使用的交付闭环**。不能用目录/测试数量给可靠完成百分比；新UI完成也不自动满足发行条件。

| 有限收口 | 已有基础 | 仍需验收的明确出口 |
| --- | --- | --- |
| 1 基础能力收口 | 图文/声音/器乐/T2V已有统一App证据；歌声GPU及音符服务已验 | I2V全片数值/质量/D接线仍未过；AP1与GPU歌声资源组合整合。首发承诺若改为不含I2V需显式产品决定，不以状态更新偷偷后置 |
| 2 新UI＋一条真实组合 | 项目/资产/候选/保存等服务可复用；PNG配方基础已有 | 统一节点是已明确方向，具体新UI尚待用户方案；实际组合例如文字整理生成条件→参考图候选→人工采用/保存来源。统一App内多个按钮分别成功不等于组合已验；输入法/缩放/键盘/可访问性/取消/保存需最终界面验收 |
| 3 公开能力的模型准备与许可 | 下载校验/恢复/重连及部分离线引擎部署已有 | 正式App不附权重；用户明确选择下载/导入并处理用途资格。D对自身代码/运行时、实际随包与获取行为核对来源/条款/摘要，不替用户作法律判断或接受条款。现有SwiftF0包内含ONNX、独立权重许可unknown，无权重发行路径尚未落地；不能写成已解决或擅减HUM承诺。资格框不创造许可，SA3/Gemma、MRT2、Qixuan/BigVGAN条款分别记录 |
| 4 统一应用打包和干净Mac首用 | 开发签名沙盒和独立离线资源包已跑通 | 最终全部引擎/依赖随包或支持的获取方式；选择发行渠道后按该渠道完成签名/公证/系统检查，干净Mac/新用户无Xcode与开发目录完成安装、授权、模型准备、生成导出；便携CLI外机不等于App首次使用 |
| 5 恢复、升级和外部验收 | 冷重开、v1→v2及统一App v9/v10→v11媒体保全、同签名跨构建书签已有证据；AP1 v12/v13/v14→v15属于未接纳候选 | 最终发行包的升级/失败恢复、外盘断开/空间不足/权限拒绝/旧项目保护；声明支持的硬件范围与代表配置；外部用户按说明独立完成。最终发布/主分支推进仍另行授权 |

这五项是剩余里程碑，不是五个等长编码阶段或工期承诺；后两项可在用户设计UI时准备，但最终包必须重验受影响链路。当前部署目标macOS26.2，不能宣称全部历史Mac均支持。后续硬件档位按实际模型/精度/工作负载测试，不能把16GiB、small或512永久封顶。

发布后保留更多模型/LoRA、复杂蒙版/精修、长视频/完整DAW/高级谱面、高级通用编程/任意图兼容、RAW及更多容器、手机捕捉、远程API/C2PA等；不要求首发全做，不因一个模型兼容问题无限追加。旧先全模态再组合排期已替代；当前整理结束只提交有限组合提案，不续跑产品任务。


## 证据绑定与本轮只读更新

- 表中图文/SA3/MRT2/T2V的统一App证据绑定`aba1326f72f33ada028e35a8e799ef04965e7afa`及[D-MULTIMODAL-BASELINE-01](tasks/D-MULTIMODAL-BASELINE-01.md)，开发机M4/16GiB；表内未列规模不外推。32B/大图/medium等外机CLI另绑定上述便携包/CLI版本，日志36GiB与用户48GB记忆差异保留unknown，不编造高内存实测。
- 源R9实际验证`8fb7d48e14ba4e140177925905ddb8130751617d`，到b334只有文档。参考full50使用CORE冻结外部脚本/输入清单，guard及data/result位于`D-Development/AgentTrials/D-CORE-CLOSE-01/run-20260921T175000Z/video/full50/`；50步、原attention容差及首步对照、取消恢复通过；约39247.6秒，释放后PyTorch MPS active为0，driver记录不是整个系统零占用。输出仅FP32 latent，摘要与本轮读取依据在整理任务。
- 歌声/HUM的AP1包与schema15没有源接纳；CORE将AP1和GPU部署组合后的全构建/真实App仍未验。包装夹具、Swift parse、CLI、旧App不能相加成一个不存在的最终产品版本。
- 已注册、当前宿主可部署、该配置真实通过、进入哪一App分别判断：32B是登记+CLI，72B仅容量试验，SA3 medium是profile+CLI，sm-sfx无真实验收；不存在一张通用“安装完成=可运行”目录可替代这些边界。

当前首发系统目标macOS26.2/Apple Silicon，干净Mac无Xcode/开发目录、最终无权重包、签名/渠道/升级与外部用户完整验收仍开放；整理没有重新确认市场/法律时效信息，也没有作分发法律结论。
