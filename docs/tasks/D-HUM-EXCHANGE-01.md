# D-HUM-EXCHANGE-01：哼唱音符交换基础

## 冻结规格 HX1（2026-09-16）

状态：实施中。用户批准按首次发布目标选择并完成下一有限阶段。本包补首发 HUM01 的普通音符试听材料及 MIDI 交换基础；首发完整 HUM 仍需要必要纠错、界面与本人检查。不是发布授权。

- source_base：`a67be67d40da30a0a742d4c109910c0c148b0dea`，`codex/inference-foundation`。
- Lead 集成树：`/Volumes/CodexProjects/Codex/D-Worktrees/D-HUM-EXCHANGE-01`，分支 `codex/d-hum-exchange-01`。
- batch/task：D-HUM-EXCHANGE-01；spec_revision=HX1；contract_revision=HX1。准备提交作为实际 Worker base_sha，完整值写各 request/回执，不自引用。
- run_id：`run-20260916T034259Z`；持久 R=`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-HUM-EXCHANGE-01/run-20260916T034259Z`。
- 原个人 scheme 保留内容、摘要、索引和未暂存状态，起始证据在 R/protection。未接纳歌声候选 c01d47e1fd8f406b35c2f9a4bdf759c6faaa95d9/H22保持不动，本包从已接纳源 schema12 出发，不新增 schema13。

## 目标与非目标

已保留且仍对应当前原声的识别结果，能够通过正式 ProjectStore 服务导出可播放的普通音色 WAV、单轨标准 MIDI。文件可脱离项目读取，包含相同近似音符、间隙和时长；原声/分析/清单不改。服务和文件阶段完成标准是独立解码与存储安全验收，不声称新按钮、真人试听或外部 DAW 全部已通过。

不增加 UI、CLI、backend/provider、模型、依赖、工程/签名修改、录音、推理、全套编辑器、量化、节拍识别、MusicXML 或歌声接纳。后续界面复用既有 AudioTransport；本阶段 WAV 仅确定性合成音符，不声称恢复原音色/人声/力度。源代码新能力没有默认替换现有入口。

## 公共契约

复用 `PitchAnalysisResult.validate()` 与 `PitchInterpretation(result:)`，不得修改识别/五帧解释规则。自由时间为相对选区起点的16k分析样本，不加原音频 startFrame 的静音，不套40ms音乐网格。尾部未覆盖的不足256样本保持静音/空白；不补造音符。限制来自既有 SwiftF0 profile（16ms—120s），不是 Mac 内存或产品永久上限。

1. `public enum PitchMIDIFile { public static func encode(result: PitchAnalysisResult) throws -> Data }`：SMF type0，单轨，PPQ960，tick0 set-tempo 500000us/qn；这只是时间编码，不是识别到120BPM。channel0，velocity80，note-off velocity0，不发program/pan/sustain或假拍号，不需要外部音源。每个样本位置映射为 nearest tick `(sample * 3 + 12) / 25`（准确整数，最大0.5tick=0.260417ms）；绝对位置投影后再求delta。相同tick先note-off后note-on。总时长以sampleCount投影，end-of-track保留首尾休止。空音符明确抛错。标识 ASCII text meta 只说明 D approximate free-time notes; 120 BPM encodes time; velocity 80 is synthetic，不写 UUID、路径、录音、设备或模型信息。正确header/chunk长度、VLQ与大端字段，无running status亦可。重复编码相同结果字节相同。
2. `public enum PitchNotePreview { public static func encodeWAV(result: PitchAnalysisResult) throws -> Data }`：标准RIFF WAVE PCM16 LE mono48000Hz；sampleCount*3帧，精确自由时间。每个音符start/end乘3，音高440*2^((midi-69)/12)。确定性正弦音色，相位每音符从0开始，峰幅0.2，5ms线性入/出（240帧，首末样本0；min(1, local/240, (length-1-local)/240)）。间隙、首尾休止为零；四舍五入为PCM16，无归一化、随机性、播放设备或写文件副作用。空音符明确抛错；输入先完整校验再分配。入口及有界循环检查 Task cancellation（至少每4096输出样本）；完整Data不超过44+120*48000*2。不要吞取消。
3. Lead `ProjectStore.exportPitchMIDI(assetID:documentID:to:)` / `exportPitchNotePreview(assetID:documentID:to:)`：仅允许该文档已接受且未拒绝/过期的结果；读取注册结果并校验摘要、job/source身份；当前audioDraft资产/版本和原音频摘要/格式必须仍匹配。未接受、被拒绝、跨文档、变更来源/项目/分析均失败，不发布。关闭后重开仍可导出合格结果。目标仅绝对fileURL且在项目包之外；不能写回项目内部任意位置。复用同卷临时文件→回读验证→原子不覆盖 ProjectFiles.publishExport；失败不替换原文件，不更新manifest。导出前后检查本项目外部修改及取消；使用已持有项目 actor，不引入新调度层。

## 行为表与验收（Worker 不改）

| 输入/状态 | 结果 |
|---|---|
| A4，休止，C5；选区起点非0 | 两个正确音符，保留相对休止，没有录音前置静音 |
| 相邻不同音/休止分开的同音 | 前音停止先于后音开始；同音重新起音 |
| sampleCount非256倍数 | 总时长保留，未覆盖尾部静音 |
| 无声或每run不足5帧 | 明确无可交换音符，零文件发布 |
| NaN/错误profile/source/hash/count | 抛错，无崩溃、无默认假值 |
| 已保留有效结果/关闭重开 | 两类导出相同语义与字节 |
| 未接受/拒绝/过期/其他文档/损坏原件或分析 | 失败，输入/manifest/目标不改 |
| 目标已有文件/软链接/项目内部路径/已取消 | 拒绝覆盖；无新项目资产或清单修改 |

CPU验收：Worker局部测试，Lead UI package全套相关回归；Lead用Apple AudioToolbox MusicSequenceFileLoadData独立读回MIDI音高、起止、tempo、轨长；AVAudioFile独立读WAV格式/帧数，信号检查音高、静音、包络及幅度。至少普通/首休止/相邻音/重起音/最大120s/无声/损坏/取消；Store原件、结果、清单字节保护和重开/碰撞/错来源。测试原本的跳过单列，不计通过；无需GPU或GUI。公开技术入口：https://midi.org/standard-midi-files-specification ，Apple AudioToolbox本机SDK MusicPlayer.h 与 MusicSequenceFileLoadData 文档。不凭未读取的规范全文宣称完全兼容所有软件。

## 分工与运行

两名真实独立 Worker 可并行：
- MIDI，gpt-5.6-terra / medium：仅新增 `Packages/UI/Sources/DWorkbench/Audio/PitchMIDIFile.swift`、`Packages/UI/Tests/DWorkbenchTests/PitchMIDIFileTests.swift`。
- PREVIEW，gpt-5.6-sol / high：仅新增 `Packages/UI/Sources/DWorkbench/Audio/PitchNotePreview.swift`、`Packages/UI/Tests/DWorkbenchTests/PitchNotePreviewTests.swift`。DSP信号边界/取消理由，非音频模型推理。
- Lead：本规格、ProjectStore.swift以及原有PitchWorkflowTests.swift追加保护测试、独立验收和文档；非实现者另只读检查 Lead 差异。

必读：本规格、AGENTS不可破坏边界、PitchAnalysis.swift、PitchInterpretation.swift；测试风格按PitchInterpretationTests。不要加载全历史。允许 Worker 自主选择局部算法/测试组织，不逐函数代写；不许改其他文件、既有阈值或规格。

每个 Worker 工作树位于D-Worktrees/<task>-<role>；独立branch和索引，base是准备提交。workspace-write network=false；仅自己的工作树、R/<role>/output、R/<role>/tmp可写，共享.git只读。CPU/GPU/GUI：仅局部CPU，禁GPU/GUI/音频设备、模型、安装/网络/配置/钥匙串/提交/递归。输出/编译缓存/临时文件均唯一tmp；Swift语法可用显式swiftc -frontend -parse -module-cache-path <tmp>/modules，不触发SwiftPM嵌套沙箱；完整包测试由Lead串行。若需单独编译使用当前SDK/显式modulecache。

首次仅PRECHECK；Lead核对实际turn_context的model/effort/cwd/sandbox再同链IMPLEMENT。异常权限拒绝先停报；无预先许可旁路。Python仅tokenize.open+内存compile不写目标pyc。每轮15分钟，初交+最多2次原因明确修复，之后一次有界Lead接管；预算不因新会话刷新。每轮先审异常/保护再发返工。Worker停写后交差异/局部测试/异常/进程；Lead显式提交，保留历史合并，组合验收后源固定SHA快进。新任务代码不进入历史歌声候选。

## 恢复与结案

当前：准备；无新模型/本人事项，本人离机，H22仍待集中办理。源个人scheme修改唯一已知差异。R/protection/start.json为起点；请求/可观察路由/轮次/审阅/验证/最终SHA在此追加摘要，日志不入Git。隐藏服务解析、完整Lead token和实际订阅费用unknown。任务完成后提案为HUM有限纠错/试听与MIDI入口接线（需结合H22合并后项目版本），不先启动下一批。
