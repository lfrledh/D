import Foundation

public enum WorkflowLanguageExample: String, CaseIterable, Sendable {
    case data
    case images
    case music
    case multimodal
}

public struct WorkflowLanguageExampleBundle: Sendable {
    public var graph: WorkflowGraph
    public var tools: [WorkflowToolDefinition]

    public init(graph: WorkflowGraph, tools: [WorkflowToolDefinition] = []) {
        self.graph = graph
        self.tools = tools
    }
}

/// Editable examples built only from registered operations and structured controls.
/// Model identities deliberately remain empty; the controller freezes the user's
/// selected registered models when a run is submitted.
public enum WorkflowLanguageExamples {
    public static func make(_ example: WorkflowLanguageExample) throws -> WorkflowLanguageExampleBundle {
        switch example {
        case .data: try dataExample()
        case .images: try imageExample()
        case .music: try musicExample()
        case .multimodal: try multimodalExample()
        }
    }

    // MARK: - E01: deterministic data language

    private static func dataExample() throws -> WorkflowLanguageExampleBundle {
        let itemFields = dataItemFields
        let tagFields = dataTagFields
        let itemSchema = WorkflowDataSchema.record(itemFields)

        var itemIndex = try valueInput("编号", value: .number(2, unit: nil))
        var itemTitle = try valueInput("标题", value: .text("可编辑主项"))
        var itemScore = try valueInput("分数", value: .number(0.92, unit: nil))
        var itemKeep = try valueInput("保留", value: .boolean(true))
        var itemOptions = try valueInput("候选文字", value: textList(["重点版本"]))
        itemIndex.title = "输入编号"
        itemTitle.title = "输入标题"
        itemScore.title = "输入分数"
        itemKeep.title = "输入保留标记"
        itemOptions.title = "输入候选文字列表"

        var record = try node("d.value.record", title: "组合字段")
        record.dataConfiguration = .init(fields: itemFields)

        let first = dataItem(id: 1, title: "第一项", score: 0.80, keep: true, options: ["基础版本"])
        let third = dataItem(id: 3, title: "可编辑失败反例", score: 0.99, keep: false, options: [])
        var list = try node("d.value.list", title: "组成列表")
        list.dataConfiguration = .init(
            schema: itemSchema,
            fields: [.init("featured", itemSchema)],
            items: [.init(id: "item-1", value: first), .init(id: "item-3", value: third)]
        )

        var filter = try node("d.value.filter", title: "筛选并稳定排序")
        filter.parameters["ascending"] = .flag(false)
        filter.parameters["limit"] = .integer(16)
        filter.dataConfiguration = .init(
            path: ["score"],
            rules: [.init(path: ["keep"], comparison: .equals, value: .boolean(true))]
        )

        var select = try node("d.value.select", title: "明确取第一项")
        select.parameters["method"] = .text("index")
        select.parameters["index"] = .integer(1)

        var titleField = try node("d.value.field", title: "读取标题字段")
        titleField.dataConfiguration = .init(schema: .text, path: ["title"])

        let rightTags = WorkflowDatum.list(element: .record(tagFields), items: [
            .init(id: "tag-1", value: dataTag(id: 1, category: "基础")),
            .init(id: "tag-2", value: dataTag(id: 2, category: "重点")),
            .init(id: "tag-4", value: dataTag(id: 4, category: "未匹配")),
        ])
        var tagInput = try valueInput("标签列表", value: rightTags)
        tagInput.title = "输入标签列表"

        var pair = try node("d.value.pair", title: "按编号配对")
        pair.dataConfiguration = .init(path: ["index"])

        var validate = try node("d.value.validate", title: "报告数据检查")
        validate.parameters["strict"] = .flag(false)
        validate.dataConfiguration = .init(schema: itemSchema)
        let validationSchema = validationReportSchema(for: itemSchema)

        var validField = try node("d.value.field", title: "读取检查结果")
        validField.dataConfiguration = .init(schema: .boolean, path: ["valid"])

        var branch = try node("d.control.branch", title: "按检查结果选择")
        branch.control = .branch(
            predicate: .init(comparison: .equals, value: .boolean(true)),
            then: try passthroughGraph(name: "检查通过", inputName: "input", schema: .boolean, fallback: .boolean(true)),
            otherwise: try passthroughGraph(name: "检查未通过", inputName: "input", schema: .boolean, fallback: .boolean(false))
        )

        var map = try node("d.control.map", title: "逐项保留身份")
        map.control = .map(body: try fallibleItemMapBody(schema: itemSchema, fallback: first), continueOnFailure: true)

        var initialState = try valueInput("循环初始状态", value: .number(0, unit: nil))
        initialState.title = "输入循环状态"
        var loop = try node("d.control.loop", title: "有限状态循环")
        loop.control = .loop(
            body: try incrementingLoopBody(),
            stateSchema: .number(unit: nil),
            maximumIterations: 4,
            until: .init(comparison: .equals, value: .number(3, unit: nil))
        )

        let pairSchema = WorkflowDataSchema.record([
            .init("left", itemSchema), .init("right", .record(tagFields)),
        ])
        let summaryFields: [WorkflowRecordField] = [
            .init("title", .text),
            .init("approved", .boolean),
            .init("validation", validationSchema),
            .init("pairs", .list(pairSchema)),
            .init("mapped", .list(.result(.text))),
            .init("loopState", .number(unit: nil)),
        ]
        var summary = try node("d.value.record", title: "组合运行摘要")
        summary.dataConfiguration = .init(fields: summaryFields)

        var result = try node("d.value.return", title: "返回数据结果")
        result.parameters["name"] = .text("dataExample")
        var export = try node("d.value.export", title: "按用户目标导出")
        export.parameters["fileName"] = .text("data-example")
        export.parameters["format"] = .text("json")

        let nodes = [
            itemIndex, itemTitle, itemScore, itemKeep, itemOptions, record, list, filter, select, titleField,
            tagInput, pair, validate, validField, branch, map, initialState, loop, summary, result, export,
        ]
        let connections: [WorkflowConnection] = [
            connect(itemIndex, record, targetPort: "index"),
            connect(itemTitle, record, targetPort: "title"),
            connect(itemScore, record, targetPort: "score"),
            connect(itemKeep, record, targetPort: "keep"),
            connect(itemOptions, record, targetPort: "options"),
            connect(record, list, targetPort: "featured"),
            connect(list, filter),
            connect(filter, select),
            connect(select, titleField),
            connect(filter, pair, targetPort: "left"),
            connect(tagInput, pair, targetPort: "right"),
            connect(select, validate),
            connect(validate, validField),
            connect(validField, branch),
            connect(filter, map),
            connect(initialState, loop),
            connect(titleField, summary, targetPort: "title"),
            connect(branch, summary, targetPort: "approved"),
            connect(validate, summary, targetPort: "validation"),
            connect(pair, summary, targetPort: "pairs"),
            connect(map, summary, targetPort: "mapped"),
            connect(loop, summary, targetPort: "loopState"),
            connect(summary, result),
            connect(result, export),
        ]
        let graph = WorkflowGraph(
            name: "E01 数据整理与控制",
            nodes: nodes,
            connections: connections,
            layout: gridLayout(nodes)
        )
        return .init(graph: graph)
    }

    // MARK: - E02: planned image sets

    private static func imageExample() throws -> WorkflowLanguageExampleBundle {
        let imageTool = try makeImageSetTool()
        var subject = try valueInput("创作主题", value: .text("城市公共花园与夜间阅读空间"))
        subject.title = "输入总体主题"

        let planningTool = try WorkflowJSONRepairTool.make(
            schema: .list(.record(themeFields)),
            task: "Create exactly two different visual themes from the supplied content. Each theme has a unique nonempty themeID, a nonempty title, and a detailed image prompt. Use only these three string fields. Return only the JSON array, with no Markdown or explanation.",
            exampleJSON: #"[{"themeID":"theme-1","title":"Example title A","prompt":"Describe the first distinct image"},{"themeID":"theme-2","title":"Example title B","prompt":"Describe the second distinct image"}]"#)
        var planner = try node("d.control.invoke", title: "一次规划全部主题")
        planner.control = .invoke(.init(id: planningTool.id, version: planningTool.version, digest: try WorkflowPlanCompiler.digest(planningTool)))
        planner.dataConfiguration = .init(fields: planningTool.graph.interface?.inputs ?? [])

        var map = try node("d.control.map", title: "按运行时主题逐项生成")
        map.control = .map(body: try themeImageMapBody(tool: imageTool), continueOnFailure: true)

        var result = try node("d.value.return", title: "返回主题图组")
        result.parameters["name"] = .text("imageSets")

        let nodes = [subject, planner, map, result]
        let graph = WorkflowGraph(
            name: "E02 两主题三图",
            nodes: nodes,
            connections: [
                connect(subject, planner, targetPort: "content"),
                connect(planner, map),
                connect(map, result),
            ],
            layout: gridLayout(nodes)
        )
        return .init(graph: graph, tools: [imageTool, planningTool])
    }

    private static func makeImageSetTool() throws -> WorkflowToolDefinition {
        let fallbackTheme = theme(id: "theme-example", title: "示例主题", prompt: "A calm reading garden at dusk")
        let themeSchema = WorkflowDataSchema.record(themeFields)
        let themeInput = try publicInput("theme", schema: themeSchema, fallback: fallbackTheme, title: "工具输入主题")

        var themeID = try node("d.value.field", title: "读取主题身份")
        themeID.dataConfiguration = .init(schema: .text, path: ["themeID"])
        var prompt = try node("d.value.field", title: "读取图像提示")
        prompt.dataConfiguration = .init(schema: .text, path: ["prompt"])

        var generate = try node("d.image.generate", title: "每主题生成三图")
        generate.parameters["count"] = .integer(3)
        generate.parameters["modelID"] = .text("")
        var candidates = try node("d.value.candidates", title: "保留全部候选状态")

        var process = try node("d.control.map", title: "只处理成功图片")
        process.control = .map(body: try imageProcessingBody(), continueOnFailure: true)

        let groupFields: [WorkflowRecordField] = [
            .init("themeID", .text),
            .init("candidates", .list(.record(candidateFields))),
            .init("processed", .list(.result(.asset(.image)))),
        ]
        var group = try node("d.value.record", title: "组合主题候选与处理结果")
        group.dataConfiguration = .init(fields: groupFields)
        var output = try node("d.value.return", title: "返回主题图组")
        output.parameters["name"] = .text("output")

        let nodes = [themeInput, themeID, prompt, generate, candidates, process, group, output]
        var graph = WorkflowGraph(
            name: "工具：单主题图组",
            nodes: nodes,
            connections: [
                connect(themeInput, themeID),
                connect(themeInput, prompt),
                connect(prompt, generate, targetPort: "prompt"),
                connect(generate, candidates),
                connect(candidates, process, sourcePort: "successful"),
                connect(themeID, group, targetPort: "themeID"),
                connect(candidates, group, targetPort: "candidates"),
                connect(process, group, targetPort: "processed"),
                connect(group, output),
            ],
            layout: gridLayout(nodes)
        )
        graph.interface = .init(
            inputs: [.init("theme", themeSchema)],
            outputs: [.init(name: "output", nodeID: output.id, schema: .record(groupFields))]
        )
        return .init(name: "生成单主题三图并处理成功项", graph: graph)
    }

    private static func imageProcessingBody() throws -> WorkflowGraph {
        let input = try requiredPublicInput("item", schema: .asset(.image), title: "成功图片")
        var resize = try node("d.image.resize", title: "明确调整尺寸")
        resize.parameters["width"] = .integer(768)
        resize.parameters["height"] = .integer(768)
        resize.parameters["mode"] = .text("fit")
        var convert = try node("d.image.convert", title: "明确转换 PNG")
        convert.parameters["format"] = .text("png")
        var output = try node("d.value.return", title: "返回处理图片")
        output.parameters["name"] = .text("output")
        let nodes = [input, resize, convert, output]
        var graph = WorkflowGraph(
            name: "成功图片尺寸与格式",
            nodes: nodes,
            connections: [connect(input, resize), connect(resize, convert), connect(convert, output)],
            layout: gridLayout(nodes)
        )
        graph.interface = .init(
            inputs: [.init("item", .asset(.image))],
            outputs: [.init(name: "output", nodeID: output.id, schema: .asset(.image))]
        )
        return graph
    }

    private static func themeImageMapBody(tool: WorkflowToolDefinition) throws -> WorkflowGraph {
        let fallback = theme(id: "theme-map", title: "可编辑主题", prompt: "A small creative studio")
        let input = try publicInput("item", schema: .record(themeFields), fallback: fallback, title: "当前主题")
        var invoke = try invocation(of: tool, title: "调用单主题图组工具")
        let nodes = [input, invoke]
        var graph = WorkflowGraph(
            name: "逐主题调用图像工具",
            nodes: nodes,
            connections: [connect(input, invoke, targetPort: "theme")],
            layout: gridLayout(nodes)
        )
        graph.interface = .init(
            inputs: [.init("item", .record(themeFields))],
            outputs: [.init(name: "output", nodeID: invoke.id, schema: imageGroupSchema)]
        )
        return graph
    }

    // MARK: - E03: humming to controlled music candidates

    private static func musicExample() throws -> WorkflowLanguageExampleBundle {
        let musicTool = try makeMusicCandidateTool()
        var source = try node("d.asset.reference", title: "导入或录音资产")
        source.assetReference = nil

        var convert = try node("d.audio.convert", title: "转换为 16k 单声道")
        convert.parameters["sampleRate"] = .integer(16_000)
        convert.parameters["channels"] = .integer(1)
        var trim = try node("d.audio.trim", title: "截取默认四秒")
        trim.parameters["whole"] = .flag(false)
        trim.parameters["startFrame"] = .integer(0)
        trim.parameters["endFrame"] = .integer(64_000)

        var pitch = try node("d.music.pitch", title: "SwiftF0 识别旋律")
        pitch.parameters["modelID"] = .text("")
        var editMelody = try node("d.control.human", title: "人工采用或编辑旋律")
        editMelody.parameters["kind"] = .text("editMusic")
        editMelody.parameters["instruction"] = .text("检查识别音符，明确提交采用版本。")
        editMelody.dataConfiguration = .init(schema: WorkflowNoteSequence.schema(clock: .seconds))

        var align = try node("d.music.align", title: "按固定速度对齐")
        align.parameters["bpm"] = .decimal(120)
        align.parameters["firstBeatSeconds"] = .decimal(0)
        align.parameters["numerator"] = .integer(4)
        align.parameters["denominator"] = .integer(4)
        align.parameters["snap"] = .text("eighth")
        let keys = try node("d.music.keys", title: "查看调性候选")

        let chordValue = try defaultChordTrack().datum()
        var chordInput = try valueInput("和弦草稿", value: chordValue)
        chordInput.title = "输入明确和弦"
        var proposeChords = try valueInput("和弦提案开关", value: .boolean(false))
        proposeChords.title = "可选语言模型和弦提案"
        let proposalFields: [WorkflowRecordField] = [
            .init("flag", .boolean),
            .init("chords", WorkflowChordTrack.schema),
        ]
        var proposalInput = try node("d.value.record", title: "组合和弦提案条件")
        proposalInput.dataConfiguration = .init(fields: proposalFields)
        var proposal = try node("d.control.branch", title: "按开关选择和弦来源")
        proposal.control = .branch(
            predicate: .init(path: ["flag"], comparison: .equals, value: .boolean(true)),
            then: try harmonyProposalBody(),
            otherwise: try passthroughGraph(
                name: "保留提供的和弦",
                inputName: "chords",
                schema: WorkflowChordTrack.schema,
                fallback: chordValue
            )
        )
        var editChords = try node("d.control.human", title: "人工编辑并采用和弦")
        editChords.parameters["kind"] = .text("editMusic")
        editChords.parameters["instruction"] = .text("明确检查和弦根音、性质、转位与时间。")
        editChords.dataConfiguration = .init(schema: WorkflowChordTrack.schema)

        var chordNotes = try node("d.music.chords", title: "和弦转成音符")
        chordNotes.parameters["pattern"] = .text("sustained")
        let preview = try node("d.music.render", title: "确定性合成试听")

        let styles = WorkflowDatum.list(element: .text, items: [
            .init(id: "candidate-1", value: .text("Solo piano, preserve the hummed melody.")),
            .init(id: "candidate-2", value: .text("Soft chamber texture, preserve melody and chords.")),
            .init(id: "candidate-3", value: .text("Warm electric piano, preserve melody and chords.")),
        ])
        var styleInput = try valueInput("三条候选意图", value: styles)
        styleInput.title = "输入三种可编辑风格"
        var optimizeStyle = try valueInput("风格优化开关", value: .boolean(false))
        optimizeStyle.title = "可选逐项风格文字优化"

        let sharedFields: [WorkflowRecordField] = [
            .init("notes", WorkflowNoteSequence.schema(clock: .quarterNotes)),
            .init("chords", WorkflowChordTrack.schema),
            .init("optimizeStyle", .boolean),
        ]
        var shared = try node("d.value.record", title: "共享真实音符与和弦")
        shared.dataConfiguration = .init(fields: sharedFields)

        var map = try node("d.control.map", title: "生成三条音乐候选")
        map.control = .map(body: try musicCandidateMapBody(tool: musicTool), continueOnFailure: true)
        let keyFields: [WorkflowRecordField] = [
            .init("root", .number(unit: nil)),
            .init("mode", .text),
            .init("score", .number(unit: nil)),
            .init("algorithm", .text),
        ]
        let deliveryFields: [WorkflowRecordField] = [
            .init("candidates", .list(.result(.asset(.audio)))),
            .init("keySuggestions", .list(.record(keyFields))),
            .init("referenceAudio", .asset(.audio)),
            .init("melody", WorkflowNoteSequence.schema(clock: .quarterNotes)),
            .init("chords", WorkflowChordTrack.schema),
        ]
        var delivery = try node("d.value.record", title: "组合候选、调性与试听版本")
        delivery.dataConfiguration = .init(fields: deliveryFields)
        var result = try node("d.value.return", title: "返回音乐候选")
        result.parameters["name"] = .text("musicCandidates")

        let nodes = [
            source, convert, trim, pitch, editMelody, align, keys, chordInput, proposeChords,
            proposalInput, proposal, editChords, chordNotes, preview, styleInput, optimizeStyle,
            shared, map, delivery, result,
        ]
        let graph = WorkflowGraph(
            name: "E03 哼唱和声与三候选",
            nodes: nodes,
            connections: [
                connect(source, convert),
                connect(convert, trim),
                connect(trim, pitch),
                connect(pitch, editMelody),
                connect(editMelody, align),
                connect(align, keys),
                connect(proposeChords, proposalInput, targetPort: "flag"),
                connect(chordInput, proposalInput, targetPort: "chords"),
                connect(proposalInput, proposal),
                connect(proposal, editChords),
                connect(editChords, chordNotes),
                connect(chordNotes, preview, sourcePort: "notes"),
                connect(align, shared, targetPort: "notes"),
                connect(editChords, shared, targetPort: "chords"),
                connect(optimizeStyle, shared, targetPort: "optimizeStyle"),
                connect(styleInput, map),
                connect(shared, map, targetPort: "shared"),
                connect(map, delivery, targetPort: "candidates"),
                connect(keys, delivery, targetPort: "keySuggestions"),
                connect(preview, delivery, targetPort: "referenceAudio"),
                connect(align, delivery, targetPort: "melody"),
                connect(editChords, delivery, targetPort: "chords"),
                connect(delivery, result),
            ],
            layout: gridLayout(nodes)
        )
        return .init(graph: graph, tools: [musicTool])
    }

    private static func makeMusicCandidateTool() throws -> WorkflowToolDefinition {
        let noteValue = try defaultNoteSequence(clock: .quarterNotes).datum()
        let chordValue = try defaultChordTrack().datum()
        let prompt = try publicInput("prompt", schema: .text, fallback: .text("Solo piano."), title: "候选意图")
        let notes = try publicInput(
            "notes", schema: WorkflowNoteSequence.schema(clock: .quarterNotes), fallback: noteValue, title: "旋律条件"
        )
        let chords = try publicInput("chords", schema: WorkflowChordTrack.schema, fallback: chordValue, title: "和弦条件")
        var generate = try node("d.music.generate", title: "MRT2 受控生成")
        generate.parameters["modelID"] = .text("")
        generate.parameters["durationFrames"] = .integer(100)
        var output = try node("d.value.return", title: "返回音乐资产")
        output.parameters["name"] = .text("output")
        let nodes = [prompt, notes, chords, generate, output]
        var graph = WorkflowGraph(
            name: "工具：真实音符和弦音乐生成",
            nodes: nodes,
            connections: [
                connect(prompt, generate, targetPort: "prompt"),
                connect(notes, generate, targetPort: "notes"),
                connect(chords, generate, targetPort: "chords"),
                connect(generate, output),
            ],
            layout: gridLayout(nodes)
        )
        graph.interface = .init(
            inputs: [
                .init("prompt", .text),
                .init("notes", WorkflowNoteSequence.schema(clock: .quarterNotes)),
                .init("chords", WorkflowChordTrack.schema),
            ],
            outputs: [.init(name: "output", nodeID: output.id, schema: .asset(.audio))]
        )
        return .init(name: "按真实音符和弦生成音乐", graph: graph)
    }

    private static func musicCandidateMapBody(tool: WorkflowToolDefinition) throws -> WorkflowGraph {
        let noteValue = try defaultNoteSequence(clock: .quarterNotes).datum()
        let chordValue = try defaultChordTrack().datum()
        let prompt = try publicInput("item", schema: .text, fallback: .text("Solo piano."), title: "当前风格")
        let notes = try publicInput(
            "notes", schema: WorkflowNoteSequence.schema(clock: .quarterNotes), fallback: noteValue, title: "共享旋律"
        )
        let chords = try publicInput("chords", schema: WorkflowChordTrack.schema, fallback: chordValue, title: "共享和弦")
        let optimizeStyle = try publicInput(
            "optimizeStyle", schema: .boolean, fallback: .boolean(false), title: "风格优化开关"
        )
        let styleFields: [WorkflowRecordField] = [
            .init("flag", .boolean),
            .init("style", .text),
        ]
        var styleInput = try node("d.value.record", title: "组合逐项风格优化条件")
        styleInput.dataConfiguration = .init(fields: styleFields)
        var style = try node("d.control.branch", title: "按开关优化当前风格文字")
        style.control = .branch(
            predicate: .init(path: ["flag"], comparison: .equals, value: .boolean(true)),
            then: try styleOptimizationBody(),
            otherwise: try passthroughGraph(
                name: "保留当前风格文字", inputName: "style", schema: .text, fallback: .text("Solo piano.")
            )
        )
        var invoke = try invocation(of: tool, title: "调用音乐候选工具")
        let nodes = [prompt, notes, chords, optimizeStyle, styleInput, style, invoke]
        var graph = WorkflowGraph(
            name: "逐风格生成音乐候选",
            nodes: nodes,
            connections: [
                connect(optimizeStyle, styleInput, targetPort: "flag"),
                connect(prompt, styleInput, targetPort: "style"),
                connect(styleInput, style),
                connect(style, invoke, targetPort: "prompt"),
                connect(notes, invoke, targetPort: "notes"),
                connect(chords, invoke, targetPort: "chords"),
            ],
            layout: gridLayout(nodes)
        )
        graph.interface = .init(
            inputs: [
                .init("item", .text),
                .init("notes", WorkflowNoteSequence.schema(clock: .quarterNotes)),
                .init("chords", WorkflowChordTrack.schema),
                .init("optimizeStyle", .boolean),
            ],
            outputs: [.init(name: "output", nodeID: invoke.id, schema: .asset(.audio))]
        )
        return graph
    }

    private static func harmonyProposalBody() throws -> WorkflowGraph {
        var language = try node("d.model.language", title: "可选和弦结构提案")
        language.parameters["task"] = .text(
            """
            提出一个8拍的和弦轨。只返回一个原始 JSON 对象，不要 Markdown、解释或额外字段。
            以下是完整格式示例，可以修改 chords 中的和弦，必须保留全部字段与类型：
            {"format":"d.music.chords","version":1,"duration":8,"chords":[{"id":"1","root":0,"quality":"major","octave":4,"inversion":0,"start":0,"end":4},{"id":"2","root":7,"quality":"dominant7","octave":3,"inversion":0,"start":4,"end":8}],"tempo":{"format":"d.music.tempo","version":1,"beatsPerMinute":120,"firstBeatSeconds":0,"numerator":4,"denominator":4},"sources":[]}
            duration/start/end 单位为四分音符拍。0 <= start < end <= 8。id 按数组顺序从字符串 "1" 开始。
            root 是0到11的整数音级（C=0），不能写音名；quality 只能是 major、minor、dominant7、major7、minor7、diminished。
            octave 取3或4，inversion 取0。tempo 固定120 BPM、首拍0秒、4/4，sources 必须为空数组。
            """
        )
        language.parameters["outputMode"] = .text("json")
        language.parameters["maximumOutputTokens"] = .integer(768)
        language.parameters["modelID"] = .text("")
        language.dataConfiguration = .init(schema: WorkflowChordTrack.schema)
        var graph = WorkflowGraph(
            name: "语言模型和弦提案",
            nodes: [language],
            layout: gridLayout([language])
        )
        graph.interface = .init(outputs: [
            .init(name: "output", nodeID: language.id, schema: WorkflowChordTrack.schema),
        ])
        return graph
    }

    private static func styleOptimizationBody() throws -> WorkflowGraph {
        let input = try publicInput(
            "style", schema: .text, fallback: .text("Solo piano."), title: "待优化风格文字"
        )
        var language = try node("d.model.language", title: "可选风格文字优化")
        language.parameters["task"] = .text(
            "只优化提供的音乐风格文字，返回纯文字；不要描述、修改或推断旋律、音符、和弦、时长。"
        )
        language.parameters["outputMode"] = .text("text")
        language.parameters["maximumOutputTokens"] = .integer(128)
        language.parameters["modelID"] = .text("")
        let nodes = [input, language]
        var graph = WorkflowGraph(
            name: "逐项风格文字优化",
            nodes: nodes,
            connections: [connect(input, language, targetPort: "content")],
            layout: gridLayout(nodes)
        )
        graph.interface = .init(
            inputs: [.init("style", .text)],
            outputs: [.init(name: "output", nodeID: language.id, schema: .text)]
        )
        return graph
    }

    // MARK: - E04: one published text, four model modalities

    private static func multimodalExample() throws -> WorkflowLanguageExampleBundle {
        var published = try node("d.text.input", title: "同一发布文字输入")
        published.parameters["text"] = .text("A lantern-lit garden where students exchange handmade books.")

        var themeID = try valueInput("主题身份", value: .text("theme-garden-books"))
        themeID.title = "输入主题身份"

        var language = try node("d.model.language", title: "文字分支")
        language.parameters["task"] = .text("Write a concise exhibition caption from the supplied theme.")
        language.parameters["outputMode"] = .text("text")
        language.parameters["modelID"] = .text("")

        var image = try node("d.image.generate", title: "图像分支")
        image.parameters["count"] = .integer(2)
        image.parameters["modelID"] = .text("")
        let candidateList = try node("d.value.candidates", title: "完整图像候选记录")

        var notes = try valueInput("受控音乐音符", value: try defaultNoteSequence(clock: .quarterNotes).datum())
        notes.title = "输入受控音符"
        var music = try node("d.music.generate", title: "受控音乐分支")
        music.parameters["modelID"] = .text("")
        music.parameters["durationFrames"] = .integer(100)

        var video = try node("d.video.generate", title: "纯文字视频分支")
        video.parameters["modelID"] = .text("")
        video.parameters["width"] = .integer(256)
        video.parameters["height"] = .integer(256)
        video.parameters["frameCount"] = .integer(17)
        video.parameters["steps"] = .integer(4)

        let resultFields: [WorkflowRecordField] = [
            .init("themeID", .text),
            .init("text", .asset(.text)),
            .init("imageCandidates", .list(.record(candidateFields))),
            .init("music", .asset(.audio)),
            .init("video", .asset(.video)),
        ]
        var record = try node("d.value.record", title: "组合四模态资产记录")
        record.dataConfiguration = .init(fields: resultFields)
        var result = try node("d.value.return", title: "返回四模态结果")
        result.parameters["name"] = .text("multimodal")

        let nodes = [published, themeID, language, image, candidateList, notes, music, video, record, result]
        let graph = WorkflowGraph(
            name: "E04 同主题四模态",
            nodes: nodes,
            connections: [
                connect(published, language, targetPort: "content"),
                connect(published, image, targetPort: "prompt"),
                connect(image, candidateList),
                connect(published, music, targetPort: "prompt"),
                connect(notes, music, targetPort: "notes"),
                connect(published, video, targetPort: "prompt"),
                connect(themeID, record, targetPort: "themeID"),
                connect(language, record, sourcePort: "raw", targetPort: "text"),
                connect(candidateList, record, targetPort: "imageCandidates"),
                connect(music, record, targetPort: "music"),
                connect(video, record, targetPort: "video"),
                connect(record, result),
            ],
            layout: gridLayout(nodes)
        )
        return .init(graph: graph)
    }

    // MARK: - Structured body helpers

    private static func passthroughGraph(
        name: String,
        inputName: String,
        schema: WorkflowDataSchema,
        fallback: WorkflowDatum
    ) throws -> WorkflowGraph {
        let input = try publicInput(inputName, schema: schema, fallback: fallback, title: name + "输入")
        var output = try node("d.value.return", title: name + "返回")
        output.parameters["name"] = .text("output")
        var graph = WorkflowGraph(
            name: name,
            nodes: [input, output],
            connections: [connect(input, output)],
            layout: gridLayout([input, output])
        )
        graph.interface = .init(
            inputs: [.init(inputName, schema)],
            outputs: [.init(name: "output", nodeID: output.id, schema: schema)]
        )
        return graph
    }

    private static func fallibleItemMapBody(
        schema: WorkflowDataSchema,
        fallback: WorkflowDatum
    ) throws -> WorkflowGraph {
        let input = try publicInput("item", schema: schema, fallback: fallback, title: "当前同构条目")
        var options = try node("d.value.field", title: "读取条目候选文字")
        options.dataConfiguration = .init(schema: .list(.text), path: ["options"])
        var first = try node("d.value.select", title: "明确取第一条候选文字")
        first.parameters["method"] = .text("index")
        first.parameters["index"] = .integer(1)
        var output = try node("d.value.return", title: "返回逐项文字")
        output.parameters["name"] = .text("output")
        let nodes = [input, options, first, output]
        var graph = WorkflowGraph(
            name: "逐项读取可编辑候选",
            nodes: nodes,
            connections: [connect(input, options), connect(options, first), connect(first, output)],
            layout: gridLayout(nodes)
        )
        graph.interface = .init(
            inputs: [.init("item", schema)],
            outputs: [.init(name: "output", nodeID: output.id, schema: .text)]
        )
        return graph
    }

    private static func incrementingLoopBody() throws -> WorkflowGraph {
        let state = try publicInput(
            "state", schema: .number(unit: nil), fallback: .number(0, unit: nil), title: "当前状态"
        )
        let iteration = try publicInput(
            "iteration", schema: .number(unit: nil), fallback: .number(1, unit: nil), title: "本轮编号"
        )
        var output = try node("d.value.return", title: "将轮次作为下一状态")
        output.parameters["name"] = .text("state")
        let nodes = [state, iteration, output]
        var graph = WorkflowGraph(
            name: "状态随轮次递增",
            nodes: nodes,
            connections: [connect(iteration, output)],
            layout: gridLayout(nodes)
        )
        graph.interface = .init(
            inputs: [
                .init("state", .number(unit: nil)),
                .init("iteration", .number(unit: nil)),
            ],
            outputs: [.init(name: "state", nodeID: output.id, schema: .number(unit: nil))]
        )
        return graph
    }

    // MARK: - Values and schemas

    private static let dataItemFields: [WorkflowRecordField] = [
        .init("index", .number(unit: nil)),
        .init("title", .text),
        .init("score", .number(unit: nil)),
        .init("keep", .boolean),
        .init("options", .list(.text)),
    ]

    private static let dataTagFields: [WorkflowRecordField] = [
        .init("index", .number(unit: nil)),
        .init("category", .text),
    ]

    private static let themeFields: [WorkflowRecordField] = [
        .init("themeID", .text),
        .init("title", .text),
        .init("prompt", .text),
    ]

    private static let candidateFields: [WorkflowRecordField] = [
        .init("id", .text),
        .init("attemptID", .text),
        .init("seed", .text),
        .init("status", .enumeration(["success", "failed"])),
        .init("asset", .optional(.asset(.image))),
        .init("error", .optional(.text)),
    ]

    private static var imageGroupSchema: WorkflowDataSchema {
        .record([
            .init("themeID", .text),
            .init("candidates", .list(.record(candidateFields))),
            .init("processed", .list(.result(.asset(.image)))),
        ])
    }

    private static func validationReportSchema(for expected: WorkflowDataSchema) -> WorkflowDataSchema {
        .record([
            .init("valid", .boolean),
            .init("data", .optional(expected)),
            .init("issues", .list(.text)),
        ])
    }

    private static func dataItem(
        id: Int,
        title: String,
        score: Double,
        keep: Bool,
        options: [String]
    ) -> WorkflowDatum {
        .record(schema: dataItemFields, fields: [
            "index": .number(Double(id), unit: nil),
            "title": .text(title),
            "score": .number(score, unit: nil),
            "keep": .boolean(keep),
            "options": textList(options),
        ])
    }

    private static func textList(_ values: [String]) -> WorkflowDatum {
        .list(element: .text, items: values.enumerated().map {
            .init(id: "text-\($0.offset + 1)", value: .text($0.element))
        })
    }

    private static func dataTag(id: Int, category: String) -> WorkflowDatum {
        .record(schema: dataTagFields, fields: [
            "index": .number(Double(id), unit: nil),
            "category": .text(category),
        ])
    }

    private static func theme(id: String, title: String, prompt: String) -> WorkflowDatum {
        .record(schema: themeFields, fields: [
            "themeID": .text(id), "title": .text(title), "prompt": .text(prompt),
        ])
    }

    private static func defaultNoteSequence(clock: WorkflowMusicClock) -> WorkflowNoteSequence {
        let tempo = WorkflowTempoMap(beatsPerMinute: 120, firstBeatSeconds: 0, numerator: 4, denominator: 4)
        if clock == .seconds {
            return .init(clock: .seconds, notes: [
                .init(id: "note-1", pitch: 60, start: 0, end: 1, velocity: 0.8),
                .init(id: "note-2", pitch: 64, start: 1, end: 2, velocity: 0.8),
                .init(id: "note-3", pitch: 67, start: 2, end: 4, velocity: 0.8),
            ], duration: 4)
        }
        return .init(clock: .quarterNotes, notes: [
            .init(id: "note-1", pitch: 60, start: 0, end: 2, velocity: 0.8),
            .init(id: "note-2", pitch: 64, start: 2, end: 4, velocity: 0.8),
            .init(id: "note-3", pitch: 67, start: 4, end: 8, velocity: 0.8),
        ], duration: 8, tempo: tempo)
    }

    private static func defaultChordTrack() -> WorkflowChordTrack {
        let tempo = WorkflowTempoMap(beatsPerMinute: 120, firstBeatSeconds: 0, numerator: 4, denominator: 4)
        return .init(chords: [
            .init(id: "C", root: 0, quality: .major, octave: 4, inversion: 0, start: 0, end: 2),
            .init(id: "Am", root: 9, quality: .minor, octave: 3, inversion: 0, start: 2, end: 4),
            .init(id: "F", root: 5, quality: .major, octave: 3, inversion: 0, start: 4, end: 6),
            .init(id: "G", root: 7, quality: .major, octave: 3, inversion: 0, start: 6, end: 8),
        ], duration: 8, tempo: tempo)
    }

    // MARK: - Graph construction

    private static func node(_ operationID: String, title: String) throws -> WorkflowNode {
        guard let operation = WorkflowRegistry.standard.operation(operationID) else {
            throw WorkflowIssue("样例需要未注册操作：\(operationID)。")
        }
        var result = operation.definition.makeNode()
        result.title = title
        return result
    }

    private static func valueInput(_ title: String, value: WorkflowDatum) throws -> WorkflowNode {
        var result = try node("d.value.input", title: title)
        result.dataConfiguration = .init(value: value)
        return result
    }

    private static func publicInput(
        _ name: String,
        schema: WorkflowDataSchema,
        fallback: WorkflowDatum,
        title: String
    ) throws -> WorkflowNode {
        try fallback.validate(as: schema)
        var result = try valueInput(title, value: fallback)
        result.parameters["publicName"] = .text(name)
        return result
    }

    /// Required structured-control arguments do not need fake asset defaults.
    /// The executor injects the declared argument before this input executes.
    private static func requiredPublicInput(
        _ name: String,
        schema: WorkflowDataSchema,
        title: String
    ) throws -> WorkflowNode {
        try schema.validateDefinition()
        var result = try node("d.value.input", title: title)
        result.parameters["publicName"] = .text(name)
        result.dataConfiguration = .init(schema: schema)
        return result
    }

    private static func invocation(of tool: WorkflowToolDefinition, title: String) throws -> WorkflowNode {
        var result = try node("d.control.invoke", title: title)
        result.control = .invoke(.init(
            id: tool.id,
            version: tool.version,
            digest: try WorkflowPlanCompiler.digest(tool)
        ))
        result.dataConfiguration = .init(fields: tool.graph.interface?.inputs ?? [])
        return result
    }

    private static func connect(
        _ source: WorkflowNode,
        _ target: WorkflowNode,
        sourcePort: String = "output",
        targetPort: String = "input"
    ) -> WorkflowConnection {
        .init(sourceNode: source.id, sourcePort: sourcePort, targetNode: target.id, targetPort: targetPort)
    }

    private static func gridLayout(_ nodes: [WorkflowNode]) -> [WorkflowLayout] {
        nodes.enumerated().map { offset, node in
            WorkflowLayout(nodeID: node.id, x: Double(offset % 5) * 280, y: Double(offset / 5) * 180)
        }
    }
}
