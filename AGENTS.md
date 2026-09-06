# D 项目协作与架构规则

## 产品方向与当前状态

D 是面向专业 AI 创作者、兼顾初学者的原生 Mac 本地推理工作站。原生 MLX 推理与高完成度体验是核心。完整依据见 docs/ARCHITECTURE_RESEARCH.zh-CN.md 与 docs/decisions/。

当前处于渐进迁移阶段：根 Package.swift 的 DInference/DRuntime 是新框架；Packages/* 是仍供应用使用的旧实现。框架测试成功不代表旧后端已经迁移或真实模型推理通过。docs/history 是历史资料，不是当前执行规范。

## 依赖与并发

- 新公共契约只含 Sendable 值和资源引用，不泄露 MLXArray、ChatSession、AppKit、SwiftUI。
- DInference 不依赖 DRuntime、MLX、网络或 UI；DRuntime 只依赖 DInference 和标准库/Foundation。
- 状态隔离和执行所有权解决并发；不得为了消除编译诊断批量添加 nonisolated、nonisolated(unsafe) 或 unchecked Sendable。
- actor 的 await 可重入，整次推理需要显式许可。execute返回前必须drain，release完成前不得放行下一任务。
- 所有任务必须有取消、清理、明确错误与可观测终态；不以字符串错误前缀或静默finish代替错误协议。
- 暂不创建空的未来功能包。先以真实用例验证边界，再提炼复用。

## 自动化协作

- 直接检查源码与Git状态，不依赖静态目录树推断存在的文件或功能。
- 在用户已确定的任务范围内完成修改、构建、测试和文档更新；不让用户代做例行文件操作。
- 遵守正在进行的用户讨论与范围；产品方向、重大取舍不能由过时说明代替用户决定。
- 保留已有未提交修改。Packages/* 已是主仓库的普通目录，原子模块来源见 docs/history/SUBMODULE_PROVENANCE.json；不要重新创建嵌套 Git 仓库或丢失来源记录。
- 有明确独立子任务时可以并行研究/审阅；共享目录编辑必须分配互不冲突的文件。
- 交付区分已实现、仅定义契约、未验证；只把实际运行结果写成通过。没有真实模型测试就明确说明。
- 用户已授权在阶段完成、验证通过时 commit 并 push 保存进度；不必为每个检查点重复请求许可。默认推送工作分支，不擅自强制推送、删除远程历史或合并主分支。沿用 lfrledh 的提交署名，在提交说明注明由 Codex 完成的工作。
- 以小型工作包分配实现：明确行为、接口、不变量和验收标准。代码和测试是接口事实来源；不预先为全项目每个函数维护一份重复的提示词。

## 本机路径与验证

主项目 /Volumes/CodexProjects/Codex/D；应用产物和日志使用同级 D-Development；新核心测试scratch使用同级 BuildCaches/D-Foundation，避免Swift调试路径前缀碰撞。均优先外置SSD。

- 新核心：`./scripts/test-foundation.sh`（Swift 6，无模型下载）。
- 原应用：`./scripts/build-local.sh`（Xcode，原锁定依赖）。
- 报告、ADR、README随实际边界变化更新。无需每次手工更新project_tree.txt；若需要目录树应排除.git、缓存和构建产物。
- 真实MLX集成另行验证输出、峰值内存、取消后停止和多次加载/卸载。原有空模板测试不能作为这些能力的证明。
