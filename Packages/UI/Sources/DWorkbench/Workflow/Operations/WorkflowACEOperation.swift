import DInference
import Foundation

/// One shared XL SFT / no-LM recipe; reference audio and edit source remain distinct.
enum WorkflowACEOperation {
    static let operation = WorkflowOperation(definition: .init(id: WorkflowModelRoutes.ace,
        title: "ACE-Step 1.5 XL SFT", detail: "MLX F32 / no-LM：文字、歌词、节拍与可选参考音频；cover 与 repaint 使用独立原声。模型输出48kHz双声道，不承诺精确音符服从。",
        inputs: [.init("prompt", "音乐描述", kinds: [.text], required: false),
                 .init("lyrics", "歌词", kinds: [.text], required: false),
                 .init("reference", "风格参考音频", kinds: [.audio], required: false),
                 .init("source", "cover / repaint 原声", kinds: [.audio], required: false)],
        outputs: [.init("output", "音乐", kinds: [.audio])],
        fields: [.init("mode", "操作", .choice(["generate", "cover", "repaint"]), .text("generate")),
            .init("promptText", "音乐描述", .text(multiline: true), .text("Solo piano.")),
            .init("vocal", "人声", .choice(["instrumental", "lyrics"]), .text("instrumental")),
            .init("lyricsText", "歌词", .text(multiline: true), .text("")),
            .init("language", "歌词语言", .text(multiline: false), .text("en")),
            .init("bpm", "BPM（0为未指定）", .integer, .integer(0)),
            .init("keyScale", "调性（留空为未指定）", .text(multiline: false), .text("")),
            .init("meter", "拍数", .choice(["auto", "2", "3", "4", "6"]), .text("auto")),
            .init("duration", "生成时长（秒；编辑取原声时长）", .decimal, .decimal(5.2)),
            .init("memoryBudgetGiB", "显式内存预算 GiB（0使用运行时策略）", .integer, .integer(0)),
            .init("loadingStrategy", "权重加载（不改变精度）", .choice(["resident", "ssdLayered"]), .text("resident")),
            .init("steps", "步数", .integer, .integer(50)),
            .init("guidance", "引导强度", .decimal, .decimal(7)),
            .init("coverStrength", "Cover 强度", .decimal, .decimal(1)),
            .init("noiseStrength", "Cover 噪声强度", .decimal, .decimal(0)),
            .init("repaintStrength", "Repaint 强度", .decimal, .decimal(1)),
            .init("startFrame", "重绘起始采样帧", .integer, .integer(0)),
            .init("endFrame", "重绘结束采样帧（不含）", .integer, .integer(48000)),
            .init("seed", "种子", .text(multiline: false), .text("42")), WorkflowLanguageOperations.modelField], modelKind: .music),
        validate: { node in
            let p = node.parameters
            guard let seed = UInt64(p["seed"]?.string ?? ""), seed <= UInt32.max,
                  (p["bpm"]?.integer ?? -1) >= 0,
                  (p["steps"]?.integer ?? 0) > 0,
                  ACELoadingStrategy(rawValue: p["loadingStrategy"]?.string ?? "resident") != nil,
                  let duration = p["duration"]?.decimal, duration.isFinite, duration > 0,
                  ["generate", "cover", "repaint"].contains(p["mode"]?.string ?? "") else { throw WorkflowIssue("ACE参数无效。") }
        }, execute: { c, s in .outputs(["output": .asset(try await s.generateACE(context: c))]) })

    static func request(node: WorkflowNode, prompt: String, lyrics: String,
                        reference: AudioSourceReference?, source: AudioSourceReference?) throws -> AudioRequest {
        let p = node.parameters
        guard let seed = UInt64(p["seed"]?.string ?? ""),
              let mode = p["mode"]?.string else { throw WorkflowIssue("ACE操作或seed无效。") }
        guard let strategy = ACELoadingStrategy(rawValue: p["loadingStrategy"]?.string ?? "resident") else { throw WorkflowIssue("未知ACE加载方式。") }
        let hasLyrics = p["vocal"]?.string == "lyrics"
        guard hasLyrics || lyrics.isEmpty else { throw WorkflowIssue("器乐模式不能静默忽略歌词；请选择歌词模式或显式清空。") }
        let meter = p["meter"]?.string ?? "auto"
        guard meter == "auto" || ACETimeSignature(rawValue: meter) != nil else { throw WorkflowIssue("不支持的拍数。") }
        let edit: ACEEditOptions?
        let operation: AudioOperation
        switch mode {
        case "generate": operation = .generate; edit = nil
        case "cover": operation = .variation; edit = .cover(audioCoverStrength: Float(p["coverStrength"]?.decimal ?? 1), noiseStrength: Float(p["noiseStrength"]?.decimal ?? 0))
        case "repaint": operation = .inpaint; edit = .repaint(strength: Float(p["repaintStrength"]?.decimal ?? 1))
        default: throw WorkflowIssue("未知ACE操作。")
        }
        if operation != .generate, source == nil { throw WorkflowIssue("Cover / repaint 必须提供原声音频。") }
        let bpm = p["bpm"]?.integer ?? 0, key = p["keyScale"]?.string ?? ""
        let options = ACERequest(vocal: hasLyrics ? .lyrics(text: lyrics, language: p["language"]?.string ?? "en") : .instrumental,
            bpm: bpm == 0 ? nil : bpm, keyScale: key.isEmpty ? nil : key,
            timeSignature: ACETimeSignature(rawValue: meter), steps: p["steps"]?.integer ?? 50,
            guidanceScale: Float(p["guidance"]?.decimal ?? 7), referenceAudio: reference, editOptions: edit, loadingStrategy: strategy)
        let region = operation == .inpaint ? AudioEditRegion(startFrame: Int64(p["startFrame"]?.integer ?? -1), endFrame: Int64(p["endFrame"]?.integer ?? -1)) : nil
        let duration = source.map { Double($0.frameCount) / Double($0.sampleRate) } ?? (p["duration"]?.decimal ?? 5.2)
        let request = AudioRequest(operation: operation, prompt: prompt, durationSeconds: duration, seed: seed,
            ace: options, source: source, editRegion: region)
        try request.validate(); return request
    }
}
