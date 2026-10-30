# 失败、权限与唯一集中待办

更新：2026-10-31，串行起点a9978ed6／最终生产3ff94ad4。**当前没有必须本人立即操作的新请求。** 用户已允许D文件访问；8101→3ff正常候选同签名身份，3ff两次冷开未再弹，不能把历史提示归因为每次构建重置权限。

本表仍是唯一D-I001–031活动清单。历史原文、失败、旧预算、请求及版本全部见[原始审计归档](history/UI-AUDIT-THROUGH-20261030.md)。未验不等于缺陷，实现不等于原生通过。新请求按[持续授权与受阻报告](MULTI_AGENT_WORKFLOW.zh-CN.md#持续开发验收授权与受阻处理)处理。

## 统一问题清单（App Store v2，2026-10-26）

| ID／问题 | 当前状态 | 剩余动作 | 负责人／依赖 | 需要用户 | 证据 |
|---|---|---|---|---|---|
| <a id="d-i001"></a>D-I001 模型库空闲轮询及同链重复投影 | 已关闭：事件驱动模型库路径 | 保持订阅终结/后台完成/绑定反例；不重做轮询。 | Lead；新回归触发 | 否 | [版本与失败原文](history/UI-AUDIT-THROUGH-20261030.md#d-i001)；[本轮](tasks/D-UI-CONSOLIDATED-01.md) |
| <a id="d-i002"></a>D-I002 已确认的模型错误及状态本地化旁路 | 已关闭：已触发模型状态旁路 | 未审页面文案归I013，不外推全库。 | Lead | 否 | [版本与失败原文](history/UI-AUDIT-THROUGH-20261030.md#d-i002)；[本轮](tasks/D-UI-CONSOLIDATED-01.md) |
| <a id="d-i003"></a>D-I003 输入兼容验证依赖中文显示名称 | 已关闭：执行验证身份 | 保持operation/port身份与改名反例。 | Lead | 否 | [版本与失败原文](history/UI-AUDIT-THROUGH-20261030.md#d-i003)；[本轮](tasks/D-UI-CONSOLIDATED-01.md) |
| <a id="d-i004"></a>D-I004 保存筛选仍依赖旧显示概念 | 已关闭：旧查询兼容 | 新增概念维护稳定ID/旧别名，未知查询不扩大范围。 | Lead | 否 | [版本与失败原文](history/UI-AUDIT-THROUGH-20261030.md#d-i004)；[本轮](tasks/D-UI-CONSOLIDATED-01.md) |
| <a id="d-i005"></a>D-I005 中心对象职责集中 | 保留：可维护性债 | 仅真实缺陷触发局部拆分，不按文件长度大重构。 | Lead | 否 | [版本与失败原文](history/UI-AUDIT-THROUGH-20261030.md#d-i005)；[本轮](tasks/D-UI-CONSOLIDATED-01.md) |
| <a id="d-i006"></a>D-I006 候选源码、资源及包内身份易失配 | 已关闭：本地交付身份范围 | 3ff普通包/桌面/冷开已核；每次最终包复查，Store见I024。 | Lead | 否 | [版本与失败原文](history/UI-AUDIT-THROUGH-20261030.md#d-i006)；[本轮](tasks/D-UI-CONSOLIDATED-01.md) |
| <a id="d-i007"></a>D-I007 原生红绿灯组件与侧栏相碰 | 已关闭：已测窗口几何 | 原生76×32外壳/12pt间距；特殊状态不外推。 | Lead；受影响路径 | 否 | [版本与失败原文](history/UI-AUDIT-THROUGH-20261030.md#d-i007)；[本轮](tasks/D-UI-CONSOLIDATED-01.md) |
| <a id="d-i008"></a>D-I008 子面板内部空白被误判为外点 | 已关闭：内部空白误外点核心反例 | 保留当前host边界/不穿透/草稿门禁；特殊关闭归I011。 | Lead | 否 | [版本与失败原文](history/UI-AUDIT-THROUGH-20261030.md#d-i008)；[本轮](tasks/D-UI-CONSOLIDATED-01.md) |
| <a id="d-i009"></a>D-I009 圆角组件的矩形父层意外露出 | 已测矩形父层修正；余项未验 | 复用Chat父clip和搜索父板实图；补受影响表面，不全局clip。 | Lead | 否 | [版本与失败原文](history/UI-AUDIT-THROUGH-20261030.md#d-i009)；[本轮](tasks/D-UI-CONSOLIDATED-01.md) |
| <a id="d-i010"></a>D-I010 跨模式Undo与真实IME/发送快捷键 | 代表IME/跨模式Undo/发送已验 | 5f真实SCIM及跨模式Undo保持；全输入法与纯Tab未穷举。 | Lead；实际输入环境 | 否 | [版本与失败原文](history/UI-AUDIT-THROUGH-20261030.md#d-i010)；[本轮](tasks/D-UI-CONSOLIDATED-01.md) |
| <a id="d-i011"></a>D-I011 子面板跨边界、系统面板及D外点击 | 三域/嵌套/跨界代表已验；组合未验 | 余下系统面板、层级组合逐实际owner验；保留确认/保存失败。 | Lead | 否 | [版本与失败原文](history/UI-AUDIT-THROUGH-20261030.md#d-i011)；[本轮](tasks/D-UI-CONSOLIDATED-01.md) |
| <a id="d-i012"></a>D-I012 消息图标悬停、辅助功能及键盘可达性 | 消息实际操作/AX已验；tooltip/VoiceOver余项 | 补真实悬停泡、完整播报与键盘入口；不以AX文本替代声音。 | Lead；可用辅助功能环境 | 否 | [版本与失败原文](history/UI-AUDIT-THROUGH-20261030.md#d-i012)；[本轮](tasks/D-UI-CONSOLIDATED-01.md) |
| <a id="d-i013"></a>D-I013 UI文案易读性、帮助工程化及其余语言覆盖 | 已批准批次已实施；余文案待审 | 语言文件唯一正文，覆盖见接线索引；02已由B2最终实现。 | 顾问/用户定新文案；Lead接线 | 新措辞需确认 | [版本与失败原文](history/UI-AUDIT-THROUGH-20261030.md#d-i013)；[本轮](tasks/D-UI-CONSOLIDATED-01.md) |
| <a id="d-i014"></a>D-I014 已批准UI布局的最终视觉接纳 | 最终3ff CS-V01–06已展示；视觉接纳待用户 | 按同版图集中反馈，确定缺陷由Lead修；不逐图停工。 | 用户/顾问 | 集中视觉判断 | [版本与失败原文](history/UI-AUDIT-THROUGH-20261030.md#d-i014)；[本轮](tasks/D-UI-CONSOLIDATED-01.md) |
| <a id="d-i015"></a>D-I015 普通App保存失败与恢复的剩余验证 | 普通App受控写失败/仅保存恢复已验 | 5f准确步骤前缀/不重推理，ff83/8101冷读；介质满/拔盘未验。 | Lead；隔离夹具 | 否 | [版本与失败原文](history/UI-AUDIT-THROUGH-20261030.md#d-i015)；[本轮](tasks/D-UI-CONSOLIDATED-01.md) |
| <a id="d-i016"></a>D-I016 真实卷／授权变化及后台完成链 | 后台完成链/同卷重定位代表已验；卷变化余项 | 保留文件身份和准入；不撤真实用户权限造故障。 | Lead；隔离卷条件 | 仅系统强制批准时 | [版本与失败原文](history/UI-AUDIT-THROUGH-20261030.md#d-i016)；[本轮](tasks/D-UI-CONSOLIDATED-01.md) |
| <a id="d-i017"></a>D-I017 画布／聊天剩余性能与非模型库展示热点 | NODE/PAN用户明显改善、ZOOM多数满意；resize未达标 | 6c/ff83匹配连续横向无稳定收益；下一最小是resize接收→布局/提交时序，旧预算不重置。 | Lead；有界实测 | 最终手感判断 | [版本与失败原文](history/UI-AUDIT-THROUGH-20261030.md#d-i017)；[本轮](tasks/D-UI-CONSOLIDATED-01.md) |
| <a id="d-i018"></a>D-I018 官方玻璃背景来源和系统菜单视觉证据 | 代表背景对照已验；外部染色暂缓非解决 | 保留用户2026-10-28暂缓决定；菜单/瞬态/分段适配证据不混同。 | Lead；用户重新开启对应范围 | 无新审美门禁 | [版本与失败原文](history/UI-AUDIT-THROUGH-20261030.md#d-i018)；[本轮](tasks/D-UI-CONSOLIDATED-01.md) |
| <a id="d-i019"></a>D-I019 本地Release构建与包依赖预检 | 本地Release预检已验；发行终检保留 | 3ff正常7引擎/零权重/strict-deep/16 helper继承；不外推Intel或干净机器。 | Lead | 否 | [版本与失败原文](history/UI-AUDIT-THROUGH-20261030.md#d-i019)；[本轮](tasks/D-UI-CONSOLIDATED-01.md) |
| <a id="d-i020"></a>D-I020 商店型产物的首次使用、升级与恢复 | 具体模型链/冷开已验；全承诺矩阵有缺口 | 3ff ACE automatic拒绝未推理/允许一次同F32/保存冷开已补；其余准确变体/能力缺口按矩阵保留，不推广全模型。 | Lead；就绪模型/环境 | 资源资格确需时 | [版本与失败原文](history/UI-AUDIT-THROUGH-20261030.md#d-i020)；[本轮](tasks/D-UI-CONSOLIDATED-01.md) |
| <a id="d-i021"></a>D-I021 零第三方模型权重随包政策及拆包 | 零权重拆包与门禁实现/本地产物通过 | 最终Store制品再跑；未知疑似阻断，模型许可不由零权重代替。 | Lead | 否 | [版本与失败原文](history/UI-AUDIT-THROUGH-20261030.md#d-i021)；[本轮](tasks/D-UI-CONSOLIDATED-01.md) |
| <a id="d-i022"></a>D-I022 首版功能、硬件及支持承诺 | Mac App Store渠道已定；正式承诺待冻结 | 模型证据/硬件/支持范围分层；不因16GiB机器降格全部承诺。 | 用户/顾问；Lead提供事实 | 需定正式口径 | [版本与失败原文](history/UI-AUDIT-THROUGH-20261030.md#d-i022)；[本轮](tasks/D-UI-CONSOLIDATED-01.md) |
| <a id="d-i023"></a>D-I023 最小资产容器／画布人工筛选 | 容器工程/真实拖放/typed保存已验；余项未验 | 任意opaque、VoiceOver及跨状态组合仍分级；不建新调度器。 | Lead | 否 | [版本与失败原文](history/UI-AUDIT-THROUGH-20261030.md#d-i023)；[本轮](tasks/D-UI-CONSOLIDATED-01.md) |
| <a id="d-i024"></a>D-I024 Mac App Store Archive、签名、验证与安装测试 | 开发签名本地Archive已验；Store链未验 | 适用分发证书/配置、Store导出安装及升级尚缺；不擅自操作账号。 | Lead技术；用户账号/上传授权 | 真实系统/账号步骤 | [版本与失败原文](history/UI-AUDIT-THROUGH-20261030.md#d-i024)；[本轮](tasks/D-UI-CONSOLIDATED-01.md) |
| <a id="d-i025"></a>D-I025 main接纳、版本标签、提审与正式发布 | main/标签/上传/提审/发布未授权 | 本轮仅工作分支/本地候选；分别授权后才推进。 | 用户 | 需要单独授权 | [版本与失败原文](history/UI-AUDIT-THROUGH-20261030.md#d-i025)；[本轮](tasks/D-UI-CONSOLIDATED-01.md) |
| <a id="d-i026"></a>D-I026 商店运行时、沙盒与下载代码边界 | 确定沙盒/加载接线已修；Store适用性开放 | 七引擎固定代码/后取数据、ChatPython/WASI/远程工具按事实说明；不擅删功能。 | Lead核实；用户取舍 | 改变能力时 | [版本与失败原文](history/UI-AUDIT-THROUGH-20261030.md#d-i026)；[本轮](tasks/D-UI-CONSOLIDATED-01.md) |
| <a id="d-i027"></a>D-I027 第三方代码及随包资源分发许可 | 已补确定许可材料；分发权利仍阻塞 | FFmpeg GPL/version3/x264/x265/OpenSSL实际链需完整对应源码/链接与Store方案；不以NOTICE算通过。 | Lead事实核查；用户许可证/依赖取舍 | 具体方案需决策 | [版本与失败原文](history/UI-AUDIT-THROUGH-20261030.md#d-i027)；[本轮](tasks/D-UI-CONSOLIDATED-01.md) |
| <a id="d-i028"></a>D-I028 隐私、网络、凭据与商店声明 | 隐私事实/manifest已有；正式声明未定 | 新增支持记录仅应用内安全保存；平台联网与既有凭据路径如实说明，主体/URL不编造。 | Lead材料；用户公开信息 | 需主体/联络/URL | [版本与失败原文](history/UI-AUDIT-THROUGH-20261030.md#d-i028)；[本轮](tasks/D-UI-CONSOLIDATED-01.md) |
| <a id="d-i029"></a>D-I029 商店材料、审核可复现路径与年龄/内容合规 | 真实复现材料部分已有；正式商店材料未定 | 类别/地区/年龄/加密/公开描述和链接需核实；不上传。 | Lead准备；用户公开口径 | 需有限材料决定 | [版本与失败原文](history/UI-AUDIT-THROUGH-20261030.md#d-i029)；[本轮](tasks/D-UI-CONSOLIDATED-01.md) |
| <a id="d-i030"></a>D-I030 自愿打赏及正式商品配置 | 支持历史客户端已实现；Xcode购买/历史恢复/显式退款恢复已验 | 15组件及3ff两平台方法通过；自动退款updates、真实账号/跨设备仍未验，旧失败保留。正式商品/金额及必要外部服务未定，0真实收费。 | Lead客户端；用户商品/必要部署 | 正式配置/必要外部服务 | [版本与失败原文](history/UI-AUDIT-THROUGH-20261030.md#d-i030)；[本轮](tasks/D-UI-CONSOLIDATED-01.md) |
| <a id="d-i031"></a>D-I031 是否开源D、自有代码许可证与公开范围 | 开源可考虑；D许可证未选 | 区分自有/Vendor/资源，保留README未授全仓许可；不替用户选许可证。 | 用户；Lead第三方核查 | 需开源范围/许可决定 | [版本与失败原文](history/UI-AUDIT-THROUGH-20261030.md#d-i031)；[本轮](tasks/D-UI-CONSOLIDATED-01.md) |

## 当前必要本人步骤

无。正式商品／商店主体／许可证等具体决定由A4准备最少选项后集中提出，不让待决阻塞独立工程。旧系统提示／已退出PID不是当前请求。
