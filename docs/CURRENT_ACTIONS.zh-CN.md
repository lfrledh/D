# 当前行动与接手点

最后核实：2026-09-27。唯一当前任务、版本与停点入口。

## D-NODE-LANGUAGE-01：集中验收与源接纳完成

18个通用节点、记录/列表/条件/Map/有状态Loop/可选人工任务/真实版本化工具与四套可编辑样例已实现。Qwen、FLUX.2 Klein、MRT2、Wan T2V与SwiftF0接通既有Store/运行时；没有按样例名字另造调度器。范围、逐项A01—A36与版本证据见[任务记录](tasks/D-NODE-LANGUAGE-01.md#当前验收检查点2026-09-27h27已实际办理)。A01—A36已按冻结范围验证；源已快进接纳并完成源入口回归与普通构建，不代表发布。

源`codex/inference-foundation`已从`130603d23a4da81ba2a9852766f3589695ec9468`快进到`ccdbdf917c1ec569cccb6c2820056e898f93d871`。候选`codex/d-node-language-01`与外盘`D-Worktrees/D-NODE-LANGUAGE-01`保留在ccdbdf9。原生/离线受测代码`08b2e39614113e4de386e4146ef33cbc00c75d59`到ccdbdf9仅四份文档变化；源入口UI包和普通D Nodes构建实测为ccdbdf9。后续结案仅改当前行动、任务记录与试用说明，最终完整SHA和远端同步结果写H/`integration/final-receipt.json`，不自引用。

源入口UI167、独立入口23、Workbench605及XCTest30各组通过；4项显式opt-in跳过，不当作真实模型新验收。四引擎与准备目录逐文件一致、开发签名完整性通过。历史5b49的UI/Runtime/资源检查、a083的UI包全量、各真实模型及修补证据仍分别保存，不改称同一版本全量模型重验。

证据根R：`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-NODE-LANGUAGE-01/run-20260926T150929Z`；H：同任务`run-20260927T020614Z-h27`。最新索引为R/`delivery/acceptance-results.json`、H/`evidence/`，旧R/`lead/final-receipt.json`是锁屏时历史，不是当前回执；当前源接纳/保护/源检查均在H/`integration/`。

## 可以怎样试用

从[试用说明](NODE_LANGUAGE_TRY.zh-CN.md)打开源`/Volumes/CodexProjects/Codex/D/D.xcworkspace`，选 **D Nodes / My Mac** 点Run，或双击H/`delivery/启动H27确认版.command`。实际普通包为H/`delivery/D Nodes H27 Pinned.app`，代码08b2e39。试用身份与普通D隔离，普通App未替换。准备的四引擎由正常Xcode构建阶段复制并签名，无构建后手补；权重独立导入。旧M0试用入口仍保留但不是本批主入口。

已在普通界面验证：本人新录音/原声试听、SwiftF0片段、人工音符/和弦与MRT2三候选、本人音乐试听；Qwen文字、Klein单参考出图、Wan短视频播放；原生工具封装/嵌套/双实例、模板与单位反例、旧确认恢复、历史结果局部运行、尺寸格式处理和多媒体导出。当前参数与历史冻结值分别可查。08b2e39重新在Xcode点Run并打开E01—E04，保存项目可重开。

本轮A35真实物理离线5方法通过，409采样及路由全程离线；结束后用户恢复网络。无需重复断网/录音/日文/试听。集中待办H27已实际办理；[本人事项清单](FAILURE_AND_PERMISSION_AUDIT.zh-CN.md)持续记录新锁屏、离机、设备或本人点击阻塞。

## 边界、保护与未完成责任

- 个人scheme未暂存`orderHint 1→6`，SHA256`ca3635d88aa5a15397b90e528667c66c0e6db7e596176e885c79d194b544206c`，index blob`9c76916bdc97c2d4298cefe64e0b0fae3380573e`。逐次源接纳前后核对，不暂存、不恢复。
- H22输入法候选窗不跟随按用户决定延期；中文/日文确认正常不代表H22修复。历史增多时保存仍慢；缓存与重复编译修补有限改善，不能称普遍流畅。Xcode负几何警告/缩放AX命中体验问题保留，不归因内存上限。
- 图像/音乐/视频本机profile是验证样本，不是产品上限；Wan 4步短片画面抽象，MRT2音频控制近似；本轮不保证艺术质量或转谱准确率。
- AP1`e5d24f4e1064423238e3c8e1112bc4b3a9a81e2e`、CORE`9d3a503d327a820cb67e399922a07c27f953e903`及I2V研究未合入、未删除。格式16不代表旧候选迁移已解决。
- 内部Pitch引擎含已追踪评估权重；正式无附带权重、分发许可、部署/首次使用与发布渠道仍有责任。没改签名策略/权限，没发布或推进main。
- 自有GUI/重模型/构建已结束；写Worker均交还，只读验收协助不写仓库。源接纳和源入口回归完成，候选与旧证据保留，不自动开启下一产品批次。

## 下一动作及下一阶段提案

本轮停在可审计的开发试用检查点。最后仅提交结案文档并同步既有工作分支，结果以H/`integration/final-receipt.json`及远端完整SHA为准；不发布、推进main或开始新产品任务。锁屏/离机/本人操作的新阻塞继续进入集中清单。

下一有限提案：以用户试用反馈为入口，优先解决积累运行历史时的保存/响应成本与节点操作可达性，在既有数据保护下实测；不再增加新模态或专用样例调度。是否开始由用户审阅本批后决定。导航和扩展约束见[仓库地图](REPOSITORY_MAP.zh-CN.md)、[边界与语言](BACKEND_EXTENSION_CONTRACT.zh-CN.md)。
