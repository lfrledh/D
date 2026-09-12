# D 项目协作与架构规则

## 2026-09-13 当前协作规则（覆盖下方历史人数上限）

用户取消项目层面的子代理数量上限，由 Lead 按任务就绪度、耦合、风险、实际工具额度及审核吞吐决定每批人数与模型；不是无限同时执行、无限返工或新增产品授权。沿用独立受限 CLI、逐任务工作树/写根/模型核验、禁止递归、原修复预算和组合验收。重型构建、GPU 和 GUI 仍由 Lead 排队。较低成本模型只接收到已消除关键歧义的任务：直接给出输入输出、状态/错误、关键反例、独立验收依据与允许路径，而非整份项目历史或逐函数答案。当前细则见 [协作规程](docs/MULTI_AGENT_WORKFLOW.zh-CN.md#2026-09-13-按任务就绪度分配人数与模型当前有效)；下一阶段范围见 [D-MRT2-WORKBENCH-01](docs/tasks/D-MRT2-WORKBENCH-01.md)。下面按日期保留的 0—2 限制是历史，不再作为当前人数政策。

## 阅读与范围

D 是面向专业 AI 创作者、兼顾初学者的原生 Mac 本地推理工作站。先读 docs/CURRENT_ACTIONS.zh-CN.md，再读 docs/PRODUCT_GOALS.zh-CN.md 的相关目标行、相关 ADR 和源码。历史研究、测试数量与旧规划只按需加载；它们不是当前执行状态。不要每轮重读全部 docs/history 或原始计划。

D-F03／D-M01 已验收：现有 UI package 内含真实 DWorkbench 服务 target 和模型安装管理，保留单项目流程。已确认总体战略见 docs/PRODUCT_STRATEGY.zh-CN.md；D-W02 / D-W04a 多文档探索与比较已验收，见 docs/EXPLORATION_STAGE_ACCEPTANCE.zh-CN.md；后续工作包尚待审批。快速草稿、远程 API、对外服务、RAW 等按目标表启动，不因规划存在就实现空入口或框架。信息架构见 ADR 0007，服务演进见 ADR 0008。

## 不可破坏的边界

- DInference 只含值型契约，不依赖 DRuntime、MLX、网络或 UI；DRuntime 只依赖 DInference 和标准库／Foundation。
- DWorkbench 拥有项目、资产、下载、模型安装与应用任务；UI 只保留展示和原生交互；D 应用注入具体 runtime／backend。服务接口不泄露 MLXArray、ChatSession、NSImage、窗口或书签。
- 项目、创作文档、资产、任务、模型身份和安装实例分别管理。模型及固定 revision 不因目录移动改变；任务提交后条件不可变。
- 状态隔离和执行所有权解决并发。不得为了消除编译诊断批量添加 nonisolated、nonisolated(unsafe) 或 unchecked Sendable。actor 的 await 可重入，整次推理需要显式许可。
- execute 返回前必须 drain；release 完成前不得放行下一重任务。文本与图像共用进程级 MLX 许可。取消是请求，终态必须反映真实停止和清理。
- 后端空闲／shutdown 后才能 cleanupUnpublishedArtifacts，只处理本实例跟踪的未发布文件；不得扫描作品根目录或删除已发布作品。
- 排队任务持有模型安装使用权，释放前禁止移除／迁移。下载状态、完整校验、操作兼容和硬件预算不能混为“已安装即可运行”。索引与暂存放在后端模型树之外。
- 原件和已交付作品不可静默覆盖；未知文件不猜测删除。保存失败、外盘失联、空间不足、损坏数据须明确报告。外盘不可用不静默回退内盘。
- 大媒体通过资源引用传递；原件、派生、预览分离。未知位深、色彩等保留未知；PNG 实现不是 RAW 支持。
- 导出只能使用目标文件授权：系统同卷临时目录准备完整文件后原子、不覆盖地发布，不能假设可在目标目录创建 sibling 临时文件。发布后同步失败仍保留结果。
- 项目 v2 必须安全迁移 v1，先保留原始清单备份再发布，不改媒体。界面、项目格式、内部 Swift 接口和未来外部协议分别演进；迁移须有数据保护和测试。
- 不创建空的未来包。UI、专业模式、助手与工作流的应用操作共享服务，不另起绕过保存和调度的生成路径。

## 依赖、协作与交付

- 用户已授权升级、替换、修复第三方依赖或自行实现；说明可复现问题、影响、方案与验证。补丁进入可重复检出的固定源码，记录来源、许可证和回退条件；不能只改 SwiftPM checkout。
- 直接检查源码与 Git 状态；保留用户已有修改。Packages/* 是主仓库普通目录，不创建嵌套 Git 仓库。来源见 docs/history/SUBMODULE_PROVENANCE.json。
- 独立子任务可以并行；共享目录编辑须分配互不冲突的文件。工作包使用 docs/TASK_SPEC_TEMPLATE.md，不为全项目每个函数维护重复提示词。
- 新目标先进入目标表，记录价值、优先级、依赖和验收；不自动扩大当前工作包。重大取舍按最新用户决定，不由历史文档替代。
- 只把实际运行结果写成通过。分别报告构建、CPU fixture、真实网络、CLI、MLX XCTest 和 UI；build-for-testing、跳过或启动超时不能记为执行通过。
- 阶段完成并验证后已获授权 commit／push 到现有工作分支，不反复求确认，不强推或合并主分支。沿用 lfrledh 署名，提交说明注明 Codex 完成的工作。
- 每次验收更新当前行动、目标状态和证据链接；历史报告保留当时事实，不用新结果覆盖。README 随实际边界更新，目录树不是必需交付。

## 本机与验证

主项目 /Volumes/CodexProjects/Codex/D；产物、模型、日志使用同级 D-Development；纯核心 scratch 同级 BuildCaches/D-Foundation，MLX 同级 BuildCaches/D-MLX，工作台同级 BuildCaches/D-Workbench。统一入口 D.xcworkspace。App／MLX 的 SwiftPM checkout 分别 SourcePackages-App／SourcePackages-MLX，不链接到同一可变检出目录。

用户已授权下载模型和真实推理。M4／16 GiB：评估权重、上下文／KV、工作区和系统余量，默认单重任务；外盘容量不等于运行内存。保持 Metal 资源随二进制部署。

- `./scripts/test-foundation.sh`：纯核心，无模型。
- `./scripts/test-workbench.sh`：工作台／应用服务／模型库 CPU 测试，外盘缓存。
- `./scripts/build-local.sh`：普通沙盒应用。
- `./scripts/build-mlx.sh`：CLI；文本、图像调用见 docs/MLX_REFERENCE_GUIDE.zh-CN.md 和 docs/IMAGE_RUNTIME_GUIDE.zh-CN.md。
- `./scripts/test-mlx.sh [文本目录] [图像目录]`：完整固定模型验证、图文实际测试、零失败／零跳过。CLI 完整验收分别为 scripts/verify-mlx-cli.py／verify-image-cli.py；offline-only 不能算真实推理。
- `./scripts/test-mlx-ownership.sh`、scripts/verify-mlx-vendor.py、scripts/verify-flux2-vendor.py：所有权和固定补丁；按改动影响复验。Vendor 约束见 Vendor/README.md。
- XCTest 会临时修改宿主签名；之后重新普通 build，确认没有测试权限例外再验收真实沙盒。CUA 实测不能冒充 XCTest UI 通过。
- 修改推理算法／生命周期时验证输出、峰值、取消后停止与重复加载释放；仅 cacheBytes 为零或短期阈值不证明无泄漏。按实际活跃分配趋势解释残留。
- 已验收基线见 docs/FOUNDATION_STAGE_ACCEPTANCE.zh-CN.md、docs/IMAGE_RUNTIME_ACCEPTANCE.zh-CN.md、docs/WORKBENCH_ACCEPTANCE.zh-CN.md 和 docs/MODEL_LIBRARY_ACCEPTANCE.zh-CN.md。B1 独立实验的残留是历史证据，不能代替 B2 测量。

## 2026-09-08 v7 有限切换批次（覆盖旧并行／阶段待批描述）

用户已批准 RESULT 恢复及 T0/META 首组有限产品实施。Lead 单一管理契约、源集成和共享文件；独立 CLI Worker 各有核验工作树／模型／受限写根，最多两个子执行或审核任务活跃，不递归。先读当前任务规格，再按需读 [协作规程](docs/MULTI_AGENT_WORKFLOW.zh-CN.md) 的副作用／停止／集成规则。普通新任务初交＋两轮修复，既有任务预算不刷新；重要 Lead 实现需非实现者检查。未知权限事件暂停并报 Lead，预先限定的安全降级才可恢复一次。当前只批准本地提交／集成，不 push、安装或更改签名／权限。切换状态以 CURRENT_ACTIONS 证据为准，未证明双执行和组合验收前不宣称默认已启用。

2026-09-08结案：D-T0-META-01已证明双任务真实并发、受限路由、非实现者审核、组合CPU与源接纳；默认按就绪度使用0—2 Worker，详细检查点见 CURRENT_ACTIONS / docs/tasks/D-T0-META-01.md。这个状态不批准尚未细化的下一产品目标，不等于T0 GUI、PNG或音乐已交付；本批不推送。
