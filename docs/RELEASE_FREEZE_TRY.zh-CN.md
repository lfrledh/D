# 本地候选与发行复现材料

2026-11-06 · 已批准12项文案、五档打赏及有限工程收口。唯一实际版本和启动入口见[当前行动](CURRENT_ACTIONS.zh-CN.md)，不是下方历史R16包。当前仅Apple Development签名的完整沙盒Release；不是Mac App Store分发、提审或发行通过。

## 当前可复现路径与证据等级

1. 使用桌面“D 最新版”，核对包内源码及交付回执。正式App不含第三方模型权重；本地资源来自用户明确选择的下载或原文件/副本路径。新用户选择目录时由系统授权，不预授全盘权限。
2. 无模型时仍可打开项目/查看已有资产；选择真实目录条目后取得/校验/登记与执行就绪分开显示。审核者需要自有可用资源及相应第三方资格，不能用固定回复冒充推理。
3. 用独立项目验证Quick/工作流、输入/Undo、保存冷开。Qwen9B Q4停止前缀与准确步骤保存失败→只保存恢复已有正常App证据；沿用版本见任务归档，不外推全部模型/配置。
4. 低内存方式保持同一准确权重，默认询问；拒绝不推理，同意一次不改默认，已记住选择可撤销。不同模型原始精度/变体的实模证据分别见矩阵。
5. 帮助“支持开发者…”及设置“打赏支持”共用面板。11月6日已批准免费本体与五档消费型打赏，客户端使用稳定拟定商品ID；正式后台尚未创建/核验，获取不到时不显示虚构价格。本地Xcode配置只作测试，不是商店账户/跨设备验收。
6. 干净配置/独立容器不等于另一台干净Mac；Intel、Store签名安装/升级、正式账号及系统强制批准仍按D-I024记录，不清用户模型/权限制造首次使用。

## 支持记录的数据流与隐私事实

既有客户端已实施、历史15组件/2本地Xcode方法验证的方案（正式账户/跨设备仍未验）：StoreKit验证结果→应用/环境/交易去重→逐笔时间、实际Decimal金额及币种、应用范围匿名账户、退款/撤销→应用私有账本；原签名凭据进本机、不云同步的Keychain。创作项目、公开日志和截图不含这些记录。未知金额/身份保留未知，不用商品现价或名称倒推；不跨币种加总，也无积分/余额/会员权益。

配置了商品时，启动/面板打开/返回应用有限读取`AppTransaction.shared`与`Transaction.all`；不轮询、不自动`refresh`/`AppStore.sync`触发账户认证。每次重新核对先撤销可展示账户范围，旧本地文件不能自行认领给新账户；离线失败保留原记录。已验证历史恢复不再次购买或发放权益。新购买在凭据和账本落盘后finish；失败只恢复同一交易。历史同步状态与支付状态独立。

启用了Apple公开消费型历史键；Apple特别提醒消费型重复交付应有服务器对账。D目前不因打赏发放内容/额度/功能，历史恢复只合并记录。客户端回放测试和Xcode本地历史不是正式同账户跨设备证明，也不是开发者集中支持者名册。

**最小推荐**：当前不部署外部服务，先完成正式沙盒账户下的同账户恢复验证。若未来必须由开发者集中识别/兑现回馈，再明确批准一个最小收据验证与记录服务：Apple签名校验、应用/环境/交易幂等、退款更新、加密数据库、保留/删除策略与单独认证；匿名appTransactionID及收据本身不能充当登录凭据。不先搭账号平台。托管地区、费用、域名、身份验证与隐私披露需该阶段明确，当前未采购/部署。

## 发行决定 D1—D5（2026-11-04 核对）

| 决定及负责人 | 推荐和验证方法 | 备选、能力及成本/数据影响 | 未决定阻塞 |
|---|---|---|---|
| D1 · 依赖分发、D 自有代码的许可与公开范围，由用户与许可顾问决定 | 优先保留当前编码与推理能力。按实际二进制补足可获取的完整对应源码、构建/修改说明，逐组件核对再分发及商店条件。评审演示下载数据如何由固定包内代码使用。 | 经批准替换特定编码器或取得相应第三方权利，需要重新验证格式、画质和跨机支持，可能产生许可成本。D 自有代码是否公开单独决定。 | 商店分发许可和运行方式核准（I026/027/031） |
| D2 · 支持记录的正式保证，由用户决定，Lead 验证平台 | 先验证同一沙盒账户在两台 Mac 的购买、恢复、退款及切换账户，按已验证范围展示记录。保留本地跨进程恢复证据与自动退款零通知记录。 | 如承诺开发者侧对账，需另批最小签名验证/幂等账本，选择地区、负责人、预算、保留期限、删除与备份责任。仅传必要交易/环境/退款字段，另做身份验证。 | 跨设备或开发者侧保证及正式 IAP（I028/030） |
| D3 · 本体免费、五档打赏金额已批准；销售地区及后台操作仍待对应授权 | 使用下方五档待录入表；界面价格只取StoreKit。消费型可重复购买，不解锁功能。本轮暂不做自定义金额。 | USD为自动定价基准；已指定币种逐地区人工覆盖，不以界面语言推定storefront，不暗改不支持的精确价格点。 | 后台字段/地区/精确价格点读回、商品配置及购买审核（I030），不再等待售价或自定义金额决定 |
| D4 · 公开主体与支持承诺，由用户/顾问确认 | 按准确模型/精度和已测硬件填写能力，将尚缺的演示列入验证。提供真实支持与隐私 URL、联系主体、地区、年龄/内容及出口加密信息。审核路径采用可合法使用的合成输入、导入、保存、冷开，有权使用的准确模型再验证生成。 | 扩大支持硬件/地区需要相应设备、资源和支持成本。隐私材料分别描述本机项目、Speech、搜索词/所访网页、MCP 许可服务、模型下载和 StoreKit，外部账本会改变申报与维护。 | 公开材料、隐私披露及正式审核范围（I022/028/029） |
| D5 · 正式发行操作，由账户持有人授权 | 用显式正式 App ID、匹配的 Mac App Store 配置与分发签名验证 Archive、安装、升级、恢复。每一步分别记录对应制品与结果。 | 可由有资格的账户管理员配置证书/描述文件或使用获准自动签名。需要相应账号角色、测试设备和审核时间。 | main 接纳、标签、上传、提审、发布各需独立授权（I024/025） |

实包包含 7 个引擎。ExternalVideo 内的 FFmpeg/ffprobe 9.0.1 采用 shared、GPL、version3、x264、x265、OpenSSL 配方。19 个原生库中，FFmpeg 自有库为 avcodec、avdevice、avfilter、avformat、avutil、swresample、swscale，另外包括 SvtAv1Enc、dav1d、mp3lame、mpg123、opus、vmaf、libvpx、x264、x265、lzma、crypto、ssl。来源、配方、许可文本和签后摘要已登记。完整对应源码与商店分发取舍仍属 D1。[上游许可](https://ffmpeg.org/legal.html) · [Apple 审核 2.4.5 / 2.5.2](https://developer.apple.com/app-store/review/guidelines/)

当前pending边界（I030）：StoreKit成功批准会通过Transaction.updates交付交易，但本客户端无法把缺少平台身份的pending请求与某条全局更新准确一一对应。交易可验证、落盘并finish，当前进程的unknownPaymentOutcome仍可能保持，Reload不解除未知请求保护，后续打赏仍被禁用。本轮不称继续购买闭环已通过，也不清标记、凭同SKU/时间猜关联或要求重启绕过。appAccountToken的公开语义为账户关联，不未经论证当逐单编号；若后续改关联须先审最小平台方案。服务端账本仅为未来额外识别/回馈承诺的条件项，不是当前首发必建服务。[Apple pending](https://developer.apple.com/documentation/storekit/product/purchaseresult/pending) · [账户关联](https://developer.apple.com/documentation/storekit/product/purchaseoption/appaccounttoken(_:))

I030下一步最小方案（本轮仅调查，未改付款代码）：沿用TipStore和现有私有账本，提交购买前先持久保存有限的请求记录（本机attemptID、商品、bundle/environment、已验证账户范围、dispatching）。保存失败不调用purchase；pending更新该原记录，冷开先恢复未决记录，再消费Transaction.updates。直接success回包才能把捕获的attempt与该已验证transaction.id关联；全局更新只按精确交易ID入账/finish，不能按同SKU、金额、时间或“只有一个未决”认领旧请求。现有unknownPaymentOutcome及两个未完成集合只是内存状态，**尚未完成跨进程未知请求保护**。appTransactionID是同账户/App的稳定范围，不是逐次请求ID；无账户/换账户时不能借别的交易解锁。Apple对pending成功交付updates的说明不能证明拒绝会发交易，空历史/超时也不能证明拒绝。appAccountToken继续为账户语义，不发明逐单用途。

拟议持久化先仅追加已有私有支持记录中的请求状态；交易凭据继续现有Keychain，项目与日志不存凭据。最小验证为提交前写失败、pending冷开、拒绝无事件、同商品异设备/异账户、直接成功与落盘失败、重复updates/finish中断；不重跑既有25组价格测试。当前公开API证据不足以让无身份pending自动解除；若允许用户明确发起另一笔打赏且旧请求仍可能完成，这是另待审的行为取舍。无服务器、无新账号、本轮无正式账户/真实付款。依据：[pending](https://developer.apple.com/documentation/storekit/product/purchaseresult/pending)、[updates](https://developer.apple.com/documentation/storekit/transaction/updates)、[appTransactionID](https://developer.apple.com/documentation/storekit/apptransaction/apptransactionid)、[Ask to Buy](https://developer.apple.com/documentation/storekit/testing-ask-to-buy-in-xcode)、[WWDC25账户token](https://developer.apple.com/videos/play/wwdc2025/249/)。

### 2026-11-06 审计续办：当前包来源事实（I026/I027）

前轮dc860审计续办的资源证据：先核 `Nov6-aff734d3/D.app`，再核 `Nov6-Retry-3b4ffcd5/D.app`：7份engine.json、2份runtime-origin及全部引擎文件字节与前包一致（完整Resources比对54,433文件，差异仅10个SwiftPM资源包的Info.plist/签名）；事实表适用于新候选，资源清单摘要仍a85e58b9…。该前轮仅聊天预设消费者改变；本轮aebbcffe另有模型添加/备份/文案及来源登记，最终包资源另验，不由旧版本外推。19库限定为ExternalVideo的 `native/` FFmpeg依赖集，不包括Python及wheel内其他库。`otool -L` 是声明的动态链接边，不是本轮执行模型或观察全部库已加载。完整签后摘要/依赖边留 `run-20261106-audit-followup/external-video-current-facts.json`，大原件仍在原受控目录；不新增永久许可台账。

| 当前组件 | 精确身份、随包字节与来源 | 修改/构建及实际接线 | 缺口与判断边界 |
|---|---|---|---|
| ExternalVideo FFmpeg/ffprobe及19库 | 21/21实际签后SHA/长度匹配engine.json；7个FFmpeg自有库+11个外部组件的12库，含libvpx；均arm64 | runtime-origin的输入二进制摘要与签后清单分开。104条非系统链接边均解析到本engine内；无Homebrew绝对依赖。14/14 native许可文件摘要相同 | 不由链接闭合推定许可证/Store通过；ffmpeg/ffprobe/x264/libvpx签名抽查通过，其余签名沿正常整包门禁 |
| FFmpeg 9.0.1 companion | 既有 `run-20261027-quality-closeout/distribution/ffmpeg-9.0.1.tar.xz`，12,036,420字节，SHA256 `cf38e0e28c7e5605942c4a77755349b0145804a397af37eb1fb4c77cb237f635` | [来源登记](../Backends/Video/Packaging/Licenses/ffmpeg-9.0.1-SOURCE.json)；随包Homebrew配方SHA `c350685d70db3a93a983062d28db5e677f7dc7651ba391a269ad6620b589073f`。prepare_external_video_engine.py校验归档、配方、许可/原始工具，App不内嵌源码归档 | upstream配方参考9989cb08…不是已证installedTapCommit（仍null）；companion须独立交付，其他依赖对应源码不能由此覆盖 |
| x264 r3222 | 本机安装配方明确源码commit `b35605ace3ddf7c1a5d67a2eb553f034aef41d55`，配方SHA `9165e288b689999b374401c1045a1904102ff279fb534f514d6569fcb608e264`；header为r3222 b35605a/REV_DIFF0 | 安装输入库SHA `e0d737b88c67ac30e8561d9267d10495529cfede1af45838914c0b522c37a26d` 与native/SOURCES及实际runtime-origin相等。既有二进制bottle SHA `b631667b5ad55c6c3ae383484f658c5b4ba14da8a2fbb1d537975695852529ca`，其配方相同 | 本轮从该精确官方commit取得848,719字节源码归档，SHA `6eeb82934e69fd51e043bd8c5b0d152839638d1ce7aa4eea65a3fedcf83ff224`；COPYING/configure/Makefile/x264.h及本机配方摘要已保存。bottle→安装输入→按D脚本重定位的独立副本→3b4候选签后库，9个具有文件字节的具名Mach-O section摘要相等；另2个zero-fill section（__common/__bss）的结构及LINKEDIT不由这9项摘要覆盖。加载标识/签名与整体摘要分别记录。此为静态分段及重定位复演，不是历史构建复现，也未闭合所有LINKEDIT/签名差异的来源。sourceSHA256仍指二进制输入；完整许可判断继续开放 |
| VMAF 3.2.0 | 既有 `run-20261026-appstore-v2/tmp/vmaf-v3.2.0.tar.gz`，18,583,070字节，SHA `a28f93f3b4fa65601be324587072e32a6a704a304ba7b1aec9b70b3f709bc1dc` | code-only输入库SHA `e3de03e30a6b74fa01c1b33dda7a869eea71b879ef5b2e51b336ff4054f350b1` 匹配runtime-origin；构建参数/builtInModels=false见libvmaf-no-models.json | 不能把被替代的Homebrew库当最终输入；其余外部依赖完整源码交付仍分别开放 |
| Audio / MRT2 | Stable Audio固定 `779434a908193105335fd8d833418603625b2859`，13个vendor文件匹配；MRT2 SDK来源 `694a545e4ba0b88bf1150137b129582166d3e07f`，5/5 provider匹配 | vendor/PROVENANCE.json、vendor/SOURCE.json及MRT2_EXPORT_PROVENANCE.md；仅exported small路径，导出图有执行含义 | Audio没有统一runtime-origin；12个可比provider中11相同。另1个未使用旧pitch副本见下文；代码许可不授模型权利 |
| Video / Pitch | Wan来源 `87db56a51758fefb748a359b90a5283bb8ba4837`，8个vendor/4个provider匹配；SwiftF0 0.1.2来源 `8e968fe53b818da318d46e14b84b3d0b41192ad1`，2个provider匹配 | PROVENANCE和prepare脚本/补丁随固定源码；实际音高装配使用独立PitchEngine及包内core，权重路径显式传入 | SwiftF0代码MIT、weightLicense=null，权重取得/权利另核；主App双架构不证明这些arm64入口支持Intel |
| ACE | 固定源码 `ca1e85fe9430179831e6bc6be790c332190a3866`，617/617 vendor、7/7 provider匹配 | runtime-origin/prepare_ace/d_ace_offline_runtime：跳过下载.py，私有视图用包内vendor；local_files_only补丁有登记，权重使用准确原路径 | 开发候选声明保留；反例测试本轮只读沿用，不写成重新运行模型通过 |
| ChatPython/WASI、远程MCP | CPython WASI3.14.8、Wasmtime49.0.2/Pulley64；PROVENANCE的runnerSourceSHA256与固定runner.c相符，runner二进制摘要匹配engine.json。MCP SDK0.12.1/`a0ae212ebf6eab5f754c3129608bc5557637e605` | PROVENANCE/package_runtime.py/runner.c；ChatMCPService与Controller。明确用户Python、只读runtime/inputs、不继承凭据；MCP须准确端点及调用许可，项目加载不连接 | WASI guest线性内存不是RSS上限；继承沙盒不是独立绝对无网络保证。MCP本地取消不保证远端已停。归档重建来源和商店适用仍需分别核定 |

其余六引擎46个定向文件与各自engine.json摘要/长度一致，已查原生入口均arm64；不外推未查文件或本轮实际推理。Audio内 `provider/d_pitch_analysis_backend.py` 的旧副本SHA `46c10713e29400f7c16680cc91d9c94d1127e936ec1a9d8becf36ee004f8e513` 仍从modelDirectory/core.py加载；**正常装配不调用它**（BundledAudioEngine/AppSessionFactory使用独立PitchEngine和bundledCore）。这是随包旧文件/来源一致性缺口，本轮不改后端或删能力，不将其报成当前已执行下载代码。上述许可材料存在不等于分发权利通过；专业许可及D自身许可仍由用户另行决定。

当前中央目录保留18个可下载项、280条文件记录，另有2个仅本地准备包的LTX2.3兼容项/54条固定文件定义；后两项没有下载动作，不新增后端。可下载记录中含模板、固定计算图和 3 个 ACE 检查点 Python 文件。ACE 准备代码在私有运行视图跳过下载的 Python，执行源码取自校验过的包内 vendor。Wan/ACE 相应权重读取使用 weights_only。包内还含 Wasmtime/WASI 的 Python 分析能力和需要显式许可的远程 MCP，应分别向审核说明其执行边界。

本机支付记录与开发者对账分开。五档客户端接线不代表商店商品已创建。平台关于消费型历史的说明、沙盒账户检验、正式商品字段及分发配置分别见 [Apple 消费型历史](https://developer.apple.com/documentation/bundleresources/information-property-list/skincludeconsumableinapppurchasehistory)、[沙盒测试](https://developer.apple.com/help/app-store-connect/test-in-app-purchases/overview-of-testing-in-sandbox/)、[商品信息](https://developer.apple.com/help/app-store-connect/reference/in-app-purchases-and-subscriptions/in-app-purchase-information)、[分发描述文件](https://developer.apple.com/help/account/provisioning-profiles/create-an-app-store-provisioning-profile)。正式隐私材料以实际收集方、目的及保留政策为准。[App 隐私披露](https://developer.apple.com/app-store/app-privacy-details/)

本机最低部署目标 macOS 26.2，开发签名和主程序两架构有本地产物证据。每个引擎/硬件的可承诺范围见[精确模型矩阵](RELEASE_MODEL_MATRIX.zh-CN.md)。

正式商店截图必须来自最终正常候选；现有截图用于本地审阅。新支持同步说明是实现所需最小双语草稿，随实际语言资源交用户/顾问审阅，不扩整批文案。

## 五档打赏：App Store Connect待录入表（2026-11-06用户批准）

下列ID为与客户端一致的拟定ID，**尚未在正式商店创建或读回**。软件本体免费；五档均为Consumable，无权益、余额或订阅；自定义金额本轮暂不实施。未进行后台写入、签协议、真实付款或上传。

| 档位 / 拟定稳定商品ID | 类型 / 参考名称 | USD | EUR | GBP | JPY | CNY |
|---|---|---:|---:|---:|---:|---:|
| 1 / `d.tip.tier1` | Consumable / D Tip Tier 1 | 1 | 1 | 1 | 100 | 5 |
| 2 / `d.tip.tier2` | Consumable / D Tip Tier 2 | 5 | 5 | 5 | 500 | 10 |
| 3 / `d.tip.tier3` | Consumable / D Tip Tier 3 | 10 | 10 | 10 | 1000 | 20 |
| 4 / `d.tip.tier4` | Consumable / D Tip Tier 4 | 50 | 50 | 50 | 5000 | 50 |
| 5 / `d.tip.tier5` | Consumable / D Tip Tier 5 | 100 | 100 | 100 | 10000 | 100 |

五档拟定显示名可复用已批准语言资源的 `tips.title`。App内完整说明 `tips.body` 保持不变，但英文超过App Store Connect商品Description的45字符限制，不能原样录入。2026-11-06本轮批准的商品Description为中文“感谢你支持 D 的开发！软件免费，打赏完全自愿。”（24字符）；对应英文“Thank you! D is free. Tips are voluntary.”（41字符）。均低于45字符；保留感谢、软件免费和自愿三项语义，只准备待录入材料，未创建正式商品或写入后台，不替换App内付款边界说明。显示名30字符、说明45字符的字段限制及实际后台读回均须分别核对。[Apple商品字段要求](https://developer.apple.com/help/app-store-connect/reference/in-app-purchases-and-subscriptions/in-app-purchase-information)

各商品ID不含货币或金额，单次只选一档，经系统确认付款。客户端不会把本表用作显示价格；真实 `Product.displayPrice` 缺失时只显示获取失败。

| 待录入字段 / 页面 | 已准备 | 尚缺/后续最小动作 |
|---|---|---|
| App本体价格 | 免费已决定 | 获准后由有权账户在App定价页配置并读回 |
| In-App Purchases：5个商品 | 上述ID、消费型、参考名、已批准App标题/说明；后台短说明已由用户批准、仅待录入 | 按已批准短说明录入、真实App记录/商品ID与字段可用，创建5个商品并读回；本轮不执行 |
| Price Schedule：基准地区 | 推荐美国/USD五档作为自动定价基准 | 账户持有人确认销售地区；逐档读取精确可用price point，不可用则报具体差异，不取近似值 |
| 手动价格地区 | GBP英国、JPY日本、CNY中国大陆；所有获准EUR及其他USD地区均使用本表数字 | 最终销售地区未定，所有指定币种须按实际获准storefront逐一登记；不能把“EUR”作为单一地区或把语言当地区 |
| 其他获准地区 | USD基准自动定价 | 读取Apple生成价表；指定币种人工价格优先，不自动覆盖 |
| 商品审核/可销售状态 | 可从最终正常候选取得面板截图；无权益说明已有 | 真实主体、账号角色、协议、税务/银行、销售地区、审核图与说明仍须对应步骤，不填虚假资料 |
| 平台验证 | 本地五档配置与正式ID隔离 | 正式商品/地区价格读回、沙盒账户和跨设备仍未验；本地StoreKit与格式夹具不替代 |

Apple允许按基准地区自动生成其他地区价格，也可逐storefront人工覆盖；人工覆盖后的地区需自行维护。精确可用价格点须从授权后台读取。[官方定价说明](https://developer.apple.com/help/app-store-connect/manage-in-app-purchases/set-a-price-for-an-in-app-purchase/) 本地StoreKit配置金额只是测试占位值，虽能按storefront格式显示，但不连接正式price point。[官方本地测试说明](https://developer.apple.com/documentation/xcode/setting-up-storekit-testing-in-xcode)

## 历史R16试用记录（原事实保留，不作当前入口）

### D 节点工作面试用入口（保留的 R16 包）

2026-10-11：当前非 UI 修补仅交本地代码候选与构建证据，未部署替换下列 App。[当前行动](CURRENT_ACTIONS.zh-CN.md)与[非 UI 任务记录](tasks/D-NON-UI-REPAIR-20261011.md)说明版本及未验层级。以下产物/原生结论属于原版本，不视为新候选已验。

2026-10-10 · **UI-PRESENTATION-REBUILD-01 / R16** · 生产 **67b1472efed99bc63c87ced5152de62d75c5ba06**。用户已认可R15实际性能改善，本版继承R14/R15，完成节点连线、卡片与功能归位的实现。

### 当时试用入口

[启动聊天当前验收.command](/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261004T145523Z-continuous-closeout/delivery/启动聊天当前验收.command)

指向 [D UI Review 67b1472e.app](</Volumes/CodexProjects/Codex/D-Development/AgentTrials/UI-PRESENTATION-REBUILD-01/run-20261010-node-workspace/delivery/D UI Review 67b1472e.app>)。普通签名/App Sandbox和7文件摘要已核对；保留隔离试用UUID，入口拒绝双开，不覆盖普通D。启动后用文件→打开项目选择独立 [Node workspace review.dproject](</Volumes/CodexProjects/Codex/D-Development/AgentTrials/UI-PRESENTATION-REBUILD-01/run-20261010-node-workspace/gui/Node workspace review.dproject>)，进入工作流→「双输入文字模板」。旧五份验收项目原样保护。

### 当时新入口

| 位置 | 用途 |
|---|---|
| 顶部 | 切换流程、新建、保存与流程菜单。 |
| 左侧 | 当前对象配置：概览、节点、连线或多选。 |
| 右侧 | 节点、素材、结果；结果可选择实际运行记录。 |
| 底部 | 显式选择运行终点与范围，查看计划后执行；运行中暂停/停止及历史。 |
| 左下 / 右下 | 指针/手型、撤销/重做 / 缩放、显示全部、重置。 |
| 节点卡片 | 身份、状态、端口、折叠和直接删除；省略号/右键保留选择、设为运行目标、运行到这里和仅重跑。 |

主线位于卡片后，端口短引出段属于节点本身；被遮挡的线和端口不应抢操作。运行目标独立于当前检查对象，不会自动选最后一个节点。既有“恢复保存”还会继续执行，因此显示为“恢复保存并继续流程”。

### 当时已验与待验

13项UI值/宿主、13项Controller/执行/保存方法最终分批通过；本地化缺键修复后单独复验。36次节点/临时线更新根、卡片和命中构造仍0，保留局部拖动；这不是FPS。全部测试后普通构建28.48秒，包签名与产物一致。

**本版尚无真实原生图。** CUA读取Finder明确报告Mac已锁定、自动解锁未成功；Agent立即停止相应GUI，未启动候选、未轮询或改变权限。全宿主事件测试另停在key-window前置、零事件，两者各自记录。不能用旧截图、构建或离屏检查替代同版原生验收。

[唯一合并待验清单](FAILURE_AND_PERMISSION_AUDIT.zh-CN.md)列明新布局静态自检、遮挡命中/双向连线、明确目标→非模型执行→保存冷开，以及连续拖动手感的步骤、预期和已验部分。Agent负责尚缺的确定性检查；用户集中观察体验，不逐项催验。详细失败与版本证据见[任务R16](tasks/UI-PRESENTATION-REBUILD-01.md#r16节点工作面分层与入口归位2026-10-10)。旧R15真实截图与性能证据保留在任务记录，不能当成本版图。F26继续延期。

本轮最终a9dc46dd正常候选复核：ExternalVideo同一21项实包字节/长度与fac/aeb/旧3b4相同，来源JSON更新不改变库/工具；资源清单e66db1da…，主执行文件43491706…，正常签名/零权重门禁通过。`run-20261106-model-add-copy/external-video-a9dc46dd-comparison.json`保留准确对应。仅静态分发事实，不是动态加载、模型运行或许可通过。
