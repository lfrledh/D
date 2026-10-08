# D 开发候选：原生界面第一版

2026-10-08 · **UI-REFINEMENT-01 r4：原生反例已定位并局部修补，新包待复验。** 当前包未启动，未接纳main、未正式发行。具体已验/余项见[当前行动](CURRENT_ACTIONS.zh-CN.md)及[本轮任务](tasks/UI-REFINEMENT-01.md#r4-解锁补验与定向修补2026-10-08)。

## 唯一推荐入口

双击原入口（已原位更新）：
`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261004T145523Z-continuous-closeout/delivery/启动聊天当前验收.command`

只启动：
`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/UI-REFINEMENT-01/run-20261008T121613Z-r3-native/delivery/D Native UI 79f9eb53.app`

代码 **79f9eb53d6c93b18b99bda7a3eb2324e38abcec5**。同树构建通过；实际为既有配置的ad-hoc签名、启用App Sandbox，codesign验证通过，不是Developer ID发行包。4关键文件与构建产物一致，没有手补或重签复制包。其后只更新交接文档，最终文档SHA见R4/lead/final-receipt.json；不声称在文档提交上重新构建或测试。

入口使用隔离偏好`B7DA6B57-4CE1-49DF-9917-59FA18A8870F`；已有D时拒绝双开，不关闭你的App。旧8cf功能基线及02df等历次候选保留，不是另一份推荐入口。本轮已打开旧2b4作独立原生检查并正常退出；新79f构建后再次锁屏，尚未执行新包入口。

## 不运行模型的试用

通过“文件→打开项目”打开专属副本：
`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/UI-REFINEMENT-01/run-20261008T121613Z-r3-native/gui/UI acceptance.dproject`

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

以下是旧02df/10ee包的原生截图，不是网页原型；全部数据为隔离夹具。它们说明沿用的界面布局，不能证明r3阅读恢复、fit或拖放已经原生通过。本轮2b4真实操作截图在R4/gui；旧布局截图不代表79f修补已验。

![02df6f1c：窄窗聊天、左模型参数与底部输入](images/ui-refinement-chat-02df6f1c.png)

![02df6f1c：两侧收起、固定图像结果与缩放](images/ui-refinement-image-02df6f1c.png)

![10ee7b9c：真实框选两个节点；02df相对10ee仅改文字页标签](images/ui-refinement-canvas-10ee7b9c.png)

## 已验与仍需检查

- r4定向检查：8个UI组件/几何方法通过；2个Controller/Store方法通过，包括空/Unicode文字封装实际调用、资产内容与重开。阅读与祖先resize的新增断言在旧实现先失败。原viewport窗口方法仍停在visible/key/host前置，不能写为通过。代码/测试精确对应见R4/lead/code-version.json。
- 2b4普通App：节点移动→单次Undo、点击端口建边、两栏收起后fit通过；长文分类往返和既有文字工具invoke失败，促成本轮79f修补。Finder和端口拖动缺有效命中证据，未当作产品根因。
- 新79f仍需：长文内部阅读点分类/模式往返；新建正确接口的工具实际调用与冷重开；面板过渡fit、稳定后一击及不重排。旧`Two text inputs v1`保留错误接口，需编辑副本/另存工具，不会静默迁移。
- Finder左侧/空白松手→附件/预览/保存冷开仍未完成；大字号、轻量、系统辅助显示保留。无需重复真人输入法/语音或模型生成。F26继续延期。
- main保持91bef旧已验基线，新组合未通过完整原生验收，不宣布最终UI或发行通过。

R4证据根：`D-Development/AgentTrials/UI-REFINEMENT-01/run-20261008T121613Z-r3-native`。`lead/native-first-pass.json`、`review-summary.json`、`code-version.json`、`delivery-r4.json`、`protection-end.json`及`final-receipt.json`记录原生、审核、版本、包、保护与远端。旧r2/r3证据保留、按未变范围复用，不累计为本轮通过率。
