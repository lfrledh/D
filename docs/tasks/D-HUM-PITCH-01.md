# D-HUM-PITCH-01：原声到可检查音高候选

状态：契约准备，未接纳；2026-09-15（JST）。spec HUM1 / contract HUM1。
源基线 07f27b2687d51a1dcccf10d3e81bf956704c7fd9，源分支 codex/inference-foundation；集成树 D-Worktrees/D-HUM-PITCH-01 / codex/d-hum-pitch-01。准备 SHA 记外部派工记录，不自引用。
R=`D-Development/AgentTrials/D-HUM-PITCH-01/run-20260914T152228Z`。

## 本轮授权与出口
用户已有麦克风，要求先完成 H09 再推进下一阶段。H09 本人录制约10.899秒，试听正常、原件导出及同机冷重开已过（旧代码 aba1326f72f33ada028e35a8e799ef04965e7afa）；证据 `D-Development/AgentTrials/D-AUDIO-APP-01/run-20260914T151107Z-h09-microphone/h09-acceptance.json`。此次无新系统提示，不能称新TCC授权证明。完整引擎版录音旧门仍关闭，Lead在本批解耦且另验。
用户另批 SwiftF00.1.2及10个固定CPU wheels，共47506438字节，外盘独立Python3.12。实际ONNX399114字节/摘要见DInference契约及R/model-materials.json；源码/package MIT，独立权重许可unknown，仅内部评估，不授权分发权重。无云/上传/新下载/全局环境/签名配置更改。

有限出口：已存短单声部WAV/CAF→选择原帧区间→异步识别→查看连续音高/近似音符候选→明确保存/拒绝→重开/JSON导出。16ms…120秒为当前原声profile解析边界；首实测2…约11秒，不是所有Mac或未来模型上限。不给原声静默降噪/调速/量化，不实现谱面编辑/节拍定稿/演唱/MRT2条件直连/实时识别。原声回放不冒称音符试听。

## HUM1冻结行为
- DInference/PitchAnalysis.swift为值契约。prepared input独立原始Float32LE单声道16kHz，精确大小/摘要；源asset/document/revision/摘要/采样率/总帧/半开范围独立保留。工作台准备源，后端只读prepared input/固定model。原文件永不改写。
- Native AVAudioConverter primeMethod.none，mono16k预处理单列版本；不得触发librosa/其他下载。每次任务独立目录/进程；源与派生/输出不可重叠。原声可正常保存而无法识别时仍保留。
- SwiftF0阈值严格 >0.9；46.875…2093.75Hz。输出frameCount=floor(sampleCount/256)，中心=(256*i+127.5)/16000。非发声Hz=null，score不是校准概率。格式/形状/NaN/无限/重复键/布尔冒数值/版本/来源不符为失败；静音为正常无发声音高，不能把错误伪造为静音。
- 后端采用现有LocalProviderProcess，原DRuntime排队/取消/drain/release，不能以取消按钮状态当进程结束。不改现有SA3/MRT2/图文视频精度。输出单个版本JSONartifact ≤2MiB，严格来源/run/profile/digest一致，数值验证后发布；release不删发布文件；失败临时只由拥有者追踪清理。
- Notes是DWorkbench按独立算法从轨迹得到的近似解释：等律最近半音、连续同音至少5帧/80ms，遇无声或音高变化即断；起止为对应分析块边界且裁至选区，不用中心充当起点，不创造力度/节拍。原声作者来源保留，不称纯AI音乐。
- 提交捕获context/document/asset/选区输入版本；生成不改原声。切换/改区间/关闭时取消或使候选过期，过期不可接受；保存失败保持候选可重试，拒绝只弃候选。已保存解释独立ID/run/hash/源，旧解释不覆盖；项目schema兼容迁移与原字节备份由Lead统一。
- 导出JSON只包含本次分析/原声ID摘要和相对时间，不含绝对路径/书签/账号/内部Agent记录。仅显式目标，原子拒绝覆盖；原始录音与已有文件不改。外部JSON只解析不执行，未知版本明确拒绝。

## 分工与边界
Lead：共享DInference、schema/ProjectStore/ProjectSession、原声预处理、应用注入/录音门、任务UI装配及验证/接纳。Worker BACKEND Sol/high：仅新PitchAnalysisBackend.swift、PitchAnalysisProviderProtocol.swift、Backends/Audio/Python/d_pitch_analysis_backend.py及对应新增测试。Worker INTERPRET Terra/medium：仅新DWorkbench/Audio/PitchInterpretation.swift、UI/Views/PitchAnalysisView.swift及对应新增测试；准确公共接口在追加规格/准备代码内冻结后启动。两项不改共享文件，Worker不得改任务/验收/依赖/工程/用户scheme/旧证据/源Git。先预检后IMPLEMENT，独立受限CLI/网络关/工作树+自有output/tmp写根；Git只读，Lead停写后提交。初交+最多两修复，必要一次有界Lead接管；重要Lead改动非实现者审阅。

## 最小验收（不能由实现者放宽）
核心编码/验证正常及NaN/布尔/未知版/损坏/来源不符；实际CLI等待完整退出；短音/静音/正弦音高/重复同音/滑音/八度/背景噪声分项，不以单个准确率概括。模型加载缺失损坏、input size/digest/非有限、超时/取消/后续任务和重复调用；原件摘要保持。持久化：save/reopen/拒绝覆盖/保存失败/过期候选/旧schema原字节备份/历史图文音视频记录保持。完整CPU、局部后端、独立普通构建及实际沙盒GUI分别记；真实human录音需私有本地评估，不进Git。完整普通开发版仍使用既有签名，不以禁签构建冒称GUI通过。

## 恢复点
源未修改，scheme当前SHA256 ca3635d88aa5a15397b90e528667c66c0e6db7e596176e885c79d194b544206c、原index blob9c76916bdc97c2d4298cefe64e0b0fae3380573e未暂存。H09全部本轮GUI正常退出。安装进程结束，pipcheck通过；2秒静音0voiced/440Hz正弦median437.57Hz、125帧、CPUprovider单测通过，未证明人类哼唱质量。下一步冻结Worker接口及执行基线，开始受限实施。所有大证据在R，最终SHA及费用未知项待结案，不改历史。

## BACKEND1 / INTERPRET1 的准确交付接口
BACKEND1允许：`Backends/MLX/Sources/DMLXBackend/PitchAnalysisBackend.swift`、`PitchAnalysisProviderProtocol.swift`、`Backends/Audio/Python/d_pitch_analysis_backend.py`、`Backends/MLX/Tests/DMLXBackendTests/PitchAnalysisBackendTests.swift`、`Backends/Audio/Python/tests/test_pitch_analysis_backend.py`，不改现有transport/helper。公开 `PitchAnalysisBackend: InferenceBackend` actor，`init(configuration: PitchBackendConfiguration) throws`。`PitchBackendConfiguration` 为Sendable值，init参数 `pythonExecutable:URL, providerScript:URL, artifactDirectory:URL, timeoutSeconds:Double=30, cancellationGraceSeconds:Double=2`。descriptor id=`cpu.pitch.swift-f0`，version=`0.1.2-d1`，capability仅audioPitchAnalysis。请求model.directory显式指向swift_f0包目录，model.revision固定为modelSHA256；只读目录中model.onnx，实读SHA校验。prepared输入文件实读精确sampleCount*4、SHA、finite。estimate只验证，不载模型，正向测量前memoryestimate给保守256MiB。构造不安装、不下载。只允许nativeprocess独立CPU执行，环境PYTHONDONTWRITEBYTECODE=1/TMPDIR/XDG自有run目录，固定CPUprovider，当前modelinit ORT inter/intra线程各1。必须保留本包真实core路径且与指定model目录核对，不能从另一模型路径静默加载。script CLI `--request <request.json>` 读明确文件，版本1严格JSON；输出单个result JSON一行，UTF8与换行；stderr诊断不混stdout。Swift协议可复用AudioJSONParser防重复键/深度/布尔混数值。worker自行决定request envelope，不改变公开类型，request/result对应与资源清理测试冻结。artifact固定 `<artifactDirectory>/<runID.uuidString>/pitch.json`，其余任务文件不发布；目录拒绝已有同ID/符号链接/输入输出重叠；交付结果至少metadata中profile/model digest/provider/analysisSeconds。release不删publishedartifact。无声正常，失败/取消/消费者错误无published result，子进程退出+管道drain在execute返回前完成。必测受控fakeprovider正常/缺损模型/错来源/digest/run/NaN/布尔/重复key/超量/非零/部分行/取消/超时/消费者throw/重复run/发布文件保留；真实模型由Lead另测。Worker不改验收断言，测试可新增但不可令失败变通过。实际模型帧边界256,257,384,511,512,513,15999,16000,16001,19200均已核为floor(N/256)，尾部不足hop明确未观测而非静音。

INTERPRET1允许：`Packages/UI/Sources/DWorkbench/Audio/PitchInterpretation.swift`、`Packages/UI/Sources/UI/Views/PitchAnalysisView.swift`、`Packages/UI/Tests/DWorkbenchTests/PitchInterpretationTests.swift`、`Packages/UI/Tests/UITests/PitchAnalysisViewTests.swift`。公开 `PitchInterpretation: Sendable, Codable, Equatable`，`static let version = "equal-tempered-contiguous-5-v1"`，`let notes:[PitchNote]`，`init(result:PitchAnalysisResult) throws`先validate；`PitchNote`为Sendable/Codable/Equatable，`startSample:Int,endSample:Int,midiNote:Int,meanConfidence:Double`，坐标单声道16kHz，notes连续非重叠，run≥5frames，midi=round(69+12log2(hz/440))明确nearest awayFromZero，不合并隔静音/异音；blockstart=firstIndex*256/end=(lastIndex+1)*256，不外推未分析尾部。不产生tempo/velocity/谱面/音符试听。可检查原始Hz表与note列表，声明单声部近似及未覆盖尾部。
公开 `PitchAnalysisView: View` init `result:PitchAnalysisResult?, isBusy:Bool, isStale:Bool, status:String?, hasSaved:Bool, canAnalyze:Bool, onAnalyze:@escaping()->Void,onCancel:@escaping()->Void,onSave:@escaping()->Void,onReject:@escaping()->Void,onExport:@escaping()->Void`。无文件/模型/系统面板操作，callbacks由Lead装配。按钮identifier `pitch-analyze/cancel/save/reject/export`，结果 `pitch-result`。运行时仅取消可用；stale不能save；hasSaved禁止重复save但export可用；无result禁save/reject/export；analyze须canAnalyze且无未决定候选（hasSaved后可再分析）；拒绝只清未保存候选。UI原生SwiftUI玻璃、纵向响应窄宽，信息不截断，长轨迹用有界列表/摘要不塞7500行，中文与可访问label；显示近似音符和连续音高的区别。空结果显示“未检测到可靠单声音高”，不能称系统错误。纯callback测试与真实GUILead分别验。禁止新增计时器或本地任务状态副本；view不改变source。

本批公共暂存适配在ProjectStore显式拒绝pitch，直到Lead接入；不是已支持产品入口。BACKEND与INTERPRET不依赖未完成Store。语法/CPU检查各用本任务output/tmp；SwiftPM重构建Lead串行，Worker可编写测试不自称已执行。禁网络、签名、真实模型/GUI、原声访问；模型实际运行仅Lead。存在明确权限异常先报告。

Lead非实现者审阅后澄清（仍准备HUM1）：原声expected采样数必须严格256…1,920,000，派生仅允许转换舍入±1。voiced谓词是(score>0.9 AND 46.875≤rawHz≤2093.75)，后端在隐藏原始无声Hz前验证完整谓词；无声也可有高score但超频率范围，不把score单独当可靠声音。外部结果边界解码前2MiB，prepared输入读上限7,680,000字节，最多7500frames。result.validate自洽不代表来源已验，后端必须与本次输入精确比对且来源保护由Lead预处理/Store负责。actual model-hop-boundaries.json已覆盖最短及非整hop；不足hop尾部不外推。

### 派工前部署补充 HUM1a（BACKEND1，spec2；INTERPRET1不变）
普通App的书签不能仅假定子进程继承。BACKEND configuration追加可选`accessBootstrapRoot:URL?=nil`，复用现有AudioProviderAccess创建/释放明确model、preparedInput父目录和本run目录的继承访问，不扩权限。provider支持原`d_audio_access.py`同款`--access-manifest/--access-run-id`参数，复用现有helper（只读，不复制重写）；Python路径传入前核明只读的provider兄弟helper，外盘内部评估部署由Lead复制现有helper。无accessRoot保留受控CLI。无访问时明确失败，不尝试更换全访问启动器。bootstrap由应用容器提供，helper及包需普通代码签名部署/实际验收；这不是新签名方案或新模型分发许可。初次实施前补充，与既有接口向后兼容，非Worker返工。

## PACKAGING1：仅内部评估的离线识别引擎
新增独立受限Sol/high包D-HUM-PACKAGING-01，依赖已冻结provider文件名，无依赖其他Worker实现；三个实现槽位就绪且Lead可串行验收。仅允许新 `Backends/Audio/Packaging/prepare_pitch_engine.py`、`package_pitch_app.py`、`Backends/Audio/Packaging/tests/test_pitch_packaging.py`。不改现有builder/签名配置/其他脚本。
prepare CLI必需 `--python-root`已有独立Python3.12根、`--site-packages`固定批准环境、`--provider-directory`当前Backends/Audio/Python、`--output`新目录、`--internal-evaluation-ack`显式flag。参考prepare_engine/prepare_mrt2安全copy/manifest助手（只读复用），精确复制10个已批准版本及其必要package/native.libs/许可证，stdlib不带任意sitepackages/cache；不复制INSTALLER/RECORD/REQUESTED/direct_url路径泄漏。分发版本：swift_f0 0.1.2,onnxruntime1.22.1,numpy2.4.3,coloredlogs15.0.1,humanfriendly10.0,flatbuffers25.12.19,packaging26.3,protobuf7.36.1,sympy1.14.0,mpmath1.3.0；protobuf实际包google/protobuf（不能把无关google子包塞入）。核实际model.onnx SHA fa91bb45512b90339cf4b00a599ba8fe3a253c46419fcfe6b46df77a8a8336a5，399114字节。provider仅d_pitch_analysis_backend.py +原d_audio_access.py。engine.json同已有schema1filesmanifest，kind=d-pitch-engine、providerScript=provider/d_pitch_analysis_backend.py、vendorDirectory=python/lib/python3.12/site-packages/swift_f0、pythonExecutable=python/bin/python3、pythonABI=3.12、modelManifestsDirectory=model-manifests；model-manifests/swift-f0.json声明版本/actualSHA/CPUprovider/source MIT/weightLicense unknown/internal-evaluation-only，不伪造wheel-to-commit证明。模型包内权重被复制仅供已批准内部开发产物，禁止公开分发。
package CLI必需 `--app`已有普通开发签名App、`--engine`合法PitchEngine、`--identity`现有caller身份、`--output`新app、`--report`新文件、`--internal-evaluation-ack`。参考现有package_video_app：复制app→新Resources/PitchEngine.dengine→签必要新运行组件和新app→更新签名后的engine manifests→最终codesign verify，沿输入entitlements/identifier/team，不加例外、不触钥匙串配置、不修改原件。签名命令交给已有安全超时助手，Worker只受控fake命令夹具，真实签名Lead做。任何输出存在/符号链接/重叠/错类型/digest/模型许可ack缺失拒绝；原输入/既有输出不变。输出report固定状态只说明packaging与验证事实，不声称模型/GUI/公证/TCC通过。failedstage报告要有明确失败与已产生文件；有界temps只清自有未发布，不扫描/覆盖历史。新产物的后续真实运行另验。测试正常以及拒绝无ack/错fixedversion/missinglicense/digest/非有限manifest数/路径重叠/输出已存/符号链接/命令失败超时/report不可写，fake与real分开。只stdlib离线测试，不新依赖/构建/模型/GUI/network，不能以mock改写生产规则；对实际modelhash测试可读取唯一批准ONNX到自有夹具但不得Git收模型。

## HUM2：已核平台语义与共享修正（2026-09-15 JST）
当前预处理改为 `avconverter-mono16k-prime-normal-v1`，覆盖HUM1的prime.none选择；其他模型/voicing/数值/时间坐标/质量标准不变。SDK26.5 AVAudioConverter.h:55–62明确none为实时latency，normal零输出延迟。Lead原none四率CPU中24/44.1/48k输入期望8000却出8064/8035/8032，R/conversion-diagnosis保存先失败；normal四率长度与440Hz过零对照通过，R/conversion-normal。这是Lead平台选择修订，不追罚Worker旧常量。新文件标识、Python协议与重采样必须一同更新，不能只截尾并保留开头延迟。
来源时间解释：分析块在16k样本坐标保留；导出另给sourceNotes原始帧位置，末端裁到原选区（覆盖允许的1个重采样舍入差）。不人为推断节拍/力度；原声身份不称纯AI创作。原声备注/选区的AudioDraft.revision为当前保守输入版本，未提交输入也立即使采用禁用。切换文档取消相关任务并使未决定候选失效，正常关闭和冷重开同样保留证据但不再接受过期候选；已保留解释不失效。损坏未决定文件可按登记ID拒绝，不需要解码，也不删除坏文件。
Project schema12只增加pitch job/metadata/document关系；原v11迁移先保留project.v11.backup.json。旧测试中目标版本11改为currentSchemaVersion，拒绝未来12改为current+1；迁移原字节/历史关系和未来拒绝标准不变。这属于新版本兼容断言，不能借此放宽旧内容保护。

## 本批执行与审阅记录（进行中，未接纳）
三个受限CLI实现：BACKEND Sol/high，INTERPRET Terra/medium，PACKAGING Sol/high；独立外盘工作树/任务output+tmp，workspace-write网络false，shared.git只读，Lead代提交。实际turn_context与请求分别存R/<task>，隐藏服务解析unknown。初交BACKEND900s受控结束，获360s有界初交续跑107s完成；不是预算重置。INTERPRET初交后repair1修Swift成员限定、repair2区分损坏与无音高并阻止保存/导出；两轮已耗，初交单元9项/最终组合另记。BACKEND repair1修沙盒顺序/venv/限量读取/替换文件保护；repair2修已观察Swift测试发送边界并同步Lead HUM2。PACKAGING repair1修失败报告污染输入、resolver边界及真实许可证材料缺失；其初交自检迭代不计作Lead交付后两轮。每轮发送前已复核权限/异常摘要，未观察越界/提权。
非实现者只读评审具体反例由Lead修正并补测试，不等于额外模型执行验收。Lead负责共享保存/状态/原声预处理/装配，初次工作台编译捕获回调变量并发错误已用明确Mutex状态修补，未批量加unchecked；Swift Testing keypath宏需显式闭包。464方法的首次实际CPU有旧schema断言8issue与转换3issue，保留失败不宣称通过。最终组合/实际模型/GUI尚待，源仍07f27b与个人scheme不动。
FlatBuffers wheel缺许可证全文，已从官方固定tag对应commit7e163021e59cca4f8e1e35a7c828b5c6b7915953读取Apache2.0 LICENSE（11358B/SHA cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30），仅添加到单独bundle staging，不改安装环境、不安装新依赖。证据R/license-materials/flatbuffers-source.json；wheel与源码完整等价unknown。权重license继续unknown、内部评估，无分发许可结论。
