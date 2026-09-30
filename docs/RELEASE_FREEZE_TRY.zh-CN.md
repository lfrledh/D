# 首发模型候选：精简试用

2026-09-30 · D-RELEASE-FREEZE-01。**这是未通过功能冻结出口的开发候选，不是发布版。** 编译/组件与部分真实推理已验，新普通App原生操作因锁屏尚未验。能力范围和未验项见[九模型矩阵](RELEASE_MODEL_MATRIX.zh-CN.md)。

## 在这台Mac打开

本轮唯一推荐启动器：
`/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-RELEASE-FREEZE-01/run-20260930T070201Z/delivery/启动首发模型候选.command`

它只打开同目录 `D Release Freeze Preview.app`，使用独立试用身份；若已有D运行会提示退出，绝不替你关闭。请新建测试项目，勿用唯一原件。启动器/签名完整性不等于GUI已经验收。

Xcode：打开 `/Volumes/CodexProjects/Codex/D-Worktrees/D-RELEASE-FREEZE-01/D.xcworkspace`，选 **D Nodes / My Mac / Debug** 后Run。该工作树忽略的 `Development/Development.local.xcconfig` 已指向本轮六引擎资源及既有开发签名身份；正常构建阶段校验并嵌入，未在成品中手补provider。不要误开内盘空仓库或源旧基线。

资源已在外盘一次性准备好，无需重新安装。需要从既有引擎重建资源集时，使用 `scripts/prepare-development-resources.py`，配置为上述delivery中的`prepared-inputs-final.json`，输出必须是新的不存在目录；然后仅在本机ignored xcconfig中更新资源路径。本流程不下载模型；迁移机器仍须配置实际签名和路径，不能声称当前绝对路径可携带到任意Mac。

## 试用顺序

1. 进入测试项目，在共享资料库查看真实模型名及具体profile。通过既有模型管理选择对应本地固定版本；没有权重应显示未就绪/明确错误，不能显示模拟成功。Qwen9B Q4已在外盘Models，其他大模型未验状态见矩阵。
2. 快速生成选择当前模型，检查输入和参数；工作流添加同名操作，检查两者端口/限制一致。图片、视频帧、首尾帧或音乐原声通过实际资产输入，不在提示词中冒充条件。
3. 优先试Qwen3.5-9B Q4文字与图片问答；H3选择 **FL2VA BF16** 并打开流式扩散权重，先用短视频/低步数，检查首尾帧是否进入记录。低步数样本只证明链路，不代表质量上限。
4. 查看运行记录的实际revision、profile、条件和参数；保存、重开测试项目，再导出到新目录。未接受候选不得覆盖原资产。
5. 检查画布滚轮缩放、空白拖动、中键居中及右下默认视图；控件/端口仍拥有各自手势。这些新普通包鼠标项尚待H32验收。

LTX2.5/Dev资源401，暂不能真实试；Qwen27B/BF16、Klein BF16和ACE XL F32未完成实测。ACE不会偷偷换成turbo或量化；本机预算拒绝不代表所有Mac都不能跑。旧Klein Q8严格PNG基准差异保留，不能当作数值已完全回归。MRT2展示现有small/export-v1能力，音符控制是近似的，不宣称严格服从乐谱。

## 剩余门槛

解锁后的同包Quick/Canvas与强条件真实smoke；H31两份固定资源访问；较大配置的真实运行；旧Klein基准差异归因与处理。旧H22输入法位置和前端候选未验矩阵继续保留。无需重复已办的麦克风/断网许可。本轮不推进main、不公开发布，不把新模型列表出现等同于整个模型已支持。
