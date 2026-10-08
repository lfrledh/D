# 历史与替代索引

current索引，2026-09-23。历史正文保留原义，不自动作为当前需求、授权或“下一步”。现行入口为[AGENTS](../../AGENTS.md)、[当前行动](../CURRENT_ACTIONS.zh-CN.md)、[原则](../PRODUCT_PRINCIPLES.zh-CN.md)和[协作规程](../MULTI_AGENT_WORKFLOW.zh-CN.md)。

## 整理前固定正文

以下均固定在`b334920907de0324bf3e0146bb78433742356a6c`，不会随着分支变化。离线用`git show <完整SHA>:<仓库相对路径>`读取；不需要切换工作树或联网。旧锚点随这些固定正文阅读，不以当前文件同名推定语义仍有效。

- [AGENTS.md](https://github.com/lfrledh/D/blob/b334920907de0324bf3e0146bb78433742356a6c/AGENTS.md)
- [README.md](https://github.com/lfrledh/D/blob/b334920907de0324bf3e0146bb78433742356a6c/README.md)
- [docs/PRODUCT_PRINCIPLES.zh-CN.md](https://github.com/lfrledh/D/blob/b334920907de0324bf3e0146bb78433742356a6c/docs/PRODUCT_PRINCIPLES.zh-CN.md)
- [docs/PRODUCT_GOALS.zh-CN.md](https://github.com/lfrledh/D/blob/b334920907de0324bf3e0146bb78433742356a6c/docs/PRODUCT_GOALS.zh-CN.md)
- [docs/PRODUCT_STRATEGY.zh-CN.md](https://github.com/lfrledh/D/blob/b334920907de0324bf3e0146bb78433742356a6c/docs/PRODUCT_STRATEGY.zh-CN.md)
- [docs/CURRENT_ACTIONS.zh-CN.md](https://github.com/lfrledh/D/blob/b334920907de0324bf3e0146bb78433742356a6c/docs/CURRENT_ACTIONS.zh-CN.md)
- [docs/MULTI_AGENT_WORKFLOW.zh-CN.md](https://github.com/lfrledh/D/blob/b334920907de0324bf3e0146bb78433742356a6c/docs/MULTI_AGENT_WORKFLOW.zh-CN.md)
- [docs/TASK_SPEC_TEMPLATE.md](https://github.com/lfrledh/D/blob/b334920907de0324bf3e0146bb78433742356a6c/docs/TASK_SPEC_TEMPLATE.md)
- [docs/MODEL_SUPPORT_AND_RELEASE.zh-CN.md](https://github.com/lfrledh/D/blob/b334920907de0324bf3e0146bb78433742356a6c/docs/MODEL_SUPPORT_AND_RELEASE.zh-CN.md)
- [docs/DELIVERY_AND_MODEL_BUDGET.zh-CN.md](https://github.com/lfrledh/D/blob/b334920907de0324bf3e0146bb78433742356a6c/docs/DELIVERY_AND_MODEL_BUDGET.zh-CN.md)

规则去向与替代依据见[本轮任务](../tasks/D-CONTEXT-RESET-01.md#规则去向)。旧模态导航/节点后置/模态全完成后组合已被P2026-09-23.1替代；安全、数值、兼容、许可与旧失败预算未删除。过去的当前状态及统计只对原版本有效。任务历史与外盘证据不批量搬迁、不清理。

## 最早用户材料（historical-fact）

本目录保留用户提供的三份旧 AI 协作材料，内容按原文复制。来源为本会话附件，2026-09-06 归档。

- ORIGINAL_VISION.md：原始愿景总结，文内未注明日期。
- PROJECT_PLAN_2026-02-25.md：技术规划 2.0。
- PROJECT_GUIDE_2026-02-25.md：项目与旧助手协作指南 2.0.0。

这是历史依据，不是当前代码状态或执行规范。尤其“所有 Actor 方法 nonisolated”“Module 一律 unchecked Sendable”“AI 不能改文件/构建”等条款已不适合作为本项目当前规则。当前规则见根目录 AGENTS.md 与 docs/decisions。

<a id="ui-presentation-takeover"></a>
## 2026-10-08 展示重构接手

UI-REFINEMENT-01 原位归档，展示被用户拒收，部分实现/证据保留；后继[UI-PRESENTATION-REBUILD-01](../tasks/UI-PRESENTATION-REBUILD-01.md)。79f未原生验、阅读/fit/封装/拖放/宿主失败转接；常驻规则/保护/旧预算继续有效。

接手前完整正文固定于 **6abf4e1d4a1d1b6cd0cd454c338920a681e6d1e0**：
- [旧当前行动](https://github.com/lfrledh/D/blob/6abf4e1d4a1d1b6cd0cd454c338920a681e6d1e0/docs/CURRENT_ACTIONS.zh-CN.md)
- [旧集中审计](https://github.com/lfrledh/D/blob/6abf4e1d4a1d1b6cd0cd454c338920a681e6d1e0/docs/FAILURE_AND_PERMISSION_AUDIT.zh-CN.md)
- [旧任务原位记录](../tasks/UI-REFINEMENT-01.md)

离线：`git show 6abf4e1d4a1d1b6cd0cd454c338920a681e6d1e0:docs/CURRENT_ACTIONS.zh-CN.md`；集中队列将冒号后路径改为`docs/FAILURE_AND_PERMISSION_AUDIT.zh-CN.md`。只压缩当前入口，不搬/删旧证据或个人文件。
