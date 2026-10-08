# D 开发候选：原生界面第一版

2026-10-08 · **UI-REFINEMENT-01 r3：无需桌面的实现与验证完成，同版原生候选待验。** 当前包未启动，未接纳main、未正式发行。具体已验/余项见[当前行动](CURRENT_ACTIONS.zh-CN.md)及[本轮任务](tasks/UI-REFINEMENT-01.md#r3-锁屏条件下连续收口2026-10-08)。

## 唯一推荐入口

双击原入口（已原位更新）：
`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261004T145523Z-continuous-closeout/delivery/启动聊天当前验收.command`

只启动：
`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/UI-REFINEMENT-01/run-20261008T045623Z-r3-no-desktop/delivery/D Native UI 2b4b9ad2.app`

代码 **2b4b9ad2215fa6f191ce43f0baf6848549e924f7**。同树构建通过；实际为既有配置的ad-hoc签名、启用App Sandbox，codesign验证通过，不是Developer ID发行包。4关键文件与构建产物一致，没有手补或重签复制包。其后只更新交接文档，最终文档SHA见R3/lead/final-receipt.json；不声称在文档提交上重新构建或测试。

入口使用隔离偏好`B7DA6B57-4CE1-49DF-9917-59FA18A8870F`；已有D时拒绝双开，不关闭你的App。旧8cf功能基线及02df等历次候选保留，不是另一份推荐入口。本轮按用户桌面不可用条件未执行启动器，也未创建App或Finder窗口。

## 不运行模型的试用

通过“文件→打开项目”打开专属副本：
`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/UI-REFINEMENT-01/run-20261008T010729Z-no-desktop/gui/UI acceptance.dproject`

带24节合成长文、固定图片/视频/音频和测试图。展示记录注明**受控媒体展示记录，不是模型执行结果**；没有为本轮重新生成。text:fixture不是可运行模型；未选真实模型时就绪失败/生成不可用属于夹具预期。

1. 顶部文字/图像/视频/音频筛选；右上圆钮切快速/工作流或开设置。
2. 文字左栏是模型与下一次参数，切“Conversations/会话”管理会话；右栏是资料/成果，底部仍是原输入器。面板可收起。合成长文可浏览、搜Section、点可见链接再取消；不要把文本夹具发送给模型。
3. 图像/视频固定在中央，收栏后扩展；前后按钮或右侧选择候选。图片放大/拖动/适配只改预览，视频保留时间轴/原音轨。结果详情关闭后可再开设置。
4. 画布“指针”在空白处框选，再从卡片非控件区一起移动；“手形”只平移。选端口也可点击输出再点击输入连接。删除及Undo、原有封装仍在；右下两个视图操作均不重排节点。面板过渡期间，“适配全部”暂时禁用，实际视口到达目标宽度后才可用；此新时序仍需原生操作复验。
5. 齿轮与Cmd-,共享分类/目标。外观可改浅深色、背景通透、动效及轻量模式；模型参数不放在全局设置。网络/凭据只是现有服务入口，F26真实调用仍延期。

## 同树 Xcode Run

打开 `/Volumes/CodexProjects/Codex/D-Worktrees/D-UI-REFINEMENT-01/D.xcworkspace`，选 **D Nodes / My Mac / Debug**。

本机`Development/Development.local.xcconfig`沿用现有构建设置，资源为：
`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261004T041401Z-chat-resume/delivery/resources-with-python`

正常构建阶段嵌入已有引擎，不需要手补App或重复下载。命令行同树构建已通过；本轮没有点Xcode Run或验证模型。换机依[开发资源说明](../Development/README.md)，本包不是已完成首次分发验证的安装包。

## 复用的r2真实截图

以下是旧02df/10ee包的原生截图，不是网页原型；全部数据为隔离夹具。它们说明沿用的界面布局，不能证明r3阅读恢复、fit或拖放已经原生通过。本轮没有探测桌面或补拍截图。

![02df6f1c：窄窗聊天、左模型参数与底部输入](images/ui-refinement-chat-02df6f1c.png)

![02df6f1c：两侧收起、固定图像结果与缩放](images/ui-refinement-image-02df6f1c.png)

![10ee7b9c：真实框选两个节点；02df相对10ee仅改文字页标签](images/ui-refinement-canvas-10ee7b9c.png)

## 已验与仍需检查

- r3：29方法/5套件通过，包含阅读状态归属/失效、fit测量、端口实例、拖动值逻辑及隐藏文件接收；另1方法通过真实Controller封装、保存、Store重开和边界编译。没有窗口、真实拖放或模型运行。隐藏接收反例先失败后通过；测试快照与2b4代码对应关系见R3/lead/validation-summary.json。
- 复用历史：10ee普通App框选/多移Undo/手形/点击连接/删除恢复/封装创建，以及02df冷开草稿、窄窗、固定图像与视频、设置返回结果保留。r2的12项纯值、3项hosting及r1的59项不累计为r3通过率。
- 待原生路径一：现有24节长文离底→分类/模式往返→原段落恢复；Finder左侧及空白真实松手→附件预览→保存冷开、源文件与无发送保护。沿途补大字号、轻量及系统辅助显示检查。
- 待原生路径二：端口实际拖连/拒绝、节点移动提交/Undo、封装调用与保存冷开；面板过渡时fit禁用、稳定后一次适配且节点不重排。旧viewport方法15处失败及随后visible/key前置失败原样保留，未删断言、未将前置失败认定为锁屏；该窗口方法仍待执行。
- 不需要你现在操作，不重办语音、HF、宏信任或搜索凭据；F26继续明确延期。main保持91bef旧已验基线，新组合待验，不宣布最终UI或发行通过。

R3证据根：`D-Development/AgentTrials/UI-REFINEMENT-01/run-20261008T045623Z-r3-no-desktop`。`lead/validation-summary.json`、`review-summary.json`、`delivery-r3.json`和`final-receipt.json`分别记录检查、审阅、包与最终版本。r2历史原生结果继续在`run-20261008T010729Z-no-desktop/lead/native-results.json`，不覆盖旧证据。
