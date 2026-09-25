# 当前行动与接手点

核实：2026-09-25。当前任务、源/候选、停点和下一动作以本页为唯一入口；历史任务不是开工许可。

## 当前任务：M0 节点工作台

用户已批准 [D-M0-01](tasks/D-M0-01.md) 的 S0→S1→S2 和 S3 小型扩展；不进入 S4、不公开发布。用户附件中的“待评审”不再阻止本批实施。最小范围是可编辑文字/图像/普通图片处理节点、明确人工决定、保存恢复与来源；复用原 ProjectSession、ProjectStore 和 DRuntime，不引入新模态、插件平台或平行资产系统。

- 源：`/Volumes/CodexProjects/Codex/D`，`codex/inference-foundation`，`58603870719a52ff07b6bb6e4d6d09e02c23901a`；本批尚未推进源分支。
- 候选：`/Volumes/CodexProjects/Codex/D-Worktrees/D-M0-01`，`codex/d-m0-01`。受测代码 `18cb9ec9cdf81a7e849204a40226cc91223c275e`；最终文档提交/受测版本见任务末尾与外部回执，不根据短 SHA 猜造。
- 原 source1—12 项目格式、本批16、AP1/CORE13—15分别处理。仅在独立测试项目上验证迁移，不批量升级真实作品。
- 新入口为项目内显式选择“流程画布”；旧“创作与资料”继续直接调用服务。发布文稿是快照；后续打字不改变已发布文字，不自动生成下游。

## 证据与当前限制

候选已实现 N01—N10，S3另有独立“移除空行”程序。静态注册/端口/校验、同一存储、明确继续和候选采用、局部重跑/旧输入、元数据及原子不覆盖导出已接线。不是发布声明。

本批证据根：`D-Development/AgentTrials/D-M0-01/run-20260925T091107Z/`。完整版本与命令在每项 result.json；失败日志保留。

- `18cb9ec9cdf81a7e849204a40226cc91223c275e`：完整UI package 109项UI/23项ModelLibrary/438项Workbench通过；根运行时70项复用a616126、相关代码/测试零差异已核对；构建、CPU、hosting与真实模型分列，不把总数冒充GUI次数。
- `real-delivery` 在18cb9ec上实际图文三候选/JPEG导出/恢复及真实取消通过；另经真实ProjectSession文稿入口核对相同请求、来源重开及无隐藏图。隔离 XCTest 宿主不是普通 App GUI。
- `hosting`/`hosting-fixed` 暴露窄窗口拟合1100问题；实际 viewport约束和稳定编辑器树修补后 `cpu-provenance3` 通过，包括待确认 Unicode 草稿缩放保留。离屏渲染不是桌面截图。
- 本轮曾被锁屏阻止原生 GUI；首个宿主测试对外盘临时项目写入被拒绝，改用现有 App 容器专属小项目通过，不扩大权限、不改 entitlements。本人操作集中到 [H25](FAILURE_AND_PERMISSION_AUDIT.zh-CN.md)。GUI、普通 App 的目录授权、实际断网 T15仍需各自证据。
- 最终 App/试用步骤见 [M0试用说明](M0_TRY.zh-CN.md)。不替换普通 D，未验收路径不默认覆盖旧行为。

## 保护与未整合候选

源唯一个人 scheme orderHint1→6，SHA256 `ca3635d88aa5a15397b90e528667c66c0e6db7e596176e885c79d194b544206c`，未暂存；index blob `9c76916bdc97c2d4298cefe64e0b0fae3380573e`。完整 diff/index/副本在本 run protection，源每次更新前后核对。索引干净不等于源工作区全干净。

| 保留对象 | 固定身份/边界 |
| --- | --- |
| AP1 | `codex/d-audio-project-01` / `e5d24f4e1064423238e3c8e1112bc4b3a9a81e2e`；独立候选，不随M0合入 |
| CORE | `codex/d-core-close-01` / `9d3a503d327a820cb67e399922a07c27f953e903`；包括AP1与部署记录，未做组合全验，不随M0合入 |
| I2V | 历史全50步只证明latent/首步对照，不代表解码/MP4或App通过；[原任务](tasks/D-VIDEO-I2V-01.md)预算和停点不变 |
| 上批源验收 | [UI readiness](tasks/D-UI-READINESS-01.md)；`34ee0c5e2172a0bc5479960f7d7660567e657a30`组合、`e24552a6de13b38c4f84baec83462f6681795bb7`源入口复验，后续仅文档；历史普通签名/GUI证据不能替代M0 |

本批 REGISTRY/IMAGE/CANVAS 写Worker已结束；REGISTRY/CANVAS各消耗一次定向修复，IMAGE无修复。Lead负责存储、运行、应用接线和组合修正；非实现者只读审核记录见任务。测试/构建阶段的自有进程状态在任务恢复点更新，不声称建立系统写锁。

## 下一动作与停止规则

CPU与真实模型验收已执行；代码18cb9ec的普通签名App已用独立DerivedData-Regular重建并通过签名完整性检查（`build-delivery-app` / `ordinary-app-delivery-check.json`，包含实际Debug代码dylib的四文件摘要），沙盒开启、无测试宿主临时例外。Mac解锁后补本批原生操作。如果GUI受阻，交付可运行候选、已有真实模型结果、试用说明和准确待办，不把M0标为完成，不接纳未验收路径覆盖源。全部M0验收满足后才可按原规则接纳已验组合。

到本批检查点停止；不自动启动S4、恢复旧S6/AP1/CORE/I2V、做音乐/视频扩展或发布。产品目标见[原则](PRODUCT_PRINCIPLES.zh-CN.md)、[目标](PRODUCT_GOALS.zh-CN.md)，旧服务接线债见[后端扩展约束](BACKEND_EXTENSION_CONTRACT.zh-CN.md)（本批实际新增接线以M0任务为准）。
