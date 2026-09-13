# D-AUDIO-CLOSE-VIDEO-01：音频薄封装收尾与视频后端研究

状态：准备，尚未接纳。日期：2026-09-13。规格 close-r1 / contract packaging-r1。
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
