# D — Local AI Workbench for Mac · Mac 本地 AI 工作台

<sub>中文读者：本页下方提供完整中文说明，可<a href="#d-chinese">直接跳转</a>。当前为开发预览，尚无公开安装包。</sub>

[English](#d-english) · [简体中文 ↓](#d-chinese)

<a name="d-english"></a>
## English

D is a native multimodal AI workbench for Apple Silicon Macs. Use **Quick** for a single model, or assemble editable operations on the **workflow canvas**. Both surfaces share model capabilities, runtime scheduling and project assets. Inspect inputs, keep candidates separate from accepted work, and decide what runs next. Build visual drafts, rewrite text, prepare references, and combine local image, music and video operations without surrendering control of your source material.

The node workbench is implemented. This repository is an active development baseline, **not a production release**. Successful model runs, native interaction checks, feature freeze and distribution readiness are tracked separately. There is no public installer yet.

### What is implemented

| Area | Current scope |
| --- | --- |
| Quick and workflows | Model selection, typed operations, editable connections and parameters, optional human decisions, candidates, project save/reopen and export. Some native interactions still need acceptance. |
| Text / vision | Qwen3.5-9B and Qwen3.8-27B: text, ordered images, sampled video frames and structured tool messages. D does not automatically execute returned tool calls. |
| Images | FLUX.2-klein-4B and FLUX.2-dev: text-to-image generation and ordered reference images. Original precision and separately identified quantized profiles are not interchangeable. |
| Video | Wan2.1-T2V-1.3B (text to silent video); LTX-2.5 dev single-stage (text / first frame to audiovisual video); MiniMax H3 Base FL2VA (text / first and last frame to audiovisual video). This is not every mode of each model family. |
| Music | MRT2 small/export-v1 with actual note/chord conditions; ACE-Step 1.5 XL SFT F32/no-LM generation, lyrics/reference, cover and repaint. Music control is approximate, not guaranteed score fidelity. |
| Resources | Explicit model download/import, preparation and validation, shared installation leases, cancellation and asset provenance. Explicit external references or independent copies, known-location inspection/recovery, project media collection and manual backup/independent restore are implemented. The location inspector can be opened directly without loading a missing original. Verification records are scoped to the selected asset; native registration, external-reference recovery, collection and cold reopening have been exercised on small fixtures. A later ordinary sandboxed App passed representative manual backup, independent restore and cold reopening for Quick/Canvas, then chat and attachments. See the [versioned evidence](docs/tasks/D-RELEASE-FREEZE-01.md); this is not clean-machine or NAS acceptance. |

The [model capability matrix](docs/RELEASE_MODEL_MATRIX.zh-CN.md) records exact profiles, revisions and tested modes. Full representative original-precision requests have run using SSD layering for Dev, H3 and LTX, with cancellation and real artifact storage checks. This does not establish every parameter combination, large-memory resident mode or current App interaction.

### Native preview

![Native Quick preview](docs/images/native-quick-20261003.png)

Actual native App, code `35f373a`, captured on 2026-10-03 with a synthetic prompt and isolated preferences. This cold-start screenshot honestly shows preparation status awaiting verification; it is not a generated mockup or evidence of a new model run.

### Requirements and development build

- Apple Silicon Mac; the App deployment target is **macOS 26.2**. Current local validation uses Xcode 27.0 on macOS 26.6.2. Other configurations need their own verification.
- Sufficient disk space for fixed dependencies, engine resources and user-selected models. A 16 GiB development machine is **not** a product capability ceiling. Original-precision SSD loading can take hours; it changes residency, not model precision or layer count.
- Xcode and the pinned Swift package dependencies; the first dependency resolution can require network access.
- Prepared local engine bundles and your own development signing identity. A clean clone alone is **not** a complete runnable App environment.

```sh
git clone https://github.com/lfrledh/D.git
cd D
```

Prepare the verified engine resource set with the existing tool. The output parent directory must exist; use a new output directory:

```sh
python3 scripts/prepare-development-resources.py \
  --config /absolute/path/prepared-inputs.json \
  --output /absolute/path/prepared-resources
```

The JSON has `schemaVersion: 1` and an `engines` map from bundle name to an existing absolute path. The four baseline bundles are `AudioEngine.dengine`, `MRT2MusicEngine.dengine`, `VideoEngine.dengine` and `PitchEngine.dengine`; the current H3/LTX and ACE capabilities additionally require `ExternalVideoEngine.dengine` and `ACEMusicEngine.dengine`. This tool verifies and packages **already prepared** engines; it is not a dependency or model installer. See [development resources](Development/README.md) and [backend/source navigation](docs/REPOSITORY_MAP.zh-CN.md) for preparation entry points and fixed-source responsibilities.

Create the ignored `Development/Development.local.xcconfig`:

```xcconfig
D_DEVELOPMENT_RESOURCES = /absolute/path/prepared-resources
D_DEVELOPMENT_SIGNING_IDENTITY = Apple Development: YOUR EXISTING IDENTITY
D_DEVELOPMENT_TEAM = YOUR TEAM ID
```

Open **D.xcworkspace**, choose **D / My Mac / Debug**, and Run. **D Nodes** uses the same target with an isolated, persistent trial identity. The ordinary build embeds verified engines and signs the App; do not patch providers into an already built App.

For a command-line build with separate outputs:

```sh
D_DEVELOPMENT_ROOT=/absolute/path/build-output ./scripts/build-local.sh
```

Add `--offline` only when the required dependencies are already cached. It does not impose system-wide network isolation. Engine/model acquisition is separate from Swift compilation; no claim is made that the older `build-development-app.py` prepares the complete six-engine set automatically.

### Known limitations and next work

- The current Quick input fix has passed the owner's native retest: composition works and the cursor no longer reverts. Candidate-window non-following was compared with Finder and accepted as the current system behavior; this is not a guarantee for every macOS/input method.
- The fixed chat reading, input and left/right file-drop closeout passed on code `8cf1b7dd`; F26 real search remains explicitly deferred. The new native-UI candidate has separate, incomplete window acceptance. [Current status](docs/CURRENT_ACTIONS.zh-CN.md) distinguishes these versions; earlier failed tests remain in the record.
- Earlier near-silent LTX and synthetic red-region samples remain recorded. On 2026-10-03 the owner accepted the later fixed natural LTX and H3 examples, including audio and transitions. This is representative evidence, not all conditions or long-video quality.
- Native checks passed for MRT2 registration by reference and independent copy, Quick missing-file recovery while a separate Canvas project exists, copying into the project and cold reopening. Idle model-library snapshots no longer continually reset native menus; the owner confirmed the repaired menu.
- The earlier sandbox backup failure was repaired and representative native backup → independent restore → cold reopening passed. Cold-start MRT2 readiness was checked without first opening the full model-library sheet. Real NAS, clean-machine setup and the remaining window/port combinations are not covered by these results.
- Clean-machine setup, dependency packaging, upgrades/recovery and distribution checks remain. The intended distributed App does not bundle model weights; the current internal Pitch development engine still includes an evaluation ONNX weight and is **not** a distribution package.

Models are acquired explicitly by the user; their terms and sources are separate from D's code. No new model family, training system, remote service or mobile client is part of the current closeout.

### Development, feedback and licensing

Start with [current status](docs/CURRENT_ACTIONS.zh-CN.md), [repository map](docs/REPOSITORY_MAP.zh-CN.md) and the single [risk-based testing policy](docs/TESTING_POLICY.zh-CN.md). Most engineering records are currently in Chinese. Pure contract/runtime tests use `scripts/test-foundation.sh`; workbench CPU checks use `scripts/test-workbench.sh`. Select the affected tests rather than regenerating every model output. Model tests need the specified local resources and a free compute slot.

Report reproducible problems through [GitHub Issues](https://github.com/lfrledh/D/issues), including the commit, macOS/chip/memory, model profile and concise steps. Remove private prompts, project files and credentials before sharing logs.

**No repository-wide open-source license has been granted in this repository.** Public source visibility is not a grant of MIT/Apache or unrestricted reuse. Third-party source retains its own notices; see [Vendor provenance](Vendor/README.md) and the LICENSE/NOTICE files in the respective backend/dependency directories. This update does not change licensing or announce a commercial release.

---

<a name="d-chinese"></a>
## 简体中文

D 是 Apple Silicon Mac 上的原生多模态 AI 工作台。**快速生成**用于调用单个模型，**工作流画布**用于组合可编辑操作；两者共用模型能力、运行时调度和项目资产。用户可以检查输入，区分候选与已采用作品，并决定何时运行后续步骤。它适合制作视觉草稿、改写文字、准备参考资料，以及组合本地图像、音乐和视频操作，同时保留对原始素材的控制。

节点工作台已经实现。本仓库是持续开发的基线，**不是正式发行版**。真实模型运行、原生交互验收、功能冻结和发行就绪分别记录。目前没有公开安装包。

### 已实现的范围

| 领域 | 当前范围 |
| --- | --- |
| 快速生成与工作流 | 模型选择、有类型操作、可编辑连接和参数、可选人工决定、候选、项目保存重开与导出；部分原生交互仍待验收。 |
| 文字／视觉 | Qwen3.5-9B、Qwen3.8-27B：文字、有序图像、视频采样帧和结构化工具消息；D不自动执行模型返回的工具调用。 |
| 图像 | FLUX.2-klein-4B、FLUX.2-dev：文生图与有序参考图。原始精度和单独标识的量化profile不能混为同一验证结果。 |
| 视频 | Wan2.1-T2V-1.3B：文字生成无声视频；LTX-2.5 dev单阶段：文字／首帧生成音视频；MiniMax H3 Base FL2VA：文字／首尾帧生成音视频。不代表每个模型家族的全部模式。 |
| 音乐 | MRT2 small/export-v1实际读取音符／和弦条件；ACE-Step 1.5 XL SFT F32/no-LM支持生成、歌词／参考、cover和repaint。音乐控制是近似的，不保证精确服从乐谱。 |
| 资源 | 显式下载／导入、准备校验、共享安装使用权、取消与资产来源记录。已实现显式原位引用／独立副本、已知位置查看与恢复、项目媒体收纳、手动备份和独立恢复。位置页可以直接打开，不依赖失联原件预览；核对记录限定在所选素材。小夹具已完成原生登记、外部引用恢复、收纳及冷重开；后续普通沙盒App已通过Quick/Canvas及聊天附件的代表性手动备份、独立恢复和冷重开；见[分版本证据](docs/tasks/D-RELEASE-FREEZE-01.md)，不外推干净机器或NAS。 |

[模型能力矩阵](docs/RELEASE_MODEL_MATRIX.zh-CN.md)列出精确profile、revision及实测模式。Dev、H3和LTX已经通过SSD分层加载完成原始精度的完整代表请求及取消、真实产物存储检查；这不证明所有参数组合、大内存整模型常驻模式或当前App交互均通过。

### 原生界面预览

![原生快速生成预览](docs/images/native-quick-20261003.png)

2026-10-03实际原生App截图，代码`35f373a`，仅合成提示词与隔离偏好。冷启动截图中的“准备状态待核验”保留真实状态；不是设计稿，也不代表新一轮模型生成通过。

### 环境与开发构建

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

### 已知限制与接下来的工作

- 当前Quick输入修补已通过本人原生复验：组字可用、鼠标不再闪回。候选窗不随动与本人对照的Finder表现一致，已接受为当前系统行为，不推广为所有macOS／输入法的保证。
- 固定聊天阅读、输入与左右文件落点在`8cf1b7dd`完成本轮收口；F26真实搜索明确延期。新原生UI候选的窗口验收单列未完成，见[当前状态](docs/CURRENT_ACTIONS.zh-CN.md)。旧失败记录保留，不用新截图追认。
- 旧LTX近静音及合成红块样本保留。2026-10-03本人确认后续固定自然LTX与H3样例声音、转场正常；这是代表证据，不等于所有条件或长视频质量保证。
- 原生已验MRT2原位登记／独立复制，独立Canvas存在时Quick失联素材的直接定位、收纳及冷重开。模型库空闲快照不再持续重置原生菜单，本人已确认菜单修补有效。
- 早期沙盒备份失败已修，代表性的原生备份→独立恢复→冷重开通过；冷启MRT2也已在不先打开完整模型库的情况下核对就绪。真实NAS、干净机器及剩余窗口/端口组合未由此通过。
- 干净机器首次使用、依赖封装、升级恢复及发行验证仍有缺口。最终分发App的目标是不附模型权重；当前内部Pitch开发引擎仍含评估ONNX权重，**不是发行包**。

模型由用户显式获取，其条款与来源和D源码分别记录。本轮收尾不增加模型家族、训练系统、远程服务或移动端。

### 开发、反馈与许可

从[当前状态](docs/CURRENT_ACTIONS.zh-CN.md)、[仓库导航](docs/REPOSITORY_MAP.zh-CN.md)和唯一[风险分级测试政策](docs/TESTING_POLICY.zh-CN.md)进入。工程记录目前主要使用中文。纯契约／运行时检查用`scripts/test-foundation.sh`，工作台CPU检查用`scripts/test-workbench.sh`；按影响选择测试，不为每次修改重生成所有模型产物。真实模型检查需要指定本地资源和独占计算时段。

可在[GitHub Issues](https://github.com/lfrledh/D/issues)报告可复现问题，提供提交、macOS／芯片／内存、模型profile和简短步骤。分享日志前移除私人提示词、项目文件和凭据。

**仓库目前未授予覆盖整个D项目的开源许可证。** 源码公开不等于采用MIT／Apache或允许无限制复用。第三方代码保留各自条款，参见[Vendor来源索引](Vendor/README.md)以及对应后端／依赖目录的LICENSE／NOTICE。本次更新不改变许可，也不宣布商业发行。

[↑ English](#d-english) · [简体中文](#d-chinese)
