# 当前行动与接手点

最后核实：2026-10-03。当前任务、基线、候选、阻塞与下一动作只从本页进入。历史记录不自动授权续跑。

## 当前授权：完整文字聊天专题 CHAT-PRODUCT-20261003

用户已批准 F01–F36、S00–S06 同一批实施。唯一功能状态见 [聊天清单](CHAT_FEATURE_LEDGER.zh-CN.md)。先 S00 长流/停止、正常项目包选择和新候选/旧参数重现，再 S01 布局、S02 编辑与上下文、S03 资料/记忆/备份、S04 联网工具、S05 受限代码/MCP/成果/语音、S06 组合验收。可靠切片通过普通 App 门槛后正常接纳 main，不以整个专题完成为前提；不硬合失败长流。

本轮核实候选 `40d51ee73f72eb54407e6eedbd693c9ba67068e4`、main `f31dced209855722d2f04cc0fc8c5f6712396120` 均干净且与远端一致。旧 inference-foundation 与个人 scheme 不动。A、H22、菜单、宏信任、HF 及自然视频本人结果复用；新存储和聊天宿主按影响另验。旧 B 失败和已耗预算保留；用户现明确批准这些已知缺陷继续收口，不再沿用旧停工排程，不伪造旧预算未使用。

Lead 持有共享 Runtime/WorkflowServices/ChatController/Store；文件面板和纯展示可在独立受限任务树实施。当前活动和精确进程记录在本轮证据目录：`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261003T115108Z-chat-product`。完整 Lead 成本与订阅费用 unknown。尚未完成任一新切片；本页不宣称聊天全范围或功能冻结通过。

## 历史：先修可靠性，再加入最小聊天（2026-10-03，已被上述新授权替代）

用户批准继续同一 D-RELEASE-FREEZE-01，起点 main/candidate `3a2801abab22273256923ce1f3c14407515f20ce`。批准顺序：A1 普通沙盒备份与独立恢复、A2 冷启按需模型就绪 → 两项真实 App 门槛通过并独立接纳 main → B 最小文字聊天；Q 视频质量独立。**A 的 G1/G2 已通过，独立修补基线 f31dced209855722d2f04cc0fc8c5f6712396120 已接纳并推送 main；B隔离候选原生验收部分通过、长流失败，暂停接纳**；下列上一批停点是历史事实。A受测8511718c472e788a8dcfc088eea0fde9dad050b3；独立原生证据RC/lead/a-native-gates.json、集成回执RC/lead/a-integration.json。B包含常驻四分类，文字为聊天，另三类复用；Q固定自然样本获本人确认，未宣称全部质量或冻结通过。

当前 B 已完成实现、CPU和普通签名构建，但**原生长流可靠性未通过，暂不接纳main**。实际App/原生版本`7754a2b70f3e761ef30b45fe3c5ba76bf12b817a`，与CPU受测`55fcbaa74921007a3768ed8d94a4c896e2989297`只有文档差异。定向DWorkbench45方法/5suite、UI呈现5方法复用，不重复计数；本人启用固定EquatableMacros后构建exit0/79.033秒，没有跳过宏校验。四分类实际可达，图像/音频/视频控件与草稿往返已核；新聊天完成Qwen3.5-9B Q4的TXT+PNG多轮、编辑产生分支、旧路径返回、系统预设、回答存素材并显式送Canvas。没有以量化GUI样例代替原始精度或27B验收。

最新缺陷：两次长回答均因`consumerTooSlow`结束为partial，分别保留633/562字符；不是length正常结束，也没有证明原生停止成功。切会话控制调用曾迟滞56.30秒；disk选中叶正确，旧AX内容只是未滚到底，不能误判分支丢失。Runtime沿用256事件有界队列，WorkflowServices在MainActor消费/更新预览；具体迟滞来源尚未通过时序定位，不归咎模型或16GiB。没有扩缓冲、降低断言或新增补丁。core初交+两修复及唯一Lead接管已使用，UI剩一轮普通修复；本缺陷跨消费/界面边界，不能擅自当作UI额度继续改Runtime。证据RC/lead/b-native-long-stream-failure.json。

本人集中事项已办理：宏信任、Qwen登记、切回聊天及取消当时的Go To/导出面板均完成；本人观察可能存在自动操作重试叠加；两份新的LTX/H3自然视频本人确认正常，固定样本质量通过，旧近静音首异常层仍未知。H22/菜单/资格不重开。改为逐步确认一个文件面板后，普通App的Markdown/纯文本导出、聊天备份→独立恢复→冷重开通过：2会话、9消息、5次尝试及6份资产保持，含失败部分回答与新的未发送Unicode草稿；原件/备份不变。长Markdown合成样例的表格、公式、代码块、跳底、原文复制通过；不是模型输出质量。证据RC/lead/b-native-final-acceptance.json。

保留另一个原生限制：冷重开时列表中的.dproject呈灰色；输入完整路径后Open启用且成功打开。非实现者核对A/B面板代码、Info.plist和文件类型/权限无差异，原因尚未定位；不能把数据恢复通过写成所有文件入口通过。原生停止、视频附件往返、最小尺寸设置/非法数值往返及聊天宿主真人组字仍未验，不重开已关闭的H22。当前没有必须本人立即办理的事项。

**停点**：B长流门槛失败，不接纳main；按已耗core预算不再自行追加修改，UI剩余额度不能覆盖共享消费者问题。下一最小项是定位事件消费/主线程迟滞并有限修补，再验长流与停止；文件面板只做对应的选择过滤诊断。待用户审计后决定该有限续修，当前不启动。B审计包保留，A为唯一推荐稳定入口，main仍`f31dced209855722d2f04cc0fc8c5f6712396120`。本次仅追加记录；最终候选/远端SHA见RC/lead/b-native-closeout-receipt.json。自有95339/96335/96473均正常退出，当前无D进程，自有Finder窗口关闭；Terminal受工具策略限制未操作。源个人scheme、App四关键文件和原始小项目/备份保护见同一回执。
证据 RC=`D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261003T035843Z-stabilize-chat`。H22/菜单/失联恢复保持，不重复本人操作；旧失败和预算保留。新增有限续修及角色、范围、门槛见任务记录末节。没有新的登录或模型资格事项；不发布 Release。

## 上一批历史停点：D-RELEASE-FREEZE-01 / D-DISCUSSION-FREEZE-20261002

**集中本人操作已办理；有限原生收尾部分完成。** H22按本人复验关闭，模型嵌套菜单修补通过本人操作。MRT2引用/独立复制、Quick失联文件恢复/收纳/冷重开、Canvas草稿保存重开已完成。原生手动备份返回I/O失败，独立恢复未验；不再以锁屏或权限审批解释工程缺口。当前无需新增登录、组字或试听，集中清单见[唯一待办](FAILURE_AND_PERMISSION_AUDIT.zh-CN.md)。

- 本次起点main：`a3c5b091de6e5af5bad0a1365d09ff80306d0cef`。
- H22修补/本人受测：`9baaacbc74855aaa84fa03868e62a1676d882250`；菜单修补/本轮最终App及原生受测：**`35f373ad4973a0f1dee91c68ddb9f440f25c6520`**。后续仅文档和真实截图；最终候选、main/远端完整SHA见RH/lead/final-receipt.json，不把文档SHA写成重新执行测试。
- 实施与同树Xcode：`/Volumes/CodexProjects/Codex/D-Worktrees/D-RELEASE-FREEZE-01`，`codex/release-freeze-01`；main接纳树同级`D-DISCUSSION-MAIN`。唯一推荐启动器、同树D Nodes Run见[试用指南](RELEASE_FREEZE_TRY.zh-CN.md)。旧候选保留，不自动接纳AP1/CORE/I2V。
- main为公开开发集成线，获准经相称检查正常快进/推送；公开主线、试用、功能冻结、发行分开。旧main备份已在前轮完成，不重复，不强推、不改许可证、不发Release。
- 保护源`/Volumes/CodexProjects/Codex/D`仍为`codex/inference-foundation@01758b81527dc27eb4563bf1b66fd1ceab6647ee`。个人scheme orderHint1→6未暂存，SHA256`ca3635d88aa5a15397b90e528667c66c0e6db7e596176e885c79d194b544206c`；结束保护与进程核对见最终回执。

RH=`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261003T015601Z-human-closeout`。
RN为同级`run-20261002T160047Z-native-closeout`；R=`run-20261002T062206Z-discussion`；R4=`run-20261001T162316Z-r4`；R3=`run-20261001T040512Z-low-memory`。大日志/产物不入Git。

## 历史批次的已完成、失败与未验

| 范围 | 当前证据 | 结论边界 |
|---|---|---|
| H22 | Quick多行字段复用已有原生编辑器，固定draft/field所有者；先红后绿，UI5/Quick19通过；本人确认组字可用、鼠标不再闪回 | 候选窗不随动经本人Finder对照接受为当前系统行为；不是所有系统/输入控件保证，不重复要求本人 |
| 原生模型菜单 | 35f373仅跳过完整相同的ModelLibrarySnapshot发布，保留真实状态变化；本人确认高亮/选择/文件面板正常 | 本次FILES有限Lead接管已使用，旧失败不抹去 |
| 模型引用/复制 | MRT2外部登记后复制6个必要文件至独立模型库，逐文件摘要一致、inode独立，ordinary-note.txt留在原件不进安装；本人完成隔离设置资格声明；Quick/Canvas当时均可用 | 没有重新推理。冷启动仍显示未知/待核验，现有完整资料库sheet才触发显式校验；非35f补丁引入，仍需改进初始化接线 |
| F1/F2原生 | Quick原位导入88字节PNG，另有命名Canvas；只移动本轮夹具后从Quick条目直接到缺失位置页，同内容重定位、Finder显示、复制入项目、正常退出重开/核对通过 | 原件与项目副本摘要一致、独立inode，Canvas没有串入Quick素材。只验证该小文件，不代表NAS/全拖放矩阵 |
| 备份/恢复 | 未保存Canvas标记在备份预检中保存；NSSavePanel后报`ProjectBackupError error 4`，未发布备份，正常重开文字保留 | error4为io关联错误，但UI隐藏具体操作/errno；最强源码风险为仅有target授权却在parent建兄弟stage，restore同类。本轮不追加第三轮或另一Lead接管。原生独立恢复未执行 |
| CPU/构建 | H22 UI5/Quick19；菜单UI2（含Quick组字）/ModelLibrary64/Readiness2分别通过。普通签名35f构建exit0，50.3787秒；非实现者分别审核 | 不相加成全套通过率。前轮RN UI18/Workbench42复用，未改文件服务。两项旧offscreen hosting失败保留 |
| README | EN→中文、双语标题/页内跳转；新增35f真实脱敏Quick截图，截图保留冷启待核验状态 | 不是模拟画面，不凭截图判生成或冻结通过；本次未在Xcode GUI点Run |
| 视频质量 | 本人：H3文生正常，LTX无声/红块持续，H3合成首尾难判断。只读PCM核实近静音；上游candidate已含红块，D没有后叠图；条件CRF33不是33帧叠加 | 未定位所有质量原因，未做新自然首尾生成/试听，不判模型固有限制。质量任务需下一有限修复，不重问旧样本 |

## 历史批次的预算、保护与恢复

本次FILES续修受限Sol/high初交+两次修复完成入口/核对/展示；Lead一次有界接管用于本次菜单。该额度已使用，新备份失败仅定位留证；原FILES-UI更早耗尽历史不刷新。H22为本人反例后批准范围内的Lead定点修补，非实现者审核；不能归为Sol独立通过。完整Lead用量/订阅费用unknown，不重算旧样本。

所有本轮Worker/CPU/build结束；自有测试App已正常退出，Finder自有窗口关闭。旧重复启动事故已留证并处理，不把归档当终止。工具不允许控制Terminal，因此无法确认/关闭启动器终端窗口，必要时本人关闭标题对应已完成窗口，其他终端不动。准确PID、App摘要、个人scheme内容/索引/状态见最终回执。

恢复先核真实HEAD/index、保护对象、运行状态与回执，不按聊天猜版本。本次只移动合成reference.png，模型源/旧项目/旧App/候选/外盘证据保留；不清理。

**下一最小工程项**：针对备份目标授权/同卷临时发布及可解释错误作有限修补，并补普通App备份→独立恢复；同时明确冷启就绪刷新触发。需延续旧失败、明确新增有限预算，不能绕过沙盒。视频质量继续保留独立证据，不为同一提示盲目重跑。

**本轮停在用户试用与冻结判断。** 当前不是功能冻结通过或正式发行；没有新增聊天/富文本/联网/模型平台。Pitch内部评估权重、无权重分发、首次使用/依赖封装/升级恢复/渠道等[发行责任](MODEL_SUPPORT_AND_RELEASE.zh-CN.md)继续保留。
