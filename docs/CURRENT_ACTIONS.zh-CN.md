# 当前行动与接手点

更新：2026-11-27。D-UI-CONSOLIDATED-01本轮固定普通候选已完成交付检查；唯一Lead写入、构建/GPU/原生操作串行，一位非实施者只读固定快照。用户批准Qwen官方参数与性能分段、I012剩余组合、I017测量资格，以及LTX Q8/Stable Audio/Wan512补验；不扩大清理，不全局改变默认输出额度。

## 准确对象

- 施工树 `/Volumes/CodexProjects/Codex/D-Worktrees/D-UI-CONSOLIDATED-20261020`，分支 `codex/ui-consolidated-20261020`。开工main/施工分支均为 **1ed6a251d32717629317e269f1c44bee6c01341c**；本轮产品 **4898b0246901b83ff6adebb3ced7e00ea19b016d**。最后文档提交不伪作包内生产身份，远端最终读回另记CurrentD/receipt.json。
- 本轮正常候选 `/Volumes/CodexProjects/Codex/D-Development/CurrentD/Nov27-Final-4898b024/D.app`，资源 **a1226881d0c6d19d8750f239cd484dd7bb8de447155409eb05acafa0f8b2b227**。Release -O/WMO、七引擎、零第三方权重及正常开发签名门禁已通过；三项普通生成/播放/保存/冷开已验；桌面已指向该包并正常冷开、关闭窗口和退出。
- N27=`D-Development/AgentTrials/D-UI-CONSOLIDATED-01/run-20261127-qwen-chat-low-memory`。构建 `N27/release-final-4898b024/build-report.json`；完整Archive `N27/Archive-4898b024/D.xcarchive`。没有为语言或每张图重复构建资源。
- 桌面指向4898；745为接纳后的最近回退，用户指定f928额外保护、825de3/d4ebddb/5d8ced/5607具名对照、准确模型及用户资料保护。个人scheme内容/索引状态保持。11月27先前清理结果是历史基线，不是本轮新删除授权；[原清理回执](investigations/20261113-SSD-CLEANUP/deep-audit-20261117.md#10-11月27日按用途重新审视后的授权清理)保留。

## 本轮结果与具体剩余

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

- [本轮任务增量及三档数据](tasks/D-UI-CONSOLIDATED-01.md#2026-11-27-官方思考参数历史组合与低内存补验固定交付)、[模型矩阵](RELEASE_MODEL_MATRIX.zh-CN.md)、[性能记录](investigations/D-PERFORMANCE-ATTRIBUTION-01/regression-20261022/README.zh-CN.md)、[唯一D-I清单](FAILURE_AND_PERMISSION_AUDIT.zh-CN.md)。N27/qwen/comparison-final.json与window-speeds.csv保留生产端32个速度窗口；每窗按N−1个间隔，EOS不计yield输出。
- MLX峰、进程RSS采样与系统压力分别记录，不相加；三档使用同一分层路线，未显示持续降速，单样本不能外推全部长上下文。8k/16k不是普通UI双跑；运行时任务释放不等于allocator全部为零。
- 无效实验/采集资格失败保留原因，诊断改动撤净。I018仍用户暂缓；NODE/PAN改善、ZOOM多数满意反馈不改。README已认可，未变化18图保留真实来源，不称本轮重拍。
- 本体免费、五档自愿打赏、Apple真实结果、零权重、准确精度、低内存知情选择、部分成果和运行原图保护保持。正式账号/证书、第二Mac、名称/许可证及公开联系方式按既有项单列，模型权重许可不重新开放。

最终包、桌面冷开与正常退出已核；简中、SCIM、VO关闭和全局ask已恢复。仅退役本轮10个中间App包体，外盘实测净增11.721GB、批后可用546.634GB；当前/回退/反例、模型和项目保全，详见N27/intermediate-retirement-result.json。沿同线提交/推送及正常FF main，精确远端读回与完整交付SHA见CurrentD/receipt.json；不强推或整合分叉。没有标签、商店、收费、部署或可见性操作。交用户试用和独立审计，不代替用户体验接纳。
