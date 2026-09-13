# 音频后端与跨配置验证指南

## 2026-09-13 薄封装入口（本批验收结果见任务记录）

后端公共接口已满足当前音频有限出口，不增加通用编辑或工作流框架。新入口 `Backends/Audio/Packaging/package_audio_app.py` 只编排两个既有准备器：从**当前源码**与已安装Python/依赖重建SA3和MRT2引擎，附入普通构建的**新副本**，沿用输入开发签名/entitlements，并校验后独占发布。它不使用旧阶段App里的引擎副本，不下载模型或依赖，不修改原始App；plain build-local仍只编译，不暗中触发签名封装。

开发者步骤：

1. 用现有 `scripts/build-local.sh` 普通构建；验收产物设置独立的 `D_DEVELOPMENT_ROOT` 和现有 `D_SIGNING_CONFIG`，依赖使用已有离线副本。不要向用户正在使用的普通D目录构建。
2. 准备已安装的Python3.12根和两套site-packages；MRT2固定依赖版本由prepare_mrt2_engine.py验证，SA3保持原验证配置。输出父目录须已存在，输出.app不得存在；不要混用两套MLX或改变精度。
3. 在仓库根执行下面入口，参数均为本机显式绝对路径。IDENTITY是已获准的现有开发证书指纹；不要把私钥、账号或机器路径提交Git。此步骤会正常使用既有签名服务，不能把它交给仅允许CPU的Worker。

```sh
python3 -B Backends/Audio/Packaging/package_audio_app.py \
  --app "$INPUT_APP" \
  --python-root "$PYTHON_ROOT" \
  --sa3-site-packages "$SA3_SITE_PACKAGES" \
  --mrt2-site-packages "$MRT2_SITE_PACKAGES" \
  --identity "$EXISTING_IDENTITY" \
  --output "$NEW_OUTPUT_APP"
```

成功0、输入/封装/命令/验证或报告错误2；观察完整进程结束。失败不覆盖输入或既有目标，不能通过移除沙盒、放宽manifest或覆盖旧包来解决。报告成功只证明封装、清单和签名检查，**不证明**本机推理、Gatekeeper、公证、TCC、录音或其他Mac部署。最后应从新包普通路径验证两套引擎；精度、生成参数和取消释放沿用既有验收。目录变动时重新给出依赖路径，不从旧trial绝对路径猜测恢复。

本机本批的实际命令、输入/输出保护、具体受测版本及真实回归见 [D-AUDIO-CLOSE-VIDEO-01](tasks/D-AUDIO-CLOSE-VIDEO-01.md)。外部持久证据保留所用依赖/解释器路径，不把它们写死在脚本中。推理模型权重另由模型安装/授权管理，不塞入App。以下旧封装手法是历史；新入口不把旧候选产物作为源。

## MRT2短旋律工作台使用（2026-09-13）

已验证隔离应用：`D-Development/AgentTrials/D-MRT2-WORKBENCH-01/run-20260912T163022Z-implementation/deployment-v3/signed-app/D.app`。App代码c202a7548998cade6c2d1284625c33605fe16f9a，内嵌MRT2资源33f1f0a4fa575fe27dec67c25bb02f79fd21d605（其后相关资源未变）。普通D未替换；这是开发签名产物，不是公证安装包。

1. 打开或新建项目，顶部选“音频”，新建一份没有参考原声的声音创作。右侧创作类型选“旋律器乐（MRT2）”。
2. “选择模型”指定已有固定MRT2模型根（本机为`D-Development/Models/Magenta-RealTime-2-small/magenta-rt-v2`），其中须有models与resources。无需重复下载；已有书签会在重开时校验恢复。
3. 填风格、时长、seed和音符，或使用“示例”。例如4秒，C4开始0/持续1.2、E4开始1.2/持续1.2、G4开始2.4/持续1.2。时间必须是0.04秒的整数倍，不暗自取整；当前profile最多16秒/512个音符，seed为0…4294967295。输入错误会保留并说明，生成按钮不会忽略非法字段。参数面板可滚动。
4. 生成后先试听，再决定采用/拒绝；修改音符后生成的是新的完整候选，原候选保留。拒绝已采用候选会清除采用，恢复被拒绝候选不会自动重新采用。保存后正常退出，重开项目恢复条件、候选及采用状态；导出WAV不会覆盖同名文件。

高级条件文件只含有版本的音符/时长/时间基，不导出风格提示、模型绝对路径、书签或开发记录。导入替换当前条件并保留提示与seed；文件未知字段/坏版本、超界等明确拒绝。缺省音符条件和显式空列表含义不同，均不保证静音。“按旋律生成”的普通入口需要音符。

输出为48kHz双声道float32 WAV；固定图内精度unknown且存在上游int16转换，不称全FP32。声音服从近似：即使提示no drums，本次用户仍听到类似沙锤背景声；不承诺纯钢琴、严格和弦、分轨、歌词演唱或区外波形不变。原SA3仍是独立环境/44.1kHz/原精度，提供提示、兼容WAV参考变体和帧区间重绘。两者共用重任务许可，取消后等待真实退出/清理，再运行下一任务。

### MRT2离线封装

plain `build-local.sh`不自动安装依赖或打包音乐。使用`Backends/Audio/Packaging/prepare_mrt2_engine.py`，显式传入已批准`--python-root`、`--site-packages`、`--provider-directory`（Backends/Audio/Python）、`--vendor-directory`（Backends/Audio/MRT2Vendor）、`--model-manifests`（Backends/Audio/Models）和不存在的`--output`。它只复制固定Python3.12/MLX0.31.1/LiteRT2.2.0等依赖闭包与来源许可证，不下载、签名、加载模型或证明运行通过。输出复制到专属应用的`Contents/Resources/MRT2MusicEngine.dengine`，原SA3的AudioEngine.dengine可并存。

沿用下方原封装/逐个Mach-O签名/更新签名后摘要/外层签名与验证顺序，不放宽库校验；不得照搬另一机器的私人签名identity。完整本机输入、命令和清单见本批deployment-v2/pack.json及deployment-v2/signed-app/commands.json；最终App复制已签好的42个native音乐组件并重新按既有身份签署自己的外层，不改原引擎。权重不入App/Git，商业分发/许可证审计另行。实际部署/普通沙盒生成和恢复证据见[任务结案](tasks/D-MRT2-WORKBENCH-01.md#2026-09-13-阶段验收与本地接纳)。

## APP1 工作台验收（2026-09-12）

普通开发签名/沙盒的内嵌引擎版已经真实运行SA3 small，无D_AUDIO_BACKEND_CONFIGURATION或D_AUDIO_WORKBENCH_TEST覆盖。D_UI_TEST_SESSION只隔离测试设置/项目索引；引擎启用走生产Bundle解析。项目保存/重开、模型恢复后再次生成、WAV导入变体、候选采用拒绝、不覆盖导出已验证；详情及当前版本见[APP1任务](tasks/D-AUDIO-APP-01.md)。源受测 `dd530e320df3fecaa3d23421151c000d384c652a`；下文旧“普通应用未启用/依赖尚缺”仅代表历史。

当前交付物位于外盘 `D-Development/AgentTrials/D-AUDIO-APP-01/run-20260911T155257Z-app-resume/deployment/signed-app/D.app`，普通D未替换。保持SA3固定revision、FP16 DiT/T5与FP32编解码/主文件；本机6秒是测试配置，不是所有Mac上限。源CPU和真实GUI/GPU分列，Tk、公证、长期TCC/高配型号及麦克风不由本结果证明。

## 应用内引擎的重建与保护

`./scripts/build-local.sh`仍只构建应用，不自动安装或嵌入Python依赖。普通Bundle仅在`Contents/Resources/AudioEngine.dengine/engine.json`完整校验通过后启用文件输入音频；缺失时保留图文，损坏时显示音频问题，不自动调用外部全访问服务。当前支持已装CPython3.12 arm64源，输入依赖必须事先获准。

离线封装入口如下，五个输入路径和一个输出路径须显式提供，输出必须不存在；这是构建准备命令，不是签名或验收器：

```sh
"$D_ENGINE_PYTHON_ROOT/bin/python3.12" -B Backends/Audio/Packaging/prepare_engine.py \
  --python-root "$D_ENGINE_PYTHON_ROOT" \
  --site-packages "$D_ENGINE_SITE_PACKAGES" \
  --provider-directory "$PWD/Backends/Audio/Python" \
  --vendor-directory "$PWD/Vendor/stable-audio3-mlx" \
  --model-manifests "$PWD/Backends/Audio/Models" \
  --output "$D_ENGINE_OUTPUT"
```

本机通过的源为已安装基础Python3.12.14和独立`D-Audio-SA3-20260909T152406Z-copies`环境；完整输入路径/命令、输出清单见上述run的`deployment/pack-result.json`。打包保留Python/依赖许可证与固定Vendor，不含权重、用户书签或私有素材；完整商业分发审计另行进行。

部署顺序须保持：正常构建 → 复制到不存在的专属D.app → 将封装复制到固定Resources路径 → 按原构建批准的identity逐个签署清单里的Mach-O（本机27个，`-o runtime --timestamp=none`，不是用文件扩展名猜） → 仅重算这些实际签名副本的sizeBytes/sha256并更新engine.json → 用原构建xcent与同identity签署外层App → deep/strict校验、实际Bundle resolver全文件摘要核对及entitlements与原构建对照。不要改原Python/普通App，不把签名前摘要称作签名后摘要，不用`codesign --deep --force`代替逐层处理。具体可复核命令/签名输入与脚本在run的`deployment/signed-app/commands.json`、`run-tools/d-audio-app-resume-sign.py`；这些是本机执行证据，迁移机器需提供该机明确获准的路径/身份，不能照搬个人identity。

封装产物约266MB，不进入Git；新建输出目录保留历史。应用实际从原生面板登记已许可固定模型，动态访问清单只放自有容器0700目录/0600文件，子进程实际退出后回收，不进入项目/媒体来源。普通运行不要求用户手填调试环境变量。当前没有一键跨机器安装器或通用Python插件系统。

## 最新实测与接纳（2026-09-10）

音频后端/CLI现已本地接入源工作分支，实际受测59c3225f3b48ecc6f4fd26e94463d6787b8ec116；旧“真实音频/许可未就绪”段落仅为此前状态。现有独立--copies环境与已授权small music权重已真实完成6秒生成/变体/区间重绘、取消和超时后恢复；人耳样本正常。源CLI输出44.1kHz双声道float32 WAV，调用参数/模型版本与产物记录一致，详见批次最新节。用户普通D未替换，音频生成工作台和录音仍未交付。

Qwen1.5B除登记外已完成2次短改写及同Runtime两次取消/释放，7/32B未本机验收。SA3 medium/SFX和长时音频仍是已登记/待实测，不把small6秒当产品上限；固定精度未变。新管道是有界独立读队列，排空与真实退出后交接。MLX子进程内清理后仍有18bytes未解释，缓存0，子进程已结束；不得称常驻无泄漏或拿估算当实测。

状态：D-AUDIO-BACKEND-01 组合工程验证通过的候选，2026-09-10；真实音频仍待验收。CPU/编译、真实模型和产品界面分开验收；实时结果见 [批次记录](tasks/D-AUDIO-BACKEND-01.md)。本文不是模型已经出声或普通应用已经启用音频生成的声明。

## 后端能接受什么

| 操作 | 输入 | 结果及边界 |
| --- | --- | --- |
| generate | 提示、时长、seed、步数、guidance | 新音频候选；无输入音频，不接受编辑区间 |
| variation | 原音频的固定摘要/帧数，加提示与强度 | 近似参考变体，不保证逐音符/和声/歌词服从 |
| inpaint | 同一原音频，加半开采样帧区间 | 区间内重绘，区外保留源 PCM 显式转换到 float32 后的值；第一版无接缝淡化 |

所有结果为44.1kHz、双声道、有限数值的float32 WAV主文件。输入编辑音频仅接受对应采样率/通道的RIFF/WAVE int16/int24/int32/float32；不静默转采样率或混声道。int32转float32可能舍入，原文件完整保留；不能把这种输出称作原始int32逐位相同。区间坐标属于原文件采样帧，不是字节、秒或模型latent。模型latent遮罩可覆盖更宽范围，记录两种区间。

生成输出帧数按durationSeconds×44100四舍到最近偶数；编辑输出以已验证source.frameCount为准，时长只允许现有半帧容差。模型内部仍按4096采样的latent时基处理。提示先经过固定tokenizer检查，超过模型256token限制拒绝，不暗中截断。未支持谱面、MIDI、精确歌词/歌声/和弦控制；这些不能伪装成已有字段或自动转普通提示。

## 执行及文件所有权

DInference只传AudioRequest及文件引用；DRuntime负责排队、预算、取消/结束；DMLXBackend的MLXAudioBackend持有进程级重推理许可并管理一个明确配置的本地Python子进程。Python适配器按阶段加载SA3模型，计算后返回WAV和执行快照。不是网络服务，不自动找模型/解释器/下载器。

显式配置解释器、provider脚本、已固定Vendor目录、模型目录及manifest、artifact根目录和profile。调用者仅在确已拥有模型使用权时提供licenseAcknowledged；布尔参数不替代法律登记。每个任务建立独立run目录，request.json在job之外；job内仅有必要frozen-source.wav、output.wav、result.json及自有发布临时文件。新结果不覆盖既有文件，后端release不删除发布作品或扫描根目录。result.json是私有执行记录，不是已经实现的媒体内嵌来源标准。

子进程仅接收最小环境与自有缓存/临时目录；stdout是有大小限制的JSONL，stderr独立消费。成功要求实际进程退出、管道消费完毕、唯一正确终态、WAV与记录独立校验；输出异常不能由main返回值冒充进程成功。取消先等当前运算退出，超时只终止自有子进程，释放后下个重任务才能开始。此控制并不证明模型长期内存完全无泄漏；仍要真实重复/失败/取消测量。

开发入口为Backends/Audio/Python/d_audio_backend.py，参数见--help及[适配规格](tasks/D-AUDIO-SA3-01.md)。--inspect只做固定文件/元数据校验，仍要求完整显式路径及真实已安装权重；不加载MLX。统一CLI入口及参数见DInferenceCLI --help和[运行时规格](tasks/D-AUDIO-RUNTIME-01.md)。未获许可或依赖/资源不满足时不要尝试真实生成；假provider仅用于CPU契约测试。

## 模型和机器是两个维度

| 范围 | 本次配置 | 已证明与待证明 |
| --- | --- | --- |
| 文字 | Qwen2.5 0.5/1.5/7/32B Instruct，均4-bit，各固定revision/完整摘要 | 0.5B有本次组合10类CLI真实回归及CPU文件检查；其余登记不是已安装、可装入内存或质量验证 |
| 图像 | 原verified512默认不变；显式scalableKlein4B允许256…2048的32倍数轴，最大2048² | CPU形状/拒绝规则已测，512²与一次768×512已在M4实测；1024/2048仍待测；不是FLUX9B/任意模型兼容 |
| 音频 | SA3 sm-music/sm-sfx上限120秒，medium上限380秒 | 模型能力上限不是当前M4上的性能承诺；本机首测6秒/8步/seed42，不写成产品上限 |
| 资源 | 基于主机物理内存预留max(4GiB,四分之一)，剩余作为预算上界 | 16/32/64/128GiB政策测试为12/24/48/96GiB；不是实时可用内存或不会OOM的保证 |

SA3使用FP16 DiT/T5、FP32编码器/解码器与主文件；图像q8和文字4-bit未降低。small每profile四个权重合计1,919,674,322字节；medium6,883,369,494字节，均不等于运行峰值。音频估算为2×最大组件权重+1GiB+ceil(秒)×64MiB，明确未校准。图像估算和可变cache同样需实测余量；不以统一内存容量替代带宽、系统负载、KV/工作区与延迟。

将来高配Mac验收使用同一代码SHA/固定模型revision、文件清单摘要、profile、精度和实际参数，单独记录OS/芯片/内存、运行ID、冷启动/首音、耗时/吞吐、峰值和取消释放、输出摘要及人工听感/控制服从。先拒绝超预算，不偷偷缩模型/时长/分辨率或降精度。参数配置已实现、CPU已测、该机器实测和面向用户交付分别登记。Apple Silicon MLX路径不代表Intel Mac后端已完成。

## 真实验收尚需的门槛

权重/依赖只能在授权范围获取并验证；固定MIT源码与Stability/Gemma模型条款分开，详见人工清单H11。当前已知Python环境缺mlx和sentencepiece；不在本批默默修改全局解释器。H13已获本轮空闲确认并完成图文实测；H11及独立环境就绪后，先单任务6秒生成，独立读WAV/参数，随后参考变体、区间重绘和区外逐采样检查、重复运行、取消后交接、失效输入/失败恢复。人耳听感和接缝质量独立记录，不能用合法WAV替代音乐质量。模型许可、资源或安装未满足时只保留候选，不启用普通工作台新路径。

后续产品位置：真实后端通过后，接已有候选比较/采用与安全作品保存；再依据模型确实支持的条件推进HUM/谱面控制和独立歌声里程碑，TTS单列。传统DAW和文字高级功能不是前置。[音乐路线](MUSIC_ROADMAP.zh-CN.md)维护详细目标。

## 独立解释器部署检查（2026-09-10 实测）

当前启动器会解析Python可执行文件符号链接。标准venv的符号链接因此可能指向基础解释器，丢失该venv依赖；已在本机确认首个请求报No module named mlx。配置使用标准`venv --copies`建立的独立环境，并在与子进程相同最小环境下核对sys.prefix及依赖发现；不能往全局Python安装或以任意PYTHONPATH掩盖。两份环境/失败证据保留。当前复制环境CPU --inspect通过，真实重试仍待资源恢复；不是模型数值或性能验收。记录见同日批次检查点。
