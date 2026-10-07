# D：文字聊天完整功能冻结清单

版本：v2.0 · 2026-10-03（Asia/Tokyo）；2026-10-04原位补充F26/F31与功能完成后的质量审计决议，不重编号、不重置预算。

## 用法与范围

这是一份用户讨论的实施需求快照，不是实现完成报告。F01–F36 是**能力组**，包含旧能力的完善和新能力，不是36个新模型/节点。与 `D_Chat_Productization_Agent_Task_v2.0.md` 配套。

本轮明确把此前在最小聊天中延期的联网、资料检索、可控记忆、自动辅助、答案比较、语音、受限代码执行、MCP和成果预览纳入。范围按下表的具体边界执行，不延伸为整台电脑自动化、通用插件商城、所有模型训练或跨平台平台工程。

“需求清零”指不再需要重新猜测本轮要做哪些功能；**不表示已经实现、允许删掉未完条目或只做禁用按钮。** 已有功能先核对复用，未完成者保留同一编号。依赖账号、系统资源或安全机制而暂未实测时，记录准确阻塞，不能改成“已完成的可选项”。

使用状态：未核对 / 已实现待验 / 已验通过 / 明确阻塞 / 当前不适用（仅具体模型或设备，不取消整项）。执行时只在项目一个权威位置维护：状态、实际入口、实现提交、关键证据/反例、剩余事项。不得在所有回执复制36行。

## 能力与验收

| ID | 能力组 | 本轮范围 | 最小完成/保护边界 | 首次落地切片 |
|---|---|---|---|---|
| F01 | **四模态与共享底座** | Quick常驻文字/图像/视频/音频；文字为聊天，保留单次兼容入口；Canvas不拆模态。 | 分类仅导航与筛选；VLM仍可读图/视频，视频音轨不丢；切页不自动生成、加载或取消，模型实名与安装共享。 | S01 |
| F02 | **成熟聊天布局** | 会话侧栏、简洁顶栏、居中消息、固定底部输入、按需右侧检查器；长短窗口均可用。 | 功能不能全部堆成消息按钮；空态、生成、失败、分支、附件、窄窗均有真实状态画面；焦点/AX可达。 | S01 |
| F03 | **会话生命周期** | 新建、切换、手动命名、置顶、归档/取消归档、删除及可恢复处理，项目关联。 | 切会话不串运行；删除不顺带删除被其他项目使用的素材；不强迫先创建命名项目。 | S01 |
| F04 | **历史检索与整理** | 搜索会话标题和内容、会话内查找与跳转、收藏消息、预制/自定义标签。 | 检索区分关键词/语义；不为搜索默认常驻服务；标签复用现有系统，跳到具体消息，不只打开会话。 | S02 |
| F05 | **会话草稿与多轮** | 每会话的未发草稿、附件、滚动位置和模型选择；完整有序多轮记录。 | 保存历史/当前路径/本次上下文分离；切页、保存和状态更新不清marked text，不强迫恢复旧焦点。 | S01 |
| F06 | **编辑与分支** | 修改旧用户消息、回答候选切换、从任意合适位置创建新会话。 | 旧路径保留；新路径不混入旧后续；分支标签用可读摘要，不用UUID作主要名称；不用可视化消息图代替正常聊天。 | S01 |
| F07 | **再生成与重现** | 再生成一个候选；明确按旧参数/旧seed重新运行。 | 两种行为分开；新候选的实际seed须记录，不只换attempt UUID；不承诺跨实现逐字节复现。 | S00 |
| F08 | **人工修订与续写** | 修改助手文本、选用人工修订继续讨论；支持显式采用已停止/长度截断的部分文本继续。 | 原始模型输出不覆盖，人工版本标记清楚；assistant prefill按后端支持适配；新调用续写不冒充推理检查点恢复。 | S02 |
| F09 | **答案比较** | 同模型多次、不同已安装模型或不同配置对同一固定问题比较，选一份继续或明确综合。 | UI并排不强求模型并行驻留；按已有队列串行也可；比较使用同一输入范围，各自配置与seed可查。 | S02 |
| F10 | **系统提示词自由** | 查看、编辑、完整替换、清空D默认系统提示词；本会话设置和全局新会话默认分开。 | 默认规则非隐藏强制内容；修改只作用后续调用；在途请求固定；用户清空后不暗中重新附加默认助手指令。 | S02 |
| F11 | **预设与短任务模板** | 系统/参数预设新建、复制、更新、恢复、导入导出；选段解释/翻译/改写等可编辑提示模板。 | 预设与基础模型身份分离；更新原预设不悄改历史会话；短任务由现有模型完成，不新增一排专用后端。 | S02 |
| F12 | **模型聊天模板** | 高级入口查看/覆盖选定模型的chat template，预览实际拼接并恢复默认。 | 与系统提示词分开；使用成熟模板处理；无任意宿主代码执行；角色/工具/特殊token不因编辑静默丢失；错误模板可撤回。 | S02 |
| F13 | **参数、思考与输出格式** | 暴露模型实际支持的采样、seed、上下文/输出长度、加载方式、思考选项；自动/纯文本/Markdown/JSON或schema。 | 不是所有模型复制同一套滑杆；未完成数值输入保留；软格式提示、结构约束、结果校验分开；不把校验JSON冒称受约束解码。 | S02 |
| F14 | **本次实际请求** | 可读分组检查本次规则、选中路径、固定资料、摘要、媒体处理、工具、参数及来源。 | 显示执行快照而非事后当前设置；高级原始视图可导出脱敏记录；凭据、系统秘密不进入请求/日志；预算估计与真实token分开。 | S02 |
| F15 | **长流、停止与恢复显示** | 无损接收长回答、平滑刷新、停止/停止中/已停止、切会话继续收取、失败保留部分回答。 | 修consumerTooSlow根因；显示慢不使正常生成丢字；终态/错误不丢；释放后才复用重资源；重开中断准确标记，不自动重复生成。 | S00 |
| F16 | **输出通道** | 思考、工具状态、正文、引用/结构化结果区分，按需折叠，结束原因准确。 | 只展示模型真实输出的reasoning，不编造内部思考；工具执行来自真实任务不是正文猜测；用户隐藏思考不等于关闭推理。 | S01 |
| F17 | **富文本与复制** | Markdown、公式、代码高亮/复制、表格、引用、链接；原文/排版切换；可读文本/Markdown/代码/表格复制。 | 复用当前渲染器并实测；原文不为容错改写；流式可先文本后分块富排版，但不能整段结束前无反馈；点击链接可受控打开，远程资源不自动联网。 | S01 |
| F18 | **引用选段提问** | 选中消息/资料的一部分直接引用追问、解释、翻译或改写。 | 保留具体来源和范围；不静默替换原内容；光标/选区/引用在会话切换后归属准确。 | S02 |
| F19 | **统一拖入和附件** | Finder、粘贴、本项目/跨项目已授权资料库、工作流成果统一进入已有导入边界；待发送预览、排序、移除。 | 聊天和其他当前需要素材的Quick/Canvas输入采用公共拖入规则；混合文件逐项反馈；跨项目引用/复制使用既有API；不自动执行、不丢可选控制。 | S01 |
| F20 | **文档与媒体读取** | TXT/MD/代码/CSV、PDF、DOCX等明确格式的真实提取，PNG/JPEG与受支持MP4；扫描文档可显式选择本地OCR。 | 格式探测与失败说明，不以文件名冒称已读；保留页/行/时间定位；图片和文本提取区分；OCR按需不默认全页反复跑；其他格式列未支持而非假通过。 | S03 |
| F21 | **个人/项目资料库与RAG** | 用户授权目录/集合导入、增量索引、选择资料范围、检索片段、引用回原文、材料变更/失联提示。 | 复用资料/版本/位置系统；首先可用成熟本地词法检索和现有模型重排，无须为RAG新增生成模型家族；没有embedding就不称向量语义检索；索引可重建，原资料不篡改。 | S03 |
| F22 | **可控上下文** | 选择本轮采用哪些历史/资料、消息保留但不发送、固定要求/术语/项目决定、可读预算。 | 排除/回纳不删历史；工具call/result依赖合法；不静默丢旧内容；固定要求显式来源；历史回答的配置不随当前变化。 | S02 |
| F23 | **摘要与压缩** | 手动整理上下文，及用户开启后的阈值触发摘要；查看、编辑、撤销并重新构造上下文。 | 摘要是有来源的派生版本；编辑上游或换分支使旧摘要失效；原文保留；不为每条回复自动总结，计算占用走现有调度。 | S03 |
| F24 | **可控长期记忆** | 独立的个人/项目记忆范围，手动增删改；可选自动提取建议并审核采用，也可在用户明确开启后自动记录有来源条目。 | 默认不将所有聊天写成永久记忆；会话可关闭；临时会话不读写长期记忆；忘记后不从未更新索引或摘要再次自动注入；与历史检索分开。 | S03 |
| F25 | **自动辅助任务** | 轻量临时标题＋可选模型自动命名；可选自动标签、建议追问。 | 各自开关/预算/来源可见，用户改名不再覆盖；复用已驻留/选定模型，低优先级排队；不因点击侧栏重做后台推理。 | S03 |
| F26 | **联网搜索与网页阅读** | 成熟通用搜索API首批仅Brave Search与博查Web Search，先贯通一条再补另一适配器；同一App手动选择服务、用户自配凭据。保留会话/本轮联网开关、手动搜索及显式开启的自动搜索；接口返回来源数据，最终回答由本地模型生成。 | 不抓搜索结果页，不以百科代替通用搜索，不接已退役Bing或不接新客的Google旧接口；不拆地区版、不按IP静默换服务、不内置统一收费密钥。查询可查、摘要/已读正文分开、引用有实际来源；保留网页读取、取消和错误处理，不上传整会话/附件。价格/保存条件/接口核对及真实成功、大陆可达性边界见下节。 | S04 |
| F27 | **确定性工具与表格分析** | 计算器、单位/时间换算、选定CSV表格分析；统一工具调用活动、参数、结果、失败和取消展示。 | 工具输出经真实执行；解析规则不靠eval任意代码；同一工具注册与权限边界复用；副作用有明确确认/去重/未知结果处理。 | S04 |
| F28 | **受限代码执行** | 一条本地、隔离、可取消的Python数据分析闭环；选定输入副本→执行→stdout/图表/生成文件→显式保存。 | 不做任意终端/多语言IDE；优先成熟隔离运行时；仅工作目录或Process本身不算沙盒；网络/主机FS/凭据默认不可达，资源上限与中止实测；安全未证实就标未完成，不自动降为宿主裸执行。 | S05 |
| F29 | **MCP连接** | 基于官方SDK的一条实际客户端传输（优先Streamable HTTP）；配置、连接、列工具、调用、取消和断开，成功用一个测试服务贯通。 | 不建MCP服务器商城/全协议平台；不自写JSON-RPC；服务器声明/roots不等于OS隔离；未经授权不启动任意本地命令，不允许服务器采样/外部修改自动越权。 | S05 |
| F30 | **独立成果预览** | 可保存编辑的文稿/代码/表格，以及HTML/SVG/Mermaid等本地成果面板；明确启用的独立HTML/JS交互预览。 | 聊天历史与可编辑成果分开；当前Markdown渲染继续保留；Web内容不获宿主桥接/文件/网络权限，外部CDN关闭；不建设任意React/npm开发环境，不能只有不执行的代码块就称交互完成。 | S05 |
| F31 | **语音输入和朗读** | 识别本轮仅普通话与英语，手动选择语言，复用现有系统本地实现；录音/已有音频→转写→审核→显式采用到草稿。系统或既有本地TTS朗读/暂停/继续/停止、声音/速度选择沿用原范围。 | 不自动发送、不悄悄转云；保留取消、释放和原录音。逐语言核本地能力，权限/资源确需本人时进入唯一集中待办，其他工作继续。不增加自动语种、方言、混说专项、说话人识别或常驻语音模型；不限制文字模型语言。至少一条真实本地输入输出闭环，普通话/英语的已验状态分别记录。 | S05 |
| F32 | **临时会话与删除** | 显式临时会话、留存范围说明、结束清理本次拥有的材料；常规会话删除/恢复策略。 | 不进长期历史/检索/记忆/常规备份，除非用户显式保存成果；必要临时落盘与外部工具留存如实说明；不得宣称零磁盘痕迹，禁止删共享原件或备份的用户副本。 | S03 |
| F33 | **完整导入导出与备份** | 阅读用TXT/Markdown/本地HTML；D可恢复会话包保留消息树/配置/附件/来源；至少一种明确版本的常见外部聊天格式导入。 | 外部导入先预览映射和信息损失，不覆盖原对话、不执行代码/工具；备份恢复涵盖新增记忆/资料绑定和成果，索引可重建，凭据默认不导出；无需云分享平台。 | S03 |
| F34 | **与工作流互通** | 保存回答/选段/结构化字段为版本化成果，交给明确节点/已封装工具；画布结果可带回讨论。 | 不把所有聊天编译成图；显式采用后才影响流程；继续聊不修改在途输入；自定义工具只执行已授权内容，跨项目关系不串。 | S02 |
| F35 | **键盘、外观与可访问性** | 中英文完整文本，主题/字号/行宽/代码换行、发送快捷键、Tab/VoiceOver、空态与错误态、窄窗和高对比。 | 不靠微小字体/全图标/只有hover才发现动作；Enter组字优先，Esc不吞候选；菜单和浮层串行，打开面板不重复提交；不把本轮变成iPad适配。 | S01 |
| F36 | **状态、任务与可观测性** | 排队/加载/准备上下文/思考/正文/工具/保存/完成/长度截断/停止/失败分开；可选耗时token和加载方式；可配置结束提示。 | 宏信任和准备状态不是模型生成状态；重试保存不重推理；可查看/取消正在运行的本会话任务；不新增定时任务平台/自动电脑操作。 | S00 |

## F26接口与条件核对（2026-10-04，后续实现依据）

只核公开一手接口/价格/保存条件一次，不接收费账户、不发送项目或会话资料。本次属于需求与资料更新，当前优先级仍是菜单/交互迟滞与输入区停止。先让一条来源接口→必要网页正文→本地模型回答的真实链路通过，再补第二适配器；两条均在同一F26范围，失败不得静默切服务。复用现有Runtime、工具活动、资产/Store和授权边界，不增加浏览器自动化或计费平台。

| 服务 | 官方接口与价格快照 | 结果保存条件与证据边界 |
|---|---|---|
| Brave Search | [Web Search API](https://api-dashboard.search.brave.com/api-reference/web/search/get)：`GET https://api.search.brave.com/res/v1/web/search`，`X-Subscription-Token`，返回URL/标题/摘要等来源数据；使用Search，不采用Answers代写最终回答。[官方价](https://brave.com/search/api/)为US$5/1000请求、每月US$5抵扣；不是D统一订阅或已发生费用。 | [基础条款](https://api-dashboard.search.brave.com/terms-of-service)（2026-09-01）3(b)(i)仅允许应用运行所需的临时结果存储；具体Order Form可能另定，未核用户账户保存权。不能从可调用推导无限期保存结果/缓存原包；接口自身缓存也不等于客户保存许可。 |
| 博查 Web Search | [官网示例](https://open.bochaai.com/)使用 `POST https://api.bochaai.com/v1/web-search`、Bearer用户Key；[官方插件](https://github.com/bocha-ai/dsh-web-search-bocha#config)使用 `api.bocha.cn`，返回 `data.webPages.value[]`，实施时核实并固定实际入口，不静默迁移凭据。[官方产品PDF第18页](https://mkp-res.hc-cdn.com/marketplace/public/appv2/attachment/FE5/A96/96F/0000000000FE5A9696F.20250527042304.feac985174234808a69f64e899bd6792.pdf)曾列¥0.036/次（¥36/千次）；[当前价格页](https://aq6ky2b8nql.feishu.cn/wiki/JYSbwzdPIiFnz4kDYPXcHSDrnZb)本次无法读取，因此当前生效价/套餐/免费额度未确认。 | [服务协议](https://open.bochaai.com/terms-of-service)未核得明确的结果缓存期限、聊天持久保存/备份/导出许可；这些条件unknown，不从BYOK或未写TTL推断无限保存。 |

实施时区分搜索摘要、实际读取的网页正文、本地回答及引用来源；网页读取权限和站点内容条件独立。账户条款影响的持久化范围单独说明，不静默删除用户历史、不让该局部未知阻塞无依赖实现。用户凭据沿既有本地凭据边界，不入App统一密钥、日志、项目或普通备份；不向聊天索要token。**两家带凭据真实调用与中国大陆网络可达性均未测**；公开文档可访问不作为这些验收。

排除旧接入路线：[Microsoft确认Bing Search APIs于2025-08-11退役](https://learn.microsoft.com/en-us/lifecycle/announcements/bing-search-api-retirement)；[Google确认Custom Search JSON API不接受新客户](https://developers.google.com/custom-search/v1/overview)，既有客户过渡截至2027-01-01。不按旧教程建立新接入。

<a id="post-function-quality-review"></a>

## 功能完成后的质量审计（唯一待办，尚未启动）

F01–F36功能完成后单独审计：职责过重、重复状态、重复I/O、复杂自定义适配、测试/文档重复，以及过宽的限制。现在只在此记录，不新增审计平台/任务书、不提前全局重构；结果按实际风险决定局部整理，不以行数或删除数量为目标。已确认的卡死、数据/权限风险和阻断功能的缺陷仍按当前优先级修复，必要安全措施不删除。该后续审计不是把当前未完功能移到发布后，也不替代当前验收。

## 不能在本轮混入的其他方向

LoRA/控制生态与训练、新增基础生成模型家族、远程推理/集群、iOS/iPadOS版本、商业化与许可证改变、独立相册工具、云同步/多人协作、完整剪辑/DAW、网站登录后代购发帖等电脑操作。它们仍属于其他专题，不能因为“新功能清零”被混入聊天工程。

联网搜索、语音、代码和MCP需要少量实际执行依赖，可在本任务安全边界内选用系统能力或成熟库；不要求因此新增一批大模型。若为了某项能力确需新模型，先给出**一个有依据的最小例外**及资源/许可/运行路径，集中说明；不可默默扩展九模型首发名单。没有实际可用执行路径就保留未完成，不以“框架留好”代替。

## 适配完整性与合理边界

- 已选模型已有的能力不能因页面分类被丢弃。平台不支持的某个参数应明确禁用/解释，而不是在UI收输入、后端忽略。
- 系统提示词、模型聊天模板、输出格式和显示排版是四个不同的配置。用户可以编辑行为默认值，但不能由模型的文字替代真实文件/网络授权。
- F21 的RAG可从真实的词法检索+现有模型重排开始；不可把关键词搜索宣传成向量语义检索，也不能要求部署大型独立数据库才能读几个文档。
- F24 的记忆是可见、可编辑、有范围的记录；不是自动扫描用户所有磁盘、邮件和历史会话。自动提取仅针对用户开启的内容。
- F28/F30 是一条真实且有边界的执行/预览能力，不是任意shell、包管理器和全语言开发平台。F29是MCP客户端，不是另外经营远程推理服务。
- 所有数值/时长上限区分模型硬限制、产品可配置资源预算和测试配置；不把开发机16GiB或测试256 token写成所有用户上限。
- 本表不要求每行一个新类、单独模块或测试文件；同一机制应复用，独特风险要独立可定位。

## 收口判断

S00–S05是同一份已批准范围的实施切片，完成一片可集成一片。S06做整体回归与最终状态核对。不能因分批而把后片重新变成“待用户讨论”，也不能未经用户决定将缺项藏成发布后路线。

## 实施状态（唯一维护表）

需求快照 CHAT-PRODUCT-20261003。2026-10-04 c16普通App补证R=`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261004T041401Z-chat-resume`；新证据以R/lead/c16-native-core.json、native-lock-checkpoint.json为索引。以下状态不把已有局部能力当成完整能力组通过。版本与证据在每片验收后填写。

2026-10-05连续收口证据RClose=`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261004T145523Z-continuous-closeout`；下表“连续收口”均指此目录。main仍为90819739（生产af0103b5）；候选代码4102cff1仅在1b00后增加默认关闭诊断和测试。解锁后117d布局/1ebe记忆包已补原生，671空取消接续已修并真实验证，1b00菜单首项修补待鼠标；Bottom卡顿仍未关闭。E=RClose/gui/unlocked-20261005。当时无桌面；本人晚间已解除该条件，旧RNo=`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261005T040538Z-no-desktop`仅增加非交互证据，不刷新旧原生通过日期。

2026-10-05定点真实集成RReal=`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261005T063244Z-real-chat`，受测`4266579ab5fe449ab9cdd38a474153684f5c0b56`。仅增加既有工作台测试目标的真实后端接线与Xcode测试入口；App生产代码仍4102cff1。实际1方法/2次短生成，不累计旧测试，不代表原生操作。

2026-10-05晚集中验收RHuman=`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261005T121357Z-human-queue`；普通App代码cc404e4e。后续eba9c370只补既有hosting测试和UITests scheme，未改生产代码；真实失败与成功分开，不刷新未执行项目。

2026-10-06 RNative=`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261005T141348Z-native-tail`；当时原生b8b5ebcb、代码/构建ff20f2bc（原生后来由RUnlock补验）。下列增量不把旧失败消去，不把不同测试相加成总通过率。

2026-10-06解锁补验RUnlock=`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261006T002853Z-unlock-native`；实际推荐普通App仍ff20f2bc，新滚动实验未通过/未接纳。下列状态保留失败与模拟/原生区别。

2026-10-06有限Bottom收口RBasic=`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261006T024827Z-basic-usability`；未接纳候选代码 **0219f61b204928feb83d36718a8bf4f0d46f5068**。4项定向保护通过与2项合成滚轮离底前置失败分开；普通App构建通过但再次锁屏，未新验原生。推荐ff20、main不变，最终版本见当前行动。

2026-10-06无桌面续作RFollow=`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261006T071736Z-bottom-no-desktop`，代码37b30df22b11af1e8b5b621845fc935c7eca2369。只关闭异步恢复的旧分支目标缺口；2项纯值执行、最终驱动编译分开留证。当时两项旧replay/普通App冷开Bottom仍未通过，无桌面未运行hosting；被下段解锁补验推进，历史失败保留。

2026-10-06本人集中补验RHumanNow=`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261006T115611Z-human-queue`，同一9230a6cd普通App，无代码变化；只推进下述F31/F35状态，不重跑模型。

2026-10-06最新解锁补验RNow=`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261006T110535Z-unlocked-bottom`；受测生产代码9230a6cdabf40b540b17401d39b9ac64181cd265，普通App固定冷开/搜索代表路径、个人记忆管理及MCP停止/重连已补。两replay观察到零位移，驱动前置仍失败；不虚报通过或整组冻结。当时本人已解锁但不能亲自操作；之后本人集中结果见RHumanNow，最新保护/启动/远端见当前行动。

2026-10-06输入与具体尾项RQuality=`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261006T130047Z-quality-transition`；实现/测试及普通App代码 **3cc71beecf13e70c7d6bce106172996c07daa210**。受测源码、构建、交付身份分别见 `lead/tested-source-identity.json`、`verified-source-final-build.json`、`delivery-version.json`；原生范围见 `native-tail-summary.json`。最终仅文档SHA/候选远端见 `quality-transition-receipt.json`。下表本轮通过限定在明确路径；长单条Markdown跳动及Finder有效拖入仍开放，F26为本人批准延期，未宣布冻结。

2026-10-08收口：真人52ce左侧/右下真实拖入、双预览和冷开通过；8cf1b7dd46f6041dbcf1ac3db75b19839ae390c4关闭原3项紧凑hosting失败并通过同版普通App阅读回归。此前失败为历史，不追改；下表F05/F17/F19本轮门槛已收口，F26仍是唯一明确延期。版本/证据与正常main接纳见CURRENT_ACTIONS及RPosition/lead/unlocked-closeout-receipt.json。达到本轮视觉转段门槛，不宣称正式发行或全部配置保证。

| ID | 状态 | 入口／证据／剩余 |
|---|---|---|
| F01 | 非空四分类冷开与一组在途归属原生通过 | RUnlock/gui/inflight-category-final.json：图像/视频/音频非空草稿、图像参考冷开保持；文字真实Qwen3.5-9B Q4冻结短重现运行中切图像，完成OK仍归A812，原请求/历史/草稿/两附件保持，其他分类无新增运行。只做一组，不外推全排列或全部模型。 |
| F02 | 核心/菜单代表操作已验；输入热点与本人体验已收口 | 3cc71bee：实测每次编辑重复speechVoices查询约63ms，改为首次/声音变化/激活刷新缓存，动态列表不永久冻结。修后局部body约0.17–0.25ms、编辑窗口>100ms trace组15→0；不是按键到像素保证。本人确认差不多正常；偶发字母消失随后未复现且其他App也偶有，留观察，不猜修。原菜单证据复用。 |
| F03 | 代表管理路径已通过 | 旧671/4102/cc404的创建、切换、重命名、置顶、收藏、Unicode标签、归档/恢复、软删除/恢复以及草稿保护证据复用；没有继续以未知全排列作为泛化尾项。 |
| F04 | 代表同/跨会话搜索跳转原生通过；收藏沿用 | 9230a6cd仅两处搜索center→top；37b30在固定Reply only OK.命中后布局卡死留sample，修后同会话离底/跨会话命中目标UUID、后续操作与草稿保持。RNow/gui/search-top-native-result.json；不是字符级高亮或所有搜索组合保证。旧671/cc404收藏首项与标签证据复用。 |
| F05 | 阅读恢复/搜索与紧凑hosting原反例已通过 | 1ebe会话包/独立恢复/冷开保留Unicode草稿，671管理/设置切换未丢草稿。671一次真实完成后的Bottom卡顿留样，冷开及受控动态hosting通过未能关闭该失败；E/recovery-data-check.json及lead/empty-cancel-native-hang.sample.txt。4102cff1复核未证实命令循环，只备默认关闭/限量/无正文的诊断；2026-10-05晚cc404再次复现：原请求重现OK成功落盘→上滚→Bottom导致71206主线程约98%CPU，sample指向懒布局phase/prefetch与Graph事务循环。同包冷开/切已有分支可用，不能推断动态已修；RHuman/gui/bottom-reproduced.json及lead/bottom-after-short.sample.txt。eba9新增Controller的reproduce→跟底→上滚→Bottom受控hosting通过，但未复现普通App卡死；一次官方SwiftUI trace下同短请求也响应，不能关闭失败。Bottom按钮仍留着另列状态缺口，没有猜改生产滚动。 RNative三项差分hosting通过；b8一次相同冻结短请求后的原生Bottom响应（218ms工具调用、不是帧延迟），旧间歇卡死仍开放，未修改生产滚动。 RUnlock补稳定冷开反例（无生成/无分类切换）；单一ScrollPosition实验原生改善但hosting失败，已撤回，不关闭Bottom。消息级搜索/恢复实验不外推精确像素或生产通过。 RBasic：只保留单一UUID滚动所有者、按用户phase维护跟随意图；replay完成后自动跟底恢复至20点，短流Bottom/历史及3项保护共4方法通过。两个合成滚轮driver未产生离底，测试仍失败；普通App锁屏未验，候选未接纳，不关闭原冷开反例。 RFollow：旧前后offset不能排除同步回拉，驱动边界尚未完全解释。新驱动只编译，未执行；重新读取当前分支的异步恢复小修通过2项纯值测试，不代表原生卡死关闭。 RNow：两原replay同步boundsChanges=0，实际没有离底，不是已观察到生产回拉；/var临时根拒绝后用任务xctestrun注入既有D_TEST_TEMP_DIR，没有改Store保护。9230普通App冷开真实上滚/Bottom、离底会话往返、同/跨会话搜索和输入Undo可操作，五会话历史/草稿不变；37b30搜索卡死另经center→top反例对照修补。gui/search-top-native-result.json。旧失败保留；未重跑模型，未把两个driver失败计绿，尚不宣布所有滚动组合或功能冻结。  RQuality：5项ChatDynamicBottomHosting及链接校验同次通过；replay检查真实controller跟随，非replay验证有效离底/Bottom点击/末条可见，不再依赖无效合成滚轮。可见末行对齐代替懒布局的估算总高度；保留恢复/焦点/历史要求。新长单条滚动问题单列F17，未功能冻结。  RDesktop：9b6切会话丢内部位置反例经1d5修补，Section22/16往返通过；854首次搜索未到标题，abd5有界几何校正后第一次命中到标题，Section3往返、Bottom和草稿Undo通过。原5项hosting本轮2过3败，28.31–28.54pt底部留白超28pt；稳定采样仍败，原标准保留，不用旧5过覆盖新候选。新增marker几何1方法及版本门禁1方法各自通过；无效按钮driver不计通过。详见CURRENT_ACTIONS的RDesktop。 2026-10-08：真实原生/缓存几何均28.5，不是测量误报；8cf仅去掉非空尾占位，原3失败现约20.18，28点标准不改。6 XCTest＋4 Swift Testing通过；普通AppSection23会话往返、首次搜索、Bottom及Undo通过。RPosition/lead/compact-{edge-test,tail-tests,native-result}。 |
| F06 | 编辑/分支与从所选消息分叉代表路径通过 | RQuality/gui/fork-native.ax.txt：普通App将Reading corner lighting前两条分叉成新会话，原6消息/3attempt保留；新2消息逐字段等于来源且0attempt，无自动生成。旧编辑/同会话分支/切版本与路径返回证据复用。 |
| F07 | 实现/CPU通过；菜单原生门槛通过 | regenerate新seed与reproduce冻结旧node/messages/inputs/system继续分开。c16菜单可展开关闭且短发送不复现旧反馈循环；旧真实不同seed/缺seed禁用证据复用，未重跑长生成或宣称逐token确定性。 |
| F08 | 原生部分采用/人工多版本通过 | c16部分回答采用→继续证据复用；af0103b5修复人工采用后主文仍显示旧结果。普通App冷开、中文主文、原始英文折叠、再编辑初值、切原版/人工版通过；原attempt不改。RClose/lead/adopted-display-native-red.json、native-adopted-display-green.json；定向10方法/2suite。 b8答案版本子菜单切原始→人工后主文正确，固定schema错误原始仍保留；见RNative/gui/nested-versions.json。 |
| F09 | 同模型比较原生通过；真实跨模型服务链通过 | 旧RClose同模型不同参数与普通App选用证据沿用。RReal中实际ChatController.compare→WorkflowServices→Runtime串行运行Qwen3.5-9B与Qwen3.8-27B完整BF16/SSD；同一冻结问题及seed42，正常结束各8 token。模型/revision、先释放后加载、结果/会话归属、选用第二assistant的路径和下次上下文、未发草稿保护、Store关闭重开与输出可读均通过。两答案恰好相同，按ID/路径验证选用，不凭文本差异；不是新原生跨模型鼠标验收。lead/real-chat-evidence.json。 |
| F10 | 代表作用域普通App通过 | 671实际设置新会话默认DEFAULT-ONLY，旧A812系统提示仍空，新EDB继承；清除默认后EDB保留，另一新E36为空。E/native-management-context-defaults.json，隔离suite，未生成、不改旧请求。当前独立替换/清空CPU与既有预设证据沿用。 |
| F11 | 预设与自定义选段指令接线/原生通过 | 3cc71bee补独立selectionInstruction的保存、应用、fork继承和实际QuoteSheet使用；不是覆盖聊天system。两项定向CPU通过；RQuality/gui/preset-source-quote-native.ax.txt：新预设→应用→真实PDF选段→Explain，将冻结指令、引文及sourceOnly出处加入原草稿，不发送；正常退出/冷重开仍保留指令、引文和两附件，见gui/final-fork-selected.ax.txt。 |
| F12 | 原生读取/拒绝/恢复沿用；自定义模板真实传递/生成通过 | RClose原生tokenizer预览/非法Jinja拒绝/恢复与既有12项固定tokenizer检查沿用。RReal复用已支持的有限模板加marker，9B实际冻结请求保留override，真实后端promptTokens=39与编辑预览一致、不同于默认31；随后27B使用自己的默认模板，无串入。1方法内同一组生成覆盖，不额外重跑。没有宣称任意Jinja或新增普通App模板生成交互通过；lead/real-chat-evidence.json及template/token/request原件。 |
| F13 | 格式/显示原生保留与人工字段通过；模型结构输出失败留证 | 普通App自动→JSON→D结构定义、字号14→15/换行开关保存，冷开保持。现有Qwen真实请求返回schema本身而非目标对象，明确校验失败/原文保留；不是约束解码通过。显式人工编辑采用合法JSON后可提取title送Canvas。RNative/gui/{format-display,structured-field}.json，不通过反复抽样掩盖模型失败。 RBasic/lead/f13-frozen-request-review.json核对attempt 1BA463F2完整冻结请求：system格式声明与user目标对象相容，task/systemPrompt/inputs为空，无额外冲突；node内messages与快照一致。归类为一次软格式输出失败，不归因冲突，也不外推模型普遍不支持。 |
| F14 | 代表冻结请求查看与脱敏复制原生通过 | bf8/e742本地正文token/key过度遮蔽修补及10方法沿用；旧差分AX记录不足不抹去。cc404实际Inspect frozen request显示4条有序消息全文、冻结system/格式/媒体限制/model/seed/预算与重现来源；未记录usage和约499保守估计分开。Copy redacted JSON后粘入隔离词法搜索核对：messagesJSON/systemPrompt为[withheld]，modelID/绝对路径不在分享结果，安全参数/ID保留；随后清空搜索、未发送。与已保存attempt交叉核对，RHuman/gui/request-inspection-share.json；这是操作摘要和磁盘核对，未另存完整AX原件；不承诺检测任意秘密。 |
| F15 | 停止与空取消后接续通过；旧Bottom代表路径已通过，新长文问题见F17 | 旧c16长流/部分回答采用沿用。本次真实首字前Stop产生空cancelled，原投影错误阻断后续；671仅下一请求跳过真正空/无产物cancelled或failed assistant，历史/user/非空partial/tool保留。先红后绿54方法/2suite及非实现者审阅；671原失败会话实际得到OK。完成后一次Bottom卡顿不掩盖，受控动态1方法通过但未定位根因。 |
| F16 | 实际响应分层及reasoning-only原生展示通过 | 3cc71bee修实际response无final时错误回退raw的问题，原始字节/思考继续保留，无正文明确显示，不假装完整答案。两次真实Qwen3.5-9B Q4/256与1024token长度终态都仅reasoning，原期望完整答案失败记录保留；未无限生成。捕获结果+Store重开1方法、通道视图测试通过；gui/channels-actual-open.ax.txt与channels-reasoning.ax.txt为同普通App实际展示。不是工具调用真实模型全组合或完整回答质量通过。 |
| F17 | 代表格式、可见外链取消及组合阅读回归通过 | 旧格式/复制证据复用。RDrag旧可见链接取消跳COPY-20的失败保留；RDesktop在9b6两个可见位置确认/取消均保持，滚轮停止稳定；1d5及最终abd5再验可见Apple链接确认/取消，未打开浏览器，位置保持。实际固定样例24节，旧40节表述不作为本轮样本量。搜索/会话恢复在F05记录，不将局部通过等同所有滚动回归或功能冻结。证据lead/desktop-native-result.json及gui/settle-link-*。 8cf同版普通App再次核可见链接确认/取消，前后滚动值0.01062502887236107一致；有界尾占位修补不改链接/搜索/恢复。 |
| F18 | 组合hosting与消息/资料代表选段已通过 | e0cc749保留所有断言改有效事件与同步XCTest的1+2方法证据复用；c16消息选段解释沿用。3cc普通App补PDF资料中400 lux精确选段→自定义指令Explain→草稿/来源保存，不自动发送；与F11共用同一证据，不重复计算测试数量。 |
| F19 | 左侧/右下真实松手、预览及保存冷开通过 | 原项目附件/预览/冷开、既有83字节explicit-copy采用保护沿用。RDrag/RDesktop跨窗自动拖动未确认命中，不追记通过；RDrop本人在abd5松开后路径入正文且无附件，确证内层NSTextView消费。d1ab5f71仅composer分流file URL至原导入；19方法通过，普通签名包本人重拖形成附件。Lead预览34字节CSV、保存退出、同包冷开同项目并再次预览通过；固定草稿、所有会话messages/attempts/selectedLeafID、原CSV摘要/大小/mtime及原项目保持，无自动发送。旧失败会话保留，新增唯一asset摘要一致。证据RDrop/lead/fixed-drop-native-result.json及gui/fixed-{human-drop,preview,reopen,reopen-preview}.*；用户报告加号随光标左右位置变化，仅记观察，不外推所有落点/格式。没有用选择器/粘贴代拖入；冷重开选择的是项目。 6fb随后本人确证左侧不接收且分界非光标；直接方法20通过未覆盖原生登记。fe0在完整宿主发现plain-text编辑器未登记fileURL，注册断言先红、修后22方法通过；本人复验仍左侧拒收。RPosition记录左→右→左真实进入/退出x约515，与不可见Workflow原生区域边缘相符。52ce复用原生隐藏宿主，保留画布实例/缩放；新隐藏断言先红，24方法通过，审阅补强后1方法复验。普通App导航/122%缩放与草稿保留通过；新包Finder及后续保存复验因锁屏尚未执行，不能关闭原生门槛。lead/hidden-receiver-decision.json、hidden-native-checkpoint.json。 2026-10-08本人实际松手补齐：left.csv左侧、blank.csv右下均入附件；Lead双预览/保存正常退出/同52ce冷开/重开left预览，草稿及所有会话消息/尝试/其他会话、原CSV摘要/大小/mtime保持。首次仅悬停明确不计通过；仅两落点不是三点或所有格式。8cf仅变尾占位，拖放代码未变，复用此证据并重验隐藏宿主相关方法。RPosition/lead/unlocked-drop-native-result.json。 |
| F20 | 代表格式普通App提取/采用通过 | 同隔离项目TXT、CSV、PDF页定位、DOCX中文/emoji、显式扫描PDF本地OCR均通过，PDF片段显式采用，DOCX/OCR提取与定位通过；源文件不变。图像/视频旧真实模型证据复用。RClose/lead/native-segments.json，不外推任意文档格式。 |
| F21 | 词法/采用及代表真实重排原生通过 | 1ebe普通App对现有PDF两页查询page，真实Qwen重排完成，两片段ID各一次、原始JSON/输出资产保存，未自动采用或改草稿/资料。E/rerank-raw.ax.txt、native-rerank-temporary-stop.json；c16行定位/400 lux采用沿用。个人/项目复制、目录CPU沿用，未冒称向量检索。 |
| F22 | 预览及排除回纳普通App通过；其余策略按既有证据 | 671实际将OK消息排除并持久，再回纳，预览恢复所选路径；E/native-context-excluded.json、native-management-context-defaults.json。空cancelled投影保护已修，预算仍是保守估计而非实际token。摘要失效/替代原生沿用，不把全部组合判通过。 |
| F23 | 手动与真实自动摘要通过；范围保护继续保留 | 普通App手动摘要版本/启用/关闭、修改配置导致旧摘要明确失效，原消息不丢；真实Qwen辅助摘要成功且默认未启用。来源/覆盖消息ID保存，已入独立会话恢复。RClose/lead/native-model-and-versions.json、native-recovery.json。 |
| F24 | 个人/项目代表管理、忘记与冷开通过 | 旧1ebe项目记忆/建议审核/4版本恢复沿用。RNow普通App新增个人记忆→显式启用/允许读取→编辑→忘记→冷开，个人存储保留1–4版，项目未混入；忘记后显示仅历史、读取开关关闭。请求预览显示估算902→860，不逐条展示记忆，不据此冒称新模型使用验证；服务投影/自动记录CPU沿用。gui/personal-memory-native.json、lead/personal-memory-versions.json。 |
| F25 | 真实标题/标签/追问通过 | Qwen真实辅助标题已应用，标签入会话，三条追问可显式采用到草稿、没有自动发送。独立预算/来源保存，运行串行，旧错误不隐藏。RClose/lead/native-aux-and-comparison.json；用户手动命名不覆盖等CPU保护复用。 |
| F26 | 用户明确批准延期真实API/凭据验收；已有实现保留 | 2026-10-06批准Brave/博查真实调用、凭据办理及相关完整联网验收退出本轮功能/视觉转段门槛，非实调通过。已有两适配器、来源/网页读取、安全/取消和未配置状态证据保留；不注册/购买/索key，不新增provider或爬虫。其余冻结能力不随此延期。 |
| F27 | 计算器/单位/时区及CSV代表原生入口通过 | 旧c16/671计算42/1m→100cm/UTC→东京沿用。cc404普通App选择CSV→Data→value统计，rows3/min10/max30/mean20/missing0；显式采用为工具附件，源CSV未变，b8冷开仍可读。RNative/gui/native-csv-attachments.json；4102原始字节/归属/幂等/冷开服务证据复用，不以WASI代替CSV。 |
| F28 | 真实WASI及普通App失败/成果/取消后续跑通过 | 543失败stdout/traceback exit3不发成果、CSV mean20和保存沿用。671实际sleep20运行→Stop显示cancelled→print(6*7)得到42；无迟到成果，E/native-python-cancel-and-resume.ax.txt及native-management-tools-artifacts.json。最初默认样例在Stop前已结束，不算取消。原隔离/恢复证据复用，不宿主裸跑。 |
| F29 | 普通App真实调用、在途停止、重连和冷开通过 | 37b30普通App连接官方SDK loopback57659，test_progress(10000ms)在4.49秒时点Stop/disconnect，原会话保存cancelled；重连add_numbers(17,25)=42，显式断开，9230同源冷开保留两终态，草稿/附件/attempt无变化。RNow/gui/mcp-native-result.json。夹具只是延时，不是连续进度通知；取消不保证服务端副作用撤回，原诊断error9仍显示。旧显式采用/CPU drain保护沿用，无新服务实现。 |
| F30 | HTML/Mermaid/CSV/SVG代表预览和版本路径通过 | 旧HTML本地JS/保存/Canvas/恢复及Mermaid双版本/放弃修改证据复用。3cc普通App补已有summary.csv实际2列/3与20.0、chart.svg蓝色矩形预览/保存v1，JavaScript未启用；保留Python receipt来源及原CSV/PDF。RQuality/gui/csv-visible.png、svg-preview.png；不重跑Python/模型，不外推任意格式。 |
| F31 | 普通话/英语转写、本人听感及朗读控制已通过 | 旧授权Sendable修补/普通话，以及9230英语本人录音正确→审核采用→原声与草稿冷开、Samantha听感通过均复用。3cc修cmn-CN等别名不能按exact voice列表匹配的默认声音解析，复用系统AVSpeechSynthesisVoice(language:)；1方法和普通App默认Read→Pause→Resume→Stop实际通过，无云fallback或新增权限。RQuality/gui/default-read-*.ax.txt；本轮控制证据不是再次真人听感。 |
| F32 | 代表临时会话隔离与显式成果保留原生通过 | 1ebe独立临时session草稿不入普通历史；显式保存单一Markdown成果→Canvas，结束移除自有TemporaryChat缓存，所选作品保留，普通记忆/资料不变，不自动运行Canvas。E/native-rerank-temporary-stop.json、temporary-workflow-transfer.ax.txt。无临时真实生成，CPU取消/drain/原件保护沿用，不声称零磁盘痕迹。 |
| F33 | 新会话包/独立恢复/冷开代表路径通过 | 1ebe普通App重新导出→新位置独立恢复→正常退出/冷进程打开，消息/attempt/工具/成果/资料及4个相关记忆版本保持（已用手工记忆2版及本会话建议/审核记忆2版）；17媒体相同字节/独立inode，future memoryScopes空。E/recovery-data-check.json、restored-cold*.ax.txt。旧af遗漏与14方法/2suite先红后绿保留，不重写旧包；全局预设仍独立交换，未外推所有外部格式。 |
| F34 | 代表字段到Canvas与已发布成果回聊天原生通过 | RNative人工JSON→title字段→Data Input节点保存与原结果保护沿用；ff20“添加附件→本项目成果”回流同一已发布32字节结构字段，取消/预览/移除/重新采用/冷开保持来源与原草稿，不自动发送/运行。RUnlock/gui/attachment-cold-reopen.json；不宣称任意节点和跨项目组合全验。 |
| F35 | 输入响应/组选字已收口；长文代表回归通过 | SpeechPanel热点实测修补与原生编辑/Undo、本人确认差不多正常；偶发未确认字母消失未能持续复现，用户说明其他软件亦偶有，不猜改组字。原紧凑布局/快捷键/组选字证据复用，全Tab/VoiceOver组合未测不冒称。候选不随动仍按既有用户决定为正常。 |
| F36 | 主停止/工具终态/统计及长文尾项代表通过 | 旧真实空取消→续发OK、WASI取消→续跑、MCP取消/重连冷开、F01在途分类归属、冻结请求/保存失败CPU沿用；F05旧稳定冷开Bottom/搜索路径及本轮5项有效hosting覆盖互补，不再把无效旧replay驱动当当前产品失败。超长单Markdown新跳动另留F17，不据局部绿色宣布完整冻结。 |
