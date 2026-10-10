# D 镜片拖动与节点交互修订候选

2026-10-10 · **UI-PRESENTATION-REBUILD-01** · 生产 **e6413de64889beac0f43d291c9403cbd039d598b**。保留现有布局、材质、输入修复和自适应轮廓。

## 唯一试用入口

[启动聊天当前验收.command](/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261004T145523Z-continuous-closeout/delivery/启动聊天当前验收.command)

指向 [D UI Review e6413de6.app](</Volumes/CodexProjects/Codex/D-Development/AgentTrials/UI-PRESENTATION-REBUILD-01/run-20261010-drag-interactions/delivery/D UI Review e6413de6.app>)。Finder启动后PID28667、实际包路径和原隔离UUID已核实；入口拒绝双开，不覆盖普通D。本轮D窗口读取返回一次`-10005 timeoutReached`，停止原生操作，未认作锁屏。**没有本版真实截图、边缘拖接或手感通过结论。**

原生复查使用已准备的 [Drag review.dproject](</Volumes/CodexProjects/Codex/D-Development/AgentTrials/UI-PRESENTATION-REBUILD-01/run-20261010-drag-interactions/gui/Drag review.dproject>)：文件→打开项目；其“双输入文字模板”只有文字输入、模板和确认节点，无需模型。副本尚未由Agent在本版界面打开，原始项目与会话保留。

## 变化与已验范围

- 镜片：拖动临时状态留在独立控件内；松手才切换，原单镜片、局部折射、非线性回弹与减弱动态效果保留。离屏宿主36次分帧预览注入产生32个中间呈现值，真实工作台根/保留编辑器宿主更新均为0；提交后根更新。此为更新隔离测量，不是原生帧率。
- 端口：输入、输出两端都可起拖，实时曲线；释放在另一兼容端口才按输出→输入提交，既有占用/类型/循环/Undo机制保留。普通点击/键盘端口入口也保留。手型仍用于导航及移动节点，端口连接在指针工具下操作。
- 工具：两种工具都可拖节点；手型拖空白平移，指针拖空白框选。补手形悬停、按下抓握及松手/隐藏/失焦复位。

11项原有相关方法通过；两个新增窗口事件测试在key-window前置失败，零事件，未重试到绿。离屏更新隔离测量通过；方向归一化与既有连接策略定向复验见任务回执。普通构建、独立包签名/沙盒及7文件一致性核对完成，资源增量签名失败和修正过程保留。

## 集中待验

[唯一集中队列](FAILURE_AND_PERMISSION_AUDIT.zh-CN.md)已补实际入口、步骤、预期和证据边界：镜片持续/反向拖动及取消；两方向端口拖接、空处取消、缩放后命中、单次Undo；手型抓握、两工具节点拖动、空白平移/框选及保存重开。Agent未完成的原生验证仍由Agent继续，不把确定实现错误转交用户。

R11的输入/Undo/草稿保存和浅深静态证据仍属aa7ab43f，不能冒作本版重验。未加载模型、未自动发送、未扩权限、模型矩阵、音频/E/收费或搜索。F26继续延期。
