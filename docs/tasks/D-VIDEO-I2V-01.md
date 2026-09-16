# D-VIDEO-I2V-01：首图条件短视频薄后端

2026-09-15，I2V1/spec2（spec1历史保留）。状态：用户已批准Lead按整体目标选择可独立推进的下一阶段；候选实现与正式运行已有证据，但真实画面存在严重彩色条带；质量阻塞，未验收/未源代码接纳。源基线 f6ca90b37a1134bdc6f41912cd5d5fb5173094aa，源分支 codex/inference-foundation。Lead集成树 D-Worktrees/D-VIDEO-I2V-01，分支 codex/d-video-i2v-01；共同准备SHA由各job记录。证据R=`D-Development/AgentTrials/D-VIDEO-I2V-01/run-20260915T103902Z`。

## 阶段目标与边界

### I2V1/spec2：实际性能发现后的有界Lead资源接管

spec1及其失败历史不倒改。RUN的Sol初交＋两轮普通修复结束；解析器与spool/引用缺陷均通过独立复核。随后50步/17帧实测出现101/139秒单步；Lead有序取消，子进程130、无强杀、active18/cache0、255输入不变；**没有把该次写成完成50步**。一次明确标为实验的10GiB进程驻留对照在同几何/模型/精度的2步约2.90/3.00秒，完整148.14秒，首帧差0；不从单次A/B断言全部换页根因或所有机器加速比。

在本阶段资源/生命周期目标内，Lead接管一次有限完善：增加可选执行选项 `--resident-memory-bytes` 与对应run keyword，不属于第三轮Sol修复，不改变采样、权重、精度、尺寸/步数验收。省略时沿用库的现有驻留设置（实际值unknown，不伪写0）；显式非负整数须不超过请求allocation指导及当前MLX设备推荐，严格小于总内存。超出仅拒绝该驻留选项，不能据此宣布模型不能在该Mac运行。设置/同步/恢复仅当前子进程的MLX API，不触碰sysctl/系统权限；不暗改用户值或提升系统上限。

结果增加executionMemory，区分调用者显式驻留字节、实际设置前值、设备推荐及allocation指导；默认继承不伪造已知值。设置作用域包住原执行体，正常/取消/失败都同步并恢复旧值，恢复失败保留原始异常关联。先已验证文件，再完成恢复，最后stdout终态；恢复/通知失败返回失败但不删除已验证媒体。额外读取的请求必须与实际执行绑定，不能让前验和执行使用不同请求版本。

新增独立CPU反例覆盖省略不触发设置、0/正数、布尔/负数/超过调用预算及设备限值、实际设置失败、成功/取消/异常/恢复失败、终态顺序与有效文件保留。非实现者审核Lead差异，最终正式CLI重做50步/17帧及取消/恢复验证；不以外部实验包装器代替正式入口。代码与最终验收版本分别记录。该补充仅完善可观测资源行为，不修改原质量标准。

D-VID01既有T2V已过，首图条件是独立P1基础缺口。歌声H21仍仅已发送询问，H20本人Xcode协议未确认；两者只阻塞对应依赖，不冻结本批。当前用户授权覆盖旧CURRENT_ACTIONS中“不自动启动I2V”的调度限制，不改变历史验收/许可/精度/保护义务。

目标：显式首图PNG＋描述＋参数→Wan2.2 TI2V-5B实际短帧序列、执行记录、可播放演示；验证首图条件、取消/失败/资源与原件保护。只实现独立Python后端；不改Swift/项目格式/注册/签名或UI，不把帧文件冒充MP4或App闭环。暂不接尾帧、片段编辑、LoRA、提示扩写、音轨、14B、长视频或其他模态组合。原Wan1.3B生产入口、权重/精度/测试不变。

模型源码 Wan-Video/Wan2.2 `42bf4cfaa384bc21833865abc2f9e6c0e67233dc`；权重 Wan-AI/Wan2.2-TI2V-5B `921dbaf3f1674a56f47e83fb80a34bac8a8f203e`，Apache-2.0。官方输入/输出、源码与模型卡已只读核实，不能由官方CUDA24GB推荐推导Mac门槛。原UMT5文件SHA与已装Wan1.3B相同，允许明确复用经核验的旧prepared text与tokenizer，不重复下载、不伪造新源revision。新原件三diffusion分片约20GB，VAE约2.819GB，Lead按既有下载授权取得/校验；不上传资产。

精度：新DiT沿已验证Wan计算边界：普通线性BF16，原始time/head/modulation/norm权重FP32；VAE原样PyTorch CPU/FP32，UMT5既有BF16。没有量化或改旧模型。源码的VAE仅Lead加weights_only=True,mmap=True，其他数值保持。使用其内部model.encode/decode与scale，不走外层CUDA autocast或TypeError→None。新profile公开记录慢CPU解码；不声称已适配所有机器。

## 共同契约：文件所有权

实施Worker各自独立物理工作树、spec1、受限CLI gpt-5.6-sol/high；写根仅本工作树及本job/output、tmp，网络关闭。源/common Git/原模型/其他任务/旧证据只读。只读预检、Lead核可观察上下文后才IMPLEMENT。初交＋最多两轮修复，必要一次有界Lead接管；旧歌声预算不刷新。每次≤15分钟，未知副作用/权限/身份停报，受控失败按预期另记。Lead负责共享任务、固定源码、反例、装配、重资源与Git。不得递归或自行提交。

- MODEL：仅 `Backends/Video/Python/d_video_i2v_model.py`、`Backends/Video/Tests/test_video_i2v_model.py`。
- IMAGE：仅 `Backends/Video/Python/d_video_i2v_image.py`、`Backends/Video/Tests/test_video_i2v_image.py`。
- RUN：仅 `Backends/Video/Python/d_video_i2v_run.py`、`Backends/Video/Tests/test_video_i2v_run.py`；前两接口确认后签发，不同时修改共享文件。
- Lead只维护以上任务文档、vendor来源、安全加载单行补丁、小夹具/独立数值验证和最终路线/README。非实现者审阅重要Lead差异。

必读：本任务对应包＋共同契约、AGENTS安全边界、既有d_video_model/read_snapshot与d_video_prepare路径/摘要工具；按包阅读相关Wan/旧runner。无需全历史。所有公共输入错误必须ValueError/OSError/明确异常，不能assert校验、吞错或默认降级。

## MODEL：固定原件加载

不建立新可执行配置/通用注册器，不改变旧PreparedModel。复用旧mapped_name等经验证局部函数。

`I2VModel(root: Path)`：root绝对普通无符号链接目录；只读取明确三个safetensors分片、index.json、config.json。核固定revision的原件大小/SHA、文件身份及index唯一JSON。记录`.manifest_digest`（index字节摘要）、`.originals`（仅路径名/size/sha）、`.root`；提供`.verify_unchanged()`。构造不加载模型/导入MLX，不写任何目录。三分片固定大小/摘要见R/model-metadata.json，index固定72865字节/SHAbfa2337f1163e195d24151a72298daf34a620543898109be47e414c8daa5b3fe；config固定251字节/SHAd1fea36899d00c2501b836c13ad65af56e2f9529ba622e50886d3f5c3e6c02bc。字段/架构取固定参考，不执行配置代码。

`load_diffusion(module, checkpoint=None)`：返回同一个完整加载模块。原index必须825个唯一原tensor名、只指向三个固定basename，无缺/多tensor。对module.parameters以mapped_name映射严格核学习参数集合与shape，允许生成freqs；patch_embedding.weight按原[O,C,1,2,2]展平，其他不变。逐tensor CPU读取/转换→MLX装入/显式eval→释放临时，不同时复制整个20GB原模型。原tensor均应FP32、有限值；前述精度策略严格执行，不能先BF16再上转FP32。checkpoint(index,total)可抛取消，停止后不伪称完整模块。加载前后verify_unchanged。CPU测试用明确合成受控manifest/模块，不制造真实哈希通过；真实权重由Lead另验。

## IMAGE：首图与官方CPU VAE

`read_reference(path: Path, width: int, height: int, *, reference_color_space: str) -> (rgb, record)`：显式PNG，最多64MiB/16777216像素（输入解析预算，不是Mac内存准入或推理尺寸上限）；原件普通/无symlink/读前后身份及摘要一致。单帧、RGB8、无alpha，尺寸恰width/height，不缩放/裁剪/旋转/自动补帧。只接受无ICC且EXIF方向缺失或1，sRGB标签缺失或0…3、gAMA缺失或45455/100000（容差1e-6）；存在cHRM时须为标准sRGB原色/白点（容差1e-5）；拒绝其他颜色/位深/动画，不能PIL.convert掩盖输入不支持。本函数必需keyword reference_color_space必须为"sRGB"（无默认），RUN请求也必须显式声明referenceColorSpace="sRGB"，无标签不是自动确认物理色彩。在PIL之前核PNG IHDR为bitDepth8/colorType2，避免16位RGB被PIL隐式下采样；禁止tRNS和acTL/fcTL/fdAT块（单帧APNG也拒绝），测试独立覆盖；Pillow DecompressionBombWarning视错误，先verify再load；只取所需数据，不返回原信息中的未知可执行URI。返回uint8 contiguous HWC numpy（自有不可写数组）和记录{sha256,byteCount,width,height,layout:"RGB8-top-down",colorInterpretation:"caller-declared sRGB"}，无绝对路径/EXIF私人信息。

`CPUImageVAE(weights: Path)`：固定VAE原件大小2818839170/SHA20eb789667fa5e60e7516bf509512f6cb61f01b0aa0695eadaea930c13892b36，读前后身份/摘要、普通路径；使用vendored wan22.vae2_2.Wan2_2_VAE(z_dim=48,c_dim=160,dim_mult=[1,2,4,4],temperal_downsample=[False,True,True],dtype=torch.float32,device="cpu")。明确torch.set_num_threads(2)仅在独立引擎初始化时，不导入即改全局。核心原dec_dim=256、48维mean/std不改，权重不得下载/任意pickle fallback。推理必须inference_mode，所有输入与输出CPU/FP32、形状/有限值校验。

`.encode(rgb)`→np.float32[48,1,H/16,W/16]，uint8 RGB标准归一化x/127.5−1，宽高32倍数；只首图T=1、核心encode，无随机采样。
`.decode(latent)`→np.float32[3,4T−3,H*16,W*16]，输入[48,T,H,W] FP32有限且空间偶数、T正；调用核心decode，再官方clamp[-1,1]，不能裁掉/补齐输出。当前官方核心全输出拼接，记录该资源行为，不称chunkstream；由上层单重任务及有界超时管理。每次成功/异常finally清cache，`.close()`幂等且释放模型引用，关闭后调用明确失败。不开子进程、不写媒体文件。类导入不加载torch/权重。

测试：真PNG正常/中文空格路径/损坏/截断/16bit/alpha/palette/animated/色彩和方向/尺寸/预算/软链接/输入变化；CPU VAE用受控假核心测shape/错误/清理/关闭/输入不变，原件真实验证另列，测试不能跳过固定原件校验冒充真实模型。

## RUN：待前两包可调用后签发的执行契约

新入口独立于旧d.video.frames.v1；不改旧App部署。请求精确键：旧runner全部键再加referenceImageSHA256、referenceColorSpace；schemaVersion=1、profile=wan22-ti2v-5b-bf16-cpuvae-v1、revision为本任务固定值。尺寸32倍数、帧数4n+1且至少5、各整数/seed/时间溢出等沿旧严格规则；新latent48channels/stride4×16×16；grid轴≤1024是现有RoPE表能力限制。steps1…1000、shift/guidance显式有限正、无默认40/50猜测。memoryLimitBytes是显式执行设置，不据物理RAM拒绝或改变请求。

CLI必须显式request/model/text-model/tokenizer/reference/output绝对路径（text-model指既有固定PreparedModel）。原request及reference不可与output重叠；output必须不存在、父为本任务已授权目录。新输出schema d.video.i2v.frames.v1，沿旧RGB8帧+result.json结构并记录首图、固定新模型/实际分组件精度/原text来源/参数/耗时/资源。只完整回读核对后发终态result，不把未完成目录当成功；失败保留本任务未发布现场，不误删其他文件。

资源顺序：T5条件→释放→CPU VAE encode→关闭→DiT→释放→CPU VAE decode→关闭→帧发布；CPU VAE不与5B常驻重叠。首图latent放第一latent帧；首帧token timestep=0、其余当前t；不使用14B的y拼接。初始及每次UniPC更新后首帧latent精确回填，同一个源编码不重算。共享显式噪声做数值比较；不要求Torch/MLX同seed同噪声。独立MLX随机key、正负条件分别算，CFG/UniPC沿已验路径。取消signal只置标记、当前模型调用结束后检查；CLI父所有的硬超时/回收处理不可中断CPU调用。不能瞬时取消承诺、不能返回成功后仍计算。

## RUN签发前细化（I2V1/spec1，执行基线另记）

`validate_request(value)`返回已检查原字典，不填默认值；`run(request_path, model_path, text_model_path, tokenizer_path, reference_path, output, *, emit_result=True)`返回完整结果。无App access/书签参数，本批仅独立命令行。路径检查、输出碰撞与首图SHA必须在任何重模型加载前完成；output不能等于/包住/位于任何输入文件或模型/tokenizer目录内，显式绝对无symlink。原件/请求读前后身份和摘要；结果前再检查。请求2MiB预算沿旧read_snapshot。

新结果保留旧schema结构中的request/requestSHA256/conditions/frames/stages/seconds，加入reference（IMAGE原记录）、model（repository/revision/indexSHA256/originals）、textModel（实际旧仓库/revision/manifestSHA256）、precision（text/diffusion/vae各自真实值）。不将旧PreparedModel的diffusion/vae来源写成新模型来源。frames布局RGB8-top-down，色彩声明为`model RGB interpreted as sRGB (unmeasured)`：这是显式显示解释，非测得色彩配置。每帧按[-1,1]→round→uint8转为连续HWC；完整N帧、精确字节数、回读SHA及输入保护检查后才发布result.json，不静默截断/补齐。私有执行结果可含实际提示，但不额外写绝对路径/书签/账号。

为避免适配层残留默认CPU影响执行，RUN在加载/CPU VAE后明确恢复所选MLX GPU设备；后端只有一个子进程，不并行占GPU。CPU数值对照可mx.disable_compile eager模式；真实入口保持默认编译设置，若环境阻塞如实记录，不暗改同名profile。资源释放在异常与取消路径同样执行，VAE必须finally close；MLX引用和cache在各阶段结束回收，不能让异常路径跳过清理。经确认的原件变化与取消同时出现时，原件错误作为失败并链出原取消，不吞掉变化。

观测stage至少validate/load-text/encode-text/release-text/encode-reference/release-reference/load-diffusion/denoise/release-diffusion/decode/released，反映实际边界，不承诺正在执行的单个调用能被中断。每步记录首latent帧与源的最大差值（应为0）和其余latent的变化量；只记录标量，不保存整套隐藏状态。首帧token数量为(H/32)*(W/32)，时序t=[0…0,current…current]，每个solver step之后重新夹定首latent帧。不把强制保持latent等同PNG逐像素复现。

CLI退出：完整报告及stdout成功0；输入/模型/执行/输出错误1；SIGINT/SIGTERM在检查点识别后130；argparse用法错误2。默认stdout为结构化progress/result，stderr为错误，输出流不可写不能误报0或因退出再次flush改变已判定错误；只处理实际I/O异常，允许将已经失败的自身标准流转到devnull以完成正常退出清理，不os._exit、不广吞异常。无自建子进程/下载/线程池；父验证器拥有整体超时与回收。失败不发布终态result，已独占创建的半成品保留现场。

RUN CPU冻结反例：旧请求/extra keys/bool-as-int/非法UUID和seed/32倍数/4n+1/min5/更大合法参数/帧时间溢出；首图hash/颜色/尺寸不符早拒绝；路径重叠、现有输出和原件不覆盖；首帧0与后帧t、每次更新夹定且后帧会变化；正常/取消/错误资源顺序，encode/decode关闭；帧shape/NaN/大小/摘要不符无result；最终request/reference改变无成功；stdout/stderr失败真实CLI退出。Worker只运行标准库/NumPy/PNG与明确假依赖，禁止Torch/MLX初始化；Lead独立跑真实模型/实际GPU与返回帧对照。不要把mock端到端记作真实视频。

## 独立验收与真实出口

签发前非实现者审核补充：VAE路径固定`model_path / "Wan2.2_VAE.pth"`，不增加自动发现/下载。结果model.originals除三分片外，包含VAE、index、config的普通basename/实际size/固定sha；textModel分别记录旧manifest及242个实际text shard摘要，不把未用的旧DiT/VAE列成使用材料。提交时快照与终点再核范围为request/reference、新index/config/三分片/VAE、旧prepared manifest及实际242个text shard、四个固定tokenizer；加载器的当次校验不能替代执行终点检查。不得依赖未传入的旧原始T5路径。

输出失败语义澄清：计算/输入保护/帧回读未通过时不发布result.json；如完整已验证报告已原子发布，之后stdout通知失败则保持该报告/媒体，进程退出1并明确通知失败，不能反删有效产物或声称终态已成功交给消费者。退出码0同时要求文件和通知完成。此处澄清原条款的先后关系，不放松验收。

Lead在实施前固定关键反例，Worker自检不等接纳。新增逐token时间/调制/block/head对照首帧0和非恒定后续值，复用原FP32/BF16容差，不降低旧阈值；首帧固定与非首帧变化轨迹、破坏条件负控、异常输入、文件不覆盖/变动、取消/退出/下一任务、异常/关闭清理分别测。VAE原样小结构参考及真实固定权重encode/decode、1/2/5 latent帧完整形状/数值/重复调用由Lead串行；原源码固定原件作为对照，不以自己输出当金值。

本机首验320×192、17帧、24fps、明确50steps/shift5/guidance5/seed；先有界5帧/少步探针检执行再完整样本，探针不冒充画质验收。另在CPU/契约检查更大尺寸/帧数，不能写死开发机上限。尝试真实加载，记MLX active/peak/cache、进程RSS、系统swap及耗时；OOM/超时如实失败不无限尝试。取模型编码出的首帧/逐步clamp证据，不宣称输出首帧PNG逐像素无损。真实媒体可以由既有独立编码入口验证（不调用新Xcode），若无可用入口则帧产物与MP4待验分开。无真人听看/GUI不算完整App能力。

测试环境既有外盘Python3.12 `/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-VIDEO-V0-01/run-20260913T152419Z/venv/bin/python -B`；Pillow12.3.0固定macOS arm64轮子只在R/python-deps（MIT-CMU，SHAffd0c5368496f41b0944be820fcb7a838aa6e623d250b01acf2643939c3f99d7）。PYTHONPATH显式任务代码/这个只读依赖；TMPDIR/cache/config均job/tmp，-B。语法tokenize.open＋内存compile不运行目标；不py_compile、不系统Git/Xcode/xcrun/Swift。MLX数值CPU及小合成Torch允许，真实大模型/GPU仅Lead。未知接口先向Lead反馈。

阶段结案分别记CPU、数值、真实模型/产物、GUI未知、源受测/最终及push；H20/H21仍集中记录，不请求离机用户。若完整真实后端门槛不足保留隔离候选；源只接纳相应独立完整验收过的增量，不默认开放未经验证路径。下一产品提案为已有视频候选底座接首图；不启动高级剪辑/组合或无限新包。


## 实施、修复与独立审核记录（2026-09-15）

本批三名实施Worker均走已核验受限CLI，模型请求及turn_context为gpt-5.6-sol/high；隐藏服务端解析unknown，不以自述证明身份。无用户级默认配置变更。MODEL与IMAGE初交实际重叠（UTC 10:53:30起，IMAGE至11:00:20、MODEL至11:02:24）；RUN等稳定接口后执行，重型验证仅Lead串行。任务包/写根、创建/实际参数、每轮停止与来源证据位于R的model、image、runner子目录及worker-run.py/observe-route.py。未授Worker写源/common Git/权重或网络。

| 交付 | 最终实现提交 | 初交后修复与Lead发现 | 实际检查范围 |
| --- | --- | --- | --- |
| MODEL | 76b6dae45f3695c8f9ed064cc724538be3b92b44 | 1轮；形状映射不保留整套数组，原FP32敏感权重和异常后的输入校验 | model-lead-final 8方法；model-real-final真实825张量加载、5张量处取消后新加载、5个代表参数独立精确比较，不能写成825参数逐值对照 |
| IMAGE | d2fd42212ebbe3fd12c18a66d30dc5b3a617439f | 1轮；Lead发现只破坏IEND CRC的PNG被接受，新增全chunk CRC验证 | image-lead-final 22方法；vae-real-r1固定原VAE encode/repeat及1/2/5 latent帧decode，max abs均0；该数值验收在CRC-only修补前，VAE实现未变 |
| RUN | 12000103a6444ee71164f3ced3d3237ef18f1c5d | 2轮已用尽；修复关闭stderr导致120、argparse吞OSError造成假成功、条件引用残留；增加真实spool字节序/同大小损坏反例 | runner-lead-final及combined-run-final 21方法；实际CLI错误/输出通道另列，不将mock推理当模型运行 |
| Lead驻留资源完善 | 23781123a1b8d831bb02cf3e5669fc2d309998b3 | spec2一次有界接管，非第三轮Sol修复；8项新回归先失败，再加同步/已发布文件2项，共10新增 | resident-red先失败，resident-green及runner-resident-final 31方法通过；后者对应干净2378112完整SHA |

Lead还负责契约、原样vendor安全加载、独立逐token数值测试、小合成首图、集成及真实模型/媒体验证；不能全归为Sol独立交付。非实现者singing_repo_integration_scope检查最终1200013及Lead2378112差异，未发现阻塞；后者核请求绑定/恢复/发布顺序/旧路径/无数值变化，见lead-residency-review.json。它没有执行这些测试，测试仍归Lead。

### 必须保留的事件与限制

- MODEL初交实际MLX导入遭Metal设备列表为空退出134后继续替换为夹具，且同名自测日志被覆盖；这是未按STOP协议上报，不追改合规。可见运行记录保留，没有已观察权限扩大或成功越界，隐藏副作用unknown。修复前Lead记录环境事件并禁止Worker真实运行时初始化；后续只CPU受控对象，真实MLX由Lead验证。
- IMAGE初交OMP179环境警告后按STOP回报。源码表明可能涉及共享内存与/tmp回退，但不能据源码推断实际写入；未扩写根。修复PNG测试不初始化Torch，Lead独立环境完整22项通过不冒充Worker沙箱证明。
- Lead最初数值CPU JIT调用g++触发H20，原失败在numeric-r1；仅独立CPU对照改eager，numeric-eager-r2的3方法通过，公式/原容差未变，正式GPU不禁编译。初次组合检查遗漏环境变量而未执行/出现2错误，正确显式环境后component-combination-r2与combined-old-final通过，不能覆盖原失败。
- 早期50步17帧因单步持续很慢由Lead正常取消，real-full-r1子进程130，无强杀、未发布结果。取消后才取到的vmstat或失败sample不是运行中换页证据；10GiB实验仅证实可行改善，不以降步数、分辨率或精度替代正式50步。
- 初次MP4演示检查发现色彩primaries/transfer标记缺失，probe-media失败保留；显式setparams声明后probe-media-r2全部帧解码与PTS通过。这是原色彩解释落到容器，不是重新测量校色。外部ffmpeg GPL/libx264只作开发验证，未加入D分发。

逐次CLI token记录保留原turn.completed口径于run-observations.json及各轮observed记录；未核对为增量的计数不累加，缓存与输入不能重复算。没有重算旧五次试点费用。完整Lead归因、实际订阅费用和跨模型性价比仍unknown；本样本不能证明Sol适合一切后端。环境/协议/实现缺陷与Lead审核分别归因。


## 正式样本与质量拒绝（不是阶段验收通过）

正式CLI受测代码`23781123a1b8d831bb02cf3e5669fc2d309998b3`，320×192/17帧/24fps/50步/seed2215/shift5/guidance5，显式allocation14GiB、process residency10GiB。real-full-final独立进程0，约300.490秒；MLX峰值11893469474字节，最后active18/cache0；进程RSS高水位9979379712字节，不能与MLX相加，swap有增长不冒称没有交换。255个实际输入前后SHA及身份相同。50步首latent帧差均0，首RGB帧与独立原VAE重建差0；VAE有损不能称与原PNG完全相同。

full-media-final演示为17帧、0.708333秒H.264无声MP4，独立完整解码及逐帧PTS均通过；原RGB/报告摘要、大小、mtime/ctime不变。外部封装不是App导出。**Lead实际检查contact-sheet发现后续帧严重彩色条带/形变，原帧已有，不能仅归为编码损失、普通审美或小机器限制。** 后端报告的成功只证明运行/文件契约，不代表模型效果正确；本阶段拒绝产品接纳，不能把上述机器通过拼成“视频成功交付”。失败证据quality-block.json、full-media-final/contact-sheet.png及demonstration.mp4保留。

两位非实现者只读复核实际公式、参数映射/形状、逐token时间/夹定、VAE scale、patch/unpatchify，未找到可证实结构错位；这不能证明完整真实5B前向等价。原官方FP64复数RoPE与既有FP32旋转存在已知精度边界，但没有证据归因为本次条带。补读同一固定commit的utils.py、fm_solvers_unipc.py、shared_config.py于quality-reference（只读，不运行其中下载/导出功能）。后续需同一中间输入对照完整实际扩散数值，再决定是否需要分辨率/长度单变量实验，不能先归咎模型或靠抽卡通过。

后续代码`43cbe6792f2df77c3c58eb754aac144fdef7735a`相对2378112仅任务说明、vendor修改声明注释及PROVENANCE摘要/状态；Python AST完全相同，见vendor-notice-check.json。Apache4(b)的文件内修改声明已补，原作者保留。不能声称300秒样本在后来提交上重新运行。


### 取消检查与剩余定位计划

43cbe67完整SHA如上，四个真实CLI分别在encode-text、load-diffusion、denoise、decode进度到达时发送SIGTERM，均完整退出130、无强杀、无结果终态，255输入后验一致；观察drain约11.88/17.44/1.48/8.58秒，见cancel-acceptance.json。进度边界取消不等于瞬间抢占GPU；早期取消的最后stage仍可能持有异常栈引用，不能把其activeBytes写成0。拥有的子进程已由各验证器wait回收；不是通过关闭用户D腾资源。恢复短任务另记，不以2步样本修饰50步画面失败。

**同阶段下一步，先定位而不扩建：** 使用同一份捕获的latent、时间与文本条件，对固定官方完整5B前向逐层比较，区分T5、DiT、采样器与解码；先补独立参考覆盖缺口，不先改生产实现或改随机种子。若完整数值一致，再按单变量比较时长/尺寸的模型适用范围，不由16GiB或一次低分辨率失败设永久上限。模型调用与精度若须修补，保留原失败和预算，用明确缺陷/范围的有界任务修订；RUN初交＋两轮及Lead资源接管已发生，不重新编号刷新。现有质量阻塞不转成“等待用户解锁”。

H20仍只待本人阅读/确认Xcode协议，H21仍为适用声码器外部依据；均不重复催办。HUM必要纠错、普通试听/MIDI、TTS及后续组合保留目标位置，不因本批候选失败被删除或无限推后；此恢复点不启动另一个产品批次。


### 最终恢复检查点：候选质量阻塞，源更新另有未明变动

最后四次取消之后，real-recovery-final以43cbe67完整SHA实际运行新的5帧/2步短任务，进程0、约116.935秒、无强杀/输出异常，255输入不变，首帧独立参考差0；仅证明下一任务能够运行，不是新画质验收。最后active18/cache0，所有本轮实施Worker、Lead模型/CPU/媒体及取消验证进程已结束并wait回收；原生历史pending_init记录不等于外部进程清理证明。

源更新前完整检查发现`docs/PRODUCT_PRINCIPLES.zh-CN.md`另有未提交变动：删空行，并将“当前对象/结构与操作”树行移到参数行之后；作者/授权来源未知，本Lead未作该编辑。源HEAD仍f6ca90b37a1134bdc6f41912cd5d5fb5173094aa、索引干净；scheme原SHA ca3635d88aa5a15397b90e528667c66c0e6db7e596176e885c79d194b544206c及未暂存差异仍保留。只读副本/完整diff见source-drift.json与product-principles-observed.md；**没有自动恢复、暂存、提交该文件或在源写状态文档**。

Lead前一份source-during-validation.json已包含这一差异，但该辅助检查只断言HEAD/scheme，其打印“source unchanged”过宽；后续完整status门槛在任何源变更前拒绝，保留审核遗漏事实。首次源文档预检退出1，随后只读ls-remote返回远端f6ca90b完整值，不把复合命令最后0当作预检通过。没有因此清理/覆盖源、提权或改基线。

本候选最后追加只为本任务/路线/README说明的本地记录，最终SHA写R/final-receipt.json，不作自引用提交。代码未源接纳、未推送，阶段未完成。下一恢复先核源个人/未明文档变化、候选HEAD、进程和权限，再做上文同阶段有界数值定位；不是启动新模态或重置修复预算。源分支推进前还须核清新增文档变动归属。恢复索引：stage-evidence.json、quality-block.json、quality-review.json、cancel-acceptance.json、real-recovery-final/process-result.json、source-drift.json。


## 2026-09-15 本人返回后的定点恢复（本轮诊断收束，阶段未完成）

新证据目录为 `D-Development/AgentTrials/D-VIDEO-I2V-01/run-20260915T132922Z-quality-finish`（下称R2）。源/候选起点分别f6ca90b37a1134bdc6f41912cd5d5fb5173094aa与74c44373b0b859377990224947a0b2dc277bc7f8。本人确认源PRODUCT_PRINCIPLES为误改并批准修正，Lead按既定树层级精确修补，文档回到HEAD内容；源仍仅有scheme未暂存个人修改，未暂存/还原scheme。完整保护副本及前后差异见R2/preflight.json、human-actions.json。

H20本人自行阅读/接受Xcode协议后，Xcode27.0/27A266a、firstLaunch检查、clang21定位及实际MLX CPU JIT表达式执行通过，后者不是仅版本输出；旧失败保留。H21仅只读已知线程，仍1条SENT，无新增回复/发送；不需本人重复下载授权。

本轮由Lead编写外部有界诊断，不修改生产数值/输出/精度或重置原修复预算；两位非实现者只读审核，未伪称他们执行真实测试。真实block0与30层输入/输出捕获、官方Torch CPU流式参考、相同QKV的显式公式对照分别保留。捕获hook只记录中间数据但改变同步时点；不能用于正常耗时/释放验收。first-forward捕获的诊断成功退出不代表生成完成。所有dtype按捕获manifest还原，累计链不以候选中间值替代；逐块同输入比较单列。

发现默认CPU BF16 SDPA在相同QKV下偏离显式FP32公式（再转BF16），生产MLX SDPA在该分项原容差内。尚未记录默认CPU实际dispatch名称，不能指认具体内核bug。局部MATH参考依据PyTorch2.7官方文档及本机functional.py，仍用原输入输出BF16/原容差；这不是将生产改为FP32或降低验收。完整30层MATH诊断仍有点值超限，不能宣称全5B数值完全等价，也不能把参考路径问题直接当作彩条根因。诊断脚本退出0只说明完成，逐项判定以JSON误差为准。

补充同一非恒定flow、50步/shift5与首latent回填的UniPC原容差对照通过（maxabs约3.10e-6）；原17帧已知静态画面的VAE encode/decode回环可正确还原，单独排除这一确定输入的时序/像素布局问题。正式50步参数不变的新观察运行记录全轨迹，以定位采样中何时偏离。质量门槛、原失败与未接纳状态保持；未开放App入口。完整进展和本轮进程状态以R2/checkpoint/最终回执为准，本文此处不是阶段结案。

### R2 已完成诊断的证据边界

下列仍针对74c44373b0b859377990224947a0b2dc277bc7f8生产代码，只有文档未提交变化。所有参考脚本/中间数组放R2，不进入产品或Git；CPU公式与MPS不是原官方CUDA整链的代称。

| 检查 | 本轮实际结果 | 能说明什么／不能说明什么 |
|---|---|---|
| 完整30层同输入MATH参考 | 187.41秒完成；原BF16容差之外718/57600值 | 全模型逐点等价仍未通过；参考运行0不等于数值通过 |
| 正式50步轨迹捕获 | 280.165秒、255输入不变；RGB摘要与原失败样本完全相同 | 观察器未改变该样本字节；色带仍在，不能作画质通过 |
| 原采样器回放50个真实flow | maxabs3.34e-6，原FP32容差通过 | 固定flow下的采样更新一致，不排除闭环前向差异 |
| 官方类MPS独立执行50步＋CPU解码 | 190.229秒＋28.966秒；人工看对照图同样严重彩条 | 共享捕获的T5条件/初始latent，不能由此指认原模型bug或宣称数值全等 |
| 只改帧数至121 | 1015.916秒、255输入不变，真实CLI正常退出；后帧仍严重彩条 | 单独延长未解决；不把121设为产品最短时长，不覆盖原17帧失败 |
| 当前正负提示词分词 | D与独立AutoTokenizer实际IDs/mask一致，含EOS分别34/18 | 仅这两个英文输入；未证明全Unicode清洗或完整T5编码等价 |

索引：R2/reference-forward-math、full-trace、trace-analysis、official-mps-full-r2、official-mps-decode、independent-quality-verdict.json、full-length121、length-quality-verdict.json、tokenizer-current-prompts-r2.json。非实现者审阅原公式/流程，未找到已证结构错位；官方480p推荐shift3与当前320×192/shift5不同，仅作待验证的尺寸/调度线索，详shared-conditions-review.json。两个原始UMT5权重及分词材料身份相同的依据见t5-identity-review.json，不代替本轮完整编码数值对照。

Lead外部诊断也保留两项失败：首次MPS桥接因mps与mps:0设备标识处理错误退出，局部修正后复验；首次分词诊断错误假定USE_TORCH=0仍阻止新版Transformers导入Torch，断言失败后按实际语义记录并重跑。均不是Worker新修复轮次，也未借此更改冻结产品验收标准。静态审核另补T5参考输入身份、完整512形状、错误/超时后的保护核对和退出竞态处理；其实际执行结果另列，不能把预审当测试。

### R2 最终恢复检查点

640×384/17帧生产对照完整退出0，1451.923秒，256输入保护通过；首帧独立原VAE差0，后帧确有变化，最后MLX active18/cache0。CPU decode约927.7秒；自有进程采样记录17.4G physical footprint、真实CPU conv3d/BLAS调用，最终ru_maxrss为11638161408字节，两种指标不可混同。样本没有低尺寸的严重彩条；全17帧另从H264解码逐帧检查，主体/颜色稳定但运动很轻微，未充分表现向右滚动，不宣称提示精确服从或已做GUI播放。帧数/640×384/24fps/0.708333秒/色彩标记及全解码检查通过，外部ffmpeg只是验证工具，非新增分发依赖。见R2/full-resolution640、resolution-quality-verdict.json、resolution-media-artifacts/verification.json与all-17-decoded-frames.png。320×192原失败保留；改变尺寸也改变同seed的噪声形状，不能据此证明根因或永久最小尺寸。

原始UMT5 CPU全量对照已完成：严格加载242个BF16原参数、独立当前提示IDs及完整512 mask，不用截短输入替代；同一原容差正提示39/139264超限（max0.0859375），负提示2/73728（max0.041748046875）。子进程明确退出1，179.588秒，完整等待/7输入前后保护通过，无超时/权限扩大；完整DiT MATH的718点超差也保留。因此数值门槛仍未过，640样本改善不能替它结案，不能指认T5就是色带根因。见R2/t5-reference-full/numerics.json、result.json和t5-preexecution-review.json。

本轮到此停止实验，不新增生产修补；MODEL/IMAGE/RUN及原预算保持历史事实，Lead本次仅外部诊断/人工画面核查/状态文档，两名非实现者只读审阅，未称他们执行测试。隐藏模型解析和完整Lead订阅费用仍unknown，不重算旧样本。直接失败包括上述数值门槛及保留的外部诊断构造错误，不能累计成全通过率。下一同阶段行动先从完整参考中定位首个超差层、核清同精度计算差异，再确定有界修补或经过说明的profile；任何新标准/已耗预算变更需明确，不以一次更漂亮样本改变冻结结论。

源生产代码仍f6ca90b37a1134bdc6f41912cd5d5fb5173094aa；本轮受测代码74c44373b0b859377990224947a0b2dc277bc7f8，后加仅文档。源可记录H20关闭/当前停点，但未接纳本候选代码。最终各文档提交写R2/final-receipt.json，保留未推送状态，不做自引用amend。普通D/作品未操作、模型及自有输入保护证据保留；scheme内容/摘要/索引/未暂存状态照原件核对。自有实验PID及媒体子进程均完整结束回收；历史pending_init不当作已结束。恢复以外部final-receipt和实际仓库为准，本阶段未完成，不启动下一批。

## 2026-09-16：首层定位完成，原型未通过，保留隔离质量阻塞

R3=`D-Development/AgentTrials/D-VIDEO-I2V-01/run-20260915T154710Z-numerical-finish`。生产与测试仍b4b41f4eb652e4c55270cb69ae868fd079c60110所含代码，未改任何模型算子或原阈值。有效捕获完整512输入/24层与原context逐值一致，CPU完整原参考仍39/2超差；有效34 token的block0输入、位置bias、norm1及同输入norm2一致，attention在原门槛内；已测分支首个超差在FFN输出。GELU各算子局部在阈值内，但其舍入差异经门控及末端线性层放大，不能称为全模型/彩条唯一根因。

对3925个实际BF16值，PyTorch2.7.1 CPU pow3与两次BF16乘法相同；MPS/MLX pow与FP64结果舍入相同。原T5完整512 MPS参考对未改MLX仍8/2超差，而原CPU参考对MPS也5/0；设备结果不能混作同一位级金值。两种外部原型保留全部BF16权重/结果边界：两scalar的FP32 opmath原型对CPU4/0、MPS16/0；再模拟CPU两次乘法的原型对CPU9/0、MPS1/0。均未完全通过，不以局部改善或挑参考更名接纳；没有生产修补、预算重置或精度/阈值放宽。

所有R3自有模型/诊断子进程结束并回收，除首次capture外输入保护通过。首次capture期间Lead修改了同一诊断脚本的另一模式，子进程0但版本保护1，证据无效；单独capture-r2固定脚本后重新捕获，原失败与`lead-script-version-event.json`保留，非Worker权限事件。

非实现者只读审核认可以上边界，没有执行数值/画面测试。R3恢复索引`diagnostic-verdict.json`与各job的`numerics.json/result.json`，完整脚本/输入及参考均在持久外盘。仍未知固定参考设备/精度语义、T5/DiT剩余差异的实际质量影响、320彩条因果及可靠产品profile；640好转不能覆盖原320失败。保留候选未接纳/未推送，不继续无判别目标的算子调整。

用户同时明确资格确认与许可清楚替代可继续；歌声已产生MIT替代WAV并获本人听感确认，沿原歌声R1/R2推进，不被独立I2V质量阻塞冻结。源新增9b3932081e48c68ed02593dc1bf64d5b37fdb6c8仅四份歌声/状态文档，归属已核，不含应用行为变化；本候选未合该快照。


## 2026-09-16受控数值续查结束，I2V质量门槛仍未通过

用户批准按整体目标继续下一阶段。音频统一候选AP1只待本人H22/H23，不催解锁；本次恢复I2V的有限数值定位，不重置RUN两轮修复和一次Lead驻留接管预算，不把诊断完成写成产品阶段完成。源起点`ea75dca85f1b53b64fc9f4d158c13d7bb41f8b20`；干净候选实际调用`921ebfd8a0b5b5ea61b30055244a4a227c690746`，生产实现仍`23781123a1b8d831bb02cf3e5669fc2d309998b3`。本轮没有生产/测试契约修改、模型下载或GUI操作，源只同步任务和状态文档。

证据R=`D-Development/AgentTrials/D-VIDEO-I2V-01/run-20260916T074009Z-reference-closure`，先读`verdict.json`与`final-receipt.json`；脚本、输入清单、进程回收、前后摘要和完整结果留外部目录。Torch2.7.1/MLX0.31.1、既有外盘Python3.12、M4/16GiB；重任务Lead串行。两个既有只读代理分别核参考语义/诊断解释与管线/预算，没有新的写Worker，不代表重新验证受限CLI派工。

| 有限检查 | 实际结果与不能推导的结论 |
| --- | --- |
| 全部65,280个有限BF16 tanh输入、首块3,925个实际gate值 | 254个输出差异坐标与输入转换差异完全重合，均来自极小输入范围，不能据此归咎tanh。诊断脚本的CPU逐步舍入GELU公式在这些gate值上零差；不代表生产GELU或全部T5已匹配。见`tanh-domain-r2`及`input-and-accumulation`。 |
| 完整[1,512,4096]×[4096,10240]矩阵，再抽固定点精确有理累加 | 34有效token仍75个不等、0个超原容差；前12个不等坐标中CPU11个/MLX1个取精确和最近值，4个相等对照两者正确。BF16输入往返和旧capture的manifest/SHA核对通过；只适用于抽样，不能宣称框架总体准确率。 |
| FP32内部矩阵计算后返回BF16 | 仍75个不等、0个超差，汇总指标相同；未证明输出逐位相同，也未全面排除累加因素。停止这个简单提升精度方向。 |
| 全30层DiT同输入原版/FP32 GELU内部运算原型 | 原版与旧capture逐值相同；对固定官方MATH参考仍718/57,600超原阈值。仅替换text embedding及30个FFN激活的原型1,392/57,600超差，RMS增加，实际退出1；不采纳，不放宽0.02绝对/相对容差。见`dit/full-forward`。 |
| 只替换为已验证官方CPU完整512编码的两份文本条件 | 同初始latent、320×192/17帧/50步/shift5/CFG5，官方模块MPS扩散完成；guard约169.61秒。再直接固定原版CPU/FP32 VAE解码约24.32秒，17帧有限值/首latent保留，首帧字节最大差0。Lead查看全部17帧，后帧仍明显彩条，质量失败。见`conditioning/official-context`、`decode/direct-original`。 |

最后一项是**条件替换控制实验**：仍共享捕获的初始latent、MPS桥接与采样流程，不是完整未修改官方GPU管线。它表明仅替换文字编码不能消除该样本彩条；不证明T5误差无影响、不证明低分辨率是唯一原因。旧R2“官方MPS也异常”同样须按共享条件对照理解。静态复核mask、逐token时间、CFG、每步首latent回填与VAE scale未发现新装配偏离；官方自动缩裁与空负提示替换政策和D显式请求不同，但未建立当前故障因果。

原型依据为固定版本[PyTorch fused GELU内部运算](https://raw.githubusercontent.com/pytorch/pytorch/v2.7.1/aten/src/ATen/native/cpu/Gelu.h)与[MLX实现](https://raw.githubusercontent.com/ml-explore/mlx/v0.31.1/python/mlx/nn/layers/activations.py)，不改变权重或接口BF16。最大误差下降不能抵消全元素门槛失败；本轮没有采用任一数值原型。完整T5与DiT旧失败保留，320质量失败也保留，640历史样本不能替代它。

审核与事件：非实现者只读核对脚本/证据，指出精确点积须绑定实际BF16输入，Lead用独立往返和capture摘要补证；全域字段`all_output_differences_subnormal`实际检查输入位模式，不把它当独立输出分类证据。第一次启动使用相对脚本路径，在子进程工作目录找不到文件，exit2、未执行模型；原失败保留后以绝对路径启动同一固定脚本成功。一段准备代码语法错误在执行前发生；两次只读查询使用错误外部cwd而被拒绝，后续显式定位，没有写错仓库。未编辑运行中脚本。7个guard记录均输入不变、子进程正常回收、无超时强杀；其中启动失败与原型验收失败不能计通过率。6个诊断脚本内存compile通过，不代替行为/质量验收。

**状态及下一有限计划：** 本轮诊断已结束，I2V阶段仍质量阻塞、未源代码接纳、未启用App。停止继续随机试调T5 ULP/激活。下一步应先建立固定版本官方推荐几何下的完整输入→帧基准，独立核图像准备、noise/首帧条件与时间，以及原版可达到的质量；再判断适配修补、实际可用profile或后端选择。320失败不删除、不静默改请求，开发机16GiB不定义永久能力上限；任何参考语义/验收策略修订须独立说明和审核，不能把跨设备超差直接重标通过。基准成立后才签发窄实现包；此时增加同一关键路径的写Worker不会提高效率。

对照首发总目标：各模态有限基础→一条真实能力组合→首用/部署/恢复/发行收尾的顺序保持。AP1 H22/H23本人返回时独立集中办理；不重复麦克风检查、不让I2V诊断阻塞音频接纳。下一组合优先复用已有文本与图像的稳定候选/保存操作，具体契约独立批准；不扩DAW、时间线、新框架或移动端。本轮没有启动组合或下一批。

恢复点：本轮最终候选/源文档SHA与推送见R的回执（避免提交自引用）；代码未变，没有伪称最终文档SHA重新经过模型验收。源scheme内容、摘要、索引和未暂存状态保留；普通D/旧作品未操作。模型/图像/原日志不入Git，候选/分支/旧失败证据保留。角色归因为Lead外部诊断＋两个只读复核，原三名Sol实现来源不覆盖；本轮token、完整Lead消耗、实际订阅费用unknown，不重算历史费用。
