# 当前行动与接手点

最后核实：2026-10-09。唯一活动任务为 **UI-PRESENTATION-REBUILD-01**，本聊天新原生 UI Lead 持有公共展示、集成与验收。首个切片已实施并有原生截图，供反馈；原生回归未齐，不宣布UI验收完成。

用户拒收旧界面，授权重组展示层而非重写 D。首轮直接完成公共外壳与真实聊天切片，原生自检/行为回归后交用户评审；其他模态只检公共导航，不扩模型、E、音频编辑器、收费或发行。

## 基线与保护

- 新树 `D-Worktrees/D-UI-PRESENTATION-REBUILD-01`，分支 `codex/ui-presentation-rebuild-01`，起点 **6abf4e1d4a1d1b6cd0cd454c338920a681e6d1e0**，接手时该基线本地/远端一致。包含79f阅读、fit与封装修补。
- 旧 Lead 聊天为 notLoaded、末轮回执明确自有作业结束；本次无相关构建/写Worker进程，旧UI树及索引干净。无未交接差分。旧树不再写入。
- 源 `codex/inference-foundation` 保留01758b81527dc27eb4563bf1b66fd1ceab6647ee；个人scheme未暂存 orderHint 1→6、SHA256 ca3635d88aa5a15397b90e528667c66c0e6db7e596176e885c79d194b544206c、index 9c76916bdc97c2d4298cefe64e0b0fae3380573e 原样保护。main仍91bef7d720a8b6cb923207ef787230f36496f4cf。
- 保留模型、Runtime、Store、原生输入/Undo、阅读与数据保护。保留行为不冻结旧View容器和尺寸。私人失败截图只在外盘证据区。

## 当前动作与证据

公共顶部、浮动侧栏、真实聊天输入组件已重组。生产代码 **a226008435f6ad52599b68b85d58c62228167e30**；该版普通构建通过、独立App签名及关键文件核对通过。已亲见深色空会话、短草稿Undo/Redo及半屏30行草稿；留存原图，非网页替代原生。完整宿主尺寸、原生输入身份/marked text/Undo、接收命中、受控流Stop/drain与阅读票据检查分别记录，不能覆盖原生缺口。

原生工作于2026-10-09被 `SCStreamErrorDomain -3812`（参数无效）中断；立即暂停，不轮询、不提权、不改变策略。保留当时隔离候选与草稿。待桌面可用后只续[集中队列](FAILURE_AND_PERMISSION_AUDIT.zh-CN.md)，不重开旧失败预算。下一步仍是本切片同状态对照与相关原生门槛，不进入下一产品阶段。

任务正文与验收：[UI-PRESENTATION-REBUILD-01](tasks/UI-PRESENTATION-REBUILD-01.md)。证据根 `D-Development/AgentTrials/UI-PRESENTATION-REBUILD-01/run-20261008-first-slice`（下称R），接管 `lead/takeover.json`、包 `lead/delivery-review.json`、桌面停点 `lead/native-pause.json`；`delivery/原生UI首片评审.html`汇总真实图与原型差异。[唯一试用入口](RELEASE_FREEZE_TRY.zh-CN.md)指向a2260084；早期候选仅留作恢复，不再推荐。

## 继承与原位归档

[旧UI任务](tasks/UI-REFINEMENT-01.md) superseded-as-active：部分实现/通过证据保留，展示结果被拒收。“79f未启动”是旧回执当时的事实；接手原生阶段发现用户已开79f，保持其进程和项目，未退出或覆盖。长文往返/fit/新建封装原生待复验；端口与Finder真实拖放命中未定；viewport宿主前置失败保留。其余转入集中队列，F26继续批准延期。

旧当前行动/集中队列全文固定存档与离线读法见[历史索引](history/README.md#ui-presentation-takeover)。旧成功、失败、预算与本人已关闭事项不追改，不自动授权旧实验续跑。常驻规则继续有效。
