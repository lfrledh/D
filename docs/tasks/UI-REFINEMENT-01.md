# UI-REFINEMENT-01 — 第一版原生工作台

状态：实现与非交互检查已交付，组合原生验收因再次锁屏待续；未接纳main。规格 r1；用户任务包 v1.0、设计 v0.3、交互原型 v0.2（2026-10-08）。

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
