# 当前行动与接手点

最后核实：2026-10-02。当前任务、基线、候选、阻塞与下一动作只从本页进入；历史回执不自动授权续跑。

## 当前任务：D-RELEASE-FREEZE-01 / D-DISCUSSION-FREEZE-20261002

- 用户已批准本轮正常推进main：公开开发基线与试用、功能冻结、正式发行分别报告。main为唯一日常集成线；inference-foundation保留历史，不再作为第二道接纳门。禁止强推、发布安装包、变更许可或收费。
- 起点候选 `codex/release-freeze-01@0555bacccd5eea2e57fb9d0946f1065deeded9d7`，实际目录 `/Volumes/CodexProjects/Codex/D-Worktrees/D-RELEASE-FREEZE-01`。旧main `708f5fbb7e5e78b5583c487a67329c0eeaf6e5cf` 是其祖先；当前源/远端以本run回执和真实Git核对，不把本页起点当最新HEAD。
- 干净main集成树 `/Volumes/CodexProjects/Codex/D-Worktrees/D-DISCUSSION-MAIN`。旧main归档 `archive/main-before-refresh-2026-10-02` 及独立bundle已校验；六个历史子模块的已有bundle含准确gitlink。备份不含外部模型、未提交数据或完整机器，见本run `lead/main-backup.json`。
- 个人旧源仍 `codex/inference-foundation@01758b81527dc27eb4563bf1b66fd1ceab6647ee`，scheme未暂存orderHint 1→6，SHA-256 `ca3635d88aa5a15397b90e528667c66c0e6db7e596176e885c79d194b544206c`；不切分支/暂存/还原。
- R=`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261002T062206Z-discussion`。本轮W0核对完成，W1双语首页/历史备份/公开基线先行；随后W4A外部目录导入、W4B引用/入库/已知位置/项目收纳、W4C手动备份恢复分片实现并检查。W2只针对H22实际客户端/指针和hosting，W3复用已有完整产物解决质量疑点；不新增模型或同步平台。
- R4=`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261001T162316Z-r4`；R3=`…/run-20261001T040512Z-low-memory`。既有证据与失败保留[原任务](tasks/D-RELEASE-FREEZE-01.md)，未受影响不重跑。r4正常签名App及受测代码6328d9cd7dca1edb1b2a5b233089bb73469be7ca；0555仅后续文档。
- 唯一[测试政策](TESTING_POLICY.zh-CN.md)补文件生命周期与公开主线边界。W4文件服务切片已实现：引用/独立副本、固定版本读取、位置恢复/收纳、手动备份及独立恢复；受测代码 `dac0316f4810c73a32df8545b01adc4d2ee255de` 的相关实现与 `lead/backup-integration-05.log` 对应，18项CPU检查通过，非实现者定向审阅无剩余P1/P2阻塞。包含音频→音符→和弦来源、嵌套工具/执行历史和原位置不可用后的恢复。此为服务切片，UI仍在独立候选审阅，不宣称原生用户闭环。

## 本轮已核实与当前在做

| 项目 | 当前事实及下一门槛 |
|---|---|
| 固定下载 | 原 Dev 32 文件 112,823,015,636B、LTX2.5 19 文件 70,937,200,046B 下载/校验作业确已完成。r4核精确版本/来源/文件大小，未重开下载或重复散列183GB。H31账号访问关闭。 |
| Qwen9B/27B | 修复多帧时间戳和语言 RoPE 网格映射。4bc9b9ffa7810ccaa4b380dec5c6a06a871265b5 正式 Runtime 原精度/SSD 四采样帧：9B131.489秒、27B293.433秒通过，输出正确先红后蓝，各次 active/cache0。块级/原文字、双图、工具、取消证据沿用；不宣称任意视频理解质量或长上下文极限。 |
| Dev | d3afbfb3 正式Runtime取消→50步文生→50步有序双参考同一方法5524.332秒通过；PNG已查看，每次active/cache0。两张真实产物在dba33e6分别通过Store发布/重开/导出；不是原生GUI。 |
| LTX2.5 | 完整48层Gemma4+49隐状态分阶段及小型数值对照通过；70.9GB原资源经生产ModelLibrary准备/登记56.878秒通过。首试错误拒绝原始290个F32调制表，deba254已精确修补，40项CPU/原文件header通过。6328d9c同一Runtime实际首层求值后取消50.034秒→原始704×480/97帧/24fps/30步文生8118.298秒→首帧条件8801.697秒完成，单方法16970.227秒，每次许可归零。两份真实AV完整解码及Store发布/重开/导出通过；已查看首/中/尾帧。合成首帧的平面红色区域在后续帧仍可见，不能据此宣称通用画质或精确运动服从已验；原生及真人音频未验。 |
| Wan完整目录 | 固定原仓只读取所需文件树，保留额外 google/ 等内容，不遍历/转换无关文件；非固定来源仍严格校验。18项安全/准备CPU通过；实际完整目录登记→释放实例→重开6.822秒通过，原件不变。原生文件面板/即时列表仍待解锁。既有完整转换不重复跑。 |
| Quick/Canvas就绪 | 共享实际resolver、安装代次与快照revision保护已修；6项就绪/外部视频服务检查通过。未将CPU通过写成原生即时刷新通过。 |
| H3 | 父期限已正确传递，App显式12小时；保留进程组、取消与drain。dba33e6完整512²/22帧/24fps/50步文生1267.116秒、首尾条件2004.600秒，同一方法3271.875秒通过；全50层原始BF16/SSD，每次许可归零。两段已查看首/中/尾帧、各自产物Store发布/重开/导出通过；不是同包GUI或真人试听。 |
| hosting | 两项既有离屏测试仍失败。98dcb9c有界AX诊断访问242对象、队列耗尽、0个identifier，动态读取也相同；实际点击尚未送出。待同版可见窗口对照，不归因于锁屏或删除断言。 |

## 原生与本人事项

r4的最后原生检查明确报告锁屏；本轮桌面库存可读，尚未证明目标D可操作或已经解锁。工具未提供自动解锁能力；不改系统权限。H22实际客户端/firstRect/指针来源取证、H32双入口/拖放等，以及本轮就绪刷新和完整Wan目录原生导入，统一留在[集中待办](FAILURE_AND_PERMISSION_AUDIT.zh-CN.md)。不重开已关闭的录音、断网、Xcode和H31；用户返回后在同一普通签名包集中办。

H22诊断仅 DEBUG、显式测试会话开启，不记录输入文本；当前只完成定位装置与父坐标修正，尚无候选窗/指针实际根因或修复结论，不能靠通知计数关闭。旧本人结论为选字正常、候选窗位置不随动，I型/缩放指针闪后变箭头。

## 复用、交付与恢复边界

R3 ACE原始F32完整50步四类请求及正式Runtime取消/释放；Klein BF16正式取消、完整生成、有序双参考及dd00普通App双入口/保存重开；Qwen原文字/双图/工具/取消；Wan转换/发布服务，均保留精确历史版本。改动影响核对后复用，不称在r4重跑。原普通App/旧试用会话/个人数据不改。

当前推荐入口见[试用指南](RELEASE_FREEZE_TRY.zh-CN.md)：r4/delivery的`启动首发收口候选.command`和`D Release Freeze Closeout.app`。正常签名App代码6328d9cd7dca1edb1b2a5b233089bb73469be7ca，嵌入引擎/资源由同树构建生成，签名、关键文件与启动器只读检查通过；同树Xcode配置指向resources-progress。未构建后手补provider；本包原生启动/操作仍受锁屏阻塞，不能提前宣布试用验收/冻结通过。

恢复先核真实 HEAD/index/个人scheme及R4/lead/final-receipt.json，核活动进程句柄/模型任务与受测二进制，再继续；编译产物的受测SHA可能早于只改其他路径的新提交，必须检查差分。LTX串行作业与两份Store复验均已结束，不要重开等待器或重复生成。所有写Worker已交回，旧拒绝/审核时序及修复额度保留。重构建/GPU/GUI串行，只回收本轮拥有的进程，不关闭未知D。

**功能冻结仍未通过。** 同包原生验收、剩余完整模型/条件与发布责任继续保留。AP1/CORE/I2V候选不自动接纳；无权重分发、首次使用、依赖封装、升级恢复、许可与渠道责任见[发布差距](MODEL_SUPPORT_AND_RELEASE.zh-CN.md)。本轮结束停在用户试用/冻结判断；公开main更新不关闭这些验收责任，不自动转入新模型或下个产品阶段。
