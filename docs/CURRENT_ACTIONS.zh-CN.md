# 当前行动与接手点

最后核实：2026-09-26。**本页是当前任务、版本、停点与下一动作的唯一入口**。历史任务、旧“接下来”及其他候选不自动授权续跑。

## 当前任务：节点边界与语言包（候选验收）

用户批准 [D-NODE-BOUNDARY-01](tasks/D-NODE-BOUNDARY-01.md)：整理节点/模型/格式与显示语言边界，保留原运行时、存储、模型精度和用户数据。不是新增模态、插件市场或全后端重写。

| 对象 | 已核实版本/位置 | 状态 |
| --- | --- | --- |
| 源 | `/Volumes/CodexProjects/Codex/D`，`codex/inference-foundation`，`58603870719a52ff07b6bb6e4d6d09e02c23901a` | 未推进，个人scheme仍未暂存 |
| M0候选 | `D-Worktrees/D-M0-01`，`codex/d-m0-01`，`bbf508024a80250b9e4b468e1f5713b7b13dcc13` | 保留不动；实际受测代码c8ae6f0a94958f494c4648a2beed547e7a98f0a4，T15仍未执行 |
| 本批候选 | `D-Worktrees/D-NODE-BOUNDARY-01`，`codex/d-node-boundary-01` | 从M0候选开始，受测组合`76bd5963c779c74268c69fa6a4851533768ea4c3`；最终文档SHA见外部final-handoff.json |
| 本批证据 | `D-Development/AgentTrials/D-NODE-BOUNDARY-01/run-20260926T045011Z/` | 大日志与产物留外盘，任务记录只留索引 |

绝对根均为`/Volumes/CodexProjects/Codex/`。内盘Documents/ChatGPT/D空仓库不是本工程。

## 实现边界

- 每个文字/图像执行节点冻结自己的模型身份，按节点取运行租约和实现/配方；缺失或不兼容明确拒绝，不偷用当前页面的模型。模型选择捕获项目、图、节点、操作与旧绑定，迟到选择不得写错节点。
- 具体操作归入`DWorkbench/Workflow/Operations`；`Workflow/Models`负责绑定/私有书签与配方，`Media/ImageCodec{,Registry}`承接PNG/JPEG格式差异。静态装配复用同一Store和DRuntime，未做动态代码插件或任意新格式支持。
- 语言架构位于`UI/Localization`，内置中英及外部纯JSON包；覆盖流程画布通用控件、操作说明投影与语言入口。界面文字与执行ID/参数/用户正文分开，换语言不重建编辑器。旧模态页面、服务错误/运行计划的完整翻译尚待逐步迁移。
- 命名/责任与新增模块路线见[实际导航](REPOSITORY_MAP.zh-CN.md)、[后端扩展约束](BACKEND_EXTENSION_CONTRACT.zh-CN.md)。这些文件区分源基线与候选，不把旧源升级成新能力。

## 本轮证据与未测范围

`76bd596…`：完整UI包通过 **127 UI（含离屏hosting）、23 ModelLibrary、459 DWorkbench**；App测试构建通过。完整SHA/命令/退出状态见`lead/combined-ui-final`和`lead/app-build-final`。模型路径/语言hosting的早期失败与修正保留，不相加虚构通过率。

同一版本的真实双文字模型及M0图文回归均通过（分别4.50/86.16秒测试时间）：核对实际request模型，三图候选/明确采用/处理/JPEG导出/保存重开/真实取消/独立文稿对照。详见任务验证矩阵和lead/real-evidence。普通App独立构建、签名完整性与沙盒核对通过，位于本run `cache/DerivedData-Regular/Build/Products/Debug/D.app`，隔离启动入口`lead/Launch-Boundary.command`已备妥但未执行。

CPU/hosting、XCTest宿主真实模型、普通App构建分别报告；未做本批原生窗口/实际离线/发行验收。GUI受锁屏阻塞登记H26；M0 T15依赖登记H25，未满足前不推进源。写Worker、构建与模型测试进程均已结束，无后台等待脚本。

## 保护与未整合候选

- 源唯一差异：`D.xcodeproj/xcuserdata/lfrledh.xcuserdatad/xcschemes/xcschememanagement.plist`的orderHint 1→6；SHA256 `ca3635d88aa5a15397b90e528667c66c0e6db7e596176e885c79d194b544206c`，index blob `9c76916bdc97c2d4298cefe64e0b0fae3380573e`，未暂存。保护副本/前后检查见本run。
- AP1 `e5d24f4e1064423238e3c8e1112bc4b3a9a81e2e`、CORE `9d3a503d327a820cb67e399922a07c27f953e903`、I2V历史候选与预算不变，不随本批合入。
- 原模型、作品、普通D、M0应用与旧证据保留。没有变更Team/bundle ID/权限/钥匙串/依赖锁/图schema，没有推送或推进main。

## 集中待办与停止位置

见[集中待办](FAILURE_AND_PERMISSION_AUDIT.zh-CN.md)：

- **H25**：M0真实断网T15尚未执行。上次本人断路由器WAN，本机Wi-Fi仍连接，旧检测未触发；这是检测条件漏识别，不是模型失败。两次旧等待均已结束。下次重新协调单次明确断网窗口，不照旧提示断网；联网时的offline flags不算证据。
- **H26**：本批普通App语言包导入/中英切换/草稿和选区/按节点选择不同模型的原生补验。解锁后补验，不再问机器是否空闲，不重新申请已关闭权限。
- H22输入法候选框跟随按用户决定延期；旧麦克风/歌声/Xcode事项不重开。

本批可执行验证已完成，保留可运行候选和精确证据；依赖及原生补验通过后再按现行规则接纳已验组合。到本批检查点停止，不自动启动新节点、新模态、旧S6/AP1/CORE/I2V或发布。下一有限建议是补H25/H26，然后按用户优先级逐模块扩展，不能先宣称全部应用解耦。

## 依赖M0的历史证据索引

[M0任务](tasks/D-M0-01.md)、[旧候选试用说明](M0_TRY.zh-CN.md)。M0主链18cb9ec9cdf81a7e849204a40226cc91223c275e已做普通沙盒App真实图文三候选、人工决定、保存重开/局部重跑/来源和文件/模板组合；c8ae6f0取消提示修补后又做原生取消及后续文字。证据`D-M0-01/run-20260925T112546Z-gui/evidence`。这些是复用历史证据，不等于本批GUI重测。
