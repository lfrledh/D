# D-SINGING-DEVICE-01 — E02 GPU 声码器 / CPU 兼容

状态：准备；未接纳。规格 S1，契约 SD1，批次 D-SINGING-DEVICE-01。
源基线：08a3f6263d8848136af8e52d9f27a255d99edff7。执行基线为本准备提交，完整 SHA 记外部 job / 回执，禁止自引用反复 amend。
运行：run-20260916T143605Z；证据：/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-SINGING-DEVICE-01/run-20260916T143605Z。

## 范围与产品出口

本轮用户批准对照总体目标完成离机阶段。落实 EXECUTION_DEVICE_POLICY 的 E02：BigVGAN FP32 GPU MPS 路径，保留显式 CPU 兼容。提供已验收的后端 / 现有 CLI 选择，不改工作台或默认启用新 UI。Qixuan 原 ONNX 仍 CPU，不宣称全歌声网络 GPU，不转换声库，不新增依赖，不做性能优化。AP1/IME/H22 和 I2V 质量候选独立保留，不能通过本任务刷新旧预算或声称其完成；真人听音列待办。推荐 GPU 但短输入可能受启动成本影响。

## 冻结 SD1

复用 SingingRequest.profileID + CLI 现有 --singing-profile 路径；RequestWire schema=1 / 键集不变。CPU ID qixuan-2.7.0-bigvgan-44k-approx-v1 与原清单 SHA 15489802b768fdd5c447325d5483b293601e63db54f46e84eb1c7b84df010a39 不变。新 GPU ID qixuan-2.7.0-bigvgan-44k-approx-mps-fp32-v1，清单 qixuan-bigvgan-mps-fp32-profile-v1.json，SHA 1d7b3fcc0988e4f76c4fe0b8fd7adf62fe943d947482c0878b51e38dfe725705。材料、全部算法参数、近似 mel 投影、FP32 精度均同旧版，仅 profileID 不同。固定两个映射，未知 ID、清单错配/摘要不符拒绝；清单不作为任意设备执行指令。vendor SHA e3f9f9eb2a3cad99b5f75501cbc8b5fd6504257d0c26a69c2f1c817d2c7d0000 不改。

CPU 继续原严格 result v1 / 原 precision 文本，不伪造新增设备观察。MPS 严格 result v2：顶层仍原8键；profileID 新值；model 原键加 profileSHA256、vendorManifestSHA256；execution 原键加 devices；precision 为 `Qixuan original ONNX CPU; BigVGAN FP32 MPS`。stages/seedControl=unsupported/输出样本数/裁剪/饱和计数规则不变。

execution.devices 严格两键 onnx、vocoder：
- onnx 精确键 requested、actual、provider、runtime、version、precision、fallback；值分别 cpu、cpu、CPUExecutionProvider、onnxruntime、运行时真实非空版本、FP32-original、forbidden。
- vocoder 精确键 requested、actual、runtime、version、precision、fallback、parameterDevice、bufferDevice、inputDevice、outputDevice；值 mps、mps、torch、真实非空版本、FP32、forbidden、mps、mps、mps、mps。device.type 规范化，检查每一参数/buffer dtype FP32；输出是在搬回 CPU 前观察。ONNX 来自所有实际 session.get_providers() 检查，不只拼常量。非空版本须有长度上界128，不捏造具体版本。v2 不足 / 不符拒绝，绝不能 MPS 请求接纳 CPU v1；结果、请求、inventory profile 三方相等。

Python QixuanEngine 新增 keyword-only vocoder_device='cpu'，旧三参数兼容。VocoderOutput 新增可选 devices=None，原三参数兼容；MPS 必须提供实际完整观察。默认 CPU fixture/CPU结果不强加新字段。ONNX 会话仍原设置。CPU 安全加载/strict state dict/FP32 验证不变，随后模型及输入移到 MPS，输出检查后搬回 CPU。显式禁 fallback，Swift 子进程 PYTORCH_ENABLE_MPS_FALLBACK=0，独立 renderer 导入 torch 前也须确定禁回退；污染/已预载无法证明时拒绝，不悄悄 CPU 重跑。不禁止合法 CPU 文件/投影处理。MPS 不可用、OOM、算子/设备/dtype 不符明确失败，无成功发布；同步释放后才交还资源。stderr 警告不是签名/权限成功凭据。

Swift 可添加 profile 描述查找，保留 Configuration.profileID/profileSHA256 旧别名；既有 initializer/request/CLI 不强制破坏变更。配置不再另加可能冲突的 device 参数。SingingResultRecord 保留实际 profileID，metadata 使用经过严格校验的结果；MPS metadata 加 onnxDevice=cpu、vocoderDevice=mps、deviceFallback=forbidden 及运行版本，CPU 旧结果不冒充已观察。

## 行为与验收

|输入/动作|结果|
|---|---|
|旧 CPU 请求与旧清单，在 MPS Mac|仍 CPU，v1，现有调用兼容|
|新 MPS 请求与新清单|ONNX CPU / BigVGAN FP32 MPS，v2，原裁剪/来源/保存保护|
|错清单/未知 profile / MPS 配 CPU result|明确拒绝，不发布成功|
|fallback 污染或实际设备不符|失败，不静默改设备/精度|
|取消/超时/失败/消费者错误|现有 drain / 完整性 / 未发布清理规则；下一请求能运行|
|输出目录存在/输入被改|按原安全规则失败，不覆盖原件或已发布作品|

预先固定实测数值 gate：同一 mapped mel、原权重 FP32，CPU/MPS 形状一致、全有限、峰值<=1，逐样本 atol=1e-4、rtol=1e-4 无超限。已在准备前两输入通过；约6秒条件 CPU21.61s / MPS6.10s，仅可行性不是广泛性能承诺。MPS active释放=0、driver缓存84754432，不能把driver缓存认作泄漏或清理全为0。

完成要求：原 Python singing 四套及新增反例；Swift singing / 相关 provider CPU 套件；独立 Lead 真实 CPU与MPS正式CLI生成、取消/恢复、重复释放、MPS错误与禁止回退、数值对照、输入/已交付保护；独立非实现者代码审核；组合SHA后复验源入口。所有fixture/真实模型/编译/真人未执行分开。真实声音文件算法数值可自动验证，试听与普通签名App不冒称通过；不改 App，因此保留原行为。新 UI 推荐入口待AP1收口/真人验收后单独接线。

## 所有权与执行

Lead 维护本任务、清单和全局文档、真实测试/组合/提交。Worker 不改规格、依赖、签名、UI、工程、其他任务/模型/用户数据、共享Git元数据；禁止递归。普通新任务每包初交+最多两轮针对性修复；必要一次有界Lead接管须非实现者审核。异常先审再修复。

PY Worker：仅 Backends/Audio/Python/d_singing_qixuan.py、d_singing_render.py、tests/test_singing_qixuan.py、tests/test_singing_render.py。Sol/high，数值设备与生命周期风险。CPU tests 可用现有固定 Python，禁止模型加载/GPU。
SW Worker：仅 Backends/MLX/Sources/DMLXBackend/{SingingBackendConfiguration,SingingModelInventory,SingingProviderProtocol,SingingBackend}.swift，Backends/MLX/Tests/DMLXBackendTests/{SingingBackendTests,SingingWireTests}.swift。Sol/high，严格协议和资源安全；本包语法检查，编译/运行由Lead串行。

每包独立外盘工作树从同一准备SHA；独立受限CLI workspace-write，network=false，写根仅工作树/本包output/tmp，commonGit只读；实际路由/目录/设置核验后再IMPLEMENT。输出/cache/temp唯一在本运行包子目录，PYTHONDONTWRITEBYTECODE=1；语法 tokenization.open + compile(...,dont_inherit=True) 不执行目标。Swift parse 显式module-cache-path本包tmp。未授权拒绝/未知副作用立即停报；只可使用预声明无字节码入口，不临时寻找新写根。不读取凭据或启动GUI/网络/安装/钥匙串。

## 恢复与来源

源个人scheme SHA ca3635d88aa5a15397b90e528667c66c0e6db7e596176e885c79d194b544206c，未暂存，索引blob9c76916bdc97c2d4298cefe64e0b0fae3380573e；保护副本/完整差异见start.json。不还原、不暂存。源普通D和用户作品只读。候选/分支/证据保留；通过后按既有规则固定SHA快进源工作分支，允许正常本地提交和已授权工作分支push，不推进main。最终SHA写回执，测试版本与后续仅文档差异分开。

待填：Worker route/实际版本、修复与审核、真实检查、集成和最终回执。隐藏服务端解析 unknown，订阅费用和完整Lead归因 unknown；不得重算旧样本。音频GPU设备切片完成不代表AP1/视频或首次发布完成。

### IMPLEMENT 前澄清与预检

非实现者指出SD1的兼容歧义，Lead在派工前明确：MPS fallback/预载Torch准入仅约束新MPS profile；CPU profile不因无关MPS环境拒绝，仍显式CPU。缺失环境可在首次Torch导入前设0；已污染1或预载且无法证明禁回退则MPS拒绝。Swift为自有MPS子进程设0。本澄清不追罚旧实现、不改精度/数值/材料，外部S1-clarification.md随两份IMPLEMENT一起送达。

两工作树共同执行基线2a14ad2621b63a3c230d74de9ec2f78588f44fd9：PY在D-SINGING-DEVICE-01-PY / codex/d-singing-device-01-py；SW在对应-SW / -sw。请求和实际turn_context均gpt-5.6-sol/high，workspace-write，网络false，cwd与各包output/tmp为写根，公共Git未授权写。PY thread01a0aab1-69c0-73e2-bd6f-6a51046e061d；SW thread01a0aab1-6e35-79e3-923a-fa9b701fd8fc。服务端隐藏解析unknown。预检均退出0、工作树干净，Lead核验后分别IMPLEMENT；PY的一次rg未在PATH退出127为工具定位问题，随后绝对路径读文件，无权限扩大；清单diff退出1为预期有区别，不算模型测试失败。持久路由证据在各包route-accepted.json / implement-observed.json。

Lead外部真实验收脚本在首次运行前由非实现者审查：补自有进程组完全退出、CLI实际artifact与WAV/metadata绑定、证据写根/无软链/无..限制。数值断言不变，原旧脚本不改。改善验收不记成Worker实现修复。
