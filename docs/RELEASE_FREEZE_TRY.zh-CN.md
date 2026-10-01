# 首发收口候选：精简试用

2026-10-01 · D-RELEASE-FREEZE-01 r3。**原始精度低内存开发候选，尚未功能冻结。** 代码、真实模型、普通App与真人验证分开记录；最新构建与验收结果见[本轮任务](tasks/D-RELEASE-FREEZE-01.md)及外部最终回执，不能用旧包结果代替本包。

## 唯一推荐入口

本轮交付目录：
`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20261001T040512Z-low-memory/delivery`

其中双击 **启动首发收口候选.command**，启动同目录 **D Release Freeze Closeout.app**。启动器使用既有独立试用身份，不关闭其他D、不替换普通App或作品。旧r1/r2启动器保留历史，不再作为本轮推荐入口。若当前仍锁屏，请解锁后使用；本轮未把构建、签名或启动器检查写成已完成原生操作。

## 先试已有记录，再选择原始权重

1. 同一试用身份保留r2的Qwen3.5-9B Q4文字项目与Quick/Canvas记录。继续使用常驻模式仍可；它不是本轮原始精度证据。
2. 右上 **更多 → 模型下载与安装**，选择对应的固定精度条目，导入本机外盘已经校验的目录。等待正常完整性校验，不用重新下载：

   | 模型 | 已有目录（均在 `/Volumes/CodexProjects/Codex/D-Development/Models/` 下） |
   | --- | --- |
   | ACE-Step 1.5 XL SFT 原始F32 | `ACE-Step-1.5-XL-SFT` |
   | FLUX.2-klein-4B 原始BF16 | `release-flux2-klein-4b-bf16` |
   | Qwen3.5-9B 原始权重 | `release-qwen35-9b-bf16` |
   | Qwen3.8-27B 原始BF16 | `release-qwen38-27b-bf16` |

3. Quick或Canvas选中实际模型后，在高级参数的加载方式选择 **省内存（SSD 分层加载，精度不变）**。常驻和分阶段模式保留给合适配置；SSD不会自动量化、裁层或删参考。Q4/Q8暂不支持这条SSD路径，错误会明确报告，请不要用量化条目代替原始条目。
4. 可先用已验证的小请求：ACE六秒、50步、guidance7；Klein512×512、4步、guidance1；Qwen3.5-9B或Qwen3.8-27B要求一个简短JSON、关闭思考、输出上限256。seed可用42（ACE样本用7）。本机短请求验证使用显式15GiB预算；这不是产品上限、默认建议或任意长输入的内存保证。
5. ACE支持歌词、独立参考音频，以及cover原声/repaint区间；该profile的输入为48kHz双声道PCM WAV，非法格式不会静默转换。Klein支持有序参考图；文字节点保留消息、媒体、工具结果和结构化响应。运行前参数形成快照，继续编辑不会改掉在途输入。
6. 文字逐段显示与SSD加载是两个不同能力；文字结果仍保留raw/final等结构。已有结果可以在资料库查来源，再安全导出和保存。长任务可取消，界面结束必须等计算与释放完成。

正常界面的原始模型导入、上述新选择器、取消和保存/重开仍需H32在本包集中操作。CLI/正式Runtime通过不代替GUI；未知或未验路线不会因出现在菜单中变成已冻结。

## Wan原件准备

本版普通构建包含固定转换依赖。模型库下载/导入原件后，使用 **准备独立执行包**；准备保持原件，逐张量写独立暂存目录，完整校验后原子发布并登记。中断不会伪造ready；恢复按明确状态处理，不清未知文件。

R3正式内嵌转换桥已将固定Wan原件转为1,261个分片，并由生产模型库校验器检查完整1,262文件集合。此处尚未把普通App沙盒点击、最终发布或本包视频生成记为已验。已有准备包仍可沿原入口使用；Wan2.1仍为T2V，不显示成I2V。

## 同一代码在Xcode运行

打开 `/Volumes/CodexProjects/Codex/D-Worktrees/D-RELEASE-FREEZE-01/D.xcworkspace`，选择 **D Nodes / My Mac / Debug** 后Run。不是内盘空仓库或受保护源旧版本。

本工作树忽略的 `Development/Development.local.xcconfig` 指向本轮 `delivery/resources` 和既有开发签名。正常构建阶段校验、嵌入六类引擎，不需构建后手补脚本。若只重编译源码，不必重做资源准备；资源重建复用 `scripts/prepare-development-resources.py`，读取同目录 `prepared-inputs.json`，输出新的目录后更新本地配置。

共享scheme默认独立身份 `4DFA8D40-45FA-4BA0-934C-F034F36E2D60`；如需看到推荐启动器的旧试用记录，在**本地**Edit Scheme→Run→Environment Variables，将 `D_UI_TEST_SESSION` 设为 `4555a0d5-e285-48f5-b34f-dff8238a893c`。不改Team/bundle ID/权限，不提交个人scheme。命令行普通构建和Xcode界面点击Run是两种证据，后者本轮未重做。

## 仅需本人集中处理的入口

- **H31**：本机双击交付目录中的 `H31-本机下载登录.command`。在实际固定资源仓完成HF账号访问，并在官方CLI本地输入只读凭据；不要发聊天。实际仓库为 `black-forest-labs/FLUX.2-dev` 和 `dgrauet/ltx-2.5-mlx`，拥有其他仓库权限不代表这两份固定文件可读。
- **H32/H22**：返回解锁后统一完成本包原生操作、中文/日文候选位置及必要音频试听。无需重做已关闭的录音和断网验收。

唯一清单为[集中待办](FAILURE_AND_PERMISSION_AUDIT.zh-CN.md)，不在此维护第二份状态。没有登录/解锁状态变化不重复请求。

## 尚未完成的冻结责任

Dev与LTX2.5访问及真实模型、其他尚未覆盖的原生能力、同包九模型Quick/Canvas操作、两项hosting动作和完整拖放、输入法/听感仍按[能力矩阵](RELEASE_MODEL_MATRIX.zh-CN.md)保留。模型文件下载和逐块对照不能代替完整生成；本轮已完成的完整生成见任务证据，不把不同版本通过率相加。

新增模型原件不进入App或Git。既有Pitch评估引擎中的ONNX仍是最终无权重发行策略的已知缺口，依赖封装/首次使用/升级恢复/渠道责任未解除。本轮不合入保护源/main，不公开发布。
