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

### R3 集中办理补验（2026-10-01）

本段更新上方交付时尚未解锁/登录的状态。候选起点`f383871c8a83afb6efaaec99dfe97c7e5e34136f`；受测普通App仍为`dd00baadbc030c186c1db4ceee12e02a4a4e401b`，本次没有生产代码修改或重建，仅追加任务/当前行动/集中待办三份记录。R3定义沿上文，H=`R3/lead/human-20261001T133601Z`。**这是部分原生补验，不是功能冻结完成。**

- H31：本人登录与访问申请后，13:36 UTC FLUX.2-dev固定revision `26afe3a78bb242c0a8bb181dcc8937bb16e5c66c`及LTX2.5实际MLX仓revision `e378b7e1b50fcb1795fce74219b40bb0b1ede1e2`的代表权重metadata与固定清单相符，Range各1byte返回206。旧403不覆盖。完整32/19文件合计183,760,215,682 bytes串行下载/摘要校验已启动；实时记录`R3/lead/h31-download-20261001T133601Z/events.jsonl`，只有最终result才证明完整资源取得。未读出token/钥匙串或在日志打印凭据。CLI登录不等于沙盒App取得凭据文件访问权；该入口仍未实测。
- 原生隔离：旧r2 App持有推荐试用session的模型库；本轮初次新实例被明确拒绝，正常退出，未关闭旧实例。单独验收启动器`H/启动本次集中验收.command`只替换本次session UUID，不改交付App，普通推荐入口不变。会话`2DCE71F2-652C-4917-AE76-77035D2EB35A`，新建`H/H32-r3-native.dproject`，无真实用户项目改写。
- 原生交互：点击文字连线能打开检查器，Unicode草稿`待保存草稿 👩🏽‍🎨 é 100%`与选区`待保`保留；中→英→中切换不丢草稿/选区。实际打开视频`d.video.generate`、音乐`d.music.generate`技术信息，此阶段没有提交模型任务。此为普通App真实点击证据；两项旧离屏hosting失败没有重跑，也没有改断言。
- Wan：完整原始仓目录因额外`google/`被严格导入拒绝，作为兼容缺口保留；Lead在本次证据目录创建仅固定三文件的APFS独立inode副本，不删改原件。App导入→原生“准备独立执行包”→逐张量转换/校验→原子发布/登记通过，1261张量，使用租约结束。`H/wan-native-source.json`和`wan-native-result.json`；不是Wan GUI生成或准备中取消通过。分词器仍由既有VideoEngine独立提供，执行包不是脱离引擎的完整运行环境。
- Klein：固定18文件BF16副本经App导入校验；Quick与Canvas往返实际保留512×512、4步、guidance1、seed42、预算0、`loadingStrategy=ssdLayered`。分别在Quick与Canvas真实执行红色陶碗提示，结果均成功，PNG各自实际摘要相同`6b2d7216cd828ad951b79a229a68fb2fb643df9274833eb0cf9b3316fd34c9c8`。这只是同一固定样本，不承诺任意运行逐像素确定性。Quick结果见`klein-quick-native.json`（参数由原生观察支撑，资产摘要另核对）；Canvas完整执行快照见`klein-canvas-native-run.json`，只运行新增的一个图像节点，不是整个E04四模态通过。
- 冷恢复：正常退出并重开同一隔离session，Quick恢复原提示/参数/结果；打开最近项目，原文字草稿和Klein已完成节点/SSD参数恢复。`cold-reopen-result.json`核对两图内容、一个完成run、资产及PNG摘要与退出前完全一致，没有自动新任务。缩小画布到50%查看，不冒充完整50–180%拖放矩阵。
- 新工程缺口：导入后`ProjectSession.selectWorkflowInstallation`未更新显式准备状态，`DualWorkbenchView.refreshLibrary`只刷新Quick，已打开Canvas的模型列表可能过期。实际双入口resolver可执行，冷重开模型名称正确；旧列表还用于直接添加门禁，不能仅称文案问题。最小后续修补为同步投影并保护草稿/请求，不新建运行时。只读非实现者已定点定位，未修改实现。
- H22：本人确认选字正常，候选不跟随；新增文本I型/窗口边缘拉伸光标只闪现后恢复箭头，输入和拖动仍可用。未证明根因，未作新修补，不要求本人反复复测。CUA一次SCStream -3812重连恢复，仅为工具事件，不归因于锁屏/光标。ACE固定六秒原始F32/50步样本由`afplay`播放exit0，本人答“听到了，播放正常”；`ace-listen-source.json`。Python标准wave不支持float格式3不代表损坏；本次不称App内播放或新GUI音乐生成。

保护：`protection-before.json`→`protection-after.json`逐项比较源HEAD、scheme完整diff/摘要/索引/未暂存状态和App三关键文件摘要/大小/mtime全部不变。`originals-metadata-after.json`确认两套原件inode/大小/mtime不变，是后验元信息检查，不冒充额外全权重散列。自有GUI PID82523/82948/83688均正常退出并确认不在；旧D 35439/37434未操作。自有固定下载仍在运行，工具会话48725；恢复时按进程和events/result核实，不能把GUI结束写成全部后台进程结束。

来源/复核：Lead执行原生验收与记录，`h3_primary_research`仅只读核对固定资源/入口和本次四份结果，不是另一个模型执行了GUI/真实生成。其指出Quick结构记录较窄及旧progress两处滞后，Lead已修正`realModelRunThisHumanSession`与SSD原始枚举并保留分层结论。无新Worker实现/修复轮次，不重算历史费用；本次完整Lead消耗与订阅扣费unknown。

恢复与下一步：H31本人访问和本次试听无需再办；H22先工程修补再必要真人复验。继续既定下载/Dev与LTX原始能力低内存接线、模型即时投影与原始目录兼容问题及剩余H32，不开新家族、不据资源慢放弃，也不以改profile名结案。最终文档SHA和远端/进程快照写`H/final-receipt.json`；不合入保护源/main、不发布，原件/候选/旧失败证据保留。


### R4 接续规格（2026-10-02，执行中）

同一任务，r4仅交接标识；起点3a11abaed601fad73d9050719cf0235dca560395，源01758b81527dc27eb4563bf1b66fd1ceab6647ee与未暂存个人scheme不动。按用户本次附件完成既定缺口，不增加家族/架构阶段，不合入保护源/main、不发布。R4=`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261001T162316Z-r4`；保护及下载复核见lead/protection-before.json、download-recovery.json。原Dev/LTX下载结果确实完整，未重启下载。

Lead协调共享ProjectSession/双入口状态、H22真实控件诊断与最终包；可独立的Dev完整原始SSD、LTX2.5塔/连接器分阶段、Wan外部目录清单投影使用受限独立CLI，精确允许文件及执行基线随本run冻结job/prompt，先预检后授权。新切片普通初交+两轮修复、最多一次有界Lead接管；旧Klein/Qwen/Wan转换实现预算及失败不刷新，修补新增缺口不重做旧实验。禁止Worker网络、GPU、GUI、重构建、源码外写入、共享Git写入；必要语法/小CPU检查使用任务tmp，Lead串行验收与显式提交。

风险与检查：Dev/LTX驻留/原始混合dtype → 真实小块数值对照、完整代表文生/参考及取消释放 → 沿用未变模型证据，不拿块对照替代整模型；模型投影/导入 → 状态/代次/原件反例及普通App路径 → 不重复转换验证断言；H22 → 实际firstResponder/client/firstRect与指针覆盖取证、最小补丁及真实组字 → 禁止全局替换、计数冒充坐标。新唯一测试正文TESTING_POLICY，AGENTS/协作入口短引用。最终应交同版本普通App、唯一推荐启动器与同树Xcode Run；未验/失败不改记通过。

### R4 执行证据增量（2026-10-02；尚未结案）

- 下载复核：原作业已结束且verified，Dev32文件112.823GB/LTX19文件70.937GB；仅核固定revision、来源与文件身份/大小，未重复下载或全量散列。H31不再设停点。
- 受限写切片均为可观察 `gpt-6-sol/high`、workspace-write、各自工作树/输出/tmp、网络关闭；隐藏服务端解析unknown。Dev初交＋修复1，LTX初交后一次已明确安全路径恢复，Wan初交＋修复1；完整route/job/异常摘要保留R4 worker目录。Wan修复1 heredoc临时写拒绝在Python执行前立即停报，Lead未提权；被拒临时文件精确位置unknown。不能将其写成成功越界或没有任何副作用的系统级证明。
- Dev整合271ac840827ffe35ed19e70369c882136367ebde：完整40文本层/中间层10、20、30；8双/48单DiT；原F32 VAE与I64计数保持；固定入场身份用于每阶段/读取前后复核。非实现者检查资源/条件/数值/原件边界。新夹具MLX空metadata导致严格reader拒绝，改为非空format元数据，不放宽reader。原始代表块对照`dev-original-weights`1方法4.351秒；文本/双块/单块常驻与逐层输出相等，非完整模型常驻对照。Vendor206文件/6补丁18改动闭包通过。完整正式Runtime首试误把开发来源JSON一并交给严格清单而被拒，原件未改；改用32固定文件独立APFS克隆作输入，生产完整校验保持。正在执行`dev-runtime-full-02`，受测二进制d3afbfb3fbb6f5227e0f104bdbdab3b680ea6b92。
- Qwen视频在4bc9b9ffa7810ccaa4b380dec5c6a06a871265b5修正原处理器丢时间戳、两帧网格只占一个语言块的问题；固定上游transformers a005fc82babfe8871d87746decad2dbee100a125 的processing_qwen3_vl/modeling_qwen3_5为依据。原图像/文字行为不改。3个小型Metal/位置检查通过；实际9B/27B同一红→蓝2秒视频、4采样帧、完整原始模型/SSD/输出128/seed42，分别131.489和293.433秒通过，回答正确顺序，MLX active/cache严格0。两个独立方法，不拼成全能力通过率；R4/lead/qwen{9,27}-temporal-fixed*含请求/输出/运行及xcresult。Vendor276文件/10改动独立来源重放通过。
- LTX小型48层/49状态/两注意力/两prompt数值maxabs0，`ltx-numeric-control-result.json`明确synthetic。实际完整原资源通过生产模型库准备，`ltx-production-prepare/result.json`，56.878秒，独立准备包保留；未生成视频。固定源码124文件及原补丁+流式补丁闭包通过，独立审核无P1/P2。
- Wan整合cf4a32355e6fe41ba7207fea8d20363baa08f1b9：仅固定原仓外部根投影所需树，NOFOLLOW验证中间目录及叶子，额外内容不读取。18个CPU安全/生命周期用例通过。首次两个URL断言仅因目录尾斜线失败，以标准path＋实际inode修正夹具，不降保护。真实完整目录登记首次重开夹具保留旧actor，正确触发状态锁；按既有实例生命周期释放后，`wan-actual-reopen`1方法6.822秒通过，原件身份不变、记录恢复、active lease0；未经原生文件面板操作。
- 就绪投影672ee0dc及相关实现：resolve租约/代次/revision floor，拒绝旧positive snapshot覆盖新状态；共享Quick/Canvas刷新不改草稿、参数或模型请求。6个就绪/外部视频服务用例通过（`ui-wan-ltx-preparation`），同一运行另有2个Wan夹具失败，不能把整个命令写通过。
- 4e088ac：H3内层7200秒与代表测试43200秒不一致，传递父期限并验证有限正数，App显式12小时；24项Python夹具通过，非实现者审阅无P1/P2。旧CLI省略新参数仍7200；Swift新入口必须匹配新provider。Representative新增terminal记录，事件失败也等待outcome；runner最终结论才是通过依据，文件名acceptance/DONE不单独算通过。
- 两项hosting仍失败：普通按钮positiveResult=false，事件未真正派发；非实现者定位helper早退，但现日志缺坐标/队列证据。新增单次结构诊断，不归因于锁屏、不改生产文本系统。H22当前真实诊断尚被锁屏阻塞，DEBUG工具不代表缺陷修复。原生待办已在唯一清单记录，旧证据与真人失败保留。

本段不是最终冻结回执。所有模型完整生成、普通App、原生操作和发行结论分开；最终受测SHA/App/远端/进程见后续外部回执。费用与完整Lead归因unknown，未重算历史累计用量。

### R4 完整Dev与视频入场增量（2026-10-02，仍在执行）

- `dev-runtime-full-02` exit0、5526.883秒，单方法5524.332秒：计算中取消后释放，无未发布产物；512²/50步/CFG4/seed42文生与有序双参考均完成，原始精度不变。文生2497.501秒、参考2907.018秒，MLX峰值分别4,618,451,208/4,618,596,104B（不是全进程RSS），结束active/cache0。受测d3afbfb3fbb6f5227e0f104bdbdab3b680ea6b92；请求、结果、生命周期、原件摘要及PNG均在R4/lead/dev-runtime-full-02，Lead已实际查看，两种图像均符合基础语义。
- 在dba33e67022305793b44126a9b34a014b3967fe5复用这两张产物，`dev-generated-store`/`dev-references-store`各一方法通过：正式Store独立项目发布→保存重开→导出媒体逐字节一致；请求ID、profile、精确revision、有序参考摘要在复制前绑定。公开配方保留已允许来源/参数、隐去prompt和私有输入。两份测试由非实现者复核，无P1/P2；不冒称WorkflowRunner或GUI已验。
- Dev开发下载根含来源sidecar，严格模型目录不接受它；本次使用32固定文件独立APFS克隆。正常受管理下载本来只创建32文件、状态在目录外；最终试用可以从已准备目录导入，不称含附加文件的原目录已正常导入。没有删来源/放宽校验/重复下载112GB。
- `prepare-video-final`先因父目录不存在失败、`-02`因误用只有改动源码的site而缺mlx失败；`-03`恢复已成功的完整固定site，14.420秒通过，不新装依赖。`prepare-resources-final`36.917秒通过；`app-final-build`正常签名构建82.474秒通过并独立核签名，源dba33e6。此包早于下条LTX入场修补，尚不是最终推荐包。
- `video-backend-final`9项CPU通过0.994秒。LTX完整代表请求首次27.938秒在入场失败：原固定transformer-dev为3,801 BF16＋290 F32，旧校验错误要求全部块参数BF16；无生成产物，Runtime归零。deba25435c6c2cdd4a88a8c63160ef95f89c5b9e只按六种逐层与两种输出表的精确名字/形状保留F32；其余主干BF16和固定SHA/NOFOLLOW不变，未重写权重或改精度。新回归先失败后通过，三模块40项CPU8.123秒、原始4091张量header通过；非实现者审阅无P1/P2。`prepare-video-modulation`28.150秒生成新隔离包；运行中的H3仍使用先前不变引擎，不被覆盖。后续完整LTX与同包App必须使用新包，不以header通过关闭整模型。
- hosting仅诊断增量98dcb9ccf24d6241c68f8e4dbefc28e2c81e4832：动态selector遍历242对象、全部完整AX协议、队列耗尽且identifier为0；排除本次协议cast与遍历上限假设，不能确定不可见/锁屏原因。四项原动作断言保持失败，未改生产UI/标准。自然客户端/指针来源仍需解锁后采集；不继续堆通知测试。

本段非结案。视频代表请求、原生操作、最终打包与冻结结论仍以实际后续结果为准；所有旧失败和已花预算保留。

### R4 LTX计算期取消接线（2026-10-02，未提前宣告真实通过）

`6328d9c`由Lead补充首个Gemma4 block求值后的固定进度行，以及LTX同进程有界日志（4MiB、独占创建、原stdout透传）；不增加进程、公共协议或数值变换。真实测试仅观察当前请求目录的完整标记行，再取消并要求零产物、已drain/释放，随后同一Runtime完成两次正常30步请求。缺标记、提前退出或1,800秒观察超时均失败，不能用定时取消冒充实际加载后取消。

最初误将H3的`_run_child`日志看作LTX入口，非实现者指出LTX实际直接调用`ltx_main`；该假设的临时CPU探针未保留为源码或通过证据。实际同进程反例先失败；新增日志后的首次25项CPU因旧双profile夹具遗留自己新产生的日志失败，补齐夹具自身清理后25项通过（5.689秒）。补丁固定源码检查第一次因准备夹具遗漏已有tokenizer两文件失败；补齐原有固定文件后5项通过。未改断言、精度、输入或生产清理策略。`ltx-live-progress-review.json`记录非实现者只读审阅无P1/P2；只打印固定阶段的变化不重复此前数值采样。

H3完整文生50步已经1267.116秒通过且Runtime归零；Lead查看首/中/尾帧，红杯木桌及时间变化可辨，音频仍未真人试听。本段写入时首尾条件请求仍在执行。自有旧等待器15217明确结束143，未启动第二个LTX；替换为有界串行队列，等待H3终态后依次编译、准备同版引擎/资源、普通App、LTX完整取消恢复验证。没有取消H3或改运行中引擎。源保护不变；最终状态必须读后续result/回执。

### R4 H3完成与同版交付准备（2026-10-02）

H3 `h3-representative-result.json` exit0，总3274.421秒、单方法3271.875秒；受测dba33e67022305793b44126a9b34a014b3967fe5。512²/22帧/24fps/50步/seed42，全50层原始BF16、SSD：文生1267.116秒、首尾条件2004.600秒，输入原件不变，每次Runtime activeRun=none、reservedBytes=0。真实H264/AAC媒体通过完整解码；三帧检查分别见红杯木桌运动、红→蓝方形条件变化。后者是合成条件验证，不是通用画质结论；9.454GiB为最大报告阶段分配，非全进程峰值。`h3-text-store`/`h3-conditioned-store`各一方法通过：正式Store发布、重开及导出字节一致，未重新生成。汇总`R4/lead/h3-representative-summary.json`；不称原生操作或真人试听。

6328d9cd7dca1edb1b2a5b233089bb73469be7ca正常签名构建44.550秒，完整App克隆至`R4/delivery/D Release Freeze Closeout.app`，独立深度签名/关键四文件核对通过。唯一`启动首发收口候选.command`语法和只读`--check`通过，未启动App；同树Xcode的本地配置指向同一resources-progress，嵌入provider/补丁/source摘要与准备引擎相同。`app-r4-delivery-checks.json`、`app-r4-video-source-match.json`、`launcher-r4-check.json`。没有构建后手补文件，普通App与旧数据未改。

同版LTX03在实际Gemma4首层求值后取消，50.034秒、零产物、已drain/许可归零；同一Runtime后续完整30步文生/首帧仍在运行，不能按取消成功提前关闭。已配置有界程序等待其真实终态，再复用两份结果做Store检查；不重复提交推理。解码器沿固定上游的时空tile，现有解码峰值日志并非全模型/全进程峰值，缺测量保留unknown。

常驻测试政策与试用路径由非实现者只读核对：无交付入口硬阻塞，补回低成本检查前置、既定watchdog/程序监测、至少两处真实复用才抽象三项原意，修正资源目录歧义。`r4-policy-try-review.json`；没有额外构建或重复模型验证。当前仅文档待提交，GUI/H22仍受锁屏阻塞；此段不是冻结结案。

### R4 交付检查点（2026-10-02；原生与功能冻结仍未通过）

- **LTX正式Runtime**：受测与普通App代码均为`6328d9cd7dca1edb1b2a5b233089bb73469be7ca`。`ltx25-representative-03`实际一个方法16970.227秒通过，外层16972.902秒、exit0。先在真实Gemma4首层求值后取消50.034秒，无产物、已drain；随后文生8118.298秒、首帧条件8801.697秒，均704×480/97帧/24fps/30步/CFG3/STG1/seed42。固定原始BF16与290个F32调制表、48层Gemma4/49状态/48层DiT保持；每次activeRun=none/reservedBytes=0。没有重启、减步或替代模型。`R4/lead/ltx25-representative-summary.json`绑定输入、revision、产物与终态。
- **真实产物与保存**：两份MP4均为H264＋48kHz双声道AAC，完整解码、精确97帧和AV时差检查通过。分别复用实际产物执行`VideoAVMediaInspectorTests/realSmokeOutputPublishesReopensAndExports`，文生1.796秒、条件0.191秒，各一方法通过；正式Store发布、保存重开、安全导出字节一致、输入原件不变。Store二进制为dba33e67022305793b44126a9b34a014b3967fe5加仅hosting诊断98dcb9ccf24d6241c68f8e4dbefc28e2c81e4832，相关Store/AV测试源码至6328d9c不变；不是新GPU运行或GUI通过。
- **观察限制**：Lead实际查看文生/条件视频的0、48、96帧。文生可见红杯木桌；条件输入为暗底红矩形，首帧对应，后续背景发展为桌面/立体红色物体，平面红色区域仍持续可见。不把这份合成例子写成通用画质、精确运动服从或真人音频通过。完整进程内存峰值unknown：一次运行中抽样的物理footprint和阶段Metal分配均不替代全程峰值。视觉来源记录`ltx25-{text,conditioned}-visual-source.json`。
- **条件效果定点复核**：非实现者对照固定上游提取目录，八份条件/采样/解码文件与准备site字节一致；代码将图片条件只放第0 latent帧，采样逐token mask保持，解码/mux未发现原图overlay。此为源码证据，不是实测mask/latent；不能仅凭它在“模型延续图形外观”与“尚未定位的数值/解码行为”间作最终判断。保留`ltx-condition-visual-review.json`与实际图像，不凭三帧宣布旋转/控制质量通过，也不无新假设重复昂贵生成。
- **最小互补验证**：驻留/条件改动先局部数值与原件/CPU边界，再完整正式请求和取消恢复；真实产物用于Store回放，不重复生成。Qwen/Dev/H3及Store的后续相关差分见`r4-evidence-reuse.json`，旧ACE/Klein/Wan有效结果明确沿用；不拼出跨版本总通过率。低成本、完整模型、Store、正常签名App、hosting、原生与本人结论分别保留。
- **交付与未完成**：正常签名App、唯一启动器和同树Xcode资源已准备，见RELEASE_FREEZE_TRY；未在锁屏期间启动交付App。模型即时投影与Wan完整目录服务已验，原生文件面板/刷新待H32；H22已具备实际客户端坐标诊断，但自然IME查询和指针覆盖来源尚无证据，缺陷未关闭；两项hosting实际动作失败保留。解锁后先做这些不依赖重新生成的检查，必要试听复用产物；H31与既有断网/录音不重开。
- **保护与来源**：`protection-after-models.json`逐项确认源HEAD、个人scheme内容/摘要/索引/未暂存状态及交付App四文件不变。自有LTX/Store进程和等待器均已正常结束，未关闭未知D；不是系统无其他任务的证明。实现由受限Sol切片与Lead完成，重要Lead差异有非实现者定点审阅；没有另一模型重复执行真实生成。完整Lead消耗、隐藏模型解析和实际订阅费用unknown，不重算历史用量。

最终文档提交仅更新六份获准活动/任务记录，实际代码/测试/引擎与6328d9c相同；最终SHA与候选推送核对写外部`R4/lead/final-receipt.json`，不为自引用追加提交。本轮不接纳保护源/main、不发布。停止在可用候选及原生待验的检查点；解锁后按唯一集中清单继续已有责任，不自动增加模型或新阶段。


### 讨论冻结接续（D-DISCUSSION-FREEZE-20261002，执行中）

用户任务书v1.0将W0—W5作为同一有限里程碑，明确新增文件管理与正常main推进授权。旧r4“不得main”是历史边界，现行规程已窄幅替代；不重置历史修复额度或将候选/质量/原生未验改判通过。需求包与校验在R/handoff；R=`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261002T062206Z-discussion`。

起点候选0555bacccd5eea2e57fb9d0946f1065deeded9d7；旧main708f5fbb7e5e78b5583c487a67329c0eeaf6e5cf，fetch后确认共同历史且0/1061。个人源01758b81527dc27eb4563bf1b66fd1ceab6647ee及scheme摘要/差分/索引保存R/lead/baseline.json与小型保护副本。候选起始干净，无本轮活跃写Worker。工具建立工作树因当前聊天绑定内盘空仓库而失败；未操作该仓库，按用户指定实际仓库用Git建立外盘干净main树D-DISCUSSION-MAIN。

W0/W1：仅核相关差分与接口，不全库重审。旧main准确归档标签archive/main-before-refresh-2026-10-02，独立D-main.bundle及六个已有历史子模块bundle均验证，原gitlink在各bundle可达。R/lead/main-backup.json记录范围；同SSD备份不称异地容灾，无未提交数据/外部权重。公开README英文/中文核心对等，准确注明已实现工作台、固定模型profile、引擎准备、开发签名与已知缺口，无项目级许可证新增。复用6328正常App构建/固定源码证据，未变模型不重跑；公开更新不等于原生通过或正式发布。

W4A冻结为固定模型实际所需树严格验证、额外内容不读不删，注册与后端入场保持一致；W4B在既有ModelLibrary/ProjectStore增加显式引用/独立复制、已知副本/内容版本与恢复/收纳；W4C一致快照手动备份与独立目录恢复。Lead拥有共享Store/契约，独立切片精确路径及运行设置另存本run任务包；初交＋最多两轮修复，后至多一次有界接管。任何新增功能先有真实失败/保护反例，再相应CPU/原生；不改数值/新模型/自动同步/数据库。W2原生取证、W3既有媒体完整查看并行准备，人到场事项只写唯一集中清单。

恢复：先核实际HEAD/index与个人修改，再读R/lead；本段写入时W1尚未提交，W4尚未开工，不据此宣称main已更新。后续精确提交/远端与进程状态写外部回执，避免自身SHA反复提交。


### 讨论冻结本地实现收尾（2026-10-02；原生/质量有明确未闭合项）

R沿上文。W1已先将公开main推进至b5004991e0323c976e4ba3f8bf55774b28222cb6，双语首页与旧历史归档/备份已经远端核对。后续受测组合为 **ca2121c771d6b7cd65a1d8f068440fdf7bba9221**；最终文档/远端SHA只写R/lead/final-receipt.json及会话回执，不为自引用再提交。以下是实际完成和限制，不是所有验收项关闭。

| 变更／风险 | 本次证据与结果 | 沿用／限制 |
|---|---|---|
| W4A固定模型必要树 | ModelLibrary只验证所选固定revision实际必要文件；外部README/cache/sidecar保留不读不删，受管副本仍严格。引用/复制入口接入原模型库，4MiB独立复制、取消/空间/摘要/发布/租约保护。64项模型库测试通过（44bf185，model-store-combined.log）；原始待准备资源允许备份，普通推理租约仍拒绝。 | 不是任意模型发现，额外文件不进入执行。新UI面板待H32。 |
| Qwen/Flux执行侧与登记一致 | 8份固定Qwen文件集注入常驻/SSD加载、tokenizer/template/processor；未知revision保留原严格兼容。Flux固定所需树传到文本/DiT/VAE/scheduler，无MLX跨层泄漏。cd4cd4b：35项Qwen/Flux+另23项图像目录检查通过。Dev原112,805,617,244B权重目录实际metadata/header准入1项0.076秒（f6fca9e）。 | Dev只读取固定32文件元信息/头；不冒称重新散列完整权重或生成。Vendor来源、精确补丁与许可均保留，MLX-LM全文件逆向来源核对通过。 |
| 读取变化的真实对照 | cd4cd4b：Qwen9原精度SSD四采样帧1方法132.339秒，正确先红后蓝；Klein BF16取消→完整生成→有序双参考1方法89.495秒，输入原件不变，每次释放active/cache0。Klein两个PNG分别与R3固定相同输入字节一致。 | 只证明该固定样本，非任意确定性。27B、Dev、LTX/H3、ACE/Wan未变计算/条件部分沿用上文精确历史证据，不全模态重复生成。 |
| W4B位置与收纳 | 已有资产ID/版本/位置分离，来源与历史固定；原位引用、独立副本、同版本定位、收纳到项目/独立库、在途快照保护。普通副本深检原先漏对摘要已用先红后绿反例修补380524b；旧未知I/O保留实际原因并标待核对，不假称缺失/权限失败。 | 默认概览不散列媒体；workflowState仍读取/散列≤32MiB流程快照。所选深检后深刷新有重复读取，不称零I/O。原件外部变化不回写历史。 |
| W4C备份/恢复及实际接线 | 一致快照、最后完成标记、默认不含模型/缓存、显式缺失清单、独立目录/instance恢复；音频→音符→和弦、嵌套工具与历史在源位置不可用后恢复通过。界面在备份前保存Canvas和Quick草稿，失败/取消/切项目拒绝。恢复实例拖放与最近列表不串旧项目。 | 文件服务18项先行；最终组合的UI28项/服务36项通过（files-final-cpu-02，12.579秒命令），不叠加历史凑总通过率。原生文件选择与NAS尚未验。 |
| E01有限观察 | f6fca9e的1000条53,199B索引：打开0.001742秒、20次标签筛选0.029276秒、100条标签批量保存0.001518秒，重开100条正确。 | 仅该开发机合成规模；不是文字输入性能、所有NAS或全项目无限历史的承诺。 |
| W2自然输入诊断 | 7722d4e仅DEBUG且显式session/trace开关；真实client自然firstRect透传一次，记录range/identity/坐标及NSCursor set/push/pop来源栈，不读正文；4000条上限会标证据截断。Swift6类型检查与非实现者审阅通过。 | 不是H22修复。自然查询、可见指针、关闭诊断后的真人对照尚无。裸NSTextView另开对照会改变焦点，不混作原路径。 |
| W3已有完整产物 | R/quality保留4份MP4原件链接、全部帧查看与请求索引。LTX文生接近静止、合成首帧红区域持续；H3首尾合成蓝帧明显切换，未宣布质量合格。 | 旧固定模型输出；真人音轨/审美未验。两条LTX提示不同，不算严格A/B。 |
| W3有界反证 | actual上游11文件相同；ltx-mask-probe-02在真实patchify/condition/sampler/X0Model上使用CPU固定速度替身：时间0被冻结，其他帧实际更新，尾部与无条件同seed对照相同，1.012秒通过。 | 排除被测mask/timestep/展平的跨帧误冻结；未运行真实Transformer/VAE，不解释全部画质。首试仅观察层BF16→NumPy不支持，转观察值F32后通过，生产数值未改。 |

#### 修复预算、审核与真实来源

Model导入Sol初交＋两修复后Lead一次有限接管（最深目录同步和raw backup接线）完成，额度不重置；备份服务Sol初交＋两修复完成。Qwen Sol初交＋一修复，修复的是未知revision兼容与测试临时根/文件选择说明。FILES-UI Sol初交＋两修复后Lead一次有界接管：39e43e4目录URL尾斜杠的路径比较、ca2121c显式MainActor回调隔离；原recent三断言和Swift6编译失败均保留，再复验通过。不是Sol独立完成，也不是Lead全部代写。修复1第一次因Lead漏列WorkflowController路径先暂停无实现，明确补范围后继续；不是偷偷扩大写根。repair2的rg错误路径及对已应用差异作forward检查失败不涉及权限扩大，reverse只读检查确认；每轮异常先核再集成。

重要Lead实现均由非实现者分别定点审阅，最终文件UI两项P2（取消刷新、备份未含草稿）与路径/actor注解无剩余P1/P2。只读审阅不等于另一模型重复测试。Worker实际独立受限CLI为gpt-6-sol/high、network关闭、各自工作树与输出缓存；请求、可观察路由、事件和补丁在R/{models,backup,qwen-files,files-ui}。隐藏服务端解析unknown。FILES-UI修复2墙钟647.120秒；该次增量输入2,326,353（含缓存2,238,848）、输出20,807，不能再把缓存加到输入；没有核算全部任务/Lead/订阅费用，不证明成本最优。未重算旧样本。

#### 验收映射与停止边界

- P01—P04：历史/main/双语首页/有限公开门槛按final-receipt核对；没有发布Release或改许可证。
- I01—I02及F01—F06、F08、B01—B02：固定目录/真实文件/组件与Store反例通过；I03、F07和W4完整原生点击仍待H32，不能把服务结果升级为用户操作通过。B03真实NAS未验。
- N01：工具能力明确；本轮最后一次桌面库存明确apps=[]、Mac locked（native-final-blocker.json），不自行解锁或重试。N02/N03尚无自然输入/指针根因及修补结论；N04是跨App线索，在D未复现，不能记成D已证实丢字。N05两项旧hosting未触达目标的失败继续保留，不能用28项组件通过抵销。
- Q01完整帧序列已看，真人听感未办；Q02得到有限排除证据，原因未定。E01/E02按上述规模与单一Store/运行时事实通过，非全配置性能证明。
- D01普通同版App构建/签名/入口由app-discussion-build-result与delivery-receipt绑定；锁屏未启动本包，也未点Xcode Run。D02中央清单更新H22/H32，不重开H31、录音、断网或资格问题。

恢复先核最终候选与main、源01758b8及个人scheme摘要/索引/未暂存状态。自有模型、Worker、CPU与构建进程终态以R/lead/final-receipt为准；未知旧D不关闭，不宣称系统所有进程结束。旧App/项目/权重/候选/证据保留。下一动作仅为同包原生与用户试用/冻结判断；本轮没有把锁屏和质量未知项改成完成，不启动新模型或发行。


**最终非实现者入口复核新增停点**：ca2121c没有发现该问题会改写/损坏数据，但`previewLibraryEntry`先pin并读取原件，唯一条目位置按钮在成功预览后；Quick原件失联且已有命名Canvas项目时，顶栏又指向后者，该Quick位置恢复页不可达。FILES-UI初交/两修复/一次Lead接管均已耗尽，本轮停止该项修改。W4B另有有限展示未完：仅本项目使用计数，缺导航关系清单/Finder/离线库聚合；显式深检不持久更新lastVerifiedAt，副本创建时间未独立显示。服务检查通过仍有效，**W4B完整用户闭环未完成**；不以公开开发门槛掩盖。上述无破坏性已知缺口在双语README、试用指南与当前行动明确标记，main可以正常更新，功能冻结不得据此通过。


### 2026-10-03 原生有限续修授权（授权时记录，结案见下）

起点 main/candidate `9586e35f6e3e2bb4c47432f2fa3132ab7c7b55a8`；证据 `run-20261002T160047Z-native-closeout`。用户明确再次授权 F1–F3 有限续修，不抹去上轮 FILES-UI 初交、两修复和 Lead 接管后未闭环的历史。Lead 负责 H22 现场、README、整合和验收；受限独立 Sol/high Worker 负责已知文件入口/核对/展示和对应局部测试，先只读预检再实施，普通初交及最多两次定向修复、必要时一次有界 Lead 接管。此次不新增模型/架构/权限。

桌面工具本次可访问；用户不能亲自组字/试听。H22 复用自然 firstRect 和 cursor trace，默认关闭；真实系统按键、控件替身与真人结果分开。保留旧 D 进程与数据。源个人 scheme 内容、摘要及索引起始快照见本 run 的 `lead/start.json`。受管工作树工具绑定内盘空仓而不能解析本项目 SHA，本次经核验无活动 Git hooks 后在正确外盘 Git 仓手工创建专属工作树；不操作空仓。

H22 首轮现场（ca2121c App，与9586e35代码一致）：自有PID56184/独立UUID，旧D37434未关闭。CUA单独pressKey(n/i)，不是AX填字或粘贴；中文ITABC及临时ABC均直接插入，15次client观察没有marked text/自然firstRect，未达到系统候选复现条件。输入源已恢复ITABC。原生zoom实际改变窗口，前后invalidate的responder/context与active client/context一致；没有发给另一输入对象的证据。现有cursor栈由同PID atos解到NSHostingView.cursorUpdate → NSView/NSTrackingArea → NSCursor.set；对象地址不等于光标形状，截图工具合成指针也不作系统光标证据。日志未截断。未建立原故障因果，不猜测替换TextEditor或强制光标；A/B仍未修，C未在D复现。诊断实例已Cmd+Q退出，旧D仍在。证据为gui/h22-diagnostic-summary.json、原日志和符号表。最小缺失是实体键盘建立真实候选后保持组字水平移窗一次，再看自然查询，不是新增授权。非实现者native_h22_diagnosis独立核对了证据限制。


#### native-1 初交与第一次定向修复（当时停点，结果见下）

受限 gpt-6-sol/high 初交已交回并由 Lead 按八文件提交为 `d27974b0762f272eafe4b8640087a351ca18027e`，仅进入 release-freeze 候选，main 未动。编译后 UI 18 项通过；Workbench 40 项中旧 `independentLibraryCopyAndSameVersionRelocation` 一项失败，不能因新默认轻检而删改显式深检断言。只读非实现者另发现：文件页核对后的 Session 刷新又散列其他媒体；同 inode 的项目副本移出后错误保留 projectCopy。合并为 repair1，保留初次失败。仅为这些反例新增允许 `ProjectSession.refreshAfterFileOperation` 的有限刷新区分与 `ProjectInstanceRoutingTests` 接线回归，不重构资产系统。普通修复两轮额度已使用第一轮，等待复验。

Lead 已用普通 ca2121c 包原生建立隔离 Quick 的 reference.png 外部引用和独立 Canvas-Closeout 项目。仅操作本轮夹具；旧普通 D PID37434 保留。模型库根目录已通过文件面板选择；嵌套模型菜单的自动点击未进入导入对话框，不能记作模型登记通过。自有旧测试实例57183已正常退出，等待同版新包执行完整 F4。


#### native-closeout 交付检查点（2026-10-03，工程通过，原生部分未验）

RN=`run-20261002T160047Z-native-closeout`，相对本任务AgentTrials根。起点main `9586e35f6e3e2bb4c47432f2fa3132ab7c7b55a8`，不是Dot旧快照。初交 `d27974b0762f272eafe4b8640087a351ca18027e`；修复1产品/构建版本 **1e2501faed39fab954bbb205bc556ea537916219**；修复2只改新增测试前置，最终CPU **43d6ab3e51583a31e7c8a08ac60911a6be9ddcce**。此后只有获准文档；最终main/远端SHA写RN/lead/final-receipt.json，不为自引用再次提交。

| 本轮项 | 实际改动/证据 | 结论边界 |
|---|---|---|
| F1 | SharedLibraryBrowser独立location动作；DualWorkbenchView按Quick/命名Canvas的Store+instance解析，不先pin/预览；顶栏跟随入口；位置/等待模态禁隐式生成；失败预览也可恢复 | 代码与组件通过，未宣称完整原生闭环 |
| F2 | ProjectStore.verifyAssetLocation仅核对所选位置，摘要/长度、前后fingerprint及实例/revision/磁盘manifest相合才提交lastVerifiedAt；失败取消不成功。默认概览轻检，显式asset deep仍检查该asset所有位置，保留旧契约 | 修复1纠正初交破坏旧显式deep语义的失败；不靠删旧断言变绿 |
| F2接线 | ProjectSession.refreshAfterFileOperation增加窄metadata-only区分；workflow.refreshAvailableAssets和refreshLibrary(false)只投影不散列媒体，真实新增/位置/内容变更退回原媒体刷新 | 真实Session接线测试在基线同步后破坏无关原件，核对另一文件成功/失败/取消仍保留缓存且无无关读取错误；新增内容反例仍刷新。不是新缓存平台 |
| F3 | 本项目graph/node、派生资产、run来源；图已加载可跳转，运行项明确不直接导航；Finder、已登记库离线聚合；原件/此副本时间区分。项目副本同inode移出后改为externalOriginal，不继续读缺失包内路径 | 只知本项目/已登记范围，未知创建时间不补造；新UI点击待验 |
| CPU | `lead/files-cpu-final-{command,result}.json/.log`：18项UI、42项Workbench均通过，命令7.191秒；过滤为实例/位置/文件呈现/资料库/备份/元数据相关检查 | 最终1个命令的两target结果，不叠加旧通过率。原两项offscreen hosting失败仍保留 |
| 正常App | `lead/app-build-result.json`：正常签名build60.159秒exit0；原资源六引擎由正常构建验证/嵌入，未构建后补provider。`delivery/D Native Closeout.app`及唯一启动器--check通过；无默认trace | build在1e2501f；与43d6ab3仅测试差异，产品相同。进程59433启动后CUA报Mac locked，未获窗口/点击证据，自有该进程SIGTERM后确认结束 |
| 已做原生 | 旧ca2121c/起点同代码包：隔离模型库根选择、小PNG的原位引用、命名Canvas创建/保存，任务Fixture数据已保留；自身正常CmdQ，未关闭用户旧D | MRT2嵌套菜单自动点击未完成登记，不是模型引用/复制通过；新包F4恢复/收纳/备份/重开未验 |
| H22 | 复用现有trace；15次client/context一致、natural firstRect0/marked0、未截断；同PID atos解出NSHostingView.cursorUpdate→NSCursor.set。输入源恢复；非实现者复核证据限制 | 不证明坐标正确或错误覆盖者，A/B未修；C未在D复现。需要实体键盘最短触发；没有强制光标/抢焦点/清组字 |
| README | 唯一同页EN→中文、双语标题/小字/显式锚点、旧中文兼容页，19+2本地链接和构建说明非实现者核对；公开浏览见最终回执 | 原生新截图未能固定到可公开文件；再次锁屏后不伪造或用旧界面冒充。图片项仍未完成，不影响本轮正常main开发更新 |
| 质量/模型 | 生产推理/资源未改，前文cd4cd4b/R3/R4固定完整模型和条件证据继续适用；四份完整H3/LTX视频原件/全帧/有限mask反证复用 | 本轮没有新推理、试听或质量批准；不以“慢/锁屏”为由降低精度 |

**本轮失败与来源**：Sol/high初交+两次普通修复，无Lead实质实现重写或有界接管。repair1解决非实现者提出的全媒体二次读取和移出项目副本角色，并恢复旧deep行为；实际CPU18通过，42服务中新增fixture一项7断言失败。原因是测试直接向Store导入两资产却未同步owner，正确触发内容刷新；repair2先建立真实基线并保留新增内容反例，只改该新测试。两轮静态非实现者复核没有剩余明确问题；Lead独立运行实际CPU和构建，未冒称Reviewer也执行测试。

受限CLI初交线程`01a0fd5e-0b5b-7c63-bde6-a25322fe38bc`，修复1`01a0fd77-d5ad-7571-9470-2fceb1113066`，修复2`01a0fd84-723e-7083-8698-81158b09b265`，请求/运行上下文均gpt-6-sol/high、workspace-write、networkfalse；WT为`D-NATIVE-FILES-CLOSEOUT`，输出/tmp只在RN/files，公共.git不授权Worker。逐轮route、process、event-review可核。repair2一次rg误拼日志目录ENOENT，修正只读定位；不是权限拒绝/成功越界。未读凭据/改全局/访问用户素材。三个写运行墙钟1236.57/383.29/251.51秒；末次turn增量输入439184（含缓存395136）、输出8747（reasoning4235是其中分类），不重复累计。完整Lead消耗、服务端隐藏解析、订阅实际费用unknown，不复算旧批次或宣称最优成本。

**恢复点**：所有自有Worker/CPU/build结束；诊断56184、普通前置57183已正常退出，新包59433锁屏停点后结束；旧D37434未操作。个人scheme内容/索引/未暂存状态和旧App四关键文件由最终保护回执核对；仅操作任务Fixtures，原模型/项目/候选保留。main获准正常接入、推送，当前图/聊天/新功能不在授权内。集中清单仅H22实体输入、H32桌面可用后代理原生和截图、旧视频本人质量；H31不重开。工程修补完成不等于功能冻结通过或正式发布。

## 2026-10-03 集中验收恢复与H22定点接管（进行中）

RH=`D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261003T015601Z-human-closeout`。基线a3c5b091de6e5af5bad0a1365d09ff80306d0cef，普通App代码1e2501f。用户返回后，诊断ON及同二进制/同session/单窗OFF均真人复现未确认拼音消失，H22-C现已在D复现；旧A/B缺陷不追认已修。用户要求用完关闭测试窗口/终端，已正常退出旧自有测试版37434和OFF实例64649，ON实例64007定点SIGTERM，真实数据/产物不删除。

Lead启动一次有界H22局部修补；允许仅QuickGenerationView的多行字段与直接回归，不整体替换文本系统、强制光标、抢焦点或清组字。既有TextSourcesQuestionEditor复用，以draftID+fieldID隔离所有者。新增QuickCompositionTests用实际QuickParameterField和真实QuickGenerationController/Store，原实现在无窗口变化、仅保存revision的对照下失败；两次失败分别11/9个断言保留RH/lead/h22-before*.log。后续同用例+所有者切换/Unicode/持久化复验及真人检查分别记录，不把hosting当真人。非实现者复核在Lead修补后进行；旧FILES-UI与Sol两轮预算不重置。本轮文件原生验收继续复用既有正常包/夹具，不重跑模型。

H22局部修补后，RH/lead/h22-after：UI实际hosting5项（含新增Quick字段与已有composition）和Workbench Quick19项通过，7.707秒；未跑GPU。新增用例先在未修控件失败，再用相同契约通过；附加草稿切换不串写和保存冷重开。此时仍待普通App真人与非实现者复核，不提前关闭H22-A/B。测试时HEAD为a3c5b09加本提交差异，不冒称旧提交原样通过。


## 2026-10-03 本人H22接纳与H32原生菜单有限接管

H22本人确认修补版鼠标不再闪回；候选窗不随窗口移动与Finder等苹果软件一致，明确按当前系统正常行为接纳。关闭H22，不以此推断所有系统/输入控件；先前ON/OFF组字失败与修补证据保持。本人证据RH/gui/h22-final-human.json。

随后H32登记菜单由本人实际复现：高亮约一秒消失、点击模型无反应，Lead的AX/键盘/坐标也不能打开子菜单。属于工程入口失败，不是账号/权限，已正常退出唯一测试PID66154。使用本次FILES续修尚未使用的一次有界Lead接管，不重置此前初交+两修复记录。ModelLibraryModel每400ms无条件发布相同snapshot；在35f373ad4973a0f1dee91c68ddb9f440f25c6520中仅对四个纯值类型合成Equatable并跳过完整相同快照，保留原generation/revision守卫、真实下载/复制进度、可用性与租约变化；未变导入策略、模型计算/精度、签名或项目schema。

最小检查：新增实际actor/model Observation回归。初版夹具空catalog被拒绝、URL目录斜线比较不当，各自日志保留并修正；正式未修基线model-menu-baseline只有两条预期空刷新断言失败。修后model-menu-after：UI 2方法/2suite（含原Quick组字）、模型库64方法/3suite、就绪2方法/1suite通过；代码当时为9baaHEAD加与35f373相同的实现/测试差分，摘要见RH/lead/model-menu-scope.json。不将三次测试入口冒充一个suite。native_files_review只读复核完整值涵盖与原守卫，未自行跑测试。普通App构建/原生菜单及后续文件闭环结果另行追加，当前不能由CPU断言关闭菜单。


### 2026-10-03 集中验收交付检查点（35f373，部分完成）

RH为上述human-closeout run。H22生产修补`9baaacbc74855aaa84fa03868e62a1676d882250`由本人接纳，非实现者native_h22_diagnosis复核；菜单生产/最终原生版本 **35f373ad4973a0f1dee91c68ddb9f440f25c6520**。RH/lead/model-menu-app-build-result.json记录正常签名构建exit0、50.3787秒。三个菜单相关CPU入口结果见上一节，不与H22或RN相加。RN/43d6ab3的UI18、Workbench42及未改模型结果复用，不重新生成。以下代码没有额外修补。

| 路径 | 本轮原生结果与证据 | 限制 |
|---|---|---|
| 菜单 | 本人报告修前高亮闪回/无法点击；修后本人到达文件面板，RH/gui/model-menu-human-pass.json | AX嵌套同名菜单选择仍会歧义，真人鼠标证据与工具限制分开 |
| MRT2 | external实例8E7EEEBC、独立managed实例BF29862C登记完成；6必要文件摘要相同、inode独立，源ordinary-note.txt保留、未复制入安装；本人亲自确认资格；Quick/Canvas当时可用 | model-copy-checked.json初次多余文件检查误用了extra文件名，其false不代表原件丢失；model-copy-extra-check.json纠正实际ordinary-note.txt，旧证据保留。没有模型推理 |
| Quick恢复 | 新fixture/reference.png原位引用；另有Canvas-Closeout项目，移动仅本fixture后从Quick条目直接打开缺失页→定位Relocated同内容→Finder→复制项目→正常冷重开并核对 | gui/{quick-missing-direct,quick-relocated,quick-collected,quick-files-cold-reopen}.txt。88字节PNG，原件/副本SHA cbce8e398b05835e0605e58b252ca13c8741637e7702431e82eca899516c369a，独立inode。非全媒体/NAS证明 |
| 草稿/备份 | Canvas新图/文字节点，未点保存；持久清单最初无标记。备份预检后标记已保存，原生NSSavePanel报`ProjectBackupError error 4`；Backups为空。冷重开原项目/文字成功 | gui/canvas-before-backup.json、canvas-backup-native-failure.{txt,png}、file-protection-after-native.json、canvas-cold-reopen.txt。**没有备份成功/独立恢复证据**。首次工具typeText仅插空格，改用paste并实际检查完整Unicode标记，不冒称实体组字 |
| 冷启就绪 | Quick提示待核验、Canvas MRT2/SwiftF0未知；已登记不能写成就绪通过 | 非实现者源码核清：会话readiness初始空，启动/状态刷新checkModels:false，完整资料库sheet才触发显式核验；Canvas嵌入列表不触发。35f首次snapshot必发布，actor核验绕过该guard；相关调用未改，非菜单回归 |
| README | 新35f实际Quick截图，合成文字/无账号、路径或私有资料，SHA见delivery-launcher-check.json；EN在前/中文在后/页内跳转 | 截图诚实保留冷启待核验。不是设计稿，不证明全App可用。没有为截图伪造模型结果 |
| 产物质量 | 本人旧四视频反馈及PCM/固定源码只读分析，RH/gui/video-human-review.json、lead/{video-quality-analysis,ltx-quality-source-followup}.json | LTX-text RMS -61.70dBFS、first -96.21；D无后叠图，candidate已含红块。上游`0 1.0 33`中的33为输入H264 CRF，不是33帧条件；仅首latent受条件，画质原因未全定。自然场景H3/有效LTX对照仍未做 |

**备份定点诊断和预算停点**：非实现者native_files_review只读确认同版二进制error4映射`.io(String)`，UI localizedDescription丢关联操作/errno。ProjectBackup.swift:139、149–150在target.parent创建兄弟stage，ProjectFilesView:442仅启用target授权；restore:260–261同类。该链从9586到35f无变，不是菜单改动引入；具体失败syscall尚未证实。最小后续是复用现有同卷itemReplacementDirectory导出方法及准确错误，同时保留nofollow/不覆盖/失败原件/发布后保留保护。**本次FILES初交+两修复后一次Lead接管已用于菜单，不继续新一轮修补**。现有服务测试通过不得抵销普通沙盒失败，未向用户要求全盘权限或父目录扩大授权。

**来源/交付/恢复**：原文件实现为受限Sol/high初交+两修复；H22和菜单为Lead局部实现，非实现者分别审阅、Lead运行测试/普通GUI，不冒称另一个模型也跑过。readiness/备份及视频源分析只读复核，没有GPU。完整Lead消耗/订阅费用unknown。新推荐唯一启动器为RH/delivery/menu-fix/启动D开发预览.command，App代码35f，`--check`签名通过，与同树D Nodes使用4DFA8D40试用身份；本轮实际原生验收在另外9F276A92隔离会话，未点Xcode Run、未验证4DFA现有资料。App/源个人文件/旧原件终态见RH/lead/final-receipt.json，最终文档SHA也写该回执而非反复提交自引用。

自有66154/67978/68398正常退出，先前ON/OFF及重复启动处理历史保留；Finder自有窗口关闭。工具禁止Terminal控制，无法确认启动器终端是否仍在，不以绕行技术关闭。无活跃Worker/CPU/build/GPU作业；不是系统所有未知进程均结束的保证。原模型/项目/普通App/旧候选/证据保留；仅本轮合成图移动。源个人scheme未暂存差异应与起始快照一致。

结论：工程修补/原生部分通过、本人事项当前办结；备份/初始化就绪/视频质量/剩余交互仍未完成。main获准按公开开发门槛更新，不宣称功能冻结或发行。到用户试用与冻结判断点停止，后续有限修补延续失败和明确预算，不新编号重置。


## 2026-10-03 稳定性→有门槛聊天续作（实施中）

源/候选起点3a2801abab22273256923ce1f3c14407515f20ce；RC为run-20261003T035843Z-stabilize-chat。用户本次明确新增有限A/Q续修授权，不抹除先前FILES预算耗尽。A1备份事务/错误、A2按需就绪分属受限Sol/high工作树，初交各含事先约定的诊断/实现步骤，最多两轮针对性修复及一次有界Lead接管；未经真实G1/G2不得实现B。Lead独立审核/CPU/普通App验证，Q先只读数据边界调查，重构建/GPU/GUI串行。A1先只补错误来源，在未改发布方法的普通包确认具体失败，再改事务。详细允许文件、规格r1和运行路由保存在RC/{a1,a2}；Worker不写此记录/公共Git/原件/模型/应用，不递归、不安装或联网。

G1为仅目标授权的普通App备份→测试源不可用→新实例独立恢复/冷重开；G2为不打开资料库sheet的当前模型/实际图依赖就绪，不假定登记即ready。menu相同snapshot保护不改；就绪检查不得轮询全权重。A验证后独立提交/接纳main再进入B；Q结果不以聊天抵销。旧H22/真人事项已结不重开。保护snapshot见RC/lead/start.json及scheme副本。


### 2026-10-03 A 中途检查点（尚未通过普通 App 门槛）

RC/lead/a1-native-before.json：普通签名42e7f3在仅经NSSavePanel选择的新目标执行，`create staging directory / NSPOSIXErrorDomain / 1 (EPERM)`，未发布。已定位为兄弟暂存越过目标授权范围；A1受限Sol按原定诊断→事务两个子步骤实现系统同卷暂存，候选4460f4c，尚待组合复验。无权限扩大。

非实现者复核发现G1还有真实入口缺口：备份保留Quick侧车，但恢复路由只开Canvas。Lead在f252a85新增命名项目的可选Quick owner，沿现有Store/组件/关闭与备份保存接线；不改schema、不导入覆盖全局Quick，不属于B聊天开工。审核反例的全局位置入口与项目切换过渡守卫继续修正。新增损坏侧车夹具先因缺少.dproject扩展被正确拒绝，44ddd63仅纠正夹具路径；不放宽生产校验。

A2受限Sol初交f036337未编译通过（资源标识符类型）；独立审核另发现旧书签ctime、取消指示、跨owner安装更换三项反例，repair1=dba6a10，正在按原测试政策验收。A1事务新增测试的非throwing闭包尚有编译失败，待原预算内repair1。所有候选尚未接纳main。

Lead一次证据命名失误覆盖了本run较早的诊断CPU文字日志；旧结构化结果已保留`a1-diagnostic-cpu-prior-result.json`，原13测试通过的工具记录仍在，新f252结果另存`a1-restored-owner-cpu-*`且明确失败。事件见`evidence-naming-incident.json`；不将新结果冒充旧结果，也不影响项目/模型/用户数据。后续使用独立证据名。

Q的小型阶段对照：官方现有音频编码→解码/声码器，另按生产BF16 latent重放→PCM→AAC，均有限且约−32dB，无整段零值；证据`q/audio-components-*`。只排除所测组件路径普遍静音，尚未定位完整LTX生成的低幅值来源，不计Q通过。A的G1/G2未过，B生产未开始。

### 2026-10-03 Quick 分类补充（B 范围，A 门槛不变）

用户明确：Quick 常驻文字/图像/视频/音频四分类；顶层仍为 Quick/工作流，Canvas 不分模态。实际 d82e135 树只有当前模型工作面与资料库切换，没有合适的四分类，因此 B 开始布局时补齐。分类只是导航/筛选：文字 VLM 图片/视频输入、其他模型全部已适配条件及视频音轨保留。复用现有 per-model drafts/runs、共享能力/运行时/Store，分类记住最近模型、草稿、附件、结果，文字记住当前会话；切换不取消、不加载、不下载、不提交。状态在控制器/存储，不保留四个隐藏输入器。不重新设计三类工作面；主要使用可控事件验证筛选、状态和在途归属，不重跑九模型。该补充不是 A 未通过时启动聊天的许可。

A 接线补核：项目 Quick 所属位置切换后，ModelLibrary 的异步选择回调还需固定 session/controller/draft 并在返回时检查；Lead 已做局部保护，未改变模型安装或请求语义。等待组合检查及非实现者审核。

### 2026-10-03 A 独立修补基线：G1/G2 已通过

普通 App / 最终相关受测代码 `8511718c472e788a8dcfc088eea0fde9dad050b3`；组合50项CPU在9a802b90通过，后续8511718仅将关闭屏障测试等待改为必需条件且单项复验通过，生产代码相同。普通签名构建58.348秒exit0，资源沿用R4，未手补provider。证据RC/lead/{a-combined-r2-cpu,a-close-barrier-cpu,a-combined-build}-result.json。

G1：原生仅目标授权的备份和恢复成功。未保存Quick/Canvas草稿与88字节PNG进入4文件小备份；退出后仅将本轮合成源移到保留路径，恢复为不同instance的新.dproject。原生检查Quick中文/组合字符/emoji、Canvas文字和媒体均正确，Cmd+Q后Cmd+O冷重开再次一致。原件/备份摘要不变；新全局Quick没有被导入覆盖。RC/lead/a-native-gates.json、g1-source-preservation.json及CUA截图/操作记录。跨盘rename首先被EXDEV拒绝、未改变数据，改为同卷保留加外盘证据副本，不扩大权限。G2：未打开完整资料库sheet，冷启所选MRT2由核验中至文件已核验，Canvas同状态；未准备模型仍明确未准备。跨owner、失联/版本变化/取消及合并检查用真实Session的确定性CPU补足，未重跑模型。

A1 Sol/high初交诊断+事务、repair1修复编译与原攻击时序；A2 Sol/high初交、repair1修复类型/ctime/旧结果与spinner。两者剩一轮普通额度，本次不再使用。Lead实现恢复Quick owner及关闭/异步归属；非实现者native_h22_diagnosis/native_files_review定点审阅，无剩余已知生产阻断。非实现者没有重复跑测试。旧失败与Lead证据命名事故保留，模型隐藏解析/完整费用unknown。

A当前可独立试用，允许正常接纳main后进入B。Q音频组件有限对照通过但完整生成的质量来源尚未关闭；整体冻结/发行未通过。所有A自有App/CPU/build/Worker已结束，Terminal受工具策略限制不宣称关闭。恢复前仍核对个人scheme、真实Git状态。最终main SHA仅写RC/lead/a-integration.json，避免文档自引用。

### B 启动与契约 chat-core-r1

A已独立接纳/推送main `f31dced209855722d2f04cc0fc8c5f6712396120`，RC/lead/a-integration.json。新B core受限Sol/high工作树D-CHAT-CORE，只拥有ChatState/ChatController、ProjectStore聊天侧车/备份局部、ChatTests；允许初交+两修复，详细冻结规格RC/b-core/spec.txt，不继承A余额或抹旧失败。Lead协调四分类与App装配。

最小行为表：切分类/会话只改持久导航；在途结果固定提交session/attempt/Store。编辑旧用户内容/再生成产生兄弟分支；旧路径保持。修改系统/模型/附件仅影响以后提交；请求使用固定完整选定路径和输入版本，超预算明确拒绝而不裁剪。停止等待Runtime释放，保留已收到的部分回答；重开将未终态标中断不续跑。未知/损坏侧车只读保护，保存失败保留内存和可重试产物；备份包含会话与已导入附件，恢复为独立实例。文字VLM图片/视频端口保留；图像/视频/音频仍用原Quick服务与控件。

B开始不改变Q与整体冻结门槛，未通过真实聊天路径前不作为用户交付版。输入组件复用H22安全宿主；不新增后台/数据库或四套输入/执行系统。


### 2026-10-03 B 候选接线与 Q 固定观察（未验收）
- A `8511718c472e788a8dcfc088eea0fde9dad050b3`普通App G1/G2通过；仅文档后main `f31dced209855722d2f04cc0fc8c5f6712396120`已正常推送，证据RC/lead/a-integration.json。
- B常驻四分类 `e57952ffc6278c9daa8c4cd7d97d2e07bdf4f21b`：Quick导航状态按类别记住模型/草稿，旧无navigation sidecar兼容，切换无submit。定向QuickCategory/QuickGeneration/ProjectBackupIntegration CPU通过，RC/lead/b-categories-cpu-result.json；不称聊天GUI通过。
- B-core Sol/high初交 `7130829082a70d303a09295ca7ace2da87dad2b5`（1458.98s，不含Lead/订阅费用unknown），受限CLI route accepted；无构建/测试。Lead提交并组合 `803ae9c0e75785e64f88aa063cf5410361080f91`。只读非实现者发现重复媒体、读取刷新CAS、重试pending、备份待发布、fork作用域、派生标题六个P2；core修复1解决其允许路径，Lead接线备份预检，剩余标题与编译反例随后合并处理；不是独立通过。
- B-UI按同一候选接口在独立树D-CHAT-UI、Sol/high受限CLI实现；精确任务/权限/模型/输出在RC/b-ui。Lead拥有DualWorkbench/ProjectSession、共享语言资源和依赖，Worker不改这些文件。
- 原生Markdown采用Microsoft SwiftStreamingMarkdown v0.7.0固定 `5f7c04e0558df6146f90d482edb62cb456986bda`，仅UI target；真实解析锁记录依赖（cmark0.9.0、swift-syntax603.0.2，区别于上游历史锁）。MIT等原文声明随UI资源保留，未改D许可证。无图片opt-in、禁外部openURL，原文始终保留。尚待本机布局/复制/性能检查。
- Q一次自然首帧请求源e57952f，provider相对A未变。只读非实现者核四hook各原调用一次/原值返回；不改精度/输入/随机数，完整30步、704×480、97帧24fps、seed42。记录RC/q/ltx-natural-boundaries-01与lead/q-natural-full-*，最长14400s程序回收。尚未有生成结论，不因观察数据当作修复。
- 当前仅候选，不接纳B至main。保护A App、源个人scheme和旧证据；无新本人动作。CPU/构建等等待Q独占结束，不能叠加旧通过为新通过。


### 2026-10-03 B 组合源码复核检查点

core初交7130829、两修复0c15f5f/2fb1f41已合并；六项原反例经native_h22_diagnosis在2825e27源码关闭，含Lead实际备份屏障；普通修复剩0。UI初交7737c39、修复1e12a94a已合并，四项生成门禁/错误归属/SDK检查/空Markdown问题经native_files_review源码关闭，普通修复剩1。两条受限Sol/highCLI均已结束，实际设置/权限和运行时间见RC相应process/route记录；无新Worker派生，无独立行为验收宣称。

Lead后续7ff155a/05e637b处理用户分类要求的真实边界：临时数值状态在原ChatController按会话保留；显式模型替换才清除其旧参数文本，普通键入不清；文字内“聊天/单次生成”复用原Quick，旧Qwen模型显式到单次，不能静默继续另一聊天模型。其他三类仍直接复用，Canvas不拆分；设置内容有界滚动。此处属于Lead实现，不追记为Worker独立通过。新增兼容/实际服务门禁反例待CPU；非实现者明确源码检查不代表GUI。Markdown发布为实际text/markdown/.md，沿原Store校验和导出；原文/远程资源禁用保留。

组合05e637b尚待CPU/编译/普通App真实多轮附件/聊天独立备份和原生操作。Q程序运行自然LTX完整请求后再运行一份语义相容H3首尾；原模型/数值/生产provider未变，观察hook不改变返回值。A独立f31仍可用，main未接纳B，功能冻结仍未通过。RC/lead/b-review-checkpoint-2.json为中途索引，恢复先查真实Git/进程，勿重复提交生成。

### 2026-10-03 B 编译与CPU门槛（原生仍待验）

1cea585仅修ChatController.load的catch变量遮蔽（self.error）。Lead使用core唯一有界接管，未增加Worker轮数。初次CPU的4个Chat方法/11断言失败源于夹具：emoji每个15字节（40个600，512字节标题34个510）；普通文件WorkflowAssets实际是终止型unsafePath，非可重试I/O。92e5528改用自有真实目录0500，require pending且检查精确EACCES包装，defer恢复原权限；另保留普通文件保护反例。随后取消夹具单waiter被执行/取消双等待覆盖，产生continuation misuse；仅停止自有CPU组并保留日志，855d1a3用等待数组匹配既有RunCompletion，不移除生产drain。以上由native_h22_diagnosis独立核对依据，旧失败保留。

afc72101锁文件由真实Xcode解析：Markdown依赖与已测UI包一致，已有共存pin未变，远程mlx-swift-lm被省略是原有Vendor局部包覆盖，不是更换计算实现。native_files_review另发现旧命名Quick项目没有首个聊天入口；Lead55fcbaa7只在保留项目Quick时保留已加载的空chat，不提前写缺失侧车。真实ProjectSession反例修前require失败、修后通过，非实现者复核关闭。

最终受测代码 **55fcbaa74921007a3768ed8d94a4c896e2989297**，RC/lead/b-combined-cpu-owner-result.json：exit0，18.25秒；DWorkbench45方法/5suite、UI5方法各自通过，不累加历史数字。覆盖四分类状态/在途归属、会话/附件/分支/取消/保存与备份、Markdown导出不覆盖及呈现门禁。单作业峰值344MiB，没有App/GPU运行。原生输入/真实多轮/普通聊天备份待验；CPU不替代这些门槛。

主线仍A/f31；Q固定作业继续，未因CPU夹具问题重跑模型。下一动作：Q结束后组合普通签名构建及B原生最小闭环。证据索引RC/lead/b-cpu-gate.json、b-core-lead-takeover.json；恢复仍先核真实版本和自有进程。

### 2026-10-03 B原生构建停点与Q边界结果

普通Xcode构建b3e2abc6在编译前exit65（6.39秒），需要首次启用固定EquatableMacros；不是生产编译错误，不消耗Worker普通修复。非实现者native_files_review核597c2bb的宏目标生成Equatable/Hashable与诊断，未发现文件/网络/额外进程副作用。未跳过宏校验或修改信任配置。CUA恢复后明确报Mac locked，H33和解锁进入唯一集中待办；旧H22关闭状态不变。B App尚未产生，CPU55fc通过不能冒充原生/真实聊天通过。

Q自然LTX完整BF16/30步/97帧生成exit0、9780.49秒。四阶段观察各调用一次且原值返回：latent BF16 RMS1.2295，mel BF16 RMS6.5836，vocoder waveform实际BF16 −33.962dBFS，PCM16 −33.966dBFS，AAC解码 −34.018dBFS；非有限均0。PCM→AAC只差约−0.052dB。输出aeb4ad04da07492fcac17e33525d1297b5a7219bf990c30d941f81e13498009b；非实现者独立核查数值。Lead读取0/12/24/36/48/60/72/84/96帧：倒水后水流停止、液面沉静，未见参考画面整段不动。上述只证明本请求链没有坍缩，不足定位不同旧请求−61.70/−96.21dBFS的根因，也不是人耳声音/同步验收。证据q/ltx-natural-boundaries-01/evidence/summary.json、lead/q-ltx-contact-sheet.json。

H3固定自然首尾请求两次在模型运行前拒绝：第一次缺task/cache，第二次缺LTX2_GEMMA_MAX_LENGTH=1024；旧result只记录首次失败，第二失败由独立command/log/result记录。Lead保留原目录，普通复制同一request和两图到task-attempt-3，补生产环境与唯一tmp/cache；native只读审核确认静态参数/路径要求，未预宣称模型admission通过。新执行沿原50步/全50层BF16/seed42，不是随机抽卡或重新生成不同样本。lead/q-h3-final-preparation.json、q-h3-final-preflight.json及q-h3-natural-final-result.json（仅实际结束才存在）。没有修改生产provider/模型精度。

### 2026-10-03 本人集中办理后：B原生部分通过，长流拒绝接纳

**版本**：A main保持`f31dced209855722d2f04cc0fc8c5f6712396120`。B普通App/本次原生受测`7754a2b70f3e761ef30b45fe3c5ba76bf12b817a`，相对CPU受测`55fcbaa74921007a3768ed8d94a4c896e2989297`仅文档；最终追加记录的候选SHA/远端状态写RC/lead/b-native-closeout-receipt.json。本次没有追加产品补丁、重新构建或重跑已经通过的CPU；不把记录提交当成重新验收。

| 固定检查 | 实际结果及边界 |
|---|---|
| 本人办理/正常构建 | 本人信任固定EquatableMacros、登记Qwen3.5-9B Q4、显示聊天、取消Go To/导出面板。普通签名构建exit0/79.033秒，App四关键文件在原生操作前后摘要/大小/mtime一致。RC/lead/b-native-after-trust-result.json；旧exit65不删除 |
| B-N1 四分类 | 鼠标进入文字/图像/视频/音频并查看实名筛选；Klein BF16草稿/参考控件、Wan T2V、MRT2音符和和弦入口可达，往返保留草稿。分类切换不触发模型；没有重跑九模型或把T2V改称I2V。旧单次文字入口仍有CPU/源码证据，本轮未完整原生走查；MP4附件往返未验 |
| B-N2 真实多轮 | Qwen3.5-9B Q4 revision`8b2b98c00a6b4d291155e4890773ca8f769aee53`，resident/显式15GiB，TXT+PNG三次短回答均completed/stop，37/7/16字符；第二次生成时切图像页再回来，结果保持提交会话。输入2048、前三次输出192、temperature0.7/topP0.95/thinking off；不是原始BF16/27B能力验收 |
| B-N2 长流/停止 | 后两次输出上限1024，均`partial/consumerTooSlow`，保留633/562字符，没有finishReason；点击切会话的工具调用曾耗56.30秒，原生停止尚未验证通过。选中叶/分支在磁盘正确，旧AX未滚到底不能算消息丢失。RC/lead/b-native-long-stream-failure.json；不增加缓冲、放宽失败或反复生成到偶然成功 |
| B-N3 候选/来源 | 编辑旧用户消息产生兄弟分支，返回旧路径；再生成保留旧候选。系统提示与“中文试用”预设进入后续请求；保存回答为素材、显式送工作流新增资产节点并保存，没有自动执行下游。原生Markdown/文本导出只含所选路径，分别360/348字节；覆盖拒绝复用CPU，没有声称本次原生试过覆盖 |
| B-N4 原生呈现 | 同一9955字节合成Markdown，表格/公式/高亮代码可见，代码复制到未发送草稿、跳到底部END-SYNTHETIC-24、原文开关与完整复制通过，落盘内容和原文严格一致。SHA256`11f75b66e2070c1d6ac1e2c93e04a1f2d0de00b366aca8fcf8f6eaba70b9f0d9`；不调用模型。最小尺寸设置/非法数值往返、聊天宿主真人组字未验；不重新打开已关闭H22 |
| B-N5 普通沙盒备份 | 2会话、9消息、5次尝试和6份资产进入原生备份，含两次partial；退出后仅同卷移动自有原测试项目至保留名，独立恢复为新instance `EF885B9A-5AF6-425E-91E6-20250FF2E53B`。会话/配置/分支/资产字节一致，原件与备份不变；普通退出冷重开、PNG预览、新的未发送Unicode草稿保持。RC/lead/b-chat-{source-preservation,native-backup}.json为中途证据，最终结论见b-native-final-acceptance.json |
| 文件面板限制 | 本人取消时观察多次Go To，可能由自动重试叠加；随后只操作一个面板，导出/恢复成功，不直接断言产品重复弹窗。冷重开列表的.dproject灰色，普通Go To完整路径后Open启用并成功；数据恢复通过，列表选包入口未关闭。非实现者核A/B的WorkbenchModel:765、整个Info.plist及类型/权限无差异，实际过滤/包判定原因unknown；未改UTI/权限或项目文件 |
| Q固定样本 | H3 attempt-3 exit0/2132.65秒，原始BF16张量+F32组件、全50层/50步，512²/22帧24fps，输出`7fa32f28987abe135c010405cf8f395b2a4eef114dad69191cffb0eadd0f67d3`，带32kHz双声道AAC。本人确认该样本与LTX自然样本“两段视频都正常了”。未重跑；固定样本观感通过，不补造旧近静音首异常层、不代表B App视频生成入口或全部参数质量 |

**问题定位与来源**：只读非实现者native_h22_diagnosis核Runtime沿用256事件有界队列，WorkflowServices在MainActor逐delta发布，消费者落后时按既有契约终止并清理；ChatController保留已消费部分，不伪装正常结束。尚无时序证据判定具体堵塞来自布局、切会话或保存；流式时未做Markdown渲染、保存有约2秒checkpoint，不能简单归因库、模型或16GiB。native_files_review核文件面板，不是新增独立测试或生产修补。证据b-native-readonly-review.json、b-native-open-panel-review.json。

**预算/停止**：core初交+两次普通修复+唯一Lead接管已使用；UI尚余一次普通修复，但本长流跨共享消费/界面边界，不擅自改名计入UI预算。没有追加实现或第三轮Worker。下一有限修补应先定位长流与响应迟滞、保持取消/释放和partial契约，再复验原生长流/停止；文件选择过滤单独定点。待用户审计决定，不据此自动开工。

**恢复与保护**：本次自有95339/96335/96473正常Cmd+Q后均结束，pgrep无D；Finder自有b-chat窗口关闭。Terminal受工具限制未操作，不能宣称关闭；若本人仍见已完成启动器窗口可关闭，不影响证据。候选仅四份记录差异，旧源个人scheme仍orderHint1→6/未暂存/原索引，SHA256`ca3635d88aa5a15397b90e528667c66c0e6db7e596176e885c79d194b544206c`；main和普通App/模型未动。B测试原件/备份保留，不清理。证据核对脚本初次在系统Python使用不支持的zip(strict=True)，写入前失败；改为等长断言+zip后全部比较通过，仅证据脚本兼容修正，不是产品缺陷。完整Lead用量/订阅费用unknown，不重算旧样本。

**交付结论**：A修补已独立接纳，Q固定样本已获本人确认；B组件/短链/恢复部分通过，长流门槛失败，不能称B完成或功能冻结。唯一推荐稳定入口仍为A，B App与同树Xcode仅供审计；最终记录/分支同步后停在用户审计点，不合入main、不发Release。


## CHAT-PRODUCT-20261003：完整聊天专题启动

2026-10-03 用户明确批准附件 v2.0，F01–F36 为固定清单，S00–S06 连续推进。附件原件/摘要及保护快照保留于 `/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261003T115108Z-chat-product/inputs` 和 `lead/initial-state.json`。当前候选40d51ee/main f31dced，完整值见当前行动。旧最小聊天和停止预算记录保持历史；新批准修复不能解释成旧 Terra/Sol 独立成功。共享契约由 Lead 实施、非实现者检查，写任务沿用受限 CLI。

最小工作包：S00 Lead 负责有界无损消费、取消与新候选/旧参数重现；panel Worker 仅项目类型/面板和直接 UI 测试；S01 view Worker 仅聊天展示和呈现测试，不改存储/Runtime。各新工作包初交+两轮同因定向修复，最多一次有界 Lead 接管；两次同因无进展换方法并记录。源模型与实际输入/精度不改。

选择依据：Swift Async Algorithms Channel 的 send/取消语义需显式处理生产者等待与运行取消，不直接把 send 返回当成功；D 当前 Runtime 保持标准库依赖。项目过滤优先验证 `.data` 默认类型与 `.package` 注册差异，不放开全部目录。LibreChat v0.8.8 / Open WebUI v0.11.4 / LM Studio 官方交互只参考；Open WebUI 含品牌条款，不复制源码/资产。D 保持四分类、一个 ChatController、一个按需检查器和稳定输入身份。

出口仍为同版普通 App、真实长流/停止与原生选择，分层报告；未验不接纳。后续 S02–S06 在同一批准范围，不因分片而延期。

### S00候选与S01并行展示（2026-10-03）

RCP=`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261003T115108Z-chat-product`。主候选起点`40d51ee73f72eb54407e6eedbd693c9ba67068e4`，准备提交`0a5d4fde051f78c2d4d11aa86f2be9796b3991b7`；main仍`f31dced209855722d2f04cc0fc8c5f6712396120`，未接纳本切片。

- **长流根因和修补**：固定256事件生产缓冲遇MainActor逐事件处理时会失败。实际WorkflowServices/Runtime慢显示反例先报consumerTooSlow；保留原容量，改为有界等待，并由非MainActor收集完整文本、80ms向显示发布累计快照。取消停止生产，继续排空已接受前缀，等待release后公布权威终态。没有宣称上游MLX/GPU token流也已改成背压；其既有maxTokens边界不变。峰值/等待/显示次数记录在结果元信息，非全局遥测。
- **审查发现并修复**：unfolding在首次next前已取消时可能不进入pull；新增InferenceEvents只对Runtime pull安装外层取消，旧stream构造保留原有取消责任。先红后绿保留；另补取消发送者被唤醒后再次取消导致空槽未交接的反例。原TextDraftSession取消计数出现回归，`b8ae14c5d8f6e362c2d5646304abe8c4c429b284`修复，不改旧断言。
- **候选/重现**：新候选使用新seed；旧请求重现使用原node/messages/inputs/system并保留来源attempt。菜单分开且保留当前未完成参数草稿；历史无seed不冒充重现。非实现者发现重现误受当前无效字段阻挡，先补真实Controller失败再修，最终代码`457cb9a04178f6a9f01a41bd84607119a158d5c7`。不承诺同seed跨设备逐token完全确定。
- **文件入口**：panel受限Worker修正.dproject默认动态data推导为明确package过滤；3入口复用同一类型来源，不放开全部目录、不改Info.plist/签名。独立提交`700a999fa409bbaed23df9217ea323cda4d8597a`，合并`a7225dcb57d6ebea65584b3a15ae9339616311b4`。CPU类型对照与声明检查通过；真实列表选择尚未通过。

| 验证 | 实际版本、结果与限制 |
|---|---|
| Runtime/取消 | b8ae14c5：104方法/19suite通过；包含首次拉取前取消、有界慢消费和64个发送者交接交错。不是穷尽调度，也不是GPU证据。RCP/lead/s00-runtime-compat-result.json |
| 组合消费者 | b8ae14c5：DWorkbench90方法/7suite及UI包类型2方法通过；实际WorkflowServices处理2048个Unicode片段、受控慢UI、原文持久化与最终预览清空。RCP/lead/s00-combined-cpu-r1-result.json |
| F07/面板UI逻辑 | 457cb9a0：Chat16、UI8分别通过；不把重复覆盖相加成独立总通过率。RCP/lead/s00-actions-final-result.json |
| 普通签名构建 | 457cb9a0：exit0，71.863秒；已有宏信任和固定开发引擎复用。独立完整App复制后deep/strict签名检查通过，四关键文件摘要留s00-packaged-app.json；未改包后补丁、未跳宏校验。 |
| 原生/真实模型 | 桌面工具明确Mac locked。未启动此包、未跑本轮GPU，长回答/停止/项目列表选择待解锁。H32集中收纳；旧H22/H31/H33/菜单/自然视频证据不重跑。 |

来源：Lead实现共享消费者及F07、执行测试；非实现者`native_h22_diagnosis`只读审核并提供上述反例，不冒称第二模型执行过测试。panel为可观察`gpt-6-sol/high`受限CLI，初交+一修；S01同模型独立树，初交首审发现宽度、sheet并存和夹具不足，一修进行中。每次路由/写根/网络关闭证据在对应`*-route-accepted.json`；隐藏服务端解析unknown，不继承全访问冒充隔离。

过程失败保留：早期证据驱动参数键误用，一次包装退出但自有Swift检查完成，后以正确受控超时重跑同一反例；新UI测试曾误修改不可变node，已改为构造独立旧记录，未改产品保护。panel首次探针仅构造NSOpenPanel即遇XPC退出，未展示/越权，修复前已审核并禁止继续原生探针；S01报告ps被拒绝，未提权或重试，精确命令未取回，不补造无事故证明。详见RCP/lead/harness-setup-events.json、panel-first-review.json、view-review-before-repair.json。

恢复：候选W与panel/view独立树保留；普通App、模型、旧项目及源个人scheme不动。S00独立启动器仅用于待验候选，不能标成稳定main。S01交回和审核完成后再装配；正常App门槛通过前不接纳main，不开始新存储/工具生产接线。完整F状态只维护CHAT_FEATURE_LEDGER，不归回发布后。Lead完整费用unknown，旧费用不重算。


### CHAT-PRODUCT：S01定点接管、锁屏检查点（2026-10-03）

S00没有新增实现变化：代码/App仍为`457cb9a04178f6a9f01a41bd84607119a158d5c7`，后续W提交仅记录。只读复核确认F07冻结重现仍经原WorkflowServices/请求校验，当前参数草稿不会篡改历史请求；普通break放弃InferenceRun仍须显式cancel，是已有契约，不宣称迭代器析构自动释放。已修A、H22、宏信任、账号和固定自然视频证据沿用。

S01受限Sol/high初交、修复1、修复2分别679.58/661.15/548.879秒，均为各自进程墙钟，不含Lead、审核或订阅费用。最后Worker版本`3f0b51031048b8c913e921a29b1426a799e1afc2`；初交及两修未独立满足边界。Lead唯一有界接管保留`4101afcd…/86cf75f0…/9e780b81…`历史，最终独立候选 **`3e86f12a184f12b6ec11c22494af92ebfe8f559a`**，未合W/main，未打进S00 App。

- 非实现者指出offset隐藏仍可输入、A→B→A迟到滚动缺票据；Lead使用本地NSHostingView真实可见状态、唯一访问票据，保留同一编辑器，无强制焦点/清组字。首次16项通过后新增真实ChatWorkbench缩放反例失败；不能用组件通过掩盖。
- 普通NSTextView/NSWindow同宽度缩放通过，真实宿主1300→1290保焦点，→1273失焦点。仅在测试窗口override makeFirstResponder取栈；短暂局部状态输出确认visible true→false→true，settled时看起来仍显示。第一次“只避免重复setter”仍失败，旧日志保留，撤回重复false是根因的判断。
- 最小修补去掉检查器第二份打开状态，resize只决定inline/overlay；显式关闭仍真正hide，重开不抢焦点。sidebar宽窗重开同步已展示标记。非实现者又指出窄pane→详情仅清queue而未关实际pane，present统一先closeNarrowPanel再开详情，inline不关闭。只改本任务两文件，未改旧输入组件、Store、模型或数值。
- 最终`RCP/lead/s01-view-final-result.json`：exit0/9.732秒，18方法/1suite；包含真实host marked text、原生普通控件对照、显式隐藏/重开、滚动票据、空态/长Markdown/部分失败/流式/附件/窄窗。运行时HEAD为9e780b81+已记录差异，随后3e86f12a提交完全同一内容，文件SHA对应见s01-final-submission.json。未声称在提交生成后重跑；旧失败日志不删除。
- 临时诊断输出/trace已移除，证据留`s01-focus-stack.log`、`s01-visibility-trace.log`、`s01-visibility-fix-result.json`；全套通过中仍有AttributeGraph cycle，未解释，不隐藏。离屏渲染PNG不适于视觉判定，不作为真实界面截图或美观通过。窄pane预览/重命名、真实鼠标/滚动/组字均待普通App。

来源为“Sol初步布局＋两轮修复，Lead定点接管，非实现者只读复核”；Lead同时实现与执行验证，不冒称独立模型运行过测试。未新建Worker轮数或重置旧预算；之后实测发现需按新反例继续定位，不反复同因盲试。

**后续只读准备，尚未接线：** F12复用已固定swift-jinja 2.3.2 AST与transformers 1.1.8 per-call literal模板；未知变量默认空的行为需显式作用域校验，不修改模型目录。F20/21现TextSourceReader仅TXT/MD UTF8≤512KiB，版本/来源和Store可复用，PDF/DOCX/检索/备份新数据尚无实现。F26候选SearXNG JSON+Mozilla Readability（需DOM，不仅JSC）；F27用明确Swift运算/Foundation/TabularData；F28候选CPython WASI+Wasmtime实际预开放目录/fuel/内存限制，未安装或证明隔离，无裸Python回退；F29官方MCP Swift SDK，未固定依赖或接服务，roots/注释不作权限。官方来源及适配差异见RCP/lead/future-source-preparation.json。这里不是把未实施功能记完成，也不增加新平台。

**恢复：** H32已询问解锁一次，未收到新状态，未重试GUI；S00本轮未启动、无GPU生成。所有本轮Worker/CPU/build结束；当前保护结果及最终W SHA在RCP/lead/chat-product-checkpoint.json。解锁后先S00普通App真实长回答/停止/项目列表→独立接纳；再组合S01并保留F07 W改动，继续S02–S06。新存储/工具生产接线等待可靠接收边界，整个F01–F36仍是同批批准范围。main不变，不称专题完成、功能冻结或发行。


### CHAT-PRODUCT：2026-10-03集中原生验收（未改生产代码）

起点W=`b46f0c0cc4c160208431faaffd560eafef42857f`；同一普通签名App代码=`457cb9a04178f6a9f01a41bd84607119a158d5c7`，未受影响CPU/构建不重跑。RH=`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261003T134350Z-chat-human`。本轮只更新四份现行记录；最终文档SHA见外部回执。未把文档提交当新受测代码。

- 本人解锁后实际Finder/D可访问。原9消息/5尝试的旧测试项目逐文件保留，只在独立副本运行。Cmd+O→定位父目录→列表选择`.dproject`→Open启用并打开，关闭旧列表灰色缺陷；冷重开同路径继续成功。登记既有Qwen Q4及“用于当前项目”均由代理原生完成，无需新增下载或本人资格声明。
- 最初仅登记未选“用于当前项目”，旧会话目录绑定缺失明确报错并保留一次failed尝试；随后从现有入口绑定同一固定版本并恢复原参数，未篡改旧attempt。保留notes.txt+pouring.png、原两轮路径、2048输入/1024输出、temperature0.7/topP0.95、thinking off、262144像素、resident/15GiB；原图SHA匹配。旧seed缺失时重现菜单disabled；新候选记录真实不同seed。
- 三次真实长回答分别1434/1483/1574字，均1024 deltas、finishReason=length，正常保留partial而非虚报100条完成；其中两次原为停止测试，但AX查找失效或本人未找到按钮，没有发生有效停止，不称三次计划性能基准。Runtime容量仍256、等待/峰值指标按真实值记录，没有通过扩大buffer过测。
- 有限换方法：旧AX索引停止调用35.804秒后invalidUIElement；改截图定位坐标点击，调用5.185秒返回，attempt `A8FD1A7A-67D9-4F0A-9C01-586EBA3C3D4E`取消并保留568字。随后同一App生成两条标题，attempt `20ADBE4D-14B8-4127-82E0-7F5111EF6C7B`正常completed/stop；证明本次取消终态与接续，不以调用耗时冒充精确drain时长。停止错误显示仍是原始CancellationError，留可读状态改进责任。
- 未关闭：第一次候选Menu点击后120秒超时，主线程1402/1407采样在SwiftUI transaction更新，磁盘未增加attempt；非实现者只读检查未见MLX/Runtime执行栈，不能归因模型或16GiB，也未唯一定位控件。直接用户消息“生成回复”可运行同一regenerate回调，不能据此覆盖Menu失败。生成中AX切空会话40.645秒，最终归属正确但响应迟滞未解释。用户表示未看明白停止按钮、没有任何动作，不记真人停止通过；可发现性并入已有F15/F36，不另造功能。
- 来源：Lead独立执行原生/真实模型验收；native_h22_diagnosis只读提取冻结输入并看样本，native_files_review只读核对待办及最终四份记录，并直接核对持久attempt状态；两处措辞建议已采纳，未声称他们执行测试。未修改生产代码，未重算费用、未再派写Worker。S01 VIEW候选仍未装配，本次不重开H22或重复宏/账号/视频等本人事项。
- 保护和结束：自有11225忙循环留样后SIGTERM，12161及最后测试实例正常Cmd+Q；本轮未打开Terminal窗口。原项目26文件352751字节及个人scheme内容/索引/未暂存状态不变，App四关键文件不变。没有改普通App、模型或原作品。过程/结果见`native-observations.json`、`long-stream-observations.json`、`s00-native-hang.sample.txt`、`protection-end.json`。

恢复检查点：项目列表、定长无损接收、坐标停止→下一请求有新原生证据；候选菜单/AX响应问题未修，S00整体不接纳main。main仍`f31dced209855722d2f04cc0fc8c5f6712396120`。当前无必须本人立即办理的事项；先按样本定位，修后只复验受影响路径。S01新宿主实际组字留装配后的集中项。完整F01–F36仍为原已批范围，但本次停在用户代码审计点，不宣称功能冻结或发行。

### CHAT-PRODUCT续作：同一F01–F36冻结范围

用户2026-10-03授权连续完成S00–S06，不重置历史失败。起点候选5c6b0ba4ddb7283b8cf19b61d37d57d64742fa97、main f31dced209855722d2f04cc0fc8c5f6712396120、VIEW 3e86f12a184f12b6ec11c22494af92ebfe8f559a均核实。本次证据`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261003T150039Z-chat-continue`。先以已留样本和可控流定位候选菜单忙循环/AX迟滞，固定输入区停止；再组合VIEW，保留F07与输入/数据语义。允许路径按既有Chat、受影响Store/Runtime/服务和对应测试逐包签发；共享契约由Lead协调。只读定位并行，写Worker继续独立受限CLI；GPU/构建/GUI串行。已验1024-token长生成、H22/账号等不重复。旧预算保留，本次已明确批准缺陷不得因旧额度耗尽永久停工；同因两次无进展改变定位方法。


### CHAT-PRODUCT-20261003 续作检查点：范围不缩减（2026-10-04）

证据R=`D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261003T150039Z-chat-continue`。本段只追加实际增量，完整状态仍为CHAT_FEATURE_LEDGER。

- `263857f113c20de36c5a347423cd12e3e6de5c76`模板/预设/比较；`6bca3bbba297e63fa26a927ccc4bb04e3b184e37`系统Speech接线及关闭；`4ae52508d38a1cbd3db8a227e1a3bbe4aacd7d25`个人/项目记忆、手动摘要、真实工具活动与上下文采用。共享控制器与接线为Lead实现，独立纯服务为受限Sol/high初交/记录中的有限返工；非实现者定点源码审核，不称另一个模型执行了所有测试。
- CPU证据：memory-product-wiring编译/定向通过；memory-review-r1 38项/2suite通过；s04-components最初真实Foundation编译失败（枚举重命名），r1发现乘法静默舍入与Unicode ZWJ被误作控制符；修补未放宽原断言。工具worker初交+两修后Lead保守十进制有效位预算修补；WEB worker repair1使用C0/C1标量规则保持组合字符。
- s04-wiring首编译捕获Sendable错误，标记局部helper后修复；r1仍只有已知WEB版本Unicode失败。r2 21项/4suite通过119.65秒；r3 5项通过17.64秒，精确验证采用后网页附件仍恰好存在。测试于2b9e75c5+对应工作差异，提交4ae52508代码等同最终r3受测；新增不受此筛选覆盖的App装配仍待正常构建。
- 审核的交错反例：自动搜索后修改草稿/设置不能串旧正文；保存失败仍可撤销联网并取消；关闭项目先给工具/语音/生成停止信号再等待真实drain；flush期间移除/替换自动采用附件不继续发模型。新增实际控制器保存冲突、挂起工具/模型反例；自动采用最后窗口用生产纯值校验反例，不冒称已做暂停文件系统的端到端测试。
- 官方MCP 0.12.1固定上游快照及单行URLSession注入补丁由Lead准备，注册不启动工具。接入取消的两处审阅问题在独立候选repair1修复中；收到结果后的2MiB检查不等于接收前内存硬上限。PREVIEW只实现WebKit静态HTML/SVG；RTC外联边界尚未证明，显式JS模式目前拒绝，F30仍未完成。F28只读准备调用遭自动安全审核拒绝，未通过换描述或宿主裸执行绕开；这不取消功能范围。
- 最近桌面锁屏，GUI暂停并关闭自有未输入实例。未重跑3次已过1024-token长生成，不重开H22/H31/宏/本人视频；新App菜单、输入区停止、跨页/滚动与语音仍须同版原生证据。main仍A稳定基线，组件通过不更新整体冻结状态。

### CHAT-PRODUCT v2 续作：菜单、导入和采用版本（2026-10-04）

- MENU Sol/high初交+两修后，真实NSMenu生命周期9方法中标题两断言失败；Lead按SDK补独立cell显示项并保持原断言，9方法通过。非实现者核API与生命周期；普通App忙循环仍待实际验证。
- Lead F33/F34：导入明确来源/损失确认/同receipt保存失败重试、HTML既有导出发布路径；采用的人工/部分回答独立资产及导出一致。F34反例先红后绿，导入4/交换8/采用1分别见R/lead/s02-s03-import-menu-r1与r2，不能与UI9相加称整套原生通过。实现提交d2badef2，测试时为c0d2a9e4加同一Lead源码增量；随后MCP保留历史合并与本提交，不声称已在新组合重跑。
- 详细最小证据R/lead/menu-import-closeout-evidence.json。MCP固定SDK真实本机服务通过，生产接线进行中。QUOTE与FORMAT为新范围内隔离Sol/high组件，独立工作树，禁网无构建；Lead逐次核验路由。main/旧scheme未推进。

### CHAT-PRODUCT S02 输出格式与选段接线（2026-10-04，持续实施）

同一F01–F36范围。FORMAT/QUOTE组件由受限Sol/high实现；Lead接入现有ChatController/State/界面。格式不改变后端解码器，生成后检查不会吞原文；replay/compare冻结原参数，fork仅复制选中分支。引用始终捕获源/范围/摘要，发布前与await后检查项目owner，重选同文不同位置生成不同资产身份，重试同一选段保留身份；不自动发送或替换输入。

非实现者两项P2均修复：`lead/s02-quote-owner-red`真实Store占用期间项目关闭先失败；`s02-format-quote-green`中9项格式XCTest、10项Workbench Swift Testing通过（源码为14f0c20f加本次增量）。其中UITests宿主事件注入发生identity-mismatch，尽管多测试二进制runner最终exit0，**此UI结果不算通过**；旧`s02-quote-host-geometry`1项通过仅作历史，不覆盖本次冲突。原生App将定向验证选段与菜单；不重跑长GPU。F13最初fork断言选中了regenerate的新分支，已明确指定旧assistant并补compare，未改生产fork语义。QUOTE组件初交/repair1，Lead补Swift返回/SDK getter和真实按钮geometry检查；保留所有失败证据，不归为Worker独立通过。

R仍为run-20261003T150039Z-chat-continue。MCP已有真实SDK服务controller往返与取消；AUX优先队列已验。s03-assistance初交+repair1已结束，模型/权限同先前，纯值组件待CPU及接线。当前桌面可截图，不再直接沿用锁屏事实；普通App门槛尚未通过。main仍f31dced209855722d2f04cc0fc8c5f6712396120。没有新本人授权、模型或平台。

### CHAT-PRODUCT-20261003 / S03 辅助生产接线（2026-10-04）

Sol/high辅助纯值组件后，由Lead接入既有WorkflowServices后台语言准入与ChatController。标题/标签/追问/摘要/记忆分别开关、独立预算；不变主消息和未发送草稿。原文、冻结输入与来源落入原Store；个人记忆跨owner先记录续作，失败只重试保存。只读非实现者指出保存关闭、重复应用、撤权/遗忘恢复反例，Lead逐项修补；不是Sol独立完成或另有独立模型实测。

风险→保存/恢复、隐私、后台取消；最少证据R/lead/s03-assistance-save-red2及s03-assistance-cold-red在修前失败，s03-assistance-wiring-final 13方法/2suite通过（参数化冷恢复3场景，非独立通过率），实际Store独立备份恢复与受控模型流。受测base cdcaa7758381ac0718793b1118a34b59d9780c40加Lead差分，逐文件摘要在R/lead/s03-assistance-code-evidence.json。真实辅助模型和普通App控件尚未验。R为run-20261003T150039Z-chat-continue。所有CLI已结束的事实与当前INSPECTION第一轮修复运行分开；费用unknown。

F30交互组件：Sol/high interactive1，经只读审阅合入962f90d98ba52b6399dd1479853f087cd64b2feb候选。Lead真实WK反例先失败：SDK27 optional delegate签名与实现不符，bootstrap子串/rtc/又误匹配AbortController；R/lead/s05-preview-diagnose保留实际JS错误。不删除隔离要求，修为真实SDK签名与RTC前缀检查，保留AbortController正例和选择器检查。s05-preview-wk-final 8方法通过，loopback健康请求成功、所列五条出站尝试零到达，子进程/监听回收；非实现者复核无剩余P1/P2。纯组件并非普通App或全部网络证明；编辑/保存/Mermaid继续实施。官方依据本机SDK WebKit headers及WebKit RTCPeerConnection.idl/RTCDataChannel.idl的PeerConnectionEnabled。

### CHAT-PRODUCT-20261003 F14/F30/资料准备续片（2026-10-04）

- 固定输入检查F14由受限Sol/high初交+两修，62157a62目录修补亦两修；请求/可观察设置及写根见R/s02-inspection和R/s03-knowledge的route记录，隐藏服务端解析unknown。ARTIFACT初交+两修提供纯内容/编辑器；Lead实际接Store/UI、固定本地Mermaid及预算/失败恢复，不能归为Worker独立完成。
- F30通过：独立版本与精确UTF8、HTML/SVG/Mermaid可编辑预览、原回答保留、旧成果与独立备份恢复、保存失败只重试flush、已准入保存drain、完整sidecar预算在发布前拒绝。非实现者native_h22限定源码复核未发现剩余P1/P2；不是独立执行测试。
- R/lead/s05-artifact-store-r4：基点77cb3c0e2fdcfb3276b1fa6435ece0004f39d88a+本次Lead差异，UI9方法1suite、Workbench11方法2suite通过，exit0/8.424秒。早前真实重试失败修正；CSV组合字符测试oracle误用Foundation子串比较改为完整预期UTF8；新增预算夹具先因无效用户父链、再因缺parentID编译失败，改成15个合法独立会话后通过，未改容量断言。
- 实际WK固定库测试R/lead/s05-mermaid-local（9方法，38.39秒）；健康本机HTTP正控制、未观察出站、服务已收回。Mermaid官方11.12.1固定IIFE、许可及依赖声明入资源；没有CDN、npm运行环境或宿主桥接。s02-inspection-final（8方法）及未变辅助13方法复用，不累加成全套通过率。
- 代码提交后的完整SHA写Git和外部回执，不自引用amend。普通App仍cdcaa775…；锁屏未解，新宿主门槛未验，不接纳main。F21个人/目录/重排、F32临时、F33单会话包等仍属本次完整范围，继续实施。

### CHAT-PRODUCT F21/F22 生产收口（2026-10-04）

受测 `616ba8e17be5fad7c94ca4c64838d6d31ad630e2` +本节代码差异；R/lead/s03-knowledge-wiring-final exit0，UI5方法1suite、Workbench12方法3suite。范围是来源复制、目录选择、明确模型重排与真实上下文状态；不声称真实重排模型或原生界面验收。r3的发布反例错误触发结构损坏，改为仅task自有目录不可写；r4恢复并通过，原失败保留。代码修复保留pending原文与保存owner，重试不重推理；精确来源匹配才能复用复制回的原资产；取消/范围检查置于最后await之后；目录逐项成功取消勾选避免重试重复。非实现者native_files_review提出并复核三个既有P2及新增异步窗口；同一Lead实现并执行测试。CHANNELS Sol/high初交+一修，route/耗时见R/s02-channels；真实通道和记忆来源展示，非新后端。主线未更新，原生菜单/停止仍须解锁后在同版App核验。


### CHAT-PRODUCT-20261003 · F32/F33/F34 production continuation (2026-10-04)

- Fixed base477245011956c86cd0f48d7a21ec3daf7439a4be + Lead production. F33 PACKAGE Sol/high initial+2repairs, observed restricted CLI thread01a103ff-b789-7392-a1e3-436de87af47a, candidate553dd2cb retained in history. Lead implemented actual Store/Controller/UI and fixed two fixture timestamps (createdAt later than endedAt); no contract weakening. Full Lead cost/subscription fee unknown.
- F32 temporary child owns only its cache/Store, shares runtime/model leases; close drains owned tasks/file operations before closing/removing cache, quit preflight reversible; explicit save copies chosen text without private parents. Nil personal-memory provider and temporary model-route guard. No claim zero disk traces or external tool deletion.
- F33 actual selected-session snapshot checks exact loaded bytes+revision, freezes whole branch tree and transitive asset versions including microphone original, excludes other sessions/Quick; ordinary ProjectBackup provides no-overwrite+independent restore. External personal-memory provenance does not silently copy another owner. F34 exact selected answer/quote/schema value creates versioned asset and explicit existing Canvas input; no generation. Envelope budget validates before any publication; cancellation fences all asset-read/handoff boundaries, preserves already published data and suppresses late navigation.
- Evidence R/lead/s03-package-fields-r1/r2/r3 preserves fixture failures. r4 Workbench26 methods/5 suites passed; UI runner only started with no completion, despite parent exit0, so hosting NOT passed. New real process event helper eliminated pre-dispatch identity rejection but requires exit diagnosis; no production assertion deleted. Final targeted s03-fields-final 5 methods passed after last cancellation review. ActualApp remains cdcaa775…; no claims new package/native acceptance.
- Nonimplementer native_files_review checked temporary routing/quit/file ownership; align_layout_diagnosis checked package exact-byte/original-audio protection; native_h22_diagnosis found envelope and cancellation defects, Lead fixes+counterexamples above. This is Lead implementation/reviewed by nonimplementers, not Sol independently passing whole slice. Main remains f31dced… pending ordinaryApp gate. New preferences Worker s01-chat-preferences-v1 from477245, Sol/high exact restricted tree/output/tmp, networkfalse; Lead owns controller/host/input integration; no recursive/build/GPU.
- Remaining F19 audio/paste/order/cross-project, F35 display preferences, F36 status/notification wiring continue within same frozen ledger. F28 safety-review blockage unchanged; no bypass. Native lock gate remains one central item; no new human action repeated.

### CHAT-PRODUCT F19/F31/F35/F36 增量（2026-10-04）

- 受测基点7aac9e200d08913028500d4422d9036ba798c9c9加本次Lead增量；最终候选见Git和R/lead。F19显式PNG/文件粘贴、附件排序和已打开项目复制；F31复用系统本地转写增加选取音频文件。独立审阅发现PNG缺实际尺寸导致必拒，改用原Store验证后真实PNG/坏输入通过。Quick端口共用拖入仍待补，不称F19完成。
- F35受限Sol/high初交325f3d06（365.793秒，初交一次）实现偏好值/面板/字体投影；Lead接入真实模型owner、现有编辑器和固定Markdown库小补丁。非实现者两P2（双owner旧值覆盖、marked期间设置丢失）定点修复；actual NSTextView marked/unmark及双model反例通过。不是真人IME或原生窗口验收。源码/许可/最小补丁见Vendor记录；依赖版本未变，没有缓存打补丁。
- F36复用已有Runtime状态及唯一流消费者，文字observer仅提供实际阶段；token/加载来自完整输出引用对应元数据，未知不填0。终态提示仅持久化后且每次尝试一次，保存重试不重新推理；设置默认关闭。流中正文/思考尚无可靠独立事件，仍明确原始流，禁止猜测。
- R/lead/s05-preferences-attachments：UI6方法/1suite、Workbench7方法/2suite通过；s06-feedback：UI7方法/1suite、Workbench6方法/3suite通过，含真实Runtime慢显示全文、EACCES→保存恢复仅一次提示；s01-preferences-final：UI8方法/1suite通过（最终组字/共享owner修正）。不叠加为全功能通过率。没有重跑已验长模型。F36无delta阶段专门检查与原生门槛仍需补。
- Hosting点击实验未完成：真实LLDB退出栈为Swift async主队列drain退出，未证实AppKit按钮内部退出。实验patch留R/lead/hosting-direct-send-experiment.patch并撤回自身未成功驱动变化；原测试/断言保留，不放宽。r4外层exit0不代表UI通过。
- F28自动安全审查阻塞无变化；原生最后明确锁屏，集中事项不重复。main未动。来源为Sol局部初步实现＋Lead接线/修补＋非实现者源码复核；完整Lead消耗/订阅费用unknown。

### 2026-10-04 F36 非实现者反例修补
348e7b6之后native_files_review发现阶段提示吞掉数值进度，以及检查器可能短暂串用上一回答统计。Lead将阶段与数值一同去重发布；检查器按attempt隔离，读取先清旧值，取消/票据阻止迟到发布。R/lead/s06-progress-red在真实Runtime+WorkflowServices先失败两项1/30、2/30断言；修后s06-feedback-review-green：UI2方法/1suite、Workbench5方法/2suite通过（含无首token时的加载提示及释放）。非实现者源码复核关闭两项P2，没有另跑GUI或模型。受测基线348e7b6加本次明确差分，最终代码SHA见Git；此前通知、Store和模型证据不重复。本轮使用Lead修补，不追记为Worker独立成功。

F35非实现者发现英文核心错误和输入AX名称缺口。Lead为真实NSTextView增加可选accessibilityLabel并为草稿/系统/编辑传入本地化名称，不改文本值/焦点/组字；R/lead/s01-accessibility 9方法/1suite通过，实际NSHostingView检验底层名称与原文，沿用8项偏好和组字保护。普通App/VoiceOver仍未验。错误语言继续在同一F35范围处理，不以本项关闭整组。


### CHAT-PRODUCT F19/F33/F35 组合接线（2026-10-04）

- 候选代码 b31c66311c0b65d9cf658bb8270f2554dbcedf88；三名受限独立CLI Sol/high（Quick初交＋repair1；external与language各初交），请求/观察模型、写根、精确线程、耗时与逐轮usage见R/lead/three-worker-receipt.json。隐藏服务端解析/完整Lead用量/订阅费用unknown；没有重算此前五次历史样本。
- Lead维护共享Quick活动/ProjectSession/Bootstrap、Controller/ChatState/Store来源和UI接线，Worker并未独立完成整片。非实现者审出剪贴板URL优先遮蔽PNG、重复JSON成员、重复键集合CoW性能问题；分别修补。取消时已发布素材仍保留，迟到resolver不再复制/绑定；close waiter即使被取消也等真实drain，使用一次continuation而非轮询。未改模型请求/精度。
- F33外部格式依据Open WebUI官方import/export说明；上游格式无version，`open-webui-history` v1是D映射，不伪称官方版本。多会话须显式选择；完整选中树校验，含done:false树拒绝；loss经明确许可，原JSON不执行/下载、不覆盖原件。conversationIndex保留到来源/保存/备份，防同文件不同entry冒充重试。既有D wrapper兼容。
- F35只在展示边界映射产品错误，存储原始reason不改。固定中英键/外部包覆盖/未知诊断原文通过；这是组件语言覆盖，不冒称所有系统诊断已翻译或VoiceOver完成。
- R/lead/chat-three-integration和r2分别为Lead遗漏Environment以及测试宏嵌套表达式编译失败；修复后r3 exit0/98.296s，UI12方法2suite与Workbench14方法3suite完整结束。最终continuation变化由chat-three-final补验：UI7方法1suite、Workbench16方法3suite，exit0/33.155s。两组重叠不相加成总通过率。12k宽JSON检查0.029s，仅该夹具；正式原生性能仍待验。精确受测文件摘要见three-wiring-tested-files.json；测试时HEAD893bb2e1加已列Lead差异，最终代码由b31c6631固定。
- language Worker自报一次shell here-document临时路径被拒绝后继续，仍作为协议事件记录；可访问命令输出未找到对应拒绝原文，不臆造具体目标或完整证明。未观察到权限扩大/成功越界；只在授权树保留四文件且Lead独立审核，不追改为合规。其余非零只读搜索已核为未匹配/不存在读取目标。
- 普通App菜单/主停止/拖入及新原生闭环仍待解锁；F28先前自动审查阻塞保留，无裸宿主执行/换名绕行。main仍f31dced，未接纳未验证宿主。构建/交付索引与最终文档SHA见R/lead/continuation-receipt.json；不是整项任务完成或发行。


### CHAT-PRODUCT 组合候选与可恢复检查点（2026-10-04）

- 最终代码/测试/App **e80fc15e34eff1b5ad0c27f3010103c1eb1ef10a**。b31后App r5发现Lead装配访问private store，b1b696dd改用已有public currentStore；r6构建通过。非实现者再发现关闭准入不等于取消已接纳导入，以及legacy实例缺失不能猜测本地来源；Lead最小修补由e80固定，未改推理参数/媒体。原先F19三任务及失败/来源继续保留，不追记Sol独立完成。
- 新关闭反例 `R/lead/quick-admission-red` 在b1b代码真实失败（CancellationError）；保持预期，修后green通过。最终e80的 `quick-admission-final` exit0/14.317秒：UI9方法/2suite、Workbench2方法/1suite完整结束，覆盖已接纳导入可在wait关闭完成、新导入拒绝、明确cancel仍拒绝、legacy resolver与原件保护、取消drain不忙等。与旧重复测试不相加成通过率。native_files_review只读审e80关闭两项P2，未声称另跑测试。
- 普通签名 `chat-current-app-r7` exit0/41.049秒。复制为R/delivery/**D Chat Product e80fc15e.app**；codesign --verify --deep --strict通过，四关键文件与构建产物摘要一致。唯一 `启动聊天当前验收.command` 已更新且语法通过，复用原隔离session；新包未启动。App/签名/入口证据 `current-app-delivery.json`、`delivery-entry.json`，不是原生操作或发行验收。
- CUA最后明确锁屏；旧自有App PID63889正常退出请求已发，但延后检查仍存在，不强制结束、不假称已清场，解锁后先处理该项目面板。当前全部Worker与持有CPU/build已结束；另观察到旧R4 helper88174，不属当前句柄、未处置。Terminal工具限制沿用，不绕过关闭未知窗口。
- 原native长流、1024token与停止接续证据复用；本轮未重复长GPU。F01–F36唯一清单保留原生、真实辅助/重排、Speech和F28缺口；只读范围复核未把F19/F33/F35局部通过升级为整组完成。main与远端仍f31dced209855722d2f04cc0fc8c5f6712396120，未经新宿主门槛不硬合；未推送或发布。用户的连续授权仍有效，不需要每片重新批准。
- 保护源01758b81527dc27eb4563bf1b66fd1ceab6647ee、scheme未暂存摘要ca3635d88aa5a15397b90e528667c66c0e6db7e596176e885c79d194b544206c；原始长流项目未改，最终详情在R/lead/continuation-receipt.json。当前后续仅五份获准状态/试用文档，与e80代码相同；最终文档SHA写外部回执，不反复自引用提交。完整Lead成本/订阅扣费unknown。
- 恢复：核HEAD/index/个人修改与上述进程→确认桌面解锁→正常收回旧测试窗口→从新包完成菜单/主停止/导航、素材/导入/备份等原生门槛→完成剩余真实路径并按授权接纳可靠切片。F28具体安全拒绝理由unknown，不声称可通过加Mac权限解决；保留同号工程阻塞。**本记录是阻塞检查点，不是完整聊天专题、功能冻结或正式发行完成。**


### 2026-10-04 解锁原生诊断、菜单定点修补与候选审计同步

- 用户当前解锁但不能本人操作，要求优先原生并推送所有当前代码供审计。起点7caebde0c9c662ffd60c4b99e9aa81002d5bba27/code e80；RN=`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261004T023138Z-chat-native-audit`。先由非实现者核对远端5c6b0ba4至候选的完整108提交/409文件公开范围：新增Vendor源码/许可证，无权重/原始媒体/凭据或根CI发布入口；精确推送7caebde成功。其后两次本地代码提交556da69a、**c16ab4015193d90def32a7cc6629dde9136b6f5c**均为本任务菜单修补，不改Runtime/Store/模型参数/签名。
- e80真实原生：正常打开隔离项目列表中的.dproject；候选菜单554ms展开，新候选与冻结请求重现分开，检查器打开/关闭。发送后17.43秒工具超时，第二次AX/截图16.69秒超时，96263进程CPU约100%，主线程采样显示SwiftUI布局，并命中ChatActionMenu.apply无条件重建/尺寸失效。测试副本仍11次旧attempt；不据此断言send未入内存，也不归为模型或16GiB硬限制。File菜单曾出现AX旧索引；正常重启一次后直接打开项目可用，未把工具错误全归产品。
- 风险→反例：相同展示idle反复更新保持菜单/行/标题项身份和尺寸，仅刷新动作；tracking期间不得改已显示动作；结束后迟到sender不能串到新周期。menu-red（未改实现）4断言失败；只读审阅补reopen-before-drain与idle-post-drain两个反例分别先红。最终记录一次性rowsNeedRenewal并在既有安全点换代；menu-reviewed **14方法/1suite通过，命令总耗时10.205秒**，不是13+14累计。源码复核关闭已报P2、未发现新增P1/P2；审阅者未另跑测试。Lead实施与测试，不归为Worker独立通过。
- 受测版本：最终菜单测试在556da69a上带两文件明确差异，随后由c16提交固定，精确摘要见menu-reviewed-tested-files.json。c16普通签名构建menu-app-reviewed exit0/28.331秒；复制delivery/D Chat Product c16ab401.app，签名、四关键文件和启动器语法通过。**CUA此时明确Mac再次锁屏，新包未启动；不能把修补/CPU当发送与主停止原生通过。** 不重复已过1024-token或全模型。
- 进程/数据：63889本次开始前已结束；96263正常CmdQ27.25秒超时后，核对精确可执行路径，仅对自有隔离PID发SIGTERM，确认结束，不称正常清理/保存通过。最终无D，持有CPU/build结束；非本任务旧helper/未知终端未操作。原始quick-chat摘要34ecae422482b014903e6e69902fca32aad41dad6034e1262de354cd3d839175不变；测试副本保留；个人scheme完整差异/摘要/索引/未暂存状态不变。证据protection-end.json、owned-app-stop.json。
- 本人组字/Speech权限与试听后置到唯一集中队列，H22/H31/宏及固定视频不重开。F28自动安全拒绝缺口不绕行、不移除。main仍f31dced209855722d2f04cc0fc8c5f6712396120，不硬合失败宿主；候选和检查点正常推送供审计，最终SHA/远端核对见RN/lead/audit-receipt.json。完整Lead费用unknown。
- 恢复：核c16之后仅文档差异、保护状态和自有进程→下次解锁先用唯一包完成原发送/菜单/主停止反例→其余F01–F36继续。**这次是审计同步和局部修补，不是聊天全范围、功能冻结或发行完成。**

## 2026-10-04 c16普通App复验与可靠基线接纳

R=`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261004T041401Z-chat-resume`。复用c16既有14方法、正常签名构建及非实现者菜单审核；本轮普通App实际菜单/短发送/输入区停止/partial保留/拒绝未采用继续/显式采用后再发/切会话通过，精确attempt和耗时见lead/c16-native-core.json。TXT导入→词法第3行→采用、上下文预览、工具42采用、选段解释也完成；随后CUA报告锁屏，剩余原生路径如实在唯一清单/队列，不重跑模型。

main从f31dced209855722d2f04cc0fc8c5f6712396120快进8d64000c849b70c8ad18cb574ea1f31b02b93f79，后者相对受测c16仅文档；保护快照lead/main-core-preflight.json，提交/推送回执lead/main-core-integration.json。源scheme内容/索引/未暂存保持，不接入其他候选。F14/F31/F26新实现仍在独立候选，受限Sol/high + Lead接线/复核，最终费用unknown。F28尚未实现，历史拒绝详情unknown。新App代码和完整专题/冻结出口均不由本次主线推进自动通过。


## 2026-10-04 CHAT-PRODUCT续作：F14/F18/F26/F28/F31

同一F01–F36与8d64000c决议；不是新任务/重置预算。R沿上一节。代码候选f08ca2427b54e0519780e473ea7dfcce431af234，最终仅文档SHA与推送记录在R/lead/resume-delivery-receipt.json。main已通过c16核心门槛并推送f9a439db；新原生工具路径尚待解锁，不把候选状态硬写成main全功能。

- F14 local/share使用不同投影：普通token/key正文保留、真实凭据字段遮蔽；F31仅手选普通话/英语。受限Sol/high分别初交+一修，Lead复核实际别名错误再修，10/9方法通过。F26 Brave先实现再补博查，同一显式服务设置和本地凭据文件关联；摘要与真实正文分离、真实公网example.com读取、取消/关闭/归属/备份/no-secret反例通过。带key调用及大陆可达性未知；自动回答测试为fake本地engine接线。公开API/价格/保存条件只作前次一次核对，未重做市场研究。
- F26 e742组合定向报告55项/6suite，其中54执行通过、1显式跳过；该跳过项已在另次实际网页探针中通过。与重叠历史结果不累计通过率。readonly native_files_review核对Lead接线。临时摘要8条活动、900秒为访问时过期，并非定时内存擦除；持久记录不留摘要/key。网页读取使用既有静态公开HTTPS边界，正文引用绑定实际读取。
- F18事件号Int32→系统16位截断，以及SwiftTesting异步NSApp事件退出前无suite终态已定位；LLDB退出栈在f18-exit-stack-r3.log。仅该真实hosting方法转同步XCTest，仍NSApp.sendEvent，全部行为断言保留；审阅发现Bool被XCTUnwrap误当真，修为guard+XCTFail。最终1 hosting方法及另2协调方法完整通过，测试提交e0cc7496，无生产输入补丁。
- F28采用官方CPython3.14.8 WASI与Wasmtime49.0.2完整CAPI，Pulley解释模式，无JIT/裸宿主用户代码/网络/进程/任意文件/pip。来源、固定下载摘要、编译命令和许可证在R/f28-dependencies及每个资源包PROVENANCE.json/许可证。WASI SDK24官方构建脚本指定版本，本地摘要有记录但上游旧release无digest；不称上游摘要已验。选择依据：成熟WASI能力隔离与现有Process/Store装配；差异是只读选定输入和有预算文本成果，不是通用Python环境。
- helper受限Sol/high初交+两修（9600749a）；client初交+一修（b22408c8/e72fc32b）。模型请求、观察设置、独立树、精确线程及增量usage原记录分别在f28-helper/client；隐藏解析unknown。helper初交pgrep被拒却未写回报、repair1 heredoc临时路径被拒后停止，两次未观察权限扩大/成功越界；Lead先核异常再允许明确授权目录的文件写法，未重试进程枚举。client初交相同枚举拒绝已报告，后续不重试。Lead自己的早期提示文件名/引号/测试筛选错误分开记，不算Worker代码缺陷。
- Lead复现真实CPython关闭stdout退出-13，repair2忽略helper自身SIGPIPE使EPIPE走完整清理返回2；原证据不覆盖。helper12 WAT方法、此前真实CPython7边界用例、修后闭管道、签名固定沙盒宿主分别留证。独立审阅关闭取消初始化、满管道及SIGPIPE P2。client修编译捕获、错误测试前缀、cleanup可见错误、复用严格JSON解析；Lead按实际125127字节/602文件库存将manifest预算对齐既有4MiB，代码预算仍64KiB。无全局权限修改。
- Lead共享装配：明确所选文字/CSV副本→真实WASI→可检查stdout/CSV/SVG→现有成果编辑器→显式保存；receipt保留代码/输入摘要/实现与结果摘要，并经parents纳入既有备份闭包。候选f08实际`f28-wiring-real`3方法通过：未选输入拒绝、真实分析/两个成果/原文保留/另一会话不串/独立恢复、取消后下一调用。原input保护和保存失败测试复用未改Store。`f28-client-r2`报告18条中实际16执行+2显式跳过，后两项由真实接线单独执行，不误计18全部实测。
- 签名资源不是独立CLI：直接启动inherit helper退出-5已记录，未降低App沙盒绕过；依据[Apple helper文档](https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app)在同身份、仅app-sandbox的固定测试宿主中验证，exit0并输出mean20/CSV。CPU测试使用同源码的自有无App-inherit helper副本运行WASI，两者不混为普通D验收。未验证清理失败注入、忽略TERM后KILL及35秒外层到期；既有真实取消/fullwait/下一调用、资源上限与输入拒绝是已验范围。
- 所有新资源在外盘任务目录，不入Git，不附模型权重；打包器不下载/全局安装，正常Xcode沿既有resource-set嵌入。相关资源夹具检查通过，旧模型执行未改故不重跑。普通D GUI、两家真实key和本地Speech/新聊天组字仍受锁屏/本人操作限制；只阻塞相应项，唯一清单保持待验，不宣称完整聊天或冻结。
- F28修改了共享ChatController，因此在最终代码f08另补F26接线回归 `f28-search-combination`：6方法/1suite全部执行通过，4.888秒；覆盖取消/归属、临时摘要和凭据不持久化、实际网页先于本地回答的受控接线。未重复provider全套、真实收费API或模型生成。
- f08ca242普通签名App构建 `chat-f28-app` exit0、91.924秒；资源验证与原生Xcode复制/签名通过，候选包含完整既有引擎和新的WASI资源。交付副本、四关键文件、WASI关键文件及唯一启动器见 `lead/app-f08ca242-delivery.json`。没有在锁屏时重复启动D，构建不替代普通App原生验收；本树Xcode使用已准备的忽略配置即可重建，不靠事后手补App。

恢复：先核真实HEAD/index/个人scheme、当前App与任务进程，再使用唯一新包继续未验原生路径；同一冻结范围不重新审批。全局质量审计/Liquid Glass精修仍未启动，许可证/正式Release不变。Lead与非实现者检查分别留证，不把来源标签当质量保证；完整Lead归因及订阅货币费用unknown，未重算历史五次样本。
