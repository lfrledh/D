# UI-REFINEMENT-01 — 第一版原生工作台

状态：实施中，未接纳。规格 r1；用户任务包 v1.0、设计 v0.3、交互原型 v0.2（2026-10-08）。

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

## 恢复点

已完成：任务包/截图与实际入口核对；main与候选91bef干净、远端一致；独立集成树创建。未完成：实现、组合检查、普通App与交付。当前有效r1；无新模型任务。下一动作：核实两名受限实现者预检，Lead准备壳层。
