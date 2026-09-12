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

## 2026-09-12 制作中检查点

共同执行基线6c655b231f8af6bd2824327347905317230dd451。两个独立CLI Worker均请求并在实际turn_context观察到gpt-5.6-sol/high、workspace-write、network_access=false，仅各自工作树/output/tmp可写；隐藏服务端解析unknown。CLI线程01a09398-fef8-7333-8889-e6dfdba4c646、Runner线程01a09398-feea-79c2-938f-b37316c3f4d1，从03:15:53 UTC有真实实施重叠。不是重新做协作切换试验。

CLI初交1e8c2269bc1f5f76388e29e84665dba146aa6e7f由Sol实现、Lead审查提交；遇到zsh here-document临时文件拒绝后停报，没有改权限或另找写根。一次组合命令仍执行了后续不存在的Swift工具路径及只读diff；不把其最终shell返回0当作前两项通过。Lead用内存compile检查Python，再在隔离DerivedData完成Release构建。原生受测f743909647c83cb99d4d9f0dee0a939f80388576：新CLI CPU30场景、旧文字CLI10类、旧图像CLI17类分别通过；后两者含真实模型，不合并成一个虚构总通过率。

复制后的CLI、四个bundle和AudioEngine已分别完成真实0.5B文字、512图像、small6秒音频（2.059/43.722/4.378秒，单次非性能承诺）；图像另用Apple ImageIO完整解码重编码检查且原文件不变，WAV独立解析264600帧/44100Hz/双声道float32且全部有限。完整kit及其他Mac的证明尚待后续记录。22个固定case正式backend --inspect均exit0/runs=[]；32B等超当前预算只估算，未加载权重。

7B、32B、medium下载已全部完整校验，新增清单约29.622GB；本包七组模型总42138351070bytes。具体固定revision、摘要和耗时见downloads/*/result.json。medium的共同文字编码权重以APFS克隆复用并重新校验；没有新依赖安装或全局环境修改。

打包实现由Lead编写；Sol/high只读非实现者审查发现相对输入漏过重叠检查，Lead以56c10da9a7f3a9177cf4370257d4c8123a212f8f修补；回归修复前失败、之后5方法通过，后续只读审查确认阻断解决。审查上下文均为read-only。复制资源的实际跨主机运行仍待现场，不能由这次静态审查替代。

Runner初交与第一修复均达到既定900秒运行上限，由Lead回收自有进程组并保存候选23e8857a56accf836a0f6d214c9220608d1e2310及06c500f3a04c599e9ac3b8467ef9ebca4f36dd0f，未接纳。Lead复验第一修复末态31方法，10个错误，主要为跨模态字典提前求值；另发现把图文MLX生命周期规则错误套到音频。音频真实CLI生命周期数组为空，清理/内存证据在provider记录中；Lead此前笼统的生命周期要求也有澄清责任。第二次定向修复仍使用原线程/权限，预算不重置。此处不预写其通过。

证据均在本任务run目录：cli-cpu、cli-legacy、image-legacy、relocation-precheck/real、all-profile-inspection、packaging-review及packaging-review-fix、runner各轮。protection-midpoint.json确认源仍0db7a8fa95fb1ed45be2999c7ab9cfb4d9a96361，scheme完整内容/摘要/mtime和普通D四关键文件保持。当前不需要真人操作；H09麦克风仍按原清单等待设备，不重复测试。

## Lead 有界协议收尾

Runner两轮普通修复已耗尽；第二修复876c33ee9f7c321e5ec56f2a7e7940e5b08cc951的32方法自测及Lead组合37方法通过，但4e72cfea967de687275431de5c67a3b5b87e5929首个完整包实测未满足契约。原包与kit-quick/kit-reliability-before证据保留，不追写为通过。由Astra执行一次有界接管，不再派第三轮实现。

根因与澄清：正式CLI每轮终态追加一个LF，必须精确核对“生成文本+LF”，不能strip后比较；audio正常取消可将Swift.CancellationError记入streamError，只有明确请求取消、终态cancelled/exit130/信号2、无产物/结果且有取消时间记录时才接受已识别的取消域，其他流错误仍失败。保留该诊断和provider/清理证据，不把取消记录当生成成功。旧短提示在2秒前完成，不证明取消；改用独立长输出提示，保持模型、精度、计时及取消要求。快速机器仍可能提前完成，手册明确这种情况不算取消通过。

新增持久回归：真实CLI换行形状和模型自带末尾换行、缺/多LF拒绝；音频标准取消与无关异常区分。lead-framing-before.log和lead-cancellation-before.log均先失败；导出的summary补全已存在的preflight校验/机器信息。后续需非实现者只读检查本差异和最终整包复验；不得以历史模拟通过代替。

同次有界收尾的移位反例发现：首次导出已脱敏，但原case记录保留旧绝对路径，移动整包后重新汇总会重现旧路径。lead-result-relocation-before.log先失败；改为case首次持久化时保存可移位投影，原始CLI/process证据另存不导出，实时音频依赖继续用内存中的经过校验引用。1be50b84cef6e1b7226b6521efd3b5b89a1f56d4差异已获Sol/high只读非实现者检查，无确认阻断；本条额外局部差异仍需复核，不能由前次审核替代。

f1bbf5bbd95b484a3c46c005e889ab83e6748fb4移位差异经Sol/high只读检查无确认阻断，43方法通过；其完整包quick真实3/3、reliability真实7/8。唯一未过项是文字取消也由同一DRuntime流抛出Swift.CancellationError；CLI真实exit130、drained/released、active/cache归零均已记录。该事实补齐同次标准取消诊断规则：不限定音频模态，其余全部取消守卫保持；新增文字取消反例先失败，旧无关错误拒绝断言不改。源尚未接纳，前述失败包/结果原样保留。本接管归因始终为Lead，不追加Worker预算。

## 用户追加：展示机专用组（spec_revision=3，执行协议仍为contract_revision=2）

用户要求明确准备本机不能安全运行、利用大内存展示机才能测的项目。新增showroom菜单组，仅引用已经冻结的6个case：text32-short/context8k/context16k、image1536/2048、audio-medium120。无新增模型、参数、精度变化或后端实现。88828896765f90ec3a0e182acc99fa1477b20589的22项真实inspect已证明这6项全部超出本机12288MiB预算；不得试图加载或以降低阈值通过。新增组须本机验证6项blocked_budget且没有执行阶段，现场仍按真实机器预算决定。此前8882889完整包reliability8/8、common3/3、medium6秒1/1通过；新profile摘要与旧包不同，旧结果保留旧包，不伪装成新版运行。CLI/runner代码完全相同，其已测代码证据可复用；最终整包和移位快速组另验。
