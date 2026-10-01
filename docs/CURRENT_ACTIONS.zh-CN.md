# 当前行动与接手点

最后核实：2026-10-01。当前任务、候选、停点与下一动作只从本页进入；历史回执不再充当开工指令。

## 当前任务：D-RELEASE-FREEZE-01 原始精度低内存续作 r3

- 源：`codex/inference-foundation@01758b81527dc27eb4563bf1b66fd1ceab6647ee`，未接纳本候选。
- 实施：外盘 `D-Worktrees/D-RELEASE-FREEZE-01`，`codex/release-freeze-01`。从 `49ad3dc7c1bc63aab3e6afd9491cf3bc6e5eea3d` 保留历史续作，最终受测代码 `b315ffa0c2d8d191204b0b93f1afdaaaae46e865`；结案最终 SHA 见[任务](tasks/D-RELEASE-FREEZE-01.md)及 R2/lead/final-receipt.json。
- R2：`D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20260930T142825Z-closeout`。日志、样本与测试产物留此，不能只凭目录存在推断通过。
- 本轮明确不合并受保护源或 main，不公开发布。只收口既定九模型及直接影响的应用缺陷，不开启训练、远程、移动端或新增家族。

## r3 执行中（不是验收回执）

从候选/远端c44f6438a6090f305cd3dd5dfd9d9c98f4ec47b6接续，源及scheme未变。R3=`D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261001T040512Z-low-memory`。用户明确优先原始精度/完整层数/完整条件并接受慢：ACE先做逐张量执行准备、分阶段释放与SSD逐层加载，随后Klein BF16；不以swap、估算或初期耗时直接停止。保留常驻模式、加载与精度分开。H31真实仓库/本机登录入口已准备，未启动登录等待。文字增量正文、Wan准备和既有UI工程继续；不并发高内存作业，不重开新模态。下文为r2可复用结果，最终新版本须另记实测。

## 已取得的增量与尚未闭合

类型化 VLM 消息/媒体顺序/思考控制/工具往返和 raw/final 响应资产已进入候选；九模型固定下载清单复用模型库，完整性、访问错误与执行前准备状态分开。ACE 固定上游离线加载补丁、重复校验精简和 decoder 副本释放已装配。保存增长的局部重复工作、跨项目空图与保存同步失败重试已补反例；不宣称所有性能或 UI 问题已经解决。

Qwen9B Q4 的真实 JSON、双图顺序、视频和工具结果往返已通过；Klein Q8 数值 A/B 已解释并由非实现者复核，固定新引擎仍用唯一严格基准。具体受测版本、CPU/真实模型/GUI分层见任务；其他型号不能据此算通过。

普通App已完成Qwen9B Q4的Quick/Canvas真实JSON与保存冷重开；H3原始144GB经原生模型库校验、独立准备、登记完成，随后修正目录名污染模型标题。ACE6秒/1步F32真实生成通过，但50步在2步后因换页及预计耗时受控停止，非OOM/非成功。

上述原生操作绑定 `41ad63026da948eef6e3b5f5837f63744f1a2c98`；最后 `b315ffa0c2d8d191204b0b93f1afdaaaae46e865` 仅视频实名展示及回归，CPU与正常构建通过。推荐启动器已启动最终包；之后CUA明确报告Mac锁屏，修补后的界面复验未执行，已记H32，不重复催解锁。

**冻结尚未通过**：Dev/LTX2.5固定资源访问仍受H31阻塞；27B、原始BF16等配置及ACE合理采样/强条件、每模型同包原生入口未验。H3/LTX无转换打包已接，Wan原始权重数值转换的沙盒子进程/封装/发布接线仍缺，不能把“原文件完整”写成“可执行”。H22输入法位置、两个hosting失败与完整拖放责任仍保留。模型原生能力清单、未实现项与 profile 边界见[矩阵](RELEASE_MODEL_MATRIX.zh-CN.md)，改名不关闭缺口。

## 试用、保护与恢复

唯一推荐入口以[精简试用](RELEASE_FREEZE_TRY.zh-CN.md)的已交付版本为准；构建中的新包不是推荐成品。Xcode 使用候选同树 `D.xcworkspace` / **D Nodes / My Mac / Debug**，不是内盘空仓库，也不是旧源树。

保护源个人 scheme 未暂存改动（历史 orderHint 1→6；实际以 R2/lead/protection-before.json 为准）、普通 App、项目/模型原件与旧候选。源与候选 index/HEAD、已知进程先核实再恢复；不能仅依赖本摘要。写 Worker 已交还文件，重要 Lead 改动经定点非实现者复核；真实执行与审阅分别记载。

本人操作只见[集中清单](FAILURE_AND_PERMISSION_AUDIT.zh-CN.md)：H31平台访问、必要真人IME/试听与新锁屏事件。已关闭的录音/断网不重复办理。工程问题不推成用户授权。

## 保留的历史与发布责任

- 前端拖放/返回/输入法历史：[D-UI-BASELINE-02](tasks/D-UI-BASELINE-02.md)；视频与旧媒体失败：[D-VIDEO-MODELS-01](tasks/D-VIDEO-MODELS-01.md)。本轮已修问题以本轮证据覆盖状态，原失败不倒改。
- 已入源基础：[D-NODE-LANGUAGE-01](tasks/D-NODE-LANGUAGE-01.md)、[D-NODE-QUALITY-01](tasks/D-NODE-QUALITY-01.md)。旧入口/旧日期“下一步”不再是当前许可。
- AP1/CORE/I2V候选保留、不自动合入。内部 Pitch 评估权重、依赖分发、首次使用/升级恢复、渠道与签名仍按[发布责任](MODEL_SUPPORT_AND_RELEASE.zh-CN.md)核验。

停在本收口候选的用户试用点；不自动开启下一产品阶段。后续仍须关闭上述同一冻结名单的工程与实测缺口，当前不是已进入全绿发布QA。功能冻结必须逐项达到现有出口，文档变短或分类完成不代表架构/产品/发布已完成。
