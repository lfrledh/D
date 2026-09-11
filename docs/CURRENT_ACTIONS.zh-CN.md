# D 当前行动指南

## 2026-09-11 真人返回收尾：NAV2已验收并源接纳；H09等待输入设备

源从fee074c70fb39bd9a99d146b708d6d80fd2d820e快进至实际受测bbfc72d3d4606ca96dc3c53b08fd59a602796f6f。本轮原生同一attempt UI9/9与宿主关闭2/2通过；源入口UI/工作台CPU报告291项，1项既有可选权重检查跳过，零失败。普通开发签名的隔离构建已恢复并核对，无测试权限例外。之后只有本次四份文档结案；最终源SHA与实际推送结果见`D-Development/AgentTrials/D-UI-HIERARCHY-01/run-20260911T110719Z-human-return`/final-receipt.json，不把测试绑定到尚未产生的文档提交。

新导航包括项目选择、顶部模态、模态内创作/参数/资产；跨模态浏览不改原文、候选编辑/收藏/采用、比较与基于实际条件派生、保存和最近项目/退出重开均有原生证据。源个人scheme仍为唯一未暂存修改，普通D未替换。音频生成/录音继续只在隔离DEBUG会话启用，H09/H15未过，不称整个音频阶段完成。

H16：用户报告已为xctest输入密码授权，具体提示资源未留存；随后控制会话和完整UI用例真实运行，当前阻塞解除，不推断永久TCC有效。H09：实际点击开始录音后AudioQueueStart返回InvalidDevice(-66680)；正常系统音频清单只有输出、无输入。失败预约与0帧CAF保留，未登记成作品；已正常退出测试实例。需要接入麦克风并确认输入电平后补短录音/试听/保存重开，不重复模型条款或全盘授权。H15的普通沙盒provider接线及显式录音格式转换仍是工程边界。

下一动作：核对本次固定源版本推送回执后停止NAV2；用户接好输入设备时优先补H09。后续产品工作优先完成音频引擎的普通工作台接线和真实候选闭环，不启动新音乐模型/HUM/META批次。详细失败、来源、审核和恢复见[任务记录](tasks/D-UI-HIERARCHY-01.md#2026-09-11-真人返回验收与源接纳)及[人工清单](FAILURE_AND_PERMISSION_AUDIT.zh-CN.md)。以下旧检查点按各自日期/版本保留，不作为最新待批准状态。


## 2026-09-11 NAV2 实装候选：组件/构建通过，完整原生验收待恢复

项目→模态→创作/资产/参数的新UI已在隔离候选实现；受测代码8c326f858ed9e6c908e144f9f3da49f579209b14（codex/d-ui-hierarchy-01）。全UI包报告291项/36套件通过、1既有条件权重检查禁用；App及UI测试构建通过，非实现者差异审核已收齐。原生实际窗口已确认项目页、文稿保存/图文切换、窄窗选区/参数可达；XCTest初始化阻塞、CUA近期项目重开时管道关闭，完整9场景未通过，不默认接纳或推送。

源仍fee074c70fb39bd9a99d146b708d6d80fd2d820e及唯一未暂存个人scheme；普通D四文件保持。旧VIEW三项工程缺口已在获准NAV2限定Lead收尾中通过，但音频H09/H15、普通沙盒provider仍单列未验收。当前资源窗口已获用户确认，不重复条款/下载/麦克风能力批准；待核实控制连接/可见系统提示。任务、来源、进程、证据和下一动作见[最新NAV2检查点](tasks/D-UI-HIERARCHY-01.md#nav2-实施恢复检查点组件装配通过原生完整验收受阻)与外部final-receipt.json。下面各日期记录保留当时事实。


## 2026-09-11 新导航方向：先项目，再模态，再创作

用户已要求重整UI层级。普通启动先项目选择；项目内顶部图像/文字/音频模态栏；各模态内创作、候选、参数与项目资产筛选分开。资产默认本模态，可勾选其他模态；浏览不改变当前文档/候选或复制媒体。详见[UI层级方案与下一阶段工作包](tasks/D-UI-HIERARCHY-01.md)。本轮设计与可点击结构草图完成，未修改Swift产品代码；18组草图布局/交互组合检查通过，不是原生App、GUI或模型验收。

下一实现从Lead共享导航契约开始；就绪后可并行壳层和资产投影两个独立任务，再串行装配既有图文编辑器。音频复用AW1已过服务，旧VIEW三项缺口及预算0保留，不能借改名重置；H09/H15仍需之后真实验收。项目归属/模型/精度/签名不改，未默认启用音频候选、未操作普通D、未推送。源起点31b351240778f005c0ef5cb51b0e0d1e6b0db3b0；本轮最终源仅以下有限文档变化，完整SHA/保护/审查与原型证据见 `/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-UI-HIERARCHY-01/run-20260910T233410Z/final-receipt.json`。

## 2026-09-11 AW1第一阶段检查点：服务通过，产品尚未整体验收

D-AUDIO-WORKBENCH-01获准第一阶段已完成可独立推进的录音所有权、生成存储和共享服务；新界面仍未接纳，真实产品闭环未完成。源本轮只追加状态/待办文档，生产代码继续633150477de90d30c1f44c915b1f10e13acd246d，schema5与新AI界面未默认启用。

录音受测971a669c70d3148f65693701182c8ae3721b25f6，CPU251项报告/1既有可选跳过，非实现者复核接受；存储受测690408ed2e786b9470cef1dfcce522e022751ab0，全UI包CPU260项报告/1既有可选跳过；共享服务最终受测d6b7d1ea5df72730ed9c198d8df56d5c17bb6d5c，219项报告/1既有可选跳过、零失败。集合重叠不相加；新视图不在该全包版本内，未做完整App装配编译。生成/变体/重绘服务验证使用真实DRuntime和合成音频，不能当作真实模型/GUI验收。

批次候选 `0295618cb851511c8aa3c207a3a4b887913d7501` 位于`/Volumes/CodexProjects/Codex/D-Worktrees/D-AUDIO-WORKBENCH-01`；相对最终受测版本仅交付文档变化。详细[阶段记录](/Volumes/CodexProjects/Codex/D-Worktrees/D-AUDIO-WORKBENCH-01/docs/tasks/D-AUDIO-WORKBENCH-01.md)。外部持久索引：`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-AUDIO-WORKBENCH-01/run-20260910T140156Z/final-receipt.json`；最终源文档SHA写回执，不自引用提交。

E-AW-VIEW-01：Terra初交/两修、Astra一次有界测试接管后仍有来源切换旧区间残留、禁用原因提示不一致、离屏布局验收失败；预算为0，未合入。需要明确限定UI收尾，不是缺Mac授权。H09/H15为之后的实际麦克风及新音频工作台真人闭环；当前未获得新的资源窗口，未启动GPU/GUI。当前普通沙盒与隔离Python/provider访问、48k单声道CAF到44.1k双声道WAV的显式转换仍未验证/未实现，不静默转换或靠Full Disk Access代替。

来源：录音Sol实现后Astra有界修补及Sol复核；存储Sol初交/两修、Astra审核实测，无Lead代写；VIEW Terra及Lead失败测试收尾；共享服务Astra实现、Sol限定非实现者复核。费用和完整Lead消耗unknown。本轮不推送未验收实现、不修改普通D/个人scheme、不启动下一音乐/HUM/META任务。[持续待办](FAILURE_AND_PERMISSION_AUDIT.zh-CN.md#当前队列)区分工程问题与真人事项；旧阶段条目按其日期保留，不作为最新状态。

<!-- 以下为合入的AW1阶段历史检查点；当前状态以最新NAV实施记录为准。 -->

2026-09-11本轮检查点：AW1录音/存储组件及共享服务已通过CPU；最终服务受测d6b7d1ea5df72730ed9c198d8df56d5c17bb6d5c（219项报告/1既有可选跳过），Store690408ed全UI包260项/1跳过。VIEW仍未接纳且预算已用尽；第一阶段尚未整体验收，未启用源新路径。H09/H15待工程收尾后集中真人验收。参见[阶段最终检查点](tasks/D-AUDIO-WORKBENCH-01.md#2026-09-11-本轮交付检查点服务通过第一阶段尚未整体验收)及外部final-receipt.json。

2026-09-11 AW1更新：录音组件CPU/非实现者审核已过并合入隔离批次；VIEW在初交、两修及一次Lead接管后仍有验收缺口，已停止且未合入。STORE独立实施中，共享装配仍待验证。阶段尚未完成、源产品未变。工程缺陷不归因为用户不在；详情见[阶段任务](tasks/D-AUDIO-WORKBENCH-01.md#2026-09-11-中途检查点不构成阶段验收)。

## 2026-09-10 第一阶段：AI 音频工作台实施中

用户批准较大第一阶段。新隔离批次 D-AUDIO-WORKBENCH-01 从源633150477de90d30c1f44c915b1f10e13acd246d开始，保留历史合并HUM b191071ea8b6e2db7e2c93238cdc8048c2940c4a；不把旧H09修补失败说成已接纳。本阶段明确包含录音创建/writer/ProjectStore的所有权重整，以及生成、参考变体、帧区间重绘、候选试听/采用拒绝、安全保存重开/导出。普通D和源schema3目前不动，候选新路径仍受隔离门控制。

录音Sol/high与新创作视图Terra/medium各自受限工作树，精确文件范围不重叠；存储/会话接线按依赖串行协调，不凑并行。规格与恢复入口见[阶段任务](tasks/D-AUDIO-WORKBENCH-01.md)。人工需要当前设备/GPU窗口、实际麦克风点击/录音、声音比较/导出重开；用户不在则在清单H09/H15留待集中办理，不将历史空闲答复外推至本轮。

## 2026-09-10 收尾：音频后端已本地接纳；录音仍隔离

D-AUDIO-BACKEND-01有限后端阶段已通过真实验收并快进源工作分支。源接入前9b20e0f20039027ce75b2bae00bffa215bc1789e → 实际源受测 `59c3225f3b48ecc6f4fd26e94463d6787b8ec116`；真实修补代码 `a0bfd0ec47ec40f93c7342934fc82dfd0ac754d0`，二者仅3份合并文档差异。此后本次结案仅文档，最终HEAD和实际push结果写外部final-receipt.json，不宣称测试跑在尚未产生的文档提交。

SA3 small music固定6秒/8步/guidance1/seed42：真实生成、重复、参考变体、区间重绘通过，44.1kHz双声道float32 WAV；重绘2..4秒之外PCM不变。新实时管道在1/8步取消，CLI130、未发布产物，取消延迟约0.227秒，随后新CLI成功；超时失败后下一CLI也成功。同Runtime/租约交接由原CPU检查证明，不能把独立CLI说成同一Runtime。源目录新编译CLI另实际生成通过（5.076秒、WAV摘要0aa169b…），适配器和Vendor明确来自源目录。用户确认提示音及六秒样本“都听到了，播放正常”。MLX每子进程清理后18bytes/cache0，18bytes精确归属仍unknown；子进程实际退出，不承诺常驻模型无泄漏。

本轮组合：Python21、核心30方法通过；UI174方法报告，其中173通过/1既有可选权重检查跳过；后端43方法/102展开全通过；独立无签名应用编译通过，未启动。源入口音频21方法/44展开再次通过。各组有重叠，不加成总通过率；旧图文真实回归/768×512及1.5B真实改写取消复用原证据，不称本轮重跑。当前只有后端/CLI具备生成能力，普通D.app未替换，音频生成UI与schema4未默认启用。

H09额外路径修补未接纳：真实根因是祖先遍历未在根收敛，341个../导致lstat errno63；不是已证实系统授权缺失。Lead候选7184e6d…测试编译失败；非实现者Sol/high另指出遗漏UITests调用及验证到实际创建之间的父目录替换风险（创建代码原已存在）。保留在HUM分支 `b191071ea8b6e2db7e2c93238cdc8048c2940c4a`，只本地保存，不混入源。当前需明确扩大录音创建/写入与ProjectStore所有权契约后有界修复，不能追加一次点击或Full Disk Access代替。原诊断版重开已有测试备注/片段已看见，完整录音保存重开仍未过。H09-LIVE1原额外预算已用，未暗自重置。

人工队列更新：H11/H12/H14原授权均已落实；H14旧四文档/三分支已真实推送并远端核对。新代码/文档推送以本次回执为准。用户要求需要真人动作时仅播一次短音效、不调系统音量/不循环；本次已实际播放并获听感确认，不创建后台监听。未完成项只保留H09工程范围与之后实际麦克风/录音验收，不重复条款/下载/IME。

下一产品目标提案：接已验证后端，实现“提示或参考音频 → 新候选/圈段重绘 → 试听比较 → 采用/保留原件 → 安全保存导出”。优先复用声音候选服务，先解决与其依赖的录音/文件创建边界；录音不是文件输入生成的必需前置。精确乐谱/和声/歌词控制、HUM转谱、歌声和高配Mac矩阵分别推进，不以完整DAW/高级文本为前置。本轮不启动下一批。

恢复证据：`D-Development/AgentTrials/D-AUDIO-BACKEND-01/run-20260910T111515Z-approved-finish`，按需读runtime/candidate-preserved、cpu-red/green、real、merge-resolved、combination、cpu-source/source-real；recording/finish-stop与review/h09-response；source-fast-forward、final-receipt。个人scheme唯一未暂存、索引原blob、普通D四文件均保持；当前自有执行/测试/GUI进程已结束，以回执为准，不声称全系统写锁。

## 2026-09-10 集中实测新停点（覆盖下面上一续办状态，历史保留）

本轮文档推送在执行前被自动审批拒绝（包含本机路径/模型与测试审计内容的对外发布范围）；仅保存本地文档提交，无上传重试。具体H14与live-push-rejection.json保留，不把待办说成已推送。

H11真实SA3 small music6秒生成、repeat、变体、区间重绘已完成，固定精度保持；重绘范围外PCM一致。H12 1.5B除既有两次短改写外，本次两次真实取消/释放/下一任务通过。音频新取消检查未通过：双管道并发读取时进度被延迟至子进程结束附近；CLI130不能代替真实提前取消。两次同Python进程清理active18bytes/cache0且未增长，18bytes精确归属unknown。

H09仍未到系统麦克风提示，实际Start被祖先路径检查拒绝；建议在原项目rootFD内校验，原件不覆盖/许可前后重查均保留。H10真实GUI导入/播放动作/Unicode注释与帧片段保存/原件和片段安全导出通过；真人听感未答，重开检查时Mac锁定。自有实例已结束，普通D和源个人scheme未变。需要解锁后继续真人项；不重新要求下载/条款/全盘授权。

两个新生产修补超出既有原任务修复预算，保持提案等待额外有界授权：H09路径验证与H11双管道及时读取，均保持原标准、直接回归和非实现者审核；没有新Worker/生产修改/默认启用。源产品仍beaaaf82d845e672c6a3b661d928654affc00518；本轮源起点5e7e024f7194e5a7a15424c5254b1837ac8efee4，音频受测d1a5c26e3d2eda84ad7641a98b5aa33ce7f55407，HUM受测372a8acadf39b92faf4b17b6315f0f63774e4cff。候选未源接纳，不把候选实测写成用户普通D已具备。

证据入口：`D-Development/AgentTrials/D-AUDIO-BACKEND-01/run-20260909T152406Z-h11-authorized/live-acceptance-checkpoint.json`、`live-final-receipt.json`（最终版本/保护）；HUM同级`run-20260909T152120Z-h09-authorized/h10-import-export-verification.json`、`review/path-response.md`；H12 `run-20260909T151340Z-h12-authorized/cancel/lead-verification.json`。持续人工队列见[清单](FAILURE_AND_PERMISSION_AUDIT.zh-CN.md#人工协作待办持续维护入口)。下一步只是完成当前验收与限定修补，不开始新产品批次。


## 2026-09-10 集中授权续办检查点

H09/H10/H11/H12均已明确获用户批准，不再等待原授权。H12固定1.5B权重10文件880,170,545bytes完整核验；实际统一CLI连续两次中文改写完成，每轮release active/cache=0，峰值966,847,960bytes。受测二进制来自d1a5c26e3d2eda84ad7641a98b5aa33ce7f55407，候选03798abfe17229f7678f9fcd611df87da7c775ac仅后续文档；不是1.5B完整模型库GUI/取消/专业质量验收。

H11用户确认适用资格并授权固定small music四权重1,919,674,322bytes及独立依赖；下载完整核验，未代接受/注册。mlx/mlx-metal0.32.2、numpy2.3.5、sentencepiece0.2.2安装于新外盘venv，使用固定预编译wheel，原全局Python未变。首个6秒请求在计算前失败：当前Swift启动器解析python符号链接后运行基础解释器，丢失venv依赖。对照sys.prefix/find_spec确认；新建标准venv --copies保留明确真实可执行路径，CPU --inspect和完整固定权重/Vendor核对通过，未改实现/精度或注入PYTHONPATH。原环境/失败保留；此兼容限制不是SA3数值通过。

H09在独立HUM候选增加批准的用途说明和两个麦克风能力，并仅将DEBUG有效UUID+audio测试门传给recordingEnabled。Lead补正启用后仍显示“未启用”的旧侧栏文字；Sol/high受限只读复核先指出反例、后接受修正，未替代真实测试。候选372a8acadf39b92faf4b17b6315f0f63774e4cff普通既有身份签名构建成功；首版已核对Sandbox/Hardened Runtime及麦克风能力，修正版尚待重新启动/实际提示。没有替换普通D、变更Team/bundleID/钥匙串/TCC，schema4仍未源接纳。

H10用户最初已保存退出且空闲。首个自有测试PID37620创建本轮新项目后正常退出0；退出后CUA getAXState重新定位到“Model Library Acceptance”旧D窗口，尚不能确认其进程身份，未继续操作/关闭。已请用户保存退出该窗口；不能把它当本轮隔离实例。后续音频generate-copies启动被自动审批明确拒绝（仍有D运行、GPU空闲未重确认），命令未执行；没有换路径绕过。暂停GUI/GPU依赖项，独立CPU检查继续。不要再在Quit后调用D对象getAXState（工具可能重启/重定位）；用自有进程退出回执及仅枚举状态确认。

下一动作：收到退出/当前空闲证据后，重新以专属UUID启动已复核测试版，在真实“开始录音”入口交用户点击麦克风提示；完成短录音/试听与H10保存导出恢复。同时按单重任务顺序完成SA3生成/变体/重绘/取消与重复释放，以及1.5B剩余验证。许可和下载无需重复审批；当前资源拒绝不是全盘权限缺口。全部原预算/失败/来源保留，不启动新产品批次。

证据：H09 `/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-HUM-ENTRY-01/run-20260909T152120Z-h09-authorized`（preparation/label-fix、signed-build2、review/routing及两次review、app-run/result、protection-checkpoint）；H11 `/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-AUDIO-BACKEND-01/run-20260909T152406Z-h11-authorized`（authorization、download/environment/copies、environment-launch-diagnosis、generate失败、inspect-copies、retry-resource-rejection）；H12 `/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-AUDIO-BACKEND-01/run-20260909T151340Z-h12-authorized`（download-result、normal/report）。开发与用户媒体来源分开；本次Lead实施与实测，Sol只读审核；完整Lead/订阅消耗unknown。


## 2026-09-10：音频后端候选与待授权清单

本次源产品仍保持已验收 beaaaf82d845e672c6a3b661d928654affc00518 的代码；本提交仅更新当前状态和人工清单。音频后端/跨配置实现与证据在 [候选批次](https://github.com/lfrledh/D/blob/03798abfe17229f7678f9fcd611df87da7c775ac/docs/tasks/D-AUDIO-BACKEND-01.md)，候选 `codex/d-audio-backend-01` / `03798abfe17229f7678f9fcd611df87da7c775ac`，实际受测 `d1a5c26e3d2eda84ad7641a98b5aa33ce7f55407`，两者只有七份文档差异。实际推送状态及最终源SHA见下述外部回执，不把本段写成尚未完成的推送证明。

组合Python21、核心30方法通过；全UI包174方法报告（173通过/1既有可选权重检查跳过）；完整后端CPU42方法/100展开通过，三种实际跨语言音频CPU夹具通过；应用/CLI无签名编译通过。既有文本10类和图像17类CLI真实回归完整通过，另768×512 q8真图52.710秒、MLX峰值6309409880bytes、释放active/cache0。音频仍未真实出声，较大文字型号及高配Mac矩阵待验证，候选代码尚未默认接纳；原声音UI/schema4候选亦未混入。

下一动作集中于人工清单H11/H12：SA3/Gemma使用条款/适用登记确认与后续独立环境；被自动审批拒绝的新1.5B下载明确范围答复。H13当前空闲确认及串行图文实测已完成；H09/H10继续是原录音/声音UI独立门槛。不要重做已完成协作试验或为CPU工程问题要求全盘权限。

Lead协调四个Sol/high工作包，Python/运行时各两轮普通修复；运行时另一次有界Lead修补经过非实现者只读审核。真实音频验收未完成，不能宣布本阶段全部完成或普通D已能生成音乐。源scheme未暂存排序修改保持，普通D/用户作品未操作；当前新实现/审核/验证进程均已结束，最初FIFO超时子进程最终退出码unknown的历史保留。现有证据不等于全系统进程审计。恢复先核对仓库/权限/活动任务，而非只信摘要。

外盘持久回执：`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-AUDIO-BACKEND-01/run-20260909T123045Z/final-candidate-receipt.json`。内含候选/源版本、保护与推送证据；音频真实验收通过后再接候选比较/采用/安全保存，传统DAW与文字高级功能不是前置。

人工协作事项的持续入口：[待办与已解决记录](FAILURE_AND_PERMISSION_AUDIT.zh-CN.md#人工协作待办持续维护入口)。用户回到 Mac 时先读此处；不把旧失败重复算作未处理。

更新：2026-09-09。只记录当前执行所需信息；历史依据按需读取，不默认加载全部报告。

## 声音工作台装配：工程验收通过，真实使用门槛待集中处理（2026-09-09）

用户授权本阶段至推送，普通派工/修复/审核已自主完成。服务与生产UI已在隔离批次接通：限定WAV/CAF PCM导入、波形/普通播放控制、原始帧范围片段与Unicode注释、安全保存重开、原件和明确float32 WAV片段导出。导入按钮冻结渲染时的项目上下文/文档，文件面板前后校验；失效操作不写入后来的文档。录音结束/待恢复文件处理已有服务与界面接线，实际设备尚未验收。

**准确的验证范围：** UI修补代码/测试b042c7ebefca0798c671a6c277254e13a1c2b7bb，定向11方法全部通过；隔离组合40ec0d7b6b1525c3a0c12cab7e00f3a6773ab63d（比b042仅UI任务记录）从组合目录运行全UI包226方法/29套件，225通过/1既有可选权重检查跳过、零失败。该组合完整独立DerivedData应用编译通过，CODE_SIGNING_ALLOWED=NO/CODE_SIGNING_REQUIRED=NO，仅编译未启动，不证明签名/沙盒/麦克风/GUI。没有重跑真实文字/图像推理；旧路径CPU回归包含在组合中，定向方法不重复相加。

**版本与交付边界：** 候选在`codex/d-hum-entry-01`，本轮获准推送以保存进度；源`codex/inference-foundation`产品仍与已验收a406af9cd8908a77ae2f013d29121164d6fc0745相同，本轮源起点55e31bd0827ca63ea23cd5b3de39bd9535637c9c之后只更新四份状态/路线文档。未把schema4或新声音路径接管源入口：UIflag不是Store迁移开关。音频DEBUG入口须有效D_UI_TEST_SESSION UUID与D_AUDIO_WORKBENCH_TEST=1，录音仍关闭。最终完整源/候选SHA和实际推送确认见外部final-receipt.json；本节覆盖较早“接线待开始”记录，但不追改当时事实。

**审核与恢复：** 服务/界面分别由Sol/high受限CLI实现，顺序执行以保护共享存储；各自初交和两轮修复后，Lead各一次限定收尾，非实现者只读审核接受相应Lead差异。不是Sol独立通过，也没有重做协作机制试验。所有本轮子执行/审核/构建/测试进程已结束；源scheme内容/摘要/索引/未暂存状态与普通D.app四关键文件保护保持，既有作品未改，工作树/证据保留。用量只保留本run逐次原始记录，完整Lead与订阅费用unknown，不宣称成本最优。

**停点与下一动作：** [人工清单H09/H10](FAILURE_AND_PERMISSION_AUDIT.zh-CN.md#人工协作待办持续维护入口)等待用户回到Mac后集中处理：批准具体麦克风能力增量及测试入口，再完成当前独立窗口的实际录音/人耳试听/导入导出/保存重开/旧项目副本迁移与界面检查。没有新音乐模型/依赖/签名身份/TCC授权。通过后再决定源默认接纳；不能把工程编译或合成PCM当作声音闭环已交付。随后优先HUM可编辑音符/MUS-0普通试听与MIDI，再接一个MUS-1受控器乐候选、紧接MUS-2歌声，TTS单列，不等全部文字/图像/META增强。

批次记录：[声音装配候选](https://github.com/lfrledh/D/blob/codex/d-hum-entry-01/docs/tasks/D-HUM-ENTRY-01.md)。持久证据：`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-HUM-ENTRY-01/run-20260909T055825Z-assembly`，从final-receipt.json按需读ui/acceptance-integration、ui-review/lead-final-verification、combination/lead-tests-ui-integrated、app-build/final-assembly及保护/推送记录。恢复先核对真实HEAD/索引/个人修改，不仅相信摘要。

## 当前检查点：H08与原声基础组件已验收，本地批次保留（2026-09-09）

用户批准本阶段直到验收和本地提交，不再逐项询问普通修补。H08已关闭：类型限定、实际容器/有符号PCM检查、宽窄滚动/Unicode组件覆盖均通过；本次Lead补齐重播false/抛错后的旧进度定时器释放。原18项断言保留，新增3项真实Timer所有权反例先在未修补实现失败、再通过；不是改接受标准。

**实际受测：** AUDIO代码939b522e038fb74a3c640ff85db84956e7959f88，21方法/2套件通过、无跳过；STORE与AUDIO隔离组合211ae96ec508e086d6ff901936cc524f02a20aa3，全UI包207项中206通过、1项原可选文字权重检查跳过、零失败；核心17方法/2套件通过。21已包含在207内，不叠加计数。组合还验证导入后移走来源、原件/片段导出、重开后持久化参数交给原生播放准备与帧范围定位，原声字节不变；未播放声音。方法、SHA/文件摘要/进程结果在本轮证据中。

**审核与归因：** 本次Lead修复一行生产代码并增加直接回归；Sol/high为非实现者只读复核，接受此差异且无剩余组件阻塞，未独立跑测试。前期Terra/Sol初交和修复、Lead接管及类型修补历史保留。当前两段审核运行设置均匹配Sol/high/read-only/approval-never，无新权限/缓存或未配对命令事件。没有新增实现Worker或重新做并行试验；隐藏服务解析、完整Lead消耗/订阅费用未知。

**交付位置与边界：** 已验收基础代码在外盘`D-Worktrees/D-HUM-ENTRY-01`、分支`codex/d-hum-entry-01`；AUDIO候选19aa520ace3003af977de7b2957189cffce31e81相比受测939b522仅任务文档。源本轮起点692ac43dc470f57f0be7ab868f0d943618099a03，后续只提交这四份状态/路线文档，产品代码仍与a406af9cd8908a77ae2f013d29121164d6fc0745相同。尚未把schema4或新声音入口设为源默认：共享会话/生产UI接线、完整应用编译、真实录音/试听/GUI和产品迁移验收仍待下一阶段，不能用组件通过替代。

**下一阶段：声音灵感工作台接线与真实使用闭环。** 唯一服务Worker先实现项目/录音/播放生命周期与保存协调；接口接纳后，UI Worker接波形、片段、备注和原生导入导出。共享ProjectSession/ProjectStore不并行写。Lead冻结异步身份/草稿版本/未保存输入/关闭失败规则，串行集成与真实验收；使用独立测试项目，不碰既有作品。当前阶段在此结案，不自动开始装配。详细边界与反例在下方批次记录；实际麦克风能力和真人窗口在可审阅实现准备好后集中核对，不为CPU缺陷要求全盘访问。

音频推理按[音乐路线](MUSIC_ROADMAP.zh-CN.md)：原声保全/试听→可编辑音符与八小节→一个受控本地器乐候选→紧接歌声，TTS单列。数据/输入工作可按依赖交错，不等全部文本/图像/META增强；当前无音乐模型接入、下载或手机实施。

保护/恢复：源个人scheme完整内容、摘要、索引及未暂存状态保持，普通D.app四个关键文件内容/大小/mtime保持；本轮自有CPU/审核进程均结束，没有推送或删除候选。批次记录：[D-HUM-ENTRY-01](/Volumes/CodexProjects/Codex/D-Worktrees/D-HUM-ENTRY-01/docs/tasks/D-HUM-ENTRY-01.md)。最终完整源/批次SHA及仅文档差异、测试/审核/保护/用量索引：`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-HUM-ENTRY-01/run-20260909T040308Z-h08-acceptance/final-receipt.json`。旧失败证据不覆盖，恢复先核对真实Git状态和活动任务。

## 最新结案：T0 工作台、PNG 配方交接与人工遗留项

2026-09-08，本轮有限里程碑已本地集成并通过验收，未推送。**本节覆盖下文历史停点；没有启动下一产品批次。**

- 源分支 `codex/inference-foundation` 从 `1d290a847766e69324d9b999ed8cc49425e2d07e` 快进至组合受测 `685ef0502586bc5785826a3dc938622d8401f0e7`。隔离组合和源目录各自165方法/22套件通过，源入口实际指向源文件。正常签名构建、同次8/8 UI、真实文字/图像与中文组字缩放在 `a6c516ad6b52c944ce70a0bd764d68a94fd0f3bc` 验证；到685ef仅文档变化，代码/测试/夹具/工程/执行入口一致。之后本地结案提交仅文档，最终完整SHA见下列外部回执。
- T0：同一项目内新建文稿，选段改写、候选预览、接受/拒绝/受保护单级撤销、安全保存和重开已接线并真实验收。选区/正文版本改变使旧候选失效；中文、组合字符与emoji按Character边界处理。正文持久化，临时候选/选择/撤销不跨关闭保存，关闭前需处理候选。当前固定小文字模型只证明流程，不保证专业写作或音乐理论质量。
- PNG：实际任务配方的公开/私有预览、新副本导出、另一项目离线读取、显式创建新草稿及重开已验收。只恢复可用提示词与seed，不恢复完整环境或自动运行；公开提示词隐去时不能创建伪空草稿。原媒体非D块字节保持，外部元数据不执行，原件/已有目标不覆盖。
- 最后一项全新DerivedData普通签名产物恢复已通过：自动恢复图像项目、真实蓝杯作品和FLUX目录可访问状态；配方草稿保留Unicode和最大UInt64 seed；v2及中文文稿重开成功，Qwen已校验选择恢复。v1/v2原始备份逐字节相同、原图片未变。未修改真实用户作品、未重新申请系统权限；这不是公证、发行、任意未来构建或永久TCC保证。
- 用户报告的窄窗口裁切已修复并接纳：分栏/工具栏随宽度重排，原生编辑器身份和选区保留；最终真人明确“输入与缩放均正常”。人工清单H01—H05/H07本轮事项关闭，H06仅在实际新提示出现时处理。

证据根：`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-T0-WORKBENCH-01/run-20260908T125225Z-human-finish`。索引 `final-stage-receipt.json`；关键 `final-fresh-restore.json`、`final-fresh-restore-files.json`、`final-merged-acceptance.json`、`final-source-acceptance.json`、`source-ff-result.json`；原始失败与所有历史验收继续保留。任务：[T0](tasks/D-T0-WORKBENCH-01.md)、[PNG](tasks/D-META-PNG-01.md)。

来源：Terra完成既有组件实现及记录中的有限返工，Astra负责共享装配、实际修补和产品验收，Sol/high做非实现者只读差异审核；本次续办只有恢复/集成/文档与只读进展汇总，没有再次修产品代码或追加Worker修复轮次。路由与沙箱为可观察证据，隐藏解析和完整订阅费用仍unknown；不能据此认定成本最优。

恢复检查点：本轮自有应用、CPU、构建和子任务均结束；候选/证据保留。源索引干净，唯一个人scheme排序差异保持未暂存（SHA256 ca3635d88aa5a15397b90e528667c66c0e6db7e596176e885c79d194b544206c）；原普通D.app四个关键文件内容/大小/mtime均保持。产品代码已进入本地源分支，但旧普通D.app未替换；已验收的新应用仍在本轮 `signed-build/DerivedData-fresh/Build/Products/Debug/D.app`。

下一建议是一个较完整的“声音灵感工作台”里程碑：短原声导入/录制、波形定位和普通试听、独立片段与备注、安全保存重开及音频导出；Lead先冻结音频资产/时间/迁移契约，再按就绪度把存储与音频服务/视图交给0—2 Worker。仅为提案，格式与时长上限、麦克风权限增量及真实验收另行明确，不在本轮开工。之后紧接可编辑音符/八小节受控音乐/歌声路线，见 [音乐与HUM](MUSIC_ROADMAP.zh-CN.md)；不以全部文字增强或META完成为前置，不下载模型/声库。

## 历史基线与范围（由上文最新结案覆盖）

- 源本地检查点仍为 `6735266933773adaee33b3a66a01b09c0b1f7d9b`，codex/inference-foundation；上一批已接纳记录复用。本轮 [D-T0-WORKBENCH-01](tasks/D-T0-WORKBENCH-01.md) 候选完成工作台/生产保存接线，受测代码 `62fc7b5dd568e5f53354382dd189d09e96b7e0bc`：142 CPU/离屏、核心17及隔离无签名App编译通过，非实现者审核无剩余静态阻塞。**真实改写/GUI待验收，未源接纳、未推送、未默认启用schema3**；最终候选文档SHA见任务外部回执。默认协作仍按就绪度0—2 Worker，不重新试验。
- 历史服务阶段起始提交：`28cbb6c`，分支 `codex/inference-foundation`。
- 已验收：纯核心、真实文本／图像后端、单项目图像工作台、D-F03 应用服务分离、D-M01 模型安装到真实出图、D-W02 / D-W04a 多文档探索与比较。
- 最新检查点：[多文档探索与比较验收](EXPLORATION_STAGE_ACCEPTANCE.zh-CN.md)，源码和运行证据见对应 JSON。提交及远程同步状态以 Git 为准。
- UI 逻辑：项目拥有多份创作文档，模型为共享资源；多文档 v2 已验收；快速草稿另行排期。
- 当前硬件：M4／16 GiB，外盘优先；单个重推理任务，固定 FLUX.2 Klein 4B q8、512²、4 步、guidance 1。

## 最小阅读入口

1. `AGENTS.md`：长期不变量、工具和验证要求。
2. `PRODUCT_GOALS.zh-CN.md`：当前目标行、状态、依赖与启动条件。
3. `decisions/0007-project-information-architecture.md`、`decisions/0008-application-services-and-provider-evolution.md`：本轮设计边界。
4. 相关实际源码和测试：DInference／DRuntime、UI package 与 D 应用装配；不要从文档推测接口。

## 工作包和验收

| 包 | 交付 | 状态 |
| --- | --- | --- |
| A | 设计文档；真实 DWorkbench target；无视图项目／任务服务；兼容 v1 与旧生命周期 | 已验收 |
| B | 固定模型库、外盘授权、下载暂停／恢复、完整校验、安装租约与模型管理 UI | 已验收；管理库跨盘搬迁另列 D-M02 |
| C | 普通沙盒真实安装到生成／保存／重开；失败恢复、服务与核心回归、外观／键盘验证 | 已验收；2 张参考图片、运行中取消交接、后台安装、恢复均通过 |

模型目录约束不能因下载索引而放宽；索引／暂存放在模型安装之外。原来已准备的模型可登记完整验证，但不能以此代替下载路径验收。

## 复验入口

- `./scripts/test-foundation.sh`：无模型核心回归。
- `./scripts/test-workbench.sh`：项目、应用服务、安装器 CPU 测试；真实模型结果另行记录。
- `./scripts/build-local.sh`：正常 Debug arm64 沙盒构建。
- 涉及后端文件／资源边界时按改动运行相应 MLX 测试；数学与资源算法变化时复验真实取消、释放、峰值和数值。
- XCTest 宿主测试后重新正常构建，确认没有测试签名例外，再验证真实沙盒权限。
- CUA 流程、XCTest 执行、CPU fixture、真实网络与 GPU 结果分开报告；未执行不记为通过。

## 当前检查点：可持续探索与比较已验收

[总体规划](PRODUCT_STRATEGY.zh-CN.md)、[工作包](EXPLORATION_STAGE_PLAN.zh-CN.md) 与 [验收及证据](EXPLORATION_STAGE_ACCEPTANCE.zh-CN.md) 是本阶段入口。D-W02 / D-W04a 完成：独立创作、候选整理、比较、条件复用、采用与重开；v1 原字节备份后迁移 v2，图片不改写。

最终 CPU 82 项通过，核心 17 项通过，关闭协调 2 项通过，8 个不同 UI 场景按完整和定向运行通过；真实正常沙盒 4 次新提交、3 成功／1 取消，固定参考一致、导出和路径失联恢复通过。测试类别、各轮失败与实测限制见验收报告，不混计为一次测试运行。

导出使用系统同卷临时目录再原子发布到已授权文件，不依赖父目录宽泛授权。草稿／选择／候选元数据的已接受写入须在导航和关闭前完成；编辑弹窗绑定固定对象，失败不丢弃输入。

下一步先与用户确认参考引导／定向修改的具体创作场景，再形成单独工作包并审批。当前没有已自动启动的后续阶段。D-W04 的搜索／集合、快速草稿、其他模态和远期服务按目标表保留，不自动展开。保留用户 Xcode scheme 排序修改。

## 进入新产品阶段前：授权稳定性

历史权限和其他失败已按原因／复验／当前处理整理为 [审计清单](FAILURE_AND_PERMISSION_AUDIT.zh-CN.md)。已知历史权限阻塞对应的核心验收后来通过；UI 启动超时的具体根因未证实，不能统一归因于 D 外盘权限。

D-C01a 的只读诊断子任务 [D-C01a-DIAG-01](tasks/D-C01a-DIAG-01.md) **已本地集成并通过任务验收；未推送**。2026-09-07 源目录在 `2524fc61417ddb5fe07e28f466ba6709fcba69f8` 完成 15 个 CPU 测试方法（原 10＋新增 5，后者含 8 个真实 CLI 场景）、Lead 12 场景、报告保护及普通 D.app 只读交叉检查。之后仅有结案文档变化，最终版本／证据见任务记录；源个人 scheme 排序修改保持未暂存。

诊断入口：`python3 -B scripts/diagnose-app.py --app PATH`，必须显式指定产物，可用 `--report PATH` 新建报告；只检查并报告，不修签名／权限。对应局部回归：`python3 -B -m unittest discover -s scripts/tests -p test_diagnose_app.py -v`。该任务当时的真实产物为 ad-hoc，本任务不证明公证、TCC、GUI 或跨构建恢复通过。

D-C01a 整阶段尚未完成。2026-09-07 用户回到 Mac 并授权处理环境／应用权限后，已完成外盘项目绑定、现有开发私钥调用、Apple Development 签名正常构建及原路径首次重开恢复。后续 `build-local.sh` 读取外盘本机签名配置；直接 Xcode GUI Build 仍保留原设置，不能混用后假定签名稳定。完整 8 项 UI XCTest、真实签名版生成／导出、再次签名重建恢复尚待验证。详见 [最新授权检查点、构建意外与恢复记录](MAC_PERMISSION_SETUP.zh-CN.md)。没有启动 D-P01、双 Worker 或推送。

D-C01a-RESULT-01 候选仍在独立工作树、HEAD `829ca10e2f396c8309723d55a69149cb132017d6`；因既有权限事件停止，第一轮修复尚未由 Lead 复验／集成。本轮授权设置不改写该试点结论。B10 偶发测试保留观察；物理拔盘／断电、完整 VoiceOver 等仍属于发行前独立验收。

## 2026-09-08：v7 RESULT 恢复与产品批次授权

D-C01a-RESULT-01 已保留历史合并、由 Lead 有界修补、非实现者只读审核，并从源目录通过 15 方法与 39 场景复验；受测代码 653c09cd2e526c7e8cc0f09b925232f85826ee46。[记录](tasks/D-C01a-RESULT-01.md)。此前“第一轮修复尚未复验”的段落为历史停点，已由本段替代。不是 D-C01a 整阶段或真实 UI 8/8 完成，未推送。

用户 v7 已批准有限 T0 产品批次及一个独立 META 配方切片，并批准有门槛的双 Worker 流程切换。Lead 准备分支 codex/d-t0-meta-01；规格／并发／验收尚未完成，不提前标记常规多代理已启用。源用户 scheme 排序修改继续保护。当前源签名行为不因本批变化。

## v7 首组产品批次：已本地接纳，常规多代理已启用

源接收快照 c808293692eb7be90b7c9de73667c9d7bc327e3a → 已受测组合 `c3197ad9cdade3d486a4153418cacc39af85bc81`。批次 [D-T0-META-01](tasks/D-T0-META-01.md) 完成：两个独立受限 Terra/medium 实现重叠229.3338秒；各自两轮修复，META另经Lead测试夹具收尾，生产代码非实现者审查及组合验收通过。工作台117/核心17在组合通过，源目录工作台117再通过。此后仅结案文档，最终源HEAD见外部final-receipt并以Git核对。未推送，候选和证据保留。

**常规多子代理开发流程已启用**：以后用户批准产品目标/继续获准批次，由Lead按任务就绪度使用0—2 Worker，受限独立CLI与串行重验证；不需额外会话逐步骤传话。本批所有子任务/自有检查进程结束，未建立系统写锁。当前停止在批次结案，不自动展开下一目标。个人scheme唯一未暂存差异保持，索引干净。签名/权限/精度/数据保护规则不变。

已明确多模态出口：[音乐/HUM](MUSIC_ROADMAP.zh-CN.md)、[资产来源](ASSET_PROVENANCE_PLAN.zh-CN.md)。图像有限出口已有历史证据，签名版完整 UI/重建恢复缺口保留，不阻塞独立组件。当前 T0 范围仅编辑/运行桥接/草稿 Data 归档，META 仅内部配方 Data/隐私，不默认启用新 UI；完整工作台保存、真实文字生成、PNG往返及音乐仍未验收。

下一用户可感知出口是 T0 工作台界面和生产保存接线，在允许的独立环境完成实际选段改写、保存重开。下一音乐包以 HUM/MUS0 原声/自由时间/音符数据与普通试听出口进入，不等所有图像/文字增强或 META 全部完成；下载/音源/模型精度需另行明确。

## T0 工作台候选：代码/编译通过，真实闭环待验收

本轮用户已批准有限工作台接线，取代上面“下一目标待批准”的历史停点。候选 codex/d-t0-workbench-01 在外盘同名工作树；源仍保持6735266…及唯一未暂存scheme修改。完整SHA、来源、失败/修复、保护和恢复索引见 [任务记录](tasks/D-T0-WORKBENCH-01.md)，不要把短SHA补造为新基线。

已实现同项目文稿、选区失效、候选处理、单级撤销、序列化自动/显式保存和重开；schema3备份迁移未用于真实作品。现有Qwen模型全部文件摘要已由生产代码只读校验，但没有新的MLX生成。142方法是本轮组合一次运行，不加总早期139/141或各子包方法；核心17和unsigned编译分别记录。真实GUI/CUA访问超时、用户D/GPU空闲状态未确认，因此整个候选留在隔离分支，原入口不变。

本批两个Terra/medium局部Worker均初交+2修复，Lead负责共享接线和反例，另有非实现者只读审核；各自自有进程已结束。下一动作仅恢复本目标的真实验收：确认设备空闲，界面控制可用，使用明确测试产物绝对路径和独立项目，完成现有模型真实改写/候选交互/保存重开，再按原规则本地接纳。Xcode已登记隔离编译产物到LaunchServices，不能只按名字D猜测产物；未启动它或替换普通D。签名/权限方案不改，不为此下载。

音乐/HUM的原声/自由时间/音符数据和普通试听仍有明确后续出口，不等待完整高级文本或META。PNG内嵌、音乐模型、手机等没有在本轮开工。

## v8 里程碑检查点（2026-09-08；覆盖上面的下一步待批描述）

本轮授权为T0真实收尾＋一个后续有限闭环。**产品代码未接纳，普通D未替换，无推送**。本段所在源提交仅更新当前动作/协作规程；最后已接纳产品代码仍6735266933773adaee33b3a66a01b09c0b1f7d9b。以下候选不能当作已交付：

- T0：候选目录 /Volumes/CodexProjects/Codex/D-Worktrees/D-T0-WORKBENCH-01；任务记录 docs/tasks/D-T0-WORKBENCH-01.md。代码与既有62fc7b5dd568e5f53354382dd189d09e96b7e0bc一致，新增签名构建来自8c40e968c61f4ee661efdb6c92ffe77cd7b91cff，之后仅任务记录6bf7eef9be37036e06b96dd3dbcb364ceee8a712。现有配置正常签名、完整性和entitlements已核对；GUI仅库存查询响应，未绑定/启动实例。当前空闲/GPU/GUI窗口请求未获答复，真实改写/IME/取消释放/签名保存及合成v1/v2迁移仍待。证据 D-Development/AgentTrials/D-T0-WORKBENCH-01/run-v8-20260908/validation-entry.json。
- 后续选择META-PNG：目录 /Volumes/CodexProjects/Codex/D-Worktrees/D-META-PNG-01；任务记录 docs/tasks/D-META-PNG-01.md。受测ea1c19abf89ca8fdc6339df904aba0c0c7c59a98，137 CPU方法通过，完整禁止签名编译通过；新副本/离线读取/新草稿为合成文件与会话实测，不是GUI。非实现者复审仍要求4个精确尺寸边界夹具；Lead自查预览校验在界面线程，尚需移出。Terra初交+2修复、Lead一次有界夹具接管已用；未自动追加轮次，保留候选和真实产品门槛。曾出现旧项目移位锁测试1次异常，定向及最终组合通过但根因unknown，不声称修复。最终候选SHA/模型/进程/证据由 D-Development/AgentTrials/D-META-PNG-01/run-v8-20260908/final-receipt.json 索引。
- HUM-ENTRY的具体依赖：现有ProjectStore仅接纳image/png及固定图片结果路径；原声素材需独立持久化增量，不能悄悄扩大schema。音乐/HUM下一出口仍是原声导入、保存和普通试听，然后明确的真实哼唱转录验证，不等全部T0增强或META平台。没有启动模型/声库下载、手机或完整音乐编辑器。

最小剩余动作：协调本轮实际GUI/GPU窗口；META另需上述限定收尾的追加预算后再复验，不重新全库审计或重新试验协作机制。当前所有本轮自有子进程已结束；用户D/GPU空闲未知，不关闭用户D腾资源。scheme当前内容/摘要/索引/未暂存状态保持；恢复时重新核对真实仓库，不只相信本段历史状态。

## 人工协作集中处理：2026-09-08

今后用户回到 Mac 时，先读取 [人工协作待办](FAILURE_AND_PERMISSION_AUDIT.zh-CN.md#人工协作待办持续维护入口)，按最新任务回执核对并集中处理。Lead 持续记录等待用户的具体事件；权限、测试窗口、预算和普通工程缺陷分开，授权后实际复验才关闭，不后台自动触发。

本轮源起点 `188662d79f5283db97e5a928deae4f346b219a3a`；本次只接纳文档清单，不接纳 T0/META 产品代码。用户已确认当前约 30 分钟 GUI/GPU 空闲窗口，T0 固定签名候选按完整产物路径成功控制，并用独立 `D_UI_TEST_SESSION` 在本轮外盘目录通过原生面板创建项目和新文稿，未恢复真实项目、未出现新的系统授权提示。中文输入法已交给本人操作，等待回报；模型访问、真实改写、保存重开及迁移不因这一小步记为通过。

保留的待办：H03 真人 IME；H02 后续模型／保存等实际验证；H04 同次完整 UI 与稳定签名跨构建连续验收；H05 PNG 两项有界收尾需额外预算批准。旧 GitHub／外盘 runner／RESULT 缓存事故已有后续处理，不能再次当作待设置权限。源个人 scheme 保持原内容和未暂存状态；没有改真实作品、签名、系统权限、模型或推送。当前进程、检查结果、最终文档 SHA 与恢复点以外部 `D-Development/PermissionSetup/run-20260908T122903Z-return/receipt.json` 为准，恢复先核对，不能仅相信此历史段落。

## 2026-09-08 人工集中收尾检查点

候选实际受测代码 `a6c516ad6b52c944ce70a0bd764d68a94fd0f3bc`，组合目录 `/Volumes/CodexProjects/Codex/D-Worktrees/D-HUMAN-FINISH-01`、分支 `codex/d-human-finish-01`。源当前只更新待办文档，产品代码尚未接纳；不存在仍运行的本轮测试应用、构建或审核进程。本次源提交仅CURRENT_ACTIONS与FAILURE_AND_PERMISSION_AUDIT文档变化，最终SHA见外部 `human-checkpoint-receipt.json`。用户一小时窗口已结束，追加15分钟协调尚无回复，不能视作已同意。

- 165方法/22套件组合CPU通过（显式启用既有文字权重只读检查）；8项UI在同一个 `uitests-refined.xcresult` 中全部通过。此前第一次8项有2项原生GoTo面板失败保留，测试只增强完整路径和面板消失的同步断言，未降低原验收。
- Lead修复文字窗口宽度反馈/分栏约束：窄窗口上下布局、工具栏换行，AnyLayout保留原生编辑器身份，原选段有44pt最小高度。窄/宽实际往返、真实候选与失效警告可达；用户在最终构建上明确回复“输入与缩放均正常”。离屏回归的窄布局断言经历旧实现先失败后通过；早期仅bounds的探针曾通过，不能冒充完整复现。
- 正常签名Qwen真实改写证明原文接受前不变，接受只替换选段、撤销恢复、取消后下一任务可运行，校验中变选区明确拒绝、完成后变选区禁用接受且可拒绝。旧构建保存的测试正文与模型选择在新构建恢复；中文输入法人工结果单列。最终a6实测再次真实生成“阳光明媚。”并接受/撤销/保存。模型文风和标点不宣称专业质量。
- 正常面板打开合成v1/v2，均迁移schema3且原清单备份逐字节一致、图片未变；v1另已GUI重开。真实作品未迁移。PNG私有/公开新副本由正常面板保存，在另一项目离线读回；公开提示词withheld导致新草稿不可用，私有明确接受生成独立草稿801488BE-1237-41E1-A15C-B8343E8DBAEC并落盘，原文档不变、没有自动生成。独立CRC/JSON检查确认全部非配方PNG块字节保持、Unicode和最大UInt64 seed准确。
- 正常开发签名FLUX.2 Klein4B q8，512²/4步/guidance1/seed42真实完成；作业6A86F463-F611-4C45-9B39-493C38C56191，原生导出436021字节且与项目图片SHA256一致，sips解码512²，CUA看图为蓝色陶杯。estimatedPeakBytes为预算估计，不冒充本轮峰值实测或数值基准。
- 真实编译已在新的DerivedData-fresh完成；二进制和签名资源摘要与前产物不同，Info.plist相同。**尚待这个全新产物重开图像/模型授权、配方草稿及v2/T0最终恢复检查；不提前记整个里程碑或D-C01a完成。**

证据根 `/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-T0-WORKBENCH-01/run-20260908T125225Z-human-finish`：verified-checks-before-human-ime、human-ime-final、gui-progress-1/2、migration-after-native-open、migration-and-recipe-before-rebuild、png-native-crosscheck、image-normal-signed-result、normal-fresh-rebuild、checkpoint-await-final-window（JSON）；review/gui-delta-response.md。GUI截图/操作另在本会话，JSON明确区分用户报告、CUA与文件检查。

来源：Terra既有初步实现/历史返工原样保留；本轮Astra Lead亲自修复，Sol/high非实现者仅只读审核差异，非独立测试执行。观察上下文四次均Sol/high/read-only，隐藏服务端解析unknown；各阶段耗时/usage原始快照保留，未将累计/缓存快照盲目相加，完整Lead与订阅费用unknown。没有新Terra第三轮、签名方案变更、安装、推送或权限扩大。CUA一次粘贴超时后核对正文/磁盘，改用原生输入；界面AX旧状态与截图不一致后以实际启动作业核实，不推断应用拒绝生成。

恢复：先核对真实源/组合HEAD、scheme内容/摘要/index/未暂存状态和自有进程；源本轮文档新增属于已批准清单维护，之后可在隔离组合分支保留历史合入该明确源快照，核对仅文档差异，再按既定验收门槛接纳。下一动作只是上述新产物恢复，不能再重复真人IME、模型下载或整套协作试验。音乐/HUM原声导入保存与普通试听仍是明确后续出口，不等全部文字增强，本轮不启动。
