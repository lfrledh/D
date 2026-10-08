# UI-REFINEMENT-01 — 第一版原生工作台

状态：r2补齐聊天分工、设置路由、系统玻璃与本地化，已补部分普通App验收；组合余项明确保留，未接纳main。当前结果见文末“r2 无桌面补齐及解锁验收”，前面r1是历史。规格 r1＋2026-10-08续作附件；用户任务包 v1.0、设计 v0.3、交互原型 v0.2（2026-10-08）。

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
