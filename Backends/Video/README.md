# Wan V0 本地视频后端

D-VIDEO-V0-01 的命令行后端已通过 D-VIDEO-WORKBENCH-01 接入基础视频工作台。阶段验收、代码版本与实际结果见 `docs/tasks/D-VIDEO-WORKBENCH-01.md`；最初数值/命令行验收仍保留于 V0 记录。

## 在工作台使用

1. 使用带 `VideoEngine.dengine` 的构建；普通未封装构建不自动下载引擎。打开或新建项目，选择顶部“视频”，再点“新建视频创作”。
2. 选择**已准备**的 Wan2.1 模型目录（含准备清单与转换权重），不是原始 checkpoint 根目录。登记、恢复和执行分别校验，不会把模型复制进项目。
3. 填写描述、可选负面描述和实际生成参数。默认832×480/17帧/50步是样本配置，非所有机器的推荐值。内存预算留空使用主机默认；显式MiB值写入任务和运行记录，可能使用swap，不是物理内存硬上限。模型/几何限制与内存建议分开。
4. 生成后得到未自动采用的候选。预览不自动播放；选择、采用、拒绝/恢复是分别的操作。取消等待计算和进程清理；隐藏参数、切换模态不会取消已提交任务。
5. 保存并重开可恢复草稿、模型登记与候选决定。修改草稿不会改写旧任务配方。导出创建新的无声MP4，已有文件拒绝覆盖；完整提示词/seed/模型配方仍在项目记录中，当前**没有**将完整配方内嵌到独立MP4。

本批M4/16GiB普通沙盒流程样本：320×192、17帧/16fps、50步、seed42、14GiB显式指导值；后端253.192秒，MLX峰值11.077GiB，进程峰值RSS约4.755GiB，两者不能相加；最终active18bytes/cache0且子进程退出。小画面可见红色车辆，也有明显模糊、形变/色彩瑕疵，不宣称达到成片质量。历史832样本、长序列及其他机器是不同证据范围。

## 边界

输入是不可变的正/负文本条件、已安装的固定模型及显式几何/帧率/步数/引导/seed；输出是无声 H.264 MP4 文件引用、实际执行配方和独立媒体检查记录。推理不下载资源，不调用云端，不制作音轨，不把视频资源复制进控制事件。

- 模型：Wan2.1 T2V-1.3B，revision `37ec512624d61f7aa208f7ea8140a131f93afc9a`；本适配器暂不支持其他 checkpoint 或 I2V。
- 精度：T5 BF16；DiT 主体 BF16并保留原 FP32 time/head/modulation/norm；VAE FP32。原始权重保留，不能静默改成量化模型。
- 模型形状要求：宽高为16倍数，帧数4n+1；本适配器各latent轴不超过1024，1...1000步、UInt32 seed，正的引导及shift。模型条件格式512token，超长明确拒绝，不截断。
- 请求的帧率是有理数 p/q；N帧容器时长=Nq/p。采样器固定 UniPC order2/bh2；几何、参数和精度不随开发机偷偷改变。
- M4/16GiB不是能力上限。调用方明确给内存预算；运行时报告预算拒绝或实际加载/计算失败。更大模型需要独立适配/授权，不能仅改文件夹名。
- MLX的`memoryLimitBytes`是计算调度指导值，可能超过并使用可用swap，不是RSS或物理内存硬上限。准入估计与真实峰值分别记录；不能把预算检查通过当成不会OOM。
- 软件编码/独立完整解码后才发布；不覆盖旧文件。RGB8明确解释为full-range Rec.709，压缩不是无损。目录身份路径在不支持的文件系统上明确失败，无危险普通路径回退。

## 目录与准备

`Python/d_video_prepare.py` 将已校验原始checkpoint逐张量转换到**全新**目录；`d_video_run.py`只读取已准备目录。`Vendor/wan21/PROVENANCE.json`记录固定源码、最小数值补丁及许可证；没有修改可变依赖检出。`requirements-tested.txt`是已授权隔离Python3.12环境的版本记录，不能据此擅自联网安装。

原件需包含DiT safetensors、T5 BF16 pth、Wan VAE pth及本地 `google/umt5-xxl` 分词器。准备入口：

```sh
"$VIDEO_PYTHON" -B Backends/Video/Python/d_video_prepare.py \
  --source "$WAN_ORIGINAL" --destination "$WAN_PREPARED_NEW"
```

参数必须是明确的绝对路径，输出位置与模型/代码分开。Python环境、模型、准备目录均放外盘。不要从临时工作树删除唯一模型或证据。

## 统一运行时入口

使用独立构建出的 `d-infer`，不替换普通D.app。以下环境变量由操作者设为已有、获准的位置；本命令不负责安装：

```sh
"$D_INFER" --capability video --model "$WAN_PREPARED" \
  --revision 37ec512624d61f7aa208f7ea8140a131f93afc9a \
  --video-python "$VIDEO_PYTHON" --video-script "$D_PROJECT/Backends/Video/Python/d_video_run.py" \
  --video-tokenizer "$WAN_ORIGINAL/google/umt5-xxl" \
  --prompt 'A small red toy car slowly rolling across a wooden desk, fixed camera, natural daylight, simple background.' \
  --negative-prompt 'blurry, overexposed, distorted, low quality, watermark' \
  --width 832 --height 480 --frames 17 --fps-numerator 16 --fps-denominator 1 \
  --steps 50 --guidance 6 --shift 8 --seed 42 --memory-budget-mib 20480 \
  --artifacts "$NEW_RUN/artifacts" --report "$NEW_RUN/cli-report.json" --timeout-seconds 3600
```

`--inspect`仅估计，不证明可生成。Ctrl+C请求取消，等待当前计算结束和进程/管道清理；不是按键后立即强杀GPU。`--cancel-after-steps`可作受控去噪边界检查。文本、图像、音频、视频共用进程内重任务许可；调用方仍须协调不同D进程之间的硬件使用。

2026-09-14首次真实样本在M4/16GiB完成上述几何/50步，CLI耗时1669秒，MLX峰值18.294GiB，最终子进程退出前active18bytes/cache0；swap使用量未知。该次实际使用旧估计13GiB及14GiB指导值，已保留原记录。校准后本几何估计19.28125GiB，旧14GiB准入会明确拒绝；上面的20GiB是调用方显式预算示例，**不是已在20GiB设置下重复完成的完整样本**。校准仅来自这个短片配置，长序列DiT及其他机器峰值仍待测，不据此承诺24/32GiB机型性能。完整样本可见红色玩具车运动，也存在车身形变和末段背景噪点；文件/数值验收不等于专业成片画质验收。

成功的任务目录含request.json、frames/result.json、frames/frames.rgb、output.mp4、media.json，以及任务自己的tmp/cache。发布后的文件不会被release删除；失败私有目录保留用于诊断，应用拥有其清理权。大raw文件/权重/批量结果不入Git。media.json保存最终MP4摘要，避免把全文件摘要写回文件形成自引用。

## 验证入口与解释

- 基础运行时：`scripts/test-foundation.sh`；工作台草稿/候选/迁移/媒体/取消/导出回归：`scripts/test-workbench.sh`。
- `Backends/MLX/Tests/DMLXBackendTests/VideoBackendTests.swift`：CPU契约、受控子进程与合成媒体。音频进程提取同时复验AudioBackendTests/MRT2BackendTests。不是实际模型生成。
- `Backends/Video/Tests/VideoMediaChecks.swift`：软件H.264、完整解码、时间/色彩/文件身份/取消/失败。编译仅需该文件及VideoFrameSequence/VideoArtifactWriter，使用独立输出/模块缓存。
- `test_video_prepare.py`、`test_video_runner_contract.py`：CPU转换/不可变输入/分词器/参数。`D_VIDEO_PYTHON`指Python代码目录、`D_VIDEO_TOKENIZER`指固定分词器目录；临时文件用D_TEST_TEMP_DIR。
- `test_wan_vae_reference.py`、`test_wan_numerics.py`：固定官方源码与小Torch/MLX CPU共享输入；显式D_WAN_VENDOR和D_WAN_REFERENCE_ROOT，禁GPU。官方CPU SDPA fallback不证明CUDA FlashAttention逐位相同。
- 真实生成必须额外记录固定revision、实际请求/精度、完整进程退出、内存/耗时、全部帧解码和人类/维护者看图；CPU mock不能替代。没有承诺跨框架或跨设备逐像素相同。

语法检查使用 `tokenize.open` 和内存 `compile(..., dont_inherit=True)`，不执行目标模块、不写目标pyc。不要使用默认py_compile；其他缓存和临时文件仍须限定在任务目录。未知权限拒绝先停报，不能自行创造绕行路径。

## 离线工作台部署（D-VIDEO-WORKBENCH-01）

`Packaging/prepare_video_engine.py`从已有Python3.12、白名单依赖、固定分词器和源码准备可移动视频引擎；`package_video_app.py`只向新应用副本加入视频并沿既有身份签名，不改输入应用或音频引擎。完整出口以当前任务记录为准。

现有tokenizers 0.22.2 wheel缺少许可证文件。仅此固定版本可使用本仓`Packaging/Licenses/tokenizers-0.22.2-LICENSE.txt`回退：来自[官方v0.22.2标签](https://raw.githubusercontent.com/huggingface/tokenizers/v0.22.2/LICENSE)，SHA-256 `c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4`。有许可证的安装不依赖回退；复制后再次校验。无下载、安装或对原环境写入；其他缺许可证仍拒绝。

便携Python只承诺固定视频provider所需能力。其闲置标准库`_tkinter`无配套Tcl/Tk，不提供Tkinter GUI；视频导入/生成通过不代表通用Python环境或全部扩展闭包通过。
