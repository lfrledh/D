# D 开发预览：本轮试用

2026-10-07 · 完整聊天专题仍在连续收口，**尚未达到功能冻结**。main为90819739e99b366d7cdb2f549c129eea28728206（生产af0103b5）；下列为审计/继续验收候选，不能当成原生门槛全部通过的稳定版。唯一逐项状态见[聊天清单](CHAT_FEATURE_LEDGER.zh-CN.md)。

## 唯一推荐启动入口（开发验收包）

双击：
`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261004T145523Z-continuous-closeout/delivery/启动聊天当前验收.command`

入口原位保留，现在只指向 **D Chat Product 3cc71bee.app**：
`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261006T130047Z-quality-transition/delivery/D Chat Product 3cc71bee.app`。
实现/测试代码 **3cc71beecf13e70c7d6bce106172996c07daa210**；最终普通签名构建39.955秒成功。交付副本与实际受测构建包的可执行文件、调试库、Info.plist和CodeResources一致，签名复核通过，没有手补/重签。RQuality为上述run，证据 `lead/delivery-version.json`、`verified-source-final-build.json`；最终文档与远端SHA见 `lead/quality-transition-receipt.json`。

本包减少每次编辑重复查询声音的负担，本人确认输入/删除基本正常。代理已实际操作：消息分叉、自定义选段指令＋PDF引用、资料库成果采用、思考/无正文分层、表格复制、外链确认、CSV/SVG预览和系统朗读暂停/继续/停止；正常关闭重开后草稿与附件保留。旧冷开Bottom/搜索、个人记忆/MCP、英语识别与听感证据按未变范围复用，新的5项滚动hosting已通过。

**这是开发试用候选，尚未达到视觉转段或完整功能冻结。** 长单条Markdown在滚动/链接确认返回时有阅读位置跳动，两个局部实验未改善，已移除；Finder真实拖入尚缺有效操作证据。不要用此包处理唯一一份重要资料，继续使用下面的隔离小项目。旧包与失败证据保留，不混用启动入口。

入口复用隔离偏好`BC96EF26-C157-4A48-84B4-A54785B1A42E`及已登记模型，已有D时拒绝双开，不替换普通D。本人不能操作；本轮随后再次锁屏，代理原生验收已暂停，现在无需新增授权、输入或试听。F26搜索实调/凭据已获准延期，未验不记通过。

## 从保留的小项目继续

1. 解锁后启动，菜单“文件→打开项目”，选择本轮独立恢复副本：
   `/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261004T145523Z-continuous-closeout/gui/unlocked-20261005/Restored-chat-1ebe7042.dproject`。
   “Reading corner lighting”保留比较、人工版本、PDF/DOCX/OCR与记忆；“List twelve…”保留部分回答、空取消、成功OK及工具/成果；两个空会话用于默认系统提示词作用域检查。不要覆盖原项目或旧包。
2. Quick→文字。主操作为输入区“发送／停止”；未接受前不替换历史原文。671已修首字前停止后不能续发，并实际得到OK。新菜单首项“重命名”已实点保存；“收藏”和已有分支首项已用鼠标+Return操作，答案版本子菜单经鼠标展开＋键盘选择已补；1057/962pt主操作和浮层关闭已在1ebe验证，不等于所有布局完成。
3. 检查器可看已有知识重排、Python失败/成功/取消记录、单位/时区及HTML/Mermaid成果。Mermaid两个保存版本互不覆盖，放弃未保存不会改旧版；临时会话只有显式保留成果进入Canvas，不自动运行。Python仍是有预算的WASI标准库，不是宿主任意终端。
4. 1ebe已用普通App执行新包→独立恢复→冷重开，完整4版本会话记忆及17份独立媒体保持。旧af包遗漏不会自动补写；新恢复不自动打开未来记忆授权。全局预设另行交换。
5. 联网“搜索与工具”保留Brave/博查入口，但真实API和凭据本轮已批准延期，无需现在办理。未配置不会伪造结果；摘要不是已读取正文，采用正文后才交本地模型。
6. 输入托盘“语音输入与系统朗读”手选普通话/英语。两种本地转写→审核→采用未发送草稿已有实际证据；英语本人确认及系统朗读听感已通过，本包补默认声音与暂停/继续/停止操作。无需重复录音或试听；旧失败记录保留，不自动转云。

已验版本分开：推荐仍3cc71bee；9230的未变Bottom/搜索/恢复与本人英语证据复用。2026-10-07工作树增加未接纳阅读候选2cd9a588dd6d2c6a1f567019222bf3290d847c17，**与推荐包不同代码**；原生复验在打开项目时被锁屏阻塞，不替换唯一启动器。main仍90819739（af生产基线）。新候选构建/摘要/未验范围见run-20261007T004102Z-drag-reading/lead/reader-candidate-version.json，不建议用户混用诊断包。

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

沿用前轮cd4cd4b的Qwen9四帧请求与Klein完整生成/有序参考实测；本轮为F16补两次已有Qwen Q4思考通道短请求，均按所设输出长度结束且没有final；不能把它当完整回答质量通过。其他模型没有重复生成。Dev50步、H3原始完整50步及LTX2.5原始30步的未变计算沿用R4结果，单次LTX约135–147分钟；不因慢而减少精度/层数。精确profile、已验条件及未验范围见[能力矩阵](RELEASE_MODEL_MATRIX.zh-CN.md)。H3既有执行包位于`Models/D-Video-Packs/H3-FL2VA-BF16`；LTX既有包位于`run-20261001T162316Z-r4/lead/ltx-production-prepare/prepared/ltx-2.5-bf16-9CB71D89-01ED-4227-9C35-E53AA16FB8CB`（相对AgentTrials/D-RELEASE-FREEZE-01）。Wan完整原仓服务已验，内嵌转换仍保持原件并独立发布，Wan仅T2V。无需重复准备已有有效包。

已有视频无需重复人工审阅：2026-10-03本人确认新的LTX倒水→停止、H3自然首尾两段均正常。LTX固定完整30步/原始BF16样本约−34dBFS，PCM至AAC没有幅值坍缩；H3固定完整50步/原始BF16张量与F32组件。旧LTX近静音及合成红块的历史不抹去，旧近静音首异常层仍未知；新样本通过不是所有参数的质量保证，也不是B App视频生成入口通过。精确记录在当前任务RC/q，未再随机抽卡。

## 同树 Xcode Run

打开当前候选工作树（当前为未接纳阅读候选2cd9a588，与推荐3cc71bee包不同代码；仅用于继续开发/验收，不宣称已修好）：
`/Volumes/CodexProjects/Codex/D-Worktrees/D-RELEASE-FREEZE-01/D.xcworkspace`

选择 **D Nodes / My Mac / Debug**。本机忽略配置`Development/Development.local.xcconfig`使用既有签名身份，资源目录为：
`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261004T041401Z-chat-resume/delivery/resources-with-python`

正常Xcode资源阶段嵌入现有引擎与ChatPython，无需手补App或重装模型。本轮同树D Nodes普通签名build通过，实际已验路径见上；未让本人在Xcode点击Run。换机按[开发说明](../Development/README.md)准备资源。**main工作树仍为af生产基线**，不能用main Run冒称候选推荐包同代码。

## 集中办理与交付边界

此前已验的恢复、紧凑布局、真实重排、临时成果和工具取消等证据沿用。本次处理原集中队列，首次语音授权的工程崩溃已修补；语音实测、Bottom与其他原生操作的最新结果只见[当前行动](CURRENT_ACTIONS.zh-CN.md)及[唯一队列](FAILURE_AND_PERMISSION_AUDIT.zh-CN.md)。搜索凭据/实调按本人决定延期；不重复旧授权和固定视频。

这是可构建的试用候选与准确停点，**不是完整聊天验收通过、功能冻结或正式发行**。未完条目保留同号，不移至发布后；未强推、改许可证或发布Release。首次使用、无权重分发/依赖封装、升级恢复和渠道责任仍保留。
