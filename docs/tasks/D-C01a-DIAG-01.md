# D-C01a-DIAG-01：只读开发签名／产物诊断工具

状态：准备／等待执行链路预检；未授权 IMPLEMENT，非 D-C01a 整阶段验收。
规格修订：1。维护者：Lead（Codex，当前 Astra 设置）。日期：2026-09-07。
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
