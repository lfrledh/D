import Foundation

/// Reviewed, descriptive projections of adapters already present in the source tree.
/// This catalog neither discovers installations nor validates or submits inference requests.
public enum ModelNodeCatalog {
    public static let entries: [ModelNodeDescriptor] = [
        flux,
        qwen(
            id: "mlx-community/Qwen2.5-0.5B-Instruct-4bit",
            title: "Qwen2.5 0.5B Instruct · 4-bit",
            revision: "a5339a4131f135d0fdc6a5c8b5bbed2753bbe0f3",
            availability: .workbench,
            validation: "已有工作台历史实测；仍需另行确认本机是否已安装相同固定版本。"
        ),
        qwen(
            id: "mlx-community/Qwen2.5-1.5B-Instruct-4bit",
            title: "Qwen2.5 1.5B Instruct · 4-bit",
            revision: "8b403126fc14f14cfc99bb4cfa72ecbc129ea677",
            availability: .workbench,
            validation: "已有工作台历史实测；登记状态本身不等于当前机器已安装或已复测。"
        ),
        qwen(
            id: "mlx-community/Qwen2.5-7B-Instruct-4bit",
            title: "Qwen2.5 7B Instruct · 4-bit",
            revision: "c26a38f6a37d0a51b4e9a1eb3026530fa35d9fed",
            availability: .workbench,
            validation: "已有工作台历史实测；资源准入仍按实际提示长度、输出预算和设备状态判断。"
        ),
        qwen(
            id: "mlx-community/Qwen2.5-32B-Instruct-4bit",
            title: "Qwen2.5 32B Instruct · 4-bit",
            revision: "2938092373e5f97b95538884112085364c2da315",
            availability: .backend,
            validation: "源码已登记且有外部 CLI 实测；没有普通工作台的 32B 验证，不据此承诺本机可运行。"
        ),
        stableAudio(profile: "sm-music", title: "Stable Audio 3 · Small Music",
                    maximumDuration: "120 秒", availability: .workbench,
                    validation: "源码工作台与 CLI 路径已适配；静态支持不表示模型已安装。"),
        stableAudio(profile: "sm-sfx", title: "Stable Audio 3 · Small SFX",
                    maximumDuration: "120 秒", availability: .evaluation,
                    validation: "后端已适配，但没有真实模型验证；不冒充工作台已验证能力。"),
        stableAudio(profile: "medium", title: "Stable Audio 3 · Medium",
                    maximumDuration: "380 秒", availability: .backend,
                    validation: "已有真实 CLI 路径证据，但不是普通工作台入口的验证。"),
        mrt2,
        swiftF0,
        singing,
        wan21
    ]

    private static func qwen(id: String, title: String, revision: String,
                             availability: ModelNodeAvailability, validation: String) -> ModelNodeDescriptor {
        ModelNodeDescriptor(
            id: id,
            modality: .text,
            title: title,
            summary: "固定版本的 Qwen2.5 Instruct 文字生成节点；接收一个已经由应用组合好的提示词并流式返回文字增量。",
            modelIdentity: id,
            revision: revision,
            engine: "mlx.text · MLX / MLXLLM / MLXLMCommon 2.30.6 · qwen2-text/1",
            device: "默认 GPU；请求不提供设备切换",
            precision: "权重为 affine 4-bit、group size 64；整体计算 dtype 未统一声明",
            availability: availability,
            deploymentNote: validation,
            operations: [
                ModelNodeOperation(
                    id: "text.generate/1",
                    title: "生成文字",
                    summary: "模型接收单一提示词。工作台会在提交前组合选区、指令与资料上下文，它们不是三个独立模型端口。",
                    inputs: [
                        ModelNodePort(id: "prompt", title: "提示词", dataType: "String / UTF-8",
                                      requirement: .required,
                                      detail: "不能为空；最多 1 MiB UTF-8。实际 token 须同时符合输入预算与模型上下文联合上限。")
                    ],
                    outputs: [
                        ModelNodePort(id: "textDelta", title: "流式文字增量", dataType: "String stream",
                                      requirement: .required,
                                      detail: "成功执行会产生按顺序到达的文字增量；不是模型直接写出的文件。")
                    ],
                    parameters: textParameters
                )
            ],
            notes: [
                "输入预算 1…32768（默认 2048），输出预算 1…8192（默认 256）；提示词实际 token 与请求输出之和还必须不超过模型 config 的 max_position_embeddings。",
                "温度只要求有限且不小于 0，没有 2.0 上限。API／CLI 可调；工作台改写固定 0.7、资料回答固定 0.2。",
                "top-p 在 (0, 1]，默认 0.95；API／CLI 可调，当前工作台固定。",
                "后端会记录实际随机种子，但 TextRequest 没有用户可调 seed；也没有 top-k、重复惩罚、工具、图像或多消息端口。",
                "登记、已安装、资源足够和本机实测是不同状态；16 GiB 开发机不是产品上限。"
            ],
            evidencePaths: [
                "Packages/UI/Sources/DWorkbench/Models/TextModelProfiles.swift",
                "Packages/UI/Sources/DWorkbench/Text/TextGenerationSettings.swift",
                "Backends/MLX/Sources/DMLXBackend/MLXTextBackend.swift"
            ]
        )
    }

    private static let textParameters: [ModelNodeParameter] = [
        ModelNodeParameter(id: "maximumPromptTokens", title: "输入 token 预算", defaultValue: "2048",
                           acceptedValues: "1…32768，并受模型上下文联合上限与资源准入限制",
                           detail: "控制应用送入模型的输入预算；不表示任何模型都能在当前机器接纳最大值。", isAdjustable: true),
        ModelNodeParameter(id: "maximumOutputTokens", title: "输出 token 预算", defaultValue: "256",
                           acceptedValues: "1…8192；输入实际 token + 请求输出 ≤ 模型 max_position_embeddings",
                           detail: "请求上限，不保证一定生成到该长度。", isAdjustable: true),
        ModelNodeParameter(id: "temperature", title: "温度", defaultValue: "0.7",
                           acceptedValues: "有限数且 ≥ 0；没有 2.0 上限",
                           detail: "API／CLI 可调；当前工作台改写用 0.7、资料回答用固定 0.2。", isAdjustable: true),
        ModelNodeParameter(id: "topP", title: "Top-p", defaultValue: "0.95",
                           acceptedValues: "有限数，0 < top-p ≤ 1",
                           detail: "API／CLI 可调；当前工作台没有暴露此项。", isAdjustable: true)
    ]

    private static let flux = ModelNodeDescriptor(
        id: "flux2-klein-4b-q8",
        modality: .image,
        title: "FLUX.2 Klein 4B · Q8",
        summary: "同一个固定模型通过三份执行 profile 提供验证尺寸生成、可扩展生成与单图参考编辑。",
        modelIdentity: "mzbac/FLUX.2-klein-4B-q8",
        revision: "ef52ee019fd1d0e75ae4deb40476ba65989716d7",
        engine: "mlx.image.flux2-klein · MLX / fixed Flux2",
        device: "默认 GPU；请求不提供设备选择",
        precision: "Q8 权重；文本编码器、transformer 与 VAE 以 bfloat16 加载，并非全流程 int8",
        availability: .workbench,
        deploymentNote: "源码工作台支持三份 profile；安装状态、历史尺寸实测和当前机器可运行性分别判断。",
        operations: [
            fluxOperation(id: "verified512/1", title: "验证配方生成", reference: false,
                          geometryDefault: "512", geometryAccepted: "固定 512 × 512", adjustableGeometry: false),
            fluxOperation(id: "scalableKlein4B/1", title: "可扩展尺寸生成", reference: false,
                          geometryDefault: "512", geometryAccepted: "宽高各 256…2048、32 的倍数；面积 ≤ 2048²", adjustableGeometry: true),
            fluxOperation(id: "referenceKlein4B/1", title: "单图参考编辑", reference: true,
                          geometryDefault: "512", geometryAccepted: "宽高各 256…2048、32 的倍数；面积 ≤ 2048²", adjustableGeometry: true)
        ],
        notes: [
            "verified512/1 与 scalableKlein4B/1 不接受参考图；referenceKlein4B/1 恰好要求一张参考图，不支持多参考。",
            "全部 profile 固定 4 步、guidance 1、conditioning length 512；没有 mask、strength、negative prompt 或 LoRA。",
            "参考图须为单帧 8-bit RGB／RGBA PNG、最多 64 MiB；校验方向和颜色后冻结为 rgb8-srgb-v1 字节与摘要。参考图几何须合法，但不要求与输出相同。",
            "输出是 8-bit DeviceRGB PNG；不能据此保证文件嵌入 sRGB profile。参考编辑已有源码工作台入口，但 CLI 没有对应 flag。",
            "历史本机覆盖 512×512、768×512、512×768；外部 CLI 覆盖 1024／1536／2048，不表示每台机器都保证这些尺寸。"
        ],
        evidencePaths: [
            "Packages/UI/Sources/DWorkbench/Models/ModelLibraryTypes.swift",
            "Backends/MLX/Sources/DMLXBackend/ImageExecutionProfile.swift",
            "Backends/MLX/Sources/DMLXBackend/MLXImageBackend.swift",
            "Sources/DInference/ImageExecutionCapability.swift"
        ]
    )

    private static func fluxOperation(id: String, title: String, reference: Bool,
                                      geometryDefault: String, geometryAccepted: String,
                                      adjustableGeometry: Bool) -> ModelNodeOperation {
        var inputs = [
            ModelNodePort(id: "prompt", title: "提示词", dataType: "String / UTF-8",
                          requirement: .required,
                          detail: "去除空白后不能为空；最多 1 MiB，模板化后最多 512 token，不静默截断。")
        ]
        if reference {
            inputs.append(ModelNodePort(id: "referenceImage", title: "参考图", dataType: "PNG · rgb8-srgb-v1",
                                        requirement: .required,
                                        detail: "恰好一张单帧 8-bit RGB／RGBA PNG，≤ 64 MiB；不接受多参考。"))
        }
        return ModelNodeOperation(
            id: id,
            title: title,
            summary: reference ? "image.referenceEdit/1：以一张已验证参考图与文字提示生成新图。" : "image.generate/1：仅以文字提示生成新图。",
            inputs: inputs,
            outputs: [
                ModelNodePort(id: "png", title: "生成图像", dataType: "PNG · 8-bit DeviceRGB",
                              requirement: .required,
                              detail: "成功执行的主产物；DeviceRGB 不等同于保证嵌入 sRGB profile。")
            ],
            parameters: [
                ModelNodeParameter(id: "width", title: "宽度", defaultValue: geometryDefault,
                                   acceptedValues: geometryAccepted,
                                   detail: "与高度共同满足 profile 的几何与面积限制。", isAdjustable: adjustableGeometry),
                ModelNodeParameter(id: "height", title: "高度", defaultValue: geometryDefault,
                                   acceptedValues: geometryAccepted,
                                   detail: "与宽度共同满足 profile 的几何与面积限制。", isAdjustable: adjustableGeometry),
                ModelNodeParameter(id: "steps", title: "采样步数", defaultValue: "4", acceptedValues: "固定 4",
                                   detail: "固定配方，不是可运行设置入口。", isAdjustable: false),
                ModelNodeParameter(id: "guidance", title: "Guidance", defaultValue: "1", acceptedValues: "固定 1",
                                   detail: "固定配方。", isAdjustable: false),
                ModelNodeParameter(id: "conditioningLength", title: "条件长度", defaultValue: "512", acceptedValues: "固定 512 token",
                                   detail: "超过时拒绝，不静默截断。", isAdjustable: false),
                ModelNodeParameter(id: "seed", title: "Seed", defaultValue: "工作台随机；固定字段缺省 0",
                                   acceptedValues: "UInt64：0…18446744073709551615",
                                   detail: "完整 UInt64 范围。", isAdjustable: true)
            ]
        )
    }

    private static func stableAudio(profile: String, title: String, maximumDuration: String,
                                    availability: ModelNodeAvailability, validation: String) -> ModelNodeDescriptor {
        ModelNodeDescriptor(
            id: profile,
            modality: .audio,
            title: title,
            summary: "Stable Audio 3 Optimized 的 \(profile) profile，提供从文字生成、参考变奏和区间重绘。",
            modelIdentity: "stabilityai/stable-audio-3-optimized / \(profile)",
            revision: "da6edc54ddba10bfd79a077102ded687f80e882b",
            engine: "mlx.audio.sa3 · Python MLX · DiT + T5 Gemma + codec",
            device: "默认 GPU；请求不提供设备切换",
            precision: "DiT／T5 Gemma FP16；codec 与音频处理 FP32",
            availability: availability,
            deploymentNote: validation,
            operations: stableAudioOperations(maximumDuration: maximumDuration),
            notes: [
                "文字提示在工作台不能为空；最多 1 MiB UTF-8，实际最多 256 token。",
                "参考音频固定为 44.1 kHz 双声道 WAV，可为 PCM16／24／32 或 Float32；请求时长与来源须在半个采样内相等。",
                "区间重绘采用原始来源采样帧的半开区间，必须非空、在界内，且映射到 latent 4096 后仍非空。",
                "输出为 44.1 kHz 双声道 Float32 WAV；不支持 notes、lyrics、negative prompt 或 LoRA。",
                "profile 的源码支持、真实验证、普通工作台入口、模型安装与当前机器资源准入是不同状态。"
            ],
            evidencePaths: [
                "Backends/Audio/Models/\(profile).json",
                "Backends/MLX/Sources/DMLXBackend/AudioExecutionCapabilities.swift",
                "Backends/MLX/Sources/DMLXBackend/AudioBackendConfiguration.swift",
                "Sources/DInference/AudioRequest.swift"
            ]
        )
    }

    private static func stableAudioOperations(maximumDuration: String) -> [ModelNodeOperation] {
        [
            stableAudioOperation(id: "audio.sa3.diffusion.generate", title: "文字生成", reference: false,
                                 inpaint: false, maximumDuration: maximumDuration),
            stableAudioOperation(id: "audio.sa3.diffusion.variation", title: "参考变奏", reference: true,
                                 inpaint: false, maximumDuration: maximumDuration),
            stableAudioOperation(id: "audio.sa3.diffusion.inpaint", title: "区间重绘", reference: true,
                                 inpaint: true, maximumDuration: maximumDuration)
        ]
    }

    private static func stableAudioOperation(id: String, title: String, reference: Bool,
                                             inpaint: Bool, maximumDuration: String) -> ModelNodeOperation {
        var inputs = [
            ModelNodePort(id: "prompt", title: "声音描述", dataType: "String / UTF-8",
                          requirement: .required,
                          detail: "工作台要求非空；最多 1 MiB，最多 256 个实际 token。")
        ]
        if reference {
            inputs.append(ModelNodePort(id: "referenceAudio", title: "参考音频", dataType: "44.1 kHz stereo WAV",
                                        requirement: .required,
                                        detail: "PCM16／24／32 或 Float32；请求时长须与来源在半个采样内一致。"))
        }
        if inpaint {
            inputs.append(ModelNodePort(id: "editRegion", title: "重绘区间", dataType: "原始来源采样帧半开区间",
                                        requirement: .required,
                                        detail: "非空且在来源界内；映射至 latent 4096 后也必须非空。"))
        }
        let strengthFixed = !reference
        return ModelNodeOperation(
            id: id,
            title: title,
            summary: inpaint ? "保留参考音频区间外内容，对指定采样帧范围重绘。" : (reference ? "以一段合法参考音频生成变奏。" : "仅根据文字描述生成完整声音。"),
            inputs: inputs,
            outputs: [
                ModelNodePort(id: "audio", title: "生成音频", dataType: "44.1 kHz stereo Float32 WAV",
                              requirement: .required, detail: "成功执行的主音频产物。")
            ],
            parameters: [
                ModelNodeParameter(id: "duration", title: "时长", defaultValue: "6 秒",
                                   acceptedValues: "> 0 且 ≤ \(maximumDuration)",
                                   detail: reference ? "须与参考音频时长在半个采样内一致。" : "profile 的请求时长上限。", isAdjustable: true),
                ModelNodeParameter(id: "seed", title: "Seed", defaultValue: "42", acceptedValues: "0…4294967294",
                                   detail: "UInt32 最大值减一。", isAdjustable: true),
                ModelNodeParameter(id: "steps", title: "采样步数", defaultValue: "8", acceptedValues: "1…100",
                                   detail: "整数。", isAdjustable: true),
                ModelNodeParameter(id: "guidance", title: "Guidance", defaultValue: "1", acceptedValues: "1…15",
                                   detail: "有限数。", isAdjustable: true),
                ModelNodeParameter(id: "strength", title: "Strength",
                                   defaultValue: strengthFixed ? "1" : "工作台 0.5；CLI 1",
                                   acceptedValues: strengthFixed ? "生成操作固定 1" : "0.01…1",
                                   detail: strengthFixed ? "纯文字生成的固定配方。" : "参考变奏／重绘可调。",
                                   isAdjustable: !strengthFixed)
            ]
        )
    }

    private static let mrt2 = ModelNodeDescriptor(
        id: "mrt2-small-export-v1",
        modality: .audio,
        title: "Magenta Realtime 2 · Small",
        summary: "以器乐风格提示和有明确时基的音符序列生成短时长音乐；音符条件可明确缺席或显式为空。",
        modelIdentity: "google/magenta-realtime-2 · mrt2_small",
        revision: "010aa0dcb0dfd27b24f0ad07b4dad63e8f9521cc",
        engine: "mlx.audio.mrt2 · 官方 MLX export + LiteRT text + SentencePiece",
        device: "音频图默认 MLX GPU；LiteRT 文字部分不声明为全 GPU；请求无设备选择",
        precision: "图内部精度未知；int16 输出按 /32768 转为 Float32",
        availability: .workbench,
        deploymentNote: "源码工作台已适配并有受限真实闭环；不表示任意音符、时长或机器都已验证。",
        operations: [
            ModelNodeOperation(
                id: "audio.mrt2.note-conditioned",
                title: "提示词／音符条件音乐",
                summary: "按 25 Hz 帧时基生成 0.04…16 秒器乐；可提供音符，也可明确表达无音符条件。",
                inputs: [
                    ModelNodePort(id: "prompt", title: "器乐风格提示", dataType: "String / UTF-8",
                                  requirement: .required,
                                  detail: "非空，最多 4096 UTF-8 bytes、127 个 SentencePiece token。"),
                    ModelNodePort(id: "noteSequence", title: "时长与音符序列", dataType: "AudioNoteSequence · 25 Hz",
                                  requirement: .required,
                                  detail: "durationFrames 必填。notes 缺席表示不施加音符条件；notes=[] 表示显式零条件，两者语义不同且都不代表静音。")
                ],
                outputs: [
                    ModelNodePort(id: "audio", title: "生成音乐", dataType: "48 kHz stereo Float32 WAV",
                                  requirement: .required, detail: "成功执行的主音频产物。")
                ],
                parameters: [
                    ModelNodeParameter(id: "durationFrames", title: "时长帧", defaultValue: "150 帧（6 秒）",
                                       acceptedValues: "1…400 帧；25 Hz，即 0.04…16 秒",
                                       detail: "所有音符结束帧不得超过该时长。", isAdjustable: true),
                    ModelNodeParameter(id: "seed", title: "Seed", defaultValue: "42", acceptedValues: "0…4294967295",
                                       detail: "采样随机种子。", isAdjustable: true),
                    ModelNodeParameter(id: "notes", title: "音符联合限制", defaultValue: "示例旋律或无条件",
                                       acceptedValues: "最多 512 音符；MIDI 0…127；0 ≤ start < end ≤ duration",
                                       detail: "同音高音符不可重叠；不同音高可形成和弦。", isAdjustable: true),
                    ModelNodeParameter(id: "warmupSteps", title: "Warmup", defaultValue: "5", acceptedValues: "固定 5",
                                       detail: "固定导出配方。", isAdjustable: false),
                    ModelNodeParameter(id: "temperature", title: "温度", defaultValue: "1.3", acceptedValues: "固定 1.3",
                                       detail: "固定导出配方。", isAdjustable: false),
                    ModelNodeParameter(id: "topK", title: "Top-k", defaultValue: "40", acceptedValues: "固定 40",
                                       detail: "固定导出配方。", isAdjustable: false),
                    ModelNodeParameter(id: "cfg", title: "CFG", defaultValue: "MusicCoCa 3 / notes 1 / drums 1",
                                       acceptedValues: "固定三组 CFG；mapper seed 固定 0",
                                       detail: "不是 SA3 guidance 或 steps。", isAdjustable: false)
                ]
            )
        ],
        notes: [
            "notes 缺席与空数组必须保留区别；显式空数组不是静音承诺。",
            "最多 512 个音符；同音高不可重叠，和弦可以由不同音高的并行音符表达。",
            "音高近似而非精确钢琴复现；不接受参考音频、重绘区间或歌词，也没有 SA3 的 steps／strength。"
        ],
        evidencePaths: [
            "Backends/Audio/Models/mrt2-small.json",
            "Backends/MLX/Sources/DMLXBackend/MRT2ModelInventory.swift",
            "Backends/MLX/Sources/DMLXBackend/MRT2ProviderValidation.swift",
            "Packages/UI/Sources/DWorkbench/Audio/MusicCreationDraft.swift"
        ]
    )

    private static let swiftF0 = ModelNodeDescriptor(
        id: "swift-f0-0.1.2-cpu-v1",
        modality: .audio,
        title: "SwiftF0 0.1.2 · 音高分析",
        summary: "对已验证原始音频选区做单声音高分析；这是分析节点，不生成声音，也不等同于 MIDI 转写。",
        modelIdentity: "swift-f0 0.1.2-d1 · sha256 fa91bb45512b90339cf4b00a599ba8fe3a253c46419fcfe6b46df77a8a8336a5",
        revision: "0.1.2-d1",
        engine: "backendcpu.pitch.swift-f0 · ONNX Runtime CPUExecutionProvider",
        device: "CPU",
        precision: "FP32 输入；宿主派生 16 kHz mono Float32",
        availability: .workbench,
        deploymentNote: "源码内部工作台音高分析已接入；AP1 音符编辑／MIDI 候选未接纳。独立权重分发许可仍未知。",
        operations: [
            ModelNodeOperation(
                id: "audio.pitch.analyze",
                title: "分析单声音高",
                summary: "锁定原始资产身份、版本、摘要和明确帧选区后，派生 16 kHz mono Float32 输入进行分析。",
                inputs: [
                    ModelNodePort(id: "sourceSelection", title: "原始音频选区", dataType: "validated asset + frame range",
                                  requirement: .required,
                                  detail: "来源 8…192 kHz；选区 16 ms…120 s。派生为 256…1,920,000 个 16 kHz 样本，换算误差 ≤ 1 来源采样。")
                ],
                outputs: [
                    ModelNodePort(id: "analysis", title: "音高分析", dataType: "application/vnd.d.pitch-analysis+json",
                                  requirement: .required,
                                  detail: "PitchAnalysisResult：时间、来源、voiced、pitchHz? 与 confidence。"),
                    ModelNodePort(id: "interpretation", title: "近似单音解释", dataType: "PitchInterpretation",
                                  requirement: .optional,
                                  detail: "宿主程序派生的最近十二平均律单音，最短 5×256 样本（80 ms）；不是模型 MIDI 或音频输出。")
                ],
                parameters: [
                    ModelNodeParameter(id: "frequencyRange", title: "频率范围", defaultValue: "46.875…2093.75 Hz",
                                       acceptedValues: "固定 fmin 46.875 / fmax 2093.75",
                                       detail: "当前 profile 的固定模型范围。", isAdjustable: false),
                    ModelNodeParameter(id: "confidenceThreshold", title: "有声阈值", defaultValue: "> 0.9",
                                       acceptedValues: "固定 confidence > 0.9",
                                       detail: "没有可调阈值；confidence 不是校准概率。", isAdjustable: false),
                    ModelNodeParameter(id: "hop", title: "Hop", defaultValue: "256 samples @ 16 kHz",
                                       acceptedValues: "固定 256",
                                       detail: "解释层最短持续时间为 5 hops。", isAdjustable: false)
                ]
            )
        ],
        notes: [
            "不修改或归一化原始音频；只分析宿主派生输入。",
            "unvoiced 的精确含义仍有限，confidence 不是校准概率。",
            "不提供 ASR、TTS、多声音高、音频生成或模型 MIDI 输出。",
            "独立权重的分发许可未知，不能把源码适配写成可随 App 分发。"
        ],
        evidencePaths: [
            "Sources/DInference/PitchAnalysis.swift",
            "Backends/MLX/Sources/DMLXBackend/PitchAnalysisBackend.swift",
            "Backends/MLX/Sources/DMLXBackend/PitchAnalysisProviderProtocol.swift"
        ]
    )

    private static let singing = ModelNodeDescriptor(
        id: "audio.singing.qixuan",
        modality: .audio,
        title: "绮萱 2.7.0 + BigVGAN · 歌声合成",
        summary: "以中文歌词、音符和显式发音锚点合成单声道歌声；声学模型与声码器组成一个复合节点。",
        modelIdentity: "Qixuan 绮萱 2.7.0 DiffSinger/OpenUtau ONNX + nvidia/bigvgan_v2_44khz_128band_512x",
        revision: "BigVGAN 95a9d1dcb12906c03edd938d77b9333d6ded7dfb · Qixuan 2.7.0 fixture-bound",
        engine: "audio.singing.qixuan · Qixuan ONNX acoustic + BigVGAN vocoder",
        device: "声学模型固定 CPU；声码器可用 CPU，或 MPS FP32 profile 优先且明确回退 CPU",
        precision: "Qixuan ONNX profile；BigVGAN CPU 或 FP32 MPS；不是全 GPU",
        availability: .backend,
        deploymentNote: "仅源码后端与 CLI；普通 App 未由 AppSessionFactory 装配，AP1 UI 候选不在当前源。",
        operations: [
            ModelNodeOperation(
                id: "audio.singing.qixuan",
                title: "合成中文歌声",
                summary: "在材料身份、profile 与使用确认等部署前提满足后，根据不可变乐句和发音数据合成歌声。",
                inputs: [
                    ModelNodePort(id: "phrase", title: "歌唱乐句", dataType: "SingingPhrase",
                                  requirement: .required,
                                  detail: "language=zh；中文歌词与 1…4096 个音符；MIDI 0…127，休止可为 null。音符须无缝覆盖整段。"),
                    ModelNodePort(id: "pronunciations", title: "发音与元音锚点", dataType: "SingingPronunciations",
                                  requirement: .required,
                                  detail: "须匹配 phrase ID／revision；每个歌词单元显式音素与合法 vowelIndex，休止使用空音素和 null 锚点。")
                ],
                outputs: [
                    ModelNodePort(id: "audio", title: "合成歌声", dataType: "44.1 kHz mono Float32 WAV",
                                  requirement: .required, detail: "成功执行的主音频产物。"),
                    ModelNodePort(id: "executionRecord", title: "执行记录", dataType: "SingingExecutionRecord",
                                  requirement: .required, detail: "记录实际 profile、材料绑定与执行条件。")
                ],
                parameters: [
                    ModelNodeParameter(id: "executionProfile", title: "执行 profile",
                                       defaultValue: "MPS 可用时优先 mps-fp32；否则 CPU",
                                       acceptedValues: "qixuan-2.7.0-bigvgan-44k-approx-v1 / qixuan-2.7.0-bigvgan-44k-approx-mps-fp32-v1",
                                       detail: "两者都由 CPU 跑 Qixuan；差别是 BigVGAN CPU 或 FP32 MPS。", isAdjustable: true),
                    ModelNodeParameter(id: "timebase", title: "时基与格式预算", defaultValue: "1,000,000 ticks/s",
                                       acceptedValues: "总时长 1…600,000,000 ticks；1…4096 音符／歌词；总音素 ≤ 8192",
                                       detail: "600 秒是格式预算，不是质量已实测上限。", isAdjustable: false),
                    ModelNodeParameter(id: "recipe", title: "声学固定配方",
                                       defaultValue: "hop 512 / head-tail 8 frames / depth 0.6",
                                       acceptedValues: "pitch 10 / variance 20 / acoustic 20 steps；context 500,000 ticks",
                                       detail: "固定执行配方。", isAdjustable: false)
                ]
            )
        ],
        notes: [
            "模型引用、profile、材料绑定与使用确认是环境准入前提，不是创作输入端口；确认不能创造第三方许可。",
            "休止歌词单元对应一个休止音符、空歌词、仅 SP 音素和 null 元音锚点；发声单元不得包含 SP。",
            "没有 seed、文字 prompt、strength 或 guidance。",
            "近似 mel 重投影并非原始 DiffSinger 声码器路径。",
            "MPS profile 只加速 FP32 BigVGAN；不能称整条链路为 GPU。"
        ],
        evidencePaths: [
            "Sources/DInference/SingingRequest.swift",
            "Backends/MLX/Sources/DMLXBackend/SingingBackendConfiguration.swift",
            "Backends/MLX/Sources/DMLXBackend/SingingBackend.swift",
            "Backends/Audio/Fixtures/Singing/qixuan-bigvgan-profile-v1.json",
            "Backends/Audio/Fixtures/Singing/qixuan-bigvgan-mps-fp32-profile-v1.json"
        ]
    )

    private static let wan21 = ModelNodeDescriptor(
        id: "wan21-t2v-1.3b-bf16-v1",
        modality: .video,
        title: "Wan 2.1 T2V · 1.3B BF16",
        summary: "纯文字生成无声 H.264 MP4；当前 adapter 没有首帧、参考图、音频、遮罩或时间线输入。",
        modelIdentity: "Wan-AI/Wan2.1-T2V-1.3B",
        revision: "37ec512624d61f7aa208f7ea8140a131f93afc9a",
        engine: "mlx.video.wan21 · Python MLX · software H.264 encode",
        device: "T5／DiT／VAE 默认 GPU；H.264 软件编码在 CPU，不等于模型 CPU 模式",
        precision: "T5／DiT BF16，time/head/modulation/norm 保留 FP32；VAE FP32",
        availability: .workbench,
        deploymentNote: "源码 App 与 CLI 已适配；理论几何上限不是任意硬件的实测承诺。",
        operations: [
            ModelNodeOperation(
                id: "video.generate/1",
                title: "文字生成视频",
                summary: "依据正向与可选负向提示生成无声视频；当前 Wan 2.1 adapter 仅支持 T2V。",
                inputs: [
                    ModelNodePort(id: "positivePrompt", title: "正向提示词", dataType: "String",
                                  requirement: .required,
                                  detail: "去除空白后非空；最多 512 token，超过时拒绝。"),
                    ModelNodePort(id: "negativePrompt", title: "负向提示词", dataType: "String",
                                  requirement: .optional,
                                  detail: "协议字段存在但可为空；最多 512 token，超过时拒绝。")
                ],
                outputs: [
                    ModelNodePort(id: "video", title: "无声视频", dataType: "H.264 MP4 · Rec.709",
                                  requirement: .required,
                                  detail: "全范围 Rec.709 display RGB，编码写入 Rec.709 tags；不含音轨。"),
                    ModelNodePort(id: "frames", title: "内部帧记录", dataType: "RGB8 frames + execution record",
                                  requirement: .required,
                                  detail: "执行记录保留实际 profile 与参数；主交付物仍为 MP4。")
                ],
                parameters: [
                    ModelNodeParameter(id: "geometry", title: "画面尺寸", defaultValue: "832 × 480",
                                       acceptedValues: "宽高为正且是 16 的倍数；max(width/16, height/16, latentFrames) ≤ 1024",
                                       detail: "latentFrames = (frames - 1) / 4 + 1；联合限制是理论格式边界。", isAdjustable: true),
                    ModelNodeParameter(id: "frames", title: "帧数", defaultValue: "17",
                                       acceptedValues: "4n + 1，且与几何共同满足 latent 上限",
                                       detail: "必须为正并满足联合限制。", isAdjustable: true),
                    ModelNodeParameter(id: "frameRate", title: "帧率", defaultValue: "16/1 fps",
                                       acceptedValues: "分子、分母均为正 Int32",
                                       detail: "有理数帧率。", isAdjustable: true),
                    ModelNodeParameter(id: "steps", title: "采样步数", defaultValue: "50", acceptedValues: "1…1000",
                                       detail: "整数。", isAdjustable: true),
                    ModelNodeParameter(id: "guidance", title: "Guidance", defaultValue: "6", acceptedValues: "有限数且 > 0",
                                       detail: "不静默改写。", isAdjustable: true),
                    ModelNodeParameter(id: "shift", title: "Shift", defaultValue: "8", acceptedValues: "有限数且 > 0",
                                       detail: "调度参数。", isAdjustable: true),
                    ModelNodeParameter(id: "seed", title: "Seed", defaultValue: "42", acceptedValues: "0…4294967295",
                                       detail: "UInt32 全范围。", isAdjustable: true)
                ]
            )
        ],
        notes: [
            "不接受首帧、参考图、音频、mask 或 timeline；本节点没有 I2V 端口。",
            "Wan 2.2 仅有研究性 latent 工作，不属于当前 Wan 2.1 adapter，也不列为可运行节点。",
            "几何公式给出格式边界，不是当前机器的速度、内存或画质保证。"
        ],
        evidencePaths: [
            "Backends/Video/Models/wan21.json",
            "Backends/MLX/Sources/DMLXBackend/VideoBackendConfiguration.swift",
            "Sources/DInference/VideoRequest.swift",
            "Sources/DInference/VideoExecutionCapability.swift"
        ]
    )
}
