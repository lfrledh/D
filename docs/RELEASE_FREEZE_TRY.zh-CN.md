# D 开发预览：本轮试用

2026-10-04 · 当前是完整聊天专题的 **S00/S01＋后续功能组合验收候选**。代码、定向CPU/hosting和正常签名构建有对应证据；新包的原生菜单、主停止与新增功能操作尚未验收。旧S00真实长回答/坐标停止证据保留，不重复生成，也不替代新宿主检查。主线已验A仍保留；本页只给当前候选一个启动入口。

## 当前候选唯一验收入口

双击：
`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261003T150039Z-chat-continue/delivery/启动聊天当前验收.command`

启动同目录 **D Chat Product e80fc15e.app**，代码/构建版本 **e80fc15e34eff1b5ad0c27f3010103c1eb1ef10a**。隔离会话仍为 `BC96EF26-C157-4A48-84B4-A54785B1A42E`，复用已有隔离登记，不替换普通D。新聊天布局、共享附件、导入和其他已实施条目均在此包；逐项状态只见[唯一聊天清单](CHAT_FEATURE_LEDGER.zh-CN.md)。复制后签名及四个关键文件核对通过；新包未启动，不能凭构建称可用性通过。

若已有D运行，入口拒绝双开，不替你关窗口。当前旧测试实例 **D Chat Integrated.app / PID63889** 已收到正常退出请求但仍存在；解锁后Lead须先核其项目面板并正常退出，不能直接再开新包。旧包和证据均保留，非推荐入口。

## 解锁后的验收路径

1. 在同一隔离设置打开 `run-20261003T150039Z-chat-continue/gui/Chat-integration.dproject`（相对此任务外盘证据根）。已有Qwen登记不重复；项目列表、会话栏、四分类及窄窗返回由Lead先验。不要改原始长流项目。
2. Quick→文字→聊天，生成时输入区主操作为停止。先用已批准的可控流/短请求检验响应、停止中→已停止、部分回答保留与显式采用继续；不重做三次1024-token长生成。
3. 回答操作区分“新候选”和“按旧参数/seed重现”；缺seed不冒充重现。核验菜单不忙循环、切换/关闭不丢焦点，参数与原回答不被覆盖。
4. 拖入或粘贴小文件，查看预览/顺序/移除；四分类切换保留各自草稿。只使用隔离小夹具，跨项目复制须指向明确实例。原件保留。
5. 外部聊天导入先选会话并预览损失，再显式接受；D会话包和新增成果按备份→独立恢复验证。资料、上下文、记忆、工具和成果在按需检查器内逐项核验，不能以按钮存在判通过。

以上组合原生检查尚未执行，最后桌面观察为锁屏。现有CPU/控制事件、真实网页/MCP/WK证据见清单；不等于真实App操作。旧A备份恢复、冷启动、本人H22与固定视频证据复用；新增聊天宿主组字、本地Speech授权/当前语言资源及试听只在准备好现场后集中办理，不重问旧模型资格。F28受限Python仍未实现，不称完整专题或冻结通过。

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

选择 **D Nodes / My Mac / Debug** 后Run。该树代码与上述App的 `e80fc15e34eff1b5ad0c27f3010103c1eb1ef10a` 一致，之后检查点仅改获准文档；最终文档SHA见当前run的 `lead/continuation-receipt.json`。main仍为已验A `f31dced209855722d2f04cc0fc8c5f6712396120`。本轮正常签名构建通过，复用已有EquatableMacros信任，未跳过宏校验；未在Xcode界面点Run。若需复用验收注册，在Scheme运行环境填写上述 `D_UI_TEST_SESSION`，不修改共享Scheme。先正常退出旧D，不打开内盘空仓库或保护源旧版本。

旧B长流失败与旧S00菜单忙循环/AX迟滞保留；当前已组合修补代码但仍待原生反例关闭。不要把组件/构建通过写成新布局已经验收。

该树忽略的`Development/Development.local.xcconfig`复用已有签名和`run-20261001T162316Z-r4/delivery/resources-progress`，六类固定引擎由正常构建验证、嵌入和签名，未构建后手补provider。仅本轮Swift变更无需重复准备资源；公开干净机器需按[开发说明](../Development/README.md)准备已有依赖/引擎，不能只克隆就推断音视频可运行。引擎未变不代表所有App入口已通过。

## 集中办理与交付边界

[唯一集中清单](FAILURE_AND_PERMISSION_AUDIT.zh-CN.md)中，先由本人解锁，Lead处理旧窗口并完成可独立操作；新聊天组字与本地语音确需本人时集中办理。没有新的HF登录、模型资格或宏信任要求；旧H22和固定视频不重开。

本次最终e80包未启动；自有Worker/构建/CPU进程结束。旧测试App的正常退出尚未完成，终端窗口状态未知；只处理明确拥有的窗口/进程，不以归档代替结束。

普通App门槛通过后按已授权流程接纳main并继续尚未完成的证据；F01–F36始终是同一批范围，未完成项不移至发布后。这是可恢复候选，不是任务结案。没有正式安装包/Release，未改许可证或收费；无权重分发、首次使用/依赖封装/升级恢复/渠道责任仍保留。
