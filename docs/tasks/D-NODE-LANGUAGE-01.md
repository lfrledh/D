# D-NODE-LANGUAGE-01：通用节点语言与四模态试用

状态：实施中，规格 r1 / language-v1，2026-09-27 JST。用户明确批准 S0—S4 连续实施；不公开发布、不推进 main、不自动接纳 AP1/CORE/I2V。

## 基线与证据

- 源：`codex/inference-foundation`，`130603d23a4da81ba2a9852766f3589695ec9468`。
- Lead：外盘 `D-Worktrees/D-NODE-LANGUAGE-01`，`codex/d-node-language-01`。源工作文件不用于实现。
- R：`D-Development/AgentTrials/D-NODE-LANGUAGE-01/run-20260926T150929Z/`（相对 `/Volumes/CodexProjects/Codex/`）。用户交接 12 个文件全部摘要核对并保留在 R/attachments；其中 01/02/03 是范围、节点和 A01—A36 验收要求，不是通过记录。
- 源个人 scheme 仍未暂存，SHA256 `ca3635d88aa5a15397b90e528667c66c0e6db7e596176e885c79d194b544206c`；索引 `9c76916bdc97c2d4298cefe64e0b0fae3380573e`。保护副本和完整差异在 R/evidence/baseline.json。
- 本轮受测/最终版本尚未产生。旧集中验收以原任务回执为准，不算本轮通过。

## 范围与责任

N01—N18、G01—G03、V01、M01—M09 均交付有界可配置版本。四套可编辑样例 E01 数据控制、E02 图文候选、E03 哼唱与和声、E04 四模态素材。至少两个真实版本化工具、同计划无画布入口、检查点/局部运行、普通 App 与 Xcode Run。

共享契约、Store 版本、Controller/解释器、运行准入、App/工程装配由 Lead 统一协调。Worker只改冻结的局部文件；不各造模型库/Store/调度器。旧 M0 操作 ID、确认等待、seed/count、项目和资产保护保留；未选分支不准备模型。用户内容与当前参数/实际运行快照分开，媒体值按固定版本引用，不使用 Any 或 eval。

音乐 M04 是已有 SwiftF0+分段，不是 Basic Pitch；M09 必须传入真实25Hz音符条件；V01仅Wan T2V。既有精度不改。Pitch当前包含399114字节内部评估权重的耦合按附件§7保留、明确披露，不能据此分发或宣称无权重包。

## 执行与预算

按 C2026-09-23.1，写Worker独立外盘工作树/分支，受限 CLI workspace-write，网络关闭，仅自身树及本run output/tmp/cache写入；Git共享管理目录不授写。预检后核对客户端 turn_context，再 IMPLEMENT；共享文件由Lead单一所有。读源码用只读原生调查，不能当作写隔离证明。

每个新有限工作包初交+最多两轮针对修复，之后最多一次有界Lead接管；旧任务预算不刷新。每轮修改授权前先查异常/保护。默认15分钟，确需较长任务事先写明。重构建/GPU/GUI串行，CPU预算也受约束。无字节码Python编译使用tokenize.open+compile，不exec目标；所有测试缓存落指定目录。敏感/未知越界立即停相关任务。

## PACK r1：开发资源可重建入口

请求 `gpt-5.6-sol / high`，本机可观察设置核对后执行。目标：固定清单的本地资源准备与构建前复制；无安装、下载、重签、全App构建或GUI权限。

允许文件仅：`scripts/prepare-development-resources.py`、`scripts/embed-development-resources.py`、`scripts/tests/test_development_resources.py`。工程phase、签名设置和现有build脚本由Lead接线，Worker不得修改。

输入显式本地 JSON 配置，schemaVersion=1，engines 为四项精确键 `AudioEngine.dengine` / `MRT2MusicEngine.dengine` / `VideoEngine.dengine` / `PitchEngine.dengine`，值为本机已准备引擎目录绝对路径。准备命令 `--config PATH --output PATH`：只读输入引擎，校验引擎 manifest/路径不逃逸、不得与输入重叠；产生独立资源集和带逐文件摘要的开发资源清单。相同输入重复调用可验证后复用，未知或不同现有输出拒绝，不清目录。此工具只暂存已准备引擎，不自行执行准备器/下载/安装。

复制命令 `--prepared PATH --destination PATH`：只把四引擎复制到新构建包的 Resources/Engines，复制前完整验证清单，路径安全、限制文件数量/总量。相同内容重用；冲突拒绝不覆盖未知文件；不得改输入、签名、系统或用户数据。跨文件失败报告具体位置和未完成状态，不宣称原子四包。跟随引擎内部相对symlink仅当目标仍在本引擎中（保留链接），外部或绝对链接拒绝。允许Python.framework内部链接。路径含空格/Unicode正确；安全参数，不shell执行。

CPU临时夹具：四引擎、重复准备、缺一项、坏manifest、清单hash冲突、源/destination重叠、符号链接逃逸、重复embed不改文件、目标已有陌生引擎拒绝。真正引擎+构建签名前接线由Lead另验。正常退出0；输入/校验/写入失败2，并保留可诊断错误；stdout异常不能误报成功。输出报告与原文件保护独立。仅标准库，无第三方依赖。Worker提供差异/结果，由Lead提交，不编辑本规格。

## 验收与恢复

A01—A36逐项记录 CPU/hosting、模型、GUI、本人录音/试听，不把旧结果、CLI或编译冒充新的四模态画布闭环。GUI与模型资源默认Lead管理，无需再次问空闲。新的本人操作/锁屏阻塞入集中清单，继续独立工作。

S0已核实外盘/源/索引/无已知执行进程，既有源构建App以全新固定隔离UUID启动，实际看见空项目选择页，然后正常退出；只证明基线可启动，不证明新增节点。受限CLI旧可执行路径失效，当前实际入口为 ChatGPT.app 内 codex-cli/CodexCLI.app；需本次预检元数据确认。桌面工作树工具绑定内盘空仓库导致指定SHA无效，未改源；改用已授权真实外盘 Git 创建隔离树，未动源checkout。

下一动作：核定值/控制/存储接口，派限定实现，串行组合验收。当前没有正式产品验收通过；不得提前接入源或称阶段完成。
