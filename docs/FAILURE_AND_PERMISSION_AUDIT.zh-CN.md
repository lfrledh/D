# 失败、权限与唯一集中待办

更新：2026-11-06。B9续验从64cf7c2接续，桌面已切到正常修补包1c2f37ed并冷开核对，临时归因与无效对照已撤回。原 11637899 报告已接收，文件访问与 Speech 的本人步骤已完成。B9 的正常备份反例和修正见任务回执。

本表仍是唯一D-I001–031活动清单。历史原文、失败、旧预算、请求及版本全部见[原始审计归档](history/UI-AUDIT-THROUGH-20261030.md)。未验不等于缺陷，实现不等于原生通过。新请求按[持续授权与受阻报告](MULTI_AGENT_WORKFLOW.zh-CN.md#持续开发验收授权与受阻处理)处理。

## 统一问题清单（App Store v2，2026-10-26）

| ID／问题 | 当前状态 | 剩余动作 | 负责人／依赖 | 需要用户 | 证据 |
|---|---|---|---|---|---|
| <a id="d-i001"></a>D-I001 模型库空闲轮询及同链重复投影 | 已关闭：事件驱动模型库路径 | 保持订阅终结/后台完成/绑定反例；不重做轮询。 | Lead；新回归触发 | 否 | [版本与失败原文](history/UI-AUDIT-THROUGH-20261030.md#d-i001)；[本轮](tasks/D-UI-CONSOLIDATED-01.md) |
| <a id="d-i002"></a>D-I002 已确认的模型错误及状态本地化旁路 | 已关闭：已触发模型状态旁路 | 未审页面文案归I013，不外推全库。 | Lead | 否 | [版本与失败原文](history/UI-AUDIT-THROUGH-20261030.md#d-i002)；[本轮](tasks/D-UI-CONSOLIDATED-01.md) |
| <a id="d-i003"></a>D-I003 输入兼容验证依赖中文显示名称 | 已关闭：执行验证身份 | 保持operation/port身份与改名反例。 | Lead | 否 | [版本与失败原文](history/UI-AUDIT-THROUGH-20261030.md#d-i003)；[本轮](tasks/D-UI-CONSOLIDATED-01.md) |
| <a id="d-i004"></a>D-I004 保存筛选仍依赖旧显示概念 | 已关闭：旧查询兼容 | 新增概念维护稳定ID/旧别名，未知查询不扩大范围。 | Lead | 否 | [版本与失败原文](history/UI-AUDIT-THROUGH-20261030.md#d-i004)；[本轮](tasks/D-UI-CONSOLIDATED-01.md) |
| <a id="d-i005"></a>D-I005 中心对象职责集中 | 保留：可维护性债 | 仅真实缺陷触发局部拆分，不按文件长度大重构。 | Lead | 否 | [版本与失败原文](history/UI-AUDIT-THROUGH-20261030.md#d-i005)；[本轮](tasks/D-UI-CONSOLIDATED-01.md) |
| <a id="d-i006"></a>D-I006 候选源码、资源及包内身份易失配 | 已关闭：本地交付身份范围 | B9 普通包、桌面指向与签名按本轮最终回执复查，Store见I024。 | Lead | 否 | [版本与失败原文](history/UI-AUDIT-THROUGH-20261030.md#d-i006)；[本轮](tasks/D-UI-CONSOLIDATED-01.md) |
| <a id="d-i007"></a>D-I007 原生红绿灯组件与侧栏相碰 | 已关闭：已测窗口几何 | 原生76×32外壳/12pt间距；特殊状态不外推。 | Lead；受影响路径 | 否 | [版本与失败原文](history/UI-AUDIT-THROUGH-20261030.md#d-i007)；[本轮](tasks/D-UI-CONSOLIDATED-01.md) |
| <a id="d-i008"></a>D-I008 子面板内部空白被误判为外点 | 已关闭：内部空白误外点核心反例 | 保留当前host边界/不穿透/草稿门禁；特殊关闭归I011。 | Lead | 否 | [版本与失败原文](history/UI-AUDIT-THROUGH-20261030.md#d-i008)；[本轮](tasks/D-UI-CONSOLIDATED-01.md) |
| <a id="d-i009"></a>D-I009 圆角组件的矩形父层意外露出 | 已测矩形父层修正；余项未验 | 复用Chat父clip和搜索父板实图；补受影响表面，不全局clip。 | Lead | 否 | [版本与失败原文](history/UI-AUDIT-THROUGH-20261030.md#d-i009)；[本轮](tasks/D-UI-CONSOLIDATED-01.md) |
| <a id="d-i010"></a>D-I010 跨模式Undo与真实IME/发送快捷键 | 代表IME/跨模式Undo/发送已验 | 328d真实SCIM拼音、Quick往返后Undo/Redo通过；全输入法与纯Tab未穷举。 | Lead；实际输入环境 | 否 | [版本与失败原文](history/UI-AUDIT-THROUGH-20261030.md#d-i010)；[本轮](tasks/D-UI-CONSOLIDATED-01.md) |
| <a id="d-i011"></a>D-I011 子面板跨边界、系统面板及D外点击 | 三域/嵌套/跨界代表已验；组合未验 | 余下系统面板、层级组合逐实际owner验；保留确认/保存失败。 | Lead | 否 | [版本与失败原文](history/UI-AUDIT-THROUGH-20261030.md#d-i011)；[本轮](tasks/D-UI-CONSOLIDATED-01.md) |
| <a id="d-i012"></a>D-I012 消息图标悬停、辅助功能及键盘可达性 | 编辑焦点与保存保护已验；长代码旁白查找缺陷开放，本组有限诊断结束 | c683真实VO取消/保存后均可VO Space打开准确消息编辑，旧内容保持。真实VO-F定位45行代码历史标题会持续刷新，21d隔离对照同样复现。显式edge方案另有历史区空白，已撤回。8dc/24dda正常Find仍失败，已全部撤回；真实滚轮离开底部后及普通屏外段落查找同样循环。9b实测Find间已插桩聊天scroll调用及转录区出现/消失事件均为0，f02内层ID对照也失败，全部撤净。下一步定位系统自动焦点/布局事务，不将此工程缺陷交给用户排错。1c2已补准确编辑返回、英文、8消息冷读及正常退出重开。 11月6日219新锚点组未取得合格屏外Find（真实键入读回不符、AXSet无跳转证据），不能排除假说。46e撤净探针；旁白已关，不改音量。下一最小判别先确认精确目标跳转与同段焦点/布局，不转用户排错。 | Lead工程项 | 否 | [版本与失败原文](history/UI-AUDIT-THROUGH-20261030.md#d-i012)；[本轮](tasks/D-UI-CONSOLIDATED-01.md) |
| <a id="d-i013"></a>D-I013 UI文案易读性、帮助工程化及其余语言覆盖 | B1—B9沿用；11月6日12项批准文案/关联行为已实现 | 新增12项及五档接线见任务逐项表；61定向组件通过，aff正常App中英标题、预览关闭/真实编辑门禁、导入导出/冷开已分级；补修原始诊断标题漏键。普通App与本地StoreKit分级记录。新增必要tips.partial缺档提示留正式资源供审阅。B9八组及搜索来源沿用。顾问按正式双语资源集中审阅，用户试用后再接纳。 | Lead补验；顾问/用户审阅 | 仅新的措辞决定 | [版本与失败原文](history/UI-AUDIT-THROUGH-20261030.md#d-i013)；[本轮](tasks/D-UI-CONSOLIDATED-01.md) |
| <a id="d-i014"></a>D-I014 已批准UI布局的最终视觉接纳 | 328d V1–V6 中英及冷开实图沿用；B9 V1—V5 分版本核验；视觉接纳待用户 | 按同版图集中反馈，确定缺陷由Lead修；不逐图停工。 | 用户/顾问 | 集中视觉判断 | [版本与失败原文](history/UI-AUDIT-THROUGH-20261030.md#d-i014)；[本轮](tasks/D-UI-CONSOLIDATED-01.md) |
| <a id="d-i015"></a>D-I015 普通App保存失败与恢复的剩余验证 | 普通App受控写失败/仅保存恢复已验 | B9正常App在独立32MiB映像实际ENOSPC，旧聊天文件逐字节保全，de6保存并关闭重试仍失败时保留；释放空间后增加1会话、2消息、0推理。5f步骤前缀/仅保存恢复沿用。物理断电未验。 | Lead；隔离夹具 | 否 | [版本与失败原文](history/UI-AUDIT-THROUGH-20261030.md#d-i015)；[本轮](tasks/D-UI-CONSOLIDATED-01.md) |
| <a id="d-i016"></a>D-I016 真实卷／授权变化及后台完成链 | 后台完成链/同卷重定位代表已验；卷变化余项 | B9专属卷同一路径换目录，D拒写且替代目录为空。恢复原inode后草稿保存成功，正常退出后映像卸载/重挂字节相等。真实用户卷授权撤销及后台模型完成组合仍独立。 | Lead；隔离卷条件 | 仅系统强制批准时 | [版本与失败原文](history/UI-AUDIT-THROUGH-20261030.md#d-i016)；[本轮](tasks/D-UI-CONSOLIDATED-01.md) |
| <a id="d-i017"></a>D-I017 画布／聊天剩余性能与非模型库展示热点 | NODE/PAN用户明显改善、ZOOM多数满意；resize未达标 | 11月6日Binding初值读取局部化组件成立，正常包轮换p95宽差32/18/18pt对16/16/18pt无稳定收益，已撤回。宿主归属3.993秒段layout并集1458.640ms、root赋值6.036ms，隐藏祖先布局523.389ms；未记录区间不归因GPU，下一步需区分隐藏宿主约束传播及外层提交。宿主诊断已移除，1c2终验单段中位12/p9516/末10pt，未据单段宣布收益。 11月6日219同包A/B/A五段：Binding构造可消除，宽差中位均12pt、p95 A16/14/16对B16/16，布局包含sum约1527–1535ms；无稳定收益，46e完整撤回，不再扩大本组。最终呈现/提交关系仍缺证据。 | Lead；有界实测 | 最终手感判断 | [版本与失败原文](history/UI-AUDIT-THROUGH-20261030.md#d-i017)；[本轮](tasks/D-UI-CONSOLIDATED-01.md) |
| <a id="d-i018"></a>D-I018 官方玻璃背景来源和系统菜单视觉证据 | 代表背景对照已验；外部染色暂缓非解决 | 保留用户2026-10-28暂缓决定；菜单/瞬态/分段适配证据不混同。 | Lead；用户重新开启对应范围 | 无新审美门禁 | [版本与失败原文](history/UI-AUDIT-THROUGH-20261030.md#d-i018)；[本轮](tasks/D-UI-CONSOLIDATED-01.md) |
| <a id="d-i019"></a>D-I019 本地Release构建与包依赖预检 | 本地Release预检已验；发行终检保留 | 1c2f37ed正常7引擎/零权重/strict-deep已核，19原生库登记及prepared实际消费者校验通过；16 helper继承，不外推Intel或干净机器。 | Lead | 否 | [版本与失败原文](history/UI-AUDIT-THROUGH-20261030.md#d-i019)；[本轮](tasks/D-UI-CONSOLIDATED-01.md) |
| <a id="d-i020"></a>D-I020 商店型产物的首次使用、升级与恢复 | 具体模型链/冷开已验；全承诺矩阵有缺口 | 3ff ACE automatic拒绝未推理/允许一次同F32/保存冷开已补；本轮正常包查看9B/Q4与ACE/F32实际规格，未运行模型。27B原始BF16的正常GUI、商店型首次安装/升级的同权重授权与恢复仍按矩阵具名保留。 | Lead；就绪模型/环境 | 资源资格确需时 | [版本与失败原文](history/UI-AUDIT-THROUGH-20261030.md#d-i020)；[本轮](tasks/D-UI-CONSOLIDATED-01.md) |
| <a id="d-i021"></a>D-I021 零第三方模型权重随包政策及拆包 | 零权重拆包与门禁实现/本地产物通过 | 最终Store制品再跑；未知疑似阻断，模型许可不由零权重代替。 | Lead | 否 | [版本与失败原文](history/UI-AUDIT-THROUGH-20261030.md#d-i021)；[本轮](tasks/D-UI-CONSOLIDATED-01.md) |
| <a id="d-i022"></a>D-I022 首版功能、硬件及支持承诺 | Mac App Store渠道已定；正式承诺待冻结 | 模型证据/硬件/支持范围分层；不因16GiB机器降格全部承诺。 | 用户/顾问；Lead提供事实 | 需定正式口径 | [版本与失败原文](history/UI-AUDIT-THROUGH-20261030.md#d-i022)；[本轮](tasks/D-UI-CONSOLIDATED-01.md) |
| <a id="d-i023"></a>D-I023 最小资产容器／画布人工筛选 | 容器工程/真实拖放/typed保存已验；余项未验 | 任意opaque、VoiceOver及跨状态组合仍分级；不建新调度器。 | Lead | 否 | [版本与失败原文](history/UI-AUDIT-THROUGH-20261030.md#d-i023)；[本轮](tasks/D-UI-CONSOLIDATED-01.md) |
| <a id="d-i024"></a>D-I024 Mac App Store Archive、签名、验证与安装测试 | 开发签名本地Archive已验；Store链未验 | 适用分发证书/配置、Store导出安装及升级尚缺；不擅自操作账号。 | Lead技术；用户账号/上传授权 | 真实系统/账号步骤 | [版本与失败原文](history/UI-AUDIT-THROUGH-20261030.md#d-i024)；[本轮](tasks/D-UI-CONSOLIDATED-01.md) |
| <a id="d-i025"></a>D-I025 main接纳、版本标签、提审与正式发布 | main/标签/上传/提审/发布未授权 | 本轮仅工作分支/本地候选；分别授权后才推进。 | 用户 | 需要单独授权 | [版本与失败原文](history/UI-AUDIT-THROUGH-20261030.md#d-i025)；[本轮](tasks/D-UI-CONSOLIDATED-01.md) |
| <a id="d-i026"></a>D-I026 商店运行时、沙盒与下载代码边界 | 确定沙盒/加载接线已修；Store适用性开放 | 七引擎固定代码/后取数据、ChatPython/WASI/远程工具按事实说明；不擅删功能。 | Lead核实；用户取舍 | 改变能力时 | [版本与失败原文](history/UI-AUDIT-THROUGH-20261030.md#d-i026)；[本轮](tasks/D-UI-CONSOLIDATED-01.md) |
| <a id="d-i027"></a>D-I027 第三方代码及随包资源分发许可 | 已补确定许可材料；分发权利仍阻塞 | FFmpeg GPL/version3/x264/x265/OpenSSL实际链需完整对应源码/链接与Store方案；不以NOTICE算通过。 | Lead事实核查；用户许可证/依赖取舍 | 具体方案需决策 | [版本与失败原文](history/UI-AUDIT-THROUGH-20261030.md#d-i027)；[本轮](tasks/D-UI-CONSOLIDATED-01.md) |
| <a id="d-i028"></a>D-I028 隐私、网络、凭据与商店声明 | 隐私事实/manifest已有；正式声明未定 | 新增支持记录仅应用内安全保存；平台联网与既有凭据路径如实说明，主体/URL不编造。 | Lead材料；用户公开信息 | 需主体/联络/URL | [版本与失败原文](history/UI-AUDIT-THROUGH-20261030.md#d-i028)；[本轮](tasks/D-UI-CONSOLIDATED-01.md) |
| <a id="d-i029"></a>D-I029 商店材料、审核可复现路径与年龄/内容合规 | 真实复现材料部分已有；正式商店材料未定 | 类别/地区/年龄/加密/公开描述和链接需核实；不上传。 | Lead准备；用户公开口径 | 需有限材料决定 | [版本与失败原文](history/UI-AUDIT-THROUGH-20261030.md#d-i029)；[本轮](tasks/D-UI-CONSOLIDATED-01.md) |
| <a id="d-i030"></a>D-I030 自愿打赏及正式商品配置 | 五档客户端/本地API已验；正式商品与真实账户未验 | 365历史恢复/明确刷新退款通过；328d隔离43900→43965恢复准确unfinished后账本1、队列total0/unverified0、无重购。原同进程失败、自动及raw-only退款0事件保留；正式账户/跨设备未验。11月6日本体免费、五档分币种金额及本轮不做自定义金额已批准；客户端正式ID/localtest隔离已实现；本地StoreKit五币种25价格、五档5购买、pending批准精确交易落盘finish及明确Reload退款通过；pending请求无平台关联ID仍保守保护。普通aff实际显示商品获取失败与平台记录失败，重新加载不付款；Release不接受xcode交易，不用假价格。520pt面板中英真实第五档点击已验（测试宿主、未支付）。正式商品配置、销售地区、服务端账本及其主体/费用/保留删除备份责任仍待对应步骤，0真实收费。 | Lead客户端；用户商品/必要部署 | 正式配置/必要外部服务 | [版本与失败原文](history/UI-AUDIT-THROUGH-20261030.md#d-i030)；[本轮](tasks/D-UI-CONSOLIDATED-01.md) |
| <a id="d-i031"></a>D-I031 是否开源D、自有代码许可证与公开范围 | 开源可考虑；D许可证未选 | 区分自有/Vendor/资源，保留README未授全仓许可；不替用户选许可证。 | 用户；Lead第三方核查 | 需开源范围/许可决定 | [版本与失败原文](history/UI-AUDIT-THROUGH-20261030.md#d-i031)；[本轮](tasks/D-UI-CONSOLIDATED-01.md) |

## 当前必要本人步骤

用户指向桌面后，指定11637899报告已核收并固定哈希，先前缺失请求关闭。正式商品/主体/许可证等原决定保持；旧系统提示/PID不是当前请求。

2026-11-02 本轮必要系统步骤：c7d310cc在专属会话明确点击“授权语音识别…”后，前台成为UserNotificationCenter；未读取未知提示正文。请求针对Speech，不请求麦克风/Metal/全盘访问，尚未录音或转写。已提示一次；需要本人处理系统提示后再核真实授权状态。触发时PID31289/11:02:56 UTC，随后已保存并正常退出，确认PID消失，不能拿该PID续操作。约2秒合成语音文件准备好，真实ASR仍未执行；其他源码/支付/构建继续，不循环触发。

2026-11-03较早的328d检查点：Speech选en-US仍显示“尚未请求授权”，未再次触发；旧请求是否已处理不能从历史弹窗推断。准确剩余是本人批准后核实际状态并完成约2秒专属测试音频转写/采用；不涉及麦克风，不阻塞交付。当前正常实例45707，旧31289已结束。桌面328d冷开无新文件授权提示；未更改TCC/系统策略。

2026-11-03用户确认已允许语音识别。328d实际显示en-US可开始转写，2.052秒专属WAV两次产生本机转写，分别验证不采用与追加。正常退出45707并由桌面冷开50588，草稿、来源和两组原件/转写均保留。该本人步骤已关闭，详见本轮A16/A17。
