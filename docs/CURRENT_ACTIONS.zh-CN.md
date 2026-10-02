# 当前行动与接手点

最后核实：2026-10-03。当前任务、基线、候选、阻塞与下一动作只从本页进入。历史记录不自动授权续跑。

## D-RELEASE-FREEZE-01 / D-DISCUSSION-FREEZE-20261002

**本轮有限续修已到交付检查点，整体部分完成。** 文件入口/核对范围的工程修补与相称CPU检查通过；H22未形成真实IME候选，不虚构根因或改文本系统。桌面开始可用，完成旧同代码包的隔离准备；新包连接时再次明确锁屏，剩余原生操作与真实README截图保留。main可以按已批准开发门槛正常推进，功能冻结/正式发行尚未通过。

- 起点main：`9586e35f6e3e2bb4c47432f2fa3132ab7c7b55a8`。
- 本轮生产代码/正常签名App：`1e2501faed39fab954bbb205bc556ea537916219`。最终CPU受测：`43d6ab3e51583a31e7c8a08ac60911a6be9ddcce`；两者仅新增测试夹具修正，产品代码一致。后续仅文档，最终main/远端SHA见RN/lead/final-receipt.json，不把文档SHA冒充重新执行过测试。
- 实施与同树Xcode：`/Volumes/CodexProjects/Codex/D-Worktrees/D-RELEASE-FREEZE-01`，`codex/release-freeze-01`；干净main接纳树为同级`D-DISCUSSION-MAIN`。唯一启动器及D Nodes Run见[试用指南](RELEASE_FREEZE_TRY.zh-CN.md)。旧候选保留，不自动接纳AP1/CORE/I2V。
- main是唯一公开开发集成线；旧main归档与六个旧gitlink bundle已在前轮完成，本轮不重复、不强推、不改许可证、不发Release。
- 保护源`/Volumes/CodexProjects/Codex/D`仍为`codex/inference-foundation@01758b81527dc27eb4563bf1b66fd1ceab6647ee`。个人scheme orderHint1→6仍未暂存，SHA256`ca3635d88aa5a15397b90e528667c66c0e6db7e596176e885c79d194b544206c`；索引/旧App/原件保护以最终回执为准，不切换或整理个人源。

RN=`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261002T160047Z-native-closeout`。
R为同级`run-20261002T062206Z-discussion`，R4=`run-20261001T162316Z-r4`，R3=`run-20261001T040512Z-low-memory`。

## 已完成与未闭合

| 范围 | 已实现/本轮证据 | 尚未证明 |
|---|---|---|
| F1直接恢复入口 | 资料库条目独立位置动作不先pin/预览原件；Quick与命名Canvas按Store+instance区分，顶栏按当前入口；文件模态阻止隐藏生成，预览失败保留恢复入口 | 新包中“失联Quick+独立Canvas→定位→收纳→重开”完整原生序列待解锁 |
| F2核对范围/时间 | 默认概览轻检；选项深检与显式核对只读目标；摘要/长度/前后fingerprint和项目revision一致后更新lastVerifiedAt。验证后Session只更新元信息，不二次散列全媒体；实际内容变化仍刷新。失败/取消不记成功 | CPU/接线反例通过，不等于原生点击/NAS/无限规模性能 |
| F3已知位置 | 本项目graph/node、派生资产与运行来源展示；图已加载时可导航，运行记录标不直接导航；Finder入口、已登记库离线聚合、原件/副本时间分开 | 仅已知范围，非全磁盘/跨软件索引；本轮原生点击待验 |
| 文件CPU/构建 | `files-cpu-final`：UI18、Workbench42均通过；原始失败保留。普通签名App build exit0，未构建后手补provider；独立非实现者审阅修补与测试 | 两项旧offscreen hosting失败未重跑/未抹去；新包可见操作未完成 |
| 原生已做 | ca2121c包与起点9586产品代码相同：登记模型库根、NSOpenPanel原位引用小PNG、NSSavePanel创建命名Canvas、保存、正常退出；均仅任务夹具 | 模型嵌套菜单自动操作未完成登记。此准备不是1e2501f新包F4通过；新包process启动后CUA返回Mac locked，自有新进程已结束 |
| H22 | 15次实际client/context观察一致；现有trace调用由同PID符号化到NSHostingView.cursorUpdate→NSCursor.set，未截断；无新增日志装置 | CUA按键没有marked text或自然firstRect，不是IME复现。A候选/B指针根因未定、未修；C未在D复现。需实体键盘最短触发 |
| README | 唯一全文改成同页EN在前/中文在后，小字引导、双语标题、显式锚点；旧中文页兼容跳转。源码/链接/构建说明非实现者复核 | 真实当前原生脱敏截图未取得，随H32补。GitHub桌面/窄屏观察见最终回执，不假称已有图片 |
| 模型与质量 | 计算代码未改，沿用cd4cd4b的Qwen9原始精度SSD四帧、Klein BF16取消/完整/有序参考及R3/R4 Dev/H3/LTX/ACE/Wan有效结果；原MP4和全部帧证据保留 | 本轮没有新GPU/试听。LTX红区域/H3合成尾帧跳变原因及一般控制质量未定，不改称模型固有限制 |

模型导入/必要树64项、Qwen/Flux35项、图像目录23项及备份等旧证据只按未变路径复用，不相加虚构本轮通过率。完整版本/命令/失败和修复来源只见[原任务记录](tasks/D-RELEASE-FREEZE-01.md)最新段。

## 唯一集中待办与下一动作

[集中待办](FAILURE_AND_PERMISSION_AUDIT.zh-CN.md)维护H22实体组字/指针、H32解锁后代理可自行完成的原生操作/截图，以及四份旧视频的本人质量判断。H31账号/下载和已办录音、离线、Xcode事项不重开；没有状态变化不重复探测锁屏或催问。

同版App启动器不会关闭另一份D；用户试用前自行保存退出旧App。诊断默认关闭。新包已启动进程但未取得窗口/点击证据，未在Xcode界面点Run；不要写成“原生验收通过”。

## 预算、恢复与停止

旧FILES-UI初交/两修复/Lead接管历史不变。本次用户明确批准的新有限续修由受限gpt-6-sol/high初交+两次修复完成，Lead未实质重写实现；非实现者静态复核及Lead实际CPU/构建分开。repair1解决旧深检回归、全媒体二次读取和项目副本移出角色；repair2仅修测试的未同步前置状态。无剩余普通修复，本次有界Lead接管未使用。权限/模型路由及异常逐轮已查，无成功越界证据；隐藏解析和完整Lead/订阅费用unknown。

恢复先核真实HEAD/index、个人文件、活跃句柄/已知写入者及App摘要；当前受限Worker/CPU/build已结束，自有测试进程终态见RN/lead/final-receipt.json，旧D未关闭。保留模型/项目/候选/证据，不清理。不通过重复生成或新抽象掩盖未验。

**停在用户试用与冻结判断。** 不增加聊天/富文本/联网/模型平台；Pitch内部评估权重、无权重分发、首次使用/依赖封装/升级恢复/渠道等[发行责任](MODEL_SUPPORT_AND_RELEASE.zh-CN.md)继续保留。
