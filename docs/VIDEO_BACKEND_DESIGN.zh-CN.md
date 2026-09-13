# 视频后端：薄接口与首个验证方向

核实日期：2026-09-13。状态：用户要求的视频后端研究/设计提案；**没有视频模型下载、安装、运行或产品实现**。适用代码起点ec7c6eff989dbff501db470838448cc4e793258e。来源为官方模型卡、固定版本实现源码和实现者测量，不是D本机验收；不是已冻结ADR。

## 先收住音频，再做视频

用户明确：后端只负责模型所需条件→计算→结果、取消、错误及释放；足以供上层组合复杂功能后就转模态。音频已有生成/参考变体/区间重绘、结构化音符条件、文件结果和统一生命周期，无必须新增接口。音频本批只补可复现的双引擎离线封装。歌声、HUM、TTS、深度编辑仍保留目标，**不再作为启动视频的前置**。

视频优先价值是“给一句描述或一张创作图，得到短视频候选”，不是先做时间线、分镜系统或剪辑器。模型通常返回按时间排列的像素帧；部分新模型还返回音频采样。MP4/MOV是随后编码封装的交付文件，不能把“数组生成成功”说成“视频已可播放”。

## 两条候选路线，暂不绑定后端

|方向|核实的能力|资源与适用边界|决定|
|---|---|---|---|
|Wan2.1 T2V-1.3B → Wan2.2 TI2V-5B|1.3B只做文本→静音视频；5B dense同权重支持文本/首图→静音视频。不要把14B的图像、VACE或音频驱动能力写给1.3B。|1.3B官方常见832×480/81帧/16fps；5B的“720P”示例实际1280×704/121帧/24fps。官方8.19GB和≥24GB为各自CUDA显存/卸载设置，不能换算Mac统一内存。|优先技术验证方向：先锁文本编码精度/内存，再短T2V；通过后加5B的首图条件。模型Apache-2.0，仍记录每份实际权重及组件许可。|
|LTX-2.3音视频联合|22B；区别于原LTX-2的19B，也区别于旧LTX-Video2B。可研究图像/音频条件、音视频同步和retake。|已有Swift MLX实现者96GB M3 Max测量，但GPU峰值不等于全机内存；不是D验证。较大模型、编码器和许可均须单独核验。|较大Mac扩展候选，不作为M4/16GiB首验门槛。|

依据：[Wan2.1官方及运行配置](https://github.com/Wan-Video/Wan2.1)、[1.3B模型卡](https://huggingface.co/Wan-AI/Wan2.1-T2V-1.3B)、[Wan2.2官方](https://github.com/Wan-Video/Wan2.2)、[5B配置](https://github.com/Wan-Video/Wan2.2/blob/main/wan/configs/wan_ti2v_5B.py)、[LTX-2模型卡](https://huggingface.co/Lightricks/LTX-2)、[LTX-2.3模型卡](https://huggingface.co/Lightricks/LTX-2.3)。所有“建议配置”需下载前固定revision；不照抄仓库未来变化的main。

**一个实际实现陷阱：**核对 `mlx-video` 的87db56a51758fefb748a359b90a5283bb8ba4837，`load_t5_encoder`把T5权重上转FP32。按该实现UMT5-XXL约5.68B参数估算，仅这一阶段权重约22.7GB/21.2GiB，未含激活；主Transformer的1.3B或Q4下载体积不能代表全管线。其转换的Transformer量化不自动量化T5。因此当前实现不能直接标成16GiB即插即用。先选定并验证文本编码器的适当精度/量化与分阶段释放方案；若沿用原实现，则大内存首验，本机只记录有界尝试及失败，不伪造通过。[加载源码](https://github.com/Blaizzy/mlx-video/blob/87db56a51758fefb748a359b90a5283bb8ba4837/mlx_video/models/wan_2/utils.py#L59)、[转换源码](https://github.com/Blaizzy/mlx-video/blob/87db56a51758fefb748a359b90a5283bb8ba4837/mlx_video/models/wan_2/convert.py)。新视频精度要显式评估，不改变现有文本4-bit、图像q8或音频配置。

LTX-2.3 Swift实现者在96GB M3 Max的1024×576/241帧/I2V+音频条件下记录BF16、qint8、int4 GPU峰值54.8/44.6/38.4GB，耗时1145/1458/1294秒。只能说明存在具体Mac路径，不证明其他机型速度、内存或量化画质。[固定版本测量](https://github.com/VincentGourbin/ltx-video-swift-mlx/blob/0b7e48567fdc686478cb16463496c24f2eda5d1f/docs/benchmarks/README.md)。

旧LTX-Video2B作为备选保留：官方有MPS路径及图像/视频条件，但0.9.6与0.9.8多阶段配置不同、后者不是新LTX-2；0.9.6起权重另受LTXV Open Weights License，不沿用源码Apache许可，也无D本机峰值证据。[旧实现](https://github.com/Lightricks/LTX-Video)、[0.9.8配置](https://github.com/Lightricks/LTX-Video/blob/main/configs/ltxv-2b-0.9.8-distilled.yaml)、[权重许可](https://huggingface.co/Lightricks/LTX-Video/blob/main/LTX-Video-Open-Weights-License-0.X.txt)。暂不为多个模型同时建设适配器。

LTX-2系列许可有收入门槛及直接竞争产品的另行商业许可条款；D的具体使用/分发是否落入该条款未知，需选型前向权利方确认，不能因Swift封装MIT就认定模型可无条件嵌入。这是候选取舍问题，本轮未代用户接受条款。[官方许可](https://huggingface.co/Lightricks/LTX-2/blob/main/LICENSE)。

## 最小后端契约（提案，不生成空代码）

|层|必要职责|明确不放入该层|
|---|---|---|
|DInference|VideoRequest：明确operation、模型身份/revision/profile、提示词、seed、宽高、帧数、有理数fps；I2V仅在支持时带已授权首图资源引用及摘要。进度/错误/结果仍为值型。|MLXArray、AV对象、窗口、书签、任意未校验JSON参数袋。|
|DRuntime|复用单重任务许可，排队、请求取消、drain及release后交接；图文音视频统一排队。|模型内部采样算法、剪辑流程、为视频再建独立调度器。|
|视频backend内部|载入/文本或图像编码/去噪/VAE解码/有界帧交付/编码封装/独立校验；发布后只返回文件引用和实际运行记录。MLX Swift或独立Python进程按真实可行性选择，取消与资源归属不可省略。|整套工作流引擎、无限帧队列、模型下载、用户项目存储。|
|Workbench|条件草稿、资产授权、预设、候选/采用、来源与保存、导出。以后用多个请求组合编辑、分镜或音频条件。|绕过runtime直接调用模型；从变化后的UI重读已提交参数。|

结果至少含：文件引用/摘要、实际宽高/帧数/有理数帧率/时间基、codec/像素格式/色彩原色-传递函数-矩阵-范围/方向、模型实现与计算精度、可选音轨（采样率/通道/样本数/开始时刻/时长）。未获知标unknown。首次静音结果明确无音轨，不能因项目有音频就自动混入。未来帧位置条件、视频区间/蒙版、音频条件按具体能力增加类型，不现在预建通用编辑API。

边界必须先固定：

- 帧数和fps是权威时间定义，展示秒数派生；区分N/fps播放时长与(N−1)/fps首末帧间距。29.97类分数帧率不截成整数。模型4n+1/8n+1及尺寸对齐来自profile，不能默默改720→704或延长视频。用户明确选择调整后才执行。
- 图像ICC/EXIF、缩放/裁剪、RGB→YUV与范围明确，原图不变。不能用肉眼“看起来正常”代替方向/色彩数值检查。不同损失编码不要求文件或像素逐位同一；源帧摘要与最终容器摘要分开。
- 音视频各有时间基；禁止以截到较短轨道默认掩盖尾音或帧丢失。Swift候选当前exporter存在整数fps/按较短时长混流行为，接入前须明确修正或拒绝不支持值。[实现](https://github.com/VincentGourbin/ltx-video-swift-mlx/blob/0b7e48567fdc686478cb16463496c24f2eda5d1f/Sources/LTXVideo/Utils/VideoExporter.swift)。
- 首选系统AVFoundation/VideoToolbox媒体写出候选，不因示例使用ffmpeg就新增安装依赖。AVAssetWriter写一个容器，CMTime支持有理数时间；具体编码支持与颜色处理需本机独立验证。[Apple写出接口](https://developer.apple.com/documentation/avfoundation/avassetwriter)、[CMTime](https://developer.apple.com/documentation/coremedia/cmtime)。
- 计算资源释放不删除已交付视频；编码失败/取消只清理本任务未发布文件。先可解码回读，再独占发布；writer、子进程、管道和GPU都结束后才能下一重任务。

## 下一有限工作包 V0（待启动，不在本批自动实施）

1. 固定一种候选及完整编码器/精度/来源清单，CPU验证帧时基、文件交付、错误/取消、profile参数反例；再申请明确资源与新增依赖/权重授权。不要首先搭通用视频框架。
2. 优先Wan1.3B的短T2V管线；17帧/16fps可作为初测提案（原生832×480），只证明工程闭环，画质/支持范围需实际对照；不能为内存强制拒绝而冒充负例验收，也不能无限交换/无超时等待。1.3B不支持I2V，界面/契约不得假装支持。
3. 实际加载、生成、可播放输出、阶段取消、下一任务、失败不覆盖、重复释放与详细内存通过后，即达到首个视频后端出口；之后考虑5B I2V与独立轻工作台。无需等歌声、HUM、全部图像编辑或视频剪辑完成。
4. M4/16GiB和更大Mac使用独立profile：模型/量化、分辨率、帧数、步数、编码器/offload策略均为明确参数。只记录实测机型；模型文件/MLX活跃与峰值/进程RSS/系统内存压力及交换/耗时分别计量，估算不当硬限制、CUDA数字不当Mac承诺。

待验证项：16GiB可行文本编码方案及数值差异、固定Mac实现兼容/许可、完整运行峰值、帧级取消粒度、色彩/编码对照、实际时长与音画同步。研究结论不保证视频艺术质量，不承诺时间一致性、任意长视频、精确局部编辑或分轨。首片之后再按模型真实控制能力决定产品功能。
