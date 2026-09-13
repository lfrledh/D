# Wan V0 本地视频后端

D-VIDEO-V0-01 的命令行后端；工作台视频入口尚未开放。阶段验收状态、代码版本和实际结果以 `docs/tasks/D-VIDEO-V0-01.md` 为准。

## 边界

输入是不可变的正/负文本条件、已安装的固定模型及显式几何/帧率/步数/引导/seed；输出是无声 H.264 MP4 文件引用、实际执行配方和独立媒体检查记录。推理不下载资源，不调用云端，不制作音轨，不把视频资源复制进控制事件。

- 模型：Wan2.1 T2V-1.3B，revision `37ec512624d61f7aa208f7ea8140a131f93afc9a`；本适配器暂不支持其他 checkpoint 或 I2V。
- 精度：T5 BF16；DiT 主体 BF16并保留原 FP32 time/head/modulation/norm；VAE FP32。原始权重保留，不能静默改成量化模型。
- 模型形状要求：宽高为16倍数，帧数4n+1；本适配器各latent轴不超过1024，1...1000步、UInt32 seed，正的引导及shift。模型条件格式512token，超长明确拒绝，不截断。
- 请求的帧率是有理数 p/q；N帧容器时长=Nq/p。采样器固定 UniPC order2/bh2；几何、参数和精度不随开发机偷偷改变。
- M4/16GiB不是能力上限。调用方明确给内存预算；运行时报告预算拒绝或实际加载/计算失败。更大模型需要独立适配/授权，不能仅改文件夹名。
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
  --steps 50 --guidance 6 --shift 8 --seed 42 --memory-budget-mib 14336 \
  --artifacts "$NEW_RUN/artifacts" --report "$NEW_RUN/cli-report.json" --timeout-seconds 3600
```

`--inspect`仅估计，不证明可生成。Ctrl+C请求取消，等待当前计算结束和进程/管道清理；不是按键后立即强杀GPU。`--cancel-after-steps`可作受控去噪边界检查。文本、图像、音频、视频共用进程内重任务许可；调用方仍须协调不同D进程之间的硬件使用。

成功的任务目录含request.json、frames/result.json、frames/frames.rgb、output.mp4、media.json，以及任务自己的tmp/cache。发布后的文件不会被release删除；失败私有目录保留用于诊断，应用拥有其清理权。大raw文件/权重/批量结果不入Git。media.json保存最终MP4摘要，避免把全文件摘要写回文件形成自引用。

## 验证入口与解释

- 基础运行时：`scripts/test-foundation.sh`；工作台显式拒绝视频任务回归：`scripts/test-workbench.sh`。
- `Backends/MLX/Tests/DMLXBackendTests/VideoBackendTests.swift`：CPU契约、受控子进程与合成媒体。音频进程提取同时复验AudioBackendTests/MRT2BackendTests。不是实际模型生成。
- `Backends/Video/Tests/VideoMediaChecks.swift`：软件H.264、完整解码、时间/色彩/文件身份/取消/失败。编译仅需该文件及VideoFrameSequence/VideoArtifactWriter，使用独立输出/模块缓存。
- `test_video_prepare.py`、`test_video_runner_contract.py`：CPU转换/不可变输入/分词器/参数。`D_VIDEO_PYTHON`指Python代码目录、`D_VIDEO_TOKENIZER`指固定分词器目录；临时文件用D_TEST_TEMP_DIR。
- `test_wan_vae_reference.py`、`test_wan_numerics.py`：固定官方源码与小Torch/MLX CPU共享输入；显式D_WAN_VENDOR和D_WAN_REFERENCE_ROOT，禁GPU。官方CPU SDPA fallback不证明CUDA FlashAttention逐位相同。
- 真实生成必须额外记录固定revision、实际请求/精度、完整进程退出、内存/耗时、全部帧解码和人类/维护者看图；CPU mock不能替代。没有承诺跨框架或跨设备逐像素相同。

语法检查使用 `tokenize.open` 和内存 `compile(..., dont_inherit=True)`，不执行目标模块、不写目标pyc。不要使用默认py_compile；其他缓存和临时文件仍须限定在任务目录。未知权限拒绝先停报，不能自行创造绕行路径。
