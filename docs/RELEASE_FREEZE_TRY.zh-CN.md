# 本地候选与发行复现材料

2026-11-04 · COPY-B9-RELEASE-CLOSEOUT-20261104-r1。唯一实际版本和启动入口见[当前行动](CURRENT_ACTIONS.zh-CN.md)，不是下方历史R16包。当前仅Apple Development签名的完整沙盒Release；不是Mac App Store分发、提审或发行通过。

## 当前可复现路径与证据等级

1. 使用桌面“D 最新版”，核对包内源码及交付回执。正式App不含第三方模型权重；本地资源来自用户明确选择的下载或原文件/副本路径。新用户选择目录时由系统授权，不预授全盘权限。
2. 无模型时仍可打开项目/查看已有资产；选择真实目录条目后取得/校验/登记与执行就绪分开显示。审核者需要自有可用资源及相应第三方资格，不能用固定回复冒充推理。
3. 用独立项目验证Quick/工作流、输入/Undo、保存冷开。Qwen9B Q4停止前缀与准确步骤保存失败→只保存恢复已有正常App证据；沿用版本见任务归档，不外推全部模型/配置。
4. 低内存方式保持同一准确权重，默认询问；拒绝不推理，同意一次不改默认，已记住选择可撤销。不同模型原始精度/变体的实模证据分别见矩阵。
5. 帮助“支持开发者…”及设置“打赏支持”共用面板。普通Release无正式商品，不能付款；本地Xcode配置只作测试，不是商店账户/跨设备验收。
6. 干净配置/独立容器不等于另一台干净Mac；Intel、Store签名安装/升级、正式账号及系统强制批准仍按D-I024记录，不清用户模型/权限制造首次使用。

## 支持记录的数据流与隐私事实

本轮客户端已实施并有15组件/2本地Xcode方法验证的方案（正式账户/跨设备仍未验）：StoreKit验证结果→应用/环境/交易去重→逐笔时间、实际Decimal金额及币种、应用范围匿名账户、退款/撤销→应用私有账本；原签名凭据进本机、不云同步的Keychain。创作项目、公开日志和截图不含这些记录。未知金额/身份保留未知，不用商品现价或名称倒推；不跨币种加总，也无积分/余额/会员权益。

配置了商品时，启动/面板打开/返回应用有限读取`AppTransaction.shared`与`Transaction.all`；不轮询、不自动`refresh`/`AppStore.sync`触发账户认证。每次重新核对先撤销可展示账户范围，旧本地文件不能自行认领给新账户；离线失败保留原记录。已验证历史恢复不再次购买或发放权益。新购买在凭据和账本落盘后finish；失败只恢复同一交易。历史同步状态与支付状态独立。

启用了Apple公开消费型历史键；Apple特别提醒消费型重复交付应有服务器对账。D目前不因打赏发放内容/额度/功能，历史恢复只合并记录。客户端回放测试和Xcode本地历史不是正式同账户跨设备证明，也不是开发者集中支持者名册。

**最小推荐**：当前不部署外部服务，先完成正式沙盒账户下的同账户恢复验证。若未来必须由开发者集中识别/兑现回馈，再明确批准一个最小收据验证与记录服务：Apple签名校验、应用/环境/交易幂等、退款更新、加密数据库、保留/删除策略与单独认证；匿名appTransactionID及收据本身不能充当登录凭据。不先搭账号平台。托管地区、费用、域名、身份验证与隐私披露需该阶段明确，当前未采购/部署。

## 发行决定 D1—D5（2026-11-04 核对）

| 决定及负责人 | 推荐和验证方法 | 备选、能力及成本/数据影响 | 未决定阻塞 |
|---|---|---|---|
| D1 · 依赖分发、D 自有代码的许可与公开范围，由用户与许可顾问决定 | 优先保留当前编码与推理能力。按实际二进制补足可获取的完整对应源码、构建/修改说明，逐组件核对再分发及商店条件。评审演示下载数据如何由固定包内代码使用。 | 经批准替换特定编码器或取得相应第三方权利，需要重新验证格式、画质和跨机支持，可能产生许可成本。D 自有代码是否公开单独决定。 | 商店分发许可和运行方式核准（I026/027/031） |
| D2 · 支持记录的正式保证，由用户决定，Lead 验证平台 | 先验证同一沙盒账户在两台 Mac 的购买、恢复、退款及切换账户，按已验证范围展示记录。保留本地跨进程恢复证据与自动退款零通知记录。 | 如承诺开发者侧对账，需另批最小签名验证/幂等账本，选择地区、负责人、预算、保留期限、删除与备份责任。仅传必要交易/环境/退款字段，另做身份验证。 | 跨设备或开发者侧保证及正式 IAP（I028/030） |
| D3 · App 售价及可选打赏商品，由用户定金额和地区 | 两项分开选择。打赏推荐先一档消耗型，文案“支持早期开发 / Support early development”，价格取 StoreKit。需要正式稳定商品 ID、参考名、类型、本地化、基础地区及价格档、销售地区、审核截图和说明。 | 多档增加本地化、定价及退款验证成本。现有本地 SKU 与生产隔离。创作功能独立于交易。 | 正式核价、商品配置及购买审核（I030） |
| D4 · 公开主体与支持承诺，由用户/顾问确认 | 按准确模型/精度和已测硬件填写能力，将尚缺的演示列入验证。提供真实支持与隐私 URL、联系主体、地区、年龄/内容及出口加密信息。审核路径采用可合法使用的合成输入、导入、保存、冷开，有权使用的准确模型再验证生成。 | 扩大支持硬件/地区需要相应设备、资源和支持成本。隐私材料分别描述本机项目、Speech、搜索词/所访网页、MCP 许可服务、模型下载和 StoreKit，外部账本会改变申报与维护。 | 公开材料、隐私披露及正式审核范围（I022/028/029） |
| D5 · 正式发行操作，由账户持有人授权 | 用显式正式 App ID、匹配的 Mac App Store 配置与分发签名验证 Archive、安装、升级、恢复。每一步分别记录对应制品与结果。 | 可由有资格的账户管理员配置证书/描述文件或使用获准自动签名。需要相应账号角色、测试设备和审核时间。 | main 接纳、标签、上传、提审、发布各需独立授权（I024/025） |

实包包含 7 个引擎。ExternalVideo 内的 FFmpeg/ffprobe 9.0.1 采用 shared、GPL、version3、x264、x265、OpenSSL 配方。19 个原生库中，FFmpeg 自有库为 avcodec、avdevice、avfilter、avformat、avutil、swresample、swscale，另外包括 SvtAv1Enc、dav1d、mp3lame、mpg123、opus、vmaf、x264、x265、lzma、crypto、ssl。来源、配方、许可文本和签后摘要已登记。完整对应源码与商店分发取舍仍属 D1。[上游许可](https://ffmpeg.org/legal.html) · [Apple 审核 2.4.5 / 2.5.2](https://developer.apple.com/app-store/review/guidelines/)

模型目录的 18 项、280 条文件记录中含模板、固定计算图和 3 个 ACE 检查点 Python 文件。ACE 准备代码在私有运行视图跳过下载的 Python，执行源码取自校验过的包内 vendor。Wan/ACE 相应权重读取使用 weights_only。包内还含 Wasmtime/WASI 的 Python 分析能力和需要显式许可的远程 MCP，应分别向审核说明其执行边界。

本机支付记录与开发者对账分开。普通候选的商品名单为空。平台关于消费型历史的说明、沙盒账户检验、正式商品字段及分发配置分别见 [Apple 消费型历史](https://developer.apple.com/documentation/bundleresources/information-property-list/skincludeconsumableinapppurchasehistory)、[沙盒测试](https://developer.apple.com/help/app-store-connect/test-in-app-purchases/overview-of-testing-in-sandbox/)、[商品信息](https://developer.apple.com/help/app-store-connect/reference/in-app-purchases-and-subscriptions/in-app-purchase-information)、[分发描述文件](https://developer.apple.com/help/account/provisioning-profiles/create-an-app-store-provisioning-profile)。正式隐私材料以实际收集方、目的及保留政策为准。[App 隐私披露](https://developer.apple.com/app-store/app-privacy-details/)

本机最低部署目标 macOS 26.2，开发签名和主程序两架构有本地产物证据。每个引擎/硬件的可承诺范围见[精确模型矩阵](RELEASE_MODEL_MATRIX.zh-CN.md)。

正式商店截图必须来自最终正常候选；现有截图用于本地审阅。新支持同步说明是实现所需最小双语草稿，随实际语言资源交用户/顾问审阅，不扩整批文案。

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
