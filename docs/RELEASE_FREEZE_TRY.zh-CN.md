# D 开发预览：本轮试用

2026-10-06 · 完整聊天专题仍在连续收口，**尚未达到功能冻结**。main为90819739e99b366d7cdb2f549c129eea28728206（生产af0103b5）；下列为审计/继续验收候选，不能当成原生门槛全部通过的稳定版。唯一逐项状态见[聊天清单](CHAT_FEATURE_LEDGER.zh-CN.md)。

## 唯一推荐启动入口（开发验收包）

双击：
`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261004T145523Z-continuous-closeout/delivery/启动聊天当前验收.command`

入口原位保留，现在只指向 **D Chat Product 9230a6cd.app**：
`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261006T110535Z-unlocked-bottom/delivery/D Chat Product 9230a6cd.app`。
代码 **9230a6cdabf40b540b17401d39b9ac64181cd265**；普通签名构建51.718秒。实际原生操作在同签名`D Search Top Experiment.app`上完成，交付副本四关键文件逐字节一致，签名复核通过，未手补或重签。RNow为上述run，见`lead/delivery-version.json`及`gui/search-top-native-result.json`。

本包实际通过原保存项目的冷开上滚→Bottom到末条、离底会话往返、同/跨会话搜索跳转、输入单字符/Undo和正常退出重开。37b30旧搜索卡死已留sample；本次仅将两处搜索目标对齐从center改top，保留目标/门禁/历史。个人记忆新增/启用/编辑/忘记/冷开与MCP在途停止/断开/重连42/冷开分别有原生证据；没有新增模型生成或真人组字。

**这是有限通过的开发试用包，尚未功能冻结。** 两个hosting测试仍没有建立真实离底，断言保持失败；不以原生代表操作把测试涂绿。所有视口/新生成后的滚动组合、具体F表未验项继续保留。旧ff20、0219、37b30包和失败证据不删除；新的推荐只通过本入口进入，避免多开混淆。

入口复用隔离偏好`BC96EF26-C157-4A48-84B4-A54785B1A42E`及已登记模型，拒绝在已有D时双开，不替换普通D。本轮自有App与loopback服务都已结束，无新Terminal；受测/文档/远端及进程见RNow/lead/unlocked-closeout-receipt.json。

本人当前已解锁但不能亲自操作；英语失败后置、朗读/输入体验和搜索凭据留原集中队列，不催办。普通话、Speech授权、旧H22、固定视频、CSV/格式/字段及F09/F12有效证据复用。

## 从保留的小项目继续

1. 解锁后启动，菜单“文件→打开项目”，选择本轮独立恢复副本：
   `/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261004T145523Z-continuous-closeout/gui/unlocked-20261005/Restored-chat-1ebe7042.dproject`。
   “Reading corner lighting”保留比较、人工版本、PDF/DOCX/OCR与记忆；“List twelve…”保留部分回答、空取消、成功OK及工具/成果；两个空会话用于默认系统提示词作用域检查。不要覆盖原项目或旧包。
2. Quick→文字。主操作为输入区“发送／停止”；未接受前不替换历史原文。671已修首字前停止后不能续发，并实际得到OK。新菜单首项“重命名”已实点保存；“收藏”和已有分支首项已用鼠标+Return操作，答案版本子菜单经鼠标展开＋键盘选择已补；1057/962pt主操作和浮层关闭已在1ebe验证，不等于所有布局完成。
3. 检查器可看已有知识重排、Python失败/成功/取消记录、单位/时区及HTML/Mermaid成果。Mermaid两个保存版本互不覆盖，放弃未保存不会改旧版；临时会话只有显式保留成果进入Canvas，不自动运行。Python仍是有预算的WASI标准库，不是宿主任意终端。
4. 1ebe已用普通App执行新包→独立恢复→冷重开，完整4版本会话记忆及17份独立媒体保持。旧af包遗漏不会自动补写；新恢复不自动打开未来记忆授权。全局预设另行交换。
5. 联网“搜索与工具”选择Brave/博查、本地选择自己的凭据文件并允许本会话联网。两家真实API尚未验，不在聊天贴key、不代注册或购买。摘要不是已读取正文；采用正文后才交本地模型。
6. 输入托盘“语音输入与系统朗读”手选普通话/英语。能力查询已验，Speech现已报告允许，普通话本地转写→审核→采用草稿已通过；英语“No speech was recognized”和系统朗读仍在[唯一集中队列](FAILURE_AND_PERMISSION_AUDIT.zh-CN.md)。本人暂不便时不催办、不自动转云。

已验版本分开：9230是本轮实际源内容；37b30完成个人记忆/MCP操作，9230再冷开确认。旧恢复/模型/输入热点等按未变调用复用，不冒称本轮重跑。main仍af生产基线；9230候选与推荐包同代码。


## 使用已下载模型

原件均在`/Volumes/CodexProjects/Codex/D-Development/Models/`：

| 模型 | 目录 |
|---|---|
| ACE-Step 1.5 XL SFT 原始F32 | ACE-Step-1.5-XL-SFT |
| FLUX.2-klein-4B 原始BF16 | release-flux2-klein-4b-bf16 |
| FLUX.2-dev 原始BF16 | release-flux2-dev-bf16 |
| Qwen3.5-9B 原始权重 | release-qwen35-9b-bf16 |
| Qwen3.8-27B 原始BF16 | release-qwen38-27b-bf16 |

Dev现在可直接选择含来源sidecar的原目录，不必清理或另复制到“干净目录”。完整校验和实际推理是两个步骤；看到目录通过不代表所有能力已验证。

Quick/Canvas选真实模型，高级参数选择**省内存（SSD分层加载，精度不变）**。常驻/分阶段保留；不自动量化、裁层或删条件。短起步配置可用：ACE6秒/50步/guidance7/seed7；Klein512²/4步/guidance1/seed42；Qwen关闭思考、输出上限256的简短请求。开发机短请求使用显式15GiB预算，不是产品上限或任意长输入保证。

沿用前轮cd4cd4b的Qwen9四帧请求与Klein完整生成/有序参考实测；本轮未重复模型生成。Dev50步、H3原始完整50步及LTX2.5原始30步的未变计算沿用R4结果，单次LTX约135–147分钟；不因慢而减少精度/层数。精确profile、已验条件及未验范围见[能力矩阵](RELEASE_MODEL_MATRIX.zh-CN.md)。H3既有执行包位于`Models/D-Video-Packs/H3-FL2VA-BF16`；LTX既有包位于`run-20261001T162316Z-r4/lead/ltx-production-prepare/prepared/ltx-2.5-bf16-9CB71D89-01ED-4227-9C35-E53AA16FB8CB`（相对AgentTrials/D-RELEASE-FREEZE-01）。Wan完整原仓服务已验，内嵌转换仍保持原件并独立发布，Wan仅T2V。无需重复准备已有有效包。

已有视频无需重复人工审阅：2026-10-03本人确认新的LTX倒水→停止、H3自然首尾两段均正常。LTX固定完整30步/原始BF16样本约−34dBFS，PCM至AAC没有幅值坍缩；H3固定完整50步/原始BF16张量与F32组件。旧LTX近静音及合成红块的历史不抹去，旧近静音首异常层仍未知；新样本通过不是所有参数的质量保证，也不是B App视频生成入口通过。精确记录在当前任务RC/q，未再随机抽卡。

## 同树 Xcode Run

打开当前候选工作树（生产代码9230a6cd，与上面的推荐包对应；最终文档SHA另见回执）：
`/Volumes/CodexProjects/Codex/D-Worktrees/D-RELEASE-FREEZE-01/D.xcworkspace`

选择 **D Nodes / My Mac / Debug**。本机忽略配置`Development/Development.local.xcconfig`使用既有签名身份，资源目录为：
`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261004T041401Z-chat-resume/delivery/resources-with-python`

正常Xcode资源阶段嵌入现有引擎与ChatPython，无需手补App或重装模型。本轮同树D Nodes普通签名build通过，实际已验路径见上；未让本人在Xcode点击Run。换机按[开发说明](../Development/README.md)准备资源。**main工作树仍为af生产基线**，不能用main Run冒称候选推荐包同代码。

## 集中办理与交付边界

此前已验的恢复、紧凑布局、真实重排、临时成果和工具取消等证据沿用。本次处理原集中队列，首次语音授权的工程崩溃已修补；语音实测、Bottom与其他原生操作的最新结果只见[当前行动](CURRENT_ACTIONS.zh-CN.md)及[唯一队列](FAILURE_AND_PERMISSION_AUDIT.zh-CN.md)。搜索凭据本人尚未准备，保留；不重复旧授权和固定视频。

这是可构建的试用候选与准确停点，**不是完整聊天验收通过、功能冻结或正式发行**。未完条目保留同号，不移至发布后；未强推、改许可证或发布Release。首次使用、无权重分发/依赖封装、升级恢复和渠道责任仍保留。
