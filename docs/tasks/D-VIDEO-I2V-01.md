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


## 2026-09-16 IMAGE 最后一轮局部修补：CPU卷积workspace（spec I2V1-IMAGE-r3）

同一D-VIDEO-I2V-01，IMAGE初交及一次修补历史不改；本次消耗剩余一轮普通修补，不刷新RUN预算。原候选74cf41f232df53d43017c3c86bf6cc05f4f510a9；本准备提交为执行基线（完整SHA见外部job.json）。这是新发现的资源执行问题，非追罚原规格：原640×384解码927.7秒、栈为slow_conv3d/SGEMM；meta形状估算1216×736最大展开46.09GiB，估算不是RSS。GPU参考在另一工作树运行，本包禁止Torch/MLX初始化或任何模型执行。

目标：仅CPU FP32 VAE实例内，降低大卷积展开workspace；数学卷积、权重、FP32、padding/cache、模型结构、输出形状/顺序保持。固定内部workspace目标512MiB，不是产品尺寸/物理内存准入；单个输出高度行超过预算时用一行，明确预算非总内存硬上限。小卷积仍原生路径。仅处理本适配器拥有的CausalConv3d实例，放在原cache拼接和全局padding之后；不全局修改Torch/原vendor，不跨块重新padding/cache，不拆norm/attention，不改变time/width/通道求和。按输出高度分块，保持全部时间/宽度及正确halo，支持原stride/dilation/groups/bias；使用单个预分配输出、逐块赋值，不能保留全部块再cat导致峰值复制。输入/权重不变；异常仍上传；close和初始化失败无持久外部patch或资源引用。导入仍不加载Torch。

允许仅：Backends/Video/Python/d_video_i2v_image.py；可选同目录d_video_cpu_conv.py；Backends/Video/Tests/test_video_i2v_image.py；新增Backends/Video/Tests/test_video_cpu_conv.py。任务文档仅Lead维护。禁区：其他源码、vendor、RUN、模型加载/数值公式、Swift、工程/签名、依赖、所有源目录/权重/已有证据和公共Git写入。不得commit、递归派工、网络、安装、构建或GUI。

测试契约由Lead固定：实际CPUFP32分块与原生卷积用原FP32 atol=1e-5/rtol=1e-5逐值比较（不降低）；涵盖原始causal预padding后首/后chunk、非整块尾行、bias有无、groups、stride/dilation、单行超预算、small-native、输入权重不变、异常传播、实例隔离和close；不只断言内部函数调用镜像。实际Torch测试实现由Worker写、仅Lead串行运行；Worker可运行原22项PNG/fakeVAE测试，必要补fake核心接口而不删断言；使用现有Python、任务tmp和-B。新增测试的Torch导入不得污染原独立测试运行。新测试前须通过tokenize.open+compile源码检查，不exec目标、不py_compile。Lead另验真实320/17帧原VAE对照、原首RGB<=1门槛、推荐尺寸完整解码与视觉、实际内存和取消；这不是Worker自测通过可以替代的门槛。

请求gpt-5.6-sol/high；workspace-write，网络禁用，写根仅本任务工作树及本run/output、tmp，公共Git只读；未知权限/来源/副作用立即停报。当前进程执行不得加载Torch/MLX；已有OpenMP沙箱失败不要重试。普通修补仅此次，不自开后续轮次。回传改动、测试/未执行项、异常、实际进程状态和输出证据，停止写入交回Lead。

### IMAGE-r3 验收与一次有界Lead接管（2026-09-16）

执行基线afe8d1f24c1c9700a74a89098e1fc97cfca5b644，Sol/high受限CLI最终候选5bce2d083a4df17721805e86c15a340a629152cd；自检仅14PNG，Lead独立22PNG/合成VAE＋7实际Torch＋3分块执行观察通过。真实320×192/17帧与固定原版CPU VAE完整返回FP32及RGB逐值差0。原生旧适配器同输入峰值10.229GB，本候选7.534GB；单样本而非广泛性能承诺。原规格文字更正：1e-5/1e-5是此次逐卷积新增更严门槛，完整VAE原门槛实际为3e-5/3e-5；已在IMPLEMENT前澄清，未改阈值。

随后推荐1216×736完整解码在原生二维卷积出现同类workspace瓶颈，实际采样slow_conv2d/SGEMM、physical footprint peak25.1G；Lead于约307秒停止自有进程5859，退出-15并回收，原件保护通过，没有完成帧或质量成功。证据R5=`D-Development/AgentTrials/D-VIDEO-I2V-01/run-20260916T090246Z-official-profile`中的recommended-decode-sample.txt及official-recommended-decoded。先前仅约束3D属于Lead资源范围遗漏，不是Worker越界/未遵循，也不重置修复预算。

本次使用IMAGE尚未使用的一次有界Lead接管，保持同四文件范围，另仅追加本记录；没有第三轮Worker，RUN接管不刷新。仅增加适配器所属标准nn.Conv2d零padding的FP32高度分块，512MiB内部列展开目标、单行下界、stride/dilation/groups/bias/整batch通道宽度不变；小卷积仍原生，非零padding_mode或字符串padding先明确拒绝，不静默改变语义。原3D逻辑与所有阈值不动，权重/精度/vendor/模型/主线程规则不变。

冻结新增验证：实际原生对照与真实非整块尾行/调用次数，batch>1、bias有无、groups/stride/dilation、单行超预算、小原生、实例隔离/错误/close恢复；Lead先构造资源路径反例在5bce旧实现失败，再改实现。之后重跑22＋原7及新增2D、独立3D观察、完整原版320/17返回3e-5及首RGB<=1，最后推荐尺寸解码。新增实现由非实现者只读审查。此有限接管复验失败则停止相关接纳，不再连续补救或放宽门槛。


## 2026-09-16 推荐几何参考与CPU资源修补收口：I2V仍质量阻塞

本轮按输入参考→资源热点→局部数值/生命周期→画面质量的次序推进。受测资源候选 `10c57ab264fe326ea48cea529b264eafaccc2590`，工作树 `D-Worktrees/D-VIDEO-I2V-01-CPU-CONV`、分支 `codex/d-video-i2v-01-cpu-conv`；源起点 `c3e468ca7d10271b4ab872ff796b659f6d494a24`。原主候选74cf41f保持不动。本节只报告有限修补与失败参考，**整体阶段未完成，代码不源接纳/不推送/不启用App**。最终候选及源文档提交SHA写R5/final-receipt.json，不自引用反复提交。

R5=`D-Development/AgentTrials/D-VIDEO-I2V-01/run-20260916T090246Z-official-profile`。固定官方源码42bf4cfaa384bc21833865abc2f9e6c0e67233dc、权重921dbaf3f1674a56f47e83fb80a34bac8a8f203e，保持普通BF16/敏感FP32扩散及CPU FP32 VAE。Torch2.7.1/MLX0.31.1/Python3.12.14、M4/16GiB，所有重任务串行；16GiB没有变成准入上限。

### 参考链与质量结论

按照官方720面积及原首图比例独立准备1216×736、完整512文字条件、Torch CPU噪声seed2215；保持17帧/50步/shift5/CFG5与同一正负提示。官方MPS注意力全查询执行有明显换页，停止自有进程；仅在查询维度分块、保留完整K/V，实际4370-token QKV和全30层首步839040个输出逐值差0后才跑全程。50步约2072秒完成；属于有明确MPS/分块桥接的固定原版参考，不是未经修改的官方CUDA或121帧README复现。

VAE原生3D卷积形状估计单次展开约46.09GiB（估算非RSS）；3D修补后又实测2D热点，Lead有限接管补齐。最终推荐尺寸解码约404.23秒、峰值RSS9911074816字节，首latent精确保留、首RGB差0。采样工具另报physical-footprint峰值约18.5G，与RSS口径不同，不能混成一个数字或声称总内存512MiB。此前3D-only进程约307秒停止、峰值footprint25.1G的失败记录保留。

Lead与两名非实现者查看全部17帧及原尺寸抽帧：此前大面积条带未出现，主体/背景保留；但红球主要缩小、轮廓变化，不足以确认向右滚向方块。固定颜色分割仅作佐证：中心水平移动约7.35像素、面积降至73.58%，不是运动真值/模型准确率。**本样本运动质量未过**，不启动另一轮昂贵正式MLX推荐尺寸生成、不把换尺寸当已证实唯一根因、不换seed挑结果。320失败与完整T5/DiT跨设备逐元素超差继续保留；原小组件/VAE容差、精度和期望没有降低。

### 资源候选复验

- 最终固定SHA下，10个独立测试进程共133方法通过：IMAGE22、MODEL8、RUN31、prepare8、旧runner12、packaging15、I2V小数值3、旧数值13、旧VAE7、卷积14。无跳过；重复运行不累加，历史全模型失败不包含在这133项中。见`final-components/{counts,code-before,result}.json`。
- 真实320×192/17帧，生产返回的clamp后FP32及全部RGB与未改原版逐值差0，保持原3e-5/3e-5和首RGB≤1门槛；不外推所有内部张量完全相同。原适配器同输入峰值RSS10.229GB→修后5.856GB，约22.35→19.40秒。另有3个实际分块执行观察；见`full-vae-original`、`full-vae-old-adapter`、`full-vae-final`、`conv-independent-final`。
- 正式默认编译CLI的小配置320×192/5帧/2步，仅验生命周期。首图编码取消约4.91秒、解码取消约6.42秒后正常退出130，完成释放且无终态成功结果；随后的独立进程恢复生成完成，首RGB差0、完整结果与255项输入保护通过。见`cancel-encode-final`、`cancel-decode-final`、`recovery-final`；不是该小配置质量通过，也不据单次序列声称无泄漏。
- 恢复校验外壳在产品子进程exit0、输入保护及结果结构检查之后，因把旧首帧参考定位到新run目录而exit1。保留原脚本/失败；单独完成检查只修正外部参考路径，原断言不动，复查同一产物/输入摘要及首帧。见`recovery-verifier-path-error.json`、`verify_completed_recovery.py`、`recovery-final/completion-check.json`。没有编辑执行中脚本或将外壳exit1抹成0。

### 来源、预算与恢复

Sol/high受限独立CLI执行IMAGE最后一轮普通修补，预检约66.6秒、实现约428.7秒；路由/写根/网络禁用证据在`image-final-repair/*-observed.json`，隐藏服务端解析unknown。2D范围遗漏归Lead，Lead使用IMAGE一次有界接管实现，非实现者只读审核；没有新独立模型执行测试。Sol预检/实施的逐次终态用量记录在usage.json，缓存输入属于总输入，不另加；完整Lead消耗/订阅费用unknown，不重算历史或声明成本最优。IMAGE预算已用完，RUN既有预算不刷新；MODEL历史额度不改，不允许以新编号绕过。

两个自有停止实验、Worker及本轮模型/检查进程均已回收。历史原生pending_init不据此声称外部进程结束。只读合并预检曾把Git帮助的`--[no-]overwrite-ignore`误按字面`--overwrite-ignore`搜索而失败；未执行任何合并，后核选项存在，真正停止源接纳的原因是质量门槛。个人scheme原字节/SHA/index/未暂存差异保持，普通D和既有作品未启动/修改，权重原件保护通过。

**下一有限动作提案：** 优先一个固定推荐几何下17→121帧的原版参考控制，先冻结原时间位置噪声对应关系、首帧/文本/精度/步数及受控超时，再判定短时域是否限制可辨运动。它仍是待检验假说，当前没有运行121帧，不宣称更大内存必定解决。参考可用后才进行D正式路径对照；仍不可用则回到模型/profile适用性决策，不继续零散算子试调或超预算修补。通过旧标准或经独立说明的正式验收修订前，I2V阶段不得结案成功。

首发顺序仍为有限模态基础→一条真实创作组合→首用/部署/恢复/发行。AP1的H22/H23保持独立本人待办，用户离机不催解锁；不因这项质量定位新建权限请求，不启动下一模态/界面或更改发布目标。

## 2026-09-16 新用户要求：GPU优先、CPU显式备选（DEVICE-r1）

状态：新设备选择功能候选准备，不改变I2V原数值/质量失败，不刷新旧IMAGE/RUN预算。task_id仍D-VIDEO-I2V-01；子范围DEVICE-r1；run_id为D-DEVICE-AUDIT-01/run-20260916T105115Z/gpu-worker。源74384bb4c4eddc0fe075f4b705b1a3f2824103a3；实现父基线0f2797cab421e9c5dd52e75f85dddfe5a8414d96；本准备提交完整SHA由job.json固定。分支codex/d-video-i2v-01-gpu-vae，物理目录D-Worktrees/D-VIDEO-I2V-01-GPU-VAE。

用户明确：支持范围内首先实现最高有效性能路径；GPU优先，CPU作为可选备选；NPU需真实支持/测量，不加假入口。本子范围只使首图视频CLI的VAE能显式选择MPS FP32/GPU或既有CPU FP32，默认推荐GPU。不是全模型CPU模式；T5/DiT仍MLX GPU。没有App I2V入口/质量接纳，不扩公共Swift契约/签名/打包。

**Worker允许文件**：Backends/Video/Python/d_video_i2v_image.py、d_video_i2v_run.py，以及可选新增d_video_i2v_gpu.py；直接测试Backends/Video/Tests/test_video_i2v_device.py（新增），test_video_i2v_image.py、test_video_i2v_run.py（仅新增用例/必要无语义重构，既有断言和预期不降低）。不改CPU卷积实现、vendor、模型/采样/精度、包清单、其他测试/源码或本文。Lead维护本文与全局文档。Worker不commit、不联网、不派工、不运行真实权重/GPU/GUI/构建、不读凭据、不安装依赖；CPU合成夹具和内存compile允许。

### 冻结契约与行为表

| 输入/情形 | 必须行为 |
| --- | --- |
| 原`wan22-ti2v-5b-bf16-cpuvae-v1`请求 | 原CPU FP32语义、工作区修补、精度字段保持；不得暗中GPU执行。旧PROFILE常量可保留兼容别名。 |
| 新`wan22-ti2v-5b-bf16-gpuvae-v1`请求 | 编码与解码均MPS FP32；新推荐DEFAULT_PROFILE指向它；请求仍显式profile，不缺省改写输入。CLI帮助说明GPU首选及CPU选择方法。 |
| 其他profile/CPU和GPU混淆 | 原严格校验，不伪造已支持；旧结果SCHEMA兼容，新结果精度必须写GPU/MPS FP32。 |
| GPU不可用，或PYTORCH_ENABLE_MPS_FALLBACK=1 | 在重模型计算前明确失败，不默默CPU重跑；运行环境未设置时GPU路径在首次Torch导入前显式设0，值非0时拒绝。CPU路径不依赖MPS可用性。已导入Torch但fallback状态无法确认时失败。 |
| GPU适配器编码/解码 | 与CPU返回同类型/形状/自有contiguous NumPy FP32；输入不变，GPU张量不越过adapter；验证实际参数/输出设备与精度，非有限/形状错误失败。保持VAE权重固定摘要与身份检查。 |
| 生命周期 | 每次调用finally清模型cache；关闭幂等、同步后释放本实例refs；构造/编码/解码失败均不隐藏异常，不安装CPU卷积分块到GPU，不改全局/vendor；不声称driver保留等于泄漏或已归零。 |
| 执行记录 | 结果增加窄的executionDevices，记录VAE请求/解析设备、runtime、FP32、fallbackDisabled；text/diffusion明确MLX GPU。记录实际路径；不把requested当observed，不记录NPU支持。旧CPU结果原字段不变，新增字段可追加。 |
| 取消/输出错误/资源保护 | 沿用已验收检查、错误码及输出保护；drain/release后结束，不能因GPU更换吞错、改first-frame锁定/采样。 |

不要求重写现有适配器或通用设备框架；尽量复用已验证的输入/生命周期校验。GPU路径实现可选择局部组织，避免重复整份CPU适配器。普通CPU文件读取、NumPy/PNG/发布不等于模型CPU回退。

### 验收与预算

1. 旧133方法按原入口回归；新增profile/CPU兼容、GPU能力/回退拒绝、解析设备/精度记录、输入/输出设备形状类型和失败/双close，用合成CPU/受控fake实现，不以mock代替真实GPU。
2. Lead已完成原版VAE完整MPS解码先行：320x192/17，Torch2.7.1，禁CPU fallback；3133440点满足原atol/rtol各3e-5，首帧和全部RGB最大1。独立证据在run/full-mps-vae-r2。不是本候选实现验收；冷24.14秒不证明GPU更快。
3. Lead在代码固定后另行做真实GPU编码/解码对CPU参考、冷/重复分开计时、明确错误/取消恢复和最小CLI实际运行。原数值/帧门槛不降，整个I2V运动/跨设备诊断仍未通过。
4. 受限CLI Sol/high完成初次实现，最多两轮定向修复（只适用这次新DEVICE契约）；Lead/nonimplementer审核。旧IMAGE/RUN既用预算不因此重置；需修其旧数值算法或越界立即停报。
5. Writer单一；Worker结束交回后Lead才写其目录。运行工作目录即核验worktree；输出/临时为本run/gpu-worker/output及tmp。PYTHONDONTWRITEBYTECODE=1，PYTHONPYCACHEPREFIX/TMPDIR/D_TEST_TEMP_DIR均指向授权tmp；语法用tokenize.open+compile(...,dont_inherit=True)，不exec目标、默认py_compile禁用。未预授权权限拒绝暂停报告，不绕行；预先唯一缓存安全降级按现行规程。

真实解释器：D-Development/AgentTrials/D-VIDEO-V0-01/run-20260913T152419Z/venv/bin/python；直接测试PYTHONPATH指本worktree Backends/Video/Python、Vendor、Tests及已批准Pillow目录D-Development/AgentTrials/D-VIDEO-I2V-01/run-20260915T103902Z/python-deps。只用本地既有依赖。模型/用户应用/源个人文件只读。结果交output/RESULT.md，说明实际diff、测试证据、未测/异常、进程状态；Lead代提交不改作者身份。

### DEVICE-r1 初交复核与第一次修复（2026-09-16）

初交c0b7a50fa9ef5cb4b5c35dcc9a23daa6c6464a39，Sol/high同一受限CLI，未接纳。Worker自检125通过（旧133内108、新12、额外访问5）；未跑的25由Lead负责，不能相加假称完整通过。已保留同进程测试隔离失败、缺环境变量失败、OMP179临时文件警告和ps拒绝。OMP警告未提前停报，属于执行协议缺口/来源待明；未观察到成功越界或权限扩大，源保护保持。后续Worker只做stdlib内存编译，Torch行为测试由Lead在原授权下执行，不能借此扩大Worker写根。

非实现者与Lead独立确认两项：当前env0无法证明Torch首次导入时禁fallback；close在释放本实例及局部core/owner前清allocator。Lead外部review-regressions.py在固定初交上两个反例均真实失败（exit1，代码未变）。第一次DEVICE普通修复只处理这两项及GPU显式驻留入口的预检顺序，新增必要持久反例，不改变旧IMAGE/RUN预算或任何数值/输出标准。已导入且来源未知的Torch即使当前env0也拒绝；同模块在首次导入前设定0并核验的同一实例才可复用；可选注入不能绕过。释放测试需检查弱引用/最后清理的次序，不能仅计调用次数。GPU preflight先于显式驻留的runtime加载，以免依赖变化引入不确定导入时机；没有证明当前runtime必导Torch。

修复写回同一允许六文件；Worker不改本节/Lead外部反例、不执行Torch/MLX/GPU或进程枚举，syntax只用tokenize.open+compile。Lead负责全部原回归、真实GPU/CPU与取消恢复。初次DEVICE交付加本次修复1，之后最多剩1轮普通DEVICE修复；原阶段质量停点不变。


## 2026-09-16 DEVICE-r1设备选择收口：功能候选通过，效率与I2V质量未结案

源起点74384bb4c4eddc0fe075f4b705b1a3f2824103a3；本轮固定受测代码`ba978d508c91db55f11fc008bec25ccf6baf0f1a`，在`D-Worktrees/D-VIDEO-I2V-01-GPU-VAE`、`codex/d-video-i2v-01-gpu-vae`。新GPU/既有CPU profile仅选择VAE，T5/DiT仍MLX GPU；GPU首选推荐不暗改旧CPU配方。请求profile仍必填。尚无App I2V入口或全模态设备选择，不将此候选合入/推送源代码。源仅同步设备原则/修复清单/本记录，生产仍3898e1d020cbc356417e04e7c9f761db1a910725。

外部证据E=`D-Development/AgentTrials/D-DEVICE-AUDIT-01/run-20260916T105115Z`，最终候选/源文档SHA与push写E/final-receipt.json，不为自引用反复提交。当前解释器Python3.12.14、Torch2.7.1、MLX0.31.1，M4/16GiB；现有模型/精度/依赖不变。GPU为MPS FP32、显式禁CPU fallback，未知预加载Torch拒绝；原CPU FP32及工作区方案保留。

### 固定版本的验证与明确未通过项

- `components-final`：11个独立进程共151方法，旧133加18新方法，0失败/0跳过；包含原数值、输入/输出保护、profile与生命周期合成检查。`review-red`在初交c0b7a50失败的两个独立反例，`review-green`在本版通过，未改反例。非实现者静态复核无阻断；记录一项非阻断测试缺口：驻留顺序用例当前观察device_info而非_runtime_components调用，实际生产代码顺序正确。
- `candidate-vae`：真实GPU编码与固定CPU参考最大差8.441507816314697e-6，真实17帧解码最大差2.104043960571289e-5，按原atol/rtol各3e-5均0超限；首/全部RGB最大1。实际参数及编码/解码输出均mps，非mock/请求标签。CPU编码/完整解码float及RGB差0。输入自有拷贝、NaN拒绝后重复编码、双close和关闭后拒绝均通过；输入/代码/权重摘要保持。
- 同一VAE探针GPU encode约1.94/decode22.01秒、随后CPU约0.33/16.31秒；早先两次warm原版GPU28.39/36.00秒、CPU20.09/19.40秒。顺序/传输/缓存边界不同，不能直接推广硬件排序，但**不能声称GPU已更快**。GPU关闭后active=0、driver仍约6.47GB，随后进程正常结束；不把driver保留断言为泄漏，也不忽略其资源影响。
- `gpu-cancel-encode-corrected`、`gpu-cancel-decode`：真实GPU边界取消分别约4.11/8.68秒后exit130，无终态成功结果/发布清单，输入255项保护。不是GPU瞬时可中断承诺。
- `gpu-recovery`：取消后新进程正常生成，CLI全程约121.25秒，首帧原参考最大1，完整帧/请求/摘要/设备记录检查通过。`cpu-explicit`原CPU profile真实生成约104.10秒，首帧差0，VAE记录CPU而T5/DiT仍GPU。均为320x192/5帧/2步/seed2215的生命周期小配置，保留原默认编译和显式10GiB MLX驻留范围，不是运动质量/全机内存上限/多次无泄漏证明。两次独立单样及不同文字阶段耗时不足证明端到端哪种普遍更快。
- `gpu-cancel-encode`第一次Lead误用事件名encode而非既有encode-reference，未发送取消，子进程完成exit0，外壳正确exit1；保留原结果，**不计取消通过**。核对旧R5事件后，仅用新目录/正确参数重跑，原脚本断言及实现未改，见cancel-trigger-correction.json。这是Lead验证输入错误，不算Worker普通修复。

当前功能候选可供后续集成审核；最高有效性能目标仍待测量/优化，原I2V运动质量及完整T5/DiT数值超差仍未过。没有将这151方法或VAE成功合并成全视频质量通过，也没有换seed/改精度/容差/黄金样例。H22/H23与原作品、普通D保持不动。

### 来源、预算与恢复检查点

Sol/high完成DEVICE初交及1轮修复；请求与可观察上下文一致、同一受限workspace-write CLI、网络禁用，隐藏服务端解析unknown。Lead冻结规则、独立反例/真实测试与提交，没有代写生产实现；两名非实现者分别审代码和政策，未声称另一个模型执行了实测。初交OMP179警告未及时停报的协议缺口保留；未发现成功越界，修复仅stdlib内存编译，不重复碰撞/扩大权限。旧IMAGE/RUN预算不刷新；DEVICE还剩1轮普通修复，未使用Lead实现接管。

E/worker-usage-observed.json核对本次新线程3次调用：预检140.33秒、初实现810.84秒、修复455.26秒。终态CLI用量与同线程累计total_token_usage匹配，**不把三次累计值相加**；按相邻快照保存增量，缓存输入是总输入子集。最终累计输入5418547（缓存5242112）、输出57692；完整Lead消耗/订阅实际费用unknown，不重算历史样本，不据一次交付称成本最优。

本轮自有Worker、GPU/CPU/检查进程已结束并回收；不据此宣称所有历史原生pending任务或系统进程结束。源scheme字节/SHA/index/未暂存状态与起点一致；代码工作树保留、原件/权重未改。最终候选文档提交比受测只加本节，源仅7份指导/任务文档；具体SHA/保护/远端核对见外部回执。

下一有限动作：依设备清单E01先针对实际VAE算子/传输/缓存与代表性几何建立端到端性能对照，保留CPU选择；再承接既有推荐时域/运动质量控制，不启动广泛参数扫描。E02歌声神经声码器GPU路径是下一个高优先修复，ORT/NPU逐项核实，E03设备公共记录与E04预算准入分别安排，不新建万能框架。上述计划不意味着本轮已执行，也不以全部NPU支持阻塞有限首发。


## 2026-09-20 R6：推荐几何121帧参考控制（已获本阶段执行授权）

规格R6-REF121.1；源起点8c44bb4ba57856bfa77c8419bc3283e8d16e0d4f。用户批准上一阶段提出的有限参考/质量收口；不是追加旧IMAGE/RUN修补预算或提前接纳I2V。Lead只在独立REFERENCE121文档工作树及本次外部证据目录准备验证器；原候选74cf41f、CPU0f2797c、GPUc18179c均保持干净且不改生产算法。本人仍离机，H22/H24不催办。

固定1216×736/121帧/24fps/50步/shift5/CFG5及原提示、权重、精度。Torch CPU seed2215先重新生成并逐值核原48×5×46×76噪声，再从同一生成器续取26片沿时间拼接；原五个时间位置和首图latent不变。称受控时域扩展，不冒称官方一次randn或未经修改CUDA复现。实际latent48×31×46×76，27094 tokens，首874 timestep为0；原FP64 time/RoPE仍显式CPU桥接，神经网络扩散MPS。

新外部attention验证器只分query64，self全部27094 K/V、cross全部512 K/V保留，输出预分配；不运行完整Q×K巨矩阵。第一实际self及正/负cross各全query用另一query31分区对照原0.02/0.02，并对固定不连续query额外显式FP32 softmax公式检查（先保留原Q/K按V的BF16转换）；分别声明全覆盖分区一致性与抽样公式检查，不代替完整D模型数值。解码复用已验CPU FP32 VAE分块候选，只作明确参考，逐帧写RGB和分页联系图避免遗漏后帧/额外全片复制；首RGB≤1不变。

一次实际长序列启动：加载至首个完整正负采样步≤900秒，扩散总≤4小时，成功才解码≤1小时；原14GiB MPS进程allocator测试设置保持，不根据物理RAM预拒绝。时间调制e0约1.86GiB、工作区等计入实际风险，不能把query/512MiB卷积块当总内存保证。失败/非有限/旧容差超限/保护变化/超时/OOM即留证停止，不换seed、不增加扫描、不编辑运行中的脚本、不自动再跑整模型。首步后记录剩余时间估计与实际峰值口径。

只有完整121帧首图/来源检查通过、无严重色带且红球向右运动可辨，才进入同输入D数值检查；其旧全模型失败仍须满足原门槛，不能据参考过了就启用App。参考/资源仍失败则该控制以失败结果收口，I2V产品保持阻塞，提出模型/profile或可用硬件的具体后续选择。Lead实现外部验证，非实现者先审核冻结脚本、后独立看证据，不宣称另有模型实跑。源scheme原字节/索引/未暂存状态保护，普通D/作品/旧证据不动。

本run与最终结果见外盘`D-Development/AgentTrials/D-VIDEO-I2V-01/run-20260920T114813Z-reference121`的spec/freeze/验收及final-receipt；准备提交完整SHA在外部记录。阶段结束区分“控制实验已结束”和“I2V产品已通过”，最终文档SHA不自引用。

冻结前非实现者发现外部guard两项缺口（保护检查异常漏终态、leader退出后同组后代未回收）。Lead先以任务自有受控输入复现失败，再最小修补；输入消失、孤儿后代与正常结束三项预期匹配，独立只读复核解除阻断。是模型启动前的验证器修补，不冒充生产算法返工/模型通过；原失败、修补摘要与独立审阅在本run保留。小规模attention三方法（含六组尺寸/精度子例）通过，噪声准备已核原五片逐值相同；真实121帧尚未运行。

### R6结果：固定参考控制已结束，资源失败；I2V产品仍未验收

2026-09-20，本次准备提交`74936ddd8789223dab58fcf797867c2fc3c6746a`仅追加冻结规格；实际验证的是外部固定脚本/输入清单`inputs-run.json`（SHA256 `8dcdc109d60dc7630bf1d7da736c6f31b0d84338196e53b406635ca9e1b47f69`），不是该Git提交中的新产品实现。源生产与起点`8c44bb4ba57856bfa77c8419bc3283e8d16e0d4f`完全相同，原I2V三个候选未改/未接纳。解释器Python3.12.14、Torch2.7.1、MLX0.31.1、macOS26.6.2、Apple M4/16GiB；权重revision/原始LFS摘要与旧参考14项交集已核对，未下载/换模型。

| 检查 | 实际结果与边界 |
| --- | --- |
| 外部验证器与准备 | 6个源码内存compile通过；attention 3个CPU方法通过，其中一方法含6组尺寸/精度子例；guard三个受控用例分别匹配失败/失败/成功，不能累加成产品推理通过率。31片latent/噪声保留原5片逐值相同，首latent精确。原guard先失败后修补，见guard-red/guard-fixture-results及preflight-review。 |
| 唯一实际121帧模型尝试 | 三个权重分片均加载到MPS，完成加载active=10,136,722,176字节。首次正条件前向在固定原版`wan/modules/model.py:468`的`time_projection`线性输出处OOM；对应FP32输出张量按形状计算为1,997,586,432字节，运行时报告申请约1.86GiB失败；错误原文报告active约12.01GiB、其他分配161.45MiB、限额14GiB。没有降低参数或关闭allocator保护重试。 |
| 时间/资源口径 | 模型脚本约31.03秒（含约29.68秒加载），guard从子进程启动含导入/后置保护约42.76秒；均未触及900秒/4小时限时。RSS峰值4,672,815,104字节与MPS分配是不同指标，未测全机峰值，不合计成统一内存峰值。清理active=0，driver仍169,295,872字节；随后进程退出1、主进程回收、自有组消失，无强杀/超时。 |
| 未执行门槛 | `steps=[]`、`attentionChecks=[]`，因此真实27094-token分块/数值尚未运行；没有首步、最终latent、121帧解码或运动评价，后续D完整数值检查不触发。小CPU检查与旧17帧真实分块对照不能替代这些缺口。 |
| 文件保护 | 64项前后身份/摘要相同，清单未变；旧权重/输入/候选只读，源scheme字节/摘要/索引/未暂存状态不变，普通D/作品未操作。 |

**结论只限本次固定14GiB allocator配置和参考实现的资源失败。** 它不是“16GiB一定不能跑”的证明，不是模型/软件永久容量上限，也不能据此断言大Mac必然通过。推荐尺寸121帧的画质仍未知；旧小尺寸彩条、17帧运动不足、完整T5/DiT数值超差仍有效。没有新增可用I2V入口，不把失败控制称为整个I2V产品阶段完成。解码原计划CPU仅是明确的参考支路，本轮未执行；生产GPU首选与精度政策保持。

非实现者`/root/i2v_reference_review`独立核对报错位置、空steps/attentionChecks、64项保护和终态，确认没有将资源失败推断为质量结果；其仅只读审核，没有独立运行模型。Lead实现外部验证器、修正两项准备缺陷并运行测试，没有生产算法修改；本次无实施Worker/普通算法修复，IMAGE/RUN/DEVICE各旧预算不刷新。只读原生审核请求继承父设置，可验证实际模型为unknown；不声称这是受限低价CLI实施样本。可观察墙钟记录于各run；完整Lead/审核token、订阅扣费unknown，不重算历史或据此判断模型性价比。

证据：本run的`launch-context.json`、`freeze-inputs.json`、`acceptance.json`、`diffusion/{result.json,stdout.log,stderr.log,before.json,after.json}`、`diffusion/data/result.json`、`postflight-review.json`与`final-receipt.json`。脚本/小夹具及原始证据持久保留在工作树之外，未把权重/大日志入Git；最终状态提交只更新三份获准文档，具体候选/源/推送SHA写外部回执。

### 下一有限阶段提案与恢复边界（尚未实施）

建议先解决**已定位的I2V内存可运行性阻塞**，不插入普遍提速或参数搜索。下一次明确审批时需单列新增资源修补范围/预算，不能以R6诊断或新编号自动追加已耗尽的旧算法修复：先核查原时间条件在首图/其余位置的重复计算与后续使用点，研究保留原精度/算子语义的有界物化；先以独立公式、已有小规模与固定真实层反例验证原容差，再尝试同输入完整正负首步。只过首步仍不等于50步/质量通过；完整参考和D数值/画质须按顺序通过，失败保持明确出口，不无限串补。是否能降低所有后续峰值尚未知，不能承诺只修时间投影即可完整运行。较大Mac的同输入对照是独立备选，待实际有设备再协调，不在本人离机时新增点击事项。

如资源方案需改变精度/模型或突破新增预算，应报告具体取舍；不得为赶首发降低质量门槛或默认启用候选。阶段由Lead冻结关键数值/资源契约，单一数值实施者与非实现者审核分开，真实GPU排队；不为该串行问题制造多个写Worker。已有文字/图像组合、首用/部署/恢复/发行仍保留下一位置，I2V失败不变成整个项目无限等待的理由，但本轮不自动启动那些工作。

恢复检查点：本阶段参考控制已按失败出口收口；原I2V仍阻塞。源/候选的最终文档SHA与push见本run/final-receipt，产品代码仍起点8c44bb4；scheme继续未暂存，源索引应干净。自有推理进程已回收、无继续运行任务；独立review只读已结束。H22候选栏定位、H24GPU歌声试听仍在集中清单，本人返回时处理，本轮未催解锁、未开GUI或新阶段。

## 2026-09-20 R7：16GiB适用性判断与限定资源修补（新增用户授权）

用户在R6后要求判断16GiB是否够用、区分实现与硬件并完成本阶段。本轮授权据此明确为资源可运行性调查/一个窄修补，不刷新旧IMAGE/RUN算法精度修补。源基线14be06f870f048dd6fd3f57a700c53a7021e21a6。规格R7-RESOURCE.2，同一task ID。只读资料显示原固定网络逐token重复计算两种时间条件；需实测等价修补能否降低峰值。官方24GB独显示例不是Mac最低规格保证，CPU/MPS共享内存不能靠搬到CPU就宣称物理内存下降。

### Worker最小契约（只限诊断实现，非产品启用）

允许新建`Backends/Video/Tests/wan22_compact_time_reference.py`、`Backends/Video/Tests/test_compact_time_reference.py`两文件；其余全部只读。Lead维护本记录、外部装配/验收和提交。原vendor、backend生产、工程、依赖、签名、个人scheme、源/其他候选禁止写；不改原精度/阈值，不联网、递归或提交。Sol/high受限workspace-write CLI，工作树与本run worker/output,tmp为唯一写根，共同Git只读。Worker只执行stdlib tokenize.open+compile内存语法检查，不import目标、不执行Torch/MLX/构建/GPU；Lead运行实际行为测试。未知拒绝/副作用停报，不自行绕行。

接口：`install_compact_time_reference(model, *, first_tokens: int, seq_len: int, chunk_size: int=256)`返回有`close()`及context manager的局部适配器；只作用于指定模型实例，不能改类/global、原参数或dtype/device。重复安装拒绝，close幂等且恢复所有注册hook/instance forward，安装失败同样撤销；不持有新的权重副本。仅固定单batch、首first_tokens与其余位置两种常量时间条件的诊断支持，输入不合形状/分段常量须报错，不能默默近似。

通过原time_embedding输入的局部prehook验证两段常量并选两个代表行，原FP32 time_embedding/time_projection计算和权重不变；e/e0仅两个位置。block/head须按首图/其余片映射使用条件，不能expand后重新生成全长六路modulation。保留原运算顺序、norm/GELU(tanh)、混合精度以及attention/全K-V/位置编码/残差语义；仅对token独立affine/residual应用条件作有界分块；norm、FFN、head线性层仍按原完整形状调用，原attention不在此包修改。返回原形状，输入/权重不改。禁止改latent几何、step、seed、提示、scheduler、噪声、首帧锁定或CPU/GPU执行选择；没有新的CPU神经网络回退。

关键反例/验收：首段长度1或末尾1、chunk跨首段边界、非整除chunk、相同两时间、第三种时间/非法形状/布尔或越界first/seq/chunk、context异常和双close、安装后调用原样恢复、参数/输入未变。保持头/块中FP32调制与BF16普通权重，连续全部token输出，不能只验第一/末行。Worker测试可合成，Lead必须用固定原版真实定义作独立对照，CPU与实际MPS的FP32时间嵌入/时间投影/调制按3e-5/3e-5、mixed块/完整模型按原0.02/0.02，0超限/全有限；该对照不代替旧D数值门槛。测试也不可更改冻结门槛。

### Lead验收、限额与终点

先固定脚本/输入、组件与独立原版小模型对照，再以原真实时间层/块作数值检查（不加载全模型CPU拷贝）。通过才以R6完全相同1216×736/121/50/24fps、Torch受控噪声与条件运行MPS参考，保留14GiB allocator和无隐式fallback。先首步完整正负≤30分钟（本阶段显式延长以测真实计算能力），如过首步再50步总≤8小时，decode≤1小时；过程采样MPS active/driver、进程RSS、系统压缩/交换分开。不以物理RAM预拒绝，不关闭保护。资源失败或数值失败记录明确归因，不能降低分辨率/帧数/精度或参数扫选通过。原64项只读保护与进程组回收复用。

本次新资源实现限初交+至多两轮有明确原因的局部修复，可一次有界Lead收尾；旧算法预算不增加。不是每出现新OOM就任意扩成重写。涉及全网流式调度/磁盘权重轮转或新精度/新模型时不在本窄修补内。若不能在此配置完成，给出“当前实现/配置在本机不足”和硬件/实现各自证据，不能装作产品通过。若完整参考画质通过，才进入原D数值质量门槛；原超差仍未解决则产品继续隔离，不靠本轮预算修旧算法。GUI与本人验收H22/H24继续独立，不催用户。

结果必须区分16GiB是否足以一般开发、此具体5B长视频是否实际可用、是否达到质量验收；不得将诊断可运行当D支持发布。验证通过的测试工具与有限状态记录可提交工作分支，原未验I2V产品不默认接纳。原始证据放本run外盘永久目录；run/版本/保护/预算/来源由Lead追加，最终SHA在外部回执，避免自引用。

R7冻结前非实现者建议采纳为R7-RESOURCE.2：首个候选只压缩/分段使用两组时间条件，撤回.1对FFN/head线性分块的选择，避免混合变量；FP32条件通路明确沿用3e-5/3e-5而非attention的BF16门槛。先真实条件层（全50个时间值）/小模型/真实块检查再全网。其“精确0误差”建议记录测量但不擅自替换既有FP32容差；不新增精度要求或降低标准。此修订在派工前生效，没有Worker实现或修复预算消耗。

<a id="r7-results"></a>

### 2026-09-21 R7结果：代码开销已证实，整网止于数值门；资源调查收口

**限定资源调查已结束，I2V产品未通过；不接纳或默认启用候选实现。** 用户进一步要求区分代码与硬件并评估流式加载，本轮已完成这些调查；没有把“考虑流式”当成流式加载研发已经启动。实际执行日为2026-09-21，外部run沿用2026-09-20创建的目录名。

源基线`14be06f870f048dd6fd3f57a700c53a7021e21a6`；资源候选工作树`D-Worktrees/D-VIDEO-I2V-01-RESOURCE`，分支`codex/d-video-i2v-01-resource`。准备提交`c9cdc93328f5b70600d799822a1195bed76d4ca8`→冻结执行基线`3fcf851294f15a86561ddeb9af6c1e18baa04a42`；Worker初交`d8c3f9e667565d57950b4052dc918c350aa71bfe`，修复1 `f2111a13393784e642a7547f3df101fed039408c`，修复2/最终实际受测候选`7a4aec0d9846cd21f62ead24681b69d5aab1d6e2`。新增仅两个诊断文件，生产后端没有改写。

解释器Python3.12.14、Torch2.7.1、MLX0.31.1、safetensors0.7.0；Apple M4/16GiB、macOS26.6.2。Wan2.2-TI2V-5B固定revision `921dbaf3f1674a56f47e83fb80a34bac8a8f203e`、原定义`42bf4cfaa384bc21833865abc2f9e6c0e67233dc`。1216×736/121帧/24fps/50步/shift5/CFG5/seed2215、R6噪声及输入、14GiB allocator、普通BF16/敏感FP32均不变。NN在MPS；原FP64时间/RoPE CPU桥明确保留，无隐式CPU神经网络回退。不是未修改CUDA官方复现，也不是完整D数值通过。

#### 实施、修复与有界Lead接管

Sol初交的独立寿命检查发现中间张量未在最后使用后释放；修复1释放局部引用，但残差闭包自引用仍使结果依赖循环GC；修复2以普通闭包状态去掉自引用，新增禁用循环GC时的重复释放反例。原红灯证据保留，没有靠提高内存阈值通过。

直接将时间网络矩阵运算从27094行缩为两行虽通过时间层容差，真实block0仍有71项超出原`.02/.02`，因此拒绝该数值路径。控制实验改用原完整形状GPU时间网络的原值代表行后，同一块与输出头误差为0，支持将这次偏差定位到该形状变更；不外推全部模型等价。

随后按本轮一次有界Lead收尾冻结`R7-RESOURCE.3 staged-original-time-1`（外部`bounded-lead-closeout-spec.json`）：在扩散权重常驻前，仍用原完整形状GPU运算准备50个实际时间点，逐行精确检查两组常量，再保存拥有独立存储的FP32代表值。正式诊断调用严格核对时间、条件、顺序和正负两次调用，替换直接两行计算结果；不平均、不降精度、不回退失败路径。该调整只在外部验证器，未改Worker两个文件。后续整网再失败即停止，已经执行此停止条件；旧IMAGE/RUN预算和两轮Worker修复额度不刷新。

#### 验证矩阵（不将不同覆盖范围累加为总通过率）

| 检查与本run目录 | 结果与覆盖边界 |
| --- | --- |
| `cpu-repair2` / `lifetime-green` / `small-original` | 12个CPU方法、6个独立寿命检查、6个原定义小网络条件分别通过；含首段/块边界、恢复、输入/参数保护。初交和修复1的失败分别保留。小网络不是5B全网验收。 |
| `real-time` | 实际50个scheduler时间点FP32时间层/投影全部通过3e-5/3e-5；block0/14/29的12个完整token调制/残差使用点同门槛通过。不代表完整attention。 |
| `real-block` | 直接两行时间计算路径失败：真实block0在83232768元素中71项超限，maxAbs=0.2520751953125；不是OOM。该路径没有进入整网运行。 |
| `same-condition-control` | t=1000诊断控制：原完整形状时间条件的两代表行使block0/head全量误差0；输入/参数未变。1000不是实际首时间999，两路共用Q64 attention，不能据此证明独立attention正确。 |
| `staged-binding-cpu` / `staged-time` | 3个绑定CPU方法通过；50个实际时间点每行均确认为两组精确常量，文件回读/参数保护通过。e/e0表总8601600字节（约8.20MiB），加编码输入/时间号总8704400字节；不是整个模型内存。 |
| `staged-first-block` | 实际首时间999，缓存值与新鲜原值精确相同，block0/head误差0，输入/权重未改。共用Q64 attention，仍不替代独立数值门。 |
| `diffusion-staged`（唯一整网资源尝试） | 全部权重加载后越过原时间投影OOM；首个正条件block0 self-attention的Q64/Q31全27094 query比较已越过零超限断言，随后13个固定query×24头×128=39936元素的独立FP32公式检查有158超限，maxAbs=0.134765625。旧`.02/.02`不变，立即失败退出1。未完成首块/正负首步/50步，没有最终latent、解码或新视频。 |

独立公式检查在统计返回前抛错，终态`attentionChecks=[]`不能解释为“没有进行任何attention检查”；全查询分区比较已完成的判断来自冻结代码控制流，未保存的maxAbs不补造。此前零误差块对照两边都使用相同Q64实现，因此与本次独立门失败不矛盾。现在不能进一步断言偏差一定来自MPS BF16 SDPA、FP32公式或哪一种内核；需新的最小对照才能定位，不能用增加内存或放宽误差掩盖。

#### 16GiB是否够用：三种不同结论

1. **一般开发与既有小配置：仍可继续。** 既有图文音频/T2V证据保持，本轮没有重跑或增加它们的支持范围。没有理由将开发机换成产品能力上限。
2. **可避免的代码开销：确有实证。** 常驻转换权重10136722176字节（约9.44GiB）；原全长e/e0及逐块调制可同时产生约4.03GiB的张量（静态推导，非测得全机峰值）。相同权重和allocator下，分阶段精确时间准备已越过原1.86GiB申请失败点并进入真实attention；这不是纯硬件无能为力。
3. **此121帧负载的完整实用性：未证明，内存余量紧张。** 整网脚本87.503秒、含导入/保护的guard99.666秒；这次先撞数值门，没有OOM/超时。10–80秒8次系统样本swap used从1744.56M升至最高6582.38M；压缩器最高7041204224字节，子进程ru_maxrss=6073139200字节。它们口径不同，不能相加为统一内存峰值，也不能把全机交换全部归本任务；首样本不是空闲基准。MPS完整峰值未取得，首步/全片耗时未知。14GiB是本次allocator限额，不是物理16GiB或产品限额。

最终释放active=0、driver=117276672字节；driver缓存不能据此写成泄漏或物理峰值。guard确认退出1、reaped、自有进程组消失、82项前后文件身份/摘要不变。未操作普通D/作品/GUI；不需要真人解锁。资源样本汇总见`resource-observation-final.json`。

#### 流式加载评估：可以做独立原型，尚不能作为产品解决方案

固定safetensors布局清楚：30块，每块27个参数；第14/29块跨分片。每块转换后约312.22MiB，公共权重约300.51MiB；单块加公共部分静态约612.73MiB，**只算权重**，不含激活、转换暂存、页缓存与系统。按需从SSD读下一块、GPU执行、同步后卸载上一块具备试验条件。单纯把完整权重搬到CPU仍占统一内存，不能冒称流式降总RAM。

必要门槛：其余块保持meta而非完整CPU state_dict；固定权重/shape/dtype/device逐项一致；初版不预取；处理跨分片与取消/失败释放；反复加载后的活动内存无持续残留；分别量测RSS、MPS、页缓存/交换与实际I/O。所有NN保持GPU、既有精度不变，内存较大机器可保留常驻模式；策略与物理内存建议分开，不写死16GiB。

代价不能忽略：当前原FP32存盘权重若50步×正负两路逐块读取，逻辑读取约1.964TB；文件缓存可能减少物理读取，实际速度未测，预先哈希还会预热缓存，不能冒称冷盘性能。现有safetensors0.7.0没有新backend参数，本轮未升级。**流式只解决权重驻留，不解决当前attention数值门或固有计算量；本轮没有实施流式加载。** 依据/计算见`static-capacity.json`、`streaming-assessment.json`，版本/接口实际使用前再核验，不依赖未安装的新特性。

#### 来源、预算、版本与恢复检查点

独立受限CLI实施者`gpt-5.6-sol/high`，线程`01a0bed7-8e13-7a40-8bd0-67ad4997ee57`；四次运行分别预检、初交、修复1、修复2，turn_context确认模型/档位/任务cwd、workspace-write、网络关闭和唯一输出/tmp写根，共同Git只读；服务端隐藏解析unknown。初交调用`/usr/bin/python3`意外触发Apple启动器/xcodebuild缓存告警、另有ps拒绝，Worker未立即停报的事实保留；未观察到成功越界或权限扩大，未捕获的全系统副作用unknown。后续两修复使用固定外盘解释器和内存compile，无新增拒绝；不把旧协议事件改写为合规。

Sol初步实现＋两轮修复；Lead提供反例/定位、运行行为检查并亲写外部有界时间准备与绑定。非实现者`/root/i2v_memory_cause_review`仅独立只读检查代码和证据，没有另跑模型，不能称独立实测。其启动前/后核验均保留；全网失败后不新增Worker、不重试新算法。

本次CLI用量是累计快照，四次增量相加等于最后累计：输入1366526（其中缓存1271552，不能再相加）、输出34512，四次可观察墙钟分别58.485/481.664/148.437/121.789秒；不是四个累计值求和。完整Lead/审核消耗与订阅费用unknown，不重算历史任务，不据此判定低价模型成本最优。来源与环境事件见本run `worker-usage-observed.json`和`worker/*-event-review.json`。

持久证据根为`D-Development/AgentTrials/D-VIDEO-I2V-01/run-20260920T124234Z-resource`。每个上表目录有guard终态/日志及适用的data结果。最后唯一整网冻结清单`inputs-staged-run-frozen.json` SHA256 `8057d3841432763c6a75dcb52a45847dba6d414b750fd83f4e5f54ff5f88e6f9`；实际时间表SHA256 `c2ea1f98f9125ac1052b1de967134758a6e70762fc553230c7b07b28c3581197`。外部脚本按清单摘要关联，不能只用Git SHA代替它们的版本。完整运行/保护/审核见`before-full-launch.json`、`postflight-review.json`、`acceptance.json`及最终`final-receipt.json`；没有所谓`staged-evidence`文件，不引用不存在的索引。

源本次只接纳任务/当前行动/目标三份文档，生产代码不变；失败诊断文件留在资源候选，未合入/推送该候选。独立结案工作树`D-Worktrees/D-VIDEO-I2V-01-RESOURCE-REPORT`从源14be06f建立，避免把失败实现带入源；最终源/远端SHA写外部回执，不让提交自引用。个人scheme SHA256仍`ca3635d88aa5a15397b90e528667c66c0e6db7e596176e885c79d194b544206c`，原index blob `9c76916bdc97c2d4298cefe64e0b0fae3380573e`与未暂存1→6完整差异须保持。旧候选/证据保留，自有计算和Worker结束。H22/H24不变，H23不重开。

**下一有限阶段提案，尚未实施**：先收敛首个self-attention的独立数值门，抽取固定真实Q/K/V，分开BF16 SDPA、显式FP32与独立高精度抽样参考，定位算术/框架/对照差异，保持原容差；不重新跑全片碰运气。与之独立可准备逐块SSD加载原型，仅block0/14/29固定权重逐值、实际块输出、重复加载/取消/清理与内存/I/O；数值未过时不得将流式整网生成称接纳。阶段应单列新范围/预算，不能刷新已耗尽R7或旧IMAGE/RUN修复额度。完整正负首步→50步→解码/运动→D数值仍逐门触发；首发其他无依赖能力组合/首用/部署继续保留位置，不无限等待I2V。

## 2026-09-22 R8：固定注意力归因与单块流式原型（已获阶段批准）

用户批准上节下一阶段，并返回Mac集中办理。源基线`d2ab56bb7bab15c8745d6ea06a5039bb608f6dea`，规格/契约`R8.1`，batch/task沿用`D-VIDEO-I2V-01`。仅两个独立诊断实施包ATTN/STREAM，Lead掌握共享验收、真实GPU与文件保护；生产后端/GUI/精度/依赖不改。R7初交+两修复+Lead收尾已经结束，旧失败和预算保留；本次新包初交+至多两次普通修复、一次有界Lead接管，超限停止，不能转回修R7或旧完整D算法。执行基线是本节准备提交，完整SHA记录在各job/request，禁止从旧源漏读契约。

两个Sol/high受限独立CLI实施包均仅写自己的两份新文件；只用已知外盘Python执行stdlib内存compile（tokenize.open正确处理编码），行为/CPU/真实模型检查由Lead串行运行。网络关闭、禁止递归/提交/GUI/模型/构建/权限/安装。工作树及专属output/tmp为唯一写根；任务记录、源、原权重、其他任务、共同Git均禁止写。未知权限事件立即停报，先核前轮异常再派修复。worker只读预检，Lead核验实际turn_context的模型/目录/权限后才发IMPLEMENT。运行限15分钟；目录、基线、模型不符不以重试猜测。旧`/usr/bin/python3`会触发Apple启动器，明确禁止，不能再当无副作用检查入口。

### ATTN：形状保真的诊断矩阵

允许仅新增`Backends/Video/Tests/wan22_attention_diagnostics.py`与`test_wan22_attention_diagnostics.py`。最小接口`run_attention_matrix(q,k,v,*,positions,device)`：输入CPU上Q/K FP32、V BF16，单batch `[1,N,H,D]`、全有限、同N/H/D；positions为非空、唯一、升序有效整数且拒绝bool。device显式`cpu`（合成检查）或`mps`（真实检查），禁止隐式回退。不读权重/磁盘、不变更输入或全局配置；返回普通dict，输出为拥有独立CPU存储的tensor，调用者管理保存。用局部inference_mode和SDPA MATH上下文，恢复上下文，不凭MATH名称推断MPS内部精度。原矩阵/位置参数不可搜索择优。

返回`outputs`键至少含`A_bf16_q64`、`B_bf16_q31`、`C_formula_fp32`、`C_bf16`、`D_sdpa_fp32`、`D_bf16`、`F_cpu_fp64`，形状均`[1,len(positions),H,D]`，前三组计算使用相同的BF16量化Q/K/V数值；C/D先保留FP32实际结果再显式BF16。A/B严格调用这些位置所在的完整原64窗口及窗口内31/31/2子窗口（尾块真实长度），之后再取选定行；不得先缩为13行SDPA。C为原验证器语义的显式FP32 `softmax(QK^T/sqrt(D))V`，全K/V；D为相同BF16值升FP32的SDPA（同Q64形状），仅诊断，不能替换产品策略；F为相同BF16数值的CPU FP64 SDPA。计算阶段/窗口/耗时作为标量元数据返回；不得以路径差异本身抛失败掩盖完整结果，输入/非有限/运行错误须明确抛错。

Lead独立实现E：逐头NumPy CPU FP64稳定softmax/点积，从相同BF16量化值升精度，不与Worker共用公式函数。以解析小夹具和E/F在1e-10/1e-10内全部一致确认高精度基准；此门仅验证新FP64参考，不替代原BF16门。每条公共BF16输出与E显式BF16舍入结果及未舍入E分别按原`.02/.02`记录超限/最大误差/坐标，A-C仍保留旧门。只有复现原失败、E/F可靠、A对E通过而C对E失败并有具体运算定位，才能认为验证器有误；A/C都失败或各自对E通过但互差超限都不能这样归因。不得升精度替换生产、放宽阈值或把分区相等当独立正确。

Lead只加载原meta模型首块与必需公共权重，在实际999/positive/首个self-attention的RoPE后、官方BF16转换前捕获完整Q/K/V，然后通过专用捕获终止退出，不执行其他块/全片。固定几何1216×736/121、R6输入/噪声、R7精确原时间表、原权重/桥/精度；Q/K预计FP32，V BF16，保存独立CPU数据与V的uint16原位/shape/stride/hash及来源。固定13位置`[0,1,30,31,63,64,873,874,4369,4370,13547,27092,27093]`，六个Q64窗口起点`[0,64,832,4352,13504,27072]`、全27094 K/V，默认缩放1/sqrt128，无mask/causal/dropout；不能将未量化rawQ/K的高精度结果冒作主基准。捕获不等于完整R7重放；若旧失败未复现，只记录未复现。

CPU反例至少含解析常值V、手算小softmax、原窗口/子窗口与非整除尾部、顺序/重复/越界/bool positions、dtype/device/shape/非有限输入、输入不变与输出独立存储。Lead限一次固定真实矩阵，确有明确待辨原因时最多一次单变量局部控制，先记录依据；不得扫描chunk/seed/换模型/依赖。真实捕获和矩阵各≤1800秒，CPU独立参考同限，不设不可信速度承诺。未复现或无法归因也有明确出口，不因此串入整网修补。本阶段不执行新50步全片。

### STREAM：单块租约，加载/计算/释放独立验收

允许仅新增`Backends/Video/Tests/wan22_streaming_block_reference.py`与`test_wan22_streaming_block_reference.py`。最小接口`BlockLoader(meta_model, model_root, frozen_manifest, *, device="mps", checkpoint=None)`，`with loader.resident(block_index) as block:`及幂等`close()`。只允许0/14/29整数（拒绝bool）；同时一个租约，嵌套/重入/关闭后调用拒绝；调用者在作用域内使用块并负责放弃输出/额外参数引用。close在活动租约内拒绝，退出租约清理后可close。不执行网络/推理、不改attention/time/RoPE/全局类，不管理公共权重；构造时仅元数据，其余块保持meta，不预取、不建全CPU state dict或BF16文件。CPU device仅用于明确合成fixture，真实运行必须MPS，不回退。

Lead提供版本1 manifest：`schemaVersion`、`blocks`（字符串0/14/29映射参数记录数组，字段name/shard/shape/sourceDtype/targetDtype）、`shards`（basename映射device/inode/size/mtimeNS）。sourceDtype固定`float32`，targetDtype=`float32`或`bfloat16`，必须与冻结原精度规则一致：`.modulation`和名称段以norm开头保留FP32，其余BF16。参数名需精确`blocks.<id>.`前缀且与对应meta块完整集合/shape一致；真实每块27个，7 FP32/20 BF16；不能用`blocks.1`误匹配14。分片只接受普通文件basename、禁止路径逃逸/symlink，每次访问前后身份一致。重复/缺字段/非法类型、未批准dtype、shape/offset/非有限值/截断/身份改变明确报错；不从tensor内容推测缺失元数据。文件完整hash由外部guard保护，loader不每次哈希全部20GB然后声称冷盘性能。

租约逐tensor读取原FP32、验证有限/shape/dtype，转换并安装到指定块；完整校验/同步后才yield，异常不暴露半块。退出先同步再移除本实例安装的参数/引用，恢复meta并关闭映射；不修改输入文件。取消异常`BlockLoadCancelled`；checkpoint接收只读标量mapping，固定stage至少`before_load`、`after_read`、`before_install`、`after_install`、`ready`、`before_release`、`released`，含block/name（适用时）/completed。checkpoint异常或取消都清理；释放通知不得阻止必要清理。普通读取/取消且清理成功可再次租约；同步/清理/原件身份失败则poison实例，禁止下一租约。异常保留原原因，不能以清理异常覆盖全部上下文或将异常转成功。

合成CPU测试覆盖正常/跨片、每阶段取消、回调和块执行异常、二次进入、close、原件/manifest错误、精度规则、逐值权重及所有块恢复meta。夹具/缓存只放D_TEST_TEMP_DIR，不能修改真实模型权限或原权重。

Lead真实验收：81参数全部与独立原FP32读取转换逐值相同、名称/shape/dtype/MPS确认。固定小块输入使用确定性CPU生成后上传，`x=[1,128,3072]` FP32、context`[1,32,3072]` BF16、e`[1,128,6,3072]` FP32、grid`[1,8,16]`、全局RoPE CPU FP64桥；种子固定81429，仅本小fixture，不替换R6视频seed。独立常驻同块参考不调用loader，真实0/14/29串行全输出按旧`.02/.02`零超限/全有限，输入保护；这是加载等价，不是其在整网轨迹上的数值/视频质量。两路共用attention不得解除ATTN独立门。

一次预热0/14/29，随后五轮0→14→29加载/释放（至少一轮禁用循环GC）。每次清除本轮调用方别名并同步后，目标/其他块都meta，旧Parameter弱引用消失、活动GPU分配回到加载前基线；driver/cache/RSS另记不冒充总内存。真实取消至少首参数后、转换后安装前、block14跨片点、ready/块执行后，清理后再成功加载。未知残留不能提高阈值；外部guard前后保护、≤1800秒，单重任务。记录逻辑读字节/耗时及能取得的实际读取，无法归因的物理I/O/cache状态为unknown，不能从mmap虚拟量或本fixture推断冷盘全模型速度。

### 组合、交付与本人待办

两个包独立工作树从同一准备SHA派工，文件无重叠；Lead串行提交/审核/普通保留历史合并到R8集成树，最后对组合固定SHA执行相关检查。只有满足冻结门的诊断工具可接纳；失败包隔离，不因另一个通过宣称双包全部通过；无新用户可用I2V入口。源接纳前后核对当前HEAD/个人scheme完整差异和索引，不stash/reset/强推，不触碰普通D/作品。阶段后按既有授权提交/推送工作分支，最终SHA只写外部回执。若需接纳仅通过一包，保留失败分支和事实，不改任务编号。

持久证据`D-Development/AgentTrials/D-VIDEO-I2V-01/run-20260921T151422Z-attention-stream`，各Worker job/route、外部脚本/输入清单、结果/审核/回执关联；不复制大QKV/权重入Git。H24已按原固定source-real样本SHA256 `36e4db23963598f978fc5333f3c54a812c4de264318a06e189a9bb4bc5b230f0`播放，用户确认“听到了，人声和旋律清楚，播放正常”，本人听感事项关闭；不冒称App接线或全歌声网络GPU化。H22仍需工程定位，本阶段不重启旧壳层修复或要求本人重复中文测试。

### R8期间用户补充（2026-09-22）

用户将另行规划一套UI，当前输入框/候选窗等问题延期；H22保留历史失败并转UI重构待办，不是修复通过，不阻塞本次后端诊断。H24固定GPU歌声听感本人已确认正常。未获得自动启用未验收产品路径的授权。

<a id="r8-results"></a>
### R8结果：诊断工具通过，数值问题已缩小范围，I2V产品仍未通过

源起点`d2ab56bb7bab15c8745d6ea06a5039bb608f6dea`，准备`2b4d6624a0e4fc600df372a37f59c86b85df08f3`。ATTN实际受测`fae34f9acb92d67f25fd394a8121db4d71bc966f`，STREAM实际受测`59c267d182b0924fefd90b19dae60f1235220bfa`；组合CPU实际受测`fd74734e337ed246d42fffcfa055fb7df1c57a4e`，四份实现/测试与真实GPU受测版本逐字节相同，未声称GPU重跑于组合提交。这里只接纳四份`Backends/Video/Tests/wan22_*`诊断/测试文件和四份获准记录，生产后端/GUI/精度/依赖/签名不变；R7失败实现不随本次合入。

#### 注意力：失败来自实际计算路径，不是旧对照公式失效

固定实际首时间999/正条件/block0输入成功捕获，完整Q/K/V为`[1,27094,24,128]`，原始FP32与BF16位数据均回读验证；未执行attention或其他块来寻找更好样本。独立NumPy FP64稳定公式E通过4个解析检查，Torch CPU FP64 SDPA的F与E在39936元素上最大差`2.0961010704922955e-13`，严格`1e-10/1e-10`零超限。它们使用同一BF16量化输入，不把rawFP32输入当另一个基准。

| 固定矩阵 | 原注意力`.02/.02`结果 | 结论边界 |
| --- | --- | --- |
| A（MPS BF16 Q64）对C（旧显式FP32公式舍入BF16） | 精确复现158/39936超限，maxAbs 0.134765625；旧MPS FP32阈值运算另行保留 | 不是未复现或仅CPU小夹具 |
| A/B（Q64/Q31）各对E舍入BF16 | 均158超限，maxAbs 0.134765625 | 二者共同偏离独立参考 |
| A/B各对未舍入E | 均159超限，maxAbs约0.134772427 | 与舍入E口径分开 |
| C/D（显式FP32/FP32 SDPA再舍入BF16）对E两口径 | 均零超限 | D仅诊断，未替换产品策略 |
| A对B | 零超限，maxAbs 0.0001220703125 | 分区一致不能证明数值正确 |

C/D未舍入FP32对E最大差分别约`1.1894e-5 / 8.9255e-5`，本次统计仍使用`.02/.02`，不能说都通过`3e-5`的另一门槛。结论严格限定为：**本机Torch2.7.1、该固定真实输入及选定查询上，超差定位到MPS BF16 SDPA路径；原独立公式门有依据。** 尚不能断言具体底层kernel、累加器或所有Mac/BF16均有同一缺陷。唯一额外单变量控制未使用，现有对照足够完成本轮归因。无新50步/完整首步/视频，也没有默认启用I2V。

捕获脚本约6.625秒、E计算约0.437秒、真实矩阵约2.750秒；矩阵含导入/保护guard约14.126秒。矩阵结束active=0，driver=420200448字节，RSS累计峰值3722166272字节；不是全模型峰值。捕获84项、E92项、矩阵98项文件保护通过，退出0且自有进程组回收。

#### 流式：三块加载等价及寿命通过，不能外推全片速度

真实block0/14/29各27个参数（7 FP32/20 BF16），81个全部与独立原FP32读取转换逐值一致；每次租约中整模型恰好只有目标27参数驻留，其余包括公共参数均meta。三个独立常驻块与loader路径各393216输出元素误差均0，输入/参数保护通过；这是固定128-token小块输入的加载等价，两路共用attention，不能解除上一节独立门。

每块参数驻留327387136字节（约312.22MiB）。输出阶段每次卸载回到11206656字节输入基线，阶段结束active=0；不是每次卸载所有GPU内存均零。预热三块后，五轮0→14→29全部禁用循环GC，旧Parameter弱引用消失、全部meta、active逐次回0；首读后、安装前、跨片14、ready及读前五个取消边界、调用方异常恢复通过；另在真实GPU块计算同步后取消，再成功加载通过。

输出/重复阶段脚本约11.413/18.902秒，guard约22.753/30.028秒；最终driver分别3899392/1523712字节，RSS累计峰值约1.43/0.91GiB。driver/cache/RSS与活跃参数不同，不相加、不宣称长期所有内存零增长。每块654626816字节是逻辑原tensor读取；预先哈希、重复加载已预热缓存，物理SSD读取与冷缓存吞吐仍unknown，`verificationSeconds`包括独立权重核对等开销，不能外推全模型速度。两阶段各88项保护一致、退出0/自有进程已回收。

**适用性**：逐块GPU加载具备继续原型的条件，降低常驻权重已可验证；目前只覆盖三块、没有公共权重与全长激活/30块/正负首步/50步调度，不是产品流式引擎。16GiB仍不设为所有Mac能力上限；大内存常驻策略保留。

#### 修复、审核与来源

两个受限独立CLI Sol/high包从同一准备版本真实并行：ATTN初交15:25:38—15:32:13 UTC，STREAM初交15:25:38—15:34:32 UTC；实际模型/档位/目录/workspace-write/网络关闭及输出/tmp写根由turn_context核实，隐藏服务解析unknown。两包均初交+一次普通修复，无修复2、无Lead接管实现；R7/旧IMAGE/RUN预算不刷新。

ATTN初交错误地改变C的query形状/缩放运算，Lead独立持久反例先失败；另补BF16量化溢出检查和CPU后升FP64，原常值V新测试误设逐位相同导致假失败，由Lead明确改为对应机器精度容差（BF16仍exact），不改原真实`.02/.02`。修复后9个CPU方法+Lead原13行/除法检查通过。STREAM初交15个CPU方法通过，但Lead反例发现首次同步失败后仍可复用、两个loader可同模型同时驻留；修复1加入poison和模型级单owner，17个CPU方法+2个独立反例通过。异常/权限记录先核后派修；本轮没有观察到权限拒绝、成功越界或配置扩大。Worker没有行为测试/GPU/commit权，所有行为验证和显式提交由Lead完成。

Lead实现外部捕获/E/真实验证器；非实现者`i2v_memory_cause_review`和`i2v_streaming_contract`独立只读审核代码及证据，未另跑模型，不声称另一个模型独立实测。预发真实验证前补了单块驻留断言、原FP32阈值口径、dtype/来源检查与失败留证；属于验收器纠错，没有降低标准。组合26个CPU方法无失败/跳过，源接纳后以明确源路径再跑同一集合及两份Lead反例，结果及最终SHA见外部回执。

本轮每Worker预检/初交/修复1共三次CLI快照，减去上次累计后统计，末值与运行元数据相同：ATTN input881558（含cached806912）、output30809；STREAM input1323142（含cached1215360）、output34696。cached不能再加到input，reasoning已含output；完整Lead/Reviewer用量和订阅费用unknown。一次Lead临时用量汇总因变量名遮蔽builtin失败，未改输入/代码/权限，修正元数据脚本后取得核对结果；不是Worker失败或重算历史费用。本样本不能证明成本最优。

#### 证据与恢复

持久根`D-Development/AgentTrials/D-VIDEO-I2V-01/run-20260921T151422Z-attention-stream`；入口`acceptance.json`、`prelaunch-independent-review.json`、`postflight-independent-review.json`、`worker-usage-observed.json`与最终`final-receipt.json`。每阶段有guard/data终态及前后保护。矩阵冻结清单SHA256 `e7803610dd8ef6f447986ac34afe6e80483c5784e66593a560971f3aa1eac9b5`，流式冻结清单`a57f703722aa3152636d3d95710d1c700c2d4c7411c48921a7f32516dc225d91`；原大QKV、权重与日志只在外盘，不入Git。原失败证据、两个初交提交及两修复提交均保留。

当前组件阶段已验收，I2V产品仍未过；H24本人试听已关闭，H22按用户最新决定延期到专项UI重构，不是通过。普通D/作品未操作，scheme原SHA256 `ca3635d88aa5a15397b90e528667c66c0e6db7e596176e885c79d194b544206c`、index blob `9c76916bdc97c2d4298cefe64e0b0fae3380573e`及未暂存1→6差异保护。源仍允许这一个个人差异，不称完全干净。所有自有实测和Worker已结束；源最终接纳/推送与文档差异写回执，不为提交自引用反复提交。

**下一阶段提案（待用户批准）**：围绕一个明确GPU注意力修补候选，保持权重/输入输出精度和旧容差，明确内部运算契约后，先固定全query分区与独立抽样，再真实块；随后把已验三块加载推广为隔离的30块加公共权重调度，仅验证一个完整正负推理步的取消/资源与结果，不直接启动50步。任一关键门失败即停该路径，不恢复旧耗尽预算或搜索seed/chunk。后续50步/解码/运动质量/D适配仍独立门控；首发其他无依赖的有限能力组合和首用/部署/恢复保持位置。UI只保留需求和安全边界，待用户专项设计，不先行重构。

<a id="r9-spec"></a>
## 2026-09-22 R9：注意力修补与完整流式 forward（冻结 R9.1）

用户批准继续修复及流式实装，并核对全模态模型支持和首发差距。源基线`368751084ab94a58b4d97dc96ad5c7c0948d2419`；执行准备SHA写外部job/回执。证据根`D-Development/AgentTrials/D-VIDEO-I2V-01/run-20260921T161245Z-full-stream`。本轮终点为可执行后端部件＋完整30块正负首步；不直接运行50步，不默认启用App I2V，不合入旧失败的MLX适配/RESOURCE分支。原权重、1216×736/121帧、seed/latent/条件、容差及14GiB本机allocator预算不变；后者只限本次验证，不限产品硬件范围。

公共安全：两个独立受限CLI Sol/high（数值/生命周期风险，不按代码行数选低档），各初交＋最多两轮针对修复＋一次有界Lead收尾；旧R7/IMAGE/RUN耗尽预算不刷新。任务规格、assembly/真实验证器由Lead维护；Worker不改公共记录、其他文件、源、模型、旧证据或共同Git，不commit/派生/联网/安装/构建/GUI/GPU。仅显式解释器`D-Development/AgentTrials/D-VIDEO-V0-01/run-20260913T152419Z/venv/bin/python -B`用tokenize.open+内存compile作语法检查，不导入/exec目标、不py_compile；正常输出/缓存/临时均在job写根。未知权限事件暂停回Lead，预授权无字节码检查是唯一降级。Lead串行行为验证及显式提交，审核后组合；每次修改源前后核验个人scheme内容/索引/未暂存状态，不stash/reset/restore/amend/rebase/cherry-pick/清理。候选代码不等于产品通过。

### R9-ATTN：一个明确的 GPU 运算实现

允许新建且仅改`Backends/Video/Python/d_video_wan_attention.py`、`Backends/Video/Tests/test_wan_attention.py`。API `wan_attention(q,k,v,*,query_chunk_size=64,device="mps",checkpoint=None)`；`AttentionCancelled(RuntimeError)`供回调取消。q/k允许FP32或BF16，v必须BF16，布局[B,Q,H,D]/[B,K,H,D]，同设备，Q与K可不同；全部有限，FP32转BF16后也须有限。先把q/k按原路径量化BF16，再提升FP32；v按既有BF16值提升FP32。每query分区保留全部K/V，以FP32 SDPA数学路径完成累加/softmax，再返回原布局BF16新存储；不改变输入/权重精度、mask/scale/dropout/causal语义，不CPU回退。仅显式device=cpu用于小合成测试；不可隐式搬设备。query_chunk_size正整数且排除bool；dtype/shape/空维度/设备/非有限值/回调错误明确拒绝，真实未知错误不吞掉。无新增后端选择器或万能参数袋。

内部FP32是本次显式修补的运算契约，不把“FP32诊断通过”暗中当开关：PyTorch2.7 SDPA官方文档说明数学后端对half/BF16中间量使用float；R8实测却发现本机BF16路径偏离独立E/F，故显式固定输入量化及FP32数学运算。https://docs.pytorch.org/docs/2.7/generated/torch.nn.functional.scaled_dot_product_attention.html 。不能据此宣称已找到底层kernel bug或所有设备都异常。

inference及SDPA上下文局部设置并恢复；不改全局flags。checkpoint只含只读标量，至少`before_chunk`/`after_chunk`及start/end/total；异常正常退出/释放局部引用，不保存tensor事件、全query logits或输出分块列表。可预分配最终输出、逐块填入；取消不交付部分成功结果。CPU测试独立FP64公式、cross/self、尾块、BF16量化次序、错误/取消/恢复/输入与全局设置保护。Lead真实门：R8冻结QKV全部27094查询Q64/Q31结果均有限，旧`.02/.02`零超限；原13查询E/F独立参考同阈值，输入保护；取消后可再生成且无未解释GPU活跃残留。只比较Q64/Q31不能替代独立参考。

### R9-STREAM：完整权重会话与实际模型 forward

允许新建且仅改`Backends/Video/Python/d_video_wan_weights.py`、`Backends/Video/Tests/test_wan_weight_session.py`。API `StreamingWeights(meta_model,model_root,frozen_manifest,*,device="mps",checkpoint=None)`；`session()`上下文、`resident(block_index)`上下文、`forward(*args,**kwargs)`、`close()`、只读`statistics`。取消异常`WeightLoadCancelled`，poison异常`WeightSessionPoisonedError`。复用R8算法思想/必要局部源码，但生产文件不得import Tests、旧工作树或外部run；旧R8诊断文件及17测试保持原样作为历史回归，不为测试方便改断言。不要复制整份Wan模型、引入新依赖/全局框架。

manifest schemaVersion整数2，字段恰好`schemaVersion,blocks,shared,shards`；blocks每个0…N-1字符串→记录数组，shared为公共记录数组。每记录name/shard/shape/sourceDtype/targetDtype；原FP32、目标普通BF16，time_embedding/time_projection/head前缀及modulation/norm保留FP32；shards与R8同basename→device/inode/size/mtimeNS。参数须与全部meta模型精确覆盖，不遗漏/别名/重复/未知；shared不能含blocks，不能任意前缀扩大范围。MPS真实Wan固定30×27（每块7FP32/20BF16）+15公共=825，公共FP329/BF166；CPU合成模型可更小，但语义相同。源码/元数据预检不读取tensor。全部真实825参数随后由Lead逐值比独立FP32读取转换，原shape不做MLX展平。

一模型一个owner；session进入逐tensor载入15公共参数，resident仅允许活动session中一个块，其余块meta。原FP32逐tensor独立暂存并转换，禁止整模型CPU字典/预取/持久转换权重；每次安全打开/前后身份校验、数据有限/shape/dtype，完整load后才yield。租约退出同步后恢复本实例meta，保留公共；session退出清全部。普通取消/计算异常清理成功可下一session，身份/同步/清理失败poison不可复用，close释放owner但不得把未知真实参数假装清除。close活动session/lease/forward拒绝，关闭幂等。错误保留主因并附清理错误，取消不阻止必要清理。

forward仅活动session/无活动lease可用。局部包装实例当前block.forward（调用捕获的saved_forward，不递归block(...)），按0…N-1顺序每块租约真实执行；结束/异常逆序恢复原实例forward，避免残留闭包/替换别的wrapper；不得改全局模型类。强制inference，拒绝重入/并发session/forward，调用方持有输出不得隐式留住模型参数。捕获已有compact时间wrapper，Lead先装时间适配再由本组件临时包租约，逆序退出。顺序遗漏/重复拒绝，不把未执行块当通过。

checkpoint包含stage/group（shared或block）/block（适用）/name（适用）/completed等只读标量；固定load各阶段沿用R8`before_load,after_read,before_install,after_install,ready,before_release,released`，forward前后可扩展标量。共同参数失败、跨片块取消、body异常、head异常、关闭/重入/双owner、安装一半失败、同步poison/弱引用释放/输入文件保护需CPU覆盖。新反例不改变旧标准。

### R9真实装配、停止门及支持盘点

Lead依次：CPU/静态审阅→固定真实attention独立门→825权重逐值、0/14/29小块独立常驻对照和session重复/取消释放→一完整正/负30块forward+一次CFG/scheduler更新。真实相同输入、全有限、首latent逐值锁定，事件顺序0…29正再0…29负。完整步每种attention首遇独立抽样；若后层出现异常立即留证，禁止换seed/尺寸/步数/容差“通过”。完整步上限1800秒；达到限额记录耗时/资源终态，不换大机假设消除。已有精确原完整形状staged时间表绑定；首时间999原完整形状网络与表重核，不能单独启用已失败的两行time GEMM。CPU FP64时间/RoPE桥是显式参考适配，不称全网络CPU推理。

本轮可执行部件接收调用方构造的Torch模型；固定官方model/许可部署、50步/解码/画质和D原MLX路径的接线仍独立未通过，不把验证harness绝对路径装进产品。一个首步成功只解除该门。14GiB不表示总进程内存或产品上限，GPU active/driver/RSS/系统swap分别记录；逻辑tensor读取≠物理SSD吞吐，哈希预热不宣称冷盘。guard保护所有固定输入、GPU串行、自有进程限时回收，普通D/作品不动。

同时Lead依据现有证据更新一份有限模型支持/发布缺口摘要及CURRENT_ACTIONS/目标索引，区分App、CLI、外机、候选、许可未知；不将历史测试当本轮重验。用户另行UI重构，H22延期仍非通过；UI完成后还需统一部署/模型获取及许可/干净Mac首用/升级恢复，不自动发布。非实现者复核Lead装配和证据，最终只接纳满足其冻结范围的部件，阶段完成按既有授权推送工作分支。

<a id="r9-results"></a>
### R9结果：实际流式部件与GPU注意力，产品I2V仍按独立门控

源起点 `368751084ab94a58b4d97dc96ad5c7c0948d2419`；准备 `2f982eb4682e4b5d5a5338f7b48fade07282502f`。注意力受测 `c0165a2b950d2aab8cad53f2f8bc38bf57e547ec`；流式生产修补 `54abf5f26fa437477bd4b4d3e772f50ea9df52c5`，Lead仅测试观察器收尾 `70ce096cd8ff14e2b78556dc81f51d652e6e0036`。组合CPU/真实825权重/首步使用 `8fb7d48e14ba4e140177925905ddb8130751617d`；四份实现/测试来源保留，末次文档版本和源回归/推送写外部最终回执，不以标题推断已测。

**实装范围**：新增两个不依赖Tests或外部run的Python后端部件：GPU attention明确保留原BF16量化输入/输出、内部FP32数学计算；StreamingWeights面向调用方构造的meta模型，公共权重会话＋逐块租约＋实际forward临时包装，退出逆序恢复。全部30块/15公共权重逐tensor从原FP32分片读取，保持原BF16/FP32目标规则，不预取全模型CPU字典、不生成另一套转换权重、不降精度。来源图谱、项目/作品、Swift契约、GUI和原模型文件未改。当前真实装配为固定官方Torch定义和明确CPU FP64时间/RoPE桥；并非原D MLX适配或完整App流式入口，不能默认启用I2V。

#### 数值与权重寿命

- 固定实际27094查询/24头/128维共83232768输出：Q64/Q31分区逐值相同；13查询独立CPU FP64参考39936值旧`.02/.02`零超限，未舍入maxAbs0.015537481、舍入BF16后0.00390625。取消后重试一致，输入保护；脚本25.296秒，guard35.928秒，最终GPU active0/driver499859456B、RSS峰值4275961856B。只对独立抽样宣称参考通过，不能把分区一致当全元素独立数值证明。
- 固定原完整形状首block0和head，dense时间条件对已验证staged原形状时间：83232768＋5202048元素maxAbs0；首999全形状时间值与固定表逐值一致，输入/参数不变。两路共用新attention，结论只为时间适配/block/head等价，不替代上一独立门。脚本32.743秒，guard43.446秒，active0，RSS峰值2869592064B。
- 真实825参数的名字/shape/dtype/MPS和原FP32独立转换逐值核对全部通过；代表块0/14/29每个393216元素与独立常驻参考maxAbs0。其余块meta、公共权重随session生灭。三次全部30块循环均禁循环GC、旧Parameter弱引用消失、每块释放回公共基线/session回0；公共读后、块读后、安装前、ready、真实跨片14取消及实际GPU块后取消/恢复通过。
- 权重阶段实测活跃上界682982144B（约651.34MiB，含分配粒度），逻辑公共315108096B＋一块327387136B（约612.73MiB）不是总推理峰值。三个循环driver1350270976→2424012800→2424012800B，active均0，最终empty_cache后driver322666496B；活跃权重与driver保留分开，不声称驱动内存全零或长期所有内存无增长。RSS峰值1758576640B。脚本216.935秒、guard227.864秒；统计逻辑读91378525696B/3779tensor，读秒174.799含校验/复制等开销，事前hash及重复加载预热缓存，物理SSD吞吐和冷盘性能unknown。

#### 完整首步：原1216×736／121帧通过，尚未产出完整视频

真实装配重新核对首时间999的原完整形状时间网络与staged表精确一致。先真实GPU block0后取消，严格核验受控触发标记与唯一cancel事件[0]，清理回输入基线；再同一loader新session完整执行正0…29、负0…29并完成一次CFG5/UniPC更新。正负context原形状34×4096/18×4096，取消和各forward之后与CPU快照逐值一致；sample在调度前未改，调度后第一latent与原参考逐值相等。正负结果及新latent均FP32、shape48×31×46×76、全有限。权重statistics为3 sessions/61 leases/2 forwards，与取消1块＋实际60块一致。

四类首遇独立CPU FP64抽样各39936元素：self正/负maxAbs0.01553748100086505，cross正0.0004829916635241682、负0.0004291556800492258，原`.02/.02`均零超限；不是每层全元素CPU对照。完整实际一步837.473秒，含时间准备/取消等脚本856.432秒、guard868.141秒；未触发1800秒限额。各块释放后的active最高1047037184B，采样driver最高7645921280B，RSS累计峰值3346923520B；这些不是同一含义，不相加，也不将块边界active冒称瞬时峰值。最终active0/driver461078528B。系统swap首末采样2358.25→2393.69MiB属整机观察，不能全部归因本任务。

正/负/更新latent已持久保存并校验SHA256；first-step为`1c0714ee69b5e34af63d6d71feb5f91d453ab0d55d16c116d2878e0009e03f17`。真实stream和step各107项输入前后保护一致，正常退出0，自有进程组已回收。结论为：本机16GiB能够完成这一固定完整正负步；此前至少有可修复实现开销和数值路径问题，并非单靠内存容量就能解释。**不证明50步、解码、视频画质、所有Mac或D原MLX适配已通过。** 流式降低常驻权重，但单步约14分钟已提示速度代价；逻辑读取/缓存预热与完整片段耗时另验，不能据本步承诺冷盘性能。大内存常驻策略没有被删除，未设置16GiB产品上限。

#### 来源、失败与审核

ATTN、STREAM为两个独立受限CLI `gpt-5.6-sol/high`，同准备基线、独立工作树/输出/cache，网络关闭、common Git不授写；参数与turn_context相符，隐藏服务解析unknown。ATTN初交＋修复1后通过；STREAM初交900秒无代码超时，修复1在代码/测试和语法完成后900秒超时，初交及修复预算均计入，无新任务重置。Lead保留候选，15方法先通过；独立反例暴露poison跳过公共清理、BF16转换溢出、异常traceback自有张量残留。最终修复2耗619.319秒，生产三问题修正；没有额外Worker轮次。

STREAM新22方法出现4个弱引用断言失败；不是据此直接降低验收。固定CPython3.12最小实验确认测试回调读取f_locals会缓存旧强引用，独立外部反例此时已通过。唯一有界Lead收尾只增加24行测试观察代码：再次读取本组件相关frame，同步观察缓存并先验证源/转换/安装/结果locals为None，保留异常、禁GC、弱引用及输入保护，不清帧、不改locals、不丢异常、不调用GC。22方法随后通过；生产SHA256始终`fe9eeb88c3ce657637bfa19ad7727eb7bf70573e666080e101cdffcdab2c3814`。归因为Sol实现/修补＋Astra Lead测试收尾与真实验证，不能称Sol预算内独立全部通过。原失败证据保留，后续失败不得重新编号刷新本组件预算。

非实现者`i2v_streaming_contract`只读审核生产修补、测试收尾、权重证据；`i2v_memory_cause_review`只读审核完整块/首步验收器。Lead外部harness的取消来源标记、条件前后保护、cleanup错误终态等启动前补齐，不改冻结容差。两者没有另跑模型，不能描述为独立模型再次实测。组合58个CPU方法零失败/跳过（新10＋22、旧9＋17），独立attention/stream反例有先失败后通过记录；源入口结果见最终回执。

R9用量只取本轮两条CLI累计快照差值：ATTN末值input1240764（含cached1092480）/output24476；STREAM末值input1751539（含cached1649792）/output40695。中断轮次仅最后可观察快照，未上报尾部/精确分轮归属unknown；不将各累计数重复相加，reasoning含于output。完整Lead/Reviewer用量及订阅费用unknown，不能证明低成本最优。仅本轮统计，未重算旧样本。

#### 证据与边界

证据根`D-Development/AgentTrials/D-VIDEO-I2V-01/run-20260921T161245Z-full-stream`：job/route/event-review、CPU/独立反例、attention-real/full-block/stream-real/step-real的guard及data终态、前后输入保护、审核和最终回执。大权重/QKV/日志/输出仅外盘，不入Git。新[模型支持与首发清单](../MODEL_SUPPORT_AND_RELEASE.zh-CN.md)区分App/CLI/外机/候选/许可unknown；历史实际结果不冒充本轮重测。UI专项重构H22延期非通过，H24已关闭；没有新增本人操作。用户scheme原字节/索引/未暂存状态、普通D/作品/模型保持。

**下一阶段提案（待用户审核）**：对照首发D-VID01及薄后端目标，下一主线是固定同条件完整50步参考/解码/画质的有限验收，再确定D适配和发布可用执行路径；不先扩更多视频模型或时间线，不恢复旧耗尽修补预算。单步已测约14分钟，先据此给整段运行明确时间/进度/取消与资源预算，不能用换seed/缩尺寸/改精度或容差提前通过。可并行准备已有AP1与GPU歌声资源的组合整合契约，复用已通过的人机记录；实现与最终统一App验收另列。随后一条真实图文组合、用户新UI，以及模型获取/许可、干净Mac安装和升级恢复共同构成首发出口。用户UI设计可并行，H22留最终UI验收；本轮不进入该提案、不默认启用任何未验路径、不发布。
