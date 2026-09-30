# 首发模型能力矩阵

2026-10-01 · D-RELEASE-FREEZE-01 · **候选，尚未功能冻结**。最终代码与证据版本见[本轮记录](tasks/D-RELEASE-FREEZE-01.md)；当前停点仅以[当前行动](CURRENT_ACTIONS.zh-CN.md)为准。

模型能力、D已实现的profile、资源是否就绪、本机实测、Quick/Canvas原生验收分开。下表不是九模型均已交付的声明。16GiB开发机不限制其他Mac的合法请求；预算不足明确报告，不自动换模型、降精度或丢条件。

## 九个冻结目标

| 模型／精确实现范围 | 输入 → 输出与关键控制 | 实现及资源 | 本轮验证／缺口 |
|---|---|---|---|
| **Qwen3.5-9B**；原始BF16及独立MLX Q4 profile | 原生角色消息、按序文字/多图/时间戳视频、工具声明/调用/结果、型号特有思考控制 → raw/reasoning/final/toolCalls；输出上限、seed、采样与上下文预算。非法组合拒绝，不自动执行工具 | MLX LM 3.31.4；BF16与Q4固定独立revision。Q4已取得 | r2 Q4正式runtime四请求通过：最终JSON、双图明暗顺序、视频描述、工具结果往返42；精确代码2f2855b，1个测试。BF16未跑；41ad630普通App的Quick/Canvas均真实生成title/answer记录并保存冷重开，原生参数为Q4、思考off、seed42、输出256、显式预算15GiB；不是27B或其他精度的证明 |
| **Qwen3.8-27B**；原始BF16及独立MLX Q4 profile | 同一VLM消息形状；3.8独立 reasoning_effort/preserve_thinking 映射，拒绝不适用的9B开关；不冒充9B实测 | 已登记与装配，Qwen3.5架构读取3.8实际配置；尚无本机完整权重 | 契约／配置检查及编译；真实推理未验，不能用9B结果替代 |
| **FLUX.2-klein-4B**；原始BF16、既有Q8分开 | 文字＋可选有序参考图 → PNG；尺寸、步数、seed，参考图有共同校验 | 原始Klein 4B为蒸馏模型；新增BF16固定清单，Q8旧路径保留。BF16资源未取得 | r2源级A/B确认Float32 Steel attention缩放顺序差异；经非实现者复核保留上游实现并绑定新版本唯一严格PNG。生产3周期通过、active/cache归零；旧失败保留。BF16、多参考新路径真实验收未完 |
| **FLUX.2-dev**；原始BF16 profile | 文字＋可选有序参考图 → PNG；独立guidance、步数、尺寸和seed，不沿用Klein的固定512 token规则 | 分阶段Pixtral编码／扩散／解码，固定32文件清单；约112.82GB资源尚未取得，平台返回401 | 契约／库存／参考映射检查，未做真实模型；H31仅阻塞这份资源，不重新询问开发下载授权 |
| **Wan2.1-T2V-1.3B**；既有视频BF16编码/扩散、FP32解码profile | 文字＋负面提示 → 无声MP4；尺寸、帧数、帧率、步数、guidance、shift、seed | 复用既有MLX视频后端和运行环境；不显示I2V端口，不接纳未经支持的首帧 | 历史真实链路保留；本轮共享契约/媒体回归不等于新Quick/Canvas真实smoke |
| **LTX-2.5**；单阶段dev完整权重profile | 文字＋可选首帧 → 带音频MP4；独立视频参数与显式扩散权重流式开关；不支持末帧，输入即拒绝 | 固定ltx-2-mlx 0.15.12，扩散核心BF16，其余精度按文件头记录；当前实验性diffusion视频解码器，2.5 audio FF及Gemma4资源校验；不以LTX2.3 Q8替代 | 映射／进程／FFmpeg媒体夹具通过；2.5资源401，**尚无真实2.5生成，冻结门槛未达** |
| **MiniMax H3 Base · FL2VA / 原始BF16** | 文字＋可选首帧／尾帧（分别冻结）→ 带音频MP4；显式流式加载、合法尺寸/帧数、步数、seed | 原始50层公开Base；公开Base本身为CFG蒸馏，不冒称未公开非蒸馏版；不是Ref2VA多参考路线。约144GB资源已校验 | 历史真实生成/取消恢复；本轮修复真实MP4的Store时长误判，保留原件。新增首尾帧真实结果见本轮记录，GUI仍待验 |
| **MRT2 small/export-v1** | 意图、可选音符与和弦结构 → 48kHz双声道WAV；seed、1…400个25Hz条件帧 | 真实音符条件编码，非把和声拼进prompt；导出profile最长16秒，固定采样配方，鼓当前不受约束 | 既有真实有条件/无条件生成保留；是近似音高/起音控制，不承诺精确音符、声部或音色；非完整MRT2所有导出/流式能力 |
| **ACE-Step 1.5 XL SFT · F32 / no-LM** | 描述＋歌词/语言、BPM/调式/拍数、独立风格参考音频；cover原声或repaint区间 → 48kHz双声道F32 WAV | 原始XL权重实际F32；MLX扩散/VAE与MPS条件处理。固定官方源码，无模型侧动态代码/自动下载；不接LM，不冒充turbo/base | 原始资源已校验；独立引擎导入、CPU参数/输入保护、长音频保存重开已验。r2公开本地加载入口加固定最小补丁，校验起止各一次，MLX转换后释放不用的Torch decoder；真实6秒/50步F32尝试在2步后由Lead受控停止：231秒、swap约17GiB，非OOM/非成功。另6秒/1步F32实推理261.12秒完成，48kHz立体声有限PCM已检查；只是冒烟，未作人试听或合理采样质量验收。转换峰值和必要组件仍可能占大量内存，不伪造流式已实现 |

ACE当前原声与参考输入为48kHz双声道PCM WAV；F32须有限且在[-1,1]，不隐藏重采样或截幅。生成使用0.1秒网格，编辑按原声精确帧时钟；请求时长0.1–600秒。原生解码尾长/短缺分别记录，输出不偷偷裁切到“看似相同”。这些是该profile的明确边界，不是所有音频模型的通用限制。

## 单一执行真相与来源

Quick与Canvas实例化同一个 `WorkflowRegistry` 操作，使用同一端口、字段和请求构造。说明卡片是投影；自然语言detail/default展示串不被解析执行。旧 `d.text.generate`、旧Qwen2.5、LTX2.3和SA3继续兼容，不能把旧成功计为新冻结目标通过；既有标签键不因模型实名改变。

| 家族 | 当前执行来源／固定版本入口 |
|---|---|
| Qwen | `TextModelProfiles`、`WorkflowLanguageRecipe`、`MLXQwenVLMBackend`；9B原始c202236235762e1c871ad0ccb60c8ee5ba337b9a、Q4 8b2b98c00a6b4d291155e4890773ca8f769aee53；27B原始1d4bf0f2ff6012fd82039f2fa52739d0dd7c60c0、Q4 10c35caafbb80f7dc6a7a432cdd11af10a6d4818 |
| 图像 | `WorkflowImageRecipe`、`LocalImageModelInventory`／`LocalFluxDevInventory`、各自后端；Klein BF16 e7b7dc27f91deacad38e78976d1f2b499d76a294，Q8 ef52ee019fd1d0e75ae4deb40476ba65989716d7；Dev 26afe3a78bb242c0a8bb181dcc8937bb16e5c66c |
| 外部视频 | `WorkflowVideoRecipe`、`ExternalVideoExecutionProfile`、`ExternalVideoBackend`；`Backends/Video/Adapters/Resources`中的固定清单。H3 42ed227ee7df40d41602854ae760620d6eb651fe；LTX2.5 e378b7e1b50fcb1795fce74219b40bb0b1ede1e2；实现源码与补丁随准备引擎记录 |
| Wan／MRT2 | 既有`VideoRequest`／`AudioNoteSequence`、对应后端与导出运行环境；模型清单在正常开发资源集，旧真实证据见当前行动历史索引 |
| ACE | `WorkflowACEOperation`、`ACERequest`、`ExternalACEBackend`和薄Python适配；XL d06de46b4622f781cf07f4a013a67d591ca52819，共享编码器/VAE 19671f406d603126926c1b7e2adc169acbcade22，官方源码ca1e85fe9430179831e6bc6be790c332190a3866 |

所有路径仍经过既有安装使用权、DRuntime队列/取消、输入快照及Store发布；普通处理节点不伪装成模型。输出的实际profile、revision、条件摘要和执行参数进入运行记录。新增模型权重不进入App或Git；既有Pitch引擎评估权重、依赖封装和渠道发行责任不被本表解除。

## r2 能力承接与准备边界

- `release-model-catalog.json` 通过现有 Models/Resources 载入：九家族、12个固定精度条目、228文件；SHA-256 与 Git blob SHA-1 按来源区分，多仓库依赖使用各自 revision/path。ModelLibrary 沿既有续传、原件校验、目录授权、安装使用权。旧 Klein 索引兼容，不把下载完成等同执行就绪。
- Quick/Canvas共用 `WorkflowLanguageMessageForm`、同一操作/校验及安装身份绑定。选择异步返回带代次保护，重新登记目录取代同身份旧安装；缺失/取消不自动选另一个模型。
- VLM消息保留原生role、媒体顺序、工具调用和结果关联；Qwen9B的enable_thinking、27B的reasoning_effort/preserve_thinking按固定上游分别映射。**JSON提示+最终结果解析验证不是原生约束解码**。raw响应以独立类型化资产保存，不塞进4MiB metadata；64MiB资产解析预算及工具JSON/工作流datum预算仍是明确应用保护限制，超预算失败不静默截断，不宣称无限输出。跨项目复制保留资产字节。
- 文本/图像/MRT2/ACE固定原始目录可经模型库校验导入。视频原始目录下载标为`preparationRequired`，不能领取运行租约；已有准备包仍可从Quick/Canvas显式目录入口登记。H3/LTX2.5无需数值转换的固定配方已增加“准备独立执行包”入口：保留原件、独占暂存、校验后原子发布、取消与关闭等待、登记前核项目归属，不自动切换草稿。5个CPU准备反例及取消登记接线通过；真实H3普通沙盒App的144GB原件校验→独立准备→登记已通过，准备不触发生成/切换草稿；LTX2.5仅CPU配方路径，资源仍缺。**Wan原始下载到分片转换包的产品接线未完成**，仍须明确的子进程目录授权、固定转换依赖、完成清单与取消发布验证；不借宿主Python绕过，也不靠profile改名关闭F03。
- Dev有序参考图已在真实端口与能力投影一致；文案不作为执行schema。LTX2.5/Dev缺资源仅阻塞各自真实模型验收，不伪装为已支持完整上游功能。
- 选定checkpoint的上游能力与当前实现差距仍是工程责任：更复杂原生模式、未取得资源和未验证精度不能仅靠profile改名关闭。no-LM指未接另一语言规划权重；已有ACE歌词/风格参考/cover/repaint仍须真实条件验证。没有新增训练或云端工具。

## 冻结出口与故意不做

必须补齐：每个正式模型的Quick/Canvas真实smoke及其公开承诺的强输入；Klein数值归因/处理已完成并保留版本约束；获取受阻资源；完成必要大内存实测与新普通App原生操作；共享取消、保存重开、导出按机制复用验证。未完成不得写“首发冻结通过”。

本轮不增加新模型家族、插件市场、通用注册平台、工作流DSL、专业剪辑/DAW、Ref2VA或Wan I2V，也不迁移/删除旧候选。LTX2.5资源缺失不将其悄悄从冻结名单删除。开发资源和源码许可记录保留，但不把内部适配测试写成模型商业分发已获许可。
