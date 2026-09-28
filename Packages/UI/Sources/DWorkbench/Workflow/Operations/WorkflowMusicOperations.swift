import DInference
import Foundation

/// Ordinary operations, never a hidden music scheduler. Each can be used independently.
enum WorkflowMusicOperations {
    static let operations: [WorkflowOperation] = [pitch, align, keys, chords, render, music, trim, convert]
    private static let noteInput = WorkflowPortDefinition("input", "音符", kinds: [.record, .notes])
    private static let recordOutput = WorkflowPortDefinition("output", "结果", kinds: [.record])
    static let pitch = WorkflowOperation(definition: .init(id: "d.music.pitch", title: "识别哼唱音高", detail: "SwiftF0＋连续音符分段；保留原声及连续音高，不等于 Basic Pitch。",
        inputs: [.init("input", "单声部原声", kinds: [.audio])], outputs: [recordOutput, .init("pitch", "连续音高", kinds: [.pitch])],
        fields: [WorkflowLanguageOperations.modelField], modelKind: .pitch), execute: { c, s in
            let input = try WorkflowExecution.inputAsset("input", kind: .audio, context: c)
            let ref = try await s.analyzePitch(input, context: c)
            let result = try JSONDecoder().decode(PitchAnalysisResult.self, from: await s.readData(ref))
            return .outputs(try pitchOutputs(input: input, reference: ref, result: result))
        })
    static func pitchOutputs(input: WorkflowAssetReference, reference: WorkflowAssetReference,
                             result: PitchAnalysisResult) throws -> [String: WorkflowValue] {
        let interpretation = try PitchInterpretation(result: result)
        let sequence = WorkflowNoteSequence(clock: .seconds, notes: interpretation.notes.enumerated().map { i, note in
            .init(id: "note-\(i + 1)", pitch: note.midiNote, start: Double(note.startSample) / 16_000,
                end: Double(note.endSample) / 16_000, velocity: 0.65)
        }, duration: Double(result.sampleCount) / 16_000, sources: [input, reference])
        return ["output": .data(try sequence.datum()), "pitch": .asset(reference)]
    }
    static let align = WorkflowOperation(definition: .init(id: "d.music.align", title: "解释节拍", detail: "保留原声；显式速度、拍号与量化产生新的音符解释。",
        inputs: [noteInput, .init("tempo", "速度映射", kinds: [.record, .tempo], required: false)], outputs: [recordOutput],
        fields: [.init("bpm", "BPM", .decimal, .decimal(120)), .init("firstBeatSeconds", "第一拍秒位置", .decimal, .decimal(0)),
            .init("numerator", "拍号分子", .integer, .integer(4)), .init("denominator", "拍号分母", .integer, .integer(4)),
            .init("snap", "量化", .choice(WorkflowMusicSnap.allCases.map(\.rawValue)), .text("none"))]), execute: { c, s in
            let sequence = try WorkflowNoteSequence(datum: await datum(c.inputs["input"], services: s))
            let p = c.node.parameters
            let tempo: WorkflowTempoMap
            if let input = c.inputs["tempo"] { tempo = try WorkflowTempoMap(datum: await datum(input, services: s)) }
            else { tempo = .init(beatsPerMinute: p["bpm"]?.decimal ?? 120, firstBeatSeconds: p["firstBeatSeconds"]?.decimal ?? 0,
                numerator: p["numerator"]?.integer ?? 4, denominator: p["denominator"]?.integer ?? 4) }
            guard let snap = WorkflowMusicSnap(rawValue: p["snap"]?.string ?? "") else { throw WorkflowIssue("量化方式未知。") }
            return .outputs(["output": .data(try WorkflowMusicPrograms.align(sequence: sequence, tempo: tempo, snap: snap).datum())])
        })
    static let keys = WorkflowOperation(definition: .init(id: "d.music.keys", title: "查看调性候选", detail: "时长加权音阶匹配；分数不是概率，不替用户决定。",
        inputs: [noteInput], outputs: [.init("output", "候选列表", kinds: [.list])]), execute: { c, s in
            let notes = try WorkflowNoteSequence(datum: await datum(c.inputs["input"], services: s))
            let schema: [WorkflowRecordField] = [.init("root", .number(unit: nil)), .init("mode", .text), .init("score", .number(unit: nil)), .init("algorithm", .text)]
            let items = try WorkflowMusicPrograms.keys(sequence: notes).map { candidate in
                WorkflowDataItem(id: "\(candidate.root)-\(candidate.mode)", value: .record(schema: schema, fields: [
                    "root": .number(Double(candidate.root), unit: nil), "mode": .text(candidate.mode),
                    "score": .number(candidate.score, unit: nil), "algorithm": .text(candidate.algorithm)]))
            }
            return .outputs(["output": .data(.list(element: .record(schema), items: items))])
        })
    static let chords = WorkflowOperation(definition: .init(id: "d.music.chords", title: "编写和声", detail: "可编辑的和弦轨及明确转位/织体；不是隐式提示词。",
        inputs: [.init("input", "和弦轨", kinds: [.record, .chords], required: false)],
        outputs: [recordOutput, .init("notes", "和弦音符", kinds: [.record])],
        fields: [.init("pattern", "织体", .choice(["sustained", "arpeggio"]), .text("sustained"))]), execute: { c, s in
            let value = try await datum(c.inputs["input"] ?? c.node.dataConfiguration?.value.map(WorkflowValue.data), services: s)
            let track = try WorkflowChordTrack(datum: value)
            guard let pattern = WorkflowChordPattern(rawValue: c.node.parameters["pattern"]?.string ?? "") else { throw WorkflowIssue("和弦织体无效。") }
            return .outputs(["output": .data(try track.datum()), "notes": .data(try WorkflowMusicPrograms.chordNotes(track: track, pattern: pattern).datum())])
        })
    static let render = WorkflowOperation(definition: .init(id: "d.music.render", title: "音符合成试听", detail: "确定性正弦参考音；供纠错试听，不冒充钢琴或歌声模型。",
        inputs: [noteInput], outputs: [.init("output", "试听音频", kinds: [.audio])]), execute: { c, s in
            let notes = try WorkflowNoteSequence(datum: await datum(c.inputs["input"], services: s))
            let bytes = try await WorkflowCPU.run { try WorkflowMusicPrograms.render(sequence: notes, sampleRate: 48_000) }
            let parents = Array(Set(notes.sources + c.inputs.values.flatMap { $0.datum?.assetReferences ?? [] })).sorted { $0.assetID.uuidString < $1.assetID.uuidString }
            return .outputs(["output": .asset(try await s.publishMedia(bytes, mediaType: "audio/wav", parents: parents, context: c))])
        })
    static let music = WorkflowOperation(definition: .init(id: "d.music.generate", title: "受控音乐小样", detail: "MRT2 以25Hz（40ms）编码音高、起音与延续；同音声部合并，非零力度不编码，鼓当前不受约束。输出限48kHz双声道WAV、最长16秒；采样固定温度1.3、Top-k 40、MusicCoCa CFG 3及音符/鼓 CFG 1。条件服从为近似，不保证精确复现。",
        inputs: [.init("prompt", "创作意图", kinds: [.text], required: false),
            .init("notes", "音符条件（可选；可显式为空）", kinds: [.record, .notes], required: false),
            .init("chords", "和声", kinds: [.record, .chords], required: false)], outputs: [.init("output", "音乐", kinds: [.audio])],
        fields: [.init("promptText", "意图", .text(multiline: true), .text("Solo piano, clear melody.")),
            .init("durationFrames", "时长（25Hz帧）", .integer, .integer(100)),
            .init("seed", "种子", .text(multiline: false), .text("42")), WorkflowLanguageOperations.modelField], modelKind: .music), execute: { c, s in
            let prompt = try await WorkflowLanguageOperations.text(c.inputs["prompt"], fallback: c.node.parameters["promptText"]?.string ?? "", services: s)
            let notes: WorkflowNoteSequence?
            if let value = c.inputs["notes"] { notes = try WorkflowNoteSequence(datum: await datum(value, services: s)) } else { notes = nil }
            let track: WorkflowChordTrack?
            if let value = c.inputs["chords"] { track = try WorkflowChordTrack(datum: await datum(value, services: s)) } else { track = nil }
            guard let seed = UInt64(c.node.parameters["seed"]?.string ?? "") else { throw WorkflowIssue("音乐 seed 无效。") }
            let sequence = try WorkflowMRT2Condition.make(notes: notes, chords: track, durationFrames: c.node.parameters["durationFrames"]?.integer ?? 100)
            let parents = Array(Set((notes?.sources ?? []) + (track?.sources ?? []) + c.inputs.values.flatMap { $0.datum?.assetReferences ?? [] }))
                .sorted { $0.assetID.uuidString < $1.assetID.uuidString }
            return .outputs(["output": .asset(try await s.generateMusic(.init(prompt: prompt, seed: seed, noteSequence: sequence), parents: parents, context: c))])
        })
    static let trim = audioProgram("trim", title: "截取音频", includeConversion: false)
    static let convert = audioProgram("convert", title: "转换音频规格", includeConversion: true)
    private static func audioProgram(_ suffix: String, title: String, includeConversion: Bool) -> WorkflowOperation {
        var fields: [WorkflowFieldDefinition] = [.init("whole", "完整片段", .flag, .flag(true)),
            .init("startFrame", "起始采样帧", .integer, .integer(0)), .init("endFrame", "结束采样帧（不含）", .integer, .integer(16000))]
        if includeConversion { fields += [.init("sampleRate", "输出采样率（0保留）", .integer, .integer(0)),
            .init("channels", "声道（0保留）", .integer, .integer(0))] }
        return .init(definition: .init(id: "d.audio." + suffix, title: title, detail: "明确范围与采样规格，发布新资产，不修改原声。",
            inputs: [.init("input", "原声", kinds: [.audio])], outputs: [.init("output", "音频", kinds: [.audio])], fields: fields), execute: { c, s in
                let ref = try WorkflowExecution.inputAsset("input", kind: .audio, context: c)
                return .outputs(["output": .asset(try await s.transformAudio(ref, context: c))])
            })
    }
    @MainActor static func datum(_ value: WorkflowValue?, services: any WorkflowOperationServices) async throws -> WorkflowDatum {
        guard let value else { throw WorkflowIssue("缺少音乐数据。") }
        if let ref = value.asset {
            guard [.notes, .chords, .tempo].contains(ref.kind) else { throw WorkflowIssue("需要明确的音符、和弦或速度资产。") }
            return try JSONDecoder().decode(WorkflowDatum.self, from: await services.readData(ref))
        }
        guard let datum = value.datum else { throw WorkflowIssue("需要结构化音乐数据。") }
        try datum.validate(); return datum
    }
}
/// The 25 Hz rounding is explicit recipe behavior, never a change to editable score data.
enum WorkflowMRT2Condition {
    static func make(notes: WorkflowNoteSequence?, chords: WorkflowChordTrack?, durationFrames: Int) throws -> AudioNoteSequence {
        guard (1...400).contains(durationFrames) else { throw WorkflowIssue("当前 MRT2 配方支持1…400个25Hz条件帧。") }
        var values: [WorkflowNoteSequence] = []
        if let notes { values.append(notes) }
        if let chords { values.append(try WorkflowMusicPrograms.chordNotes(track: chords, pattern: .sustained)) }
        var output: [AudioNoteEvent] = []
        for value in values {
            try value.validate()
            if value.clock == .quarterNotes && value.tempo == nil { throw WorkflowIssue("拍时间音符需要显式速度映射。") }
            func seconds(_ time: Double) -> Double {
                workflowMusicTimelineSeconds(time, clock: value.clock, tempo: value.tempo)
            }
            for note in value.notes where note.velocity > 0 {
                let start = seconds(note.start), end = seconds(note.end)
                guard start >= 0, end <= Double(durationFrames) / 25,
                      let a = Int(exactly: (start * 25).rounded(.toNearestOrAwayFromZero)),
                      let b = Int(exactly: (end * 25).rounded(.toNearestOrAwayFromZero)), b > a else {
                    throw WorkflowIssue("音符超出小样范围或短于25Hz条件分辨率；请明确修改片段，不会静默截断。")
                }
                output.append(.init(pitch: note.pitch, startFrame: a, endFrame: b))
            }
        }
        // MRT2 encodes 0=rest, 1=sustain, 2=onset. Keep every distinct onset
        // while collapsing voice overlap; nonzero velocity/voice identity are not encoded.
        let grouped = Dictionary(grouping: output, by: \.pitch)
        var occupancy: [AudioNoteEvent] = []
        for pitch in grouped.keys.sorted() {
            let starts = Dictionary(grouping: grouped[pitch]!, by: \.startFrame)
            var held: AudioNoteEvent?
            for start in starts.keys.sorted() {
                let end = starts[start]!.map(\.endFrame).max()!
                if let prior = held {
                    if start <= prior.endFrame {
                        occupancy.append(.init(pitch: pitch, startFrame: prior.startFrame, endFrame: start))
                        held = .init(pitch: pitch, startFrame: start, endFrame: max(prior.endFrame, end))
                    } else { occupancy.append(prior); held = .init(pitch: pitch, startFrame: start, endFrame: end) }
                } else { held = .init(pitch: pitch, startFrame: start, endFrame: end) }
            }
            if let held { occupancy.append(held) }
        }
        let result = AudioNoteSequence(durationFrames: durationFrames, notes: values.isEmpty ? nil : occupancy)
        try result.validate()
        return result
    }
}
