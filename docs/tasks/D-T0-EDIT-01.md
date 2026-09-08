# D-T0-EDIT-01：选段改写与草稿数据组件

规格 1，contract_revision=1，batch_id=D-T0-META-01；源 c808293692eb7be90b7c9de73667c9d7bc327e3a，实际 base_sha 为共同准备提交（派工 request 中完整值）。Lead 维护本文件；状态待预检。run_id=run-v7-initial；证据根 /Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-T0-EDIT-01/run-v7-initial。

## 范围与最小资料

真实价值：文本生成不直接覆盖作者原稿；选段版本、候选比较、接受／拒绝／撤销及草稿字节归档可由工作台复用。当前仅后台服务／数据切片，未接默认 UI，不改变 .dproject v2 或宣称完整 GUI 已交付。必读：本文件、AGENTS 的不变量、docs/MULTI_AGENT_WORKFLOW.zh-CN.md、副作用段、Sources/DInference/Inference{Run,Request,Backend}.swift、现有 DWorkbenchTests 的 Testing 风格；不要加载完整历史／音乐研究／其他模型文档。

只可新增／编辑：
- Packages/UI/Sources/DWorkbench/Text/TextDraft.swift
- Packages/UI/Sources/DWorkbench/Text/TextDraftSession.swift
- Packages/UI/Sources/DWorkbench/Text/TextDraftArchive.swift
- Packages/UI/Tests/DWorkbenchTests/TextDraftSessionTests.swift
- Packages/UI/Tests/DWorkbenchTests/TextDraftArchiveTests.swift

禁止改其他源码、共享 ProjectSession/ProjectStore/ModelLibrary、UI、工程、锁文件、任务单、Git 元数据、源树、D.app、用户数据、模型和旧证据。不递归派工、不下载网络、不重签、不全应用构建。

## 冻结可观察契约

在既有 DWorkbench target 内，Foundation/Observation/DInference 可用；不新增库。公开入口名称和最低语义如下，附属内部类型／私有实现自行组织，不能改行为后只改测试。

- TextDraftDocument：Codable/Sendable/Equatable，id UUID、revision UUID、text String；新建可指定 id/revision 以可重复测试，正常默认新 UUID。任何实际编辑／接受／撤销产生新 revision，即使之后恢复旧文字也不能复用旧 revision；相同文本赋值可不改版本。最大 UTF-8 1 MiB，空稿可保存。
- TextRewriteSelection：不可变文稿 id/revision、UTF-16 location/length 与捕获的选段文本。TextDraftSession.selection(inUTF16: NSRange) throws 创建；非空，负值/溢出/越界/半 surrogate/组合字符内部均拒绝。端点必须是 Swift Character 边界，不能仅按字节或 Unicode scalar 处理。涵盖中文、ZWJ emoji、组合重音、旗帜。
- @MainActor @Observable TextDraftSession：init(document: TextDraftDocument, engine: any InferenceEngine, backendID: String)；公开只读 document、candidate、partialText、isRunning、isCancelling、errorMessage。editText(_:) throws；requestRewrite(selection:instruction:model:maxTokens:temperature:topP:) async throws；cancel() async；acceptCandidate() throws；rejectCandidate()；undoAcceptedRewrite() throws。推理参数默认与 TextRequest 一致。模型显式 ModelReference，复用传入现有引擎，不新建 runtime/backend、不触碰权重。
- requestRewrite 捕获选段／指令／模型／参数并构造真实 TextRequest，经 engine.submit 调用唯一通路。实际提示格式为：Rewrite the selected passage according to the instruction. Return only the replacement text. 后接明确 Instruction 和 Selected passage 段；把确实提交的 InferenceRequest 留在候选。无音乐规划能力承诺。只处理 textDelta，非文字输出是明确错误；最多 1 MiB 生成文本，空结果不能形成可接受候选。
- 同一 session 只一个运行；提交 await 前占用 isRunning，直到事件流结束并 await outcome 后才释放。保留取消意图覆盖 submit 尚未返回的窗口；cancel 在 handle 可用后请求取消；取消和错误必须等 outcome 清理完成，不把单纯按钮状态当停止。消费者任务取消也要取消并等原 run，不丢失后端所有权。取消／失败的片段不成为候选。不要因取消本服务而 shutdown 别人的共享引擎。
- 原稿可在生成期间编辑；迟到候选不得改稿。候选记录 runID、原稿版本、原始选段、replacement、实际 request/result metadata；只有文稿 id/revision/原始范围内容仍完全匹配才可接受，否则保留候选用于比较但明确不可接受。可提供 canAcceptCandidate 便于调用方。开始新运行或 reject 可清除旧候选；接受只替换所选范围，其他文本原样保留，接受后不能再接受同一个候选。
- 撤销仅当前最后一次接受且稿件未在其后编辑时可用，恢复接受前原文并赋新 revision。若其后人工改稿，明确拒绝旧撤销，不能覆盖人工工作。首版不承诺跨关闭保存撤销栈或待选候选；归档仅保存已存在的原稿／接受后的稿件，UI 后续必须提示未处理候选，不假装完整编辑器完成。
- TextDraftArchive.encode(_ document) throws -> Data，decode(_ data) throws -> TextDraftDocument：显式 schema_version=1 的 JSON 封装，非 bool 整数版本，原 Unicode 文本与 ID/版本不变；拒绝未知版本、损坏、超预算数据。总输入上限 8 MiB（JSON 转义开销），解码后文本 1 MiB。仅 Data 编解码，不扫描/迁移/写真实项目。测试可在自有 tmp 保存 bytes 后重新读取，证明序列化恢复；生产文件事务／UI 接线是后续明确工作，不冒充已实现安全文件保存。

## 验收与资源

至少验证：普通替换、无旁及文本、拒绝不改稿、接受后不能重用、撤销和人工编辑后的撤销拒绝；所有 Unicode 边界与溢出、版本变化后迟到结果不能接受；submit 前后／流中取消、取消清理 gate 未开放时仍 busy 且拒绝再提交；失败／非文字／空／超限输出不形成候选；实际 request 值不从后变 UI 重读；归档原稿与接受后重开、未知/bool版本/坏 JSON/上限。用可控 CPU fake engine/run 或 DRuntime fixture，gate 等待有界，不靠长 sleep。不调用真实模型或 GUI。

模型请求 gpt-5.6-terra / medium。仅本工作树和该 run 的 worker-output、tmp 可写；输出/caches/temp 全归此 run，TMPDIR、D_TEST_TEMP_DIR、PYTHONDONTWRITEBYTECODE、CLANG_MODULE_CACHE_PATH 由 Lead 固定。允许局部 swift test --package-path Packages/UI --scratch-path <run>/tmp/build --cache-path <run>/tmp/spm-cache --config-path <run>/tmp/spm-config --security-path <run>/tmp/spm-security --skip-update --filter 'TextDraft'；只依赖本地 package，不下载。不运行已有 ModelLibrary 网络夹具。Python 检查只能内存 compile，不 py_compile。若 SwiftPM 内层 sandbox/工具默认目录拒绝，暂停该检查并报告，不自行加 --disable-sandbox 或提权；Lead 可承担定向编译。只预先允许缓存已由任务变量指向的同一路径；不创造替代目录。

先仅预检并回传定位／理解，Lead 发 IMPLEMENT 后实施。初交＋最多两轮普通修复，每轮15分钟；达到预算可一次 Lead 接管仍失败停。改规格先问 Lead。不 commit、不改任务单。回传文件、测试命令／数量／失败与限制、所有权限或工具异常、自有进程结束状态到 worker-output。Lead 每轮查异常再派工。本任务与 META 无写入重叠、无代码依赖。

## 初交审核与修订 2（冻结行为不变；2026-09-08）

初交文件由 Terra/medium 完成，Lead 尚未改实现。Worker 按调度未编译；Lead 在固定初交提交上串行验证，结果见 run-v7-initial/lead-initial-tests.json/log。T0 初交测试有 Swift await 语法错误；META 初交测试有真实版本接受缺陷及未实际变更输入的负例夹具。测试代码缺陷、产品实现和环境分别归因。

Lead 已检查初次执行事件：修改只在允许文件和自有输出，静态命令退出0，未观察到越界/权限拒绝/网络/安装；子 CLI 结束并交回写入权。Lead 新增只读验收夹具 Packages/UI/Tests/DWorkbenchTests/TextDraftLeadContractTests.swift；不扩大 Worker 修改清单，Worker 不可修改该文件。反例来自原契约，新增的是真实覆盖而非新的产品需求。修复1后仍最多余一次普通修复；不换编号重置。

Lead 帮助为语义说明、反例和测试，未代写实现；具体修复消息/请求SHA/模型写根在 repair-1-prompt.txt/request.json。Swift package 测试仍由 Lead 串行承担；Worker 不得把未执行测试报为通过。

## 修订 3：消费者在 outcome 等待期间取消（2026-09-08）

repair-1 的18方法已通过；Lead 非实现者代码审核发现，流结束后等待 outcome 期间没有消费者取消处理。原契约要求消费者取消到达原 run 并等待清理，不能只在最后丢弃候选。新增 Lead 只读反例：先进入 outcome gate，取消消费者，确认在手动释放清理 gate 前后端收到一次取消；即使断言失败也释放自有 gate。它覆盖既有要求，不改变产品范围，也不声称真实 MLX 生命周期已重测。

修复2为最后普通修复，仅允许 TextDraftSession.swift 及 TextDraftSessionTests.swift。修复需以每运行身份隔离迟到取消，仍待权威 outcome 结束、不 shutdown 引擎、不暴露新公共 API。Lead 契约测试不可修改。前轮执行结束；事件和保护核对未见越界／拒绝。

## 候选验收（2026-09-08，待批次接纳）

选段版本/Unicode、接受/拒绝/撤销、真实 InferenceEngine 桥接及草稿 Data 往返；取消 outcome 边界反例先失败后通过。 固定代码/测试 `1399502c6593678a71b91e6b726217b54c47d1b0`，Lead 串行定向测试 20 方法通过，证据 `/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-T0-EDIT-01/run-v7-initial/lead-repair-2-tests.json` 及同名 log。真实模型/GUI/生产文件事务未执行，不默认替换现有界面。本记录提交仅追加文档，候选最终 SHA 见外部 final-candidate-review.json，不声称在后来的文档提交上重测。

Terra 初步实现及两轮修复；Lead 规格、独立反例和生产代码非实现者审查，未代写产品实现。 任务修订3/契约1，初次＋两轮修复额度已消耗，全部 CLI 已结束并交回写入权。请求及全部可见 turn_context 为 gpt-5.6-terra / medium、workspace-write、网络关闭、独立任务目录及自有输出/tmp；共享 Git 写入由 Lead 完成。隐藏服务解析未知。执行异常及允许路径已复核，无未处理权限/来源事件；没有全系统写锁或全系统进程检查。

原始源 c808293692eb7be90b7c9de73667c9d7bc327e3a，共同准备 e4e39b404a9d0d83c92bae285b12b961976de438。实际每轮执行 SHA、模型/写根、终止和用量见 final-candidate-review.json；逐 CLI 终态用量仅记一次，缓存输入已含于输入，不把累计快照反复相加。完整 Lead 归因/订阅费用 unknown。下一步仅 Lead 保留历史合入 D-T0-META-01，验证组合和源入口；候选不是默认 UI 已启用。

## 批次本地接纳（2026-09-08）

已随 [D-T0-META-01](D-T0-META-01.md) 保留历史合并并快进源工作分支，受测组合 `c3197ad9cdade3d486a4153418cacc39af85bc81`；隔离组合工作台117/核心17通过，源入口工作台117通过。代码未因接纳改变；本段仅文档结案。未推送、无活跃本任务CLI、工作树及证据保留；产品/真实验证限制见上，不把组件验收改为完整GUI交付。
