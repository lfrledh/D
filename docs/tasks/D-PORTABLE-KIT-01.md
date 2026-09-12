# D-PORTABLE-KIT-01 — 便携离线跨 Mac 验证包

状态：获准实施，尚未验收。spec_revision=2，contract_revision=2，batch_id=D-PORTABLE-KIT-01。
source_base=0db7a8fa95fb1ed45be2999c7ab9cfb4d9a96361。执行基线为包含本规格的准备提交，完整 SHA 在每次派工记录中。
源分支 codex/inference-foundation；集成目录 D-Worktrees/D-PORTABLE-KIT-01。原 scheme 唯一个人未暂存差异受保护。
证据：D-Development/AgentTrials/D-PORTABLE-KIT-01/run-20260912T030734Z。

## 授权与终点

用户批准制作上轮明确的测试包及中文使用说明。预装既有固定模型以及7B、32B、SA3 medium（新增完整清单约29.6GB）；沿用已确认SA3/Gemma适用资格，不代用户接受新条款。新依赖/签名方案/系统权限不在范围。用户本轮确认D及其他GPU任务空闲，可串行小配置实测。不操作普通D，不登录展示机账号，不现场安装。现场首次运行/门店允许仍待用户完成。
终点：外盘独立目录可搬移、固定配置一键串行运行、断点状态和结构化结果包、中文操作手册；本机真实小配置与高配置静态检查分列。新机器/大配置不伪称本机通过。当前App的参数UI不在本次重做范围，生产后端精度/模型能力不变，专用CLI使用同一正式后端。

## 所有权与执行

- Lead：规格、共享契约、profile/catalog数据、打包工具/启动入口、文档、下载、构建、审核/集成。仅Lead可写公共Git管理目录。
- KIT-CLI（Sol/high）：仅 Backends/MLX/Sources/DInferenceCLI/CLIOptions.swift、DInferenceCLI.swift、CLIReport.swift，以及 scripts/verify-testkit-cli.py（新增CPU入口）。不得改后端数值代码、权限、工程、旧断言/黄金样例。
- KIT-RUNNER（Sol/high）：仅 tools/testkit/d_testkit.py、tools/testkit/tests/test_runner.py及必要小夹具（均新增）。不得改KIT-CLI、profile/catalog、任务规格、正式UI/后端。
- 两个Worker独立外盘工作树，网络关闭，写根仅本工作树+本轮output/tmp；Git只读，绝对Git命令使用Xcode内Git以避免xcrun缓存。只读预检→Lead核验运行上下文→同链路实施。最多两个活跃任务，不递归。每任务初次实现+两轮修复；重要Lead实现非实现者审核。
- CPU检查用tokenize.open+compile(...,dont_inherit=True)，不exec目标、不写目标pyc；行为测试另列，所有临时目录由D_TEST_TEMP_DIR指定，PYTHONDONTWRITEBYTECODE=1。无未知拒绝绕行；拒绝或副作用不明立即停报。Worker不运行GPU/GUI/完整构建/下载，不更改缓存权限。

## KIT-CLI 冻结契约

保持旧调用默认值和退出语义。新增：
1. `--prompt-file ABS_PATH` 与 `--prompt` 恰好一个；仅UTF-8普通文件、最多1MiB、拒绝符号链接/损坏编码，读入后请求值冻结。空文本合法，超界不得截断。
2. 文字专用 `--max-prompt-tokens N` (1..32768,默认2048)、`--max-output-tokens N` (1..8192,默认1024)、`--cache-limit-mib N` (0..1024,默认64)。传入既有MLXBackendConfiguration，不改模型能力校验；maxTokens不能超过配置输出上限。
3. 图像专用 `--image-memory-limit-mib N` 可选正整数，必须不超过本次admission budget；注入既有memoryLimitBytes。不改模型q8/4步/guidance1/形状契约。
4. `--inspect` 无值开关：构造正式backend并调用estimate，不submit/execute、不加载权重、不初始化运行时/释放MLX缓存，不视为生成成功。图像/音频仍可在显式artifact目录创建必要空目录。JSON report可写，但不stdout输出生成片段。report增加 `inspection` 对象 `{estimate:{peakBytes,confidence},withinBudget:Bool}`。有效检查返回0，即使withinBudget=false；检查异常返回1、参数错误2。runs为空。报告保留实际配置选项与backend描述。
5. 不修改公共DInference协议。CLI请求构造允许局部复用，非任务参数不悄悄接受。报告沿用schemaVersion1并添加可选字段，既有验证器兼容；所有新字段含义须清楚。
验收：默认兼容、中文/emoji/空文本文件、两个输入/缺输入/非UTF8/超长/符号链接拒绝、边界/超界数字、错误模态、inspect合法/超预算/缺失模型、inspect不执行provider/不生成作品；实际CLI调用等待退出。CPU测试由Lead提供已构建CLI路径D_TESTKIT_CLI，Worker可写测试但不可启动真实生成。

## KIT-RUNNER 冻结文件接口

打包根目录是显式 `--kit PATH` 或启动脚本所在目录，不能依赖cwd/开发机器HOME/PATH。Python3.12标准库实现，调用包内d-infer，不另建推理管线。不启动网络服务，不读取profile中的任意命令/env，不下载。

kit.json schemaVersion=1：
```
{ "schemaVersion":1,"kitID":"...","sourceSHA":"fullsha","buildConfiguration":"Debug",
  "cli":"Bin/d-infer","engine":"Runtime/AudioEngine.dengine",
  "catalog":"Manifests/catalog.json","profiles":"Profiles/profiles.json",
  "minimumMacOS":"26.2","audioLicenseAcknowledged":true }
```
catalog.json schemaVersion=1：models字典，key为稳定modelID；每项含 `directory`（根相对普通目录）、`manifest`（根相对文件）、`format`（text/image/audio）、`revision`，音频另含`audioProfile`。正式manifest原样保存：text files有name,size,algorithm,checksum；image/audio files有path,size,sha256。完整内容校验必须真实执行，git-blob-sha1含blob头；不能只核对size。只允许已声明相对路径，无`..`、绝对路径或符号链接逃逸。

profiles.json schemaVersion=1：`profiles:[{id,title,caseIDs:[...]}]`，`cases:[{id,title,model,capability,promptFile,parameters,timeoutSeconds,expected,repeatCount}]`。可选`sourceCase`引用同一profile前面的成功音频用例；若输入依赖失败则blocked_dependency，不拼其他attempt的结果。
parameters仅白名单：text maxTokens/temperature/topP/maxPromptTokens/maxOutputTokens/cacheLimitMiB；image width/height/steps/guidance/seed/imageProfile；audio durationSeconds/steps/guidance/seed/audioOperation/audioStrength/audioEditStartFrame/audioEditEndFrame。`cancelAfterSeconds`是case可选受控取消实验；expected仅completed/cancelled。repeatCount限制1..3，case/profile数量有界。seed JSON建议十进制字符串传CLI，不经float。未识别字段/布尔冒充数值/非法组合拒绝，不静默更改配置。

命令：`preflight --kit ROOT`（目录/工具/manifest/兼容检查，不推理）；`run --kit ROOT --profile ID`；`menu --kit ROOT`（中文选择/预检摘要/开始，无需输入命令）；`summarize --kit ROOT --run RUN_ID`（离线回读与导出）。允许`run --resume RUN_ID`复用未完成case列表，但必须新建attempt，不覆盖旧证据；sourceSHA/profile摘要不一致拒绝恢复。可用`--cases`等小选项，必须记录选择，不把未选case计为通过。

## 执行与证据边界

- 每个run写Results/<UUID>/，所有临时/缓存也在独立run内；输入/权重/程序不写，不改HOME。单kit使用fcntl等进程锁防双击；不主动杀用户进程，不以空闲内存等同GPU空闲。界面先显示资源协调提示，用户选择启动即确认本次机器可用。
- 先完整校验所需模型/输入，再逐项调用包内CLI --inspect复用正式estimate；预算沿用物理内存减max(4GiB,25%)，不足记blocked_budget，不能缩模型/参数。图像显式分配限额可取当前预算并记录，这是资源策略不是图像参数。缺模型/不支持OS/缺依赖标blocked，不自动修复机器。
- 每个case独立拥有进程组，stdout/stderr并行或直接文件持续消费，有大小上限；SIGINT/TERM取消先让正式CLI清理，有限宽限后仅停止本case进程组并wait，记录强制停止，不能当正常取消通过。用户Ctrl-C停止本批新任务；超时/输出超限不会留下后台计算。重试预算不自动循环。
- 完整退出码+JSON终态+对应request/result/产物验证共同判断。text保存完整文本，PNG检查CRC/实际解码尺寸，WAV检查RIFF格式/44100双声道float32/有限值/帧数和摘要。可复用旧验证器算法但不得硬编码512。重绘区外PCM对照，小数时间不用猜字节。记录cancel后本case结束；后续新进程成功不能伪称同Runtime交接，repeat才覆盖同进程路径。
- 采样本case拥有的PID及可确认子PID RSS（不能直接相加当去重物理内存），保存采样间隔/范围/漏采unknown。MLX峰值与进程RSS分别展示。记录系统swap前后与压力可观察字段、芯片/内存/OS/Xcode可用性；无sudo/自动初始化Xcode/安装/全系统进程内容扫描，非必要字段不可读为unknown。
- case完成立即原子保存；run/attempt原始证据不覆盖；突然停止回读显示interrupted，不伪造完成。结果包可重建summary.json、summary.html和ZIP，不包含模型/程序/凭据/开发agent日志。通用包中路径相对化、主目录/账号路径脱敏；原始CLI日志在private目录且不默认进入ZIP。HTML必须转义。manifest摘要不自引用，外包摘要单列；损坏/未知版本拒绝或显式invalid，结果内路径不得逃逸。
- 区分执行成功、结构正确、人工质量pending；overall只有所选必需case真正通过才complete；blocked/failed/cancelled/interrupted单列。报告生成成功不等于用例通过。

## 必需CPU反例与最终验收

Runner至少覆盖：正常假CLI/已标注模拟产物；缺模型/坏摘要/路径逃逸/符号链接；坏profile/布尔数值/未知字段；预算拒绝不生成；退出码与报告矛盾；超时/取消/强制停止；中断恢复不覆盖；输出失败/已有run；Unicode路径；HTML转义和导出不含绝对用户路径；PNG/WAV损坏；双启动锁。所有假CLI必须明确注入测试工具本身，生产kit固定包内CLI，禁止profile任意可执行命令。
Lead从冻结组合构建，使用独立DerivedData/既有离线依赖；重跑旧CLI兼容、CPU和实际小模型，移位副本重跑快速组，现场大配置仅inspection不加载。包内模型完整摘要校验、实际运行参数/退出与独立媒体检查对照；普通D四关键文件和源scheme前后保持。中文说明包含启动、选择、停止、结果位置、带回、被阻止时处理和未验收边界。
本次准备批准不等于展示机现场已通过。未经验证的新生产UI路径不启用。提交/集成保留历史，源只接纳已测组合；不推主分支、不强推、不删除工作树/证据。

## 恢复检查点（准备）

源/保护状态已核对；新专属集成工作树从source_base创建。无Worker已实施。已获当前GPU空闲确认。下一动作：准备提交→两个独立Worker预检/路由核验→实施；Lead并行下载/封装准备。待最终追加受测版本、实际产物、失败/修复/来源、进程和人工待办。

规格2（实施前）：纠正图像固定manifest实际使用path/size/sha256，原规格误写为text格式。非新验收要求；两任务开始实现前接入本准备版本。生产文字结果本来包含promptTokens/generationTokens及分阶段时间，应保留实际字段，不用chunkCount冒充tokens。
