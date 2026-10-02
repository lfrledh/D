# D · Mac 本地 AI 工作台

[English](README.md) · **开发预览**

D 是 Apple Silicon Mac 上的原生多模态 AI 工作台。**快速生成**用于调用单个模型，**工作流画布**用于组合可编辑操作；两者共用模型能力、运行时调度和项目资产。用户可以检查输入，区分候选与已采用作品，并决定何时运行后续步骤。

节点工作台已经实现。本仓库是持续开发的基线，**不是正式发行版**。真实模型运行、原生交互验收、功能冻结和发行就绪分别记录。目前没有公开安装包。

## 已实现的范围

| 领域 | 当前范围 |
| --- | --- |
| 快速生成与工作流 | 模型选择、有类型操作、可编辑连接和参数、可选人工决定、候选、项目保存重开与导出；部分原生交互仍待验收。 |
| 文字／视觉 | Qwen3.5-9B、Qwen3.8-27B：文字、有序图像、视频采样帧和结构化工具消息；D不自动执行模型返回的工具调用。 |
| 图像 | FLUX.2-klein-4B、FLUX.2-dev：文生图与有序参考图。原始精度和单独标识的量化profile不能混为同一验证结果。 |
| 视频 | Wan2.1-T2V-1.3B：文字生成无声视频；LTX-2.5 dev单阶段：文字／首帧生成音视频；MiniMax H3 Base FL2VA：文字／首尾帧生成音视频。不代表每个模型家族的全部模式。 |
| 音乐 | MRT2 small/export-v1实际读取音符／和弦条件；ACE-Step 1.5 XL SFT F32/no-LM支持生成、歌词／参考、cover和repaint。音乐控制是近似的，不保证精确服从乐谱。 |
| 资源 | 显式下载／导入、准备校验、共享安装使用权、取消与资产来源记录。位置管理、复制入库和手动备份恢复属于当前实施切片，不能视为已经全部完成。 |

[模型能力矩阵](docs/RELEASE_MODEL_MATRIX.zh-CN.md)列出精确profile、revision及实测模式。Dev、H3和LTX已经通过SSD分层加载完成原始精度的完整代表请求及取消、真实产物存储检查；这不证明所有参数组合、大内存整模型常驻模式或当前App交互均通过。

## 环境与开发构建

- Apple Silicon Mac；App部署目标为 **macOS 26.2**。当前本机使用macOS 26.6.2和Xcode 27.0验证；其他配置需分别核验。
- 为固定依赖、引擎资源和用户选择的模型保留足够磁盘空间。16 GiB开发机**不是产品能力上限**；原始精度SSD加载可能运行数小时，只改变驻留方式，不减少层数或降低精度。
- Xcode与锁定的Swift包依赖；首次解析依赖可能联网。
- 预先准备的本地引擎包和自己的开发签名身份。仅干净克隆仓库**还不是完整可运行环境**。

```sh
git clone https://github.com/lfrledh/D.git
cd D
```

使用现有工具准备已核验引擎资源集。输出的父目录须存在，输出目录使用新位置：

```sh
python3 scripts/prepare-development-resources.py \
  --config /absolute/path/prepared-inputs.json \
  --output /absolute/path/prepared-resources
```

JSON使用`schemaVersion: 1`和`engines`映射，将引擎名称指向已经存在的绝对路径。四个基础引擎为`AudioEngine.dengine`、`MRT2MusicEngine.dengine`、`VideoEngine.dengine`和`PitchEngine.dengine`；当前H3/LTX和ACE能力还需要`ExternalVideoEngine.dengine`和`ACEMusicEngine.dengine`。该工具核验并封装**已准备的引擎**，不负责安装依赖或模型。各准备入口和固定源码责任见[开发资源说明](Development/README.md)与[后端／源码导航](docs/REPOSITORY_MAP.zh-CN.md)。

建立已被Git忽略的`Development/Development.local.xcconfig`：

```xcconfig
D_DEVELOPMENT_RESOURCES = /absolute/path/prepared-resources
D_DEVELOPMENT_SIGNING_IDENTITY = Apple Development: YOUR EXISTING IDENTITY
D_DEVELOPMENT_TEAM = YOUR TEAM ID
```

打开 **D.xcworkspace**，选择 **D / My Mac / Debug** 后Run。**D Nodes**使用同一目标和独立、持久的试用身份。正常构建会嵌入已核验引擎并签名，不应在App构建后手补provider。

命令行构建使用独立输出目录：

```sh
D_DEVELOPMENT_ROOT=/absolute/path/build-output ./scripts/build-local.sh
```

只有依赖已缓存时才追加`--offline`；它不代表系统强制断网。引擎／模型获取与Swift编译是不同步骤，旧`build-development-app.py`也不能自动准备完整六引擎集合。

## 已知限制与接下来的工作

- 输入法候选窗位置和鼠标指针回退仍在定向定位。历史真人检查中选字正常，不表示定位问题已关闭。
- 当前App原生验收未完成；两项离屏hosting测试未触达目标控件，失败记录保留。
- LTX合成首帧样本的平面红色区域持续存在，原因和通用控制质量未确定；H3短样本不证明长视频质量。
- 导入、已知位置恢复、项目收纳和手动备份按有限切片推进；没有云同步或多台Mac并发写同一库。
- 干净机器首次使用、依赖封装、升级恢复及发行验证仍有缺口。最终分发App的目标是不附模型权重；当前内部Pitch开发引擎仍含评估ONNX权重，**不是发行包**。

模型由用户显式获取，其条款与来源和D源码分别记录。本轮收尾不增加模型家族、训练系统、远程服务或移动端。

## 开发、反馈与许可

从[当前状态](docs/CURRENT_ACTIONS.zh-CN.md)、[仓库导航](docs/REPOSITORY_MAP.zh-CN.md)和唯一[风险分级测试政策](docs/TESTING_POLICY.zh-CN.md)进入。工程记录目前主要使用中文。纯契约／运行时检查用`scripts/test-foundation.sh`，工作台CPU检查用`scripts/test-workbench.sh`；按影响选择测试，不为每次修改重生成所有模型产物。真实模型检查需要指定本地资源和独占计算时段。

可在[GitHub Issues](https://github.com/lfrledh/D/issues)报告可复现问题，提供提交、macOS／芯片／内存、模型profile和简短步骤。分享日志前移除私人提示词、项目文件和凭据。

**仓库目前未授予覆盖整个D项目的开源许可证。** 源码公开不等于采用MIT／Apache或允许无限制复用。第三方代码保留各自条款，参见[Vendor来源索引](Vendor/README.md)以及对应后端／依赖目录的LICENSE／NOTICE。本次更新不改变许可，也不宣布商业发行。
