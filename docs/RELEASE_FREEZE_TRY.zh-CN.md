# D 开发预览：本轮试用

2026-10-04 · 当前为完整聊天专题的增量验收候选。main `f9a439db5c0542d7a6bd6def8f88a9a7965b67df` 已接纳与 c16 相同的生产代码，普通App菜单、发送、输入区主停止、部分回答采用和会话往返已验。下面的新包另含F14/F26/F28/F31修补与接线，已构建、签名和定向验证，**尚未完成新包的原生操作验收**。逐项状态只见[唯一聊天清单](CHAT_FEATURE_LEDGER.zh-CN.md)，不把构建或组件通过写成完整专题/冻结通过。

## 当前候选唯一验收入口

双击：
`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261004T041401Z-chat-resume/delivery/启动聊天当前验收.command`

它启动同目录 **D Chat Product f08ca242.app**，代码/构建版本 **f08ca2427b54e0519780e473ea7dfcce431af234**。最终文档提交不改变该包代码，完整交付/远端映射见同一run的 `lead/resume-delivery-receipt.json`。隔离偏好 `BC96EF26-C157-4A48-84B4-A54785B1A42E` 继续复用已有模型登记，不替换普通D。副本签名、四关键文件及内置WASI关键文件均与构建/资源来源核对。

入口会拒绝双开，不替你关闭正在运行的D。当前自有c16测试实例PID829留在锁屏现场、没有在途生成；下次解锁由Lead先核实并正常退出，再用本入口。旧包和证据保留，均非本轮推荐入口。不要同时打开多份测试D。

## 解锁后的有界试用路径

1. 打开隔离小项目 `/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261003T150039Z-chat-continue/gui/Chat-integration.dproject`。已有Qwen登记继续使用；不要改原始长流项目或重复下载模型。
2. Quick→文字。c16的菜单/发送/主停止反例已关闭；新包只按影响补原生回归和剩余管理操作，不重复长生成。生成时输入区主操作是“停止当前生成”；被停止的回答需显式采用后才可继续。回答菜单区分“新候选”和“按旧参数/seed重现”。
3. 在本次实际请求检查器查看普通包含token/key的文字应仍可读；敏感凭据字段受保护。分享导出是另一个脱敏投影，不把本地查看与公开分享混为一谈。
4. 在“检查器→资料→搜索与工具→工具”选择 **Python 分析**：用内置示例，或勾选草稿中的文字/CSV附件；界面给出只读输入路径。点击“运行这段代码”，查看stdout或“打开成果”，在既有成果编辑器中明确保存。Python不能访问网络、宿主文件或凭据，不支持pip/原生扩展；本版是有预算的标准库分析，不是任意终端。真实WASI→CSV/SVG→Store→独立备份恢复及取消已通过；这次还需验证普通D中的点击、错误提示和保存入口。
5. 同一工具选择器→“联网搜索”，手动选择 **Brave Search / 博查 Web Search**，选择本人本地凭据文件后显式允许本会话联网。文件只含相应API key，不在聊天粘贴，App不代注册或购买。搜索摘要不是已读正文；点击“读取网页正文”后才可采用来源，回答仍由本地模型生成。两家带凭据真实请求及大陆可达性未验，缺key时不伪造结果。
6. 语音入口手选 **普通话 / 英语**，录音或选择已有音频→本地转写→审核→采用到草稿；不会自动发送或转云。系统权限/语言资源及真实转写、试听要按[集中清单](FAILURE_AND_PERMISSION_AUDIT.zh-CN.md)办理。
7. 复用已有小材料检查成果→Canvas、会话交换、备份→独立恢复和冷重开。分别留证，不把所有路径挤成一个难定位的巨型测试。对话/原始回答/附件不得被成果编辑或继续聊天覆盖。

c16已实际完成TXT导入、词法检索第3行并采用、上下文、计算器结果采用和选段解释。F18组合hosting现已完整结束；新Python真实接线/签名沙盒测试宿主、实际公网网页读取各有独立证据，但不替代普通App入口。旧A备份恢复、冷启动、本人H22与固定视频结果复用。新聊天宿主组字及本地Speech确需本人时集中办理，不重问旧模型资格。

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

打开本候选实际构建的工作树：
`/Volumes/CodexProjects/Codex/D-Worktrees/D-RELEASE-FREEZE-01/D.xcworkspace`

选择 **D Nodes / My Mac / Debug**。本机忽略配置 `Development/Development.local.xcconfig` 已复用原签名身份并指向一次准备好的：
`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261004T041401Z-chat-resume/delivery/resources-with-python`

正常Xcode资源阶段已验证并嵌入现有引擎和新增ChatPython；无需手工修补App、重复准备或下载模型。本轮同树命令行Xcode普通签名构建通过，未在锁屏时宣称已手动点Run。依赖缺失或换机按[开发说明](../Development/README.md)准备资源；主线树当前仍是已验c16同码基线，不能用它冒充新候选同版入口。

本轮固定构建命令、完整资源来源、签名和副本检查在上述run的 `lead/chat-f28-app-result.json`、`lead/f28-resources-real-result.json`、`lead/app-f08ca242-delivery.json`。资源/权重留外盘，不随代码推送。

## 集中办理与交付边界

[唯一集中清单](FAILURE_AND_PERMISSION_AUDIT.zh-CN.md)保留：解锁后由Lead补剩余原生路径、新聊天宿主组字、系统本地语音与试听、F26本地凭据和真实API。H22/HF/宏信任/固定视频已办理，不重复。当前没有启动新GUI或新终端；自有旧App仍保留，未知终端不操作。

新包是已构建的可试用候选，Mac锁屏使本次新增原生验证尚未完成。全范围未结案，未完成项不移至发布后；主线接纳、候选审计、功能冻结和正式发行分别判断。没有发布正式安装包/Release，没有改许可证或收费；无权重分发、首次使用/依赖封装/升级恢复/渠道责任继续保留。
