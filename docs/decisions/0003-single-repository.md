# ADR 0003：统一 Git 版本管理，保留编译边界

日期：2026-09-06。状态：已执行。

六个子模块由同一产品共同交付，单独保存与推送增加不必要的协调。将其源码按当前路径纳入 D 主仓库，保持每个文件、Package.swift、Package.resolved 和 Xcode 引用不变。导入时逐一比较 Git tree，确认与原提交逐字节一致。

这一步统一的是版本管理，不是合并 Swift modules，也不宣称旧实现已接入新 runtime。ADR 0001 的按能力渐进迁移继续适用。

原仓库、提交与 tree 见 ../history/SUBMODULE_PROVENANCE.json。原远程仓库历史保留；本机另在外盘 D-Development/RepositoryBackups 保存各仓库完整 Git bundle。此后普通 clone 可取得全部自有源码，第三方 SwiftPM 依赖仍需首次解析下载。

验收：导入树一致；无 gitlink；从普通 clone 构建原应用并执行新核心测试。模型权重、构建缓存和 Git 备份不纳入主仓库。
