# D-VIDEO-WORKBENCH-01：视频基础工作台闭环

状态：2026-09-14已完成有限产品验收并本地接纳，最终文档提交/推送见本run/stage-final-receipt.json。规格stage-r1，契约video-workbench-r1及下文deployment-r2澄清。原始源基线8d42433f65540509633515333d9549d3465ffd1a，上一完整视频实测e26c6eaa395fe371512269c5fc97b5fa7bba86e6，上一组合/源实测1530e92584f2a36680e8c350b803e9338897dd32，旧审核与回执已对应。本批完整版本见结案段和各job.json，不为提交自引用改写历史。

R=/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-VIDEO-WORKBENCH-01/run-20260914T002821Z；W=/Volumes/CodexProjects/Codex/D-Worktrees/D-VIDEO-WORKBENCH-01。源scheme唯一未暂存差异，完整内容/diff/index/摘要及普通D四文件起点见R/protection/start.json。当前用户已确认普通D退出、GPU空闲、隔离测试版可用前台。H09仍待麦克风，不重复申请新模型/安装。

## 有限出口与优先级

先完成各模态的基础功能，再做跨模态组合。当前视频V0已有完整薄后端，缺用户入口；本批补项目→视频→草稿/模型选择→不可变任务→进度/取消→候选预览/选择/采用/拒绝/恢复→安全保存重开/MP4导出。复用项目、任务、资产与导出基础，不制作新的编辑器、时间线、节点或组合框架；不做I2V、音轨、新视频模型、音乐/手机/PNG平台。HUM、歌声与其他基础能力保持后续独立位置，不等视频高级功能。

默认Wan2.1 T2V-1.3B固定revision37ec512624d61f7aa208f7ea8140a131f93afc9a，T5/DiT BF16保留原FP32张量、VAE FP32，UniPC order2。默认832×480/17帧/16fps/50步/CFG6/shift8/seed42是当前样本，不是产品上限。显式宽高/帧数/fps分数/steps/seed按当前adapter合法域；不静默改值。512模型token限制由后端实际分词拒绝，UI不按字符假算。

## Lead冻结的共同行为

|输入/状态|操作|结果/反例|
|---|---|---|
|草稿含中文、emoji、未完成数字|保存/切文档|原始编辑文本保留；执行前另行验证，不把无效值改默认|
|有效草稿、已授权模型、空闲|生成|先安全保存草稿和排队记录；冻结请求、模型revision、预算、目标文档；结果不会自动采用|
|生成中改输入或切文档|异步结果到达|记录原任务/原文档，不能改变其他文档、覆盖新输入或触发旧按钮；布局变化不提交任务|
|队列/计算/保存阶段|取消/关闭|保留当前slot直到真实进程/管道/计算/写盘结束；保存失败保留待保存结果和原采用作品，不伪报completed|
|已有候选|选择/采用/拒绝/恢复|选择≠采用；拒绝只改关系且清除相关采用/选择，不删文件；跨文档、拒绝/失败/中断候选不能采用|
|合法既有项目v1…v7|重开/迁移|原始清单先备份，升级v8；v7严格字段仍校验，未知/损坏拒绝；媒体不重写、迁移不新建视频文档|
|已登记MP4|预览/导出|重新验证身份/内容/请求参数；只读本地，不自动播放/下载；原件不覆盖，系统同卷暂存/回读/独占发布；冲突与发布后失败明确保留结果|
|已切换项目/模态/预览|迟到播放回调|取消旧加载、停止播放器并解除观察；不停止由宿主持有的生成任务；音视频播放互斥|

内存：旧host默认仍是physical−max(4GiB,physical/4)，16GiB下12GiB。新增InferenceRequest.memoryBudgetBytes可选、默认nil，host显式allowsRequestBudgetIncrease默认false；提高预算需host允许，降低可接受，正数/Int64表示限制。Runtime按每请求快照准入，reservedBytes仍是估计占用。App仅视频UI显示自动与显式MiB，空字段=自动，无效字段保留并阻止按钮/快捷键。用户明确值同时送MLX软指导并写入结果，不把它叫硬内存上限。自动不足显示估计/预算/风险，不悄悄提升；其他Mac不受16GiB封顶。

部署：视频独立VideoEngine.dengine，原音频封装和签名不变。现成离线Python3.12与必要白名单运行依赖，不能携带整套torch/transformers或访问安装机器路径。无需下载新权重/依赖。引擎校验复用既有固定manifest安全实现；模型仍在用户选定外盘，只取得模型和本次run的窄目录访问。书签只存在容器临时访问记录、不进项目/导出。完成/失败后待子进程退出再清理。缺损视频引擎只禁用视频生成，既有项目和媒体可读。

## 分工与允许范围

Lead单一维护公共请求/预算、ProjectModels/ProjectStore/ProjectSession、WorkbenchSession、AppSessionFactory/Bootstrap、导航/资产投影、共享封装装配与全局文档。准备中先实现value contracts并CPU验收，再签发独立写任务；Worker不修改共享状态/存储/模型/签名配置。

### DEPLOY（Sol/high）

允许：Backends/Video/Packaging/prepare_video_engine.py、Backends/Video/Packaging/package_video_app.py、Backends/Video/Tests/test_video_packaging.py、Backends/Video/Tests/BundledVideoEngineChecks.swift、Backends/Video/Models/wan21.json、D/BundledAudioEngine.swift。不修改音频packaging、其他D文件、后端算法/runner、模型或任何真实App。

复用Backends/Audio/Packaging/prepare_engine.py与package_audio_app.py纯辅助（不要调用后者package()再次加音频）。固定目录：python/bin/python3、Python/d_video_run.py+d_video_model.py+d_video_prepare.py+d_audio_access.py、Vendor/wan21原样、tokenizer的4个既有固定文件、model-manifests/wan21.json、engine.json。kind=d-video-engine；pythonABI=3.12；providerScript=Python/d_video_run.py；vendorDirectory=Vendor；modelManifestsDirectory=model-manifests。tokenizer来自调用者显式目录并校验d_video_run.py的固定SHA，不运行/转换模型。视频小模型声明含schemaVersion1、repository/revision/profile/precision，非权重清单替代品。

引擎解析器保留历史类型名以兼容已有音频调用，Family增加video时将全部二元逻辑穷尽switch，音频路径/kind/必需字段完全保持；复用同一受限读取/逐文件SHA/执行位/不跟软链逻辑。新增videoTokenizerDirectory属性仅video返回root/tokenizer。不要复制300行新验证器或建通用框架。

prepare参数：--python-root（完整普通bin/python3.12+标准库）、--site-packages、--video-root、--audio-provider-directory（仅读d_audio_access.py）、--tokenizer、--output，均显式绝对路径。白名单mlx/metal0.31.1、numpy2.4.3、tokenizers0.22.2、ftfy6.3.1、wcwidth0.8.3及原生资源/dist-info/license；不安装不全量复制。只有tokenizers实际运行所需闭包确有缺口才停报，不擅自增依赖。输出无软链/安装绝对路径，已有输出拒绝覆盖。

package参数：--app已签名输入（可带音频engine）、--engine已准备视频engine、--identity既有身份、--output新App、--report新报告。校验输入/engine、复制到独立暂存、签原生子文件并更新manifest、签外层、核对bundle ID/Team/entitlements和音频engine字节不变、独占发布。不覆盖原产物，不换Team/bundleID/entitlements、不读密钥、不在Worker执行真实codesign。失败语义沿音频封装工具，输出已存在拒绝；发布后报告失败不能删除已发布App。

CPU夹具：有效与缺文件/错hash/类型/版本、Unicode空格路径、软链/重叠/已有输出、白名单及许可证、audio两family兼容、签名命令失败/超时/身份或entitlement改变、报告失败和已发布输出保留。模拟codesign明确夹具，Lead另做真实独立封装/导入/沙盒/生成验证。可对必要签名 helper 用mock，不降低断言。

### MEDIA（Sol/high，准备后签发）

仅新增Packages/UI/Sources/DWorkbench/Video/VideoMediaInspector.swift与Tests/DWorkbenchTests/VideoMediaInspectorTests.swift。公共VideoAssetMetadata由Lead提供。接口：public enum VideoMediaInspector；static func inspect(at: URL, expected: VideoRequest, timeoutSeconds: Double = 60) async throws -> VideoAssetMetadata；static func contentSHA256(at: URL, maximumBytes: UInt64) throws -> String。

限制本地普通无软链MP4、唯一H264视频轨、无音轨、transform方向恒等、尺寸/完整帧数/逐帧PTS和duration与request有理数精确对应。不能用nominalFrameRate近似冒充；允许等值约分CMTimeCompare。独立AVAssetReader完整软件解码，关闭/取消读者后才返回；检查前后及打开descriptor身份/大小/mtime/ctime/hash，路径祖先也检查。预期输入通过VideoExecutionCapability校验；读取预算按expected几何rawbytes+1MiB，哈希分块，超时/取消真实停止，禁止semaphore包装未结束异步工作。错误有原因，不返回默认成功。contentSHA256供原始字节复制的暂存校验，不等于新的解码证据。

夹具用软件H264生成小MP4，非GPU模型；检查有效有理帧率、错尺寸/时间/帧数/音轨、截断/错hash、软链/路径、deadline/取消及输入未改。不从生产结果抄黄金输出；如沙箱妨碍AVFoundation或SwiftPM先报Lead，Worker可先仅做源码/无缓存编译，不换权限。

### VIEW（Terra/medium，值接口就绪后签发）

仅新增Packages/UI/Sources/UI/Views/VideoCreationView.swift、VideoPreview.swift、State/VideoCreationActions.swift和Tests/UITests/VideoCreationViewTests.swift、VideoPreviewTests.swift。共同行为为原生液态玻璃、同级模态、内容/参数分离，沿AudioCreationView响应式布局；不得改导航和共享model/store。

VideoCreationActions @MainActor闭包：generate/cancel/save/chooseModel/stop:()->Void；select/adopt:(UUID?)->Void；preview/export:(UUID)->Void；reject:(UUID,Bool)->Void。生成由host最终核验，视图不触碰模型文件/任务/保存。VideoCreationView init(draft:Binding<VideoCreationDraft>,candidates:[ProjectAsset],selectedAssetID:UUID?,adoptedAssetID:UUID?,modelStatus:String,canGenerate:Bool,isBusy:Bool,progress:Double?,status:String?,previewURL:URL?,previewIdentity:UUID,defaultMemoryBudgetBytes:UInt64,actions:VideoCreationActions)。presenting(VideoCreationPresentation)->Self，enum complete/content/parameters。所有字段来自已有草稿，输入String不夹断；parameter展示自有已实现域/实测范围/耗时与内存提示，不能给用户虚假的占用保证。

VideoPreview(url:URL?,identity:UUID)为UI内AVPlayer承载；只用host提供的已验本地URL，初始不自动播放；替换URL/身份/onDisappear停止、清item/observer并取消加载；旧回调不改新状态。不要从元数据读取URI或自行打开文件面板。原生控件可播放/暂停/拖进度；非项目服务API不泄露Player。候选按钮不依赖右侧面板打开，拒绝可恢复，已有采用有明确标记，导出选中具体ID。按audio先有参数辅助+button handler反例，再CPU布局520/1000宽、长中文/emoji、数值无效不提交、忙时操作禁用、关闭参数不丢输入、两文档不同identity回调失效。若界面辅助需要测试hook可局部设计，不改宿主动作契约。

## 运行与验收门槛

每Worker独立外盘worktree、分支、索引；工作树+本run/output+tmp是唯一写根，workspace-write、网络false、忽略全局模型默认，具体模型/effort/turn_context由Lead核对。预检只读不IMPLEMENT；基线与规范漂移/权限拒绝按协作规程暂停回Lead。禁止递归、提交、构建真实App、GPU/GUI/模型/安装/网络/密钥/系统设置。普通初交+两修，最多一次有界Lead接管；每轮15分钟，不编号重置。允许局部CPU测试；Python用tokenize.open+compile内存检查，无默认py_compile；其他cache/tmp只用本run指定目录。

Lead逐包审核后提交，隔离合并、组合具体SHA回归：核心/工作台/视频与受影响音频桥接CPU、旧项目迁移/导出保护、独立签名App构建/封装、真实Wan生成/预览/取消/采用拒绝/保存退出重开/导出冲突及既有模态入口回归。完整后端数值/原50步样本按未变代码复用；App至少一次明确参数真实生成，缩小几何的流程实测不冒充原832画质。模型/精度不能为过测改变。真人没看到不能写真人通过，GUI被锁/权限阻塞记人工清单，不关闭用户App。最终源接入前后scheme/app/输入保护，源相关回归、文档结案与push分别记录。

## 恢复检查点

准备进行中；实现Worker尚未启动，3个只读规划已结束。用户GPU/GUI窗口已确认。当前Lead拥有W写权，源保持8d42433及个人scheme。下一步准备value contracts/独立CPU、准备提交，然后派工。规格、模型路由、修复、实现/审核来源、组合/源/最终SHA及真实证据逐步追加；不将计划写作已完成。

## 2026-09-14 执行澄清 deployment-r2

DEPLOY初交指出Lead原规格python/Python在默认大小写不敏感APFS冲突，CPU夹具FileExistsError，正确停报。此为规格缺陷，不追罚Worker。仅脚本目录改为provider，providerScript=provider/d_video_run.py；固定runtime python/、Vendor/及其余字段不变。MEDIA/VIEW公共Swift契约video-workbench-r1不变。DEPLOY以repair1完成此有界更正，原历史规格保留。VIEW初交SwiftPM用户clang缓存写入被拒、MEDIA嵌套sandbox被拒，两者均立即停报；Lead使用原授权独立检查入口，不扩大Worker权限。源及scheme保持起点。

## 实施中间检查点 2026-09-14（未接纳/未编译装配）
Lead共享接线与schema8持久化已形成候选，准备进入三包组合，不是产品验收。核心62方法和访问桥5方法通过；VIEW由Terra初交+两修，Lead一次有限测试接管（SwiftUI导入、任务目录、真实挂载/子树卸载与完整滚动内容横向测量），9方法通过，非实现者只读审核关闭；生产View未由Lead改写。MEDIA由Sol/high初交+repair1，8方法通过，最后普通修复用于加强原契约的身份/取消/超时反例与夹具收尾；新缓存路径拼写错误被拒后已暂停，未提权。DEPLOY最后修复针对精确清单类型、安装记录剔除和合法runner组合：不固定整个runner源码hash，改为显式输入文件复制前后身份/摘要/模式及最终清单一致，tokenizer/模型revision仍固定。全部历史和逐轮事件在外部run目录；未知服务端解析与费用仍unknown。真实App/GPU/GUI尚未执行，本轮用户窗口已确认，源分支及scheme未改变。

## 组合候选收尾检查点（2026-09-14，未源接纳）

三包固定候选：VIEW `3c1ded8f1ff207067580cea94c205e79706e4df9`，DEPLOY `826ecea6295c727408016ef36fc0d91a44bd132a`，MEDIA `a061e382e07426f892928d2aa17934dd44444f4e`；保留历史组合为`c4b98405e0d4bb1e55182c9faa7fe88fd48b3d6a`，Lead收尾代码`86a3d6c6db9e3da88e43558cfaba053ff3fd153d`。每包初交/两修结束，VIEW一次Lead测试接管，MEDIA一次Lead取消回调finish守卫接管；DEPLOY一次Lead真实wheel缺许可证接管，加入固定官方文本回退，不放宽要求。原失败、参数/可观察模型、停报与缓存事件保存在R各包目录。Terra/medium与Sol/high的实现、Lead共享装配和上述介入分别归因，隐藏服务端解析、订阅费用unknown。

Lead补充schema8旧断言、解码暂停期间编辑/取消、重复恢复保留额外原件、导出保护、字段回调ABA、预览关闭drain及drain期间取消终态。原始全局并行UI检查出现旧滚动时序失败；未改其断言，独立串行及随后组合串行357方法通过；新增取消后9方法局部通过，最终组合执行中。48个音频/MRT2/视频进程桥接方法通过，构建及执行证据分别在R/mlx-test-build-r1、mlx-cpu-r1，受测工作文件与86a3d6c代码一致。

三名非实现者仅只读复核，分别关闭VIEW/Store、MEDIA/取消、DEPLOY/清单/许可证问题；不冒充其独立运行测试。R保留每轮检查和产物。运行时已离线准备，安装环境与权重未改；闲置Tkinter不属于视频provider支持范围，实际导入/沙盒App待验。收尾记录第一次写入因系统Python stdin编码失败而未落盘，代码提交已成功；本追加如实补记，不amend。

下一动作是最终组合CPU、独立签名App封装、真实视频闭环，之后才可源接纳。源8d42433及scheme保持；三个实现Worker已结束，无任务写入者等待。当前Lead拥有W写权，模型/GUI资源由Lead串行使用。

## 2026-09-14 有限产品验收与本地接纳

实现/组合受测 `86a3d6c6db9e3da88e43558cfaba053ff3fd153d`；App与源受测 `2b4675cd7837532b77be4f1850c257e0458d2e09`，两者仅README/任务记录变化，代码/测试/依赖一致。源8d42433以固定2b4675快进，未改写历史；integration-command.json记录实际操作与个人文件核验。最后只修改结案指南/目标/任务/协作经验，完整最终SHA及远端见stage-final-receipt.json；不声称测试在尚未产生的文档提交上执行。

| 层次 | 实际结果与证据（相对R） |
|---|---|
| 核心 | 源source-core：62方法/10套件通过，零失败/跳过。 |
| 工作台与UI组件 | source-workbench：358方法/49套件通过，显式D_TEST_TEXT_MODEL启用旧权重只读校验，零失败/跳过。前期combined-ui-r3是357通过/1可选跳过，随后existing-text-checksum单独补验；本行仅指一次源完整执行，不把历史相加。 |
| 音频/视频桥接 | mlx-test-build-r1及mlx-cpu-r1：48方法/4套件通过，CPU受控子进程/合成媒体；不是48次真实生成。 |
| Python/清单 | video-python-combined与source-video-python各40方法通过（已包含15封装与5访问检查，不能重复累加）；lead-video-resolver-run 9检查、lead-audio-resolver-run 22检查。未重新跑未改变的Wan数值模块，沿用已验收V0。 |
| App/部署 | app-build-r1普通签名构建；package-audio-r1/package-video-r1独立产物，原音频引擎字节保持；prepare-video-engine-r3离线白名单、packaged-video-import从重定位后的bundle导入固定provider且全部来源在bundle；codesign显示/严格完整性与entitlement交叉核对通过。未安装/下载，不称公证或全Python/Tkinter可用。 |
| 真实视频/GUI | gui-r1/acceptance.json：320×192、17帧、16/1fps、50步、CFG6/shift8、seed42、14GiB显式指导值；固定revision/精度。真实取消后进程退出，下一任务完整生成、预览播放/选择采用拒绝恢复、模态切换与中文文稿保存、导出冲突、冷启动恢复通过。CUA操作不是新XCTest UI套件，也不是用户画质认可。 |

真实产物任务 `D5564CF2-8B5B-4B6A-8C38-8DC31DE677B5`，资产 `622BF017-56FE-4430-8A96-FBD87733C876`。视频182728bytes，SHA256 `fdd62ab72a631461e113f584d71811ee443106c29a6574373247b1375270211b`，17/16秒、H264、无音轨。result.json记录后端253.192秒（从任务到资产254.875秒）、MLX峰值11893469474bytes≈11.077GiB、进程峰值RSS5105598464bytes≈4.755GiB；最终MLX active18bytes/cache0且子进程已退出，两种内存不可相加或称跨机保证。短片可见红车但明显模糊/形变/色彩瑕疵，本次不升级成片画质。请求/固定权重清单摘要/精度/seed/逐阶段记录/完整MP4均保留专属项目，输出不入Git。

生成未自动采用。Lead通过CUA执行界面动作：选择/采用，拒绝后清除关系而原件不变，恢复后采用；导出与资产全字节相等。原生同名面板确认后应用仍拒绝覆盖，副本hash/size/mtime不变。修改并保存新的中文/组合字符/emoji视频草稿后，旧任务request不变；冷启动恢复后documents/jobs/assets语义全等，媒体字节不变、模型恢复校验、预览成功。VideoProcessAccess已为空。实际GUI限独立项目/产物；非相关图文音频入口回归不冒充新三模态生成。

三包来源：VIEW Terra/medium线程01a09d5b-3002-7171-99c7-2d2e474f3905；MEDIA Sol/high线程01a09d5b-3001-79b3-8070-a780b916c1e3；DEPLOY Sol/high线程01a09d5b-3002-7772-a1d5-7d313af18110。各自在任务工作树/output/tmp可写、网络关闭、实际turn_context核验，无共享.git写权，基线2a046c70db9c311a7407ce30969c86d15ef42800。各初交+两修已用，Lead有限VIEW测试、MEDIA finish守卫、DEPLOY许可证回退接管分别记录，三名非实现者只读复核关闭，见review-closure.json；共享契约/状态/存储/装配/回归由Lead负责。运行时间/原始用量在逐轮记录中，未将resume累计快照相加，完整Lead费用与订阅费用unknown；本样本不证明低成本模型无需接管或经济性最佳。

保留E-VW-CUA-01隔离事件：首次正常退出11941后读取AX触发自动启动12269，缺隔离环境、仅停项目选择页；普通ModelLibrary启动索引写入（事前无摘要，无法证明元数据未变），两条installed/零lease/无错误，未打开普通项目、无下载或生成。已退出，并以同一隔离UUID26AD1FC9-1792-4093-93D6-6A682B2541F7显式启动12337完成冷重开，期间普通索引摘要保持。不能把普通D产物未变说成所有用户偏好完全未变；没有自动回滚索引。详见gui-auto-relaunch-incident.json与失败清单。后续退出只读进程回执/库存，不对退出App读AX。

恢复检查点：源已接纳2b4675，最终文档SHA/推送/远端见stage-final-receipt.json；候选W与三个Worker工作树/分支、证据保留。源索引干净，唯一未暂存scheme仍orderHint1→6，摘要ca3635d88aa5a15397b90e528667c66c0e6db7e596176e885c79d194b544206c；普通D四文件与独立测试App关键文件前后全等。两个受控GUI进程均退出0，自动启动实例也退出，生成子进程/观察器及所有本批Worker结束。不推进主分支，不替换普通App。H09待麦克风，没有新人工授权项；停止本批，下一建议是图像参考编辑基础闭环，先按实际模型条件确定契约，不启动I2V/时间线/组合/HUM/歌声新实施。
