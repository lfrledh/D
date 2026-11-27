# 当前行动与接手点

更新：2026-11-27。上一轮Qwen官方设置、I012/I017有限调查与低内存补验已形成 **b712c80cac5fac7946d94b466b5d6acfb47e70ec** 交付点。本轮串行实施用户批准UI文本第1–20组，归I013；21–40未批准、不实施。唯一Lead写入与Mac操作，一位非实施者只读固定快照；不重新运行未受影响的GPU矩阵。

## 准确对象

- 施工树 `/Volumes/CodexProjects/Codex/D-Worktrees/D-UI-CONSOLIDATED-20261020`，分支 `codex/ui-consolidated-20261020`；开工main/施工分支均为 **b712c80cac5fac7946d94b466b5d6acfb47e70ec**，本批生产提交 **e1de72e705c1ebd46f0b5ede36a4fdda592a10be**。最后文档提交与包内生产身份分别记录。
- 本批证据 C27=`D-Development/AgentTrials/D-UI-CONSOLIDATED-01/run-20261127-ui-copy-01-20`。31项双语正文更新，52个指定帮助条件及文件详情重复段删除；正式中英各5766键，重复键/键集/占位符/帮助引用通过。第9条分流归档、缺记录、运行/保存、缺消息与缺种子，冻结请求保持；历史错误原文继续精确识别。
- 定向19项UI/错误/帮助测试与4项Workbench方法（含3种种子情况）通过；非实施者只读复核固定16文件通过。新普通Release/完整Archive、签名/包内文本/双架构dSYM/七引擎/零权重已核；同包中英代表界面、实际新建/导入/选择保留草稿、保存/正常Quit/桌面冷开通过。稀有错误分支按组件或源码/资源级记录，不冒称普通App全部触发。
- 当前桌面 `/Users/lfrledh/Desktop/D 最新版` 已读回 `/Volumes/CodexProjects/Codex/D-Development/CurrentD/Nov27-Copy-e1de72e7/D.app`；生产为上述e1de，七引擎资源继续为 **a1226881d0c6d19d8750f239cd484dd7bb8de447155409eb05acafa0f8b2b227**。完整Archive `C27/Archive-e1de72e7/D.xcarchive`，构建 `C27/release-final/build-report.json`，门禁 `C27/final-package-e1de72e7.json`；最终文档交付SHA/远端读回另记CurrentD/receipt.json，不伪改包内标记。
- 4898为已验最近回退，745作为仍开放I012的旧基线额外保护；f928及825de3/d4ebddb/5d8ced/5607具名对照、模型和用户资料保护，本批接纳未删除App。个人scheme内容与未暂存状态保持。
- 上轮证据 N27=`D-Development/AgentTrials/D-UI-CONSOLIDATED-01/run-20261127-qwen-chat-low-memory`；其普通App/GPU/保存冷开与失败证据按本批影响继承，以下为前轮有效结果和仍开放项。

## 已交付工程结果与具体剩余

| 项目 | 实际结果 | 仍缺什么 |
|---|---|---|
| Qwen3.5-9B Q4 | 补topK/minP/presence/repetition持久化、普通配置与重现接线；存在惩罚只计本次生成、不含prompt、不限20。准确官方参数/32768额度/seed42三档22、8142、16379输入均自然EOS结束并有正文，输出2282、8269、4735。短档普通App保存/Quit/冷开；长档同生产后端受控真实GPU。 | 默认未改；旧小额度无正文不等于丢正文。约2.1token/s的分层路线下短样本等正文约18分钟。尚未隔离GPU/读取/采样各自耗时；不将“预填充＋首ID返回”冒作纯预填充。新默认策略交用户决定。 |
| I012历史卡死 | 早先限定滚动负结果保留；最终4898原QA取得合格VO Find：sample30逐字读回、即时确认焦点至Return约25微秒，随后AX空/单核持续、正常Quit失败，已核保存内容后定向恢复。 | **仍未修复。** b18同资格失败，48e4完整撤回。最后单次内层诊断确认SwiftUI更新链将clip上移195pt，随后报告范围增加820pt，但未定位循环属性创建者；不能据此猜改高度/阅读/焦点。下一条件是保留故障的最小源码构造或该属性来源证据，由Lead负责；VO关闭、原SCIM输入源恢复。 |
| I017 resize | 12秒Animation Hitches可以保存、重开导出并关联真实输入；无有效最终内容呈现/FPS表。新详情观察对照没有稳定收益，且B存在场景差异，已完整撤回。 | **仍开放。** 现有链只能证明更新/主线程停顿，缺失效创建者及内容最终呈现归因；不再重复旧冻结/缓存实验。用户手感接纳另列。 |
| Stable Audio Small Music | 补迁入音频创建页的同一加载方式选择。557普通包原模型、显式分层6秒/8步/CFG6/seed42完成；最终4898冷读保持同doc/job/asset/摘要，真实播放0→2.9→6.0秒。WAV与原常驻参考字节相同。 | 不代替听感接纳；浮点峰8.39与旧参考相同，不称无削波。创建页既有中文状态/候选名漏接列I013，不冒称全界面本地化已通过。 |
| LTX2.3 Q8 | 最终4898普通App完成保留ED2准确副本、512×320/25帧/30步，automatic/12GiB单次同意；全解码、播放、保存、正常Quit和冷开同成果再播放已验。 | 作品质量仍待用户；低频RSS峰4.183GB、系统压力含normal/warning，不称完整App峰或全程无压力。 |
| Wan512 | 512²/17帧FP32 VAE峰7.824GB已测，策略v3只补准确几何；832×480历史普通成功有效。最终4898正常界面512²/17帧/50步请求8096C516完成，automatic/12GiB单次同意、FP32 VAE，17帧全解码/播放、正常Quit及冷开同成果再播放通过。 | 普通执行MLX峰7.812GB；provider峰RSS2.185GB与低频采样0.559GB分列，不相加、不外推所有几何或用户质量接纳。 |
| 旧加载策略显示 | 4898使旧缺字段节点实际fixed/resident/staged时显示相应兼容值；新建automatic与明确手选保持，六个消费者共用纯投影，不改冻结/存储。 | 2项UI、21项配方/服务组件和只读审查已过；不泛称所有历史项目亲跑。 |

## 证据与边界

- [当前UI文本1–20增量](tasks/D-UI-CONSOLIDATED-01.md#ui-copy-01-20-20261127)、[前轮三档数据](tasks/D-UI-CONSOLIDATED-01.md#2026-11-27-官方思考参数历史组合与低内存补验固定交付)、[模型矩阵](RELEASE_MODEL_MATRIX.zh-CN.md)、[性能记录](investigations/D-PERFORMANCE-ATTRIBUTION-01/regression-20261022/README.zh-CN.md)、[唯一D-I清单](FAILURE_AND_PERMISSION_AUDIT.zh-CN.md)。N27/qwen/comparison-final.json与window-speeds.csv保留生产端32个速度窗口；每窗按N−1个间隔，EOS不计yield输出。
- MLX峰、进程RSS采样与系统压力分别记录，不相加；三档使用同一分层路线，未显示持续降速，单样本不能外推全部长上下文。8k/16k不是普通UI双跑；运行时任务释放不等于allocator全部为零。
- 无效实验/采集资格失败保留原因，诊断改动撤净。I018仍用户暂缓；NODE/PAN改善、ZOOM多数满意反馈不改。README已认可，未变化18图保留真实来源，不称本轮重拍。
- 本体免费、五档自愿打赏、Apple真实结果、零权重、准确精度、低内存知情选择、部分成果和运行原图保护保持。正式账号/证书、第二Mac、名称/许可证及公开联系方式按既有项单列，模型权重许可不重新开放。

前轮4898包、桌面冷开与正常退出已核；当时简中、SCIM、VO关闭和全局ask已恢复。前轮仅退役10个中间App包体，外盘实测净增11.721GB、批后可用546.634GB；当前/回退/反例、模型和项目保全，详见N27/intermediate-retirement-result.json。沿同线提交/推送及正常FF main，精确远端读回与完整交付SHA见CurrentD/receipt.json；不强推或整合分叉。没有标签、商店、收费、部署或可见性操作。本批e1de的两次正常Quit（530/1239）与桌面冷开完成；最后为简中，输入源/VO/全局ask未改变，未留QA窗口。C27/native-acceptance.json按普通App/组件/未触发分别记录；交用户试用和独立审计，不代替体验接纳。
