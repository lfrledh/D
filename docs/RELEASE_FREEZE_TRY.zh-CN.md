# D 开发预览：本轮试用

2026-10-08 · CHAT-PRODUCT-20261003本轮功能门槛已收口，达到视觉转段门槛；F26真实搜索API/凭据按用户批准延期。尚非正式发行，未自动开始质量审计或UI改版。唯一逐项状态见[聊天清单](CHAT_FEATURE_LEDGER.zh-CN.md)。

## 唯一推荐启动入口（开发验收包）

双击原有入口：
`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261004T145523Z-continuous-closeout/delivery/启动聊天当前验收.command`

现在只指向 **D Chat Product 8cf1b7dd.app**：
`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261007T132148Z-drop-position/delivery/D Chat Product 8cf1b7dd.app`。

实际受测生产代码 **8cf1b7dd46f6041dbcf1ac3db75b19839ae390c4**；普通签名构建27.966秒成功。复制前后可执行文件、调试库、Info.plist、CodeResources一致，签名验证通过，没有手补/重签。RPosition为上述run，见`lead/compact-app-version.json`、`compact-native-result.json`；最终仅文档版本及main/候选远端对应见`lead/unlocked-closeout-receipt.json`。不宣称在之后文档提交上重新跑过模型。

本包包含已收口的输入响应、长文阅读恢复/搜索、文件拖入修补与Dev SSD入口。52ce本人将left.csv拖到左侧文字区、blank.csv拖到右下空白区并实际松手，两处均成功；Lead双预览、保存退出、冷开和原件/草稿保护通过。8cf仅移除非空会话多余尾占位，6 XCTest＋4 Swift Testing通过（原3失败保持标准），同版普通App上滚/Bottom、内部位置恢复、首次搜索、可见链接取消和Undo通过。旧语音、模型、工具/恢复证据按未变路径复用，没有新一轮全模型生成。

入口仍用隔离偏好`BC96EF26-C157-4A48-84B4-A54785B1A42E`，已有D时拒绝双开，不覆盖普通D。旧3cc/abd5/d1ab/6fb/fe0/52ce包及失败证据全部保留，已不是推荐入口；具体前后对照见[原任务记录](tasks/D-RELEASE-FREEZE-01.md)。不要同时打开旧测试版。

CSV直接成为附件，无需确认框；输入托盘外侧16点padding也接收文件，故可比深色文本框略宽。移出后的加号短暂保留仅为用户观察，没有证据称是特意的延迟设计。成功应以松手后附件出现为准，未把悬停或加号本身当通过。

## 从保留的小项目继续

1. 解锁后启动，菜单“文件→打开项目”，选择本轮独立恢复副本：
   `/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261004T145523Z-continuous-closeout/gui/unlocked-20261005/Restored-chat-1ebe7042.dproject`。
   “Reading corner lighting”保留比较、人工版本、PDF/DOCX/OCR与记忆；“List twelve…”保留部分回答、空取消、成功OK及工具/成果；两个空会话用于默认系统提示词作用域检查。不要覆盖原项目或旧包。
2. Quick→文字。主操作为输入区“发送／停止”；未接受前不替换历史原文。671已修首字前停止后不能续发，并实际得到OK。新菜单首项“重命名”已实点保存；“收藏”和已有分支首项已用鼠标+Return操作，答案版本子菜单经鼠标展开＋键盘选择已补；1057/962pt主操作和浮层关闭已在1ebe验证，不等于所有布局完成。
3. 检查器可看已有知识重排、Python失败/成功/取消记录、单位/时区及HTML/Mermaid成果。Mermaid两个保存版本互不覆盖，放弃未保存不会改旧版；临时会话只有显式保留成果进入Canvas，不自动运行。Python仍是有预算的WASI标准库，不是宿主任意终端。
4. 1ebe已用普通App执行新包→独立恢复→冷重开，完整4版本会话记忆及17份独立媒体保持。旧af包遗漏不会自动补写；新恢复不自动打开未来记忆授权。全局预设另行交换。
5. 联网“搜索与工具”保留Brave/博查入口，但真实API和凭据本轮已批准延期，无需现在办理。未配置不会伪造结果；摘要不是已读取正文，采用正文后才交本地模型。
6. 输入托盘“语音输入与系统朗读”手选普通话/英语。两种本地转写→审核→采用未发送草稿已有实际证据；英语本人确认及系统朗读听感已通过，本包补默认声音与暂停/继续/停止操作。无需重复录音或试听；旧失败记录保留，不自动转云。

本轮两个定点项目可继续查看：`run-20261007T132148Z-drop-position/gui/Drop-position.dproject`保留左右拖入附件；`run-20261007T104034Z-desktop-resume/gui/Reading-acceptance.dproject`保留24节长文（相对AgentTrials/D-RELEASE-FREEZE-01）。不需要重新运行模型或重复本人输入/试听。

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

Quick/Canvas选真实模型，高级参数选择**省内存（SSD分层加载，精度不变）**。Dev的该选项已在9b6c982b补通，普通App选择与保存冷开证据保留，新推荐8cf包含该修补。常驻/分阶段保留；不自动量化、裁层或删条件。短起步配置可用：ACE6秒/50步/guidance7/seed7；Klein512²/4步/guidance1/seed42；Qwen关闭思考、输出上限256的简短请求。开发机短请求使用显式15GiB预算，不是产品上限或任意长输入保证。

沿用前轮cd4cd4b的Qwen9四帧请求与Klein完整生成/有序参考实测；本轮为F16补两次已有Qwen Q4思考通道短请求，均按所设输出长度结束且没有final；不能把它当完整回答质量通过。其他模型没有重复生成。Dev50步、H3原始完整50步及LTX2.5原始30步的未变计算沿用R4结果，单次LTX约135–147分钟；不因慢而减少精度/层数。精确profile、已验条件及未验范围见[能力矩阵](RELEASE_MODEL_MATRIX.zh-CN.md)。H3既有执行包位于`Models/D-Video-Packs/H3-FL2VA-BF16`；LTX既有包位于`run-20261001T162316Z-r4/lead/ltx-production-prepare/prepared/ltx-2.5-bf16-9CB71D89-01ED-4227-9C35-E53AA16FB8CB`（相对AgentTrials/D-RELEASE-FREEZE-01）。Wan完整原仓服务已验，内嵌转换仍保持原件并独立发布，Wan仅T2V。无需重复准备已有有效包。

已有视频无需重复人工审阅：2026-10-03本人确认新的LTX倒水→停止、H3自然首尾两段均正常。LTX固定完整30步/原始BF16样本约−34dBFS，PCM至AAC没有幅值坍缩；H3固定完整50步/原始BF16张量与F32组件。旧LTX近静音及合成红块的历史不抹去，旧近静音首异常层仍未知；新样本通过不是所有参数的质量保证，也不是B App视频生成入口通过。精确记录在当前任务RC/q，未再随机抽卡。

## 同树 Xcode Run

打开与推荐包同生产代码的候选工作树（8cf1b7dd＋随后仅文档结案）：
`/Volumes/CodexProjects/Codex/D-Worktrees/D-RELEASE-FREEZE-01/D.xcworkspace`

选择 **D Nodes / My Mac / Debug**。本机忽略配置`Development/Development.local.xcconfig`使用既有签名身份，资源目录为：
`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261004T041401Z-chat-resume/delivery/resources-with-python`

正常Xcode资源阶段嵌入现有引擎与ChatPython，无需手补App或重装模型。本轮同树D Nodes普通签名build通过，代理已在同代码App执行上述定点原生检查；没有让本人点击Run，未重跑模型。换机按[开发说明](../Development/README.md)准备资源。main正常接纳同一8cf生产代码及随后文档；main与候选精确SHA见本轮外部回执。构建入口仍推荐上述已核资源配置的同树workspace。

## 集中办理与交付边界

此前已验的恢复、紧凑布局、真实重排、临时成果和工具取消等证据沿用。本次处理原集中队列，首次语音授权的工程崩溃已修补；语音实测、Bottom与其他原生操作的最新结果只见[当前行动](CURRENT_ACTIONS.zh-CN.md)及[唯一队列](FAILURE_AND_PERMISSION_AUDIT.zh-CN.md)。搜索凭据/实调按本人决定延期；不重复旧授权和固定视频。

本轮既定聊天代表验收已收口，可供用户审计并决定下一视觉阶段；F26仅按明确决议延期，未称真实联网通过。功能收口不等于正式发行：首次使用、无权重分发/依赖封装、升级恢复和渠道责任仍保留。没有强推、改许可证或发布Release。
