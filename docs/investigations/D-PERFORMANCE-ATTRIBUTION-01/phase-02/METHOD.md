# 离线复算方法

本目录方法仅Python标准库，读指定旧证据、写指定衍生目录；不启动App、不发输入、不联网。外部顾问取得本地受控旧证据后运行：

```sh
python3 -m unittest discover -s method -v
python3 method/reanalyze.py --old-root "$PHASE1_ROOT" --output "$OUTPUT" --scratch "$SCRATCH" --rules method/classification-rules.json
python3 method/presentation_join.py --old-root "$PHASE1_ROOT" --scratch "$SCRATCH" --output "$OUTPUT/presentation-record-joins.json"
```

变量由本地保管人指向证据根，不包含在Git。输入需要`exports/{phase}-toc.xml`、`exports/{phase}-data.xml`和`reports/{phase}-analysis.json`。五段列表固化，未自动纳入无效08。输入摘要见capture-manifest；当前工具要求单run、匹配TOC，不能盲目适配任意未来schema。

1. XML用iterparse流式读；id/ref是整份XML命名空间，用外部临时SQLite索引加8192项LRU保存定义。跨row/table的process/thread/backtrace/frame/binary和标量均解引用；不按行或表清空引用。当前嵌套栈在内存，结束元素从ET父移除；不建立全部raw DOM。未解引用、循环、重复ID、TOC索引/schema名称不符直接拒绝。
2. 精确PID来自对应TOC；线程必须有TID。TID只在同段内部映射main/event/worker匿名别名；同名不同TID不合并。没有按Main Thread名称把所有线程当主线程。所有目标Running采样均计入，单位原weight纳秒→毫秒，负数拒绝，不假设每行1ms。半开窗`lo <= t < hi`。
3. 时窗沿用Phase1请求操作窗，整数ns舍入；不把CPU活跃起点伪造为输入起点。每线程及全线程给whole、等三分、固定1s bin，最后短尾保留实际时长。timeline的weight是区间CPU样本权重，不是FPS；不能把不足1秒尾bin视作整秒频率。
4. 调度区间裁窗后做事件扫线：每状态原始sum与union、总体covered/gap、重叠时间union、跨状态重叠、重复区间分别保留。显式Unknown不是gap。`scheduler-accounting.csv.overlap_s`表示有多重覆盖的时间union；manifest规范的overlap_s表示重复计数excess，语义不同，本次两者均0。Blocked等待原因未知，time-profile的record-waiting-threads=0，不能从运行栈补造阻塞栈。
5. self取导出叶帧；inclusive每样本对相同(module,symbol)仅计一次，防递归重复，但祖先之间仍重叠。全局排序不经过关键词；业务类别是后附的可重叠标记。self累计比例分母为总Running权重；inclusive累计分母为所有inclusive重叠权重之和，**不是CPU覆盖率**。CSV另列denominator_ms为该scope样本总权重，供独立计算具体符号覆盖。
6. 匿名地址保留sha256截取标识，避免把不同未符号化地址合成一个桶；不公布真实地址。路径隐去。`<deduplicated_symbol>`是工具已丢失细节的符号，不可恢复；路径直方图完整保留当前导出的匿名符号序列，不能称原始执行路径无损。
7. 代表栈规则：每线程每等分，取累计最高叶符号的第一条匹配栈，以及seed20261018的uniform样本；另取最高权重1秒bin的时间序列加权中位样本。未按业务关键词择首条。每条给row/time/weight/完整leaf→root，空段不造样本；同叶的代表栈不能代替其所有样本共同调用链。完整路径直方图另存gzip，gzip mtime=0保证重现。
8. 规则v2按当前源码连接geometry、hit、draw、port/node接收器分开，未用旧WorkflowWire零命中排除当前实现。分类无论命中多少均不改变全局排行。

初版评审发现同名TID可能合并、负weight/空窗校验不足、地址桶合并、加权中位实现不一致，均修正并补测试，随后重跑全部五段exit0。22个测试方法覆盖跨表引用、重复标签/ID、循环、缺失/前向引用、schema、身份、权重、递归、边界、未知状态、overlap/gap、选样确定性和精确显示join。它们不证明trace真实性或D产品通过。方法在Python3.9执行。

G1阶段记录：当时重放未实施：不把组件测试已有的postEvent→sendEvent循环当作全App定时重放；其每步等布局会产生coordinated omission。下一次必须用固定墙钟计划、记录发送/实际接收/状态以及迟到、合并、失焦中止，组件层只用于不变式，不输出原生FPS。

## Fixed production source references

These are source evidence, not latency measurements.

- [Input and native viewport](https://github.com/lfrledh/D/blob/9eae90e4adc4008c3894f09bcd07c71e23701045/Packages/UI/Sources/UI/Views/Workflow/WorkflowCanvasViewportInteraction.swift#L350)
- [PAN observation guard](https://github.com/lfrledh/D/blob/9eae90e4adc4008c3894f09bcd07c71e23701045/Packages/UI/Sources/UI/Views/Workflow/WorkflowGraphSurface.swift#L275)
- [Library hosting and execution bar](https://github.com/lfrledh/D/blob/9eae90e4adc4008c3894f09bcd07c71e23701045/Packages/UI/Sources/UI/Views/Workflow/WorkflowCanvasView.swift#L510)
- [Glass geometry and host](https://github.com/lfrledh/D/blob/9eae90e4adc4008c3894f09bcd07c71e23701045/Packages/UI/Sources/UI/Views/Quick/WorkbenchLocalBackground.swift#L491)
- [Connection drawing](https://github.com/lfrledh/D/blob/9eae90e4adc4008c3894f09bcd07c71e23701045/Packages/UI/Sources/UI/Views/Workflow/WorkflowConnectionDrawing.swift)
- [Connection hit receiver](https://github.com/lfrledh/D/blob/9eae90e4adc4008c3894f09bcd07c71e23701045/Packages/UI/Sources/UI/Views/Workflow/WorkflowConnectionReceiver.swift)
- [Native directory admission](https://github.com/lfrledh/D/blob/9eae90e4adc4008c3894f09bcd07c71e23701045/D/WorkbenchBootstrap.swift#L61)

## 2026-10-19 新重放记录的资格方法

`method/replay_analysis.py`只读取已导出的本地JSON，不发送事件。输入为同前缀report/plan/events，输出逐项INVALID或B_LOCAL_STAGE_EVIDENCE。先检查记录schema/来源级别、完整目标/来源标识、固定轨迹/数量/节奏、非有限数与布尔序号，再核对每槽intent→posted→received→handler-return及全局顺序、缺失/重复/取消、最终图/视口/倍率。NODE/PAN发生额外缩放会拒绝。pilot标记保留，不能混算正式重复。真实身份仍须与本地签名和启动回执互核，JSON自称B不证明来源。

42方法/43展开合成情景；一个方法含NODE/PAN两个参数反例。旧22方法仅沿用，不把26、41等中间轮数累加。失败与修正均保留私有日志。几何callback没有输入到布局完成的唯一桥，输出明确不提供layout完成时延；ZOOM锚点未由handler状态独立验证。缺文件/崩溃记录不得补零，原生试录失败不用于性能结论。

复算入口：`python3 method/replay_analysis.py $PRIVATE_PREFIX --output $PRIVATE_RESULT`；合成自检：`python3 -m unittest discover -s method -p test_replay_analysis.py -v`。原始事件和崩溃文件不随报告推送。

## 2026-10-19 资格协议v2与截断证据

`replay_analysis.py`同时保留v1，v2严格绑定report/plan profile。`qualification-low-load-v1`为1.25秒、250ms间距、NODE/PAN6条与ZOOM4条；只可得到B_LOW_LOAD_ACTION_QUALIFIED，不计连续重复。时间链为planned（计划值）→intent→main-enter→post-begin→posted→received→handler-return-state；received是在真实生产monitor出队后的入口，handler-return-state为同步路由返回时状态快照，不能扩张为布局/屏幕完成。

v2要求逐槽完整/唯一/顺序、实际最小post间距、计划/投递/出队坐标以及投递到接收欧氏距离<1点；必须有sending-ended与对应completion，完整成功要求提交/Undo/测量外复位。CLI用同一prefix自动读report、plan、events和completion。协议阈值来自预登记，不从结果调优。

截断段仍为INVALID完整计划，但保留已观察阶段的分布与`partial_state_observations`。运动采用生产一致的向量长度；原reported_motion另存，冲突不改写raw。缺失末槽表示terminal-state-unobserved，不生成虚假的最终视口/倍率不匹配或Undo错误。只在存在末槽时执行原终态比较；完整资格绝不因此放宽。纯合成测试59方法/66展开情景通过，含新增17/23；旧全线程/显示分析测试未无理由重跑。

`qualification-03-timeline.csv`为去敏相对时序：相对每段预定epoch，保留停止、未投递及阶段间隔，不含实际PID、项目身份、路径或内容。绝对单调时钟/完整身份与原始事件留本地。CSV没有FPS、GPU或输入到显示换算。
