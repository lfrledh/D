# D 开发预览：本轮试用

2026-10-05 · 完整聊天专题仍在连续收口，**尚未达到功能冻结**。main已接纳af0103b532ed4b14a35518c3cd5aae7727dcf327可靠修补基线；下列候选另含紧凑主操作和记忆导出修补，不能把编译/CPU通过当作新包全部原生操作通过。唯一逐项状态见[聊天清单](CHAT_FEATURE_LEDGER.zh-CN.md)。

## 唯一推荐试用入口

双击：
`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261004T145523Z-continuous-closeout/delivery/启动聊天当前验收.command`

启动同目录 **D Chat Product 1ebe7042.app**，固定代码 **1ebe7042175de441f708939618a3a4686f5d5ae1**。R指该run目录；签名/副本/构建见 `lead/app-delivery-final.json`、`lead/memory-package-app-result.json`，最终文档和远端SHA见 `lead/continuous-receipt.json`。后续仅文档不改变包代码。

入口复用隔离偏好`BC96EF26-C157-4A48-84B4-A54785B1A42E`与已登记模型，不替换普通D，并拒绝双开。旧包保留但不再推荐。af实例已正常退出；锁屏时新117实例未操作，仅对核实的自有进程结束，1ebe包未启动。请勿同时打开其他测试包。

## 从保留的小项目继续

1. 解锁后打开上述入口。菜单“文件→打开项目”，选择：
   `/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261003T150039Z-chat-continue/gui/Chat-integration.dproject`。
   当前会话为“Reading corner lighting”，保留两份短候选、人工版本、PDF/DOCX/OCR资料、工具成果和未发送Unicode草稿；不用重复下载或修改原始长流项目。
2. Quick→文字。输入区“发送／停止当前生成”为主操作；回答菜单区分新候选与旧请求重现。人工采用后主文应显示选中版本，原始输出可展开，继续聊天不改历史请求。af已实际验证采用/切版本/再编辑；新候选待补1057pt及较窄窗口的按钮与关闭可达性。
3. 检查器“资料／工具”可看已有Python失败诊断及CSV分析、MCP结果、HTML成果。成果必须明确保存/采用，进入Canvas不会自动生成。Python是有预算的WASI标准库分析，不是宿主任意终端；无pip、网络和任意文件访问。
4. 会话菜单“导出可恢复会话包…”→项目文件“恢复手动备份…”→选择**新位置**，再退出重开副本。af旧包已验证17媒体独立，但漏掉尚未使用的本会话审核记忆；1ebe补齐该历史，**新包原生导出/恢复及冷开仍待验**，请保留旧包和原项目，不覆盖它们。
5. 联网在“搜索与工具”选择Brave或博查、本地选择自己的凭据文件并允许本会话联网。不要把key放到聊天。搜索摘要不是正文，读取并采用正文后才进入本地回答；两家真实API尚未验，不代注册或购买。
6. 输入托盘“语音输入与系统朗读”手选普通话/英语，录音或已有音频→本地转写→审核→采用草稿，不自动发送。两语言能力查询通过，系统许可和实际转写/听感仍需[集中办理](FAILURE_AND_PERMISSION_AUDIT.zh-CN.md)。

已沿用旧c16菜单/真实长流/主停止/H22/HF/宏及固定视频结果。本轮普通App另已完成文档提取、Python成败和CSV保存、HTML交互/Canvas、本机MCP、真实短模型比较及辅助、预设交换和模板错误恢复。它们不替代未验的管理、目录/真实重排、临时会话、字段交接和新数据完整恢复；精确范围只维护在唯一清单。

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

打开与本候选App相同的工作树：
`/Volumes/CodexProjects/Codex/D-Worktrees/D-RELEASE-FREEZE-01/D.xcworkspace`

选择 **D Nodes / My Mac / Debug**。本机忽略配置`Development/Development.local.xcconfig`使用既有签名身份，资源目录为：
`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261004T041401Z-chat-resume/delivery/resources-with-python`

正常Xcode资源阶段嵌入现有引擎与ChatPython，无需手补App或重装模型。本轮同树普通签名构建通过；没有在锁屏时声称人工点Run/原生验收通过。换机按[开发说明](../Development/README.md)准备资源。**main工作树目前是af生产基线，紧凑控制与记忆导出补丁仍在候选**，不能用main Run冒称上述包的相同代码。

## 集中办理与交付边界

桌面再次锁屏后仅完成可独立的记忆筛选修补、CPU/恢复、签名构建及审计同步。下一次解锁由Lead先补剩余原生；本人只需按[唯一队列](FAILURE_AND_PERMISSION_AUDIT.zh-CN.md)集中处理新聊天组字、Speech/试听和搜索凭据，不重复H22/HF/宏/固定视频。

这是可构建的试用候选与准确停点，**不是完整聊天验收通过、功能冻结或正式发行**。未完条目保留同号，不移至发布后；未强推、改许可证或发布Release。首次使用、无权重分发/依赖封装、升级恢复和渠道责任仍保留。
