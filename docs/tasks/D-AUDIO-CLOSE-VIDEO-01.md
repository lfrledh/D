# D-AUDIO-CLOSE-VIDEO-01：音频薄封装收尾与视频后端研究

状态：音频收尾及视频研究已验收、本地接纳；推送结果与最终文档SHA见末尾外部回执。日期：2026-09-13。规格 close-r1 / contract packaging-r1 未改。
用户授权：收齐必要后端接口便转下一模态；音频仅交付收尾，视频本轮研究，不下载/安装/运行新模型，不扩写编辑器、HUM、歌声、TTS。复杂创作操作属于工作台。上一阶段 `c202a7548998cade6c2d1284625c33605fe16f9a` 已完成真实 SA3/MRT2 工作台验证，最终源 `ec7c6eff989dbff501db470838448cc4e793258e` 为七份文档之后版本；历史不重算。

源基线：`ec7c6eff989dbff501db470838448cc4e793258e`，codex/inference-foundation。Lead候选：外盘 D-Worktrees/D-AUDIO-CLOSE-VIDEO-01，codex/d-audio-close-video-01。执行基线是包含本规格的准备提交完整SHA，由派工记录给出，不自引用。外部证据：D-Development/AgentTrials/D-AUDIO-CLOSE-VIDEO-01/run-20260913T050442Z。源个人scheme的内容、摘要、索引及未暂存状态在protection/start.json和副本保存；每次源更新前后核对。普通D/历史产物/模型保持只读。

## 唯一实现包 P1（Sol/high）

目的：从普通新构建D.app和已安装的两套离线依赖，调用现有两个引擎准备器，生成另一个自包含、同身份签名的D.app。替代阶段临时封装脚本的手工步骤，不新增后端接口、不改推理或签名政策。不依赖任何旧trial App/引擎副本。没有自动安装、下载、模型执行、GUI、扫描寻找应用或身份。

Worker仅可写：
- Backends/Audio/Packaging/package_audio_app.py（新增薄入口）
- Backends/Audio/Tests/test_audio_app_packaging.py（直接CPU测试，可把小夹具内联）

不可写：所有其他源码、prepare_engine.py、prepare_mrt2_engine.py、build-local.sh、工程/依赖/签名/权限/任务规格、源工作区和共享Git。Lead单独负责全局文档、审核/构建/真实封装/资源/集成。不要递归派工、commit或改用户配置。

### 冻结输入输出和保护

CLI 必需显式参数：`--app`（新普通构建输入），`--python-root`（3.12标准库根），`--sa3-site-packages`，`--mrt2-site-packages`，`--identity`（既有40位证书指纹），`--output`（不存在的绝对.app路径）。所有目录绝对、无符号链接祖先、输出父目录必须存在，拒绝输入输出祖先重叠/已存在或运行中出现的输出。源码provider/vendor/model manifests从本脚本所在仓库得到，不能由数据输入指定任意命令。无JSON配置/新框架。命令安全argv，不拼shell。正常成功0；输入、复制、命令失败/超时、验证失败和输出错误2；错误指出阶段，不能把未验证写为通过。

输入App必须是结构可读的普通已签名沙盒构建；codesign完整性验证与读取信息分别检查。bundle ID从Info.plist、Team从签名读取，非空且不是ad-hoc；App Sandbox必须true，禁止凭get-task-allow认定非普通开发包，保留输入实际entitlements。拒绝输入已有两套引擎，避免默默替换/混合历史版本。不更改源App，output只在完整验证后以既有RENAME_EXCL方式发布；失败仅清理自建暂存，保留已有output和input。允许报告为stdout简短JSON；持久执行日志由Lead捕获，不新增自动报告平台。输入/代码/依赖目录可能有大文件，只做必要读校验。

固定编排：复用prepare_engine和prepare_mrt2_engine，分别生成AudioEngine.dengine和MRT2MusicEngine.dengine，依赖与精度各自保持；输入python/site-packages不变。只在自建App副本中处理引擎Mach-O签名（按magic识别，不凭扩展名）。使用显式原identity、runtime、timestamp=none；无keychain枚举或申请证书。签名后的native文件才更新engine.json大小/摘要，非native字节不变；保持现有清单格式和BundledAudioEngine严格验证规则。输入App已签嵌套组件保留。最后按输入实际entitlements签名外层并验证整App（验证可deep，签名不deep），核对bundle ID、Team及entitlements不变；新引擎解释器/native同Team。只签新副本，不更改既有签名方案。不运行解释器/模型进行自动验收；签名和清单通过不能宣称普通沙盒推理通过。

独立输入App内允许正常框架的内部相对symlink，若实现无法安全支持可明确拒绝（当前真实App预检无须此能力）；绝不跟随越界链接复制。外部命令需受控超时并回收自己的子进程。两套准备器可直接调用已知Python函数以复用安全逻辑，无需新增进程；其余外部命令仅codesign及必要既有复制工具。避免泛化可注入命令行测试后门：CPU测试可以patch受控内部command seam，真实签名/产物由Lead独立验证。

### 必须覆盖的CPU验收（冻结预期）

1 正常合成App/两套引擎编排与manifest，明确签名响应是夹具；2 空格/中文/emoji路径；3 缺失/相对/畸形App或损坏plist；4 output存在/发布时碰撞，原件不变；5 output与input重叠和链接逃逸拒绝；6 input已带引擎拒绝；7 未签名/验证失败/Team或identifier缺失与最终不一致拒绝；8 sandbox缺失/false拒绝，get-task-allow true仍可用且entitlements完整保留；9 原生/非原生更新边界和摘要；10 任一prepare/签名异常/超时失败不发布、保留输入；11 正常CLI和错误退出及stderr文本不是失败依据；12 无缓存语法编译。
现有音频Python测试全部回归；不要为了通过改既有断言。CLI关键输入失败以真实进程结束码检查；不制造真实签名样本/申请证书。Lead用真正已安装依赖+当前普通新构建+既有identity封装，直接codesign/清单/App resolve交叉验证，并在资源允许时从新包做SA3和MRT2短生成及取消/下一任务回归。不降低旧精度。普通D不启动/替换，未确认资源先做CPU与独立构建；缺真实验收则保留候选，不宣称新包已可用。

### 执行与模型

唯一受限独立CLI Worker：gpt-5.6-sol/high（路径/签名/原子发布风险较高，接口已定）。先只读预检，Lead核对实际turn_context的cwd/base/model/effort/写根，再IMPLEMENT。写根仅自己的独立工作树和该Worker output/tmp，网络false，共享Git只读；本任务不授予真实codesign/钥匙串/应用访问或任何模型/GPU/GUI/build。独立目录和request记录是执行事实入口；隐藏服务端解析unknown。

输出/缓存/TMP：全部为派工消息给出的唯一output/tmp。`PYTHONDONTWRITEBYTECODE=1`，语法使用tokenize.open后内存compile(dont_inherit=True)，不执行/导入目标作为语法证明。不默认py_compile。任务测试可按正常方式导入所测模块用于行为测试，但不得导入MLX/运行模型。真实权限事件按现行协作规程停报，预先批准的失败夹具单列。初交+最多2轮针对性修复、每轮≤900秒；越界/身份/契约问题立即停止，不用修复预算猜测。Lead在每次返工前检查异常和保护。

## Lead收尾与视频研究

P1写入交回后：审查+CPU+一次非实现者只读复核；普通隔离构建沿用既有Team/bundle/entitlements。既有AudioRequest/AudioSynthesisParameters/DRuntime已足够支持音频组合，无新增空接口。当前图文推理代码不变，无故不重跑全模型基准。

仅必要文档：本任务、AUDIO_BACKEND_GUIDE、CURRENT_ACTIONS、PRODUCT_GOALS、MUSIC_ROADMAP及一份VIDEO_BACKEND_DESIGN；明确研究候选/本机unknown。视频研究覆盖T2V/I2V输入输出、具体模型版本、Mac实现/依赖与精度、帧时基/颜色/内存/取消；不把CUDA显存数字等同Mac统一内存，不只支持本机小模型。视频实现、模型下载与歌声/HUM均未获本轮实施。通过后固定SHA隔离集成、源FF与相关入口回归，显式暂存、提交push工作分支；失败保留证据不自动回退。

## 恢复检查点

已做：源身份/保护及无活动hooks检查、音频接口只读审计、建立独立Lead工作树。未做：P1预检/实现/测试/封装/真实运行/视频文档/集成。原阶段已验收，不重标为欠缺；新封装入口需本批验收。GPU/GUI资源确认待用户答复。Lead证据目录paths.json/protection记录完整路径和SHA。模型来源和各轮失败随后追加，不覆盖历史。

## 2026-09-13 验收、本地接纳与收尾检查点

上面的恢复点是开始时记录。用户随后确认普通D及其他AI空闲、Mac解锁；本批已完成薄封装和视频设计研究，停止于此，不启动视频实现或追加音频功能。

### 版本与职责

- 源起点 `ec7c6eff989dbff501db470838448cc4e793258e`；准备/执行基线 `1d405bda9c838fa016f7acb2fd7cc2a360ec9dc1`。
- P1实现/独立审阅版本 `2b8127c21fc106f3b19157adb3840408ca68b5f2`；Lead文档与保留历史合并后的组合/源实际受测版本 `48d65f8ca76c992c62d4233c343a85d19ed1079b`。源已以固定SHA快进到该版本。完整差异为两份Python实现/测试与六份文档，无Swift、推理算法、运行时、prepare工具、工程/依赖/签名方案改动。
- 普通新App在准备基线构建；App代码、模型清单、provider/vendor到组合版本逐路径相同。两套引擎均由组合版本的入口从当前源码和已安装依赖重建，不使用旧App内的引擎。
- 本次结案提交仅修改获准文档；其自身SHA和最终远端核对写外部 `stage-final-receipt.json`，不把测试记在尚未产生的文档SHA上。

P1为受限独立CLI `gpt-5.6-sol/high`，线程 `01a09928-c585-70b1-8efa-be4d6e85f5ce`：实际turn_context与请求一致，cwd为P1独立工作树，仅该目录及本run的p1/output、p1/tmp可写，network=false，共享Git不授予写入。初次交付完成，无交付后返工，Lead未实质重写实现；Lead审核后代提交。非实现者只读审阅为另一个Sol/high CLI，线程 `01a09936-81aa-70d0-91ba-5a8f83b626b2`，未发现阻断项；该审阅没有运行测试。Lead另行执行下面所有集成、真实命令及产品复验。隐藏服务端解析仍unknown；角色标签不作为质量证明。

### 验收证据

证据根 **R** 为 `/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-AUDIO-CLOSE-VIDEO-01/run-20260913T050442Z`。2026-09-13，M4/16GiB、macOS26.6.2、Xcode26.6/Swift6.3.3，已有外盘Python3.12；实际命令、cwd、解释器、完整版本和退出状态均见各子目录request/result。未下载或安装依赖。

|检查|实际结果与边界|R下证据|
|---|---|---|
|新测试与原音频CPU|新增12、原101，组合及源入口各113方法，零失败/零跳过；是同一集合，不累加成226。两份源码经tokenize.open与内存compile检查，无目标pyc。|cpu-combined、cpu-source、source-validation|
|独立命令反例|成功命令的stderr文字不误判失败；真实自有Python子进程超时后杀组并回收。不是签名服务真实超时或GPU取消证明。|lead-command-checks.py、lead-command-result.json|
|新普通构建|独立DerivedData、离线已解析依赖、既有开发身份，构建exit0（80.24秒）。无XCTest签名例外。|native/build-request.json、build-result.json|
|真实双引擎封装|组合入口9.92秒、源入口9.84秒，均exit0；新副本69个Mach-O组件签名后更新清单；独立codesign和生产BundledAudioEngine resolve/confirmUnchanged通过。初次还逐文件交叉核对两份清单。|package-real、direct-validation、package-source、source-validation|
|普通沙盒真实生成|隔离新包SA3生成6秒一次；MRT2生成4秒两次；三个float32双声道WAV独立解析、帧数/采样率/有限数/摘要与记录相符。|gui/observations.json、real-validation.json|
|取消和下一任务|一次MRT2任务确实取消，无已发布资产；同会话seed43的新任务成功。未测精确GPU内核中断时点。另一次拟取消任务已先完成，按成功计，不冒充取消。|gui/real-validation.json及测试项目Tasks|
|候选/持久化|播放入口、采用/拒绝、保存、正常退出重开；文档/任务/资产相同，SA3/MRT2模型恢复校验，音符/seed和候选状态保留。|gui/before-reopen.json、observations.json、real-validation.json、reopen/exit.json|

真实运行包为 `R/artifacts/D Audio Closure.app`；源入口第二次封装为 `R/artifacts/source-entry/D.app`，后者只做清单/签名/resolve路径复验，没有重复GPU/GUI。真实运行用相同生产代码和资源，区别清楚保留。普通D从未替换。`D_UI_TEST_SESSION`只隔离设置和测试项目索引，无后端测试覆盖；测试项目为 `R/gui/projects/音频封装回归 🎹.dproject`。

实际SA3参数：固定revision `da6edc54ddba10bfd79a077102ded687f80e882b`，6秒/seed42/8步/guidance1，输出44100Hz/264600帧；MLX峰值约1.61GB、最终active18B/cache0。MRT2固定revision `010aa0dcb0dfd27b24f0ad07b4dad63e8f9521cc`，small-export、4秒/C4-D4-G4/seed42与43，48000Hz/192000帧；两次首PCM1.23/0.79秒、总5.60/5.27秒，MLX峰值约0.528GB、进程峰值RSS约1.52GB、清理后active8B/cache0。计量口径不同，不把这些值相加或据此宣称无泄漏；固定图内部精度仍unknown。完整参数、阶段、清理、输出摘要在real-validation及原始运行记录。

SA3变体/重绘与安全导出沿用上阶段未改实现的已验收证据，本批不重跑并冒称新增通过；图文代码不变，没有全模型回归。未新增真人音质判定、GUI XCTest、麦克风、公证、TCC持续性或其他Mac验证。此前用户“正常钢琴但背景类似沙锤”反馈保持，音符条件精确传递不等于声音精确服从。

### 失败、环境事件与来源口径

1. P1初交前一个符号链接夹具错误地创建绝对目标，第一次新测试11/12；修正夹具为预期内部相对链接后12/12。其他校验加固也在初交内完成，不计作Lead第三方修补。
2. P1尝试删除自己tmp中的pyc，执行工具在启动前拒绝rm命令；Worker停报且未重试/提权。三份受控pyc夹具留在授权目录，不清理以追求表面干净。关键词扫描的其他命中是测试/源码文本，不等同实际权限事故。原事件与可观察权限证据保存在p1，不追溯改写。
3. Lead首次选MRT2父目录，缺models/resources，界面明确拒绝且未提交任务；纠正为已有 `magenta-rt-v2` 根后通过。属于测试操作错误，不归给Worker实现。
4. 正常退出后调用CUA状态查询自动重启了同一隔离产物；该实例环境未核验、没有打开用户项目或执行模型，立即正常退出。之后显式使用原隔离UUID启动并完成重开。普通D路径未启动。经验：退出后只核对持有的进程句柄/退出记录，不再调用可能重新启动App的状态API。详情gui/auto-relaunch-event.json；不声称自动实例的环境或用户偏好逐字节已验证。
5. 集成只读预检最初未识别本机Git帮助的 `--[no-]` 呈现方式；核对本机帮助后修正证据检查，无Git写入、契约或代码改动。最终祖先、路径、hooks/attributes、碰撞和保护门槛通过后才快进。

可观察CLI预检100.55秒、实现686.81秒、只读审阅268.65秒。usage-observed.json逐条保存本批turn.completed字段，不累加可能重叠的会话累计快照；缓存输入是总输入的子集，不能再加一次。完整Lead归因、订阅实际费用和经济性仍unknown；本样本只证明此明确规格下可交付，不认定Sol适合所有后端。来源为Sol初次实现、独立Sol只读检查、Astra Lead契约/文档/实际验证与集成。

### 恢复与下一动作

源 `codex/inference-foundation` 已接纳上述受测组合；后续仅结案文档，最终完整HEAD与push状态查R/stage-final-receipt.json。源scheme仍为唯一未暂存修改，SHA256 `ca3635d88aa5a15397b90e528667c66c0e6db7e596176e885c79d194b544206c`，原索引blob/diff保持；普通D四个关键文件及新构建输入41文件的摘要/大小/mtime未变。保护快照在protection及integration，不建立系统写锁，不删除任何工作树/旧证据。

P1、只读审阅、构建/CPU/封装和本批应用均结束；两个显式启动的App有exit0，自动重启实例另有定点退出记录。无后续后台任务。恢复先检查实际HEAD/个人修改/进程，再按[视频设计](../VIDEO_BACKEND_DESIGN.zh-CN.md)签发V0：先确认完整文本编码器的精度/内存和固定依赖，再做短静音视频后端；新增权重/依赖具体授权另行。H09设备继续保留，歌声/HUM/TTS不阻塞V0。本任务不等于音频全部远期功能或视频已交付。
