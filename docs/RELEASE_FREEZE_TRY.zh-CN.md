# D 开发预览：本轮试用

2026-10-03 · A独立稳定性修补已验并在main；**B聊天有长回答中止缺陷，留在审计候选，不接纳main**。本页唯一推荐稳定App代码 **8511718c472e788a8dcfc088eea0fde9dad050b3**，main `f31dced209855722d2f04cc0fc8c5f6712396120`只多记录。普通沙盒备份/独立恢复/冷重开与按需模型就绪通过；不是整体功能冻结或正式发行。

## 唯一推荐启动入口

双击：
`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261003T035843Z-stabilize-chat/delivery/a-combined/启动稳定性验收.command`

启动同目录 **D Stabilize A.app**，使用隔离9F276A92会话，不替换普通D。若已有D运行，入口拒绝重复启动，不关闭旧App。

## 本轮可试路径

1. Quick编辑一份草稿，或打开命名项目编辑Canvas，使用小测试素材。
2. 顶栏“项目文件”→“创建手动备份”，选择全新目标；不会覆盖已有包。
3. “恢复手动备份”→选备份→选新的.dproject→“打开已恢复项目”。Quick草稿存在时会显示“本项目”所属位置；可切回独立全局Quick。
4. 退出后通过文件→打开项目重开，草稿与媒体仍在。不要移动真实原件来测试；本轮只移动合成夹具。

冷启动会按需检查所选模型与图的实际依赖，无需先打开完整资料库。登记、核验、待转换、推理资源准入仍不同；没有进行新的模型推理。真实NAS未验，错误会保留操作/errno和已发布状态。

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

## 当前候选的同树 Xcode Run（与推荐稳定App分开）

打开：
`/Volumes/CodexProjects/Codex/D-Worktrees/D-RELEASE-FREEZE-01/D.xcworkspace`

选择 **D Nodes / My Mac / Debug** 后Run。**该树现为B聊天候选，已不是上方A稳定App的代码**；B原生受测 `7754a2b70f3e761ef30b45fe3c5ba76bf12b817a`，后续仅文档。本轮普通签名构建通过且本人已信任固定EquatableMacros，未跳过宏校验；未在Xcode界面点击Run。先正常退出自己打开的D再Run，不并行启动相同bundle。不要打开内盘空仓库或保护源旧版本。

B原生App/启动器保留在同一run的`delivery/b-chat/D Chat Candidate.app`和`启动D聊天试用.command`，仅供定位审计，不是第二个推荐稳定入口。已实际验短多轮TXT+PNG、编辑/再生成分支、系统预设、存素材/送工作流、导出及聊天独立备份冷重开；长回答两次中止，原生停止尚未验证通过，因此不能据此发布或接纳。恢复包列表曾灰色，但文件→打开项目→Cmd+Shift+G输入完整.dproject路径可打开；原因待定位。详细证据/未验项见[当前行动](CURRENT_ACTIONS.zh-CN.md)及[任务记录](tasks/D-RELEASE-FREEZE-01.md)。

该树忽略的`Development/Development.local.xcconfig`复用已有签名和`run-20261001T162316Z-r4/delivery/resources-progress`，六类固定引擎由正常构建验证、嵌入和签名，未构建后手补provider。仅本轮Swift变更无需重复准备资源；公开干净机器需按[开发说明](../Development/README.md)准备已有依赖/引擎，不能只克隆就推断音视频可运行。引擎未变不代表所有App入口已通过。

## 待集中办理与停止边界

[唯一集中清单](FAILURE_AND_PERMISSION_AUDIT.zh-CN.md)现无新增账号/输入法/设备/试听要求。H22本人已接受当前候选窗行为，并确认鼠标不再闪回、组字可用；不重复复验。A手动备份与冷启就绪已验，Q固定自然视频本人已验；B长流与文件列表问题需工程处理，不是待你授权登录。

测试用App/自有Finder窗口已正常关闭。工具限制Terminal控制，若还有标题对应“启动D聊天试用.command”等已完成窗口，可由本人随时关闭；其他窗口不动。

main按获准开发门槛正常推进，个人源与旧App/项目/模型保留。没有正式安装包或Release，未改许可证/收费。Pitch内部评估ONNX仍是无权重分发责任；首次使用/依赖/升级恢复/渠道等未关闭。本轮停在用户试用与冻结判断，不自动扩张下一阶段。
