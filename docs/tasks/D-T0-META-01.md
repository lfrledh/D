# D-T0-META-01：首组产品双任务批次

状态：Lead 准备；v7，2026-09-08。source_base=c808293692eb7be90b7c9de73667c9d7bc327e3a。集成树 /Volumes/CodexProjects/Codex/D-Worktrees/D-T0-META-01，分支 codex/d-t0-meta-01。共同执行基线为本准备提交，其完整 SHA 记录在外部 preparation/request 中。contract_revision=1。

目标：T0 的编辑／推理桥接与可重开草稿数据组件，加独立 META 配方／隐私组件，两方独立受限执行、Lead 非实现者审核和组合 CPU 回归后本地接纳。不是签名、GUI、音乐、PNG 内嵌或 T0 产品全闭环交付。既有图像 UI/ProjectStore 格式不变，新组件不自动启用。没有依赖 META 的全模态前置门禁。

所有权：T0 独占新增 DWorkbench/Text 下三个文件及对应两份测试；META 独占新增 DWorkbench/Media/GenerationRecipe.swift 及对应测试。双方不改 ProjectModels/ProjectStore/ProjectSession/ModelLibrary/InferenceRuntime/UI 视图/Package.swift，详细清单见各任务。Lead 负责文档、装配判断及集成。SwiftPM 会自动发现目标内源文件，不需新包或空接口。两任务接口不相互依赖，无需预写实现让 Worker 抄。

本批验收：每方定向 CPU 测试和契约反例；Lead 代码审查、测试语义／权限事件核对；合并后的 UI package 全量现有 CPU 回归及纯核心回归。已有模型目录不访问。GUI/真实推理无法证实隔离时留待后续，不用 mock 证明真实推理；无用户默认路径改变才能接纳增量。当前没有系统写锁，源推进前后重新验证保护。

证据根 /Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-T0-META-01；task/run 各自子目录。原 RESULT 由独立已接纳任务记录承载，不重置其预算或将其工具作为本批必需门禁。Lead 曾在一次只读命令中漏写 D-Worktrees 路径，工具在创建进程前拒绝；按已确认物理目录纠正，未进入错误仓库或产生文件，不计 Worker 缺陷。

恢复：源上述 SHA；仅个人 scheme 未暂存（读取 start-protection 为准）。批次尚无活跃 Worker；待准备提交、两个独立工作树和预检后签发 IMPLEMENT。默认多代理状态尚未启用。最终代码／测试／文档 SHA 和实际重叠时间在结案补充。
