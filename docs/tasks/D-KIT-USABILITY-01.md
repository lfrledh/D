# D-KIT-USABILITY-01：现场返回后的有限可用性修补

状态：准备；spec_revision=1，contract_revision=1。用户于2026-09-12明确要求改善测试脚本提示／交互，然后继续既定受控音乐路线。源基线 `d6623fd5e9308893f99ecf1b54b5c2c0f7e17c87`；执行基线为本规格准备提交的完整 SHA，由派工记录提供，不自引用。

现场证据索引：`D-Development/AgentTrials/D-PORTABLE-KIT-01/run-20260912T142949Z-field-review/field-review-receipt.json`及同目录现场报告。8次现场运行、32条通过覆盖24个不同case；72B确已加载/少量输出，用户手动中断；音频1.516秒先完成，3秒定时取消未命中。历史结果不重写。本批不是旧未验收候选继续循环修复：旧runner/probe试点的失败与修复预算保留；已接纳交付后的新现场问题和用户新增UX请求单列本批。

## 目标、范围与所有权

目标：非技术用户能理解将测什么、当前在做什么、等待多久、如何停止、结果在哪里及哪些没测到；中断保存可取得的诊断；音频取消在真实计算阶段触发。保持后端、模型、精度、产物安全和既有判定，不因为机器预算而跳过probe。

非目标：产品UI/后端重写、完整监控平台、模型下载、音乐模型实施、修改Mac权限、重建原生CLI。无GUI，不关闭普通D。音乐条件后端由Lead另行按原路线核实许可/固定资源与契约。

一个受限独立CLI Worker，Sol/high（现有可观察且允许型号；进程/流读取和中断清理高于简单文案风险），最多初交＋两次定向修复。Lead单一规格、profile、封装、审核、真实小模型、源接纳与文档维护。Worker不得递归派工，不写公共Git元数据，不commit。

Worker允许路径严格为：
- `tools/testkit/d_testkit.py`
- `tools/testkit/tests/test_runner.py`
- `tools/testkit/README.zh-CN.md`
- `tools/testkit/build_kit.py`（仅现有launcher的中文提示/结束操作文字，不改复制、摘要、路径或打包行为）
- `tools/testkit/tests/test_runner.py` 内可补 launcher 文案检查；已有 `test_packaging.py` 只读/运行。准备规格误写为 test_builder.py，repair1 已澄清，不要求额外建文件。

Lead拥有`Profiles/profiles.json`、本任务记录、CURRENT_ACTIONS/目标/人工清单和外部封装输出。Worker不能修改这些文件、Swift/后端/应用/工程/依赖/签名/模型/原SSD包/Results/个人scheme。不得用全库格式化或删除断言消除失败。

## 冻结行为

1. menu默认输出简明中文，不在最后倾倒完整JSON；`preflight/run/summarize`现有机器JSON stdout兼容，运行过程提示走stderr。保留七组ID和顺序，但中文解释内容/重叠/建议顺序，明示组名不代表机器实际内存。显示系统芯片、物理内存以及推荐值是参考（不是可用内存保证）。可按q退出；无效菜单输入应提示重新选，不直接堆栈退出。开始须明确输入s/开始/RUN等可读确认，不把回车等同同意运行大模型。不要自动连续运行多组。
2. 不先校验全部83GB才显示菜单。先显示不加载模型的硬件/菜单信息，选中后由已有preflight只校验所选模型。校验每模型/大文件时给阶段及完成数/字节或限频心跳，读一次不能跳过hash；不得把hash进度当推理百分比。
3. 开始显示[第几项/共几项]、中文标题和实际参数摘要、结果目录、停止方法。运行期间至多每5秒心跳，至少能显示已等待时间/是否收到模型进度或文字/正在取消与清理。只解读已存在的日志格式；没有明确阶段时说“后端运行中，尚未报告生成进度”，不能杜撰加载百分比、剩余时间或把静默说成卡死。保留原日志，实时提示不泄露完整prompt和文件内容、不直通任意ANSI/控制字符。监控不打开网络、不改变内存参数。
4. KeyboardInterrupt清理后仍必须持久化已有父进程结果（returnCode、signal、超时、取消、强停、RSS样本、流信息）；之后把中断传回run。异常分支也要保留已有CLI错误/部分输出诊断，不能吞异常显示成功。维持有界回收，只管理自有进程。结果自身无法写盘时明确失败，不能声称证据已保存。不要用os._exit或改变全局信号/权限过测。
5. 新中断run只将当时已启动项标为interrupted，后项标`not_started_after_interruption`。旧run在显式summarize时可依据已存在case证据正确投影，保留原case/run/attempt；本批不调用summarize覆盖原现场记录。不能把没有case文件等同执行过；损坏状态仍按原契约拒绝或显式invalid。summary/HTML/中文结尾显示通过、失败、主动中断、未启动及原因，保留机器状态名/原始诊断、路径脱敏和HTML转义。通过标准不变。
6. 新可选case字段`cancelWhen`只允许字符串`audio_denoising_started`，只适用于capability=audio且expected=cancelled，必须与cancelAfterSeconds互斥。原定时字段向后兼容。Lead会单独把audio-cancel6改为新字段，仍为原small6秒/8步/精度，Worker不要改profiles。
7. 该触发器基于当前原生CLI实际stderr格式`[UUID] progress completed/total`，total等于当前请求steps且`1 <= completed < total`时，说明已有一轮去噪进度。必须使用有界行缓冲和严格数值/格式，忽略不匹配或过长行；通过事件唤醒拥有子进程的监控立即请求取消，不靠原0.5秒轮询等待错过整个短生成。流读取线程不私自管理其他进程，不由日志注入任意动作。它只是已声明取消case的执行触发，不能作为生成通过证据。记录触发类型/是否观察/是否发出，验证仍沿用CLI终态/退出/清理/无产物要求。
8. 若真实生成在发取消前已完成，保持该取消用例未通过，并明确“生成已先完成，本次未测到取消”；不能把完成当取消、自动重试或提高模型精度/时长。未观察到去噪时不得伪称取消阶段命中；总超时仍有效。触发器的原生假设由Lead以实际CLI复核，日志文本只是触发信号。
9. 结束只给中文结果概览、耗时、当前结果位置、下一步（可重开入口选另一组/带回Results/等待清理后推出SSD），质量待人工确认。机器命令退出规则保留，人工中断不能改成complete。无效输入、文件保护、超时、OOM未知语义不降低。

## 输入资料与验证

必读本规格、AGENTS不可破坏边界、目标runner及对应测试。不要加载全项目历史。相关原生stderr样例只需已知格式，不读模型/其他run私有日志：`Run 1/1: UUID`、`[UUID] progress 1/8`、文字stdout分块。README需同步真实交互与现场发现，不宣称48GB实测（多处系统记录为36GiB，用户说48保留差异）。

Worker语法检查用tokenize.open后内存compile(source,filename,'exec',dont_inherit=True)，不exec目标、不默认py_compile。行为测试使用既有Python3.12 `/Volumes/CodexProjects/D-TestKit/Runtime/AudioEngine.dengine/python/bin/python3`、`-B`；D_TEST_TEMP_DIR/TMPDIR/PYTHONPYCACHEPREFIX唯一固定到本run worker/tmp。预授权仅这一缓存路径，不准扩大/更换权限。旧55 runner＋5 builder方法应继续通过，新增CPU覆盖：

- menu先显示选择再做选中模型校验；q/无效输入/确认取消/正常结束可懂且不输出JSON墙；machine run保留JSON。
- 长静默假CLI能在结束前观察心跳；日志含分片UTF8/超长行/控制字符时有界；原始流与结果仍匹配。
- 真正的runner CLI子进程收到SIGINT后完整退出：process记录存在、已有失败/部分CLI报告可取得；后项未启动而非interrupted；旧中断摘要回读有证据地兼容；不修改旧原件。
- 受控CPU进度fakeCLI触发取消且已发出；其他阶段/完成末帧/恶意日志不触发；提前完成明确未覆盖；字段类型/组合非法拒绝；旧时间取消仍过。
- 保留原退出码、文本换行、模型/输出校验、拒绝覆盖、原件保护、ZIP脱敏和HTML转义测试，不改既有黄金数据以掩盖问题。

Lead在Worker停写后独立review；使用隔离新kit/独立Results，串行真实quick/reliability和CLI兼容（当前资源确认后），验证取消在去噪阶段、后续任务、手动中断保存及中文有空格路径。32B/72B不在本机运行，旧现场证据只读。发布新版包前保留原包/Results封存；部署仅已核验任务文件/程序，不改模型或普通D；旧结果仍可定位。源只接纳具体已测组合，再按本轮授权推送工作分支，不改main/master。

Worker预检先返回物理目录/Git根/common/HEAD/分支/规格/允许路径/验收；Lead从实际turn_context核对Sol/high与workspace-write、network=false、仅本树/output/tmp可写再发IMPLEMENT。意外权限拒绝/不明副作用停报，预期失败夹具按测试记录；每轮修复前审核异常。全过程每次子执行≤15分钟；Lead只回收自有句柄。

恢复点：源仍上述基线，个人scheme唯一未暂存差异；原包及现场Results未动。先规格准备提交→受限Worker→Lead复核／封装／真实验证。下一产品准备按MUSIC_ROADMAP顶部条件控制入口；新资源/依赖须单独具体确认，不用SA3冒称支持精确音符。

## 2026-09-13 执行中检查点

准备基线54f57fc4be01c91ece018ddd5dfa19a4f62e9037；受限Runner Worker Sol/high线程01a09619-5532-7350-ac03-87bf162fd07e，cwd与workspace-write/network=false已从实际turn_context核对，隐藏服务端解析unknown。run-20260912T144755Z/worker保留请求、观察及事件。初交900秒到时由本任务包装器回收，未报告完成；已写四个获准文件，Lead复验65方法中两项即时去噪取消超时，其余63项通过。原因是默认缓冲pipe的read(65536)等待，不是模型失败或新权限。修复1已给出此反例、事件唤醒竞态及未补齐的原冻结菜单/中断/心跳/历史投影测试要求，未改通过标准；普通修复余量在本轮后还剩1。前轮只观察到补丁包装解析失败，无权限扩大事件。

Lead单独修改profile中文标题，以及audio-cancel6使用已冻结cancelWhen，其他生成/模型/精度参数不变。源d6623fd及个人scheme仍保持，原包Results保留671个文件的起始摘要；普通D关键文件单列保护快照。尚未接纳或发布新版包。一次Lead文档追加的系统Python脚本解析失败，未修改文档；随后以文件补丁写入。profile独立提交e168f17已完成，不能把未执行的文档更新混入该提交描述。

## 2026-09-13 有限实现与制作验收

状态：工具候选已通过制作验收，待本批源接纳／发布；不覆盖下面历史停点。实际受测组合 `ec0dcdd0ab2fb55e0b0cb1a027ccfcb35d7c2b5d`，Worker交付 `b933518bacbb9c3a59bd4d40b6b9812d9ce863be`。四个Worker文件、Lead profile与手册组合经Astra Lead非实施者代码检查，73个CPU方法通过（runner68＋builder5）；未改动原生CLI另做30个兼容CPU场景通过，不称重新构建后端。

真实新版包在M4/16GiB串行验证：quick 3/3（faf7fc8b-0cd5-446d-91db-099ae767cc9a），reliability 8/8（da94f288-b823-4dda-88ae-959017734182）；audio-cancel6观察到去噪并已发取消，退出130、无发布音频，后继新进程通过。真实手动SIGINT回收退出130，当前项interrupted、余7项not_started_after_interruption（563a31b3-44e4-4b06-adbe-5b17753b34b7）；不能计作8个执行通过。中文空格独立APFS副本2178个非模型文件摘要/不同inode核对，旧中断结果回读脱敏通过，新quick 3/3（a301157e-67b9-4948-a95b-c0f598a42810）。PNG实际解码、WAV帧/有限PCM、重绘2..4秒之外PCM相同、ZIP排除私有路径另行核对。媒体艺术质量未重新真人确认。

修复历史保留：初交900.022秒被本任务有界包装器结束；repair1 556.553秒修正管道缓冲与事件唤醒，Lead70方法通过后独立旧结果反例仍失败（未索引但已完成case被当未启动）；repair2 310.128秒修正有界证据回读，Lead73方法通过。新分片日志夹具原有调度竞态经明确等待修正，重复5/5与全套通过；没有降低真实取消条件。普通修复剩0。一次Worker ps被沙箱拒绝后停止并报告，无扩大权限；只依据自有进程回执确认结束。Lead为规格、反例、profile/说明及独立验收，没有把runner实现代写后归给Worker。

请求及可观察运行均Sol/high、独立workspace-write写根、网络关闭，原始路由/异常/回合回执见run/worker。初交无turn.completed用量；后两回合usage作为原始快照保存，可能含同会话累计，不相加。缓存输入不额外加到总输入，完整Lead消耗与订阅费用unknown；本样本不证明模型性价比最优。Lead另有两次只读分析脚本误写字段名/空值导致异常，修正分析后原媒体检查通过，不改产品测试断言。

证据根：`D-Development/AgentTrials/D-KIT-USABILITY-01/run-20260912T144755Z`。入口：cpu/combined-kit.log、cpu/native-cli-compat.log、real-quick/real-reliability/real-interrupt/real-relocated各process.json、real-special-checks.json、independent-media/result.json、relocation.json、protection-before-integration.json、collaboration-accounting.json。制作包sourceSHA为ec0dcdd，原生二进制仍对应f743909647c83cb99d4d9f0dee0a939f80388576；依赖与精度未变化。本次没有在16GiB加载32B/72B。普通D、源个人scheme及原671个Results文件内容/大小/mtime核验保持；旧包保留，发布位置与最终源SHA另写收尾回执，不提前声明推送。
