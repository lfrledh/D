# D 开发预览：本轮试用

2026-10-03 · D-RELEASE-FREEZE-01 / D-DISCUSSION-FREEZE-20261002。正常签名App产品代码为 **1e2501faed39fab954bbb205bc556ea537916219**，CPU受测 **43d6ab3e51583a31e7c8a08ac60911a6be9ddcce** 仅追加测试夹具修正；之后仅文档。普通构建和签名完整性通过；新包进程启动后桌面再次锁屏，**本包完整原生操作未通过**。main更新不等于功能冻结/正式发行。

## 唯一推荐启动入口

双击：
`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261002T160047Z-native-closeout/delivery/启动D开发预览.command`

它启动同目录 **D Native Closeout.app**。如提示另一份D正在运行，请先自行保存并退出旧D，再重试；启动器不会关闭或替换旧App。使用独立持久试用身份`4DFA8D40-45FA-4BA0-934C-F034F36E2D60`，与同树D Nodes scheme一致。既有试用项目保留，建议先新建测试项目，不迁移正式作品。旧启动器仅保留历史，不作为本轮入口。

## 先试文件功能，无需重新运行模型

1. **更多 → 模型下载与安装 → 登记已有模型**：选真实固定模型，再选“保留原位置”或“复制到模型库”。复制模式需先选择模型库根目录，仅复制实际需要的文件，源目录的README、sidecar、缓存等不删不改。未准备资源会明确显示待准备，不能当成推理就绪。
2. **资料库 → 导入素材**：文件面板提供“复制到项目（默认）”和“引用原位置”。引用需要原盘连接；任务会固定输入版本，外部变动不能改写历史。先用一份可丢弃的小测试文件，保留原件。
3. 打开项目后点顶栏 **项目文件**（更多菜单也有），选素材检查已知位置、摘要、状态、登记/文件时间及本项目已知使用计数。可核对内容、定位同版本文件/文件夹、复制入项目或独立资料库；“收纳项目媒体”批量保留项目所需媒体。不同字节应作为新素材导入，不自动接管旧历史。
4. 在该页 **创建手动备份**：备份会先保存当前Quick/Canvas草稿；默认元数据+媒体，不含模型/缓存。模型可选，但大模型会明显增加空间/时间，原始待准备资源备份后仍需准备。失败/取消保留原件；缺失必须明确选择不完整备份，不会自动声称完整。
5. **恢复手动备份**：选择备份和一个尚不存在的`.dproject`新位置，再点“打开已恢复项目”。恢复拥有独立实例，不覆盖原项目，保留逻辑资产/来源；模型如包含在Models目录仍需正常登记，设备目录授权不复制。真实NAS尚未验；同SSD备份不等于容灾。

**本轮修补**：资料库资产详情已有独立“查看文件位置”按钮，不必先预览失联原件。Quick与命名Canvas并存时按所属实例打开，顶栏项目文件跟随当前入口；单项核对只深读目标，成功后保存时间和快照，失败不记成功。本项目已知使用关系、Finder、已登记库离线汇总和副本时间已补。新包完整原生回归受锁屏阻塞，暂请只用新建小测试项目；不是已经真人验收或真实NAS保证。

下次解锁后的最短复验已准备在本轮证据`gui/Fixtures/`：Quick中原位引用的reference.png、独立Canvas-Closeout.dproject，以及含普通附加文件的MRT2独立测试目录。由Lead先补失联→位置→同内容定位→收纳→保存重开，再验证未保存草稿→手动备份→恢复新实例。不要移动真正模型或正式作品来制造故障。

## 使用已下载模型

原件均在`/Volumes/CodexProjects/Codex/D-Development/Models/`：

| 模型 | 目录 |
|---|---|
| ACE-Step 1.5 XL SFT 原始F32 | ACE-Step-1.5-XL-SFT |
| FLUX.2-klein-4B 原始BF16 | release-flux2-klein-4b-bf16 |
| FLUX.2-dev 原始BF16 | release-flux2-dev-bf16 |
| Qwen3.5-9B 原始权重 | release-qwen35-9b-bf16 |
| Qwen3.8-27B 原始BF16 | release-qwen38-27b-bf16 |

Dev现在可直接选择含来源sidecar的原目录，不必清理或另复制到“干净目录”。完整校验和实际推理是两个步骤；看到目录通过不代表所有能力已验证。

Quick/Canvas选真实模型，高级参数选择**省内存（SSD分层加载，精度不变）**。常驻/分阶段保留；不自动量化、裁层或删条件。短起步配置可用：ACE6秒/50步/guidance7/seed7；Klein512²/4步/guidance1/seed42；Qwen关闭思考、输出上限256的简短请求。开发机短请求使用显式15GiB预算，不是产品上限或任意长输入保证。

沿用前轮cd4cd4b的Qwen9四帧请求与Klein完整生成/有序参考实测；本轮未重复模型生成。Dev50步、H3原始完整50步及LTX2.5原始30步的未变计算沿用R4结果，单次LTX约135–147分钟；不因慢而减少精度/层数。精确profile、已验条件及未验范围见[能力矩阵](RELEASE_MODEL_MATRIX.zh-CN.md)。H3既有执行包位于`Models/D-Video-Packs/H3-FL2VA-BF16`；LTX既有包位于`run-20261001T162316Z-r4/lead/ltx-production-prepare/prepared/ltx-2.5-bf16-9CB71D89-01ED-4227-9C35-E53AA16FB8CB`（相对AgentTrials/D-RELEASE-FREEZE-01）。Wan完整原仓服务已验，内嵌转换仍保持原件并独立发布，Wan仅T2V。无需重复准备已有有效包。

先看已有完整视频：前轮`run-20261002T062206Z-discussion/quality/先看这里.md`和四个MP4。LTX合成首帧红区域持续、H3合成尾帧明显跳变，原因/通用画质未定；CPU哨兵只排除mask跨帧冻结这一假设。新包播放入口和真人音轨评估未验，避免先无目的地重生成。

## 同树 Xcode Run

打开：
`/Volumes/CodexProjects/Codex/D-Worktrees/D-RELEASE-FREEZE-01/D.xcworkspace`

选择 **D Nodes / My Mac / Debug** 后Run。不要打开内盘空仓库，也不要把保护源旧版本当本包。正常命令行构建已经通过；本轮未在Xcode界面点击Run。

该树忽略的`Development/Development.local.xcconfig`复用已有签名和`run-20261001T162316Z-r4/delivery/resources-progress`，六类固定引擎由正常构建验证、嵌入和签名，未构建后手补provider。仅本轮Swift变更无需重复准备资源；公开干净机器需按[开发说明](../Development/README.md)准备已有依赖/引擎，不能只克隆就推断音视频可运行。引擎未变不代表所有App入口已通过。

## 待集中办理与停止边界

[唯一集中清单](FAILURE_AND_PERMISSION_AUDIT.zh-CN.md)维护H22/H32及已有产物听感。H31账号/下载已关闭，不再登录或索要token；旧录音、断网、Xcode设置不重做。H22本轮取得实际client/context与符号化cursor来源，但工具未形成真实IME候选/自然firstRect，尚未修复候选不随动/指针回退。下一步需要实体键盘最短触发；不能把直接插入或旧选字正常视为位置正常。两项离屏hosting未触达目标的旧失败也保留。

公开main已获本轮正常推进授权；个人源与旧App/项目/模型保留。没有正式安装包或Release，未改许可证/收费。Pitch内部评估ONNX仍是无权重分发的已知责任；首次使用/依赖/升级恢复/渠道等发行门槛未关闭。本轮停在用户试用与冻结判断，不自动扩张下一阶段。
