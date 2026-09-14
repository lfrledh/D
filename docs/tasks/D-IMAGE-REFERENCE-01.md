# D-IMAGE-REFERENCE-01 单参考图基础编辑

状态：已获用户本阶段执行/验收/提交授权；隔离候选组件/装配通过，真实模型与GUI待验收，尚未接纳。日期2026-09-14。
source_base=b15be1175b80f265752f79eb45c6f3981ca13283；spec_revision=1；contract_revision=IR1。
W=`D-Worktrees/D-IMAGE-REFERENCE-01`，分支`codex/d-image-reference-01`。
R=`D-Development/AgentTrials/D-IMAGE-REFERENCE-01/run-20260914T034346Z`。执行基线在准备提交后由Lead以完整SHA写入各任务job/路由记录；不是源漂移。

## 范围及冻结行为

项目→图像→显式选择参考PNG/已有图像→描述修改→新候选→比较采用/保留原图→保存重开/安全导出。已有Klein4B q8 revision ef52ee019fd1d0e75ae4deb40476ba65989716d7；4步、guidance1、512tokens、BF16计算不变。无新权重/依赖、mask/strength/区域锁定、多参考、LoRA、RAW/任意JPEG、工作流编辑器或签名修改。

单参考为实际模型图像条件，语义服从近似，不承诺其余区域像素不变。输出与参考尺寸各自256…2048且32倍数，保持已支持输出profile；这是首个adapter范围而非16GiB机器上限。不隐式缩放裁切。首版PNG8位RGB/RGBA，单帧、正常方向；透明底按白色合成、转换至sRGB RGB8。原PNG逐字节保留；执行派生为无头、行优先RGB8 `rgb8-srgb-v1`，真实颜色/方向边界需独立夹具验证。未知/损坏/超限明确失败，不回落文生图。

| 起点/操作 | 结果/反例 |
|---|---|
| 旧文档/浏览来源/采用候选 | 不自动成为参考；reference为nil继续T2I |
| 选择参考 | 显式referenceImageAssetID，独立于selected/adopted/sourceAssetID |
| 点击生成 | 首次await前冻结文档/参数/参考ID/模型；成功保存后制作每run独占输入，hash/尺寸/字节/编码进入请求 |
| 排队后改草稿/切文档 | 旧任务只用提交快照；完成只追加原文档候选，不覆盖最新草稿或原件 |
| 取消/失败/拒绝 | drain后释放；保留源PNG/已发布作品，不清理未知文件 |
| 参考文件被替换/损坏 | 受控读取、摘要和完整性失败；不使用另一次路径读取冒充已核输入 |
| 重开/移动项目 | schema9安全迁移v1…8有原清单备份；执行路径重定位不改来源/摘要 |
| 复用条件/PNG配方 | 同项目明确保留原参考；当前不能携带依赖的完整配方导出必须拒绝并说明，普通PNG安全导出保留 |

## 公共契约与单一所有权

Lead维护Sources/DInference/ImageReference.swift、InferenceRequest/ImageExecutionCapability、LocalImageModelInventory估计，以及ProjectModels/ProjectStore/ProjectSession、WorkbenchModel和工程装配。reference请求必须显式referenceKlein4B/1，旧backend因此拒绝未知profile；schema9防旧App静默丢条件。ImageReference URL+sha256+byteCount+width+height+encoding，不含数组/书签/UI；通用请求只值型。实际RGB载荷读取由后端验证，同任务MLX许可覆盖所有编码/扩散/解码。参考编码独立VAE阶段，eval/释放后加载Transformer。

## 两个先就绪的独立实施包

1. IR-BACKEND，Sol/high，允许：Backends/MLX/Sources/DMLXBackend/MLXImageBackend.swift、Flux2ImageMath.swift、新ImageReferenceInput.swift；Tests/DMLXBackendTests下新ImageReferenceBackendTests.swift、Flux2ReferenceMathTests.swift。不得改Vendor/公共契约/锁/工程。添加真实分阶段参考编码和生产math数值测试，参考固定tiny image fixture。读取权限受限本地RGB并拒绝摘要/字节/尺寸不符；共享许可/逐步取消/资源清理/原T2I不回归。所有MLX测试Lead串行；Worker只写测试，不运行GPU/完整构建。
2. IR-PIXELS，Sol/high，允许：Packages/UI/Sources/DWorkbench/Media/ImageReferencePixels.swift及Tests/DWorkbenchTests/ImageReferencePixelsTests.swift（仅这两路径）。public struct ImageReferencePixels: Sendable，let width:Int,height:Int,rgb:Data,sourceSHA256:String；public static decodePNG(_ data:Data) throws -> Self。不读写任何文件，不创建资产/任务，解码同一受限Data。输入不超过64MiB，符合上方几何/8位/方向/单帧；CRC/解压/数量严格，sRGB/透明白底/行序可验证。受限PNG元数据解析，不执行URI/指令、不静默忽略未知色彩语义。可用现有Foundation/ImageIO/CoreGraphics/CryptoKit/zlib，不加依赖，不改PNGRecipeCodec。允许局部CPU测试，专属缓存；失败/超限不返回假像素。

后续UI包待Lead接线契约就绪才签发，避免空等或并写共享状态。两个独立CLI与Lead并行；原生只读设计核查已经完成，可复用记录，后续重要Lead实现由非实现者固定快照审阅。

## 运行及验收

逐任务独立外盘worktree/分支，workspace-write仅自己的目录与R/<worker>/output,tmp，network=false，共享.git不授写；Lead按允许路径提交。预检只读，Lead核cwd/HEAD/commonGit/model/effort/实际sandbox后发送IMPLEMENT。源码编译用内存compile；Swift显式独立module/scratch缓存。网络/安装/GUI/GPU/签名/源目录/用户应用/模型/其他任务/全局配置均Worker禁区，不递归。初交+最多两次针对修复，必要一次有界Lead接管，不重置编号或预算。未预先授权权限拒绝立即暂停报告；既定唯一缓存降级一次；成功越界/身份错/未知副作用停止。

冻结验收：核心profile/旧host拒绝/JSON兼容；参考解码RGB/透明/色彩/方向/损坏/CRC/截断/尺寸/溢出/预算CPU；Store原件hash/外部改变/安全迁移/保存失败/项目移动/快照隔离；backend固定FP32参考atol1e-4 rtol1e-3、IDs精确，实际BF16 encoder权重覆盖/有限值，条件与无条件对照、取消后下一任务、重复释放；原T2I/文本回归；普通签名隔离App参考编辑、采用/重开/导出防覆盖。Worker自检≠Lead复验，夹具≠真实生成，CUA≠XCTest，人眼图片判断≠精确服从。

源个人scheme起点ca3635d88aa5a15397b90e528667c66c0e6db7e596176e885c79d194b544206c，未暂存1→6；R/protection/start.json和副本。普通D4关键文件保护。旧阶段完整受测2b4675cd7837532b77be4f1850c257e0458d2e09→源b15仅8份Markdown。不得关闭用户D；GPU/GUI等待本阶段空闲确认。测试App退出只看持有进程回执/非启动inventory，不调用目标getAXState自动重开。H09待设备，集中人工办理时提醒。

## 恢复检查点

已完成：源身份/历史结案差异/保护核验、两个只读设计核查、外盘隔离目录。未完成：实施/测试/真实验收/集成/push。普通D不操作。模型隐藏服务解析和订阅实际费用unknown，后续按实际角色/返工/源码SHA记录，不把Lead接管计作Worker独立通过。

## 2026-09-14 接线检查点与UI工作包（spec2；后端/像素IR1不变）

IR-PIXELS：Sol/high初交＋修复1。Worker因SwiftPM嵌套sandbox_apply拒绝正确停报；未扩大权限，0项Worker测试。Lead初编译发现try语法错误，独立审阅另发现gamma payload、累计解压和TIFF后继指针问题；修复后Lead9方法CPU通过，非实现者关闭，候选d75213a01c421b7ce7a1176adaf40cd5674da25a。不是实图/模型验收。IR-BACKEND：初交候选87298dc，build-for-testing通过；正在修复1（FP32像素归一化后转BF16、补实际编码及生命周期检查），无GPU执行。

Lead接线候选已与PIXELS保留历史合并；16个匹配ImageReference的工作台/组件方法通过。原图复制、快照任务、取消下一任务、schema8备份、历史浏览原件不激活、派生hash、防覆盖、保存失败/重开均有CPU证据。来源绑定通过每run准备票据验证，不能拿B像素冒充A；所有参考入口携带docID/navigationEpoch，并校验当前image模态。历史原件保留安全相对路径，不强改为新导入目录；导入新文件使用Images/<UUID>/original.png。真实UI/GPU仍待本阶段用户空闲确认。

IR-VIEW：Terra/medium，contract=IR1-UI1。仅允许Packages/UI/Sources/UI/Views/GenerationInspector.swift、新ImageReferenceSection.swift、新Packages/UI/Tests/UITests/ImageReferenceSectionTests.swift。Lead已提供WorkbenchModel.referenceImageAsset、canUseSelectedImageReference和chooseImageReference/useSelectedImageReference/clearImageReference(documentID:navigationEpoch:)；参考ID来自ProjectSession，视图不另存任务/草稿。新section放模型与提示词附近，显示未选/原件名与尺寸/近似服从，按钮导入PNG、使用已选图片、移除参考；保留原图，用新候选，不暗示精确局部编辑。不自动选择asset/采用/生成，不把查看资产改成输入。请求记录显示任务实际参考名/hash/几何，并与当前草稿分别标注。宽参数栏窄时纵向排布/文字换行，继续ScrollView；原生系统控件与现有玻璃外壳，禁额外视觉框架。

UI操作闭包在渲染时捕获activeDocumentID与projectSession.navigationEpoch，Task开始后必须传原捕获值，不能重新读取当前doc作为旧事件目标。模态切换/离开再回来的ABA旧事件无效；文件面板内部也复核代次。isChangingProject时disabled，选中非PNG时“用作参考”disabled；running不意味着草稿不可改，已提交快照保持。Tests按WorkbenchFacadeTests/ExecutionSettingsViewTests既有模式，用独立临时项目、fake engine、NSHostingView离屏布局；不启动App/系统文件面板/GUI自动化/GPU。不重复SwiftPM嵌套拒绝；Worker仅源码解析（swiftc -frontend -parse）及测试编写，由Lead执行CPU suite。

UI独立工作树/base/model/输出在R/view/job.json；预检后才实施。初交+两轮针对修复预算，固定范围/路由规则同上。源仍b15、scheme未暂存保留；源和普通D尚未推进/改写。用户未回复空闲前继续不受影响的CPU/构建，不把旧窗口授权外推。

## 2026-09-14 组合工程检查点：等待本阶段真实资源窗口

当前实现代码/CPU/装配受测SHA=2a34f12c3bc6d47b6b8bf93db339659b0da4d480。状态为**隔离候选已完成组件与装配验证，真实模型/GUI待验收；尚未源接纳、未推送**。源仍b15be1175b80f265752f79eb45c6f3981ca13283及唯一个人scheme修改；不得把候选界面默认接入日常源版本。此段后的提交只有3份状态文档，代码对应关系和最终候选SHA见R/engineering-checkpoint.json，不自引用提交。

### 实际交付与来源

- IR-BACKEND：受限Sol/high，初交＋修复1，cc51669afea4d05894d219383a57116814ffc360。FP32像素归一化后转BF16；参考VAE编码、t10条件与生产step共用固定实现；源码非实现者审阅关闭。初版87298dc及修复后的build-for-testing都通过，真实激活仍未执行。
- IR-PIXELS：受限Sol/high，初交＋修复1，d75213a01c421b7ce7a1176adaf40cd5674da25a。Lead执行9项CPU；non-implementer review关闭。SwiftPM嵌套权限拒绝正确停报，不曾扩大写根或继续绕行。
- IR-VIEW：受限Terra/medium，初交＋修复1＋修复2，d4c1c310b7c037f8c4725195a4a18e48d38c5c47。初交async RunLoop编译失败；修复1新增private探针导致合成初始化器私有，修复2显式初始化后2项实际CPU通过；三个按钮窄栏纵排、宽栏横排/视口内均有几何断言。无Lead重写该Worker实现，非实现者review关闭；普通修复预算已用完，不能另编号刷新。
- Lead统一实现值型契约、schema9、Store/Session/facade接线并执行测试。固定版本审阅发现旧Images/Legacy.png被错判新目录：R/legacy-reference-negative先失败，788ba1c修复后通过。A/B准备票据、文档/epoch/模态、原件保护、项目移动和入队前取消均有具体反例；非实现者shared-review-final关闭。Lead自有测试最初选择不可用text模态导致失败，改为夹具实际支持的video空模态，不改变生产规则。
- 独立CLI时间/模型/写根/退出与原始turn用量见R/worker-execution-summary.json和各worker route-accepted/process/events。实现期间BACKEND与PIXELS有真实重叠；VIEW在共享契约就绪后开始。模型隐藏解析、订阅实际费用、完整Lead消耗unknown。原始turn计数仅留档，未经本批增量归一化不求和、不把缓存重复加计；不能凭单批断言哪个模型最划算。

### 验证索引和限制

| 检查 | 实际结果 | R下证据 |
|---|---|---|
| 组合核心 | 64测试/11suite，零失败/跳过 | combined-core |
| 组合UI/workbench CPU | 379测试/53suite，零失败/跳过，包含权重只读校验与离屏几何，不是模型推理/前台GUI | combined-ui |
| 参考输入后端CPU | 6执行/6通过/0跳过；第一次OnlyTestIdentifiers过滤导致0执行，未算通过，改用既有CLI完整target/suite过滤后实际执行 | backend-input-cpu-r1、backend-input-cpu-r1-summary.json |
| 后端编译 | build-for-testing通过，代码1aa92f84；后续至2a34仅Store/tests/UI变化，MLX代码完全一致 | backend-build-repair1 |
| 普通签名隔离App | 组合2a34 build通过；按既有方案封装音频/视频引擎，诊断exit0，未启动App | app-assembly、package-audio、package-video、app-signing-report.json |
| 共享专项 | 20测试/4suite实际通过；旧项目合法Images子目录、移动后新run、入队前取消反例包含其中 | shared-final-reference |
| 原全套初次失败 | 376项两处历史迁移assert仍为schema8，当前明确schema9；只更新这两处预期，备份/严格ness断言保留；之后377和组合379通过 | integration-ui-full、integration-ui-pre-view-r1 |
| 数值/真实生成/GUI | **未执行**；不把已编译/条件跳过算通过 | real-mlx-prepared-not-run.xctestrun仅配置 |

恢复前：先核源b15/索引/用户scheme、候选HEAD、worker/test已结束回执和用户本阶段资源确认。R/protection/start.json与pre-gpu.json记录scheme完整差异、索引、内容摘要/mtime，以及普通D四关键文件均不变；初始diff字符串省略终末换行已明确归一，文件字节未改。三个CLI全部写权已交回；无本阶段App/GPU进程启动，没有活跃实现者。

下一步只需确认普通D已保存退出、其他AI/GPU空闲且测试版可用前台，然后Lead串行：固定FP32参考/实际BF16激活/条件对照/取消恢复/重复释放/旧图文回归；真实普通沙盒导入参考、生成、新旧比较/采用、保存冷重开/普通PNG导出防覆盖。使用R/D Reference Workbench.app并由R/launch-isolated.py显式D_UI_TEST_SESSION启动，退出后不用getAXState重新触发启动。数值当前冻结atol1e-4/rtol1e-3、IDs精确，验收失败不能改黄金样例或阈值；BACKEND/PIXELS各尚余1轮普通修复，VIEW已无普通修复。通过才固定SHA源快进/源相关复验/按授权push；本检查点不启动下一产品批次。H09仍待设备，音乐/HUM/歌声与研读不以高级图像完成为前置。

## 2026-09-14 资源授权恢复

用户明确本Mac默认由Lead使用/管理，今后无需再确认空闲，用户需要时主动通知。本任务恢复真实模型与GUI验收，旧等待窗口已解除；工程候选c6ac018/受测代码2a34保持，未重新实施或刷新修复预算。资源授权证据R/resource-policy-authorization.json；新长期规则已写AGENTS/协作规程。恢复核验源b15、candidate c6干净、scheme原hash/未暂存不变，未见实际D/已知推理进程；进程名相似的Dock/DiskManagement不是D。真实模型仍由Lead串行，独立测试App显式UUID启动，保留普通应用与作品。
