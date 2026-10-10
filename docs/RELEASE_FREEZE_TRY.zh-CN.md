# D 输入修复与自适应轮廓候选

2026-10-10 · **UI-PRESENTATION-REBUILD-01** · 生产 **aa7ab43fb85445454af0e0aadac010c3489e76a3**。修复输入及留白点击；单行紧凑胶囊，多行连续曲率圆角矩形。保留已认可布局、功能归组、长输入上限和内部滚动。

## 唯一试用入口

[启动聊天当前验收.command](/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261004T145523Z-continuous-closeout/delivery/启动聊天当前验收.command)

现指向 [D UI Review aa7ab43f.app](</Volumes/CodexProjects/Codex/D-Development/AgentTrials/UI-PRESENTATION-REBUILD-01/run-20261010-composer-repair/delivery/D UI Review aa7ab43f.app>)，已启动PID25593，路径及原隔离UUID核实。入口拒绝双开，不覆盖普通D。当前现场位于独立副本的可编辑测试会话，两栏展开、三行中文草稿。

如冷启动仍选中原来的已删除会话，会明确显示只读说明及“恢复会话／新建对话”。不会自动撤销删除。也可通过文件→打开项目选择 [Composer review.dproject](</Volumes/CodexProjects/Codex/D-Development/AgentTrials/UI-PRESENTATION-REBUILD-01/run-20261010-composer-repair/gui/Composer review.dproject>)，打开已有测试会话。原始项目和副本原有三个会话不变，新草稿没有发送。

## 本轮实际结果

- 同版实际点击左留白、编辑器右缘后键入，Command-Z/Shift-Z；单行、多行、30行增高上限和滚轮通过。归档→恢复→再输入与Undo通过；正常退出后的草稿重开保留。
- 浅深主题、1080点双栏及收栏原生已查看。摘要/记忆两框的旧静态待看已补；临时文字撤销，未保存记忆。恢复跟随系统/14pt，其他偏好保持。
- 11个唯一相关测试最终通过，最后增长/收缩/Undo与命中2项复验通过；旧初测失败保留。最终普通构建27.71秒、严格签名/App Sandbox及7关键文件匹配；非实现者复看三图无静态阻断。

[单行紧凑胶囊](</Volumes/CodexProjects/Codex/D-Development/AgentTrials/UI-PRESENTATION-REBUILD-01/run-20261010-composer-repair/gui/07-final-single-line-aa7ab43f.jpg>) · [多行连续圆角](</Volumes/CodexProjects/Codex/D-Development/AgentTrials/UI-PRESENTATION-REBUILD-01/run-20261010-composer-repair/gui/06-final-multiline-aa7ab43f.jpg>) · [双栏工作面](</Volumes/CodexProjects/Codex/D-Development/AgentTrials/UI-PRESENTATION-REBUILD-01/run-20261010-composer-repair/gui/11-final-both-sidebars-aa7ab43f.jpg>) · [深色及摘要/记忆编辑区](</Volumes/CodexProjects/Codex/D-Development/AgentTrials/UI-PRESENTATION-REBUILD-01/run-20261010-composer-repair/gui/09-final-context-dark-aa7ab43f.jpg>)。以上均为最终aa7ab43f真实原生图；未重绘。

滚动条thumb拖动未取得可确认位移，仍待验；不以滚轮通过代替。原生输入法候选交互、Finder拖放、模型停止/阅读往返和旧复杂镜片动效保持独立边界，本轮未加载模型。统一余项见[集中待验清单](FAILURE_AND_PERMISSION_AUDIT.zh-CN.md)，无需逐项反馈。

## 新入口

- **左侧“本会话设置”**：模型与常用预设、回答方式、上下文与记忆、会话整理、高级模型设置。当前规则只影响以后请求；预设在此应用，在设置统一管理；支持的其余参数仍在高级入口。
- **右侧“资料 / 成果 / 工具”**：资料负责查找与采用；成果负责已保存回答及可编辑内容；工具先选计算/换算/分析/联网或MCP任务，再看对应输入和结果。切页保留编辑状态，不自动运行。
- **消息“更多”**：继续讨论、回答版本、保存交接、朗读、查看详情按分隔线归组；历史详情读取当次快照。对话列表菜单可进入“会话整理”。
- **齿轮 / Command–逗号**：同一设置。发送键在“操作”；默认规则与当前项目预设在“聊天默认”；朗读声音/速度在“声音”；路径、下载与备份在“文件与模型”；凭据在“网络与凭据”。识别语言仍留在语音输入，应用语言独立。

## 版本与保护

5ac3353c为被反馈输入问题的前轮功能归组版本；原生复现其已删除会话显示普通只读输入框。a7a4ea3a为本轮中间版，02–05图归该版；aa7ab43f进一步保护原生滚动条区域，06–11为最终版。旧R10证据保留，不混写成当前通过。

R11证据位于外盘 run-20261010-composer-repair/lead。原始UI review.dproject全部75文件摘要相同，副本旧三个session与presets完全一致，仅新增本轮测试会话。源01758b81/main91bef7d7和个人scheme原样保护；唯一活动任务不变，F26继续延期。

## 同树 Xcode Run

打开 /Volumes/CodexProjects/Codex/D-Worktrees/D-UI-PRESENTATION-REBUILD-01/D.xcworkspace，选 **D Nodes / My Mac / Debug**。本轮普通构建成功，未点击Xcode Run。沿用既有签名及外盘资源，详见[Development](../Development/README.md)。
