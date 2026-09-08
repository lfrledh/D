# D 的 Mac 授权与无人值守开发方案

更新：2026-09-08。状态：本机开发签名连续验收已通过，包括同次完整UI、普通签名真实生成/导出和全新构建后的项目/模型恢复。下文2026-09-07段落保留历史背景，最新结论见文末；不是永久免授权或发行验收。历史失败归档见 [审计清单](FAILURE_AND_PERMISSION_AUDIT.zh-CN.md)。

目标是让**已授权位置内的常规构建、测试、生成和保存能够连续运行**。不能承诺一次操作永久消除系统授权：新增资源、权限撤销、应用身份变化及部分系统安全界面仍可能需要本人确认。

## 为什么 Codex 能访问，D 仍可能被询问

| 层次 | 实际作用 | D 的处理方式 |
| --- | --- | --- |
| 系统隐私权限（TCC） | 对 D、Xcode 等负责应用分别记录“可移除宗卷”等访问决定。Codex 能读写不证明另一应用已获授权。 | 在系统提示或“隐私与安全性 → 文件和文件夹”检查实际请求的应用。 |
| App Sandbox | 限制 D 能访问哪些具体文件；系统外盘开关不自动把整盘加入应用沙盒。 | 经原生打开／保存面板取得所选资源授权。 |
| 持久访问书签 | 记住曾获授权的位置，使重启后可以重新取得访问。 | 当前项目与模型服务已保存安全作用域书签，并在使用期间保持访问；失效时重新选定位置。 |
| 签名身份 | 帮助系统识别更新前后是同一应用。 | 应将长期开发版本从 ad-hoc 改为稳定的 Apple Development 签名。 |

Apple 将 App Sandbox 与系统强制访问控制区分为独立机制，并说明临时签名可能导致更新后重复询问。[Apple 权限机制说明](https://developer.apple.com/forums/thread/678819)。书签由取得授权的应用创建和恢复，不能只保存路径字符串。[Apple 沙盒文件访问指南](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)。

## 先完成的工程准备（D-C01a）

签名切换前的历史检查结果：D 的 bundle ID 是 `first-test.D`；Debug 配置为 `CODE_SIGN_IDENTITY = "-"`、空 Team，实际二进制显示 `Signature=adhoc`。这是最初为了快速恢复本机构建采用的设置。钥匙串可枚举到一个有效 Apple Development 身份；**只检查了身份可用性，没有导出私钥、签署新版本或更改钥匙串权限**。

建议在集中人工授权前实施一个小工作包：

1. 为本机开发构建设置现有 Apple Development 身份和匹配 Team，检查 D 与测试宿主／runner 的签名配置。用本机配置保存账户选择，通用仓库仍保持可配置，不硬编码其他开发者必须使用此账户。
2. 保留当前 `first-test.D`、现有容器数据和稳定启动路径；避免这时同时改 bundle ID、搬应用或清空书签。签名改变后若旧授权不能恢复，通过原生选择原位置续接，不删除项目／模型或伪装成新安装。
3. 保持 Sandbox、用户选择读写、app-scope bookmarks 和客户端网络权限；不通过关闭沙盒或增加测试临时例外解决权限。检查并补充适用的外盘使用说明 `NSRemovableVolumesUsageDescription`，说明用途；说明文字本身不授予权限。[Apple 用途说明 API](https://developer.apple.com/documentation/bundleresources/information-property-list/nsremovablevolumesusagedescription)。
4. 正常构建后检查实际签名、Team 和 designated requirement。证书存在不保证首次使用私钥不会出现钥匙串确认；如出现，记录实际签署程序与提示，交由本人处理。
5. 授权完成后执行下面的连续验证。该工作包属于开发可靠性，不提前启动参考图／新模态产品阶段。

仅把 D 加入“完全磁盘访问权限”不能取代正确的沙盒文件选择与书签，也不能授权 Xcode runner。正常工作流不需要以全盘访问作为前提。

## 回到 Mac 后如何操作

建议在上述稳定签名版本准备完成后做一次；如果先给当前版本授权也可以使用，但下次临时签名构建仍可能再次询问。

1. **打开正确的 D。** 在 Finder 按 `⌘⇧G`，进入 `/Volumes/CodexProjects/Codex/D-Development/DerivedData/Build/Products/Debug`，打开其中 `D.app`。继续使用这个开发版本，避免同名旧副本混淆。
2. **检查系统外盘权限。** 打开“系统设置 → 隐私与安全性 → 文件和文件夹”，展开 **D**，若有“可移除宗卷／可移动宗卷（Removable Volumes）”，开启它。若系统要求退出重开，照做。对 **Xcode** 的现有对应条目也检查一次，历史 MLX runner 的请求归属 Xcode。[Apple 操作说明](https://support.apple.com/zh-cn/guide/mac-help/mchld5a35146/mac)、[受保护位置说明](https://support.apple.com/en-asia/guide/security/secddd1d86a6/web)。
3. **在 D 内连接原模型库。** 打开模型管理，使用“更换或重新授权…”选择原模型库根文件夹。本轮真实安装使用 `/Volumes/CodexProjects/Codex/D-Development/Validation/ModelLibrary-20260907`；最终以界面记录的原位置为准。选择包含 `.d-model-library` 的根文件夹，不把里面某个权重文件当作模型库。已经可用时无需重复登记或重新下载。单独登记的外部模型若失联，则使用该模型自己的“重新定位或授权…”选择完整权重文件夹。
4. **在 D 内打开原项目。** 使用“文件 → 打开”选择 `.dproject`。本轮验证项目为 `/Volumes/CodexProjects/Codex/D-Development/Validation/Exploration-20260907/Visual Exploration.dproject`。这是给 D 的具体项目授权；仅把路径告诉 Codex 不能替代。若项目已自动恢复，则这一项已经满足。
5. **只回应实际出现的系统提示。** D 请求外盘访问时允许；运行 Xcode 测试时如果出现属于 Xcode／测试执行器的提示，分别处理。无需把 D 的辅助功能权限当成出图前提，D 自身不靠操控其他应用来生成。
6. **退出并重新打开 D。** 确认同一项目的作品、草稿与模型状态恢复。之后由开发验证执行一次生成、保存和新文件导出，并检查日志。

若“文件和文件夹”里没有 D：这不单独证明访问被拒绝。先从正确版本的 D 经原生面板打开外盘项目／模型库；系统可能通过明确文件选择获得所需同意，或在需要时显示单独提示。这个列表不是任意拖入应用预授权的列表；若仍失败，记录错误、应用签名及系统提示归属再诊断，不反复重置权限。[Apple Developer 对列表和临时签名的解释](https://developer.apple.com/forums/thread/125438)。

## 怎样尽量避免以后还要人工介入

- **使用稳定身份与原位置。** 同一签名身份、bundle ID、用户会话及已授权目录是常规连续开发的前提；保留授权书签和项目记录。证书／系统升级后的行为仍以复验为准。
- **区分文件选择与系统授权。** 打开新项目、选择新导出文件是正常的产品交互，自动化可以操作普通原生面板。安全工具明确拒绝访问的系统授权界面不能据此自动点击；首次或撤销后的授权仍需本人完成。
- **测试先检查执行环境。** 小 CPU 夹具留在 runner 自己的临时目录；大模型、缓存及证据留外盘。先确认 runner 确实进入用例，再等待测试结果；遇到授权等待就记录缺项，避免把启动超时当计算失败。
- **XCTest 后恢复普通构建。** 测试可能改变宿主签名；真实沙盒验证必须先重新正常构建并确认无测试权限例外。
- **未来按需要加入“默认工作目录”。** 当前已有项目和模型书签，但没有通用的“授权整个工作根目录＋默认导出目录”功能。若要无人值守创建多个新项目和批量导出，应另实现明确的默认目录、持久授权、写入预检和失效恢复；不能把选一次 SSD 误说成现有产品已支持自动管理整盘。

建议验收顺序：稳定签名正常构建 → 本人集中处理实际提示 → 既有项目／模型恢复 → 一次完整 8 项 UI 测试 → 恢复普通签名 → 真实生成与导出 → 小改动重建 → 不再手选位置而重开恢复。只有这条跨构建链路通过，才能把“当前开发流程已具备连续运行条件”记为验收；它仍不是永久不再授权的保证。

本方案不要求现在远程输入密码，也不要求重置 TCC、修改系统数据库或移除系统保护。用户回到 Mac 前，可以继续文档、源码审查和不触发新授权的已有验证工作。

## 2026-09-07 本机授权设置检查点

用户回到 Mac 后授权先处理环境与应用授权；本轮由原 Lead 直接执行，没有 Worker、GPU 生成、XCTest、远端操作或新产品阶段。应用源码基线为 `c14f892cacd69ce909e368c03db9b69c7dac1db8`。本轮共享修改仅为构建脚本读取本机签名配置及本节／当前行动记录。

- Codex 项目已改指向 `/Volumes/CodexProjects/Codex/D`；原内盘空仓库未操作。用户同时将主会话改为 full access。这不是“仅外盘可写”的隔离证明，后续 Worker 仍必须使用独立受限配置。
- 系统设置实读：ChatGPT、Xcode 显示完全磁盘访问权限；DUITests-Runner 的可移除宗卷开关已开。普通 D 没有单独条目，但项目与模型书签能够恢复，不能据此判定 D 被拒绝。本轮未改 TCC 数据库、全盘权限或钥匙串 ACL。
- 本机现有 Apple Development 证书有效至 2027-04-03，Team `3V4T79WLQS`。首次构建观察到 codesign 等待与 SecurityAgent；电脑控制工具拒绝访问安全窗口，未读取／输入密码。随后 `codesign --dryrun` 对任务副本真实调用私钥，退出 0，副本 SHA-256 前后相同；不能据此断言用户选择了某个永久允许选项。
- 独立 DerivedData 正常构建退出 0（74.166 秒）；实际产物使用 Apple Development 证书、同一 `first-test.D`、Hardened Runtime，严格／深层签名验证通过。Sandbox、用户选择读写、app-scope bookmarks、客户端网络及普通 Debug 的 get-task-allow 均保留，无测试临时例外。补充了外盘用途说明。
- 经正常退出旧实例，在原路径安装签名版并重新打开。原三份创作文档、7 条历史任务、提示词／seed、模型库两条安装记录恢复，生成按钮可用；没有重新选择目录或重新登记模型。已知项目 8 个文件的字节摘要全部保持一致。此为 CUA 恢复检查，不是生成或完整 UI XCTest 通过。

### 后续构建入口

`./scripts/build-local.sh` 默认读取同级 `D-Development/Configuration/DevelopmentSigning.xcconfig`；本机文件只含公开签名身份选择、Team 和外盘用途说明，不含私钥、不入 Git。也可显式设置 `D_SIGNING_CONFIG=/absolute/path/to/DevelopmentSigning.xcconfig`；显式指定不存在文件时退出 2。未配置本机文件的其他机器仍沿用工程原设置。配置路径包含空格／非 ASCII、无默认配置、显式缺失配置的 3 个 CPU 参数夹具通过，另有 Bash 语法检查；夹具不算真实构建。

Xcode GUI 的工程 Debug 设置没有更改，直接点击 GUI Build 仍可能产生 ad-hoc 版本；当前稳定签名入口是上述脚本，或为明确的 `xcodebuild` 操作传入同一 `-xcconfig`。后续测试必须给宿主和 runner 同一签名配置，测试后恢复普通构建。不能把这次首次切换恢复写成“以后任何构建都不会再询问”。

### 本轮构建意外与恢复

第一次尝试复用原 DerivedData、只改变 CONFIGURATION_BUILD_DIR，运行期间原 Debug/D.app 消失，目标目录只有空骨架。怀疑是共享构建状态导致产物失效／清理，但日志没有直接记录移除动作，机制仍属推断。Lead 在检查完成前曾称原产物不变，发现后已纠正；只停止本轮 xcodebuild 及其子进程（退出 -15），未终止当时的 D。

随后以未改源码和原 ad-hoc 设置在原位置重新构建成功（57.947 秒），严格签名检查通过，并备份完整应用后再做完全独立 DerivedData 的签名构建。恢复产物是新构建，部分二进制摘要与历史不同，不能冒充旧产物原字节还原。当前安装的正式签名版和切换前恢复版均保留；源码、个人 scheme 排序修改及已知项目文件受保护。后续隔离构建必须连同 DerivedData 一起隔离，修改前先保存完整可运行产物，而不只记录摘要。

### 证据与停止边界

持久目录：`/Volumes/CodexProjects/Codex/D-Development/PermissionSetup/run-20260907T134650Z`。关键索引：`artifact-incident.json`、`artifact-recovery.json`、`signing-access-probe-result.json`、`stable-build-result.json`、`stable-signature-checks.json`、`signed-app-install.json`、`installed-app-diagnostic.json`、`permission-setup-checkpoint.json`。保留构建日志、xcresult、应用和约 2.1 MB 已知项目备份，不默认入 Git。

D-C01a 尚未整体结案：完整 8 项 UI XCTest、真实签名版生成／导出、再次签名重建后恢复均待验证；D-C01a-RESULT-01 的既有候选仍暂停、未在本轮接纳或集成。没有启动 D-P01、双 Worker 或推送。主会话恢复时先核对 Git 状态、已安装签名、运行进程与本机配置，再进行下一项验证。

## 2026-09-08 连续验收结案

用户本轮确认普通D保存退出、GUI/GPU空闲并随后取消本阶段时间限制。只在独立测试项目、会话与完整独立DerivedData中执行；原D.app未替换。代码a6c516ad6b52c944ce70a0bd764d68a94fd0f3bc：同一结果包8项UI全部通过，之后重新普通签名构建，确认App Sandbox和既有授权entitlements，无测试临时例外；真实Qwen改写、FLUX q8 512²生成及原生新文件导出通过。再用全新DerivedData构建，二进制/签名资源摘要确有变化；同一开发身份和bundle ID的产物自动恢复测试项目/蓝杯图片/FLUX模型可访问状态，PNG草稿、旧v2及文字正文/Qwen选择均恢复，没有新系统授权提示。

模型可访问结论来自应用实际恢复书签、检查目录身份/文件条目及GUI状态；本次重开没有重新跑模型数值基准或逐字节权重摘要，也不声称未来所有系统/证书/路径变化都可免授权。首次真实模型生成和历史数值验收另有独立证据。只有现有脚本/本机xcconfig签名入口被验证，直接Xcode GUI默认设置并未因此改变。

代码通过后以固定组合685ef0502586bc5785826a3dc938622d8401f0e7本地接纳，源目录165方法复验通过。证据与最终文档SHA见D-Development/AgentTrials/D-T0-WORKBENCH-01/run-20260908T125225Z-human-finish/final-stage-receipt.json；具体final-fresh-restore、gui3-signature/exit、uitests-refined、image-normal-signed-result及normal-fresh-rebuild。上述旧段落“仍待UI/生成/重建恢复”和“RESULT未接纳”为历史停点，本节覆盖。

当前无待人工安全弹窗，后续统一维护FAILURE_AND_PERMISSION_AUDIT的人工清单。通用默认工作根/批量自动导出授权、物理拔盘断电、完整可访问性与发行公证仍按各自后续范围处理，不把它们算作本轮未完成事项，也不提前标记已实现。
