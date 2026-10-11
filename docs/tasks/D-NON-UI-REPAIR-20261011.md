# D 非 UI 可靠性修补与有限文档整理

2026-10-12 当前后续：D / DHA-01；原 2026-10-11 D-NON-UI-REPAIR-20261011 的实现、接受回执和证据保留。DHA-01 明确授权推送独立工作分支，停在独立复审；不合并 main、不部署或替换普通 App。

## DHA-01 2026-10-12

- 固定对象：预期和实际起点 N=`49e8c4a9e7560ceb283b44ec2163e726242e724e`。开工时原候选没有后继，N→实际起点为空；原候选保持不变。新树 `/Volumes/CodexProjects/Codex/D-Worktrees/D-DHA-01-20261012`，工作分支 `codex/dha-01-20261012`。本轮唯一外盘证据根 H=`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-DHA-01/run-20261012-01`；最终 SHA、完整实际起点→交付/N→交付差分、远端 SHA 在 H 的交付回执，不用自引用提交。
- 核验：旧 DHA 审计所用 detached N、原反例补丁、命令及日志相互匹配；原反例 1 方法/2 情景、exit 1，14 个断言失败，对照 1 方法/4 情景 exit 0。因起点及证据可比，复用原失败基线，没有无理由重跑旧全矩阵。原审计目录及其字节不变。Downloads 审计附件开工已读，后续原路径缺失，不伪造文件摘要；原始交接、最新审计和外盘反例仍可核对。
- 原因与边界：严重诊断已进入候选，但真实 candidatesChanged 的历史保存失败会遮蔽原错误，Executor 的 saving 提前返回让计算步骤残留 running，恢复可能再计算。本轮以内部错误携带主/次诊断，让失败步骤及控制祖先先进入 failed，保存状态独立为 saving。恢复只保存失败记录，保留候选/run/step/attempt/目标身份，成功仍 failed；再次失败保留原诊断与最近次级保存错误。没有新增公开契约或 Store schema，不改 Runtime/后端/依赖，不替换真实候选消费者。
- 真实 UI：历史按钮在失败记录待保存时为“重试保存失败记录”，保存成功后的 failed 为“重试计算”；普通 saving 保留原语义。主要错误优先显示原严重诊断，完整文本可查看；反馈不再把失败记录称作已计算结果，不误称保存后继续流程。
- 协作：本轮由主智能体单写；三个协作智能体只读核验/复审，不运行构建、不宣称继承权限等于写隔离，不递归。原树、scheme、项目、模型和其他工作保持保护。A2首次实际编辑复制继承，不扩 UI 改版或重修已关闭 P-01/P-02。
- 验证：初轮经真实 `scripts/test-workbench.sh` 严格依赖入口编译成功（270.25 秒）；DWorkbench 13 方法/28 参数展开情景通过，覆盖原反例、两种严重错误×候选/终态保存失败×取消交汇、连续两处恢复写入失败、显式重算、Invoke祖先failed、精确PNG/身份冷读及普通结果对照。R1增量 A2 3 方法/5 情景通过。合计16个不同核心/继承回归方法、33情景；不将重复执行相加。命令、环境、每次源码补丁、日志、退出码和逐方法计数见 H/{initial,repair1,repair2}-{command,result,summary}.json 与同名 .log。
- 未验：真实生产恢复按钮宿主 1 方法/中英2情景，初轮及两次有界宿主修正均停在AX按钮定位前置，未执行标签/点击/动作断言；三次总命令 exit 1，不能写作全绿。R1加容器/诊断、R2仅显示测试自有窗口，未改恢复行为或降低期待。随后唯一一次CUA桌面检查明确返回 Mac locked / automatic unlock failed，按规则停止，不轮询、不改权限。按钮实现已源码复审，但实际点击和完整错误/反馈可读性需桌面可用后独立验证；也不能据此认定产品按钮有缺陷。
- 环境及保护：macOS26.6.2(25G83)/arm64，Xcode27.0(27A266a)/Swift6.4；21项锁、解析与checkout相同，24份锁/manifest未变。原源/N/B树、main、个人scheme内容及索引不变，既有5个项目共404文件摘要不变；8份原审计证据不变。测试无真实模型/GPU；没有构建、部署或替换普通签名App，不代表发行通过。
- 复审停点：未参与实现者分别复审核心边界及真实UI消费者；指出的旧失败诊断遮盖新IO错误风险已修正，源码复审未留阻断，日志核验另见外部回执。自测/源码协作复审不替代交付后独立验收。本轮按授权推送修补工作分支并核实完整远端SHA，状态由 H/DELIVERY.txt 和 final-handoff.json 关联；不合并main。下列章节为2026-10-11原交付历史，不授权自动推进下一阶段。

## 身份与复用

原审计 B `178d5685e1ff953e790a7e6dc112273d6f7e54dc` → 原有限补丁 P `bb821f1fe31a263d33b1feeb33ee3cf3e7294d74` → 用户此次批准的两处 A2 收尾 `708e35f4531b0dfe2ec7a0ca1a11b335b12496c4`（本轮起点）。A1/A3沿用P独立复审与原有效证据；没有重新实施。P01/P02在P中仍存在，已在708完成此次获准收尾；旧初交/两次返修/Lead收尾预算不改写。

A2产品代码在 `d34ddd79f0f8d7c6a8084d0bd8406fe91eee0f93`，随后两提交只改测试。原P产品反例先失败；`5cc4d9d7c0357a5f71bd1e56701de8bebf51c8dd` 68方法/4suite通过，708再定向1方法/2场景通过。不是69个不同测试。非实现者`a2_closeout_review`接受源码/受控层；登记后项目切换的旧controller提示不承诺在新项目可见，普通App未验。旧Backend锁覆盖仅是A2受控条件，不关闭DIA09。

复用的P独立报告：`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-INDEPENDENT-P-REVIEW-20261011/reports/D_Independent_P_Review_2026-10-11.md` §3/4（A1/A3源码及受控成立、原生未验），不冒充本轮重审旧实现。

本轮固定入口保护详见[当前行动](../CURRENT_ACTIONS.zh-CN.md)。任务包19个文件已按清单核验；审计原件不变。外盘唯一证据根（下称R）：`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-NON-UI-REPAIR-20261011/run-20261011T095142Z`。主说明为本页，最终只有一份独立复审报告；日志/原失败与完整差分留R，不复制媒体入Git。

## 问题、风险与最小证据

| 项目 | 起点复核与修补 | 验证/状态 |
|---|---|---|
| DIA09 | UI锁缺完整闭包，App真实外workspace缺锁，development脚本查错内workspace。已有Backend固定pin作为来源，实际严格解析要求21项；19项缺NIO的失败保留，无依赖升级。脚本现在检查实际外层锁，测试入口固定依赖，支持独立App包缓存。 | 严格解析21项通过；development脚本20项通过。新增缓存参数初版Bash3空数组失败，经非实现者发现并修，定向1项通过。最终Q干净UI入口通过；实际App脚本干净严格构建通过（禁签名）。 |
| DIA05 | 原审计反例在本轮起点再失败：只读backup重新授权旧Quick字节。 | 每个Controller以Store/owner/精确bytes/revision的独立token保存；只读验证不刷新旧写入基线。初版55方法/4suite通过，补独立token发布后失败重试1方法通过；最终Q同版组合回归通过。 |
| DIA08 | 原审计结构化引用反例再失败。 | 完整引用匹配，局部节点字段/Map/Loop/Branch、工具和历史checkpoint保留可解释位置，按节点/派生资产/run去重。与Store组同次回归通过，不改删除决策。 |
| DIA06 | 原服务反例再失败；待发布图像因模型不可用不能保存。 | 已有pending先保存，缺失候选才取冻结模型。Controller.resume和Quick.retrySave真实服务链、PNG完整字节/元数据/请求身份、冷开、重复失败/取消/关闭及多候选通过。仅同存活Services内存pending。 |
| DIA04 | 两类权威错误与取消并发的原反例再失败。 | 两类权威错误先于取消，进入真实Controller/候选历史；普通取消/失败/成功回归通过，不改Runtime隔离政策。 |

原始反例：`lead/nonui-before-{command,result}.json`、`logs/nonui-before.log`（3方法失败）；`lead/dia04-before-{command,result}.json`、`logs/dia04-before.log`（1方法两类错误失败）。A2首次新增夹具编译失败单独保留，不计行为反例。图像初版9方法通过（含2个原审计反例）；覆盖补充4方法通过，不能合计为13个不同方法。Store初版55方法含原审计反例，补充1方法通过。命令、fixture路径、精确代码/叠加版本、退出码和耗时分别在R/lead/{store-after,store-repair1,image-after,image-repair1}-{command,result}.json，原日志在R/logs。

## 协作与边界

Lead协调A2、构建、集成和文档；Store与图像各一位独立CLI Worker，分别负责DIA05/08与DIA06/04。请求及实际可观察上下文均为`gpt-6.1-sol/high`、`workspace-write`、network=false、approval=never；每人独立物理树、分支/索引、output/tmp，公共Git不授写。预检之后才IMPLEMENT；无递归。模型隐藏服务端解析unknown。各新任务初交25分钟（持久化/异步身份复杂度）、最多两轮定向修复；旧A2预算不借此刷新。

Git shim只读查询发出FSEvents/cache发现诊断，xcrun缓存在获准tmp；Lead检查后明确用已选Xcode的Git，未扩权限、未重试外部写入。运行上下文和异常记在R/workers各目录。未观察到成功越界；系统内部不可见部分不声称证明。模型身份不是质量保证，Lead/Worker/复审归因和消耗以实际记录为准，完整Lead归因与订阅费用unknown。两Worker各预检/初交/补证三次调用的turn.completed及墙钟在R/lead/worker-usage.json；是逐调用增量，缓存输入包含于总输入，不另相加，不重算历史费用。

## 组合与验证版本

两组Worker初交后各使用一次针对性补证（仅测试，非生产返修），均已停写。Store最终`e322ac75856e021cca1b0abe16ebf7d6476fe7af`，图像最终`01f33b076a7024916b1a20e260fb38c378e1fbb6`；没有Lead实质重写两组实现。非实现者对各自固定差分未留确定源码缺陷。保留双方历史合入隔离候选，组合代码/测试/构建入口Q为`f119b0cd0c5a60f53b28abae206a9979f9ca2391`，没有冲突，也未推进源或main。

从Q建立全新干净检出`D-Worktrees/D-NON-UI-VERIFY-20261011`，使用R/final-ui独立空build/cache/config/security目录经实际`test-workbench.sh`验证；随后以另一空目录执行实际`build-local.sh`/外层D.xcworkspace/D。实际UI脚本严格锁通过：DWorkbench 141方法/8suite，UITests的A3生产预览状态1方法/7参数场景/1suite；两次独立test-run的计数分开，不与增量结果累加。总命令耗时333.195秒；141方法执行6.773秒，A3执行0.056秒。21项依赖的锁/解析状态/checkout revision逐一相同；所有10份跟踪锁前后不变，检出干净。命令/退出结果及精确依赖在R/lead/final-ui-{command,result}.json、final-ui-dependency-identities.json，日志R/logs/final-ui.log。

Q的build-development脚本受控测试20项通过（18.923秒），包含实际外workspace锁检查与Bash3默认/显式参数；这是编排夹具，不是App构建。第一次遗漏既有必填D_MB_TEST_TMP_ROOT，0测试/exit5；补任务专属目录后原测试通过，无测试/产品变更。两次记录在R/lead/final-script-tests[-corrected]-{command,result}.json。实际外层`D.xcworkspace` / scheme `D`经原`build-local.sh --offline`（onlyUse/disableAutomatic/skipUpdates）严格构建成功，独立空DerivedData/packages/cache，耗时154.741秒，exit0。21项App依赖锁/解析/checkout完全一致，10份跟踪锁前后不变，检出干净。Xcode27.0(27A266a)、Swift6.4、macOS26.6.2、arm64。命令/配置/结束码见R/lead/final-app-{command,result}.json与final-toolchain.json，日志R/logs/final-app.log；签名仅用本任务临时xcconfig关闭，工程/全局签名未改。复用既有7引擎准备资源，未重新运行模型。禁签名编译不证明签名、普通沙盒App或原生操作。

编译产物为`R/final-app/DerivedData/Build/Products/Debug/D.app`；Info及可执行文件摘要由R/lead/app-artifact.json绑定Q。没有启动、部署或替换推荐包。Xcode定位为干净验证树`D-NON-UI-VERIFY-20261011/D.xcworkspace` / `D`；本任务实际构建参数以final-app-command为准，不将禁签名产物推荐为已通过普通沙盒验收的App。后续最终文档提交不变更Q的生产、测试、依赖或入口，测试仍绑定Q，不声称在尚未产生的文档提交上执行。

非实现者已分别审查Store、图像与Lead的A2/DIA09；组合完整差分及动态证据由`nonui_build_docs_preflight`独立核查，不参与实施。唯一最终独立报告落在R/review/final-independent-review.md；最终SHA、该报告结论与源/远端状态以R/lead/final-handoff.json为准。源码复审、核验Lead日志与亲自执行测试分别表述。

## 文档整理与历史

[历史索引](../history/README.md#non-ui-20261011)列明整理前固定P与替代入口。CURRENT只保留当前任务/保护/下一步，R1—R16失败/反馈/预算在固定全文及原任务可取回，原生门槛保留在[集中队列](../FAILURE_AND_PERMISSION_AUDIT.zh-CN.md)。PRODUCT_GOALS只修正节点/组合/UI“尚未实施”漂移；REPOSITORY_MAP当前表按格式20定位，旧schema12/16表固定归档，旧包/兼容保留。META/HUM重复联合段落改为自身贡献和固定T0/AUDIO原文链接；AUDIO两处相对断链修正。不迁走许可证或有效契约。

整理前后字节、位置与链接核验保存于R/lead/docs-map.json及docs-links-final.json；32个本轮修改涉及链接/锚点/固定Git blob核验通过（本地可取回，不声称逐一在线打开GitHub）。固定历史不重复复制，因此现行篇幅减少不意味着删除历史。本轮未清理退役代码或旧候选。

## 保护、尚未证明与恢复

构建、受控CPU、普通App、真实模型和发行分开。此次不重跑模型、GPU、全故障矩阵；服务注入错误不能写成全部真实后端已触发并验证。普通App文稿发布/资产查看/保存冷开、A1—A3原生及R16布局命中/输入/拖动等仍须明确移交；不因代码审阅关闭。

源/main/B/P的HEAD、索引与工作区状态已和开始快照逐项比对；scheme内容、完整差异、摘要、index blob与未暂存状态一致。结束核对在R/lead/protection-final.json。两位写Worker与自有测试/构建命令均已结束；未启动GUI/模型，不把不可见外部进程说成已终止。

保留全部候选/证据与源个人修改。恢复或对照用固定提交另建独立工作树；不reset、覆盖原项目或改写历史。最终SHA记外部回执，不自引用amend。本轮结束后等用户继续UI，不自动启动下一阶段。
