# D 开发预览：本轮试用

2026-10-03 · 当前是完整聊天专题的 **S00 验收候选**，尚未完成普通 App 长回答、停止和项目列表选择。已正常签名构建，不表示本轮聊天全范围或功能冻结通过。主线已验 A 仍保留；本页只给当前候选一个启动入口。

## 当前候选唯一验收入口

双击：
`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261003T115108Z-chat-product/delivery/s00/启动聊天收口验收.command`

启动同目录 **D Chat Product S00.app**，隔离会话 `BC96EF26-C157-4A48-84B4-A54785B1A42E`，不替换普通 D。若已有 D 运行，入口拒绝重复启动，不关闭旧 App。代码/构建版本 **457cb9a04178f6a9f01a41bd84607119a158d5c7**；之后 W 候选只修改记录。新布局仍在独立树，**未包含在此包**。

## 解锁后的验收路径

1. 使用隔离项目，登记已下载的 Qwen3.5-9B Q4；不重复下载、宏信任或账号授权。
2. Quick→文字→聊天，复用旧长回答输入与完整上下文，检查是否正常结束，不能把输出上限截断与消费失败混同。
3. 再做一次生成中停止，检查已收到正文保留、状态真实结束及下一任务可用。
4. 回答菜单区分“新候选”和“按旧参数/seed重现”；旧记录缺seed时明确拒绝精确重现。新候选不会覆盖原回答。
5. 用文件面板直接在列表选择测试 `.dproject`，正常重开；不以完整路径绕过代替列表选择通过。

以上本轮尚未原生执行，当前阻塞为锁屏。旧 A 备份恢复、冷启动、本人 H22 和固定视频证据复用；不为此重复全模型测试。不要移动真实原件做故障测试。

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

打开：
`/Volumes/CodexProjects/Codex/D-Worktrees/D-RELEASE-FREEZE-01/D.xcworkspace`

选择 **D Nodes / My Mac / Debug** 后 Run。该树为 S00 候选，代码与上述 App 的 `457cb9a0…`一致，后续仅记录变化；main仍为已验A `f31dced209855722d2f04cc0fc8c5f6712396120`。本轮普通签名构建通过，复用本人已有的 EquatableMacros 信任，未跳过宏校验；未在 Xcode 界面点击 Run。先正常退出自己打开的 D，再 Run；不要打开内盘空仓库或保护源旧版本。

旧 B 的长流失败、原生部分通过及文件列表限制保留在原任务记录，不追改为 S00 已验。S01 独立布局候选即使组件通过，也不冒充这个 App 已包含或通过新布局。

该树忽略的`Development/Development.local.xcconfig`复用已有签名和`run-20261001T162316Z-r4/delivery/resources-progress`，六类固定引擎由正常构建验证、嵌入和签名，未构建后手补provider。仅本轮Swift变更无需重复准备资源；公开干净机器需按[开发说明](../Development/README.md)准备已有依赖/引擎，不能只克隆就推断音视频可运行。引擎未变不代表所有App入口已通过。

## 集中办理与交付边界

[唯一集中清单](FAILURE_AND_PERMISSION_AUDIT.zh-CN.md)中，当前只需 H32 解锁以执行 S00 普通 App 门槛，已询问一次。没有新增登录、设备或模型资格要求。H22、宏信任及固定视频本人检查已经通过，不重复办理。

本轮未启动新的前台 App，所有自有构建/CPU进程结束。旧测试终端是否仍可见未知，不通过归档或隐藏窗口声称已关闭。

S00 门槛通过后才接纳 main 并继续新存储/工具生产接线；F01–F36 是同一批批准范围，未完成项不改为发布后。稳定性、聊天全范围、功能冻结和正式发行是不同状态。没有正式安装包/Release，未改许可证或收费；无权重分发、首次使用/依赖封装/升级恢复/渠道等责任仍保留。
