# D-C01a-RESULT-01：单次 UI 验收结果的离线完整性汇总

状态：规格冻结，待本任务 Worker 定位确认后实施。规格修订 1；2026-09-07；Lead 单一维护。用户授权 v5：一个工作包、一个 Worker，最多两轮修复，条件内允许一次明确缺陷的 Lead 接管；验收后可本地快进集成，禁止 push。不是完整 UI 运行器或 D-C01a 整阶段验收。

## 目标、基线和范围

价值：为之后一次完整八项 UI 验收提供机器可判定的结果读取和证据索引，避免把“分轮通过”“七过一跳”记成一次完整通过。当前确有这个缺口；已有脚本只导出 MLX 总数摘要，UI 历史仍按分轮记录。

- 源：`/Volumes/CodexProjects/Codex/D`，codex/inference-foundation，`c14f892cacd69ce909e368c03db9b69c7dac1db8`。前序 DIAG-01 v4 已集成、复验、结案，回执与本基线一致。
- 工作树：`/Volumes/CodexProjects/Codex/D-Worktrees/D-C01a-RESULT-01`，分支 codex/d-c01a-result-01；与源共享 common Git，但工作文件和 index 独立。准备提交是执行基线，完整 SHA 随派工消息和 request JSON 给出。
- run：`run-20260907T125732Z`；持久证据 `/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-C01a-RESULT-01/run-20260907T125732Z`。Worker 额外写根仅本 run 的 worker-output、tmp；网络关闭，排除系统 TMPDIR 和通用 /tmp。
- Worker 只新增／修改 `scripts/summarize-ui-results.py`、`scripts/tests/test_summarize_ui_results.py`。只能使用标准库、Python 3.9；可在该测试文件内构造小夹具。不得改计划、已给夹具、本文、旧诊断脚本或全局文档。
- Lead 准备文件：本文、`scripts/plans/ui-acceptance-v1.json`、`scripts/tests/fixtures/ui-results/observed-two-passed.json` 及同目录 README.md；均为冻结输入。后续 Lead 可更新本文、CURRENT_ACTIONS、DELIVERY_AND_MODEL_BUDGET 作最小结案。
- 禁区：所有 Swift／UI／推理代码、工程／签名／依赖／构建脚本、源个人 scheme、原 app、模型、原 xcresult／历史证据、Git 元数据、全局配置。禁止构建、GUI、GPU、真实生成、网络下载、钥匙串／TCC、递归派工和推送。

## 四类关键歧义与资料

1. 需求已定：只判断一个明确 run/attempt，不跨轮拼接；完整通过要求预期 ID 全部一次 Passed，其他状态不通过。摘要工具自身成功与 UI 验收通过分开。
2. 接口已定：CLI 输入明确计划＋单 attempt 描述，读取该 attempt 指向的原生 tests JSON 导出；本轮不调用 xcresulttool、不读取或修改 xcresult 内部数据库。计划固定当前 DUITests.swift 八个方法及来源 SHA。
3. 平台已核实：本机 xcresulttool 的 `get test-results tests --schema-version 0.1.0 --path BUNDLE` 是只读导出；Test Case 的 nodeIdentifier 为 `DUITests/test…()`，不是计数或 name。测试下可有 Runtime Warning／Failure Message 等非测试子节点。官方本机 schema 在 run/inputs/xcresult-tests-schema-0.1.0.json；脱敏的真实两项通过导出在冻结夹具。无需猜格式或读全项目历史。
4. 验证已定：真实旧第 5 轮为六过两失败；第 6 轮只有两项通过，对八项计划缺六项。本轮读取它们不能重新宣布 GUI 已通过。Lead 会独立核对这些原始导出和代表性反例。

Worker 最小阅读：本文、AGENTS.md 的范围／质量规则、冻结计划及夹具 README/JSON；已知输出错误处理可参考 `scripts/diagnose-app.py` 的 main（只读）。当前项目状态见 CURRENT_ACTIONS 的 D-C01a 段；不加载全部历史／ADR。类／函数组织、内部算法和测试组织由 Worker 决定，Lead 不逐函数指定实现。

## 输入契约 v1

CLI：`python3 -B scripts/summarize-ui-results.py --plan PLAN.json --attempt ATTEMPT.json --report NEW.json`。三个参数必须显式给出；单个 attempt 对象，不支持列表、合并、自动选最新或扫描父目录。成功写出报告时 stdout 保持空，退出状态如下；自身错误可 best-effort 写 stderr，不把无法写 stderr 变成成功。

所有输入是标准 JSON，重复对象键／NaN／Infinity／损坏 JSON 为输入错误。版本和 revision 为整数（不接受 bool）。原生额外元数据允许保留／忽略，但未知节点类型不得悄悄丢弃后报绿。

计划按冻结文件：schema_version=1，非空 plan_id，正整数 plan_revision，target=`DUITests`，非空且不重复的 expected_test_ids 字符串列表，source 记录源码位置／版本／SHA（作为声明来源，不动态扫描 Swift）。本轮默认完整八项；工具可读取同结构显式给定的小计划以测试，不修改冻结计划来过验收。

单 attempt 示例（真实 hashes 由调用方填入）：

```json
{
  "schema_version": 1,
  "run_id": "ui-validation-20260907",
  "attempt_id": "attempt-6",
  "plan_id": "D-UI-complete",
  "plan_revision": 1,
  "plan_sha256": "64 lowercase hex characters",
  "execution_state": "completed",
  "reason": "Historical run; offline review only",
  "evidence": {
    "format": "xcresulttool.test-results.tests",
    "schema_version": "0.1.0",
    "tests_path": "UITests-6.tests.json",
    "tests_sha256": "64 lowercase hex characters",
    "source_xcresult": "/explicit/location/UITests-6.xcresult"
  }
}
```

- run_id／attempt_id 为非空字符串。plan_id、revision、plan_sha256 必须与显式计划的原始字节一致；不匹配为工具错误，不按新版本猜测。tests_path 是绝对路径或相对于 attempt 文件目录；必须读取其原始字节并校验 tests_sha256 后解析。
- source_xcresult 为非空绝对 .xcresult 路径，只记录、不打开；报告标为调用方声明来源、未独立认证。导出字节 SHA 证明本次处理的是哪些输入，不证明上游调用方没有伪造或混搭数据。
- execution_state 只接受 completed／not_started／tool_error。后两者必须 reason 非空且 evidence=null；它们是上游运行状态，汇总工具可正常报告，不能冒充“测试失败”或解析错误。completed 必须 evidence 对象与上述格式版本，不接受多个 evidence／多个 attempts。
- 原生 tests 顶层必须有 devices、testPlanConfigurations、testNodes 数组。本轮只支持一个 device、一个 configuration（其中 deviceId／configurationId 必须非空字符串）；多设备／多配置及 Repetition、Test Case Run、Arguments 的重试／参数化结构明确拒绝为不支持，不能折叠结果。
- 允许容器 Test Plan、UI test bundle、Test Suite；Test Case 必须处在名为 DUITests 的 UI test bundle 中；用 nodeIdentifier 与计划精确匹配，不按 name 猜、不截短方法名。重复／未知 ID 为工具错误。空 testNodes 是可读但缺项，不凭空断言未启动。
- 节点必须是字典，nodeType／name 非空字符串；children 若存在必须是列表。Test Case 的 result 必须为 Passed／Failed／Skipped／Expected Failure／unknown；缺失或其他值为格式错误。Test Case 不能嵌套其他测试或容器；其非测试注释子树允许 Failure Message、Runtime Warning、Source Code Reference、Attachment、Expression、Test Value。注释不计入测试数；Passed 下出现 Failure Message 属于矛盾证据，工具错误。
- 容器 result 若有也必须来自上述枚举；明确 Failed／Expected Failure／Skipped／unknown 会阻止整次 PASS（分别参与下述 FAIL／INCOMPLETE／UNKNOWN 判定），不覆盖子测试原值；缺容器 result 不据此否定已完整观察的测试结果。未知节点类型拒绝，不吞数据。

## 输出、状态和文件保护

JSON 报告必有 schema_version=1、tool_status=OK/ERROR、acceptance=PASS/FAIL/INCOMPLETE/UNKNOWN、run_id／attempt_id／execution_state（无法取得为 null）、plan 身份、tests、counts、issues、evidence。issues 为带 code 和 reason 的列表；evidence 记录计划、attempt、tests 导出的解析后路径和 SHA，以及声明的原 xcresult、格式版本；未知路径／hash 留 null，不伪造。

tests 按计划顺序，每条 test_id、status、reason、evidence_pointer（原生 JSON Pointer；非观察结果为 null）。status 为 PASSED／FAILED／SKIPPED／EXPECTED_FAILURE／UNKNOWN／MISSING／NOT_STARTED。有效输入缺失的预期 ID 为 MISSING；not_started 全部 NOT_STARTED；上游 tool_error 全部 UNKNOWN。无法可靠解析整个导出时不得把未解析的测试冒充 MISSING，使用 UNKNOWN 并令 tool_status=ERROR。计划无法读取时 tests=null、counts=null，不以空列表伪装有效零项计划。

- 退出 0：tool_status=OK，只有 completed 且计划全部一次 PASSED、容器无非通过结果时 acceptance=PASS。
- 退出 1：工具成功产生非通过诊断。已观察 Failed／Expected Failure（含容器）优先 FAIL；否则显式 unknown 或上游 tool_error 为 UNKNOWN；否则跳过／缺项／未启动为 INCOMPLETE。保留各项原始状态，不跨 attempt 选胜出者。
- 退出 2：参数／读取／解析／格式／关联／SHA／重复或未知 ID／不支持结构／报告写入错误。能安全写报告时 tool_status=ERROR、acceptance=UNKNOWN、issues 指明原因；写出错误报告不等于验收通过。输出目录不存在、目标已存在或不可写同样退出 2。
- counts 是上述七种状态的精确计数（固定大写键），不是上游 summary 通过总数。报告来源索引不复制整段失败 UI 树或大附件。
- 只新建显式报告，不覆盖既有路径／输入，包括软链接、硬链接和悬空输出软链接。拒绝在任何解析后的 .xcresult 目录内部写报告。父目录须已存在，不创建任意父目录；从源文件只读。若新报告写入失败可保留该不完整新文件，但必须退出 2、不能记成功；不删除输入或已有文件。不启动任何外部命令，正常调用不依赖 stdout。

## 固定验收与停止条件

Worker 运行本文件对应的 unittest 和必要 AST／diff 检查；不运行整个应用测试。必须覆盖：八过；七过一跳；失败／预期失败／unknown；缺项与空结果；明确未启动／上游工具错误；两份互补尝试分别仍不完整且不能批量合并；重复／未知 ID；计划 id/revision/hash／导出 hash／格式版本错误；损坏、重复键和非标准 JSON；缺 result／坏 children／不支持重试或多设备；Passed 下的失败消息和容器失败；输入／输出含空格、非 ASCII；报告存在／输入别名／悬空软链／xcresult 内部／缺父目录保护。至少关键正常与拒绝案例调用真实 CLI 并等待退出，输出/输入摘要保护有断言。

Lead 独立复核整个差异和需求反例，再用既有真实第 5／6 轮原始导出离线运行；历史事实预期分别 FAIL(6 PASSED+2 FAILED) 和 INCOMPLETE(2 PASSED+6 MISSING)。夹具通过不算实际 GUI 运行通过。测试计划 ID 与源码八个方法对应由 Lead 准备验证，Worker 不改它。

初次只做身份／理解预检：确认 task/revision、cwd/root/common Git/index、HEAD／branch、允许文件、所需验收和会改变实现的未决问题；结束，不写实现。Lead 核对实际 CLI runtime 的 Terra/medium 与受限权限后，在同一链路发 IMPLEMENT。目录／权限／基线／来源／数据保护问题立即停；普通交付后最多两轮针对性修复，每轮给反例与期望。初次和修复每轮限 15 分钟；超时由 Lead 检查自有进程并报告，不无限等待。

Worker 不 commit、不改本文，回传实际改动、测试方法／数量／结果、未覆盖项、自己的进程状态与证据位置到 worker-output。遇到规格冲突先报告；本轮无新增 Reviewer，Lead 自己复核。关键歧义已解决但一个局部明确缺陷仍存在时可按 v5 接管一次并完整复验；根因不明、越界或仍阻塞则停止。

## 实现、审核与恢复记录

Lead 准备了版本化八项计划、本机 schema 和脱敏真实小夹具，解决格式与判定歧义；尚未写实现。源个人 scheme 当前差异／SHA／索引及保护副本见 preparation.json，不能假定未来不变。CLI 版本 0.153.4，与前一任务相同，复用已验证调用方式；新任务的实际 runtime 仍须单次定位核验。实现与模型表现需和规格质量分别记录，不把本任务当作与 DIAG-01 的严格 A/B 实验。

### 初次交付与修复 1（规格修订 2，原契约不变）

单次定位预检 27.871 秒；执行基线 `07d2d27c116fad2e6355fd77081de124e3215d55`。独立 CLI 线程 `01a07bf6-6775-7cf2-8cd0-d5e88340655e` 的预检与实现均记录 gpt-5.6-terra / medium、指定外盘 cwd、workspace-write、仅两个额外输出/tmp 根、网络关闭；gates.json／implementation-runtime.json 核实，隐藏服务端解析 unknown。未重复旧派工设施探针。

初次实现 277.595 秒、只交付两个允许文件。Worker 最终 9 项 unittest 通过，Lead 重跑也通过；独立 39 个 CLI 场景有 17 项未通过，主要为错误报告丢失已知上下文，另有 bool 版本报绿。真实历史 5／6 轮的 FAIL／INCOMPLETE 对照正确；报告保护场景通过。证据 lead-initial-probes.json、lead-initial-unit.json 和 lead-initial-extra.json；初次实现的源码 SHA 已在探针摘要记录，以下检查点提交保留此候选，不称验收通过。

修复 1 为原有要求的澄清／落实，不增加产品范围，不降低验收。具体反例及期望如下：

1. 计划有效而 attempt／导出有误时，现 main 丢弃所有已知字段、tests/counts=null。仅计划本身无法可靠取得时才能 null；已验证计划应按全部预期 ID 输出 UNKNOWN，保留已读取的计划身份与 path/hash；run／attempt 等只保留有效取得的值，未知留 null。任一导出错误都不能留下局部 Passed 或猜成 Missing。duplicate-id 等现已退出 2，但报告缺这项契约；不修改原反例来适配实现。
2. schema_version=true、schema_version=1.0、attempt.plan_revision=true 被 Python 的等值比较当作 1；原契约明确整数且排除 bool，需校验 plan／attempt 的版本及 revision 类型。真实 CLI 的 lead-initial-extra.json 另证实 node.result=[] 在字典成员判断处 TypeError，实际退出 1 且无报告；非字符串 result 必须是明确格式错误、退出 2，不靠捕获全部程序异常掩盖。
3. evidence 尚缺 attempt 原始字节 SHA，也未标明原 xcresult 只是调用方声明、未独立认证；按原输出契约补齐。已读输入的路径/hash应留存，读取／解析失败的未知值如实表示；不读取原 xcresult。可自行确定说明字段名，但含义必须明确，不把所有出处归结为工具推断。
4. 补上述实际 CLI 回归及原要求遗漏的版本/格式、只读输出错误路径。测试 subprocess.run 加有限超时并用任务 tmp，避免失去有界验证；不得删原断言。错误提示用 best-effort 写入，避免 stderr 刷新错误破坏退出 2，可参考既有 diagnose-app main 中已验证的处理经验。该项不是重做 DIAG-01 或推广新 I/O 框架。

Lead 帮助类型为需求澄清、Python 类型语义说明和可执行反例；没有编辑实现／测试，也未逐函数提供算法。Worker 的数据读取／实现错误与规格质量分别评估；当前修订仍为相同 frozen 行为，后续最多再一轮普通修复。本修订和初次代码由 Lead 检查点提交后，将完整 SHA 发给同一 Worker。

### 权限事件停点（最新状态；未集成，2026-09-07）

**停止本轮执行，保留待复核候选；不是任务验收通过。** 修复 1 基线 `ec64f0304036417ccd0caf55c0327a48bfd80610`，Worker 于 13:13:58 UTC 结束，耗时 137.079 秒，回传 12 个 CPU/CLI 测试方法通过；这只是 Worker 自检。Lead 未运行修复 1 的独立复验、未接管修改代码、未集成到源分支。

停点原因：Lead 补查初次执行的失败事件时发现，`implementation-events.jsonl` 第 18 行的 `python3 -B -m py_compile` 试图建立 `/Users/lfrledh/Library/Caches/com.apple.python/Volumes/CodexProjects/Codex/D-Worktrees`，出现 PermissionError。该目录不在 Worker 的可写根内。Worker 后续用已授权 task tmp 的 PYTHONPYCACHEPREFIX 成功检查，但没有按 v5 的“目录、权限、来源、数据保护问题不等两轮耗尽；立即停止写入并报告”先停报；初次最终回执也未披露这项失败。完整原事件保留，必要摘要见 `permission-incident.json`。

这属于 Python 编译检查的默认输出目录问题，以及协作停报规则未遵守；不能归为摘要判定算法本身失败，也没有证据说明实际沙箱失效、权限扩大或源／用户文件被成功写入。`-B` 不阻止显式 py_compile 写编译产物。Lead 在已发出修复 1 后才补查到这项记录，延迟发现同样计入本次协作经验，不全部归给 Worker。今后先看失败命令与资源错误，再进入返工；可用不写缓存的 AST 检查，或在调用前固定获准任务缓存，不能以扩大可写根解决。

13:14:44 UTC 检查时修复 1 的 CLI PID 47277 已结束，未发送终止信号，也未归档代替进程证明；`permission-stop.json` 记录实际观察。既有 D 进程不操作。因为权限事件停点，本轮不再派工或继续实现／验收，不把“Worker 12 项通过”补成 Lead 通过。冻结契约仍为修订 2，已用初次＋一轮修复，剩余预算不会因后续恢复而重置；没有新增 Reviewer。

来源为 Terra/medium 初步实现及一次修复，Lead 提供规格、原生格式资料和反例，没有直接改写实现；新任务三个可观察 runtime 均保持请求模型／medium、同一独立外盘工作树及受限写根、网络关闭，隐藏服务端解析 unknown。模型／隔离设置匹配与完整协作流程合格是不同结论：本轮停报约定没有满足，不能宣称流程通过。代码的修复后工程结论尚未验收。

仅统计本任务三次 CLI（预检、初次实现、修复 1），分别 27.871／277.595／137.079 秒，总墙钟 442.545 秒；各次实际报告 token 保存在 `runtime-usage.json`，不重算 DIAG-01 历史。不把工具默认目录错误当模型逻辑失误，也不凭这一个不同任务建立提示词 A/B 因果结论；完整 Lead 消耗和订阅费用 unknown。

恢复检查点：源仍 `c14f892cacd69ce909e368c03db9b69c7dac1db8`／codex/inference-foundation；源个人 scheme 的当前字节、差异、SHA 和索引以 preparation.json、保护副本与最终回执比对。候选留 codex/d-c01a-result-01 和原外盘任务工作树；修复后两个源码文件另留 `repair-1-unverified/` 及 SHA，不只存临时工作树。最终保留提交／进程／保护结果见 `stopped-receipt.json`。无合并、推送或产品阶段切换。

最小后续动作：用户允许从本候选继续原任务的 Lead 复验，固定语法检查为不写缓存的 AST，并保持现有模型、目录、沙箱和剩余返工预算；不需要修改 Mac 权限。此处不自行恢复执行。当前没有两项已具备独立验收条件的 D-C01a 后续任务：签名稳定化与完整 UI 运行共享应用产物且有前后依赖，本离线工具也尚待复核；暂不建议双 Worker，不要求模型连续零返工作为门槛。

### v7 恢复与有界 Lead 接管（2026-09-08；修订 3，冻结语义不变）

原候选 829ca10e2f396c8309723d55a69149cb132017d6 与签名源 85ef963093f95a4f22e82927df67849522c8a0eb 已在候选内保留历史合并为 3f7985240a5932956ca970cb9b3de76f96cbb2a2。源未提前推进。相关旧 CLI 有结束回执，当前原生代理状态为 completed；没有新 Worker。工具的默认沙箱拒绝本轮外盘证据目录创建，随后仅该文件操作取得工具审批；未改全局配置／系统权限，未声称默认写根已经变化。

Lead 在合并 SHA 上重跑 12 项原测试和 39 个原 Lead CLI 场景通过；不是实际 GUI 8/8。补查发现：错误导出丢失已读取路径／SHA；显式 null 容器结果被当缺省；不可写 stderr 的退出清理导致 120（无缓冲的写报告失败分支为 1）。新增三项测试方法含七个场景，修补前 15 方法运行有六个失败子场景。选择 v7 的一次有界 Lead 接管，不再叠加最后一轮 Worker 修复作为后备救援。

Astra Lead 修补单次输入读取中的证据传递、显式 null 校验、直接文件描述符 best-effort 错误提示（包括参数错误）。没有 os._exit、吞全部程序异常或修改验收标准。新增回归调用真实 CLI 等待完整结束；既有 12 方法和 39 场景不改。来源：Terra 初步实现及一次修复，Astra Lead 定点接管；非 Terra 独立通过，尚待本次完整复验与非实现者审核。历史权限未停报和 Lead 延迟审核事实不变；后续修订不追溯生效。

本轮证据：../D-Development/AgentTrials/D-C01a-RESULT-01/run-20260908T033837Z-v7-restore（实际为主仓库同级 D-Development，非本工作树相对目录）。start-protection.json、merge-command.json、merged-candidate.json、candidate-unit-execution.json、candidate-probes.json、extra-before.json、lead-regressions-before.json。运行全程不触碰 D.app、签名、模型或用户 scheme。当前待完整复验；后续实际 SHA 见运行回执。

### v7 本地接纳（2026-09-08）

状态：已本地集成并通过本任务验收；未推送。固定代码／源入口受测 SHA：653c09cd2e526c7e8cc0f09b925232f85826ee46。候选与源目录各运行 15 测试方法（原 12＋新增 3，新增含 7 场景）和同一套 39 Lead 场景通过；不将两次运行相加。历史原生第 5／6 轮只读导出分别仍为 FAIL（6 过 2 失败）／INCOMPLETE（2 过 6 缺失），不代表新 GUI 8/8。新回归先失败后通过，真实进程完成退出码为 2。

非实现者 Terra/medium 只读审阅（线程 01a07f22-334b-7692-8886-e74e863813f4；实际 turn_context read-only）未发现阻塞问题。审阅者读取证据，没有独立运行测试；Lead 实施、执行复验和集成，不把它们混为独立测试。review-process.json 确认任务结束，未归档或中断冒充结束。所有本轮自有测试进程已等待结束，D.app 未操作。源 scheme 摘要／内容／未暂存状态、索引与 start-protection.json 一致。

初次＋一次 Worker 修复历史不变，本轮改用一次 Lead 接管，已用完此接管机会；不再把最后一轮 Worker 额度作为本次接管失败后的追加救援。任务来源为 Terra 初步实现及一次修复、Astra Lead 修补并复验；另有只读非实现者审核。历史费用不重算，本轮 Lead 完整消耗及订阅费用 unknown，单一样本不证明最优经济性。

恢复点：源已包含固定代码 SHA；候选保留 codex/d-c01a-result-01，原候选及两端历史均保留。随后结案提交只改本文与 CURRENT_ACTIONS；最终 SHA 在本轮外部 final-receipt.json。源个人 scheme 保持未暂存。D-C01a 整阶段／签名版完整 UI 验收仍未完成；v7 另行准备 T0/META 批次，不由本工具隐含批准。
