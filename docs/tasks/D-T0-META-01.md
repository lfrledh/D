# D-T0-META-01：首组产品双任务批次

状态：Lead 准备；v7，2026-09-08。source_base=c808293692eb7be90b7c9de73667c9d7bc327e3a。集成树 /Volumes/CodexProjects/Codex/D-Worktrees/D-T0-META-01，分支 codex/d-t0-meta-01。共同执行基线为本准备提交，其完整 SHA 记录在外部 preparation/request 中。contract_revision=1。

目标：T0 的编辑／推理桥接与可重开草稿数据组件，加独立 META 配方／隐私组件，两方独立受限执行、Lead 非实现者审核和组合 CPU 回归后本地接纳。不是签名、GUI、音乐、PNG 内嵌或 T0 产品全闭环交付。既有图像 UI/ProjectStore 格式不变，新组件不自动启用。没有依赖 META 的全模态前置门禁。

所有权：T0 独占新增 DWorkbench/Text 下三个文件及对应两份测试；META 独占新增 DWorkbench/Media/GenerationRecipe.swift 及对应测试。双方不改 ProjectModels/ProjectStore/ProjectSession/ModelLibrary/InferenceRuntime/UI 视图/Package.swift，详细清单见各任务。Lead 负责文档、装配判断及集成。SwiftPM 会自动发现目标内源文件，不需新包或空接口。两任务接口不相互依赖，无需预写实现让 Worker 抄。

本批验收：每方定向 CPU 测试和契约反例；Lead 代码审查、测试语义／权限事件核对；合并后的 UI package 全量现有 CPU 回归及纯核心回归。已有模型目录不访问。GUI/真实推理无法证实隔离时留待后续，不用 mock 证明真实推理；无用户默认路径改变才能接纳增量。当前没有系统写锁，源推进前后重新验证保护。

证据根 /Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-T0-META-01；task/run 各自子目录。原 RESULT 由独立已接纳任务记录承载，不重置其预算或将其工具作为本批必需门禁。Lead 曾在一次只读命令中漏写 D-Worktrees 路径，工具在创建进程前拒绝；按已确认物理目录纠正，未进入错误仓库或产生文件，不计 Worker 缺陷。

恢复：源上述 SHA；仅个人 scheme 未暂存（读取 start-protection 为准）。批次尚无活跃 Worker；待准备提交、两个独立工作树和预检后签发 IMPLEMENT。默认多代理状态尚未启用。最终代码／测试／文档 SHA 和实际重叠时间在结案补充。

## v7 结案：常规多子代理开发流程已启用（2026-09-08）

双方成果已本地接入 codex/inference-foundation，未推送；默认由 Lead 按产品目标/任务就绪度选择0—2 Worker，原安全/质量/费用授权边界不变。本批到此结束。以下事实替代上方签发时的“准备/无活跃 Worker”状态，不删除历史规格。

| 工作 | 实现/修复及审核 | 受测代码 → 文档候选 |
| --- | --- | --- |
| [D-T0-EDIT-01](D-T0-EDIT-01.md) | Terra/medium 初交＋2修复；Lead 规格、反例及非实现者审核，无产品代写；20方法通过 | 1399502c6593678a71b91e6b726217b54c47d1b0 → 346e5a50f8ee54ec0216c6ac54ea733895d6236a |
| [D-META-RECIPE-01](D-META-RECIPE-01.md) | Terra/medium 初交＋2修复后仍未全过；Lead 有界修补测试字段顺序，生产实现非实现者审核；15方法通过 | e9003174729b23ff4f45faf5776d56d9a4e18c62 → 8e41965f5506c3d1864256b73b0fa0eedb3fb68d |

执行源基线 c808293692eb7be90b7c9de73667c9d7bc327e3a，共同准备 e4e39b404a9d0d83c92bae285b12b961976de438。实际初次实现时间：T0 04:07:38.053756—04:11:50.965181 UTC；META 04:08:01.631381—04:12:44.288739 UTC，重叠229.3338秒（真实代码修改，非只读预检）。每任务独立工作树/索引/分支和输出/tmp；thread、PID、每轮基线与 turn_context 见各自 final-candidate-review.json。请求/全部可见运行设置均 gpt-5.6-terra / medium，workspace-write、网络关闭、共享Git不纳入Worker写根。隐藏服务端解析及桌面原生派工未验证。没有活动 Worker/Reviewer；8次自有CLI均 exit0并交回写入，未声称全系统进程已停止。

Lead 串行在集成树保留历史合并：T0 后 521ae16c25c5083eb78400f1c86b812c1f9e1f80 定向20方法通过；加入META后 `c3197ad9cdade3d486a4153418cacc39af85bc81`，完整工作台117方法/13套件、核心17方法/2套件通过。再从固定源c808快进至该SHA，源入口重新运行工作台117方法通过。没有内容冲突；双方分叉用普通合并整合，源仅ff-only，不重写提交。编译/测试资源排队由Lead完成，用户不需在会话间传话。

当前受测/源集成代码 `c3197ad9cdade3d486a4153418cacc39af85bc81`；本结案后最终源HEAD写在本轮 final-receipt.json，不为自引用再提交。该最终提交只含获准文档/规则状态变化，未声称在尚未产生的提交上重新执行测试。环境 macOS26.6.2(25G83)、Apple Swift6.3.3、M4/16GiB。工作台 package 装配与CPU通过；没有全应用构建、真实文本/GPU/GUI或普通D.app检查。

### 已审查的问题与保留限制

T0初交测试编译语法错误；Lead随后发现原Unicode字节被等价比较吞掉、流错误需请求取消、严格版本及调用方取消边界；最后outcome等待期间的取消用真实CPU gate先失败后通过。META的数字版本、ASCII摘要与错误内容泄露由Terra修复；其负例夹具先有不匹配seed，后依赖无序JSON。Lead只在最后固定测试夹具排序，保持原拒绝断言；不是Terra独立成功，也未另起模型审阅这处小型测试修补。生产源码仍全由Terra完成，Lead为其非实现者审阅。手写严格JSON检查较紧凑，后续涉及格式演进时需再审，不因为本次通过就声称任意元数据安全。

规格/测试新增为原契约的反例覆盖；无私自降阈值/删除断言。每次修复前核对上一轮异常及保护；新批次未观察到未处理越界/权限扩大/网络/来源事件。RESULT旧未停报及Lead审核时序继续保留。一次Lead默认外盘写被当前根沙箱拒绝后，使用工具对该限定已授权操作审批；未更改全局设置或Mac权限。另一次只读cwd拼写在创建进程前被拒绝；一次将工具JSON显示转义误读为文件转义的纠正尝试在断言处停止、未写文件。均非Worker产品缺陷。

经济性仅为样本：本次8个CLI终态计数逐次记录 usage-observation.json；同一调用内累计快照不重复加，缓存输入含于总输入，推理输出含于输出。未重算历史费用；完整Lead消耗/订阅实际扣费unknown。两个任务均需2轮修复、META还需Lead夹具接管，证明流程能交付，不证明成本最优。取消/并发类任务以后保留强Lead反例审核，不凭“普通Swift组件”降低风险。

### 恢复检查点与后续产品边界

源 `/Volumes/CodexProjects/Codex/D`、分支 codex/inference-foundation；本轮源代码接收SHA为上述c319，最终文档SHA查询 final-receipt.json并核对Git。源索引结案后应干净；唯一剩余个人scheme未暂存，SHA256 ca3635d88aa5a15397b90e528667c66c0e6db7e596176e885c79d194b544206c，完整diff/index见source-protection-start及source-ff/source-ui。未覆盖或暂存它；未触碰D.app/签名/模型。候选、集成工作树和证据均保留，不清理。自有CLI/CPU测试进程结束，未全系统枚举；恢复前重新核对现实状态。

已交付范围是T0编辑/运行桥接与Data归档、META配方Data/隐私组件，未默认接管UI或项目v2。真实文字选段编辑界面、生产保存/重开、GUI/真实模型完整闭环待验收；PNG内嵌、HUM、音乐模型、移动端均未实施。D-C01a真实签名UI/跨构建恢复另有交付门槛，RESULT通过不能代替它们。

下一建议产品目标：T0工作台中选段→候选→接受/拒绝/撤销→安全保存重开，保持Liquid Glass控制层和中性编辑区；先明确项目存储接线与关闭/未处理候选语义，再按就绪度派工。该下一目标未在本批自动执行。HUM/MUS0数据/普通试听可独立准备，不等高级文字或META全部完成；新模型/声库/权限另行授权。

证据根 `/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-T0-META-01`：integration-precheck、reviewed-candidates、merge-t0/meta-command、integrated-t0-tests、combined-ui/core、source-integration-before、source-ff、source-ui、usage-observation、final-receipt。每任务`run-v7-initial`保留每轮请求/运行/事件/测试和final-candidate-review；大日志不入Git。RESULT独立证据见其任务记录。恢复读取任务摘要和相关反例，按需索引，不复制完整聊天到每个Worker。
