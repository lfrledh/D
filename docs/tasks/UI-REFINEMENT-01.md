# UI-REFINEMENT-01 — 第一版原生工作台

状态：r3 无桌面实现与定向检查完成，代码/App `2b4b9ad2215fa6f191ce43f0baf6848549e924f7`；原生组合待验，未接纳main。当前结果见文末r3；r1/r2是历史，旧失败/预算保留。

源/候选起点：91bef7d720a8b6cb923207ef787230f36496f4cf；已验生产代码 8cf1b7dd46f6041dbcf1ac3db75b19839ae390c4。独立集成树 D-UI-REFINEMENT-01、分支 codex/ui-refinement-01。准备提交完整执行基线写外部派工记录，不自引用。

证据：`D-Development/AgentTrials/UI-REFINEMENT-01/run-20261007T184130Z`（R）。原附件、截图和摘要在 R/handoff；执行/保护/审阅在 R/lead。用户不能操作，桌面可用时Lead独立原生验收；锁屏只阻塞GUI，不探测或修改系统策略。

## 冻结范围和所有权

- Lead：DualWorkbenchView、QuickGenerationView、ChatWorkbenchView 的必要展示装配与圆形收栏、固定媒体视口、现有统一设置入口；工程装配/共享契约/集成/文档。
- Canvas Worker：WorkflowGraphSurface、WorkflowCanvasViewportInteraction、必要 WorkflowHostView 展示入口及直接UI测试；指针/手形、真实框选封装、类型色。不得改执行/存储。
- Appearance Worker：现有 ChatDisplayPreferences、ChatDisplayPreferencesPanel 与必要纯展示主题/设置小组件和直接测试；不改共享壳层/聊天正文输入。
- 只在上述UI及对应测试做必要小型值提取。Runtime、模型、保存/项目schema、原生输入器、RetainedContentHost隐藏语义不变。精确Worker路径/接口在R各spec，Lead单一维护本记录。

## 行为与验收

1. 快速/工作流同级、四分类保留；顶栏右侧相邻模式切换及设置圆钮。分类/收栏只改变展示，不生成/取消/下载/重置草稿、附件、模型/参数或结果。
2. 图像/视频固定剩余空间视口（中央无结果ScrollView），完整适配；图像缩放平移/复位仅展示，视频原音轨/控制保留。右候选列表，详情独立；旧结果不自动写回下次请求。
3. 左右收栏后不留整列；窄窗自动收栏不污染用户宽窗偏好；设置分类复用现有真实入口，不造开关。浅/深色分别保存、默认/自定义可读，低对比提示；透明度只作用背景，轻量/系统辅助有效。
4. 指针空白拖框选、节点非交互区移动；手形只平移；控件/文本/端口优先；删除/Undo/缩放复用。恢复视图不得写节点坐标。框选接现有真实封装、保存/重开/边界端口。类型色来自WorkflowPortDefinition而非标题/字符串猜测，兼容校验不变。
5. 保留原生隐藏、阅读恢复、IME/Undo/草稿/资源与版本归属。新壳层按影响复验已有小CSV/长文/媒体。禁止网页模拟执行、模型新增、MIDI、F26扩展或全局架构重写。

按唯一TESTING_POLICY：小状态与真实宿主测试→普通签名App代表操作；不把组件/AX填字当真人组字，不重跑九模型/全库hash。候选和main仅以明确受测组合接纳。

## 执行纪律

写Worker独立外盘树/分支，沿用受限CLI workspace-write、network=false、显式模型/effort；写根仅任务树及专属output/tmp（缓存在tmp），共享Git不可写。先预检后实施；不递归、不改规格、不提交。初交+最多两轮针对修复，普通单轮15分钟；确有复杂实现可事先指定时限。权限异常暂停Lead，唯一已授权无字节码编译可记录降级；不安装/网络/GUI/全构建。Lead串行构建/测试/原生操作，重要Lead差异由非实现者检查。模型服务端解析/完整Lead成本unknown。

源旧scheme的未暂存内容/索引/摘要保护在R/lead/baseline.json与小副本；源旧分支、模型、项目、普通App和旧候选不动。仅显式暂存，保留历史，不重写/强推/正式Release。

## 结果与版本（2026-10-08）

- 全部相关测试组合：`fccf8889810a2340e0c151aa3d307cfeb27e30fa`，UITests 59项/8套件通过（36.26秒含构建）。原子多节点移动1项与媒体夹具1项为此前独立运行，不相加成同一轮通过率。
- 当前生产/交付代码：`baf9128093fa214bf4ddf340331390331d9873dc`。相对fccf仅有05aa窄窗明确打开检查器，以及设置按钮实名/图像缩回100%居中；普通签名构建33.70秒通过。未声称59项在此SHA重跑，最新两个展示细节仍待原生操作。
- 唯一App/启动器及同树Xcode见[试用指南](../RELEASE_FREEZE_TRY.zh-CN.md)。关键4文件与构建产物一致、签名核对在R/lead/delivery-app.json；没有手补或重签复制包。
- main和旧release候选保持`91bef7d720a8b6cb923207ef787230f36496f4cf`，旧功能基线8cf保留。本轮候选普通提交/推送，最终文档SHA与远端状态写R/lead/final-receipt.json，不自引用反复提交。未通过组合原生门槛，不强合main。

| 范围 | 实际实现与非交互证据 | 原生层级/余项 |
|---|---|---|
| U1 壳层/圆钮/收栏 | 右上直接模式+设置；四Quick分类；Quick、聊天、Canvas分别复用真实状态；窄窗自动收栏不改宽窗偏好；项目/分类候选选择归属保留。Quick组字/隐藏宿主、宽窄策略通过 | bb6中间普通App实际四分类→图像、左右收起和设置打开通过，截图R/gui/shell-image-empty.png。**不是最终组合截图**；新包模式往返/窄窗/大字号/输入仍待 |
| U2 固定媒体工作面 | 图像/视频剩余区域GeometryReader无中央ScrollView；NSImage完整适配、放大/平移/适配；AVPlayer保留播放时间轴/原音轨；右候选、前后及旧详情。原Store资产读取 | 自有小项目复用既有2PNG/2MP4/1WAV，真实Store复制/来源摘要/保存重开检查通过；展示运行明确标“受控媒体展示记录，不是模型执行结果”。最终普通App适配/播放/候选切换/详情/采用未验 |
| U3 画布 | 原删除/作用域/Undo保留；指针框选、Shift累加、多节点实时预览并一次原子Undo；手形禁止端口提交，沿原导航；框选接原extractSelection真实工具封装；fit只改视野、不写布局 | 几何、手形提交门禁、导航门禁、低于5%适配及实际zoom拖动、控制器保存/Undo/过期目标反例通过。不是鼠标路由或新封装原生保存重开通过；库拖入/多选/封装/手形/端点随动待验 |
| U4 类型颜色 | WorkflowPortStyle按声明类型共用端口/线映射；联合不伪造单类型，带文字图例；保留原连接校验 | 代表声明/列表/冲突/联合分类通过；浅深实际合成像素、错误连接和颜色3:1参考的全套原生核查未完成，不称无障碍认证 |
| U5 外观/设置 | 统一6分类复用模型库/凭据/项目文件/语言服务；浅深HEX独立、重置/4.5对比提示、背景透明度、动态/轻量/系统辅助。旧v1偏好兼容；真实Markdown颜色进入解析缓存键，保留阅读identity | 偏好隔离/持久化/非法保护、合成及不透明回退对比、实际Markdown前景/链接检查通过；普通App自定义/冷重开/系统辅助和两模式相同位置待验 |
| 旧保护 | RetainedContentHost原生隐藏保留；不改原生输入器/阅读逻辑/模型/Runtime/Store/schema。group move唯一控制器增量只改布局 | 两个真实宿主保护测试通过。旧F17/F19/IME真人证据按未变底层保留，但不冒充最终新壳层通过；最终输入区拖入、可见链接取消/搜索/Bottom最短复验待桌面 |

完整未测不是要求穷举所有组合：按上表固定材料完成一次代表原生路径即可。新界面的部分说明仍为中文；既有语言包不删除，本轮没有宣称新增文字已全部翻译。原生材质使用公开系统regularMaterial，未造玻璃特效框架，不声称具有任意折射参数。

## 实施、复核与失败保留

- 两个有界写Worker均请求并观察为`gpt-6-sol/high`，独立物理树、分支、输出和缓存，workspace-write/network=false；共同基线b8630e57822ea1b259d8293b5bda112830ebf650。角色及允许路径在R/{appearance,canvas}/spec.txt，实际CLI/turn_context见*-request.json、*-route-accepted.json。没有用户全局配置修改。模型服务端隐藏解析未知。
- Appearance初交+1修复：修正高透明度下不透明回退的对比提示；Canvas初交+2修复：手形提交、框选导航互斥、远图适配下限和低zoom位移。均已退出0，保留原事件。Canvas修复1的进程枚举被限制，只记录环境能力，不提权、不以枚举缺失证明所有进程停止；未观察成功越界写入。
- Lead实际负责统一壳层/设置/媒体装配、原子moveNodes、主题注入与Markdown颜色刷新、保留视图环境、候选选择归属、窄窗检查器及末尾两项展示小修；不是Worker独立完成。重要Lead改动由file_drop_boundary_review、human_drop_evidence_check、native_files_review定点只读复核；不称他们另跑了GUI。
- 审阅发现的对比回退、手形接收、低zoom移动、Markdown属性缓存及窄窗检查器问题已修；最终源码复核未发现新P1/P2。实现/每轮实际墙钟见R/{appearance,canvas}/*-process.json，完整Lead归因和订阅费用unknown，不复算历史费用。
- 首次夹具测试环境变量未传播/筛选漏`()`, 未生成夹具；修正测试启动器后1 XCTest+1 Swift Testing实跑通过。首次UI测试有CGFloat.infinity类型歧义编译失败，Lead仅修限定类型，原断言不放宽；ui-tests-r2通过。原交互zoom下限从50%改为新规格5%，另保留低于5%的fit覆盖，不以删断言过测。
- 本地HTML原型被浏览器安全策略拒绝；未开localhost或换路绕过。按用户既有许可使用随包截图/书面规格，不能写“浏览器原型已操作通过”。

## 证据与最短恢复点

R/lead/{baseline.json,scheme-before.plist,ui-tests-r2-result.json,ui-tests-r2.log,fixture-tests-r2-result.json,delivery-build-result.json,delivery-app.json,locked-checkpoint.json,final-receipt.json}；R/gui/shell-image-empty.{png,ax.txt}是bb6中间壳层；新组合四模态/设置/Canvas截图尚缺。

当前桌面工具明确返回锁屏。没有继续探测、改策略或催办。未在05aa启动后执行编辑，核对自有精确路径PID53646后SIGTERM并确认结束；不是正常GUI退出。最终baf包未启动；Worker/构建/测试已结束，旧普通D和他人进程未关闭。原个人scheme内容/索引/未暂存状态在最终回执复核；模型/旧项目/历史证据不动。

唯一集中队列原位登记本轮组合原生待验，不新增本人授权/录音/试听/凭据事项。下次桌面可用：只打开唯一baf包和R/gui/UI acceptance.dproject，先固定预览/两侧收栏/窄窗，再Canvas指针手形框选封装与新壳层阅读/拖入，记录同版截图；能由Lead操作就不交本人。若真实失败，先留最短反例、在本范围修复，保留已耗预算。验证通过再决定正常接纳main；此处不启动下一阶段或正式发布。


## r2 无桌面补齐及解锁验收（2026-10-08）

起点 `f26258d13f859cc667cc79f3e2cf24c9dcc0cffa`，未回退旧成果。R2=`D-Development/AgentTrials/UI-REFINEMENT-01/run-20261008T010729Z-no-desktop`；任务附件副本为R2/task.md。开始锁屏时只读/实施/构建；用户随后明确解锁但不能操作，Lead才启动独立普通App与hosting。没有本人新操作、系统权限或模型运行。

### 实际实现

- **A**：聊天左栏默认真实模型与下一次参数，同栏可切会话；右栏只放资料/成果。保留现有编辑器/阅读器/Controller和完整会话功能。消息动作悬停或键盘聚焦显现，固定占位不挤正文；参数不写全局偏好。
- **B**：右上设置与Cmd-,经同一有类型路由，携带明确窗口/项目/会话目标；移除无回调的另一Settings scene，不造事件平台。原生复验发现结果详情关闭后sheet缓存仍为true，Lead按当前窗口的原生sheet生命周期同步并复验设置可再开，无轮询/抢焦点。
- **C**：macOS26公开`glassEffect`用于目标面板，轻量/辅助偏好走明确不透明后备（本App最低macOS 26.2，不声称兼容旧系统）；透明度只调底层背景，motion用于边栏及模式/分类反馈。inactive原生子树仍立即隐藏，不等待退场。Canvas装饰层拦截空白拖动已实测并修为不接收命中，实际指针框选/手形平移恢复。
- **D**：本轮153个refinement语义key中英对应及插值核对；稳定端口/模型/存储ID未改。长英文Text workspace和Conversations窄窗挤压已局部修并拍照。旧页面的历史中英混排不冒称全App翻译完成。

### 版本和最少互补证据

| 版本/层级 | 结果与边界 |
|---|---|
| `10ee7b9c78622262c128efd122ff71ae3c11b6ea` 纯值/路由 | targeted-r2：12方法/2套件通过；偏好、玻璃后备/动效选择、设置目标。不是原生辅助设置验收。 |
| 同10ee 原生hosting | native-hosting-r1：3个ChatPresentation方法通过（实际输入宿主/缩放、隐藏释放、Workflow宿主恢复）；旧viewport方法15处失败，单列不混成全绿。 |
| 同10ee 普通App | R2/gui/18–30：详情关闭→设置；指针框选→两节点多选移动→真实菜单一次Undo；手形平移；封装为Two text inputs；点击两端口建立连线、删节点→Undo恢复；输入/Undo、Bottom末条、可见外链确认取消、窄窗可达、分类草稿保留。`canvas2-verification.json`核原子Undo及图内容/资产/运行不变。 |
| **`02df6f1c11f7043c4b3f395e0c05bbab7d3c3940` 交付App** | 相比10ee仅3行导航标签布局；签名构建36.00秒通过，4关键文件复制一致、codesign通过。同包R2/gui/31–35：冷开保留R3 SAVE草稿、窄窗英文、图像候选/125%缩放/收栏中央扩展、详情关闭后Cmd-,再开、视频0→4.04167秒。不是新模型推理或真人听感。 |
| `7ae57793b54292ee243d7a3dbb07e4c6362365f8` 测试驱动 | 仅改旧viewport测试：显式可见窗口、实际选择指针/手形、验证队列身份与坐标；原行为断言全保留。单方法复验停在窗口visible/key前置失败，尚未进入行为断言；不是通过或生产根因证明。App代码仍02df，无需重打包测试/文档差分。 |

旧fccf59项是r1证据，未重复相加。早期`canvas-after-undo`/`canvas-after-menu-undo`未真正触发菜单动作，保留原结果；后用真实菜单点击再Return及新前后快照证明一次Undo，不覆盖早期失败。后续仅测试/文档的最终SHA在外部回执，不为自引用反复提交。

### 明确保留的组合余项

1. 本轮自动Finder跨窗拖动没有可靠目标命中，未成附件；不能由此认定旧左侧拒收复发，也不能用导入函数/选择器代替。原52ce真人左右接收/冷开证据仍有效；新壳层需最短真实落点→预览→保存重开。
2. 端口**拖动**两次未建立边，点击输出再输入成功；命中/路由归因未定。新封装已实际创建和保存，尚未从冷开界面重新检查其边界；不写封装端到端全通过。
3. 分类往返草稿与会话保留，但长消息阅读位置有跳到末段的观察；本轮尚未隔离离底/跟随状态，不能直接判成已修或已知新根因。可见外链取消的位置保持与Bottom已直接通过。
4. 检查器刚收起时立即fit曾使用过渡宽度，布局稳定后fit正常；保留最短反例，不修改坐标/重排节点来掩盖。
5. 系统降低透明度/减弱动态/高对比的值型策略通过，未实际切系统设置；大字号及真实合成可读性仍需窄的原生补验。没有无障碍认证结论。
6. viewport宿主窗口前置失败按独立工程驱动项保留；不因普通App部分成功删测试、不继续扩大测试框架。

上述不新增冻结要求、不启动下一设计阶段。当前为可试用候选、组合原生验收部分完成；main仍91bef，旧功能门槛不追改为失败，F26仍批准延期。

### 来源、保护和接续

- r2两个受限CLI Worker负责玻璃纯展示与不冲突本地化，请求/可观察`gpt-6-sol/high`、独立写根、network=false；Lead负责共享Chat/设置/主题接线、原生修补和集成。非实现者对重要生产差异及测试驱动定点只读复核，不声称另执行了GUI。证据R2/{glass,shell}与lead/worker-exception-review.json。
- glass初次shell heredoc临时文件被拒，后改apply_patch未先停报；协议未遵守保留。可观察无扩权/成功外写，隐藏副作用不凭空保证。没有用户全局配置修改。墙钟见各run结果；完整Lead token/订阅费用unknown，不重算历史。
- 源01758b8与个人scheme完整差异、摘要、索引和未暂存状态一致（R2/lead/protection-end.json）。8个夹具资产原字节、聊天历史/附件/运行和Quick runs保持；独立项目既有26字节素材新增fileLocations核验信息、原asset字段不改，数组顺序不作内容一致依据。只主动编辑本轮R3 SAVE草稿与测试图。R2/lead/fixture-protection-end.json逐项列明。
- 最终普通App4关键文件原样；D63339经菜单正常退出，任务Finder窗口关闭，无模型/自有构建作业续跑。旧Terminal关闭未确认的历史不绕过、不重报为已清理。
- 精确证据索引：R2/lead/{native-results.json,targeted-r2-result.json,native-hosting-r1-result.json,viewport-driver-r2-result.json,delivery-native-r4.json,delivery-after-native.json,final-receipt.json}。唯一包与同树Xcode见[试用指南](../RELEASE_FREEZE_TRY.zh-CN.md)。剩余先由Lead独立办理；仅确需真人区分时进入原集中队列，不要求用户现在操作。


## r3 锁屏条件下连续收口（2026-10-08）

最新用户条件覆盖r2：不能解锁或操作，按桌面不可用处理。本轮未探测桌面、未启动App/Preview/NSWindow/hosting，未运行模型或改系统策略。起点候选 `4c42756415487a8ee7b3f53b5fdd3deef92eb723` 与远端一致，源/main及个人scheme与r2一致；没有回退或清理旧资料。

R3=`D-Development/AgentTrials/UI-REFINEMENT-01/run-20261008T045623Z-r3-no-desktop`。实现与交付代码 **`2b4b9ad2215fa6f191ce43f0baf6848549e924f7`**；最终仅文档候选/远端写R3/lead/final-receipt.json。测试执行时为4c427上的未提交差分，保存逐次patch；`validation-summary.json`逐文件确认成功检查快照与该代码提交一致，不宣称在尚未产生的提交上执行过测试。

| 项目 | 本轮实际结果 | 精确边界 |
|---|---|---|
| A 阅读生命周期 | 原条件分支会销毁Chat本地缓存。由已有WorkbenchModel持有轻量阅读状态，Chat按实际Controller取得独立对象；分类、模式、文字工作面、临时会话与草稿位置切换前捕获。原生marker只弱引用，不保存到项目；关闭释放，旧view迟到回调不重绑新owner。 | 保留现有Reader/票据。校验会话/分支/消息；旧像素点遇修订或输出变化失效，仍保留合法离底意图。没有新滚动器、schema、按键I/O；真实跨模态内部段落恢复待验。 |
| B 过渡fit | 选择明确短暂禁用方案。现有原生probe同时报告scroll surface宽度和clip尺寸，按钮及动作均只在目标面板宽度有效后接纳；使用实际clip计算，可包含常驻滚动条。新增中英帮助名称。 | 无延时、排队或逐帧fit，不吞已接受的动作；原视图上下文/交互锁继续检查。仅视角/zoom，无节点坐标或Undo写入。真实动画回调/快速收放仍待验。 |
| C 端口 | output载荷增加可选project/instance身份；真实生产源、接收及节点拖动结束的Scope一致，图版本/嵌套路径/类型检查仍在。 | 旧JSON可解码，但缺实例的旧端口载荷在当前真实接收端拒绝，须重新拖动；旧版接收端自身保护未改变。不是端口鼠标失败的已证根因。 |
| C Finder | 隐藏祖先时文件接收入口重复拒绝，含hover后隐藏、prepare/perform；可见后恢复。异步导入仍重查原会话及Store，无新接收系统。 | 原生隐藏及先前左/右本人通过保留。新壳层跨窗命中仍缺，方法回调不能代替Finder松手。 |
| D 封装与展示 | 新增公开Controller添加/配置/连接→extractSelection→保存/关闭→Store重开，校验图/工具、外部接口、digest、原snapshot字节及零推理。r2封装归档核对复用。 | r2小图仅保存“两文字输入”工具定义、没有外层invoke；新检查补跨边界代码路径，不冒充原生冷开。玻璃后备/153键及未变展示证据复用；仅新增fit帮助两语言检查。 |
| D viewport驱动 | 有限复核未找到可确定的新驱动修补。曾怀疑空图zoom基准，但restoreViewContext会恢复独立空图上下文，反证后撤回。 | 保留原15失败与7ae的visible/key前置失败，不能据此前置判锁屏。旧opacity双层fixture不作为生产RetainedContentHost生命周期证据；原断言未删，未运行窗口方法。 |

### 执行与审阅

- `hidden-red`：新增一个无窗口方法，在尚未补可见性门禁时5处行为断言失败；修后同方法通过。`targeted-r3-fixed` **29方法/5套件通过**，涵盖读取快照/过期票据、fit/端口身份/拖动值逻辑、隐藏接收与注册、工具实名。普通NSView与pasteboard直接回调不等于原生拖放。
- `extraction-reopen-fixed` **1方法通过**，真实Controller/Store/编译边界，未运行模型。仅检查新增缺口，没有重跑已有Store全矩阵。r2的12/3/59项不累计为本轮结果。
- 首次UI检查误向shape-only matches传入身份参数而编译失败；首次封装夹具调用private edit而编译失败。均留原日志，分别修调用和改用公开编辑入口，未放宽断言。非实现者指出节点结束Scope遗漏身份，提交前修正；没有把普通节点移动默默破坏掉。
- Lead直接实施及执行检查；两既有只读会话分别核A/B/D与C，不称独立模型执行GUI。没有新写Worker、重置旧预算或新派工设施。用量仅可核各命令耗时；本轮完整Lead/审核token、订阅实际费用unknown，不重算旧样本。
- 同树 **D Nodes / Debug / My Mac** 构建通过（35.705秒），沿用既有资源和签名配置；实际ad-hoc签名、App Sandbox启用，未设置TeamIdentifier，不是Developer ID发行包。交付副本4关键文件与产物一致、codesign校验结果见`delivery-r3.json`；**未启动**，不是普通App本轮通过。唯一启动器原位更新，旧02df/8cf包与候选保留。

### 待解锁的两个原生路径及恢复点

1. 用r2已有24节项目主动离底→图像/视频→文字、Quick/Canvas往返，核原段落/草稿/附件；穿插已可见外链取消与显式搜索/Bottom。当前包Finder左侧/空白实际松手→附件/预览→保存冷开，核源文件与无发送。大字号、轻量及系统辅助效果沿该路径检查，不重办输入法/语音。
2. 现有小图端口真实拖连（包括无效目标拒绝）、节点移动提交/Undo、封装调用及保存冷开；面板收放时fit清楚禁用、稳定后一次适配，核节点布局不变。桌面前置满足后运行保留的viewport方法；若工具命中不明，只做最短回调/落点区分，不能无依据重复坐标。

保护：旧源01758b8个人scheme原orderHint 1→6、SHA256 ca3635…、索引与未暂存状态保持；main/旧release91bef不动。旧项目/模型/普通App不写入，新增Store夹具仅在R3/tmp。已结束本轮自有构建/检查进程，不声称控制或清理其他进程。最终源码与文档差异、远端、保护复核见外部回执。

状态：**当前可独立的实现、无窗口验证与交付准备完成；新组合仍待原生验收。** 没有新的账号/设备/权限阻塞；F26仍为明确延期。到此停止，不自动等待/探测解锁，不强合main、不发布，也不追加UI或全局重构。

## r4 解锁补验与定向修补（2026-10-08）

用户最新授权为已解锁、不能亲自操作。Lead先独立完成可做的原生路径；没有重办本人输入法/录音/试听，没有模型生成。起点候选/远端`dcd2b80a06a2f48f10d681c366bc2e94bf5ec170`，实际先验包为代码`2b4b9ad2215fa6f191ce43f0baf6848549e924f7`；源/main与r3相同。R4=`D-Development/AgentTrials/UI-REFINEMENT-01/run-20261008T121613Z-r3-native`，项目为r2夹具的新副本，未操作用户作品。

### 实际原生结果与修补

| 路径 | 2b4普通App直接结果 | 本轮处理与证据边界 |
|---|---|---|
| 长文分类往返 | COPY-21、滚动值约0.9147→图像→文字后回到Synthetic Markdown标题、约0.3178；后续观测未恢复，草稿不变。 | `ChatReadingMarkers.restore`把临时尺寸不匹配返回成功，且align不检查约束后的实际位移。改为继续原5×20ms有界恢复，并核实际offset；保留票据/版本/用户滚动和搜索保护。新增尺寸暂态/不可达点断言旧版6处失败、修后通过。**新包原路径未复验**；未证明onDisappear捕获时序及后续排版全已解决，不再猜补。 |
| 画布移动/Undo/连接 | 实际移动已连节点并提交；实际More→Undo一次恢复图节点/边/布局，资产与runs不变。点击端口建边成功。两次端口drag没有边，没有可靠接收命中证据。 | `move-undo-verification.json`、gui/06—10。只关闭移动/Undo和点击建边；端口拖连仍未验，不用点击代替。 |
| fit | 两侧关闭后可用，一次适配至89%；另一稳定面板状态仍禁用。 | 原probe只随document布局采样，祖先ScrollView独立resize漏报。无窗口真实NSScrollView反例旧版3断言失败；新增frame/clip观察、去重和拆卸清理后通过。不扩大容差、不重排节点；新包面板动画时序待验。 |
| 封装调用 | 已保存`Two text inputs v1`从库插入→确认计划→提交，父invoke实际失败“数据类型不符”；两个空文字子步骤已成功发布text asset。 | 表单默认把文字资产写作纯文字schema。仅改新草稿提议，按实际内置input/template版本、value/field/human配置或固定invoke摘要取类型；显式接口优先、旧类型后备保留。旧v1/摘要不覆写，运行校验不放宽。真实Controller提议→extract→run→读资产→保存重开通过，含空与Unicode文字、旧工具不变、零模型请求；**新建封装的原生调用待验**。 |
| Finder | 用本轮复制CSV实际CUA按住/跨窗移/松开，没有附件或反馈。 | 没有足够目标命中证据，不认定产品拒绝；原CSV、草稿/消息不变。没有选择器/粘贴/直接服务代替拖放。新壳层真正附件→预览→冷开仍缺。 |

实现/交付代码 **`79f9eb53d6c93b18b99bda7a3eb2324e38abcec5`**，7个生产/测试文件。Lead直接实施，两个既有只读非实现者分别审阅阅读与封装/viewport，没有新写Worker或模型测试。审阅发现初稿漏human显式结果schema，提交前补回并增加真实ToolBoundaryDraft boolean反例；不是用户接口缩减。封装资产重开后字节读取按审阅意见加入同一方法。

### 验证与版本

- `local-red`先遇fixture修改let字段的编译错误；改为构造新不可达point后，`local-red-fixed`真实执行：阅读6断言、ancestor resize 3断言失败。原错误和反例均保留。
- `local-green`：**1 XCTest几何方法＋7 Swift Testing方法通过**，包含真实表单提议、视口尺寸、几何/平移边界；不是8次普通App验收。之后human保护补充由`viewport-native`中的该表单方法复验通过；未变阅读/视口实现复用，不重跑同质矩阵。
- `tool-execution-final`：**2 Controller/Store方法通过**，在精确79f代码上执行，含封装纯程序真实执行、关闭后重新读输出字节及原工具/历史保护。初次同组未包含重开后字节读取，最后补断言再跑，不叠加计数。
- `viewport-native`的保留窗口方法再次失败于visible/key/host前置；未进入wheel/middle/hand等行为断言。与随后工具明确报告锁屏是两条证据，不能把前置失败归因为锁屏、也不能删原断言。需要恢复时区分宿主激活和产品行为。
- 同树D Nodes / Debug构建通过（36.003秒）；既有ad-hoc sandbox签名，codesign通过，4关键文件复制一致。没有手补产物/签名设置变更。新App为R4/delivery/D Native UI 79f9eb53.app；唯一启动器原位指向它。
- 构建复制后，CUA选择启动器明确报告Mac锁屏。停止桌面，没有重试/轮询/系统策略更改；**79f新包尚未启动**。旧2b4已正常Cmd-Q，工具isRunning=false。任务Finder第一次Cmd-W后重新取得Desktop，旧drop-input不再显示（后续证据`native-end-state.json`，首次未确认记录保留）；最后选择启动器时锁屏，是否曾建立新的Finder窗口无法确认，不声称清理用户窗口或全部系统进程。
- 受测未提交差分与79f代码对应见R4/lead/code-version.json；普通App此次只验2b4。最终仅文档SHA放外部回执，不自引用amend，不宣称在未来提交上测过。

### 保护、剩余与接续

- `protection-end.json`：源01758b8、个人scheme SHA256 ca3635…、索引9c76916b与未暂存orderHint 1→6均保持。候选main未接纳。R4夹具原52文件中50字节不变、无缺失；project.json记录本轮图/纯程序结果，quick-creation只有revision37→40（`quick-state-diff.json`），quick-chat完整字节不变。原资产/历史snapshot/CSV保持，没有自动发送。未改普通App、模型或用户作品。
- 已结束本轮所有自有构建/检查，窗口测试正常退出进程；旧版测试D正常退出，新包未启动。完整Lead/审核token与订阅费用unknown，耗时只采用各result.json，不重算历史。
- 唯一集中队列原位更新。恢复后先79f重复COPY-21→图像/文字、Quick/Canvas；新建正确输出接口工具→执行→保存冷开；面板过渡fit及稳定后一击，节点布局保持。再补实际端口drag、Finder真实松手/预览/冷开与大字号/轻量显示。已有r2布局/模型/本人证据按未受影响范围复用。
- 没有新的账号、设备或权限办理；F26继续延期。工具不足时只留下最短真人对照，当前不催本人。现状态为**定向修补与可独立检查完成，组合原生部分完成且新包待验**，不宣布最终UI、main接纳或发行通过。

证据索引：R4/lead/{native-first-pass.json,tool-run-failure.json,move-undo-verification.json,local-red-fixed-result.json,local-green-result.json,viewport-native-result.json,tool-execution-final-result.json,review-summary.json,code-version.json,delivery-r4.json,protection-end.json,final-receipt.json}；gui保留本轮2b4实际状态与截图。旧包/分支/证据不删除。正常推送候选后停在待解锁审计检查点。
