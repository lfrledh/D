# 首发收口候选：精简试用

2026-10-01 · D-RELEASE-FREEZE-01 r2。**可试用的开发候选；功能冻结尚未通过。** 正常App构建及CPU受测代码 `b315ffa0c2d8d191204b0b93f1afdaaaae46e865`；实际原生操作在其父版本 `41ad63026da948eef6e3b5f5837f63744f1a2c98`，最后变化仅视频模型展示名与对应回归。最终包已由推荐启动器启动，但锁屏阻塞了修补后的界面复验，不能把父版本操作冒充最终包全验。后续结案仅文档，最终提交在任务/外部回执中；不要用旧启动器判断本版状态。

## 唯一推荐入口

双击：
`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20260930T142825Z-closeout/delivery/启动首发收口候选.command`

同目录 **D Release Freeze Closeout.app** 是正常构建的本版。启动器使用独立试用身份，不关闭其他D、不替换普通App。避免同时在其他D运行模型；再次使用本入口会恢复这份试用记录。旧 `run-20260930T070201Z` 与 `intermediate-9cdf` 仅保留历史，不推荐试用。

## 已经可以直接试

1. 打开后快速页已有 **Qwen3.5-9B · 4-bit**，模型已通过真实界面导入与完整校验。已保存任务要求输出 `title: D freeze tryout` 和 `answer: 42`。直接点击生成，结果应是可展开记录与原始JSON。
2. 高级设置中当前思考为off、seed42、输入2048/输出256、显式内存预算15GiB。原默认12GiB曾被本配置估算正确拒绝；15仅为这次M4/16GiB短请求的显式选择，不是全模型默认/内存保证。不要直接把长视频/大上下文套用此预算。
3. 点击 **工作流**，已有从同一Quick设置生成的Qwen节点。选节点后“运行到这里”→确认计划可真实执行；输出结构、模型与预算保留。Quick继续编辑不会自动运行画布。
4. 节点结果与原文可查，保存后退出再用同一启动器打开；41ad630已实测两入口结果、草稿、节点参数和运行记录冷恢复。画布滚轮改变缩放，中键调整中心，右下恢复100%；平移/拖放全矩阵与IME跟随尚未完整关闭。
5. 模型下载与安装位于右上 **更多 → 模型下载与安装**。九家族12个精度条目已显示，支持固定原件下载/导入、校验与重新定位。未准备不显示假成功。H3/LTX2.5原始资源有独立准备入口；Wan原始权重自动转换仍缺接线，已有准备包可继续显式登记。

试用项目属于隔离会话的 `Quick Creations.dproject`；交付 `samples/` 保留本次项目快照，模型权重不复制进项目或App。日常作品请保留原件，不用唯一作品替代测试项目。

## 同一代码在Xcode运行

打开 `/Volumes/CodexProjects/Codex/D-Worktrees/D-RELEASE-FREEZE-01/D.xcworkspace`，选择 **D Nodes / My Mac / Debug** 后Run。不是内盘空仓库，也不是受保护源旧版本。正常构建阶段已校验并嵌入六种执行引擎，无构建后手补provider。

本工作树忽略的 `Development/Development.local.xcconfig` 已指向本轮外盘resources及现有开发签名。资源无需重新安装；如需重建，用 `scripts/prepare-development-resources.py` 读取本轮delivery中的 `prepared-inputs.json`，输出新目录。模型仍由正常UI下载或登记，不打包进App。

共享D Nodes scheme默认使用另一独立开发身份 `4DFA8D40-45FA-4BA0-934C-F034F36E2D60`，所以首次Run不一定看到本次试用记录。若要复用上述已备好的记录，在**本地**Edit Scheme→Run→Environment Variables把现有 `D_UI_TEST_SESSION` 值设为 `4555a0d5-e285-48f5-b34f-dff8238a893c`；无需改Team/bundle ID/权限。不要把你的个人scheme修改提交到Git。正常构建已通过；这轮没有另做Xcode界面点击Run验收。

## 本版尚不能承诺

- Dev和LTX2.5固定资源访问受平台阻塞；需本人登录取得访问或提供对应本地目录，密码/token不要发到聊天。
- 27B、9B BF16、Klein BF16未完成真实验收；不能用Q4/Q8结果代替。大内存Mac依既有参数运行，不受16GiB硬编码上限限制。
- ACE XL原始F32已产出6秒/1步真实WAV；50步在本机换页明显，受控停止。尚未合理采样、歌词/参考/cover/repaint全部实测和同包GUI试听，不能称音乐路线已通过冻结。
- H3真实首尾帧生成复用本轮前段Runtime证据，不等于最终包新视频Quick/Canvas全验；MRT2/Wan旧结果也不升级为本包全验。
- 两项hosting检查仍失败，原因和原生结果分开记录；跨项目空图保护已补CPU回归，完整原生拖放尚未验。H22中文/日文候选位置仍需集中本人检查。

详细边界见[能力矩阵](RELEASE_MODEL_MATRIX.zh-CN.md)、[本轮结果](tasks/D-RELEASE-FREEZE-01.md)、[集中待办](FAILURE_AND_PERMISSION_AUDIT.zh-CN.md)。本轮不合并受保护源/main、不公开发布。
