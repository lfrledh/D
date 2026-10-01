# D-RELEASE-FREEZE-01：首发模型有限收口

2026-10-01 · r2 已交付部分可试用候选；实现与功能冻结仍未闭合。最新回执见文末；r1及r2过程快照保留原义。

## r2 有界续作规格与恢复点

用户《Closeout v0.1》明确继续 F01—F09。起点候选/远端均为 `49ad3dc7c1bc63aab3e6afd9491cf3bc6e5eea3d`；源仍 `01758b81527dc27eb4563bf1b66fd1ceab6647ee`。源仅既有 scheme 未暂存差异，摘要与索引见新证据 R2=`D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20260930T142825Z-closeout/lead/protection-before.json`。旧 UI、视频候选不变，无新增未知差异。未获准合入受保护源或 main。

本增量先补已确认的消息/工具/思考承接、九模型准备和共享接线，再处理 ACE 同 job 重复验证/离线加载及转换后副本，最后进行 Klein 有界数值对照、普通 App 和有限 QA。冻结名单、精度、原件保护、取消释放及旧失败保留；单纯缩小 profile 不算能力完成。仅涉及既定公开 checkpoint，不扩展训练、远程或新模型。缺资源/锁屏只阻塞对应实测。

Lead 单一维护共享请求、App/ProjectSession 接线与本记录。新增两个明确切片由受限 CLI `gpt-6-sol/high` 实现：LIBRARY（复用 FORMS 已空闲工作树）：现有模型库、运输/校验、目录清单和模型库 UI；ACE-CLOSEOUT（复用 ACE 工作树）：Python provider/offline runtime、包装及直接测试。各自精确允许路径、执行基线、输出/缓存和验收在 R2 对应 `job.json`/`spec.md`；预检核验后方可实施。不改其他任务文件，不访问网络/模型/GPU/真实偏好，不提交 Git 元数据。初交预算分别 45/30 分钟；新明确切片初交+最多两次定向修复，不重置 r1 已消耗预算。模型隐藏服务端解析仍 unknown。

代表验收：混合摘要/多仓库/续传身份/访问错误/未就绪/租约；VLM 角色与媒体次序、型号特有思考参数、类型化工具往返及最终 JSON；ACE 同进程验证次数与原件突变/取消优先级、真实离线 loader 和 decoder 释放边界；Dev 参考输入投影；同包编译、真实模型与 GUI 独立。不机械重复全部旧 GPU。重要 Lead 实现须非实现者只读审阅。权重和大证据不入 Git，只有通过对应实测才更新矩阵。

接口调查后，Lead 明确第三个独立 VLM-CLOSEOUT 切片：按 R2/spec 的冻结型接口扩展 TextRequest/InferenceResult、Qwen 消息/输出映射与直接测试；既有工作流/Quick/App/Store 接线仍由 Lead 维护。请求消息与旧 prompt 不可歧义并存；媒体直接值引用且保持次序；可选 textResponse 保存 raw/reasoning/final/toolCalls，旧 `.textDelta` 只含最终正文，不建立自动工具执行器。gpt-6-sol/high 初交45分钟，受限链路与新切片修复预算同上，重要契约由Lead审核并交非实现者复核。

最终代码/受测/文档 SHA 记录外部回执，不自引用 amend。写 Worker 仅在各自预检通过后进入实施；源、普通 App、历史证据保持。

### r2 F04 数值基线决定（实现中，尚待生产版本复验）

R2/lead/klein-ab* 保留一次源代码级 A/B：独立 IMAGE 工作树只恢复 d20ead4 引入前 Steel attention 的缩放顺序，并记录实际 kernel 路径；相同模型/输入/seed/精度/SDK下原严格三周期测试通过，81.845秒。实际381次均为 **Float32 Steel/headDim128**，并非推测的 BF16 舍入，也未走 NAX。A/B三张PNG恢复旧哈希 `05f0b80ac7d9d6e4ffa105af12a8805cdea4425a9448f9d35a1bd9d8f8dda553`；原新引擎三张均为 `f7cebb5068312c1128dbd671a20d172be4a36d34d1c70aa55d62d0d3c89eb548`。差异为1845/262144像素、最大通道1/255，旧失败不删除。

Lead 决定保留上游新缩放实现，不把实验性全局回退合入生产。非实现者 video_extension_map 独立审阅同意为当前固定引擎建立唯一新精确基准；生产测试改为新哈希，仍严格逐字节，不能两个哈希任选或放宽误差。绑定 MLX Swift 0.31.4/core ce45、Flux2 959a4af、Q8 revision ef52ee0、原测试提示/seed/512²/4步、M4、macOS26.6.2/Xcode27.0。本决定没有高精度oracle，不能据此宣布新数学更准确或其他硬件逐像素相同；未知配置的差异仍须独立核实。生产测试尚未在此段撰写时重新执行，结果在后续回执追加。

## 基线与边界
源 codex/inference-foundation@01758b81527dc27eb4563bf1b66fd1ceab6647ee；实现从视频候选 d7dba252eea52d0f4a9a26915f4df3c3f7d244d0 创建外盘 D-RELEASE-FREEZE-01 / codex/release-freeze-01。原视频/前端候选保持。保护源个人 scheme 未暂存状态、作品、模型和普通 App。证据 R=`D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20260930T070201Z`。

用户三份 v0.1 任务书授权 A→B→C 同一有限里程碑：能力契约/UI、冻结模型适配及强条件、清理与最小QA；不进入新模态、main、公开发布或权重分发。现有受限Worker、修复预算、保存/许可/取消和隔离规则继续。旧AVMEDIA失败历史不改写；本轮明确重新批准针对H3 Store错误时长假设的一次有限修补与复验，不重置其他旧任务预算。

## 冻结目标
文字/VLM：Qwen3.5-9B、Qwen3.8-27B；图像：FLUX.2-klein-4B、FLUX.2-dev；视频：Wan2.1-T2V-1.3B、LTX-2.5、MiniMax H3 Base；音乐：MRT2 small/export-v1、ACE-Step 1.5 XL SFT。Qwen2.5、LTX2.3、Stable Audio3保留兼容，不能冒充新增目标已验。精确revision、后端、量化、蒸馏、profile与当前实测分别记录。

模型主标题必须实名；只实现子能力时明确FL2VA等范围。Quick/Canvas共用有类型的能力/参数/必选/可选/互斥契约，不解析说明字符串执行。复用runtime、Store、模型安装和租约；不新增平行系统/Any参数袋。支持真实图像参考列表、帧条件、音乐结构条件；不截断/降级/忽略输入。16GiB仅本机验证环境，不是产品上限。

## 执行与验收
A先形成实际调用的共用契约，再接UI展示；B按固定家族实施独立适配/映射，资源与真实运行单列；C只做本次变更相关QA与整理。正常预算初交+2定向修复，必要时一次有界Lead接管；重要Lead实现非实现者审核。GPU/构建/GUI串行；本人阻塞进集中清单。

最小QA：一族一组表驱动契约、每家族1–2代表映射、每冻结模型必要Quick/Canvas真实路径及承诺强输入、共享保存重开/取消重试/导出保护。不累加历史测试当本轮全通过。未实测路径不默认替换已验路径，记录无法执行的准确原因。

当前首个局部修复：VideoMediaInspector及其直接测试；保留mvhd最长轨道严格核对、完整解码、文件身份、原Wan无声边界，只纠正AVAsset.duration必等于最长音轨的错误假设。使用已有H3/LTX真实产物只读验证，不改原MP4、不重新推理掩盖保存缺陷。

## 准备时状态（历史快照）
准备完成；3个非写入调查并行。写入任务须另给精确允许文件/基线/输出/缓存/模型设置并预检；本文件由Lead维护。源未修改。后续受测与最终提交写R/lead回执，避免自引用提交。能力矩阵、试用与结果保持少量入口，不复制任务历史。

## 实施中恢复点（2026-09-30，非验收回执）

源仍01758b8及个人scheme未动；本轮候选已合入旧前端/视频历史，具体当前HEAD以Git和R/lead为准。已完成H3媒体duration有限修补；旧H3/LTX产物完整解码、Store与导出分别留证，不当新模型生成。共享有类型模型路由、VLM图像/视频端口、FLUX有序参考图、视频首尾帧、Quick列表与错误呈现已写入；Quick候选数量修复与组件检查通过，原生尚未验证。

已固定升级MLX Swift0.31.4及MLX LM3.31.4，保留来源/许可/最小补丁；后者加入显式预采样帧保真，旧默认不变。首次组合构建发现两参数构造器兼容错误，Lead已修，不把失败删除。Qwen3.8 output_gate_type字段与官方实际注意力算法分别核实，未擅改数学。新SDK必须继续旧文字/图像真实回归。

受限CLI写Worker均gpt-6-sol/high，目录独立，网络关闭；每轮实际context与允许写根记录R/<任务>/*-route-accepted.json。IMAGE初交+2修复已用完；FORMS初交+1修复；VIDEO LTX初交+1修复；VLM第二修复执行中；ACE第一修复执行中。IMAGE第一修复遇shell临时文件拒绝后未停报，保留协议偏差；ACE初交缓存拒绝后停报，Lead明确授权既有任务缓存后恢复。没有观察到成功越界，隐藏服务端模型解析unknown。重要Lead接线/厂商补丁均有只读非实现者检查，发现原图二次读取缺口和Quick计数问题后分别修补。

固定Qwen9B Q4及ACE XL/共享编码器资源已下载校验；ACE XL实际原始权重F32、约20GB，尚未加载。FLUX Dev和LTX2.5固定资源访问401，只限制对应真实推理，列本人入口H31；不再问开发下载批准。FLUX Klein原始BF16正在加入既有库存校验，不改变精度。所有新路径当前仍为候选，不宣称九模型冻结或普通App验收完成。

持久证据R/lead/*-result.json、Worker过程/模型路由、upstream固定源码；源/旧候选未合入、未推送。GUI上次确认为锁屏，H32与旧H22保留。恢复后先核当前Git、活动进程和真实权限，不按此段猜测任务已结束。

## 本轮交付与冻结候选（2026-09-30）

实现/受测代码 **37bd091044a2dd438a2e37f4453c32af9c91fe18**。本段之后的结案仅文档，最终SHA在R/lead/final-receipt.json，不自引用提交。当前代码包含视频/前端两侧历史及本轮独立Worker候选；源仍01758b81527dc27eb4563bf1b66fd1ceab6647ee，未将未过冻结门槛的组合快进源。源个人scheme的内容、SHA256、索引blob和未暂存状态均需同保护记录一致；新模型权重未入Git/App。

### A/B/C结果

| 阶段 | 实际完成 | 尚未完成／状态 |
|---|---|---|
| A 能力与UI | Quick/Canvas共用WorkflowRegistry与有类型配方；实名模型/profile展示；有序多图、视频帧、首尾帧与音乐音频条件保留实际资产和参数；旧模型/标签键兼容 | 新普通App实际鼠标与逐模型Quick/Canvassmoke未验（锁屏H32）；旧H22等不关闭 |
| B 适配补齐 | Qwen3.5/3.8固定BF16/Q4分别登记；Klein BF16与Dev独立库存/后端；LTX2.5单阶段配方和校验；H3首尾帧；ACE XL原始F32/no-LM薄适配与正常开发引擎包装；沿用安装租约/运行时/Store | Dev与LTX2.5资源401；27B、Klein BF16、ACE真实未验；不能写九个整模型均已支持 |
| C 最小QA与整理 | 每家族代表契约/映射、相关共享机制、真实Qwen9B与H3、正常App构建及资源签名检查；矩阵与短指南各一份 | Klein严格旧PNG基准失败，保留原标准；完整冻结和发行均未通过，不清理未知候选/历史 |

精确输入输出、量化/蒸馏、profile、revision、未支持条件见[单一能力矩阵](../RELEASE_MODEL_MATRIX.zh-CN.md)。试用入口和同树Xcode Run见[精简指南](../RELEASE_FREEZE_TRY.zh-CN.md)。没有增加插件市场、通用注册框架、新模态研究或新的并行资产/调度系统。

### 验证摘要（分组，不相加成全模型通过率）

环境M4/16GiB、macOS26.6.2、Xcode27.0/27A266a、Swift6.4。各命令、路径、退出状态、时间和版本在R/lead相应`*-result.json`及日志；大产物不入Git。

| 检查 | 结果／证据 |
|---|---|
| 最终后端/共享进程与微型数值参考 | `candidate-backends`：82 tests / 9 suites通过；其中4个显式opt-in真实图像方法跳过，不能当真实模型通过。含ACE、VLM、图像库存、视频、既有音频进程桥接与5组固定FP32参考参数例 |
| 最终基础契约 | `candidate-root`：16 tests / 3 suites通过 |
| 最终工作台/Quick/模型登记/媒体保存 | `candidate-workbench`：53 tests / 7 suites通过，含Quick共享字段、有序输入、ACE长音频及保存恢复；不等于GUI |
| 新H3产物完整解码/Store | `candidate-h3-store`：14 tests / 1 suite通过；实际本轮首尾帧MP4只读进入发布/重开/导出，原件保护；其余为同一组反例 |
| 资源准备 | `candidate-resources`：20 Python测试通过；六引擎正常资源集与ACE逐文件库存；正常`D Nodes`构建、签名结果见`candidate-app-build-result.json`与delivery/preview-build.json |
| Python适配 | `ace-python-final`15项通过；视频`test_ltx_job`5、`test_ltx_admission`11、`test_app_video_driver`22分别通过，FFmpeg夹具使用实际可执行工具。不是实模型 |
| 真实Qwen3.5-9B Q4 | `candidate-qwen9b-real`固定代码复验：正式Runtime文字、两张按序图片、带时间戳视频三请求，检查原件/输出/释放；32 token短输出不作专业质量结论 |
| 真实H3 Base FL2VA BF16 | `candidate-h3-frames-real`固定代码复验：原始50层、显式流式、首尾帧编码、256²/22帧/2步/24fps，正式Runtime返回视频及条件摘要；2步样本不证明质量上限 |
| 旧真实回归 | `legacy-real-02`旧文字通过；Klein三周期都与旧B1黄金PNG不同，测试退出65，全部严格断言保留。释放active/cache为0；不是全回归通过 |
| 普通GUI/真人 | 新包未启动；锁屏H32，旧H22等继续。签名完整性不是TCC、GUI、公证或发布证据 |

本轮真实样本使用唯一run目录，参数/seed/profile/版本/输入摘要与结果保留在R/tmp对应qwen-real与h3-frames目录。Qwen、H3是正式runtime实推理；ACE夹具/长音频是CPU合成数据，未冒充歌声生成/试听。LTX2.3历史成功不能替代2.5，旧Wan/MRT2证据不倒记为本轮新GUI。

### 保留的失败与归因

- Klein旧B1 PNG期望`05f0b80ac7d9d6e4ffa105af12a8805cdea4425a9448f9d35a1bd9d8f8dda553`，本轮三次一致为`f7cebb5068312c1128dbd671a20d172be4a36d34d1c70aa55d62d0d3c89eb548`。262144像素中1845个变化，最大通道差1/255；`image-pixel-comparison.json`及保留PNG可检查。上游MLX注意力缩放顺序有变化，是候选原因，未完成独立A/B归因；不替换黄金、不放宽容差，不声称只是无关编码差异。
- 首次真实测试筛选漏掉方法括号，执行0项；`legacy-real-selection-note.json`明确作废，改正确入口后保留真实失败。第一次ACE Swift夹具用Foundation的`/var`别名，被保护校验正确拒绝；改为本轮授权临时路径并解析物理路径，未放宽生产路径规则。
- ACE最后Worker修复后，Lead发现Python`inputMutation`终止事件被Swift拒绝/非零退出及取消覆盖。一次有界Lead接管扩展已有进程桥接的可选已drain错误投影，不另造进程系统；仅确认完整性错误优先于取消，普通超时/取消和协议错误顺序保留。真实子进程修改私有副本、取消后报告、普通初始化原因三反例先失败后通过；另补输入损坏与停止检查失败并存反例。原件未变，清理未确认分支仍没有实际注入测试，不夸称全生命周期已证明。
- VLM两轮修复后一次Lead有限接管，把私有文件清理失败放入execute可报告边界，release仍释放GPU/许可；未知文件保留。未证明任意文件系统故障下的恢复，不自动删除残留。
- Dev/LTX2.5访问401与GUI锁屏分别入H31/H32，不重新索取开发下载批准；没有因此降精度、换模型或全局拒绝大内存机型。

### 来源与预算

受限CLI写任务IMAGE、FORMS、VIDEO、VLM、ACE均请求`gpt-6-sol/high`，每次路由/实际context/目录/网络关闭/专属写根在R各任务的`*-route-accepted.json`，隐藏服务端解析unknown。IMAGE初交+2修复；FORMS初交+1；VIDEO初交+1；VLM初交+2后Lead一次接管；ACE初交+2后Lead一次接管。提交保留实现/修复历史，不把Lead修补算Worker独立通过。

共享契约/Store/App装配、厂商最小补丁与包装由Lead负责；非实现者只读检查发现并关闭原图二次读取、Quick计数、ACE错误传递等具体问题。最新ACE接管由`baseline02_services_readonly`复核，Store由`video_extension_map`复核，矩阵按其检查补LTX单阶段/实验解码及ACE时长限定；审阅不是另一次测试。IMAGE权限未停报偏差及Lead处置保留；ACE初始缓存事件、VLM受限shell环境恢复分别记录。未观察到成功越界；不能据日志宣称系统级隔离证明。

运行耗时以各process/result记录为准，usage累计快照不相加；完整Lead归因与订阅费用unknown，本轮不重算历史样本，不宣称模型路线成本最优。所有Worker已交回，不新增后续Worker或自动无限后台执行。

### 恢复检查点与下一有限动作

最终候选/远端、App四文件摘要、自有过程退出、源scheme保护在R/lead/final-receipt.json。恢复先核Git及活动状态；不要按本段短SHA猜版本。开发包正常构建、未实际启动；当前候选仅待后续验证，不合入源/主分支、不公开发布，不删除旧候选与证据。

下一步仅补冻结名单验收：H31资源取得后真实Dev/LTX2.5；可用大内存环境的原始profile；H32解锁后同包Quick/Canvas强输入及导航；独立解决Klein数值基准差异。完整图/发行/音乐专业编辑和新增模型家族故意推迟，不把这些后置功能变成本轮扩大范围的理由。


## r2 交付检查点（2026-10-01；部分可试用，冻结未通过）

### 固定版本和保护

续作起点 `49ad3dc7c1bc63aab3e6afd9491cf3bc6e5eea3d`；最终构建/CPU代码 `b315ffa0c2d8d191204b0b93f1afdaaaae46e865`。本节之后的提交仅上述现行文档，最终文档SHA和远端回执写 R2/lead/final-receipt.json，不为自引用amend。保护源 `codex/inference-foundation@01758b81527dc27eb4563bf1b66fd1ceab6647ee` 未合入；main未推进。代码位于原候选工作树/分支，未重写历史。

源scheme SHA256仍须逐项核对 `ca3635d88aa5a15397b90e528667c66c0e6db7e596176e885c79d194b544206c`，索引blob `9c76916bdc97c2d4298cefe64e0b0fae3380573e`，orderHint1→6仍未暂存；结束核对在 R2/lead/protection-after.json。原App四项文件和模型/作品原件保护分别见原生保护、各模型验证记录；不能把未读取的整个磁盘宣称已全面比对。内盘空仓库未操作。

### 审查问题与实际增量

| 问题 | 本轮处理与证据 | 状态／保留责任 |
|---|---|---|
| F01 原生能力承接 | `TextRequest`原生角色、按序媒体、工具声明/调用/结果、型号特有思考设置；后端返回raw/reasoning/final/toolCalls；旧delta仅最终正文。Quick/Canvas共用消息表单、同一操作校验、模型安装身份、显式资源预算。响应作为独立类型化资产保存，不挤入4MiB metadata；每轮工具ID不再重复。 | 已补所列请求缺口；9B实测、27B未验。工具调用数据不自动执行命令；JSON要求＋最终解析不是约束解码。64MiB响应/工具JSON/工作流datum保护上限明确拒绝，不静默截断。不能称全部上游模式已验。 |
| F02 真实证据不足 | 9B Q4正式runtime新增四请求：有意义最终JSON、双图明暗次序、视频描述、合法工具结果往返42；普通App双入口均得到title/answer结构且冷恢复。 | 部分关闭；BF16、27B及其他路线合理采样/强条件仍未验，不以9B、小样或旧模型替代。 |
| F03 模型准备 | 原ModelLibrary扩为九家族12配置228固定文件；多仓库/独立revision/混合摘要、真实状态、续传、访问失败、租约不另造系统。H3/LTX2.5固定无数值转换配方独立打包，APFS独立clone或独占复制、取消drain、原子发布/全量校验和跨项目保护；H3普通沙盒App144GB原件校验→准备→登记真实通过。 | 部分关闭。Wan原始下载到数值转换包的正常App接线未完成（纯工程缺口）；Dev/LTX资源受H31阻塞。原件完整与执行准备分开，raw仍preparationRequired。 |
| F04 Klein差异 | 上述最小源级A/B证明Float32 Steel attention缩放次序造成差异；保留上游实现，独立审阅后绑定唯一新严格黄金值，生产3周期通过、active/cache归零。 | 固定环境关闭；未放宽容差、未接受双hash、未合并实验回退；不外推其他精度/设备，不宣称数学更准确。 |
| F05 ACE重复hash | 同一初始化记录复用，初始/退出完整检查；中间使用身份保护，输入改变、取消和finally各项独立执行；跨进程重新校验。 | 重复边界已收敛；31CPU反例与实际初始化通过。不得跨文件变化/重新定位复用旧信任，不宣称消除全部I/O。 |
| F06 ACE生产mock | 四处固定上游加载点显式本地路径/local_files_only补丁，包装记录摘要与漂移拒绝；不再全局unittest.mock加载器。 | 主要维护风险缓解；少量既有私有适配仍准确登记，不伪称全公开API或重写loader。 |
| F07 投影一致性 | Dev有序参考使用实际值型契约；Quick/Canvas一致性反例；目录/模型标题修正，重新登记与冷重开投影实名，用户node.title注释和旧书签不改写。 | 已知投影缺陷关闭；最终视频标题回归先失败后通过，原生最终包复验被锁屏阻塞。 |
| F08 ACE资源 | MLX转换完成后释放不用的Torch decoder，必要条件编码组件保留；6秒50步实际进入采样2步后换页约17GiB/231秒，估算约94分钟，由Lead受控TERM后KILL；不是OOM。6秒1步原始F32真实生成261.12秒完成。 | 部分关闭；单步只是链路冒烟，无合理采样/主观质量/完整强条件结论。转换峰值仍含双份，不冒称全流式或已测最低内存；不量化/换模型降低要求。 |
| F09 文档真相 | CURRENT_ACTIONS只保留当前候选/停点/保护/下一动作；模型矩阵、试用、集中清单与本记录各司其职，历史失败不倒改。 | 活动文档已整理；不是产品架构全面解耦/功能冻结证明。 |

附带应用缺陷：`WorkflowArchiveInspection`按一次调用缓存不可变来源检查，避免历史增长导致重复读同一元数据；ProjectStore发布后fsync失败只对自身精确pending清单恢复，新增旧实例不能覆盖新版本反例；跨项目资产进入空图先复制、一次可撤销图操作、项目/epoch校验防迟到结果污染。已有CPU反例通过，不声称已经用大规模真实历史量化提速。两个hosting失败继续留证；原生的部分通过不能抵销测试失败。H22没有新增生产IME补丁，仍等待实际组字对照，不能以通知到达等同位置正确。

### 测试与真实产物（按层，不累计历史数字）

M4/16GiB、macOS26.6.2、Xcode27/27A266a、Swift6.4；重构建/GPU/GUI串行。完整参数、独立tmp、超时/子进程回收、退出状态见各 `*-command.json`/`*-result.json`，原日志/xcresult保留。下列为实际执行，未列能力不能据此写通过。

| 层／代码 | 实际结果 | R2/lead证据 |
|---|---|---|
| 最终相关UI/模型库CPU，b315ffa | 1项双语言键测试、28项模型库/准备测试、67项Workbench测试，各组通过；包含Quick/Canvas、消息/响应资产、安装身份、准备取消/源保护和视频真实标题。不是整个UI套件全绿 | ui-final-names.log/result.json，测试过滤器在command.json |
| 视频实名先失败后通过 | 未修前1方法2断言失败；修补后26项相关检查通过；最终b315ffa再纳入上行 | video-title-red、video-title-green；video-title-review.json |
| 后端CPU，9cdf8e51222852ba67bb410929ff0c613511a4a1 | 27项/3suite通过；此后改动为UI/安装准备/显示名，后端未变 | backend-final-cpu-02.log/result.json |
| ACE CPU，最终b315ffa | 31项通过；补测是为旧结果缺代码SHA字段建立精确版本关联，不再重复真实采样 | ace-final-cpu.log/result.json |
| 应用运行/Store等局部CPU | 原保存恢复/来源保护/空图与epoch反例45项通过；原生conversation验证4项通过。旧记录未全部携带SHA，不冒充最终版本全测试 | ui-local-reviewed、root-conversation；命令路径固定本候选 |
| 保留失败 | 两个hosting方法：语言切换按钮动作未被plain hosting找到、媒体技术控件toggle未能由hosting触发；可见window诊断未消除，断言未删/标准未放宽 | ui-closeout*、hosting相关日志；当前原生部分操作独立记载 |
| Qwen9B Q4正式runtime，2f2855b86c2ecd636ba749a657fe7d6e6bdee58a | 1个真实测试，4个不同请求通过，24.17秒；含视频环境实际启用 | qwen-closeout-real.log/xcresult/result.json |
| Klein Q8生产，84f66cdc18f9884792be2f1429f0f9ddd407b37c | 3周期严格新基准通过，90.33秒，资源回零；相同提示/seed42/512²/4步，未增加生成次数冒充不同模式 | klein-production-03；klein-ab*保存旧实现对照 |
| ACE原始F32/no-LM，406b853e07d2b6957cf684dad87ed782c87a8542 | 6秒1步WAV实际产出：288000帧48kHz双声道，有限F32，261.12秒；SHA256 a8f0fea3e7e24187f789d55d44ae7abf84cb213343ff0c5aff14ac8614aa99fd | ace-one-step/job/output.wav、result.json；50步受控停止另见ace-real-02，不计通过 |
| 正常签名构建，b315ffa | 正常工程装配六引擎通过，33.27秒；ditto复制正常成品，未构建后手补provider；codesign严格检查通过。启动器exit0且进程存在 | app-final-names、final-app-identity.json、launcher-native-start.json |

早期测试失败包含：fixture输出目录复用导致不覆盖保护触发、CPU测试适配签名变更、ACE一次lead直接provider cwd留下官方缓存。分别修测试调用/独立目录，缓存只移存本任务证据；生产provider已有job cwd。不是权限扩大、不是删断言。完整过程日志保留，不累计每轮重跑为新通过用例。

### 原生路径、试用与未验边界

普通签名App原生受测代码 **41ad63026da948eef6e3b5f5837f63744f1a2c98**，隔离会话 `4555a0d5-e285-48f5-b34f-dff8238a893c`。Qwen9B Q4：默认12GiB预算先正确拒绝估算13,108,401,696字节，随后由UI显式选15GiB；未先填JSON结构会拒绝。填写title(text)/answer(number)后Quick生成真实记录，带设置进入Canvas并显式运行得到同一结构；正常退出/重开保留两入口草稿、预算、运行及raw响应资产。没有覆盖普通项目或自动运行下游。证据 `native-final/qwen-gui-summary.json`及同目录AX/PNG。

H3原生：固定38文件144,023,606,861字节原件的独立APFS clone，通过真实目录授权和全部hash；点击模型库准备，发布独立包并登记，raw仍未转换状态、lease归零、当前Qwen草稿不被切换。准备后发现目录名污染视频标题，Lead修补 **b315ffa** 并独立审阅；旧自定义node.title不改。证据 `native-final/h3-preparation-summary.json`。这是准备链路，不是此App内H3生成。

最终b315ffa仅上述视频实名及对应测试变化。推荐启动器已成功启动最终包；随后CUA明确返回Mac锁屏，未继续界面操作。**不能说最终b315ffa已完成与父版相同的原生复验**；下一次解锁只补受影响标题/登记恢复及未验GUI，不无理由重跑全部模型。H32追加 `native-final/lock-after-final-build.json`；未修改锁屏策略，不轮询/催促。

唯一推荐启动器与同树Xcode Run说明：[精简试用](../RELEASE_FREEZE_TRY.zh-CN.md)。`delivery/samples/首发文字试用.dproject`是本次测试项目快照，其Qwen/H3生成权重不在App/项目内；既有Pitch评估引擎的包内ONNX例外仍按MODEL_SUPPORT_AND_RELEASE保留发行责任，不能称本包已经实现最终无权重分发。真实首尾帧H3、旧Wan/MRT2、H3 Store修复沿r1证据复用，不冒称最终同包全验。画布滚轮100→50%、中键视口移动、恢复100%已观察；空白平移/端口/拖放全矩阵和真人IME尚未关闭。

### 实施来源、审核与剩余预算

LIBRARY、VLM-CLOSEOUT、ACE-CLOSEOUT使用本项目已核验受限独立CLI `gpt-6-sol/high`，各自初交＋一轮有明确反例的修复；实际写根、请求/可观察设置、时间、输出在各job/spec/运行记录。隐藏服务端解析unknown。Lead负责共享接线、样例、固定金标决定、保存保护修补、预算/视频准备与实名修补，并亲自复验；不能把最终结果归为Worker独立完成。

Worker过程存在未按旧停止规则立即回报的缓存权限拒绝记录，Lead后续已核查并保留；不能把命令被拒绝写成已成功越界，也不能倒改为全程协议合规。没有观察到成功扩权或网络传输，未测边界不作系统证明。独立审阅为定点源码/证据检查，不是第二次模型执行：baseline02_services_readonly复核保存/迟到状态/预算/视频准备/标题；video_extension_map复核目录映射、F04与准备；h3_primary_research复核ACE四项生命周期修补。见 `targeted-review-summary.json`、`budget-review.json`、`video-preparation-review.json`、`video-title-review.json`。重要Lead差异经过非实现者检查，未新建常驻审核平台。

旧任务和r1预算不刷新。本轮不再无依据重复同一失败；Wan转换接线需上述明确子进程授权/固定依赖/取消发布实现与独立检查，不能拿H3打包冒充。ACE合理采样、27B和原始BF16缺验证不是“所有代码已无可改进”，后续仍属同一冻结名单欠账，不自动扩大模型范围。可观察单项墙钟见表；完整Lead token/订阅费用不可准确归因，unknown，不重算历史或用API价估计。

### 退出状态和恢复顺序

- **实现收口：部分完成。** VLM、固定目录、H3/LTX准备、已知投影、ACE局部生命周期和存储反例进入候选；Wan准备、完整模型条件/精度和部分交互仍欠账。
- **真实模型验证：部分通过。** 精确型号/参数以上表为准；ACE1步不达到合理采样门槛。
- **原生应用验证：部分通过。** 41ad630的Qwen双入口/冷恢复/H3准备已验；b315ffa最终显示修补的GUI复验被锁屏阻塞。
- **用户试用：有可用候选和隔离文字样例。** 同树正常构建带齐引擎，启动器已启动；未验路线上有明确缺口，不能作为九模型稳定版。
- **功能冻结出口：未通过。** H31平台访问、各未验精度/强条件、Wan工程接线及本包GUI仍须收口，不能仅改profile命名关闭。

写Worker、构建/CPU/推理自有进程均结束；最终试用App空闲保留，不自动生成，旧D保持。进程精确状态/保护/远端/最终SHA在 `R2/lead/final-receipt.json`；它是最终版本索引，不修改此提交自引用。恢复先核该回执对应HEAD、索引、个人修改、App四摘要与已知进程；再处理H31/解锁集中项和上述工程欠账。此刻停在用户试用检查点，不合入保护源/main，不发布，也不启动下一模型或新产品任务。


## r3 原始精度低内存续作（2026-10-01，执行中）

用户v0.2沿本任务新增明确工程：ACE F32先逐张量/分片准备，主干逐层SSD加载与阶段释放；Klein BF16其次，其他冻结模型按依赖继续。不静默量化/裁层/丢条件，不以一步样本关闭完整生成。速度不是失败，程序监测阶段/进度/RSS/MLX/swap/磁盘；MLX与UMA不相加，swap不是该进程独占；长任务预声明有限超时与无进展/磁盘风险条件。旧有限修复预算不刷新。

起点c44f6438a6090f305cd3dd5dfd9d9c98f4ec47b6；R3=`D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261001T040512Z-low-memory`。源01758b81527dc27eb4563bf1b66fd1ceab6647ee与个人scheme保护在lead/protection-before.json；候选干净。r2自有App35439和旧App37434保留，无新生成；不关闭未知进程。r2成果、原样本/失败/候选保留。

Lead负责ACE加载/共享请求/准备/装配及集成；只读非实现者定点复核。Qwen增量解析、HF下载认证等独立写切片仅在精确规格/独立受限CLI预检通过后派发，网络关闭、原件只读、允许文件/缓存/tmp明确，普通初交+两修后有界Lead接管不无限迭代；旧切片预算不冒名刷新。GPU、真实转换与重构建串行。

H31一轮诊断：hf0.36.0既有外盘下载环境，默认HF_HOME/token不存在且无环境覆盖；不读取token、不再重试旧401。固定清单的LTX下载仓实际是dgrauet/ltx-2.5-mlx，不是仅Lightricks原仓，已原位纠正集中待办并制作未执行的官方交互登录入口。登录只下载，Swift认证接线未完成不能因CLI登录就写通过。

### R3 bounded implementation ownership

Lead owns ACE SSD preparation/layer lifecycle, shared execution strategy and final app assembly. Two independent restricted CLI slices use `gpt-6-sol/high`, network off, own worktree/output/tmp only, no shared Git writes. New slice initial + at most two focused repairs; previous slice history is unchanged. Each starts preflight only, then requires verified runtime route before IMPLEMENT.

- R3-VLM: Qwen incremental final-body stream. Allowed paths: `Backends/MLX/Sources/DMLXBackend/MLXQwenVLMBackend.swift`, `Backends/MLX/Sources/DMLXBackend/QwenResponseStream.swift`, `Backends/MLX/Tests/DMLXBackendTests/QwenResponseStreamTests.swift`.

- R3-FORMS: Download-only Hugging Face credential connection. Allowed paths: `Packages/UI/Sources/DWorkbench/Models/ModelDownloadCredential.swift`, `Packages/UI/Sources/DWorkbench/Models/ModelRangeDownload.swift`, `Packages/UI/Sources/DWorkbench/Models/ModelLibrary.swift`, `Packages/UI/Sources/DWorkbench/Models/ModelLibraryTypes.swift`, `Packages/UI/Sources/UI/State/ModelLibraryModel.swift`, `Packages/UI/Sources/UI/Views/ModelLibraryView.swift`, `Packages/UI/Tests/DWorkbenchTests/ModelDownloadCredentialTests.swift`.

R3-KLEIN revision 1: Lead freezes `ImageRequest.loadingStrategy: ImageLoadingStrategy?` (`staged`, `ssdLayered`; nil preserves the historical staged path). A restricted Sol/high Worker will implement only the existing Klein BF16 encoder/transformer block residency and local backend estimate, preserving full layers, BF16, token/condition order, sampling and ownership. Lead owns Workflow/UI/Store copies and rejects unsupported loading modes in other adapters. No new weight format or installation stack; reuse existing lazy safetensors loading. Representative original ACE F32 6s/50-step provider run exited 0 in 366.19s with 1600 layer completions; it tested the captured provider snapshot before subsequent cancellation/progress fixes, not the current uncommitted Swift/App assembly. Evidence: R3 `lead/ace-ssd-real-01-summary.json`.

R3-KLEIN precise allowed paths: `Backends/MLX/Sources/DMLXBackend/MLXImageBackend.swift`, `Backends/MLX/Sources/DMLXBackend/LocalImageModelInventory.swift`, `Backends/MLX/Sources/DMLXBackend/Flux2LayeredExecution.swift`, `Backends/MLX/Tests/DMLXBackendTests/Flux2LayeredExecutionTests.swift`, `Backends/MLX/Tests/DMLXBackendTests/MLXImageBackendTests.swift`, `Vendor/flux2-swift/Sources/Flux2/Models/TextEncoder/Flux2Qwen3TextEncoder.swift`, `Vendor/flux2-swift/Sources/Flux2/Models/Transformer/Flux2Transformer2DModel.swift`, `Vendor/flux2-swift/Sources/Flux2/Pipeline/Flux2KleinPromptEncoder.swift`, `Vendor/flux2-swift/Sources/Flux2/Pipeline/Flux2Denoiser.swift`, `Vendor/flux2-swift/Tests/Flux2Tests/Flux2Qwen3TextEncoderParityTests.swift`, `Vendor/flux2-swift/Tests/Flux2Tests/Flux2TransformerParityTests.swift`, `Vendor/flux2-swift/Tests/Flux2Tests/Flux2KleinPipelineTests.swift`. Worker cannot edit shared requests, workflow/UI/Store, dependencies or rules. Tiny parity fixtures may be inline in these tests only; no generated production weights committed. Full xcodebuild/Metal/real BF16 and upstream-patch provenance remain Lead owned.

R3 Lead integration increment (still unaccepted): shared Klein loading/memory choice and legacy nil compatibility, transient run-owned final-body preview (never published before successful result), and ACE progress protocol bounding/header safety. The upstream ACE console print was observed on direct-provider stdout; EventWriter now captures the JSONL stream while upstream diagnostics route to stderr, covered by a fake-handler protocol regression. Current Python suite: 34 CPU checks pass; 6 fixed-vendor checks are separately evidenced, not silently counted in this suite. Previous full F32 50-step generate and lyrics+reference and cover runs passed; repaint is still running. Those jobs use preserved pre-protocol-fix provider snapshots and cannot certify this new Swift/App assembly. A task-owned upstream cwd progress cache was identified and moved with its exact digest to R3 evidence; subsequent direct runs use isolated job cwd. Source/personal scheme untouched. SSD uses an explicit 12h configured watchdog, not unlimited duration; estimated slowness alone does not stop a job.

### R3 recovery checkpoint — 2026-10-01 (implementation continues)

Evidence root remains R3 above. Original source `01758b81527dc27eb4563bf1b66fd1ceab6647ee` and its unstaged personal scheme remain protected; no source/main integration or r3 push has occurred. Candidate HEAD before this checkpoint is `b0f037c7a2598035f82d17605f888e9f16047961`; uncommitted Lead Wan App/library/packaging work is not accepted code.

- Original downloads completed and fixed-source digests verified: Klein BF16 `e7b7dc27f91deacad38e78976d1f2b499d76a294` 15,980,131,745 bytes; Qwen3.5-9B BF16 `c202236235762e1c871ad0ccb60c8ee5ba337b9a` 19,329,392,091 bytes; Qwen3.8-27B BF16 `1d4bf0f2ff6012fd82039f2fa52739d0dd7c60c0` 55,586,113,293 bytes. Download/verification is not inference acceptance. R3/lead/original-model-download-result.json keeps each file's digest algorithm (Git blob SHA-1 versus SHA-256).
- ACE original F32 full32-layer/50-step runs now include baseline, lyrics+reference, cover and repaint. Direct provider jobs used captured earlier provider code, 357–366 seconds for six seconds of audio; source/conditions and wave checks are retained. No one-step substitution. Formal DRuntime at `d96b0a9b2c87af457ade49602bb8776e3099d84a` subsequently passed cancel-at-layer → drain/release → full reference+lyrics generation, 549.29 seconds overall, reservation zero. `ace-runtime-real-command/result.json`, xcresult and run outputs distinguish the two operations. This is real model/runtime, not GUI or human listening.
- ACE additional original-weight GPU comparison at `f71537c1092e03ff96c5121922d8abcad2b33ac3`: independently loaded original F32 sliding/full attention blocks 0/1, two timesteps each; exact output/cache parity and unchanged RNG versus SSD loader. `ace-original-block-control-summary.json` (8.43 seconds inside probe). This establishes representative loading arithmetic, not full-model resident parity.
- R3-FORMS initial+two repairs completed; seven files reviewed and merged at f71537c. f715 UI CPU groups: 1/1, 28/28 and 76/76 across separate targets, not one combined suite. Credential file selected explicitly, download-only scope, cross-host redirect strips authorization; no token transmitted to inference. Real H31 login not performed. Repair2's denied read-only `ps` was reported only after further editing: protocol timing deviation retained; no successful escape or permission expansion observed. Detailed evidence `forms-final-review.json` and route records.
- R3-KLEIN initial+two repairs used restricted Sol/high. Repair1/2 added bounded SafetensorsReader and tests to original scope (same keys/dtypes/shape contract; VAE scalar I64 counter retained). Final Worker candidate `1c1f1343d76678d8c69ad4ac4c9693250caffffe` reviewed and merged for validation only. Vendor test action is `Flux2-Package` from package directory; workspace product scheme `Flux2` has no test action (exit66, not code failure). Actual 15 tests had four failures caused by new fixture saves emitting `__metadata__:null` for empty MLX metadata; strict reader correctly rejected them. One bounded Lead takeover at b0f037c sets explicit format metadata in those fixtures, leaves production reader/precision/assertions unchanged. Re-test pending. No BF16 full-generation claim yet. Tiny fixtures were actual Metal execution, separate from full weights.
- R3-QWEN-SSD new bounded slice uses explicit optional TextLoadingStrategy (nil/resident legacy; SSD original BF16 only), full hybrid decoder and staged vision, throwing I/O iteration, checked stage estimates. Allowed files: TextRequest; Vendor MLXLMCommon LanguageModel/Evaluate/Load; MLXVLM VLMModelFactory/Qwen35/Qwen3VL/Qwen35LayeredWeights; TokenIteratorTests/Qwen35LayeredTests; backend MLXQwenVLMBackend/QwenVLMModelInventory/QwenLayeredResourceEstimate; QwenVLMContractTests/QwenLayeredExecutionTests. Shared forms/Store/provenance remain Lead-owned. Initial+one repair delivered but not accepted: repair reported a task-tmp refusal, raw route/event audit is in progress; independent review still finds a VisionModel initializer compile defect. One ordinary repair remains, no third round or silent model change.
- R3-WAN-PREPARE is a separate necessary preparation bridge, not a new model: four files only (WanModelPreparation Swift + test; existing d_video_prepare.py + test), restricted Sol/high, base f71537c. Initial Python12 tests passed; Swift parse only, OMP warning retained as environment observation, not proof of successful out-of-root write. Independent review found incomplete success-marker acceptance, late-mutation gap and cleanup failure permanently holding a stopped process's permit. Repair1 R3.2 active. Narrow clarification: unknown child drain still quarantines/retains permit; confirmed-dead child with failed bootstrap-file cleanup reports failure and preserves unknown files but releases compute ownership. Lead owns installation lease, atomic non-overwrite publication and normal engine packaging. No whole-state Torch load or precision rewrite.

All restricted worker routes have exact worktree/output/tmp write roots, workspace-write, network off and observed `gpt-6-sol/high`; hidden server resolution unknown. Heavy builds/Metal/model jobs are serialized. Human H31/H22/H32 unchanged; no repeated gated request or lock probe. GUI/package/human and complete freeze remain unaccepted. Logs/weights/media stay outside Git; ordinary failure evidence and spent budgets persist.


### R3 原始模型与正常构建检查点（2026-10-01，完整Qwen复验中）

本段更新上方历史检查点，不能据旧“修复中”推断最新停点。运行根仍为R3。源/个人scheme保持原样；未合入源/main。

- R3-QWEN-SSD普通初交＋两轮修复已用完，由Lead执行一次有界收尾。修复原始9B的48个F32控制张量读取（其余727为BF16），保留原dtype；27B1199个BF16张量不伪造9B同精度结论。Tiny对照发现分层在lm_head前提前取最后行改变GEMV/GEMM舍入；恢复与常驻相同的完整chunk投影，零容差断言保持。资源估算按真实F32升型缓存与完整投影更新，不放宽系统内存权限。
- 9B真实第一次完整四请求在`258cb208435419dd35d4405b0f44f98517e80471`生成了JSON、双图顺序、视频描述和工具结果42，取消后可继续；但视觉后active16B/cache0导致3处严格释放失败，不能记全通过。视频698.39秒持续有进度，无预计慢而终止。
- 小型独立进程已确认上游两个全局GELU编译图：BF16分别保留4B/12B，合计16B；F32再增加16B。`b347c3804d9ec6498209489197c4d3ef8c03efa9`在Qwen视觉模块中按原公式/原运算次序持有编译闭包，释放模块即走MLX既有deinit清图；不重置全局RNG、不清其他任务缓存、不改精度。三轮scoped BF16/F32释放归零，和原函数严格arrayEqual；独立审阅无P1/P2。完整正式Runtime随后复跑：b347c38的9B 1方法836.707秒通过（外部命令839.445秒），取消15.667秒，JSON78.929秒、双图21.880秒、视频691.483秒、工具结果28.416秒，各次active/cache严格归零，MLX峰值约8.66GB。该历史短视频在请求2fps下只采到1帧，模型回答将其视为静态图；仅证实请求所含完整输入及生命周期，不证明时序理解质量。27B正在按既定独立请求复验，不以9B或helper通过代替。
- 原始9B与27B分别取真实线性块0和全注意力块3，以独立原始index/常驻导入对照生产逐层加载；2/3/1/1 token的权重、输出、缓存dtype/shape/零容差数值、随机状态和原件身份通过。9B同次15方法/2suite，27B独立1方法；第一次27B筛选缺`()`实际0测试，保留记录且不计通过。固定来源另由完整下载摘要绑定。Vendor276文件及完整上游补丁独立重放均校验。
- Klein `f14bcd07d6c73181fc765f7d497f346e261489d0`实际BF16正式Runtime 1方法82.983秒：加载取消15.876秒→释放0，512²/4步/guidance1/seed42完整生成31.363秒，两张有序256²参考生成35.552秒；各次active/cache0，峰值MLX约2.30GB，PNG真实解码、输入摘要不变。128²参考的旧失败符合最小256限制，只修夹具不改契约。真实样本在`klein-bf16-real-05/`。
- Wan逐张量原件准备和App发布服务接线在`e80ccd1`/`d917150`；独立非实现者审阅。VideoEngine正常准备补齐固定Torch/safetensors与现有Python的Tcl闭包，没有安装全局依赖。`b347c38`真实内嵌桥103.115秒、转换自身89.010秒/峰值RSS9,465,528,320B；1,261张量逐项有限值/精度与写回相等检查、固定原件摘要、完成清单，计算许可与目录访问均正常释放。6方法同次104.445秒通过。生产`ModelWanPreparation.verifiedFiles`随后验证真实1262文件包7.233秒；同次模型35→36方法、工作台76、翻译1分别通过，不能拼为一个测试suite。真实App沙盒按钮、原子发布/登记仍待H32，不由组件结果代替。
- 平台文字执行契约7方法通过；18个视频打包CPU用例通过。`dd00baa`只把Quick/Canvas三个加载方式共用中英文标签，Picker raw tag/请求/存储不变；新1方法0.016秒通过并独立审阅。普通D Nodes工作区正常签名构建183.820秒通过；本地忽略xcconfig指向R3六引擎资源，解决仍指R2而不含Wan转换依赖的接线遗漏，无构建后修改App脚本。最终App及后续仅文档对应关系由外部回执记录。
- 两项hosting已有失败定位为离屏普通Button/连接AX触发、技术信息Button触发，后续隐藏内容断言为连带失败；不是已证实语言选择/真实按钮失效。代码接线存在，不删/降断言、不重复同环境失败。H32解锁后用真实点击复验图/草稿不变和零推理。

细项证据：R3/lead下`qwen-activation-diagnostic`、`qwen-scoped-activation-control`、`qwen-original9-block-control`、`qwen-original27-block-control-02`、`wan-original-real`、`ui-final`、`platform-final`、`loading-labels`、`app-r3-build`各命令/结果/日志及xcresult；`execution-app-version-mapping.json`精确区分b347运行器与dd00正常App。重型任务串行，单项RSS/MLX/swap不相加；不是速度基准。完整Lead用量/订阅费用unknown，不重算既有样本。

所有写Worker已交回文件，无新写代理；Lead代码由`baseline02_services_readonly`、`h3_primary_research`、`video_extension_map`按范围只读复核，审阅者没有自行执行模型。相关review.json留R3/lead。此前拒绝事件与未及时停报、普通失败和已耗预算继续保留；不是全程无失误的声明。H31/H32/H22无新本人状态，不重试401、不催解锁、不重开已关闭的录音/断网。


### R3 交付检查点（2026-10-01）

本段是本轮最终结果，替代上方当时“执行中”的停点，不倒改其失败和修复历史。原始精度低内存执行交付在同一候选；**功能冻结仍未通过**。

| 层次 | 最终已核实结果／边界 |
| --- | --- |
| 实现与装配 | ACE逐张量准备/全32层F32 SSD主干，Klein BF16编码器与主干逐层，Qwen原始混合状态/完整chunk投影、视觉编译缓存所有权，Wan原件转换到模型库发布接线，下载专用凭据和Quick/Canvas同一加载字段已入候选。未增加平行运行时，旧常驻/量化路径保留，SSD为明确选择。 |
| 原始模型 | ACE50步完整六秒、歌词参考/cover/repaint及正式取消恢复，Klein512²完整生成/双参考及取消释放，Qwen9B/27B完整代表请求通过；精确代码、条件、时间和资源见模型矩阵及各result/summary。不同版本/不同suite不累计为一个通过率。 |
| Qwen最终复验 | 运行二进制b347c3804d9ec6498209489197c4d3ef8c03efa9。9B 1方法836.707秒、命令839.445秒：取消15.667秒，JSON78.929秒、双图21.880秒、短视频691.483秒、工具结果28.416秒，最高MLX峰值8,661,020,016B；27B 1方法361.288秒、命令364.244秒：取消35.449秒，JSON199.974秒、双图54.032秒、工具结果71.610秒，最高6,111,332,320B。每次released active/cache均0；正式Runtime预约释放断言通过。 |
| Qwen证据限制 | 9B视频完整处理本次请求采样，但历史短片按2fps仅1帧，回答视作静态图，不证明时序理解质量；27B未传视频、未验视频。两款未验长上下文极限。只是短请求限制输出256，并未把模型公开上下文能力降为该值。块对照与实际权重来源摘要独立留证。 |
| 普通App | dd00baadbc030c186c1db4ceee12e02a4a4e401b正常签名D Nodes构建通过，独立副本严格验签和启动器只读检查通过。b347→dd00仅5份显示/翻译/测试文件，后端/请求/供应商源码一致；新标签1方法通过，非实现者复核。后续结案提交仅5份文档，最终SHA写外部回执，不说模型测试跑在尚未产生的文档提交上。 |
| 原生GUI／真人 | R3 App没有启动验收；最后已知锁屏且无状态变化。r2 Q4/准备/冷恢复只作历史证据。两项离屏hosting动作失败保留、不降标准，需H32真实点击；H22候选窗位置及新ACE正常50步样本试听待本人。无重新断网/麦克风要求。 |
| 试用／冻结 | 已交付同树正常开发App、唯一启动器及Xcode Run说明，R3原始路径可明确选择试用；未称九模型稳定版。Dev/LTX2.5资源H31未解决、既定原生能力与同包双入口/保存导出、首次使用/分发责任继续保留；未仅靠profile改名结案。 |

新证据索引：R3/lead的`qwen9-original-runtime-final-summary.json`、`qwen27-original-runtime-final-summary.json`及对应命令/xcresult；`qwen-serial-queue-result.json`确认9B成功后才启动27B、整体退出0。Wan、UI与普通App证据沿上段；`documentation-final-review.json`记录非实现者对最终指导的四项具体纠正。旧16B失败、0测试筛选、资源/环境失败均未删除。

来源：受限Sol/high Worker完成分片实现；Lead协调共享请求/Store/UI/资源、实施本次有界收尾并执行验收，重要差异由非实现者定点检查。不是Worker独立完成，也不是第二模型重复实跑。旧未按时停报事件与修复预算保持，隐藏模型解析、完整Lead消耗及订阅实际费用unknown；只保留可核对的单次墙钟，不重算历史用量。

恢复：源01758b81527dc27eb4563bf1b66fd1ceab6647ee和个人scheme摘要/索引/未暂存差异由最终保护回执逐项确认；不合入保护源/main，候选正常提交/推送，最终远端以R3/lead/final-receipt.json为准。自有构建/测试/转换/串行推理进程已结束，未关闭旧D/未知进程；不以此宣称系统无其他作业。候选、原件、样例和历史证据保留。下一步仅在H31或H32/H22状态变化后补对应既定验收；本轮停在用户试用点，不新开模型或产品阶段。
