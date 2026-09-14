# D-MULTIMODAL-BASELINE-01：统一可运行开发基线

状态：本阶段有限验收通过，已接入源工作分支；最终结案版本/推送状态见R/final-receipt.json。2026-09-14，组合规格 MB1、构建修订3/MB-BUILD2，指导 P2026-09-13.1。下方按时间保留独立准备、失败和预算记录，最新状态见末节。

源基线 `ac39b73d64793bed9dd7089e32dcd43c0db2a2c1`，源分支 `codex/inference-foundation`。Lead 集成工作树 `D-Worktrees/D-MULTIMODAL-BASELINE-01` / `codex/d-multimodal-baseline-01`。外部证据 R=`D-Development/AgentTrials/D-MULTIMODAL-BASELINE-01/run-20260914T115845Z-human-return`。准备提交后的完整执行基线写各 job/运行回执，避免自引用。

## 用户结果、范围与门槛

先完成 H18 参考图与 H19 资料问答普通签名隔离 App 的真实闭环，然后把两候选与已验收图文音视频能力组合为一个明确可重建的开发版。现有项目迁移保留原清单、原件和来源；全新构建产物不替换普通 D。用一个显式入口复用既有构建/封装器，说明 Xcode 原生构建与完整三引擎封装的区别。

不启动 HUM/演唱/I2V、下载模型或依赖、编辑器/工作流平台，不更改现有签名身份、Team、bundle ID、entitlements、钥匙串/TCC 或用户 Codex 设置。main 不推进；只在验收通过后接入现有源工作分支并按既有工作分支授权同步。旧预算和失败历史不重置。

H18 固定候选 `14af48c22e9dbe7ee715b171308276347fab0f68`：本次真实导入、改图、比较采用、复制实际条件、冷重开与导出保护通过，见 R/image-native-acceptance.json；旧完整后端 141 方法仍绑定原 SHA，不称本次重跑。H19 固定候选 `606d0c6c51cc3effe3a5ac87b0e4fc9c9f5f27aa`：本次真实 7B 问答、中文/组合字符/emoji 选段、采用撤销、拒绝、取消下一任务、旧结果保护、生产保存外部修改拒绝与冷重开已执行，新增问题输入框真人 IME 检查待用户回报。H09 用户本次确认仍无麦克风，继续保留，不启动录音。H19 门槛完成前不默认开启或源接纳该候选；不依赖它的构建准备可继续。

## 组合契约（Lead 唯一协调）

- 两个已验收候选保留各自历史，先在隔离区合入明确 SHA。源只快进已验证组合；个人 scheme 不参与任何暂存、提交或冲突处理。
- 项目新写 schema11，读1…11，先按原 schema 验证再迁移。image-reference 域存在于9/11，text-sources域存在于10/11；不能把 `>=9` 当作两个候选的共同能力。
- 1…8按原备份规则迁移；9保留原参考与实际任务引用、为文字初始化空 sources；10保留所有 sources、excerpts、records、v1/v2 prompt 与正文，不能在迁移时清空；11包含两域。备份9/10的原字节后才发布，媒体不改。未知12、损坏/空值/错误类型/跨文档引用及冲突明确拒绝，不静默丢数据。
- 公共模型/Store/Session/facade 和冲突由 Lead 管理。新迁移例外须可解释；不一键选 ours/theirs。旧测试的 schema 预期只有明确新增兼容契约允许改变，黄金原清单夹具不改。
- 资料问答默认开启须已有 H19 与组合 GUI 证据；未验证组合不可替代现有入口。模型精度、token/几何支持与参数真实性不改。

## MB-BUILD1 独立 Worker 包

task_id=D-MB-BUILD-01，spec_revision=1，contract_revision=MB-BUILD1，batch_id=D-MULTIMODAL-BASELINE-01。Sol/high：部署、子进程生命周期与文件保护有实际风险；Lead先冻结输入输出，Worker自主选择局部实现，不改既有封装算法。

**只允许四个文件**：`scripts/build-development-app.py`、`scripts/development-app-config.example.json`、`scripts/tests/test_build_development_app.py`、`scripts/build-local.sh`。后三者前两个/测试为新文件，build-local只增显式 DerivedData / SourcePackages / 日志及离线选项透传；旧无参数行为保留。禁改任务规格、文档入口、Swift、工程、锁文件、Info/entitlements、签名配置、封装器、源码/用户应用/模型/历史输出。必要额外路径先问 Lead。

入口 Python3.12 标准库，不新依赖。建议接口 `python3 -B scripts/build-development-app.py --config <明确本机JSON> --run-root <全新外盘目录> [--timeout-per-stage 秒]`；源根为脚本所在仓库。JSON schemaVersion=1，必填 `developerDirectory`、`signingConfig`、`signingIdentity`、`pythonRoot`、`sa3SitePackages`、`mrt2SitePackages`、`videoSitePackages`、`tokenizerDirectory`、`sourcePackagesTemplate`。样例只写占位路径和字段说明可放 argparse/docstring，不提交本机身份/绝对私有路径。配置中身份是既有证书标识，不访问/枚举钥匙串；新身份/配置改变须停报。

行为表：

| 输入/操作 | 必须结果 |
|---|---|
| 完整现有输入＋全新run | 预检后依次现有 build-local → package_audio_app → prepare_video_engine → package_video_app，最终独立 `D Development.app`；含 AudioEngine/MRT2MusicEngine/VideoEngine 三份签名后 manifest |
| 缺输入/必要依赖入口或现有SwiftPM检出/锁不匹配 | 构建之前失败，无下载/安装/云服务；路径错误说清哪一项 |
| 已存在run/输出、run与源/输入相互重叠或软链根 | 拒绝，不覆盖、不清理；配置只作为值，不执行 |
| 独立缓存 | 既有 SwiftPM template 复制到本run，不把可变共享检出直接交给构建；独立 DerivedData、TMPDIR、Python无字节码、Clang/Swift缓存和日志；不修改全局缓存 |
| 子步骤失败/超时/取消 | 不运行后续；记录原始退出/信号/耗时和日志；只结束本轮持有的进程组并等待退出，有界TERM→KILL，普通D与其他进程不碰 |
| 封装后报告失败 | 保留已经发布的App、报告明确失败和位置，不总清理已交付产物；半成品不报统一版成功 |
| 成功状态 | `status=packaged`、`runtimeVerification=not-run`，不得把封装通过当真实推理/GUI/公证验收 |

Xcode 复用 `-disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates` 和已锁定本地检出；禁止网络更新的Git环境仅对应命令控制，不声称系统隔离断网。显式传旧获准 signingConfig，不能因新 D_DEVELOPMENT_ROOT 而悄悄用 ad-hoc。保留既有 packaging 的声明/摘要核验、逐原生文件签名、外层签名和独占发布，不 `codesign --deep --force`，不从旧 App 偷取引擎；所有 provider/video-root 来源本次源树。所有参数以 argv/env 安全传递，禁止把用户路径拼为 shell 命令。

报告最小字段：版本/源完整 HEAD 和未提交差异摘要（确实存在时），输入配置文件摘要，工具版本和每阶段命令/状态/时间/日志，最终 App 路径、三引擎 manifest 摘要、package 报告与运行未验证状态。stdout 是摘要；证据在独立run。退出0仅封装成功，输入/工具/报告失败2，用户取消130；记录具体子阶段码，不能靠外层码掩盖失败。报告/日志路径不得覆盖输入或既有文件。

Worker只执行合成CPU编排测试与无字节码语法检查，不能实际构建/签名/运行引擎/GUI/GPU。使用假命令测试真实编排生命周期，不伪装为实际封装。冻结用例：正常四阶段与三manifest；中文/空格路径；配置版本/类型/缺项；缺工具/检查点早停；输入/run重叠与已有输出保护；每一步失败不继续；超时/取消回收；最终发布后报告失败保留App；stdout失败清楚失败；不改源输入/模型/签名配置；旧build-local无参数行为与离线显式参数对应。

实施前只读预检，Lead核真实 cwd/HEAD/commonGit、CLI请求和 turn_context 的 Sol/high、workspace-write写根/网络关闭。写根仅其 worktree 与 R/build/{output,tmp}，共享.git只读；不递归。初交+最多两次修复，必要一次有界Lead接管不重置；权限事故分级按现有协作规程，未知停报。语法用 tokenize.open+compile(...,dont_inherit=True)，不 exec/import 目标做语法检查；测试产生文件/缓存仅唯一 tmp。交回差异、检查证据、异常与自有进程终态，不自行commit/改规格。Lead在Worker结束后审查并显式提交。

## 批次验收、保护与恢复

Lead串行：迁移正常/严格/中断/锁回归、组合完整工作台CPU/核心、封装CPU回归、固定组合普通签名离线构建/三引擎封装与身份/声明对照；同一产物的四模态短闭环/原项目安全冷重开。采用已有数值证据不重跑无变化所有模型；凡受影响模型入口实际短回归单列。重构建不与GPU/GUI争用，实际子进程及测试产物独立。重要Lead修改由非实现者审核后才接纳。

源个人scheme当前摘要 `ca3635d88aa5a15397b90e528667c66c0e6db7e596176e885c79d194b544206c`、索引blob `9c76916bdc97c2d4298cefe64e0b0fae3380573e`、唯一未暂存orderHint1→6。R/protection保留原件与完整差异；每次源更新前后核对。普通D四关键文件不改、不启动；所有临时写入只在本run/专属工作树。GUI退出后只看持有退出回执，不能调用目标AX自动重启。

默认普通签名方案保持；直接 Xcode Run 目前只是原生构建，不隐式打包三个Python引擎。本批统一入口和说明解决完整开发版重建，不擅自更换Debug签名配置。H09、复杂长文质量、真实硬件高容量及精确图像局部服从仍单列，不因本批通过而关闭。

当前已完成：H18、本次H19自动原生操作/真实7B、初始保护、只读组合和封装范围核查；待真人IME、实施、审核、组合/源验收与提交同步。本次按独立性先1写Worker负责构建入口，Lead共享兼容；不为并行制造任务。旧候选审核按未改代码复用，新合并差异另审。模型来源/耗时以运行证据为准，订阅扣费与完整Lead归因unknown。


## H19 真人失败与恢复检查点（2026-09-14，MB1语义未变）

用户原文：“缩窄后文字候选还在，但按空格不会输入，而是会输入空格。放宽后也一样。”固定CLOSE2 App代码1348aa7a87ae741c1a292ec43d6beafb54f2b078、候选606d0c6c51cc3effe3a5ac87b0e4fc9c9f5f27aa；H19不通过，不以原CPU/布局对象身份通过抵销真人失败。详情R/text-gui-r3-ime/human-ime-failure.json，当前AX问题文本和自有project.json快照同目录保存；R/text-native-acceptance.json分列已通过实际操作与阻塞。原产品文字/候选代码未改，原VIEW初交+两修复+一次Lead接管历史保留，剩余原预算为零。

Lead及candidate_compatibility_scope只读核查：问题框是SwiftUI TextEditor，Binding同步回读控制器已接受的问题；没有T0原生编辑桥的hasMarkedText屏障。原测试用固定notebook与空修改回调，不覆盖真实控制器/firstResponder/markedRange/空格确认；完整壳层测试只数编辑器。尚不能证明根因；可能是组字回写或输入上下文/焦点变化，不能因缺显式屏障就判TextEditor必错。只读审核未修改、运行测试或GUI。

提案仅一次新增有界Lead收尾：先记录缩放前后原生对象、焦点、markedRange/selectedRange及原生/控制器文字；根因驱动最小问题编辑桥修补和直接回归，保持原字节、跨文档归属、非法输入拒绝、取消/保存语义；非实现者审核后构建并真人验证拼音空格确认及宽窄往返。不能强制提交/取消组字、吞编辑事件、改模型/存储/签名或绕过原契约；需要扩大范围或仍不通过时停报。当前未获这次额外修补决定，未实施，不以MB或新编号刷新VIEW预算。

BUILD预检线程01a09fe3-d696-7af3-8749-65f83fa981bf，实际294cd99efc470801cbac2dd0729230cbcf4d8c73；客户端turn_context确认为gpt-5.6-sol/high、任务cwd、workspace-write和network=false，共享Git不授权写；源是本run/build/preflight-observed.json。CLI预检79.40秒、exit0已结束；未发IMPLEMENT。bare rg缺PATH的exit127、可选目录不存在exit1是预检工具问题，未观察到权限拒绝或实现写入；后续显式使用已安装rg路径，不更改全局PATH。隐藏服务解析及实际费用unknown。

保护结果R/protection/ime-pause.json差异为空；源仍ac39b73d64793bed9dd7089e32dcd43c0db2a2c1及原scheme唯一未暂存修改。文字测试实例PID57800/句柄23196仍运行并保留失败现场、无生成；此前两文字/两图像实例已正常退出，BUILD预检结束，非实现者只读任务结束。恢复先核实际Git/索引/用户文件/持有进程，再读R/ime-pause-checkpoint.json；不要据聊天摘要自动扩大额度。H18通过、H19失败、H09无设备分别保持；无merge/push，不关闭普通D。


## 续行与 BUILD 定点修复规格 MB-BUILD2（2026-09-14，现行）

用户“请继续之前的工作”批准一次额外有界Lead IME修补，原预算/失败史不改。T受测703dd146426435990b345f3ef03ee7a97ea1618a，文档候选f58f40c6636b80f4b1fbdac7acc7d2f25c5377fe；真人拼音缩放空格选字通过，原生Unicode输入/undo/redo/生产保存/冷重开通过。H19候选门槛完成，H18已通过，H09仍无设备。新索引R/text-ime-handoff.json与text-native-acceptance-after-ime.json。旧暂停段保留历史，当前可继续组合。

BUILD初交9项合成CPU由Lead重跑通过，但独立反例确认：空依赖树/外逃SwiftPM链接仍进入构建，坏stdout完整进程退出120，leader退出后忽略TERM的孩子仍活。Lead只杀本次夹具记录的孩子63485并观察PID消失；首次自有探针引号语法错误未执行目标，修正后运行，分别保留两次日志。只读复核另指出脏文件内容变化漏检、报告flush/fsync失败不完整。故初交未接纳；原内部调试不伪写为Lead返工，此次为正式修复1，修复2仍最多一次。

MB-BUILD2保持原输出/验收/权限，**允许第五路径 Backends/Audio/Packaging/package_audio_app.py，仅_run_command及其必要私有生命周期协作**。原因：它为Audio/Video复用的原生命令另开会话，原四文件无法可靠回收；Lead已核定扩充，非Worker越界。不得改变签名参数、身份、entitlements、清单、发布语义或引擎实现。显式内部监督标记仅在父PID/阶段自身session与PGID匹配时启用：原生命令继承外层已持有阶段组；默认独立调用仍自建组。helper默认/监督两模式均有界处理取消、超时、管道和重复信号；外层不因leader先退就跳过组清理，全部已持有组完成或明确cleanupIncomplete后停止，不扫描系统/杀未知PID。运行规则详见R/build/repair1-prompt.txt，其参数与MB-BUILD2同冻结。

其余修复：SwiftPM复制前后检查软链/每checkout gitdir/common-dir均在独立树内（git metadata分离/外逃/损坏拒绝，不能禁用校验）；必要输入文件按现有preparer要求在构建前只读核查；来源摘要覆盖tracked/untracked/index内容及同名脏文件变化；报告写/flush/fsync和stdout/退出再刷错误保持2并说明保留App/证据路径，不用os._exit。预期失败用例不能只验函数返回，需完整CLI及已知子PID终态；与本机真实封装验收分开。

原Worker进程枚举被沙箱拒绝后已停报，没有再试/提权，所有工具返回；不声称全系统无进程。Lead只核任务回执/子PID、保护与允许文件摘要；修复使用同线程Sol/high、原受限写根和network=false。新范围在既有任务worktree内，不改沙箱。源码目录/身份/配置不符即停，剩余预算不重置。

## Lead组合执行事件（2026-09-14）

M从8b0303e6be9b728ad3d51502b9b076391dbbf51d合T f58f40c6636b80f4b1fbdac7acc7d2f25c5377fe，保留历史提交71bfbf2a4bf620875d1307bc64c420d073a2749d；随后以固定I14af48c22e9dbe7ee715b171308276347fab0f68未提交合并。共享4生产文件按MB1合成，文档冲突保留双方历史并新建明确当前短段；测试迁移目标改11，原10黄金夹具不变。新增5个迁移方法，参数化场景另计；未通过前不接源。图像原可选参考nil仍合法，“拒绝空值”仅对应必需sources/非法值，不改变合法无参考契约。

Lead首次预检错误地把源relative `.git`相对宿主cwd解析而触发断言，编排中后一条孤立merge命令仍执行了（仅M且no-commit）。立即核两端SHA/索引/真实commonDir、已知源scheme、hooks/忽略碰撞及实际暂存差异；确认为检查脚本路径错误而非仓库漂移。合并内容全部与固定T对应，源未变；保存R/merge-preflight-incident.json后才提交。后续依赖操作改为同一检查脚本成功后执行，避免失败检查后继续mutation；不自动reset/abort或掩盖事件。

### 组合检查与候选可见入口

组合17dd2dd38e0cd0c2baa768615a54ac3b383e6746：447方法/65套件零失败，3条件检查跳过；64核心/11套件零失败零跳过。非实现者审核4共享文件无阻塞；新增迁移5方法经review补齐RGB原字节、Unicode正文UTF8和publicationDurable中断恢复，定向5方法已通过。R/old-reader-probe在专属外部package依赖真实旧T/I库，分别实际以schema10/schema9 reader拒绝当前生成的schema11项目且原清单字节不变；三次进程exit0，未改旧源码或用户项目。这一检查是新普通项目的版本拒绝，不冒充所有旧格式跨机矩阵。

H19已经过独立候选验收，本组合候选将WorkbenchModel的文字资料入口默认值设true，显式false注入仍可用；**只在此隔离候选编译/验收，源默认入口须组合GUI通过才接纳**。不再要求用户设置D_ENABLE_TEXT_SOURCES才能看到已获准功能。生产其他控制器/后端不改，随后普通App以不带该环境变量的方式验证。不可将17dd上旧默认的测试写成新默认已经测试；新固定版本与检查见下一回执。

## BUILD 最后一轮普通返工与组合复验（2026-09-14）

3c184b727554e45fe66a8fb69871ea454068742f 的可见资料入口再次通过447方法/65套件，3项条件检查跳过，R/combined-ui-visible-default；README同期仅草稿，不是代码差异。非实现者定点复核默认值与迁移测试增强无阻塞，不声称复核者执行了测试。H19真人“空格选字、文字和光标均正常”，以及其后原生撤销/重做/保存/正常退出新PID重开完整记录在 IR/ime-acceptance.json；不重跑已确认的人类输入。

BUILD Sol/high 初交未接纳。正式修复1有一次900秒超时，已结束回执/未完成处保存；同线程一次有界续行757.33秒结束0，未重置普通返工次数。其最终5文件hash见R/build/lead-frozen-repair1.json。Lead重跑18合成方法、原4真实CLI故障反例、12音频及15视频封装CPU均通过；这些不同套件不合并为产品通过率，未执行真实签名/封装。修复1内部短暂自测失败及修正保留，不将每次内部调试伪记为一次Lead返工。

只读复核发现相对Git alternates按错误父目录解析；Lead用本机Git的受控空仓库确认正常内部被拒、真实外部而误解的内部位置存在时被接纳。所有路径在本次探针自有目录，未造成用户/原缓存外部写入。故冻结修复2（规格修订3、MB-BUILD2语义不变），只改构建入口及直接测试；补正确相对基准与write/flush/fsync受控故障回归，保留原退出/保护/取消标准。原普通修复预算在此轮用尽，不无限延长。

Lead曾在Worker尚未结束时依据中途结果发只读审核；hash不符后审核正确停止，另一个未被条件保护的测试调用仅因不存在夹具目录在setup失败，未开始行为用例。R/build/lead-premature-review.json记录Lead时序问题，不归为Worker代码失败；后续执行必须等待进程结束并在同一检查脚本成功后运行。无Lead编辑Worker文件。

离线构建输入已静态审查。新自有缓存对12检出离线repack后fsck均通过，旧缓存不改；未锁的argument-parser仅在新副本移到本次保留目录，11实际锁版本的预检通过。无下载/依赖安装/签名改变；R/offline-cache-preparation及build/lead-real-input-preflight记录前后。当前所有App实例已正常退出，源仍ac39及个人scheme不变，统一构建/同App组合GUI/源接纳与push仍未完成。

## 2026-09-14 最终组合验收与源接纳

本节覆盖以上停点，保留失败和预算历史。完整受测代码/产物来源为 `aba1326f72f33ada028e35a8e799ef04965e7afa`；源于2026-09-14 14:37:47 UTC从 `ac39b73d64793bed9dd7089e32dcd43c0db2a2c1` 以固定SHA快进接入。两端共同历史、完整67路径归属、个人文件和自动化均先核对：28文字路径与f58一致、18图像路径与14af一致、4共享生产/4迁移测试与已审3c一致、5构建路径与165一致、8文档；38新增/29修改、无删除。证据R/integration-path-map.json、source-pre-fast-forward.json、source-fast-forward.json。没有工程/签名/权限/依赖或用户文件夹带。

BUILD修复2在原Sol/high受限CLI线程 `01a09fe3-d696-7af3-8749-65f83fa981bf` 完成，338.957秒，模型请求与可观察turn_context一致，workspace-write专属工作树/输出、网络关闭；隐藏服务端解析unknown。Lead在其结束后冻结五文件、复验、读取非实现者审核，再显式提交 `165d4f9798df827d4f69cc1e3c9d8e16954d8625` 并保留历史合入aba。初交加两轮正式修复已用完；构建器没有Lead实质重写。Lead提供契约、失败反例、审核/验收及集成，不能归为Worker无协助一次通过。共享schema、默认入口和额外IME有界修补由Lead负责，相关非实现者审核已完成，无新增常驻Reviewer或后续产品Worker。

### 构建、组件与源入口

同一Mac M4/16GiB、macOS26.6.2、Xcode26.6/SDK26.5，既有Python3.12外盘环境；仅代表本机样例而非产品上限。独立统一构建 `R/combined-development-app-r1/output/D Development.app` 四阶段实际执行通过（93.1086秒），AudioEngine/MRT2/Video三个引擎从既有离线环境封装，未从旧App复制。签名完整性检查通过，沿用现有身份及App Sandbox权限；不证明公证/TCC永久有效。构建报告的 `runtimeVerification=not-run` 是生成时事实，随后运行证据另存，不倒改原报告。三引擎完整文件清单及四关键文件摘要见combined-app-artifact.json。

| 本轮固定入口 | 实际受测版本/目录 | 结果与证据 |
|---|---|---|
| `scripts/test-workbench.sh` | aba，源工程目录；独立Build-UI-Source | 447方法/65套件中444通过、3个opt-in跳过；测试51.684秒、含构建总87.065秒；source-workbench/result.json及stdout.log |
| `scripts/test-foundation.sh` | aba，源工程目录；独立Build-Foundation-Source | 64方法/11套件通过；总9.160秒；source-foundation/result.json及stdout.log |
| `scripts/tests/test_build_development_app.py -v` | aba，源工程目录；指定任务临时目录 | 20方法通过；总23.928秒；source-builder/result.json及stderr.log |
| 普通开发构建/封装 | aba，组合工作树；既有离线输入 | 四阶段exit0、没有不完整清理；combined-build-entry-r1/result.json、combined-development-app-r1/evidence/build-development-report.json |

三个跳过为 `actualCLIAnswersPersistWithExactSubmittedContext`、`verifiedModelAndProductionContextForExistingCLI`、`approvedInstalledWeightsRemainUnchanged`，不说本次工作台零跳过；旧显式执行证据与本次实际GUI分别记录。原文字23项MLX、图像141/18套件仍绑定原阶段SHA，不冒称在aba全部重跑。本轮原四CLI故障、真实Git alternate反例及额外报告子进程检查的范围见R/build；报告注入替身不伪称未修改CLI。12音频/15视频封装CPU是修复1未变路径的复验，不与20方法或GPU计数相加。

### 同一新产物的真实用户闭环

固定隔离session `950345B0-C836-4976-9C4A-B79BDF4BD45E`，不设置 `D_ENABLE_TEXT_SOURCES`；独立项目副本位于R/CombinedProjects，导出R/CombinedExports。全部GPU由Lead串行，以下不是mock或只读取已有输出：

| 路径 | 实际模型/条件与结果 | 行为及证据 |
|---|---|---|
| 资料问答 | 已有Qwen2.5-7B-Instruct-4bit，revision c26a38f6a37d0a51b4e9a1eb3026530fa35d9fed，输入2048/输出128；本次回答“资料未提供预算。[S1]” | 原稿直到接受前不变；接受追加、撤销恢复；旧五条历史及本次撤销记录保存重开。text-before-accept.json、text-after-accept.json、migration-and-undo-check.json |
| 参考图 | FLUX.2 Klein4B q8，revision ef52ee019fd1d0e75ae4deb40476ba65989716d7，512²/4步/guidance1/seed42；白杯参考→红杯候选 | Lead看图确认杯色/木桌；采用后PNG导出原字节一致、独立ImageIO真解码；旧参考/蓝杯不变。image-result.json、media-inspection-image-audio.json |
| 声音 | SA3 small music，revision da6edc54ddba10bfd79a077102ded687f80e882b，6秒/8步/seed42/guidance1；44.1kHz双声道float32、264600帧 | 采用/正常试听/独立WAV解码/安全导出/重开；audio-results.json。点击取消时首任务已完成，不计作有效取消覆盖 |
| 条件器乐 | MRT2 small，revision010aa0dcb0dfd27b24f0ad07b4dad63e8f9521cc；4秒、C4/D4/G4各1.2秒、seed42；48kHz双声道float32、192000帧 | 采用、试听、WAV导出；第二任务实际早期取消、无产物；下一任务完成并拒绝，原采用结果保留。music-cancel-recovery.json；非全计算边界取消或精确配器证明 |
| 短视频 | Wan2.1 T2V1.3B，revision37ec512624d61f7aa208f7ea8140a131f93afc9a，320×192/17帧/16fps/50步/guidance6/shift8/seed42，显式14336MiB；后端404.390秒 | 文生红杯短视频；实际预览播放、采用、无声H.264 MP4导出、独立完整17帧解码及重开。video-exact-request.json、video-result.json、video-backend-record.json；不是参考PNG转视频 |

以上短文件名位于R/combined-gui-r1。模型与既有精度保持，实际请求/阶段耗时/内存与输出摘要留各记录；短期cache清零不证明全局无泄漏。SA3/MRT2两样本用户明确“听到了，播放正常”，见human-audio.json；这确认正常播放，不证明音乐完全服从音符/配器。IME额外修补代码703dd146426435990b345f3ef03ee7a97ea1618a及用户“空格选字、文字和光标均正常”见text-ime-handoff.json和IR/ime-acceptance.json（IR为D-TEXT-SOURCES-01/run-20260914T124235Z-ime），不再次重复真人检查。

普通退出PID76944(exit0)后从显式启动器用同一隔离UUID新PID79140冷启动，再正常退出(exit0)。项目9/10按原字节保留project.v9/v10.backup.json后迁移11；旧来源/引用/回答、Unicode正文、图像/声音/视频采用状态、模型选择和全部媒体字节不变。新问答撤销状态、新器乐拒绝记录恢复。独立原项目副本保持原文件摘要。R/combined-gui-r2/cold-reopen.json全部检查通过；只证明同机同身份正常退出重开，不是物理外盘拔除、跨机授权或公证验证。

### 事件、来源和恢复检查点

屏幕控制 -3812 重连未恢复，用户重新解锁后同一PID窗口恢复；没有扩大权限。两次剪贴板超时均先以实际界面确认文本已写入再生成。Lead第一次组合构建器CPU因未建既定临时目录在setup失败；创建自有目录后原代码/测试20方法通过。merge help预检曾只读stderr/错误匹配`--[no-]`选项而拒绝，修正只读检查后再更新源；前面失败均未更新源。既有预检编排/过早审核问题继续保留，不把环境或Lead时序问题全归Worker。

源入口三组复验结束；本批所有Worker/审核/构建/推理/GUI自有进程已结束。源只留个人scheme原字节/摘要ca3635d88aa5a15397b90e528667c66c0e6db7e596176e885c79d194b544206c、索引blob9c76916bdc97c2d4298cefe64e0b0fae3380573e及未暂存orderHint1→6，未纳入任何提交；普通D四文件、原项目与新App关键文件保护核对留R/protection。候选工作树/分支和历史证据保留。未创建系统写锁，也未改签名、全局配置或下载内容。

本次结案只更新README、CURRENT_ACTIONS、PRODUCT_GOALS、FAILURE_AND_PERMISSION_AUDIT及本任务五份Markdown；最终源HEAD/普通工作分支push结果与保护/进程检查写R/final-receipt.json，不为自引用再次提交。最终代码/测试/夹具与aba完全相同，不能宣称测试在其后文档提交上重跑。

工程有限闭环通过；受限CLI协作按原机制完成，重要Lead变化有非实现者检查；经济性仍未知。记录到的Worker各轮墙钟是局部运行，不将累计usage快照相加，不重算历史样本，完整Lead归因及实际订阅费用unknown。H09仅待麦克风；HUM文件薄识别、专门歌声、I2V/高级资料检索仍为分开目标。下一动作只提HUM有限文件闭环，新的依赖/模型具体授权与任务须另行确定，本阶段到此结束。
