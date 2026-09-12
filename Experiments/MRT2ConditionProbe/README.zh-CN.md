# MRT2ConditionProbe

这是 D-MRT2-CONDITIONS-01 的独立、受限短片段后端探针。它验证请求、模型清单和路径后，才在当前进程显式导入 Magenta RT/MLX；每次调用生成一个 25 Hz 条件帧（1,920 个 48 kHz 双声道采样帧），复用后端状态，并将未经增益、裁剪或重采样的 IEEE float32 数据写成 WAV。

本目录不是产品接线，也没有假模型 CLI 开关。测试通过 Python 函数的依赖注入缝隙使用纯 CPU adapter，不导入真实 SDK。

## 请求格式

请求是最大 128 KiB 的严格 UTF-8 JSON：

```json
{
  "schemaVersion": 1,
  "frameRate": 25,
  "durationFrames": 75,
  "prompt": "warm chamber strings, restrained dynamics",
  "seed": 1234,
  "notes": [
    {"pitch": 60, "startFrame": 0, "endFrame": 25},
    {"pitch": 64, "startFrame": 0, "endFrame": 25},
    {"pitch": 67, "startFrame": 25, "endFrame": 50}
  ]
}
```

`durationFrames` 为 1..400，`seed` 为 0..2^32-1，`prompt` 非空且 UTF-8 不超过 4,096 bytes。`notes` 最多 512 项；pitch 为 0..127，时间为半开帧区间，必须满足 `0 <= startFrame < endFrame <= durationFrames`。同音高区间不可重叠，相邻区间允许并会重新起音；不同音高可同时构成和弦。

`notes` 缺失表示完全不使用音符条件。`notes: []` 表示显式发送全段 128 维零向量；两者不可互换。指定音符的起始帧值为 2，持续帧为 1，其余为 0；本探针不会生成 3 或 -1。

## 模型清单和运行

`model-root/D-MODEL-MANIFEST.json` 必须且只能有 `repository`、`revision`、`license`、`files`、`totalBytes`。其中 repository 固定为 `google/magenta-realtime-2`，revision 固定为 `010aa0dcb0dfd27b24f0ad07b4dad63e8f9521cc`。每个 `files` 项只能包含规范化相对 `path`、非负 `size` 和小写 SHA-256。探针只读取并校验清单列举的文件，不扫描或修复模型目录。

```sh
/Volumes/CodexProjects/D-TestKit/Runtime/AudioEngine.dengine/python/bin/python3 -B \
  Experiments/MRT2ConditionProbe/probe.py \
  --model-root /absolute/model/root \
  --request /absolute/request.json \
  --output /absolute/new/job-directory \
  --backend exported \
  --timeout-seconds 180
```

`model-root` 和 `output` 必须是绝对路径；模型根、输出根及其祖先不得有符号链接。请求必须是非符号链接普通文件。输出目录必须不存在，不得与模型或请求重叠，且不会覆盖已有对象。

后端固定为：

- `exported`：`MagentaRT2StdMlxfn(size='mrt2_small', warmup_steps=5)`。
- `unquantized`：`MagentaRT2Mlx(size='mrt2_small', bits=None)`；这只表示不额外量化，不能称为全 FP32。

两者都固定使用 temperature 1.3、top-k 40、MusicCoCa CFG 3.0、notes CFG 1.0、drums CFG 1.0，并在模型构造前设置 MLX seed。`timeout-seconds` 最大 600，只在模型加载前后或逐帧边界生效，不能中断正在执行的 GPU 调用。

成功后目录含原子、无覆盖发布的 `output.wav` 和 `report.json`。报告保存请求原文 SHA-256、包含 prompt/seed/notes/时间基的已执行请求快照、规范化条件 SHA-256、模型逐文件证据、可观察 SDK 身份、采样参数、逐帧耗时、输出摘要和可获得的清理指标。快照来自已经严格校验的本地不可变请求值，不上传外部服务。SIGINT 只设置取消请求；当前调用返回后在边界清理，清理完整的取消返回 130、运行错误返回 1、输入错误返回 2、成功返回 0。取消时若释放、同步或 cache 清理失败，会保留原取消上下文，但终态改为失败并返回 1。

WAV 与成功报告按一个发布事务处理：两者均原子且不覆盖；成功报告无法完成时，只在设备号、inode、大小及 SHA-256 仍与本进程发布物一致的情况下回滚 WAV。已经被替换或改变的文件会保留并报告所有权丢失，绝不按名称猜测删除。失败报告的 `output` 不会把候选文件描述成已接受成功。

## CPU 测试

不要使用 `py_compile`。语法检查以 `tokenize.open` 读取源码并在内存中 `compile`；测试只使用任务专属临时根：

```sh
MRT2_PROBE_TEST_ROOT=/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-MRT2-CONDITIONS-01/run-20260912T150154Z/worker/tmp \
TMPDIR=/Volumes/CodexProjects/Codex/D-Development/AgentTrials/D-MRT2-CONDITIONS-01/run-20260912T150154Z/worker/tmp \
/Volumes/CodexProjects/D-TestKit/Runtime/AudioEngine.dengine/python/bin/python3 -B \
  -m unittest -v Experiments/MRT2ConditionProbe/test_probe.py
```

CPU 测试不证明模型可加载、GPU 内存可释放、音质可接受或音频服从条件。条件输入是精确的，但模型输出服从程度仍是 `pending/approximate`，必须由 Lead 进行真实推理、听感和独立信号分析。导出图内部精度仍为 unknown。

Lead 已确认的当前环境事实：官方 `.mlxfn` header 为 0.31.1，在 MLX 0.32.2 会以 `Invalid string size` 导入失败；同一已校验文件在 MLX/metal 0.31.1 可以导入。raw baseline 的 `bits=None` 可以加载，但 Depthformer 实际为 BF16，不能称为全 FP32；SDK 的 exported 与 raw 两条路径都包含 int16 到 float32 的转换。这些是兼容性和实际 dtype 记录，不构成最终音质、条件服从或生命周期验收。
