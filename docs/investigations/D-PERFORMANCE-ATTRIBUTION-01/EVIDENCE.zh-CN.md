# 证据索引与复算口径

本页随调查报告归档。它提供可在 GitHub 阅读的去敏摘要，以及受控本地原件的逻辑索引；不含原始 trace/XML、用户项目、索引、书签或签名个人信息。归档是既有结果的整理，没有新增采集、构建或性能修补。

## Git 内材料

|文件|用途与边界|
|---|---|
|[README.md](README.md)|完整结论、版本/环境、操作分段、支持与反证、异常和未验项|
|[interaction-summary.csv](interaction-summary.csv)|02/03/05/06/07 的五行原统计摘要；字段与本地原件一致，仅将CSV换行统一为LF|
|[data-integrity.json](data-integrity.json)|五段分析窗与主线程调度覆盖核对；覆盖完整不等于输入精确或帧链完整|
|[hotspot-stacks.sanitized.json](hotspot-stacks.sanitized.json)|05 的六个代表样本，叶到根符号顺序保留；线程身份和未符号化地址去敏|
|[classification-patterns.json](classification-patterns.json)|原分析器的分类匹配规则，只有数据，无诊断执行代码|
|[commands.sanitized.json](commands.sanitized.json)|录制/导出的历史 argv 与已记录退出码；私有根、PID及通知名替换为占位符，不能直接运行|
|[timing.sanitized.json](timing.sanitized.json)|有提示音的各段事件 UTC 与包装器单调时钟；无原 argv 或通知身份|
|[consultant-review.md](consultant-review.md)|非实施者只读复核范围、已采纳意见及剩余限制|

## 统计方法

1. 用 trace TOC 的表顺序解析导出 table 索引，解析 XML `id/ref`；精确筛选已核实评审 PID 和 Main Thread。
2. 非空闲窗取 `start_cue_end - trace_start + 0.5s` 至 `stop_cue_begin - trace_start - 0.5s`，并裁至 trace 结束。空闲06取 `[2s, trace_duration - 2s)`。提示音是请求手势的分段标记，不能替代 NSEvent 时间。
3. `time-profile` 只取该半开区间内且状态为 Running 的样本。weight 从纳秒转毫秒；本批有效主线程样本权重均为1ms，因此 CSV 的 `*_samples` 数值恰与对应样本权重毫秒相同。这不是函数调用次数，也不是连续占用时长。
4. 分类以任一栈帧包含匹配串为准，同一栈内同类只计一次；不同类可重叠。单符号 inclusive 也先在栈内去重；leaf self 只取第一帧。不能把各类求和为总CPU，不能把祖先 CA/layout 的 inclusive 权重当独占提交/布局成本。
5. `thread-state` 另行与分析窗相交，按 Running/Runnable/Blocked 区间求和，获得调度时间。它独立于 time-profile 采样。Blocked 未区分等待原因，不能视为GPU等待或统一视为空闲。
6. 本地逐秒分布包含全 trace、未筛 Running，只用于看操作覆盖；Git摘要没有把它当输入频率。帧/交换/Metal表未完成可靠归属，不计算FPS、p95或输入到呈现延迟。

CSV 的 `trace_start` 含时区；`window_start_s/end_s` 均相对 trace 开始；三个 `main_scheduler_*_s` 是调度区间秒。`main_running_samples` 为有效样本数，其余 inclusive 列按上述口径。小数位保留分析器原输出，不表示相同数量级的测量精度。原阶段02/03活动覆盖不均、实际倍率/面积不明，禁止据该表计算三种交互的快慢倍率或关侧栏性能增益。

07虽然调度窗覆盖完整，保存收尾仍异常；08用户已恢复界面但文件不完整且两项导出失败，不能补齐A/B/A。完整退出码和异常解释见主报告第6节。

## 本地受控原件

逻辑证据集：`D-PERFORMANCE-ATTRIBUTION-01/run-20261018-01`。以下路径均相对此证据集，**不是 Git 中可下载的附件**；精确机器位置由用户本地保管。原件约4.1GiB、目录权限700，未因归档移动或清理。

|相对位置|保留内容|
|---|---|
|`traces/00-idle.trace` 至 `traces/08-left-restored-wheel.trace`|九段录制；01/04手势无效，08不完整，均保留|
|`exports/*-toc.xml`、`exports/*-data.xml`|原始可读导出，含进程/路径资料；08失败材料仍保留|
|`*.command.json`、`*.timing.json`、`*.log`、`*.result.json`|逐命令、提示音时序、退出码；07单列 `07-left-hidden-wheel.wrapper-result.json`|
|`reports/*-analysis.json`、`*-hotspots.txt`、`*-example-stacks.json`|五段原分析、可读热点和代表栈|
|`reports/INVESTIGATION.zh-CN.md`、`reports/consultant-review.md`|发布前调查原件；其中“尚未推送”属于追加授权前的历史状态|
|`private/baseline-receipt.json`、`private/build-configuration-evidence.txt`、`private/protection-end.json`|App/包/签名/隔离身份、构建配置、保护文件摘要；不发布用户正文或私有路径|
|`tools/analyze-traces.py`、`delivery-manifest.json`|本地分析器及采集交付时的小文件摘要/trace元数据清单；不是原始trace全量哈希清单，也不是Git归档提交回执|

## 固定源码定位

下列链接均固定到生产 `9eae90e4adc4008c3894f09bcd07c71e23701045`。本目录归档不改变这些文件；报告中短称 `ViewportInteraction`、`LocalBackground` 对应下表完整文件名。

|文件|不可变源码|
|---|---|
| `WorkflowGraphSurface.swift` | [Packages/UI/Sources/UI/Views/Workflow/WorkflowGraphSurface.swift](https://github.com/lfrledh/D/blob/9eae90e4adc4008c3894f09bcd07c71e23701045/Packages/UI/Sources/UI/Views/Workflow/WorkflowGraphSurface.swift) |
| `WorkflowCanvasView.swift` | [Packages/UI/Sources/UI/Views/Workflow/WorkflowCanvasView.swift](https://github.com/lfrledh/D/blob/9eae90e4adc4008c3894f09bcd07c71e23701045/Packages/UI/Sources/UI/Views/Workflow/WorkflowCanvasView.swift) |
| `WorkflowCanvasViewportInteraction.swift` | [Packages/UI/Sources/UI/Views/Workflow/WorkflowCanvasViewportInteraction.swift](https://github.com/lfrledh/D/blob/9eae90e4adc4008c3894f09bcd07c71e23701045/Packages/UI/Sources/UI/Views/Workflow/WorkflowCanvasViewportInteraction.swift) |
| `SharedLibraryBrowser.swift` | [Packages/UI/Sources/UI/Views/Workflow/SharedLibraryBrowser.swift](https://github.com/lfrledh/D/blob/9eae90e4adc4008c3894f09bcd07c71e23701045/Packages/UI/Sources/UI/Views/Workflow/SharedLibraryBrowser.swift) |
| `DualWorkbenchView.swift` | [Packages/UI/Sources/UI/Views/Quick/DualWorkbenchView.swift](https://github.com/lfrledh/D/blob/9eae90e4adc4008c3894f09bcd07c71e23701045/Packages/UI/Sources/UI/Views/Quick/DualWorkbenchView.swift) |
| `WorkbenchSidebar.swift` | [Packages/UI/Sources/UI/Views/Quick/WorkbenchSidebar.swift](https://github.com/lfrledh/D/blob/9eae90e4adc4008c3894f09bcd07c71e23701045/Packages/UI/Sources/UI/Views/Quick/WorkbenchSidebar.swift) |
| `RetainedContentHost.swift` | [Packages/UI/Sources/UI/Views/RetainedContentHost.swift](https://github.com/lfrledh/D/blob/9eae90e4adc4008c3894f09bcd07c71e23701045/Packages/UI/Sources/UI/Views/RetainedContentHost.swift) |
| `WorkbenchLocalBackground.swift` | [Packages/UI/Sources/UI/Views/Quick/WorkbenchLocalBackground.swift](https://github.com/lfrledh/D/blob/9eae90e4adc4008c3894f09bcd07c71e23701045/Packages/UI/Sources/UI/Views/Quick/WorkbenchLocalBackground.swift) |
| `SharedLibraryMetadata.swift` | [Packages/UI/Sources/DWorkbench/Library/SharedLibraryMetadata.swift](https://github.com/lfrledh/D/blob/9eae90e4adc4008c3894f09bcd07c71e23701045/Packages/UI/Sources/DWorkbench/Library/SharedLibraryMetadata.swift) |

## 证据等级

- **当前实测**：同包原生采样、五段调度/CPU摘要、代表符号栈、已保留失败及退出码；不含真实FPS/GPU瓶颈结论。
- **源码推断**：父zoom写入、retained内容更新、具体Binding候选、布局/几何/缓存及命中路径。具体Binding与卡顿的因果贡献尚未单独证实。
- **历史沿用**：原生产的构建签名来源、组件与既有UI接受记录。本轮验签和身份读回属于当前检查；没有新构建/组件或模型测试。
- **未证实/环境受阻**：输入延迟、完整显示帧链、GPU分解、规模与材质独立对照、Release差异及有效A/B/A复归。见既有集中待办，不交给用户工程排错。
