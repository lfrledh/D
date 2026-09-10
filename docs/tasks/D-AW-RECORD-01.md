# D-AW-RECORD-01 / AW1-R1

批次 D-AUDIO-WORKBENCH-01；规格 R1；来源基线 633150477de90d30c1f44c915b1f10e13acd246d；执行基线见 run/request。Astra Lead 维护此规格，Worker 不编辑文档。新获批边界是从 ProjectStore 的固定根目录到真正录音 writer 的完整文件所有权；继承旧 H09 失败，不称旧任务独立成功。

目标：消除“先校验 URL，之后 AVAudioRecorder 再按路径打开”的 TOCTOU，修复已知两个测试调用编译问题。录音只用户点击后请求，固定48kHz/mono/float32 CAF/现有120秒64MiB边界；不能扩大系统能力。持有经 rootFD 安全创建的文件描述符贯穿写入与刷新，父目录被替换/重命名后不得向替换目录或任意外部文件写入。最终化必须核对根/目录/文件身份，失败保留预约及实际已写文件，不删未知文件。权限前不创录音文件，拒绝/取消后不启动；permission等待和所有await前后维持上下文/epoch。

允许：Packages/UI/Sources/DWorkbench/Audio/AudioTransport.swift、ProjectAudioController.swift；新增 AudioCaptureFile.swift / AudioRecordingDevice.swift；Project/ProjectStore.swift 中 reserveAudioCapture/audioCaptureURL/finalizeAudioCapture及新增 capture 专用方法（不改其余生成/导入/文本/导出逻辑）；直接 AudioTransportTests.swift、AudioProjectStoreTests.swift、ProjectAudioSessionTests.swift、UITests/AudioWorkbenchViewTests.swift，以及新增 AudioCaptureFileTests.swift。不得改规格/全局文档、DInference/模型后端/ProjectModels/工程配置/签名/entitlements/依赖/源工作区。必要超界先报告。

实现选择：优先 descriptor-backed AudioFile callbacks + 合适 Apple 输入 API（AudioQueue 或 AVAudioEngine），不要把已验证路径又交给按 URL 重开的 AVAudioRecorder；不要仅再加一遍 lstat 或 /dev/fd URL 猜测。可以提出更小而满足同一语义的实现。回调生命周期、buffer/FD关闭必须明确，真实录音由 Lead 后续验收。不得批量 unchecked Sendable 绕编译；单个必要跨 C 回调封装需具体锁/所有权理由。预检阶段先给最小设计建议，禁止写实现。

Lead冻结反例：1正常批准+合成PCM可解码CAF且保留预约至提交；2权限拒绝或等待中取消无文件/设备；3预约父目录替换为symlink，创建前拒绝；4创建后替换/改名，后续写只能进入已持有原文件，替换目标不变且finalize拒绝身份失配；5leaf已存在/符号链接拒绝不覆盖；6writer失败/stop刷新失败不标保存成功，原文件可恢复；7上下文失效不跨文档发布；8旧341层根遍历问题及所有既有transport/controller/store/UI测试维持断言。

独立工作树 D-Worktrees/D-AW-RECORD-01，分支 codex/d-aw-record-01。gpt-5.6-sol/high（原生录音回调及文件生命周期高风险）；受限CLI workspace-write/no network，只本树+本run worker-output/tmp，Git共享目录不可写。只CPU测试，无mic/device/GUI/GPU/下载/依赖更新。SwiftPM内部沙箱拒绝时停该检查交Lead，不自行降级。Python只tokenize.open+内存compile；所有缓存/临时文件用所给唯一目录。未知权限拒绝立即报Lead；受控失败夹具单列。初交+2修复，一次有界Lead接管后仍失败停止；每次900秒，禁止递归。

回传：实际改动/编译测试/原始证据路径/未覆盖/风险/自有进程状态；不commit。Lead审阅并在停止写入后显式提交。真实身份以请求与turn_context为证，不自述替代。
