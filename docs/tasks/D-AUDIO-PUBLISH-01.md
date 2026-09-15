# D-AUDIO-PUBLISH-01：声音产物共享发布可靠性

2026-09-15；状态：AP1-R2已完成独立验收、组合与源接纳；推送结果见最终回执。用户批准继续下一阶段；本任务处理上一阶段明确留下的共享 P2，不重置 SING1/PREP1 预算或宣称整个歌声阶段完成。

## 身份、目标与职责

- task_id / batch_id：D-AUDIO-PUBLISH-01；spec_revision AP1-R1；contract_revision AP1。
- source_base：f2eb259d306d3fbcc5e9a3234fa3e514a7b5a406，codex/inference-foundation。准备提交后的完整 execution base 记于外部 worker/job.json 与请求，不在自身提交中自引用。
- Lead 集成目录：D-Worktrees/D-AUDIO-PUBLISH-01；Worker 目录：D-Worktrees/D-AUDIO-PUBLISH-WORKER-01，两者均在 /Volumes/CodexProjects/Codex；Worker 分支 codex/d-audio-publish-worker-01。
- run_id：run-20260915T024121Z；持久证据 R=/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-AUDIO-PUBLISH-01/run-20260915T024121Z。
- 用户价值：文件保存失败不误删其他文件、不覆盖作品、不回滚已交付文件。SA3、MRT2、歌声准备共用一个发布实现；后端保持简洁。
- 一个实施 Worker gpt-5.6-sol/high：异常/描述符/所有权边界风险较高但契约已明确。Lead 规格、独立反例、审核与集成；非实现者只读复核。许可研究独立只读，不占用实现文件。

## 精确所有权与输入资料

Worker 仅可修改：
1. Backends/Audio/Python/d_audio_contract.py
2. Backends/Audio/Python/d_singing_prepare.py
3. Backends/Audio/Tests/test_audio_backend.py
4. Backends/Audio/Python/tests/test_singing_prepare.py

Lead 单一维护本任务记录与当前动作/许可专题。必读本规格、AGENTS 的不可破坏边界/资源规则，以及上述函数和直接测试；按需读 SA3/MRT2 publish_exclusive 调用及各自 job 验证。历史证据只读 R 的前阶段链接，不默认读全部聊天/架构。上一阶段原失败见 D-SINGING-BACKEND-01/run-20260915T004329Z/candidate-collision；其私有修补已接纳，共享助手未修。

禁止修改 SA3/MRT2 推理实现/契约、Swift/界面/运行时/工程设置、签名/entitlements、依赖/锁、模型/许可文件、夹具金样例、用户 scheme、任务规格及其他文件；不增加新包/通用I/O框架。不构建、不运行 GPU/GUI/录音/真实生成，不下载、不接云、不启动/关闭 D。

## AP1 冻结行为

保留 public publish_exclusive(job, filename, content, validate=...) 签名（job是目标父目录，保留job=关键字兼容）、任意 bytes 输入、可选校验器和 Path 返回；歌声使用共享函数并传严格 JSON 校验，不把 JSON 变为全音频要求。SA3/MRT2 原有“初始空 job”入口验证不改；共享函数本身允许已有其他文件的合法父目录。

| 输入/边界 | 必须结果 |
|---|---|
| 正常、空字节、正数短写、中文/空格文件名 | 完整字节重读后一次发布，返回原目标，已存在无关文件保持；短写继续直到完成 |
| 目标已是普通文件/目录/悬空链接 | ContractError(kind=output)，不覆盖；不创建临时文件 |
| 固定 token 撞已有 partial（文件或链接）/排他创建被拒绝 | 不取得清理资格；不删除既有对象及链接目标，不生成目标 |
| 成功创建但 fstat 失败 | 报错并关闭描述符；未取得可验证身份则不删除身份未知 partial，允许明确说明残留 |
| 写入零/抛错、文件同步/关闭、重读失败或字节/身份不同 | 不发布，关闭自有描述符；仅清理仍是本次 dev/ino 的普通临时文件 |
| validate 拒绝 | 发生于发布前；保留原异常类型/kind/原因，不统一改成通过或其他 kind |
| 链接前目标被受控夹具创建 | 排他链接拒绝；新哨兵完整保留，本次 partial 安全清理 |
| 发布后目录 open/fsync/close、临时清理失败 | 报错但完整目标保留，绝不回滚删除已发布文件 |
| 清理时路径不在/换 inode/变链接 | 不在可视为已无待清理物；不同身份/链接不删除，正常路径遇不匹配须报告 output 错误；已有主错误不得被清理错误替换 |

只有成功排他创建并取得 fstat 身份后，才能按 dev/ino 清理；重读返回身份及 bytes 均须与创建/输入一致。成功和异常清理使用同一身份守卫。关闭失败不可用无界重试；保留第一个已发生错误，必要 secondary 信息可附注。无法取得身份或系统拒绝清理允许保留临时残留，不能以删除未知对象换取“零残留”。不承诺对抗 lstat/unlink 之间恶意并发替换；本任务只验证确定性受控边界及应用自有任务目录假设，不建文件系统安全框架。

歌声输出封装/ds 金样例/原始文本/输入保护、真实 CLI 成功0/失败2保持。共享函数不得把校验器 ContractError 的 kind 改写。删除歌声内部重复 publisher，保留局部选择/实现自由，不逐函数规定解法。

## 验收与运行手册

先在未修共享实现上新增持久静态 partial 碰撞反例，记录真实失败后再改实现。保留原21音频与17歌声方法/断言；歌声随机补丁可改为共享模块路径，不能为成功改金样例或降低标准。

Worker 为上表提供确定性小夹具/故障注入测试，检查实际文件内容、输入/哨兵、目录成员、完整输出及描述符状态，不能只断言抛异常。Lead 独立编写重点故障检查和复用原42歌声真实CLI/条件案例；非实现者复核实现与验收。既有四个 CPU 入口：
- Backends/Audio/Tests/test_audio_backend.py
- Backends/Audio/Tests/test_mrt2_backend.py
- Backends/Audio/Tests/test_audio_provider_access.py
- Backends/Audio/Python/tests/test_singing_prepare.py

使用唯一独立 Python：/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-VIDEO-V0-01/run-20260913T152419Z/venv/bin/python -B；不调用 Apple /usr/bin/python3、xcrun、Swift 或默认 py_compile。语法通过 tokenize.open 正确读编码，再 compile(source, filename, "exec", dont_inherit=True)，不运行目标、不输出目标 pyc。测试为显式行为执行，不声称无所有副作用。TMPDIR/D_TEST_TEMP_DIR/PYTHONPYCACHEPREFIX 全在 R/worker/tmp；报告仅 R/worker/output。运行 unittest 时可用现有独立文件入口，不安装依赖。

Git 仅 /Applications/Xcode.app/Contents/Developer/usr/bin/git；rg 为 /Applications/ChatGPT.app/Contents/Resources/rg。预检只读核 cwd/root/common/HEAD/branch/规格、允许文件/验收后暂停；Lead 验证实际 turn_context 模型/强度/权限，才发 IMPLEMENT。workspace-write，网络关闭，可写仅 Worker 树、R/worker/output、R/worker/tmp；共享 .git/源/其他树/模型/应用不可写；不自提交、不派子代理。

初交+最多两轮针对性修复，必要一次有界 Lead 接管；每次最多15分钟，异常先报、不能换模型/编号重置。权限拒绝未事先允许则停止相关动作；只可按预先指定无字节码入口/唯一缓存恢复一次且未成功越界。受控失败夹具不是权限事故。每轮 Lead 先查异常与保护再派修复；迟到旧修订不接纳。

CPU通过不等于新普通App/真实模型验收；本阶段无模型算法或Swift变更，不机械重跑推理。固定候选在隔离树整合、完整相关CPU与独立反例通过后源快进，源入口复验；保持 scheme 内容/摘要/索引/未暂存状态，保留全部候选/证据，可按长期授权推送工作分支，不改 main。

## 起始检查点

源 HEAD/唯一 scheme 与前阶段回执一致，摘要 ca3635d88aa5a15397b90e528667c66c0e6db7e596176e885c79d194b544206c；保护副本/完整差异/索引见 R/protection/before.json。源/任务 hooks、有效过滤/自动化无触发项。首次Git帮助解析只取stderr导致断言，任何写入前停住，读取stdout后修正检查并重核；不是权限/代码事件。

H20 Xcode协议与H21歌声材料许可/下载未解除，详见集中清单。新共享维护初始预算独立，旧SING1/PREP1初交＋repair1及剩余额度不改。许可研究不发送邮件、不下载材料、不据输出JSON声称实际歌声。

## 实施前澄清与许可支线

非实现者只读规格审核未发现行为冲突，指出文中parent是目录角色而非实际公开参数名；IMPLEMENT前已明确保留job=关键字兼容，AP1/R1行为未变。本行文档修正在Lead集成树，Worker使用准备SHA＋明确IMPLEMENT消息，不偷偷漂移执行基线。证据R/spec-review.json、worker/implement-prompt.txt。

H21限定研究已核官方声库、声码器与CC说明；当前无足够依据解除新材料门槛，未发送询问或下载。细节复用MUSIC_ROADMAP最新H21节，不新建许可管理平台。

## AP1-R2：关闭系统调用的平台语义澄清与修复1

初交候选287a86ffddffbea6003875d4cfbb9f224253c39d，Sol/high在同一受限CLI初交；仅四允许文件。Lead独立重跑30音频、21MRT2、11访问生命周期、17歌声，以及33发布故障和42歌声条件/CLI均通过；这些结果不抵消后发现的缺陷。

Lead代码审核发现_close_publication_descriptor在os.close失败后无条件再close同一整数。三个任务自有描述符夹具实证：首次关闭实际释放、同一编号被另一只读文件复用后返回注入EIO，重试误关另一个操作的fd；file-close、directory-close、error-cleanup-close均失败，哨兵文件内容未变。证据R/candidate-close/cases/summary.json、lead-close-check.py；未触及真实应用/作品。

从本修订起明确：**关闭尝试前交出该descriptor的管理资格，os.close报错后不再按该编号重试**，也不以fstat显示同inode作为可安全重试的依据。错误仍报告并保留第一个失败，发布后的目标仍保留；关闭结果无法可靠确认时标为未知，不宣称所有系统关闭失败均已实际释放。若故障夹具故意在系统close之前抛错而保留fd，由夹具在patch结束后回收它，不让实现盲目重试来满足假设。

依据[Python PEP475](https://peps.python.org/pep-0475/#modified-functions)：close属于不重试的特殊调用，报错并不保证原fd仍开放。本次为跨平台关闭/所有权语义的Lead澄清，原AP1的“不无限重试”不意味着允许一次不安全重试；不追罚旧规格未明确的关闭结果可观测性。原有作品保护/校验错误/JSON/CLI/模型边界不变，不变更21＋17原有断言；初交新增的“必须调用两次close”属错误实现耦合测试，应更正为真实释放/复用/错误优先的断言。

修复1仅允许d_audio_contract.py、test_audio_backend.py；先在初交实现新增永久反例并保留红灯，再作最小修补，重跑同四CPU与所有独立案例。执行基线为287a86ffddffbea6003875d4cfbb9f224253c39d；AP1-R2通过原线程repair1请求显式发出，Worker旧任务文件仍包含原R1历史，不从旧SHA实施；新要求摘要与证据位于其获准output，Lead完整记录只在集成树维护。初交已用，最多两轮修复，本次使用第一轮；旧PREP1预算不改。

## 2026-09-15：验收、源接纳与结案

本有限共享维护已完成，不代表D-MUS02真实歌声后端完成。原共享静态partial碰撞先红后绿；初交另引入/暴露的关闭错误重试风险由Lead独立发现并三场景重现，非实现者复核后修复1关闭。歌声删除重复发布实现，和SA3/MRT2复用唯一共享函数；job=兼容、原请求/模型/精度/输入保护/歌声封装与CLI退出语义不变。完整未知目录/描述符关闭结果、被拒绝清理残留与恶意竞态均不超出AP1-R2声明。

| 版本 | 完整SHA / 对应证据 |
|---|---|
| 源起点 | f2eb259d306d3fbcc5e9a3234fa3e514a7b5a406 |
| Lead准备 / Worker初始执行 | 4be5c8492d3badc182d3a2028cb663ddb8fc5439 |
| 初交，未接纳 | 287a86ffddffbea6003875d4cfbb9f224253c39d；R/candidate-acceptance.json原范围绿色，另R/candidate-close三项失败 |
| 修复1候选 | 08cb5aa4abfb18e2771567d8ad7c874c69b39287；R/repaired-acceptance.json及只读非实现者复核 |
| 组合与源实际受测 | 3186aba2762850152d285afa50dc7ed7e9e3eef6；R/combined-acceptance.json、source-acceptance.json |
| 最终源 / 远端 | R/final-receipt.json、final-version-map.json；受测版本后仅三份获准Markdown结案，不称在未产生的SHA重新测试 |

| 检查 | 修复候选、组合、源分别执行的结果 |
|---|---|
| 四个永久CPU入口 | 音频31、MRT2 21、访问生命周期11、歌声17，合计80方法每次均零失败；原21/17断言未降低 |
| Lead独立发布 | 33场景通过：目标/临时碰撞、字节/身份/校验、短写、描述符和发布后错误、第一错误保护 |
| Lead真实fd复用 | 3场景通过：正常文件close、目录close、主错误清理close；另有永久回归先红后绿，不叠加为更多产品场景 |
| Lead既有歌声/真实CLI | 42场景通过；旧金样例、原输入、错误/退出和Unicode不变；只是实际Python CLI，不是演唱模型 |
| 语法与范围 | tokenize.open +内存compile、diff检查和精确文件白名单通过；解释器/完整命令/环境/哈希见各result.json |

各版本重复执行不相加成唯一场景总通过率。外部driver仍保留最初独立失败，永久测试也分别先失败再通过。Lead验收方案在运行完整矩阵前按非实现者建议补强5处判定，见R/independent-test-review.json；随后追加close语义反例，未放宽已通过检查。

来源：gpt-5.6-sol/high初交＋修复1实现；Lead任务/平台语义澄清、独立反例、测试与审核/集成，未重写生产代码；非实现者singing_repo_integration_scope只读规格/验收/代码复核，未声称另跑测试。CLI0.154.0-alpha.6.2，线程01a0a2f3-54fd-7cd2-ab7e-d5a5868babb6，3次请求与可观察turn_context模型/强度/写根均一致、network=false，隐藏服务解析unknown。详见R/worker/*-observed.json、lead-*-event-review.json。Worker非零均为预先批准的红灯夹具，没有观察到未处理权限事故或源写入。

本任务使用1次普通修复，剩1次和可选有界Lead接管均未用；SING1/PREP1旧预算不变。Worker预检75.84秒、初交458.03秒、修复182.68秒，合计716.55秒墙钟；token保留逐阶段CLI累计快照，不相加重复计费，缓存输入不再加到输入总量。完整Lead/只读研究消耗与实际订阅扣费unknown；不是成本最优或Sol普遍胜任的结论。详见R/current-run-usage.json。

恢复检查点：源已快进组合SHA并从源入口复验；个人scheme完整内容、SHA256、索引blob与唯一未暂存状态均保持，证据R/protection/pre-source-ff.json、post-source-ff.json和final。普通D、用户作品、模型未被本任务操作，未重建/重签/启动应用，不宣称新App/GPU/真实歌声通过。所有本轮CLI/测试自有进程已终止回收，不删除任何候选/证据，不推进main；最终源/推送只以回执核实。

下一动作：H20由本人确认Xcode协议，H21由本人决定发送已写好的限定询问或提供权利依据；其后仅在适用许可和具体下载授权内继续短歌声薄后端。内部研发许可可与未来分发独立推进。HUM必要纠错/普通试听/MIDI与I2V保留原独立顺序；不为等许可再造无用户价值的外围工作。
