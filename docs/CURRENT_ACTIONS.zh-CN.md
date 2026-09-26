# 当前行动与接手点

最后核实：2026-09-26。**本页是当前任务、版本、停点与下一动作的唯一入口**。历史任务与未接纳候选不自动授权续跑。

## 当前任务：M0与节点边界集中验收、同步

用户批准集中办理本人操作、完成验收后同步GitHub，再由用户审计决定下一阶段。本批不增加新功能，不恢复AP1/CORE/I2V，不公开发布。

**本批集中验收与本地接纳已完成。** H25/H26关闭，源入口CPU与独立App构建通过；按本轮授权同步GitHub后停交用户审计。 最终回执/远端状态写外部证据，不为提交自身SHA反复amend。

| 对象 | 完整版本与状态 |
| --- | --- |
| 源 | `/Volumes/CodexProjects/Codex/D`；分支`codex/inference-foundation`；从`58603870719a52ff07b6bb6e4d6d09e02c23901a`快进至`15ee8495deb4ff0da10a62ae03c05cbf890278f7`，随后仅结案文档 |
| 实际受测生产代码 | `76bd5963c779c74268c69fa6a4851533768ea4c3`；到15ee849仅5份文档。新原生/离线补验使用此代码的固定产物；源入口CPU与App构建以15ee849为HEAD，工作文件仅文档变更 |
| 保留M0候选 | `D-Worktrees/D-M0-01`，`codex/d-m0-01`，`bbf508024a80250b9e4b468e1f5713b7b13dcc13`；未改此树，历史试验与预算保留 |
| 保留边界候选 | `D-Worktrees/D-NODE-BOUNDARY-01`，`codex/d-node-boundary-01`，`15ee8495deb4ff0da10a62ae03c05cbf890278f7`；已纳入源，工作树保留 |
| 本次证据R | `D-Development/AgentTrials/D-NODE-BOUNDARY-01/run-20260926T073533Z-acceptance/`；最终版本/远端对应以`evidence/final-receipt.json`为准 |
| 原实施证据 | `D-Development/AgentTrials/D-NODE-BOUNDARY-01/run-20260926T045011Z/`与M0任务中的固定索引；旧结果不冒充重跑 |

表中相对绝对根为`/Volumes/CodexProjects/Codex/`。内盘Documents/ChatGPT/D空仓库不是工程。

## 本次实际通过与证据边界

- **H26普通App原生**：中英/外部JSON语言包导入与缺词回退，Unicode草稿/选区保留；同图两个改写节点明确选择Qwen0.5B和1.5B并串行真实运行；正常退出、同一隔离偏好重开后语言/草稿/图/绑定/运行历史仍在。见R`evidence/gui-summary.json`和`gui-*.txt/png`，不改普通App或真实作品。
- **H25/T15真正断网**：本人关闭本机Wi-Fi后，固定生产App工厂的文字→确认→三图候选→选择→尺寸/JPEG导出→保存重开与真实取消/释放通过；Swift Testing实际1项，101.070秒。执行/结束100次采样全离线，无路由恢复事件，结束后本人恢复网络。见R`offline-confirmed`。这是本机已准备模型的离线执行，不是无网络调用审计、模型安装或干净Mac发行。
- **源入口CPU/hosting**：同一15ee849，从源目录重编并通过127 UI、23 ModelLibrary、459 DWorkbench；R`source-ui/result.json`。选择器迟到、坏语言包、格式反证、保存/取消/生命周期等依旧由对应自动反例检验，原生模态选择器不冒充并发回调实验。
- **源App重建**：通过，73.32秒；codesign完整性与app-sandbox核对通过，结果见R`source-app-build`和`evidence/source-app-manifest.json`；使用原签名配置、独立DerivedData和已存在的固定依赖，不替换此前原生受测App。构建成功不自动证明新产物又做了一轮GUI。
- 原实施阶段完整测试/真实模型、非实现者审核与新上下文接手复用[边界任务](tasks/D-NODE-BOUNDARY-01.md)；M0 T01—T14的历史分层限制仍见[M0任务](tasks/D-M0-01.md)。不把历史/本轮样本数相加编造总通过率。

首轮新断网包装仍未启动，保留R`offline`。本机`route`无路由时exit0而stderr为`not in table`，scutil实际措辞也与旧条件不同；修正为无线电/所有非回环活动链路/可路由地址联合判据，原始状态/路由日志留证。未修改产品代码或放宽T15契约，不把该次未执行算通过。

## 已接入的能力及边界

M0可编辑图文、文字、文件、模板组合共用原项目Store、文字会话和DRuntime；人工确认不自动继续昂贵生成，支持候选采用、尺寸/格式处理、导出、保存恢复、局部重跑和来源检查。各执行节点冻结自己的模型身份/实现/配方，不借当前可见页面模型；缺失/不兼容拒绝，取消后drain/release再交资源。

`Workflow/Operations`组织文字/图像/资产操作；`Workflow/Models`承接绑定/配方/私有书签；`Media/ImageCodec{,Registry}`分离PNG/JPEG差异；`UI/Localization`及JSON资源负责纯数据语言包。新增同类能力可在相应模块适配并静态登记，不等于动态插件、任意模型或音视频任意连线。旧模态页/服务消息尚未完整国际化，模型安装及其他应用接线仍有已记录责任。

实际路径及扩展规则见[导航](REPOSITORY_MAP.zh-CN.md)、[扩展/语言约束](BACKEND_EXTENSION_CONTRACT.zh-CN.md)；试用从[已验工作台使用说明](M0_TRY.zh-CN.md)开始。

## 保护、候选与停止位置

- 源仅保留个人scheme未暂存修改`orderHint 1→6`；SHA256 `ca3635d88aa5a15397b90e528667c66c0e6db7e596176e885c79d194b544206c`，index blob `9c76916bdc97c2d4298cefe64e0b0fae3380573e`。不暂存、自动还原或清理此文件。
- AP1 `e5d24f4e1064423238e3c8e1112bc4b3a9a81e2e`、CORE `9d3a503d327a820cb67e399922a07c27f953e903`及I2V研究未合入；未删除分支/工作树/证据。图格式16不代表AP1/CORE13—15迁移已解决。
- H25/H26和旧设备/协议权限无需重复办理；H22输入法候选窗位置仍按用户决定延期，未改记修复。人不在、锁屏、设备或本人点击引起的新阻塞持续入[集中清单](FAILURE_AND_PERMISSION_AUDIT.zh-CN.md)，返回时集中处理。
- 本次自有GUI/断网/源测试与构建进程已结束；最终进程与Git状态在外部回执核对。没有后台等待、无限开发或自动启动下一批。

**下一动作：完成本批同步后停下，等待用户审计决定下一阶段。** 不自动扩展节点、恢复旧S6、AP1、CORE、I2V或发布。发行还需既定无权重/运行依赖封装、首次使用/升级恢复、渠道/签名及明确首发范围验收；本批验收不替代这些门槛。
