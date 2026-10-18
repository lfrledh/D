# 旧显示记录的关联资格

这是本阶段对既有记录的离线重算，不是新原生显示测量。所用旧合并XML仅首表带schema，因此另从05旧trace单独导出`hitches-updates`和`hitches-frame-lifetimes`（exit0），没有猜重复uint32字段位置。

字段核验：updates为start/duration/process/display/swap-id/surface-id/frame-color/containment-level/label；lifetimes为start/duration/display/swap-id/surface-id/frame-color/layout-qualifier/label，无PID/窗口。displayed与swap的16列定义来自当前Xcode内Apple的`GPU.instrdst/.../com.apple.gpu-tracing.dtac/schemas.xml`。导出schema与本机规则摘要和哈希留私有证据，不复制Apple包或私有XML入Git。

按同一run精确PID过滤updates，保留containment分布；顶层level0按(swap-id,surface-id)连接swap，再按完全相等的(swap.timestamp,surface-id)连接displayed。**无最近时间匹配、无跨run XML id/ref匹配、无标签猜测。** 代码见method/presentation_join.py；完整统计（整段、原窗、早中晚及未匹配行号）见presentation-record-joins.json。

|旧段|updates|level0/1|独特process/display/swap/surface键|顶层→swap→displayed|
|---|---:|---|---:|---|
|02|468|463 / 5|463|463 → 463 → 462|
|03|472|467 / 5|467|467 → 467 → 467|
|05|506|288 / 218|288|288 → 287 → 287|

以上为整条旧录制窗，不是有效手势帧数。05嵌套记录与顶层共享键，不能将506直接当帧。displayed输出surface在少数合成输出间循环，标签还含其他进程，不能当D主窗口。名称分别出现Display 2、external-1、Built-In Display，数值/时间join不证明显示名称映射。

Apple本机`com.apple.metalsystrace-display.dtac/modeling-rules/rules-0003.clp`449–460定义displayed为相邻swap间区间，并逐行分配Connection UUID；500–504按PID只留一个依赖；572–580只列1–3进程标签，更多退化Surface标签。所以该UUID不是稳定窗口连接，“无D标签”不能断言D未呈现。

三段各有start=0、duration为123.218402541/55.303042083/132.254450750秒的lifetime，超过录制。前两段相同swap/surface却在10.285748791/10.054343500秒交换；05无对应交换。不直接按start+duration计算帧时间，也不悄悄删除/修正。它与跨边界裁切相容，但当前HitchesTap规则未取得，具体原因未知；另一旧hitches-lifetime-interval不是本表，不能套用。

这些结果将“完全不能关联”收窄为“进程记录层部分可关联”；**主窗口、内容版本、实际输入与相机变化到提交的桥仍缺失**。未计算FPS、presentation百分位、漏帧或输入到显示延迟；Metal完成数、body次数及提示音均未替代呈现。GPU负载/等待、shader/overdraw、系统合成仍未排除。
