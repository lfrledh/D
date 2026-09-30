# D-RELEASE-FREEZE-01：首发模型有限收口

2026-09-30 · r2 收尾执行中；以下 r1 结果保留为历史，未升级为冻结通过。

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
