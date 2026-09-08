# T0 工作台有限闭环

2026-09-08 用户本轮目标已批准；source_base=6735266933773adaee33b3a66a01b09c0b1f7d9b，prior_tested=c3197ad9cdade3d486a4153418cacc39af85bc81。旧审核/完整回执已核对，最后仅10份文档变化，scheme未暂存原内容不变。batch_id=D-T0-WORKBENCH-01，contract_revision=1。Lead独占本记录和共享接线，使用当前已验收受限CLI机制，不再做机制试点。

## 最小行为表（冻结）
| 事件 | 结果 | 必须拒绝的反例 |
| --- | --- | --- |
| 新建文字文档 | 同一.dproject内命名文稿、独立id/revision；既有图像文档保留 | 将模态改为独立顶层项目/覆盖旧项目 |
| 选择文字并改写 | UTF16 Character边界，捕获文档id/revision、选区和选择代次；原文不变，流出仅显示候选 | 半surrogate、ZWJ/组合字符内部；延迟编辑回调写入其他文档 |
| 生成中改原文/换选区 | 保留实际用户编辑；旧候选可查看但不再接受，即使选区改回也不复活 | 将旧结果直接应用到当前同样长度的选区 |
| 接受/拒绝/撤销 | 明确接受才替换；拒绝不改原文；仅未后续人工编辑时可撤销最近接受 | 跨版本/文档接受；旧撤销覆盖新输入 |
| 生成/待处理候选时导航 | 有限首版提示先取消并等清理，或接受/拒绝候选；不静默丢弃 | 切文档/项目把结果送给新对象 |
| 保存与关闭 | 自动去抖＋显式保存，写入序列化；导航/关闭flush最新原文。失败保留内存、阻止离开并可重试 | debounce取消导致已排队写入丢失、旧snapshot回写、失联回落内盘 |
| 重开 | 正文、id/revision在原项目恢复；选择/候选/撤销不跨关闭持久化，关闭前需处理候选 | 宣称候选或撤销已永久保存 |
| 取消/错误 | 沿用TextDraftSession，直到outcome清理完成保持busy，错误不形成候选 | 关闭UI即放弃后端handle |

采用项目schema3明确image/text文档，v1/v2原始字节各自备份后升级；不改媒体或签名。格式迁移在候选完成验收前不得用于用户项目。图像入口/既有工作台逻辑持续回归。文本模型由App装配现有MLXTextBackend，与图像共用runtime/重推理许可；本轮只准已批准固定Qwen2.5-0.5B-Instruct-4bit及revision，用户选择现有目录，无安装/下载。保留security scope至取消清理后，模型登记独立于图像安装器；不为本轮重建通用模型平台。

## 分工和验收

D-T0-STORE-01负责限定项目值类型/存储及migration测试；D-T0-VIEW-01负责新文字视图/原生选区桥及对应测试。各自独立工作树、精简规格、gpt-5.6-terra/medium，网络关闭，初交+最多2修复；Lead负责ProjectSession/WorkbenchModel/App装配、共享文件和集成测试。重要Lead实现由非实现者只读审核，最多2子执行/评审同时活跃。无需为并行新建包或空类型。

CPU：原工作台117/核心17回归＋新增存储/选区/协调/保存失败反例，旧schema断言只有从2更新到当前3的明确演进，不删原保护断言。全应用隔离DerivedData及已存在依赖，代码签名关闭只证明编译，不证明运行签名。真实当前模型和GUI必须确认用户D/GPU无争用及独立会话/项目；不能则保留整个候选批次，不将schema3/新UI默认接入源或安装普通D。GUI查询本轮曾长时间超时，未知资源/权限不靠重签或关应用解决。

证据 /Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-T0-WORKBENCH-01/run-20260908；普通源个人scheme不入任务树。输出/缓存/临时归各自run。无网络下载/签名/权限/依赖修改/推送/main操作/清理。只对自有进程限时回收。到此产品检查点停止；音乐/HUM紧接独立数据/普通试听路线，不等文字高级功能，META PNG另包。

Lead实现清单补充：新增DWorkbench/Text/ProjectTextController.swift及其CPU协调测试；新增DWorkbench/Models/FixedTextModel.swift与已存在fixtures/text-model.json的资源副本，用于固定本地模型只读校验，不引入下载/依赖/新精度。Lead负责选择代次、写入排队和关闭保护，后续非实现者审核这部分重要实现。

Lead组合初验24afbd6共139方法中有1方法4断言失败：保存失败夹具只追加JSON空白，verifyUnchangedManifest现有语义以decoded manifest比较，空白不构成外部内容变化。本轮将夹具改为实际改写外部textDraft正文，保留全部保护断言与原失败证据；这是Lead夹具错误，不计Worker逻辑失败。另发现规范等价Unicode外部正文的字节变化可能被合成Equatable忽略，正在以独立反例核验，必要时使用STORE剩余1轮修复。

Lead装配复验c215：完整141CPU/离屏方法通过。额外外层禁网Seatbelt与SwiftPM自带sandbox_apply冲突(exit74)，移除仅本任务额外包装、保留原生SwiftPM沙箱/固定离线副本/skipPackageUpdates/Git protocol.allow=never后，实际编译发现DApp漏import DWorkbench(exit65)。一次局部Lead修复并记录；不归Terra。只读核实既有scripts/download-test-model.py第24/25行及已批准目录包含.download.lock(0B)、.provenance.json(2120B)，FixedTextModel现仅显式容许这两份有界regular/no-follow管理文件，不把它们当权重或身份依据，全部固定模型文件及摘要仍强制校验、其他额外文件仍拒绝。新增显式D_TEST_TEXT_MODEL环境启用的CPU校验方法；未提供路径的其他机器应明确跳过，不是推理验收。本机本轮提供现有路径，绝不下载。

## 2026-09-08 候选交付检查点（真实产品验收待完成）

状态：**组件/生产存储接线/组合CPU与应用编译通过；真实改写和GUI未验收；未源接纳、未推送。**
源仍为 `6735266933773adaee33b3a66a01b09c0b1f7d9b`，codex/inference-foundation。实际受测代码 `62fc7b5dd568e5f53354382dd189d09e96b7e0bc`。
候选在 `/Volumes/CodexProjects/Codex/D-Worktrees/D-T0-WORKBENCH-01`，codex/d-t0-workbench-01；结案后仅文档差异，最终完整SHA见外部 `final-receipt.json`。源未快进，不能称为用户已经在普通D里可用。

### 实际增量及产品边界

同一项目内可新增命名文稿。UI使用原生NSTextView和SwiftUI，控制区Liquid Glass、正文中性底色；选段改写在独立候选区展示，接受才改正文；拒绝、受保护的单级撤销、显式保存及400ms去抖自动保存已接入。文字和图像由同一InferenceRuntime与现有MLX许可执行；固定Qwen2.5-0.5B-Instruct-4bit不改变精度、参数上限或下载行为。

文档id/revision、Character对齐UTF16选区、选择代次都参与失效判断；选区改回也不复活旧结果。模型校验前捕获选段/意图，校验期间原文变化会拒绝本次改写而不悄悄换对象。正在运行或待处理候选阻止导航/关闭；等待取消清理后才释放。保存排队按前次已保存revision串行；失败保留内存原稿并阻止离开，重试不覆盖外部修改。移位项目重绑运行时保留未保存正文及其持久化revision。

持久化schema3在原.dproject保留图像、任务和媒体；v1/v2原清单按原始字节分别备份后迁移。正文/id/revision保存重开；选区、候选和撤销不跨关闭持久化。格式迁移尚未在普通签名应用验收，**不使用候选打开真实作品，不默认启用或合入源**。不是完整写作平台、多步编辑历史或专业模型质量承诺。

### 来源与返工

| 角色 | 实际任务、目录/线程 | 版本与结果 |
| --- | --- | --- |
| Terra/medium Store | D-T0-STORE-01，独立工作树同名；CLI 01a0805e-790b-74e0-a349-e9962002ab93 | base ad984b7003d11ed854342a7784f052bec86c713a；初交1a98c5e19fdb4c103c3478f0520253e7577b9633；修复1 b59ceac3642511f1c823bff0453ad460d8918a5a；修复2 fd1bbc22bf849ca9d4c09fa6d79f001ac938df79。两轮预算已用尽。 |
| Terra/medium View | D-T0-VIEW-01，独立工作树同名；CLI 01a0805e-9228-7d80-8ca4-f1770b403146 | 同base；初交45604b851574936484338ca8a28ae9711c4888c5；修复1 64ceb4de180a799a75807eddf0a7467c9604948e；修复2 5047fe41bfa39bce8723d1cfca74dd5f32985b02。两轮预算已用尽。 |
| Astra Lead（当前主会话） | 契约、ProjectTextController/ProjectSession、App/Workbench接线、固定模型登记、独立反例和组合测试、隔离合并 | 实质接线7a29d6e3010b742a51b821c8c261c3fa2afd5b21；最终局部修正62fc7b5…。不是Terra独立完成整个闭环，也未代写Worker实现。 |
| 非实现者 Terra/medium，只读 | 01a0807b-a270-76b0-9c2a-88b88e1db6a7，read-only | 审6a08bbf1fe573230d1f255744b8a0cede776e70d、c215c567e7ee8f6ead46056a93050cad7f1676e9及62fc7b5…差异。确认Unicode保护阻塞后复审关闭，最终无新增静态阻塞；没有执行测试、GUI或模型。 |

两Worker实际请求及客户端运行均可核验gpt-5.6-terra/medium、自己的外盘cwd、workspace-write；写根仅该worktree与各自worker-output/tmp，网络关闭，共同Git管理目录无写权限。各轮实际模型/权限上下文见外部runtime-observations.json。隐藏服务端解析unknown；未新做桌面自动派工试验。Lead代提交沿用原人类作者配置，来源按task/run关联。

Store由Lead反例先确认：同正文新revision被no-op丢失；随后确认规范等价Unicode外部正文会被Equatable掩盖。均先失败后修复通过，未删断言。View修复原选段比较、IME回调/光标/滚动，并修正真实编译发现的CGFloat歧义。Store/View各自初交与两轮修复历史保留，没有第三轮或新编号重置预算。

Lead自己的失误单列：首次组合保存失败夹具只加JSON空白，现有decoded manifest语义不把它当内容变化；改为真正改变外部正文，保留全部保护断言。App入口漏import DWorkbench导致应用编译失败；实际安装包含下载器两个管理文件，修正初始exact-set假设。重要Lead实现和后续模型登记改动均经非实现者只读检查。

### 验证与证据（不重复累计方法数）

证据根：`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-T0-WORKBENCH-01/run-20260908`。

| 检查 | 实际代码/范围 | 结果及索引 |
| --- | --- | --- |
| 存储局部 | b59ceac→fd1bbc2 | 40方法后新增Unicode反例先失败，最终41方法通过；store-initial、store-repair1、store-unicode-counterexample、store-repair2 `.json/.log` |
| 视图桥 | 64ceb4d→5047fe4 | 首次编译失败，最终7离屏AppKit方法通过；view-repair1/2。不是中文输入法真人体验验证。 |
| 组合 | 24afbd6→c215c56→62fc7b5 | 首次139方法中Lead夹具1方法/4断言失败；后141通过；最终**142方法、18套件通过，零跳过**（含显式现有权重CPU摘要1方法）。combined-initial、combined-final、combined-verified-model。 |
| 纯核心 | 62fc7b5 | **17方法、2套件通过**；core-final |
| App装配 | 62fc7b5 | **BUILD SUCCEEDED**；app-build-final.json/log及app-build/final.xcresult。独立DerivedData和离线依赖副本，CODE_SIGNING_ALLOWED=NO/CODE_SIGNING_REQUIRED=NO。不证明普通签名沙盒、发布或运行。 |
| 现有权重 | 固定revision a5339a4131f135d0fdc6a5c8b5bbed2753bbe0f3 | 生产FixedTextModel.verify只读检查10个固定模型文件及摘要，目录/文件大小mtime前后不变；显式D_TEST_TEXT_MODEL启用。未加载MLX、未生成文字、不能当模型质量验收。 |
| 非实现者审核 | 6a08bbf/c215/62fc差异 | review-initial内gate、review/delta/model-delta-request/process/response/events及运行上下文；最后无新增静态阻塞。 |
| 真实产品操作 | 新T0候选 | **未执行**。CUA getApp(D)长时间超时，无可用界面/运行资源状态；没有重试长挂起操作或关闭D。用户空闲确认问题尚未获得回答。 |

CPU方法由Lead以swift test --package-path <明确工作树>/Packages/UI运行，独立scratch/cache/config/security和D_TEST_TEMP_DIR；最终组合额外显式设置D_TEST_TEXT_MODEL到已批准目录。测试来源、完整命令、退出码、工作目录、受测SHA记录在上述JSON；核心package-path为工作树根。新权重测试在未显式给路径的其他机器会标跳过，不能据此声称权重检查通过。本机此轮确实执行，无下载/安装。

编译首次额外Seatbelt外层与SwiftPM自身sandbox_apply冲突(exit74)。只移除本任务多加的包装，保留SwiftPM正常沙箱、现有离线副本、禁更新和Git禁网后，发现Lead import错误(exit65)，最终修正通过；没有--disable-sandbox、全局权限变更或签名方案改动。Xcode首次错误bundle落在系统临时目录（日志给出精确位置）；后续显式-resultBundlePath写回任务目录。完整build自动执行LaunchServices登记隔离D.app（日志可见），没有启动它；后续必须按明确产物绝对路径定位，不以名字D猜测对应程序，不宣称系统登记零变化。

另一次仅Lead任务消息准备脚本报告UTF-8解析错误；内存decode/compile可通过但直接解释仍报错，原因unknown。未产生Worker运行，后续改为复制ASCII任务消息，未更改项目实现/权限、未增加实现预算。保留事件摘要，不把准备失败归模型能力。

### 保护、消耗与恢复

开始保护start.json/protected-scheme.plist；结束source-protection-end.json核对完整diff、内容摘要、索引blob与未暂存状态。源只有用户scheme orderHint1→6，SHA256 ca3635d88aa5a15397b90e528667c66c0e6db7e596176e885c79d194b544206c；索引blob9c76916bdc97c2d4298cefe64e0b0fae3380573e，未暂存、不入候选。源HEAD未变、索引干净。未改写/关闭普通D、没有真实作品迁移、没有模型或权限/签名修改；不能凭进程句柄证明用户D/GPU状态。候选、两Worker工作树、失败证据和隔离产物全部保留，无清理/推送/main操作。

本批可观测运行耗时逐次列runtime-observations.json，不与旧DIAG/RESULT用量重复。完整Lead耗时/token及订阅实际费用unknown，未套用API单价。两个Worker都需两轮返工，Lead负责实质接线与反例、另有静态审核；本批不支持“成本已最优”的结论。后续相似任务继续按风险和规格就绪度用0—2 Worker。

所有本批CLI、CPU与编译自有进程已结束；无全系统进程清理或写锁声明。最后文档提交自身SHA仅写外部final-receipt，不反复自引用提交。恢复先核对源/候选完整HEAD、个人修改、活动任务和权限，再按既有授权继续剩余验收；禁止把本检查点当成T0真实闭环通过。

**最小剩余动作**：确认D及其他本地AI任务空闲，恢复Codex对明确D产物的界面控制响应；随后在既有签名/授权范围使用独立测试产物、独立项目和已有固定文字模型完成真实改写与GUI选段/接受拒绝/撤销/保存重开。没有新签名/权限批准时不得临时绕行，未具备条件继续保留候选。通过后复核并按既定规则本地接纳，无需重新制定产品目标。

音乐、HUM及资产来源保持已落地路线；下一独立音乐/HUM包以原声/自由时间/音符数据和普通试听为有限出口，不等文本高级功能或META全部完成。本轮没有启动它们。
