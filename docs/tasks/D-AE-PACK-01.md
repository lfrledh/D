# D-AE-PACK-01：既有音频引擎离线封装

APP1/PACK1.2；batch D-AUDIO-APP-01。用户批准文件输入音频闭环；Lead 的只读部署审查确定先准备自包含引擎，普通GUI仍待资源窗口。只负责构建时把明确输入的现有文件封装为可测候选，不是安装器、下载器或签名工具，不改变现有引擎/精度。普通沙盒可执行/动态授权/模型仍另行验收，不因本包CPU通过默认启用。

## 所有权与运行
请求 Terra/medium。仅改 `Backends/Audio/Packaging/prepare_engine.py` 和 `Backends/Audio/Tests/test_engine_packaging.py`，两路径当前不存在，允许新增；不要改其他文件、任务规格、Git元数据、签名、工程配置、依赖锁或现有Python/provider。独立worktree D-AE-PACK-01，分支codex/d-ae-pack-01。源基线7510015bafc0a8b33c463dba11b1a7d54a93b073；执行基线由Lead准备提交后以完整SHA写request。输出/cache/tmp路径在request中明确；网络关闭，无递归、模型/GPU/GUI/全App或包构建。使用系统Python3运行夹具CPU；tokenize.open+compile(...,dont_inherit=True)做无字节码语法检查，不导入被检目标。行为测试缓存固定任务tmp，PYTHONDONTWRITEBYTECODE=1。

## 冻结CLI与布局
标准库Python实现，命令参数必须显式：`--python-root`（含常规文件bin/python3.12与lib/python3.12的已安装基础Python目录）、`--site-packages`（已授权venv的lib/python3.12/site-packages）、`--provider-directory`（项目Backends/Audio/Python）、`--vendor-directory`（固定Vendor/stable-audio3-mlx）、`--model-manifests`（Backends/Audio/Models）、`--output`（不存在的最终目录）。不自动搜索/下载/调用输入可执行文件，不访问keychain。支持本次CPython3.12 arm64准备；其他版本明确拒绝不偷偷猜。

输出固定相对布局：`python/bin/python3`、`python/lib/python3.12/`（基础stdlib，不含其site-packages）、`python/lib/python3.12/site-packages/`（从给定venv复制mlx、mlx_metal、numpy、sentencepiece及其对应dist-info、必要同名.libs/数据目录；pip不打包）、`provider/`、`vendor/`、`model-manifests/`、`engine.json`。不复制pyvenv.cfg，不保留原Codex基础路径；输出解释器自行找到布局内stdlib。源码/许可证/模型manifest保留；不复制模型权重。不得擅自重命名native扩展或修改二进制rpath/签名；Mach-O闭包与实际导入由Lead后续核验，manifest不能声称已通过。

engine.json: schemaVersion=1, kind="d-audio-engine", pythonABI="3.12", pythonExecutable="python/bin/python3", providerScript="provider/d_audio_backend.py", vendorDirectory="vendor", modelManifestsDirectory="model-manifests", files为按path排序数组，每项path（规范相对POSIX）、sizeBytes（整数）、sha256、executable（bool）。枚举所有已打包常规文件，不包含engine.json自身；不生成最终目录自身摘要自引用；不写绝对输入路径、账号、设备标识或凭据。生成确定性JSON（允许统一缩进，不带当前时间），Unicode保存，输出文件哈希与模式反映实际副本。架构/依赖是否可加载不从名字推断，在终端摘要标为unverified。

## 文件安全/错误
仅显式输入树；验证各根绝对本地目录和所需入口后再准备输出。输入与output/暂存不得同根或祖先后代重叠，禁止输出已存在（含dangling symlink）；输入任意symlink、特殊文件（非目录/普通文件）拒绝，不跟随、不消除保护；原始输入始终只读。路径使用Path参数，不shell拼接或执行输入代码。跳过__pycache__、.pyc/.pyo、.DS_Store、.git，不改输入；stdlib自身site-packages排除。未知site-packages顶层组件保守拒绝并说明，不悄悄包含不明插件；允许venv pip/distutils支撑内容明确忽略（pip、pip-*.dist-info、_distutils_hack、distutils-precedence.pth、setuptools*），不要用包含所有.pth的规则。

同output父目录的唯一任务临时目录完成复制、摘要与完整性检查后发布；使用不会覆盖竞争产生output的发布方法（macOS本机可用原子exclusive rename，平台不支持则明确失败，不降级覆盖）。失败只清理本调用确定拥有的临时目录，不删除竞争者/输入/未知文件。拒绝覆盖和输出保护不可因测试方便改变；成功exit0，路径/格式/复制/发布/报告I/O失败exit2，stderr说明，其他应用验收不在exit0含义中。无os._exit或吞掉所有异常伪成功；stdout正常摘要与错误流失败也保持明确退出语义。

## 必须夹具
临时独立微型文件树，不运行夹具python。正常布局/manifest/摘要/Unicode空格，重复输入确定性；缺关键组件、错误Python布局、未知site组件、symlink/特殊文件、输入输出重叠、已存在/悬空输出拒绝；复制失败、发布竞争不覆盖；原件摘要前后相同。真实CLI完整进程返回码，stdout/错误流不可写边界沿现有输出失败契约返回2。受控预期拒绝不是权限事故。仅夹具CPU不代替真实环境封装/导入/签名。

初交+最多两轮针对性修复；遇未允许权限/身份/契约不清立即停报Lead；不主动越界测试或放宽写根。首次仅预检，返回task/spec/run/真实cwd/root/common Git/HEAD/branch/允许路径/验收与边界，等待IMPLEMENT。Worker不commit，不改此任务单；回传改动、命令/结果、保护、异常、自有进程及未覆盖项。

PACK1.1派工前澄清：本机基础Python的bin/python3是符号链接，bin/python3.12为同目录常规文件；仅从明确的bin/python3.12复制到输出python/bin/python3，不追随前者，不放宽拒绝symlink规则。基础lib/python3.12/LICENSE.txt存在，随stdlib保留；各依赖dist-info许可证原样保留，不声称完成全发行许可审计。此修订发生在初次IMPLEMENT之前，不属于返工或预算重置。

## PACK1.2 初次审核与范围内澄清
+Terra初稿5项自测及Lead原套件重跑通过，但Lead独立真实CLI发现stdout/错误流不可写退出120（契约2）、符号链接父目录被接受。原测试不同拒绝案例复用污染夹具，复制失败分支允许成功，缺输出流用例；这些是验收缺口，不降低原标准。测试缓存不能硬编码本run路径，应从显式D_TEST_TEMP_DIR读取并要求它存在，避免未来写入旧证据。

+Lead澄清两个实测输入布局（不按新需求追罚旧实现）：只遍历实际选择的基础bin/python3.12和stdlib，排除的bin/python3符号链接、基础site-packages/缓存不进入复制/检查；已选择输入及所有祖先仍必须无symlink/特殊文件。venv内mlx-metal是distribution，只有mlx_metal-0.32.2.dist-info，二进制载荷在mlx目录，不需要虚构mlx_metal包目录。必需package目录为mlx/numpy/sentencepiece，同时要求四个distribution metadata；若存在合法mlx_metal目录可以保留。所有模块的真实可加载性仍由后续Lead检查，不从目录名推断。

+全路径祖先不跟随symlink；独立缺失/特殊文件/输出竞争夹具必须分别构建干净输入，并确保超时/异常时回收自有进程。需保留三个provider入口d_audio_backend.py/d_audio_contract.py/d_audio_sa3.py；基础stdlib至少验证encodings/__init__.py与LICENSE.txt，版本真实性仍待实际解释器检查。确定性注入复制失败可作为单元检查，输出/退出和发布竞争必须调用真实CLI并等待退出；不得以允许0吞掉失败或放宽阈值。

+第一轮针对性修复发出后普通修复剩余1轮。证据pack/lead-initial/result.json；环境/范围事件由Lead先核对后派修复。

## PACK1.2 CPU候选接纳（并非普通App引擎验收）
受测代码提交 c64c785c0ddcd221e0f46caae6e9354b324079c2。Terra初交+两轮修复，Lead非实现者代码审查和独立CPU复验，无Lead代写封装实现。原14项CPU测试通过；Lead8个直接CLI场景按各自期望通过（与原套件重叠，不相加）；初稿输出120与路径/夹具缺口及PACK1.2澄清保留。只接纳至批次集成树；真实环境封装、迁移解释器、Mach-O/签名、沙盒、GUI/模型尚未验收。后续同规则缺陷不能重置已用普通修复预算；若需要有界Lead接管，单独记实现/非实现者复核。证据pack/lead-repair-2/result.json。
