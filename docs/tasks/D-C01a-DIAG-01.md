# D-C01a-DIAG-01：只读开发签名／产物诊断工具

状态：试点执行结束；候选未通过全部验收、待用户决定。两轮修复已用完，停止继续实现。非 D-C01a 整阶段验收。
规格修订：3（原契约与范围不变，记录剩余复核问题）。维护者：Lead（Codex，当前 Astra 设置）。日期：2026-09-07。
run_id：`run-20260907T090333Z`。本文件复用 TASK_SPEC_TEMPLATE 的职责，合并规格、运行、审核与恢复记录。

## 基线、目录与角色

- 源目录：`/Volumes/CodexProjects/Codex/D`；源分支 `codex/inference-foundation`；源 SHA `85bc509932562c27e091a22cb101365117a9d76c`。
- 执行目录：`/Volumes/CodexProjects/Codex/D-Worktrees/D-C01a-DIAG-01`；任务分支 `codex/d-c01a-diag-01`。common Git directory 必须为 `/Volumes/CodexProjects/Codex/D/.git`，工作文件和 index 必须独立。
- 执行基线：本规格首次进入 Git 的准备提交；它与源基线不同。完整 SHA 由 Lead 在提交后写入外部 `preparation.json` 和首次派工消息，冻结后不按分支浮动选择。
- 持久证据目录：`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-C01a-DIAG-01/run-20260907T090333Z`。Worker 仅可写其 `worker-output` 与 `tmp` 子目录及任务工作树内获准文件；其余证据由 Lead 写入。
- 实现者只允许 `gpt-5.6-terra / medium`，一名 Worker，不递归派工。Lead 负责规格、门槛、审查和 Git 提交，不先代写实现。
- 用户个人文件：源 `D.xcodeproj/xcuserdata/lfrledh.xcuserdatad/xcschemes/xcschememanagement.plist` 的 orderHint 1→6；SHA256 `ca3635d88aa5a15397b90e528667c66c0e6db7e596176e885c79d194b544206c`。不能还原、暂存或携带到任务工作树。

## 目标、范围与输入资料

目标是检查显式给定的既有 D.app，生成有证据、不会将未知值冒充否定值的诊断报告。不是修复器，不进入签名切换、集中授权、D-P01 或其他产品工作。

Worker 最小阅读：本规格、AGENTS.md；`docs/MAC_PERMISSION_SETUP.zh-CN.md` 的“先完成的工程准备”；`D/D.entitlements`；`scripts/verify-mlx-cli.py` 的参数与进程检查风格（不执行）。预算约定见 `docs/DELIVERY_AND_MODEL_BUDGET.zh-CN.md` 模型分工与工作包部分，仅按需。无需读完整历史、其他 ADR 或推理源码。

实现阶段唯一允许新增的源码／测试：

1. `scripts/diagnose-app.py`：Python 标准库入口。
2. `scripts/tests/test_diagnose_app.py`：unittest 测试和小型内嵌受控夹具；临时文件只在授权 tmp 下。

Worker 不修改本规格或全局规则。明确禁止修改 build-local.sh、Info.plist、entitlements、Xcode 工程、依赖／锁文件、Swift 推理／运行时／工作台／UI、签名设置、用户文件或 Git 元数据。不得增加第三方依赖。不得 merge、push、上传、发布、改 Git 作者身份或全局 Codex 配置。

## 执行链路门槛

桌面已登记的 D 指向内盘空仓库，不能用于派工；当前原生子代理没有 cwd／sandbox 参数，当前 Lead 是 danger-full-access。拟采用随桌面客户端附带的 CLI 的独立会话，而非继承当前子代理环境；不将 CLI 结果称为桌面原生派工实测。

首次消息仅 PREFLIGHT：返回 task_id/revision/run_id、实际 cwd/realpath、Git root/common directory/index/HEAD/branch、允许与禁止范围和验收摘要，然后结束该轮，不能实现或写文件。Lead 从创建参数及运行元数据核对请求和运行模型、effort、目录及沙箱。自述不算模型或权限证据。

先用 read-only；转 workspace-write 时须对同一会话重新只读预检其新生效配置。写根仅任务工作树及两个任务输出子目录，禁网络；排除默认 /tmp 和系统 TMPDIR，使用专属 tmp。不得包含源目录、源 common .git、原 D.app、/Volumes 或用户目录。CLI 本身的认证和会话元数据不等于赋予 Worker 对这些目录的写权限。不读凭据内容。未确认时停止，不用提示词代替沙箱；不开权限，不借其他模型代做。

仅三个门槛均过，Lead 才向同一链路发出带修订及完整基线的 IMPLEMENT。隐藏的服务端模型解析可标 unknown；当前运行上下文必须明确 terra/medium。权限或身份不符立即返回 Lead。预检最多一次有明确纠正依据的重试。

## 公共行为与输出契约 v1

- CLI：`python3 scripts/diagnose-app.py --app PATH`，JSON 写 stdout；可支持显式 `--report PATH`，只能新建报告，不覆盖已有报告，不允许将报告写到被检应用内部。无参数或参数语法错误可用标准 usage/stderr，退出 2。不得隐式搜索应用。
- 外部程序仅 `/usr/bin/codesign` 的 display/verify 只读操作，安全 argv 传递；不经 shell 拼接路径。每个子进程必须有有限超时（默认 10 秒，测试可注入更短值），超时终止并回收自己的进程。不得启动、重签、移动或修改应用，不用 security/keychain、spctl、xcodebuild、swift、下载或 GUI。
- 字段名称可自行选择，但必须稳定记录 schema_version=1、检查时间、输入/解析后路径、报告完整性、总体规则结论、每项检查的 status/reason/evidence 和工具执行错误列表。命令证据包含 argv、returncode（未启动则 null）、stdout/stderr、超时／不可用／异常；stderr 非空本身不是错误。
- 产物：显式路径存在、目录／Contents 可读、Info.plist 是字典、CFBundleExecutable 是安全单文件名且该主程序存在。版本字段 CFBundleShortVersionString、CFBundleVersion 缺失如实表示 missing；不以缺版本字段单独拒收工具。记录 Info.plist 和主可执行文件 SHA256；缺失/不可读取/不适用分别报告，不扫描父目录和全盘，不把任意 plist 字段变成可越界读取的路径。
- 身份：Info.plist 的 CFBundleIdentifier 和 codesign 显示的 Identifier 独立字段、独立证据；可读时比较一致性。两者不得互相填补缺值。现阶段 D 预期 `first-test.D`；不改变它。
- 签名：区分 unsigned、ad-hoc、certificate-backed、unknown。依据 codesign 的已观察字段，不能凭 Authority 的显示名称宣布可信或 Developer ID。签名详细信息读取与 `codesign --verify --strict` 的完整性检查分开；不承诺该命令验证嵌套代码、公证或 Gatekeeper。
- entitlement 从 codesign 读出的 plist 解析，不能拿源码 entitlements 代替产物。至少分别记录 `com.apple.security.app-sandbox`、`com.apple.security.files.user-selected.read-write`、`com.apple.security.files.bookmarks.app-scope`、`com.apple.security.network.client`、`com.apple.security.get-task-allow`；每项 value/state 区分 true、false、missing、unreadable/invalid。其他实际读到的 `com.apple.security.temporary-exception.*` 和 `com.apple.security.cs.disable-library-validation` 记录实际类型/值及依据。成功解析整个 entitlement 字典后才可断言某 key 缺失，无法解析不可冒充空字典。get-task-allow 不等于关闭 sandbox。
- 当前开发规则：结构可读；Info bundle ID 为 first-test.D 且签名 identifier 一致；签名存在且完整性验证成功；前四项正式权限为 true；不含启用的 disable-library-validation 或非空 temporary-exception.*。Debug 的 get-task-allow=true/false/missing 均仅记录，不因此失败。ad-hoc 可满足当前规则，稳定 Apple Development、Team、分发／公证不是本轮硬门槛。
- PASS：有充分证据满足该项明确规则；FAIL：完成检查且证据表明不满足；UNKNOWN：证据不足、执行或解析异常，不能默认通过；NOT_APPLICABLE：前提确定不成立（例如已明确未签名时没有签名 entitlement），不能用于隐藏执行失败。不存在可用签名本身为 FAIL。
- 退出 0：诊断完整，所有适用的必需规则有证据通过；退出 1：诊断完成但存在明确规则 FAIL（例如确认 unsigned、verify 正常执行但非零、sandbox false）；退出 2：输入／读取／执行／解析／报告写入错误使必需诊断无法完成。2 优先于 1；非必需版本字段缺失或证书信任未知不提升为工具错误。JSON 报告成功产出不等于应用通过。
- 必须列明未检查：证书链信任、公证/Gatekeeper、实际沙盒文件操作、TCC 持续有效性、跨构建书签恢复、GUI 和 D-C01a 全阶段验收。

## 冻结验收要求

Lead 的期望不能由 Worker 修改；可调整私有函数和测试组织，不逐函数固定实现。测试必须覆盖行为及相应退出语义：

| 场景 | 预期 |
| --- | --- |
| 完整 app、受控 ad-hoc 或证书签名记录、合法 entitlements、verify=0 | 完整报告，规则 PASS，退出 0；分类不宣称信任 |
| 显式路径不存在、文件代替 bundle、不完整 app、损坏／非字典 plist、不安全 executable 名 | 明确读取/结构错误，退出 2；不扫描或越界读取 |
| 空格、中文、非 ASCII 与 shell 特殊字符路径 | argv 原样传递；无命令注入，读取正确目标 |
| 明确 unsigned；或 verify 正常执行但非零 | 相应 FAIL，退出 1（其他诊断无执行错误时） |
| 成功解析字典但必需 entitlement missing/false | 与 unreadable 区分，明确 FAIL，退出 1 |
| entitlement plist 无法解析、必需值非布尔、签名信息无法可靠解析 | 必需证据 UNKNOWN，退出 2；不能补默认值 |
| codesign 不可用、启动异常、display 异常非零、超时 | 工具错误独立呈现，退出 2；超时自己的子进程结束 |
| stderr 有常规签名信息/提示且正常成功 | 不把 stderr 非空当失败 |
| get-task-allow 与 sandbox 分别变化 | 各自报告，不能推导为同一个开关 |
| 报告目标存在、不可写、在 app 内部 | 不覆盖、不触碰 app，明确错误，退出 2 |

正常／失败签名使用明确标注的模拟记录，不签署真实样本。Worker：只运行 `python3 -B -m unittest discover -s scripts/tests -p test_diagnose_app.py -v` 及必要 Python 语法检查、git 只读差异检查；设置 PYTHONDONTWRITEBYTECODE，tempfile 定向专属 tmp。不能跑完整构建、测试、MLX、GPU 或 GUI。Worker 不读取真实 D.app；真实验证由 Lead 执行。

Lead：独立审查代码、测试预期、错误与退出语义、路径安全、子进程副作用。重跑轻量测试；对唯一现有普通产物 `/Volumes/CodexProjects/Codex/D-Development/DerivedData/Build/Products/Debug/D.app` 做只读真实诊断，直接调用 codesign/plistlib/hashlib 交叉核对；前后比较相关文件摘要，变化则该轮证据不完整，不能停用户 D 进程。真实与模拟证据分开；不为脚本验证而重建／重签应用。

## 回传、修复与来源记录

Worker 回传 task/revision/run_id、实际 cwd/HEAD、修改文件、git diff、检查命令/结果/日志、偏差、未知覆盖与自己的存活进程；可写任务 worker-output，不修改规格、不 commit。Lead 接回写入权后逐项暂存获准文件，保留候选分支，不合入源分支、不推送。

初次交付后最多两轮有理由的定向修复；需求／接口不清、权限／目录／模型／基线不符、数据风险或需要越界时立即停止并上报，不消耗修复轮数猜测。等待下一授权不能无限持续，结束当前轮交回控制即可。旧修订结果不自动接纳。Lead 独自负责复核，不另称独立评审模型；实质重写如实记录。

记录请求/运行模型与 effort、线程 id、隐藏解析 unknown、开始结束时间、每轮角色、检查对应代码版本、来源映射及返工原因。未知 token/额度/费用记 unknown，不套 API 单价。不在源码逐行署名，不修改人类 Git 作者配置。

## 运行、审核及恢复检查点

- 已完成：源身份与唯一用户差异核对；旧三个子代理 completed，无活跃 Worker；观察到既有 D PID 36901，未操作。无活动 Git hook、checkout filter、父级/项目 .codex 初始化配置；用户独立 hooks.json 不存在。创建一个外盘任务工作树。
- 未完成：执行链路预检、受限写入配置核验、实现、CPU 测试、真实只读产物检查和候选审核。
- Lead 只读准备检查曾有两个非 Worker 辅助命令错误：系统 Python 不含 tomllib，改用限定字段读取完成；尝试读取 sandbox 子命令帮助时该版把 macos 当命令，未找到可执行文件，未产生项目修改。不作为 Worker 失败或模型能力证据。
- 当前源 HEAD 及个人文件摘要见首节；后续恢复先核对实际仓库、任务状态和权限，不只相信本文件。准备提交不代表实现或阶段验收。完整 SHA、启动参数与运行证据由外部 preparation.json/运行记录补充；Lead 在 Worker 结束写入后更新本节。

### 初次交付和 Lead 复核（修订 2）

实际准备执行基线为 `90bcaa87d2430c4504d3c11b59c4bc89b238bc80`。独立会话 `01a07b1f-4f6c-7e03-91fe-15c550396036` 经随客户端附带的 CLI 启动，先 read-only，再同会话 workspace-write 只读确认，随后 IMPLEMENT。三轮运行元数据均为 gpt-5.6-terra / medium；网络关闭，写根为本工作树及指定 worker-output/tmp，排除通用 /tmp、系统 TMPDIR；隐藏服务端解析 unknown。不是桌面 create_thread 自动工作树功能的验证。证据 `gates.json`、`implementation-runtime.json`；会话原始记录按必要字段摘录，未复制全局配置或密钥。

Worker 初次实现耗时 272.721 秒，未 commit；首次自检前有日志未生成的命令使用问题，后修正；一次夹具构造错误修正后最终 5 项 unittest 通过。Lead 独立重跑这 5 项通过，真实普通 D.app 诊断退出 0。源码快照和 SHA 在外部 `initial-candidate/`、`initial-code-version.json`。Lead 未改写实现。

但 Lead 的 9 个定向受控场景仅 control 通过，8 个揭示缺口，见外部 `lead-review-probes.py` / `lead-initial-probes.json`。本次候选拒绝接纳，以下为第 1 轮修复；原期望不降低，不改模型、签名、权限或应用：

1. 两个 identifier 都为 wrong.bundle 时初版退出 0；必须独立要求 Info bundle ID 为 first-test.D，不能只要求两来源相同。
2. 损坏的 Info/entitlement XML 抛出 ExpatError；超时携带 bytes 部分输出造成 TypeError；选择的 debug entitlement 为 plist Data 时 JSON 序列化失败。必须产出结构完整、JSON 可序列化的错误报告和退出 2，不能崩溃、吞错或将无法解释的值转成 false/missing。
3. 缺路径等提前返回缺少必需 overall 字段；每条有效解析 CLI 请求的路径都需稳定报告结构。display 非正常非零也须独立记录工具／解析问题，而不只留规则 UNKNOWN。
4. disable-library-validation 为非布尔字符串时误判安全；应报告 invalid/UNKNOWN、退出 2。已选择检查的调试布尔 entitlement 同样区分非法类型，合法 get-task-allow true/false/missing 的原规则不变。保留实际类型的可序列化证据，不凭默认值断言不存在。
5. 安全 executable 文件名仍可通过 symlink 读到 bundle 外文件；Info/Contents/MacOS/主程序的相关解析后位置应在所选 bundle 内，否则退出 2，不读取越界目标。测试用授权 tmp 中的受控外部文件，不接触源工作区或用户数据，不把禁止写入当探针。
6. 补齐原规格已有而初版缺失的可观察测试：证书签名分类但不宣称信任；损坏／非字典 plist、缺主程序；所关注 entitlement false/missing/invalid；display/verify/entitlements 命令异常及 stdout/stderr 语义；报告成功写入、不可写、拒绝覆盖后原字节保持、拒绝 app 内报告；实际 CPU 子进程输出后超时并被回收。Python 子进程仅为该测试的受控夹具，禁止启动真实 app 或执行其他功能。
7. 私有测试用 --timeout 也必须保证有限正数；NaN/Infinity/非正数应在启动命令前拒绝。不能用该参数取消有限超时要求。必要时覆盖 stdout 写入异常的明确错误退出。

Lead 保留初次候选与本修订的本地检查点，修复执行基线完整 SHA 写入外部 `repair-1-request.json` 和发给同一 Worker 的明确消息。Worker 从该 SHA 起步；只改原有两文件，不修改本文或 Lead 探针。只读确认修订／SHA／目录后修复，结束写入并返回 Lead；至多再有一轮定向修复。所有原始失败证据保留，不能把后来的通过覆盖成首次通过。

### 第 1 轮交付复核与最后修复（修订 3）

修复 1 从 `5e20327636525840f636ecd314999b15175ec613` 开始，仍为原 Terra/medium 独立受限会话，运行上下文未变；耗时 292.919 秒。Worker 报告最终 9 项 unittest、原 Lead 9 个探针通过；早期一项“主程序缺失原因说明”的测试失败在本轮内部修正并保留日志。Lead 接回写入权后检查差异，未改写源码。

第 2 轮只完成下列原有规则的剩余缺口，不扩展功能、不变权限或模型。复现摘要在 `lead-repair-1-additional-probes.json`：

1. display 完成但异常非零、不是 unsigned 时，exit=2 但 tool_errors 为空；要求工具错误列表包含明确原因和对应命令。加测试检查字段，不能只断言退出码。
2. `Contents/MacOS` 指向 bundle 外目录，而外部 `D` 再指回 bundle 内受控文件时，当前返回 0；每个已约定目录层的解析后位置必须在 bundle 内，在启动 codesign 之前拒绝该情形。补 Info、Contents、MacOS、主程序 symlink 边界测试，仅用授权 tmp 的夹具。
3. Info.plist 中可解析的非有限 real（例如 CFBundleVersion=float('nan')）会把裸 NaN 写入 JSON。报告必须是标准 JSON：可用带类型的可序列化证据保留特殊值，不能把它补成 0/false/missing；以 `json.dumps(report, allow_nan=False)` 能成功为检查。非必需版本值异常不得靠假造已知值解决。
4. 修复 1 将实现压缩成大量多语句长行，降低可审核性。恢复项目内普通 Python 可维护风格：独立 import、每行一个语句、清晰缩进/空行和有含义的变量名；拆开复杂嵌套条件。无需第三方格式化器，不用代码压缩减少行数，也不让 Lead 代写。
5. 落实上轮已经要求的测试缺口：Info/entitlements 的非字典或损坏数据；verify 与 entitlements 各自的命令异常/超时；报告不可写及不覆盖的实际字节断言；合法 debug false/missing 与 sandbox 独立变化。超时夹具不依赖 20ms 内 Python 一定完成启动，使用合理有限时间、输出 pid，并独立确认自己创建的子进程已经回收，不能只凭 returncode=null 宣称已回收。stdio 输出错误的 2 退出语义如涉及实现，应在此一并完成。

本轮之后不再自动继续修复。Worker 只回传两个获准文件及新命名 repair-2-* 证据；Lead 完成最终独立复验，按实际证据接纳候选或明确拒绝。第 2 轮完整执行 SHA 由本修订检查点及 `repair-2-request.json` 固定。

## 最终交付、未通过项和恢复检查点

核实日期：2026-09-07。有效规格修订仍为 3，未因验收失败降低规则。修复 2 基线 `cc6eb169c4799d90e4743158245464785ace904d`；最终实现及测试候选提交 **`a2ed7c58a9bcf142090821041d4e8037bbb3d155`**，由 Lead 按文件提交 Terra 的改动。Lead 只维护任务规格、写独立复验探针、审核和提交，没有编辑诊断实现或其项目内测试。本文最终记录产生后续纯文档提交；验证绑定 a2ed7c5，不宣称在文档提交上重新执行。

### 三个独立结论

1. **工程候选：暂不接纳。** 主体功能和以下检查通过，但标准输出写入失败的退出语义不符合冻结契约。`scripts/diagnose-app.py` 的 main 最后直接 print，Python 延迟 flush 失败时实际退出 **120**，而报告写入错误约定为 **2**。复现仅将子进程 stdout 连接到任务自有夹具的只读文件描述符，没有修改文件／系统权限；夹具原字节未改变。证据 `lead-final-output-io.json`。该问题未修复，未用解释或修改验收标准掩盖。最多两轮修复已用完，不再自动派工或由 Lead 补写。
2. **模型与隔离流程：在可观察范围通过。** 同一个线程 `01a07b1f-4f6c-7e03-91fe-15c550396036`；显式请求 Terra/medium，五个运行上下文均记录 gpt-5.6-terra/medium。先 read-only，后同会话核验 workspace-write，再实现和两次修复；网络关闭，默认 /tmp 和系统 TMPDIR 排除，唯一附加写根为该 run 的 worker-output/tmp。任务工作文件和 index 独立，common .git 留在源仓库且不在 Worker 写根。授权目录内实际写入和 CPU 测试已执行；没有做源目录越界写入探针，不称其为系统层防逃逸认证。服务端最终解析／隐藏回退 unknown。桌面原生自动 worktree 派工未验证；本轮链路是附带 CLI 的独立受限会话，未改全局配置。参数来源为当前 CLI 帮助及 [官方配置参考](https://learn.chatgpt.com/docs/config-file/config-reference)，有效边界以 gates/runtime JSON 为证据。
3. **模型性价比：证据不足。** 样本只有一个，初次候选未验收通过，经过两轮返工仍有一项输出错误契约未满足，Lead 审核介入明显。不能据此断言 Terra 普遍胜任脚本、Swift 或比 Astra 更省订阅额度。

### 检查结果与边界

| 检查 | 方法／版本 | 实际结果与证据 |
| --- | --- | --- |
| 项目内 CPU 测试 | Python 3.9.6，macOS 26.6.2 arm64；`python3 -B -m unittest discover -s scripts/tests -p test_diagnose_app.py -v`，a2ed7c5 | Lead 重跑 10 个测试方法通过，含实际受控 Python 子进程超时并以 PID 确认回收；`lead-final-unittest.*` |
| 已知问题回归 | Lead 原 9 场景＋后续 3 场景，标准库受控签名/plist/path 夹具，a2ed7c5 | 12 场景通过；`lead-final-original-probes.stdout.log`、`lead-final-extra-probes.stdout.log`。与 Worker 自检分开，不能当成另一模型审阅 |
| 语法／差异 | AST 解析和 `git diff --check`，a2ed7c5 | 通过；`lead-final-checks.json` 绑定 SHA 与文件摘要 |
| 普通 D.app 实际只读验证 | 唯一既定 Debug/D.app；工具报告与直接 codesign、plistlib、hashlib 交叉核对 | 通过；ad-hoc、first-test.D 两来源一致、严格完整性验证 0、四项正式 entitlement 和 get-task-allow 均 true。报告中的类型／hash／文件结果一致；`lead-final-real-validation.json`、`lead-final-real-report.json` |
| 应用符合规则但报告保存失败 | 对同一正常 app 使用任务目录内既有报告／缺父目录目标 | 退出 2、独立报告错误、原文件字节不变；`lead-final-valid-app-report-errors.json` |
| 标准输出不可写 | 任务自有只读描述符，无 chmod／TCC／系统权限变更，a2ed7c5 | **未通过**：实际 120，期望 2；`lead-final-output-io.json` |

产物前后核对 Info.plist、主程序、D.debug.dylib、_CodeSignature/CodeResources 的 SHA256、大小和 mtime；最终实际验证与最初快照完全一致。所有真实验证都不包含构建、重签、GPU、模型推理或 GUI；没有关闭现有 D。证书签名的正常/失败类别只用夹具，不证明真实 Apple Development 或 Developer ID 信任。公证／Gatekeeper、TCC 持续性、真实沙盒操作、跨构建书签和完整 D-C01a 均未验收。

### 来源、消耗与执行问题

Worker 为唯一 Terra 会话：初次实现 272.721 秒，修复 1 为 292.919 秒，修复 2 为 302.895 秒；两次预检 38.948＋17.765 秒，CLI 调用总墙钟 **925.248 秒（约 15.4 分钟）**。不把 Lead 并行审核或准备时间从这个数倒推。原始 CLI turn.completed 合计记录输入 3,377,519，其中 cached_input 3,253,760；输出 38,266，另有 reasoning_output 字段 5,335，不重复相加。输入包含多次调用的重复上下文，不是独特文本长度，更不是订阅扣费。账户额度扣除、任务级实际费用和独立归因的 Lead token/活跃耗时均 unknown。见 `usage-summary.json`。

没有预检重试、模型替换或权限扩大；首次交付后恰好两轮修复。初次自检夹具创建失败、首轮修复的原因文字断言失败、最后一轮新增测试的临时目录生命周期错误均在各轮内部修正，失败日志保留，不计作首次通过。初次日志写入命令使用问题属于工具操作／证据保存问题，不能混作权限拒绝。未发现 Worker 越过两个项目文件的写入范围；没有给高价模型代写实现后署 Terra 名称。关键遗漏属于实现／测试覆盖问题，不以环境解释掩盖。

### 恢复与保留

- 已完成：源身份保护、一个外盘工作树、受限 Terra 链路核验、初次实现＋两轮修复、Lead 复核和现有产物交叉检查、本地候选提交。
- 未完成：标准输出写入错误的 2 退出语义及对应永久回归；工程候选的完整接纳。尚未完成的测试覆盖应随这一小修补一起复核，不能因已有检查通过宣称穷尽所有文件系统故障。
- 源保持 `85bc509932562c27e091a22cb101365117a9d76c` / `codex/inference-foundation`；唯一源差异仍为 scheme orderHint 1→6，SHA256 `ca3635d88aa5a15397b90e528667c66c0e6db7e596176e885c79d194b544206c`；源 index 无暂存改动。
- 候选位置：本工作树／`codex/d-c01a-diag-01`；未合入源分支，未推进 main/master，未 push、发布、上传证据；未改认证、远端、人类 Git 作者、签名、权限或全局 Codex 设置。
- 创建的 CLI PID 42155、42337、42551、42939、43235 均已结束；各 turn.completed 有记录，CPU fixture 子进程回收检查通过。既有 D PID 36901 仍运行。未用归档或中断代替进程结束证据；没有归档本试点或关闭共享客户端服务。
- 下一动作仅为建议：由用户决定是否单独批准修补 stdout 写入错误及回归，再复验当前候选。现有 IMPLEMENT/REPAIR 授权已用完，不自动启动下一工作。
- 外盘证据目录保持本文件首节的 run 路径；关键索引：preparation.json、worktree-check.json、gates.json、各阶段 request/runtime/process JSON、lead-final-checks.json、lead-final-real-validation.json、lead-final-output-io.json、usage-summary.json、final-process-observation.json。小摘要在 Git，本轮日志、受控夹具输出和源码快照留外盘证据目录，不只留临时 worktree；未存权重或批量作品。工作树和证据均保留，不清理无关文件。
- 压缩／重开后先核对源 HEAD、受保护文件、候选 SHA／差异、Worker 状态和权限；不得仅靠此文或聊天摘要恢复执行。
