import DInference
import DWorkbench
import SwiftUI

public struct AudioCreationView: View {
    @Binding private var draft: AudioCreationDraft
    private let source: ProjectAsset?
    private let candidates: [ProjectAsset]
    private let selectedAssetID: UUID?
    private let adoptedAssetID: UUID?
    private let modelStatus: String
    private let canGenerate: Bool
    private let isBusy: Bool
    private let progress: Double?
    private let status: String?
    @Bindable private var transport: AudioTransport
    private let actions: AudioCreationActions
    @State private var rangeStartText = ""
    @State private var rangeEndText = ""
    @State private var rangeInputMessage: String?
    private var layoutProbe: ((String, CGRect) -> Void)?

    public init(draft: Binding<AudioCreationDraft>, source: ProjectAsset?, candidates: [ProjectAsset],
                selectedAssetID: UUID?, adoptedAssetID: UUID?, modelStatus: String,
                canGenerate: Bool, isBusy: Bool, progress: Double?, status: String?,
                transport: AudioTransport, actions: AudioCreationActions) {
        _draft = draft
        self.source = source
        self.candidates = candidates
        self.selectedAssetID = selectedAssetID
        self.adoptedAssetID = adoptedAssetID
        self.modelStatus = modelStatus
        self.canGenerate = canGenerate
        self.isBusy = isBusy
        self.progress = progress
        self.status = status
        self.transport = transport
        self.actions = actions
    }

    public var body: some View {
        GeometryReader { viewport in
            ScrollView {
                let layout = viewport.size.width >= 720
                    ? AnyLayout(HStackLayout(alignment: .top, spacing: 16))
                    : AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
                VStack(alignment: .leading, spacing: 16) {
                    header
                    layout {
                        controls.frame(maxWidth: .infinity, alignment: .topLeading)
                        sourceAndCandidates.frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    statusArea
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
        }
        .onAppear(perform: loadRangeText)
        .onChange(of: source?.id) { _, _ in
            rangeInputMessage = nil
            loadRangeText()
        }
        .onChange(of: draft.editRegion) { _, _ in loadRangeText() }
        .onChange(of: rangeStartText) { _, _ in assessRangeInput() }
        .onChange(of: rangeEndText) { _, _ in assessRangeInput() }
        .coordinateSpace(name: "audio-workbench-layout")
        .accessibilityIdentifier("audio-create-view")
    }

    func observingLayout(_ observer: @escaping (String, CGRect) -> Void) -> Self {
        var copy = self
        copy.layoutProbe = observer
        return copy
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("音频创作").font(.title2.weight(.semibold))
            Text("提示或参考音频可生成候选；采用、拒绝和保存都需要明确操作。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(modelStatus).font(.caption).foregroundStyle(.secondary)
                Button("选择模型…", action: actions.chooseModel).disabled(isBusy)
                    .accessibilityIdentifier("audio-create-choose-model")
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("描述想要的声音", text: $draft.prompt, axis: .vertical)
                .lineLimit(3...6).textFieldStyle(.roundedBorder)
                .disabled(isBusy).accessibilityIdentifier("audio-create-prompt")
            Picker("操作", selection: $draft.operation) {
                Text("新建").tag(AudioOperation.generate)
                Text("参考变体").tag(AudioOperation.variation).disabled(source == nil)
                Text("区间重绘").tag(AudioOperation.inpaint).disabled(source == nil)
            }
            .pickerStyle(.segmented).disabled(isBusy)
            .accessibilityIdentifier("audio-create-operation")
            parameterFields
            if draft.operation == .inpaint { rangeEditor }
            actionRow
        }
        .padding(16)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
    }

    private var parameterFields: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            parameterRow("时长（秒）", text: $draft.durationText, id: "duration", disabled: isBusy || sourceOperation)
            parameterRow("Seed", text: $draft.seedText, id: "seed", disabled: isBusy)
            parameterRow("步数", text: $draft.stepsText, id: "steps", disabled: isBusy)
            parameterRow("Guidance", text: $draft.guidanceText, id: "guidance", disabled: isBusy)
            if draft.operation == .generate {
                GridRow { Text("强度"); Text("1（新建固定）") }
            } else {
                parameterRow("强度", text: $draft.strengthText, id: "strength", disabled: isBusy)
            }
            if sourceOperation, let sourceDuration {
                GridRow { Text("来源时长"); Text(sourceDuration).monospacedDigit() }
            }
        }
    }

    private func parameterRow(_ title: String, text: Binding<String>, id: String, disabled: Bool) -> some View {
        GridRow {
            Text(title)
            TextField(title, text: text).textFieldStyle(.roundedBorder).disabled(disabled)
                .accessibilityIdentifier("audio-create-\(id)")
        }
    }

    private var rangeEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("重绘区间（秒，含开始不含结束）").font(.headline)
            HStack {
                TextField("开始", text: $rangeStartText).textFieldStyle(.roundedBorder).disabled(isBusy)
                    .accessibilityIdentifier("audio-create-range-start")
                TextField("结束", text: $rangeEndText).textFieldStyle(.roundedBorder).disabled(isBusy)
                    .accessibilityIdentifier("audio-create-range-end")
                Button("应用区间", action: applyRange)
                    .disabled(isBusy).accessibilityIdentifier("audio-create-range-apply")
            }
            Text(rangeInputMessage ?? rangeMessage).font(.caption)
                .foregroundStyle(rangeInputMessage == nil ? .secondary : .orange)
        }
    }

    private var actionRow: some View {
        HStack {
            if isBusy {
                Button("取消", role: .destructive, action: actions.cancel)
                    .accessibilityIdentifier("audio-create-cancel")
            } else {
                Button("生成") {
                    _ = AudioCreationButtonHandler.submit(draft, source: source,
                                                          hostAllowsGeneration: canGenerate,
                                                          actions: actions)
                }
                    .buttonStyle(.glass)
                    .disabled(!canSubmit)
                    .accessibilityIdentifier("audio-create-generate")
            }
            Button("保存", action: actions.save).disabled(isBusy)
                .accessibilityIdentifier("audio-create-save")
        }
    }

    private var sourceAndCandidates: some View {
        VStack(alignment: .leading, spacing: 12) {
            sourceInfo
            Divider()
            Text("候选").font(.headline)
            if candidates.isEmpty {
                Text("还没有候选。可以先填写提示词创建。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(candidates) { asset in candidateRow(asset) }
        }
        .padding(16)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder private var sourceInfo: some View {
        if let source {
            Text("参考原声：\(source.name)").lineLimit(nil)
            Text(sourceDuration ?? "原声时长未知").font(.caption).foregroundStyle(.secondary)
            if !AudioCreationButtonHandler.sourceIsEditable(source) {
                Text("此来源不是当前模型可编辑的 44.1 kHz 双声道 WAV；仍可保留、试听和导出。")
                    .font(.caption).foregroundStyle(.orange)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 86), spacing: 8)], alignment: .leading, spacing: 8) {
                Button("试听") { _ = AudioCreationButtonHandler.play(source.id, isBusy: isBusy, actions: actions) }.disabled(isBusy)
                    .accessibilityIdentifier("audio-create-source-play")
                Button("停止", action: actions.stop)
                    .accessibilityIdentifier("audio-create-stop")
                Button("导出") { _ = AudioCreationButtonHandler.export(source.id, isBusy: isBusy, actions: actions) }.disabled(isBusy)
                    .accessibilityIdentifier("audio-create-source-export")
                Button("回到原声") {
                    _ = AudioCreationButtonHandler.adopt(nil, isRejected: false, isBusy: isBusy, actions: actions)
                }.disabled(isBusy).accessibilityIdentifier("audio-create-adopt-original")
            }
        } else {
            Text("没有参考原声；可以直接从提示词生成。参考变体和区间重绘需要原声。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func candidateRow(_ asset: ProjectAsset) -> some View {
        let rejected = draft.rejectedAssetIDs.contains(asset.id)
        return VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 3) {
                Button {
                    _ = AudioCreationButtonHandler.select(asset.id, isBusy: isBusy, actions: actions)
                } label: {
                    Text(asset.name).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.disabled(isBusy)
                    .accessibilityIdentifier("audio-create-select-\(asset.id.uuidString)")
                HStack {
                    if selectedAssetID == asset.id { Text("已选择").font(.caption) }
                    if adoptedAssetID == asset.id { Text("已采用").font(.caption) }
                    if rejected { Text("已拒绝").font(.caption).foregroundStyle(.secondary) }
                }
            }
            Text(assetDuration(asset) ?? "时长未知").font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 86), spacing: 8)], alignment: .leading, spacing: 8) {
                Button("试听") { _ = AudioCreationButtonHandler.play(asset.id, isBusy: isBusy, actions: actions) }.disabled(isBusy)
                    .accessibilityIdentifier("audio-create-play-\(asset.id.uuidString)")
                    .audioMeasured("audio-create-play-\(asset.id.uuidString)", probe: layoutProbe)
                Button("采用") {
                    _ = AudioCreationButtonHandler.adopt(asset.id, isRejected: rejected, isBusy: isBusy, actions: actions)
                }.disabled(isBusy || rejected)
                    .accessibilityIdentifier("audio-create-adopt-\(asset.id.uuidString)")
                    .audioMeasured("audio-create-adopt-\(asset.id.uuidString)", probe: layoutProbe)
                Button(rejected ? "恢复" : "拒绝") {
                    _ = AudioCreationButtonHandler.setRejected(asset.id, currentlyRejected: rejected, isBusy: isBusy, actions: actions)
                }.disabled(isBusy)
                    .accessibilityIdentifier("audio-create-reject-\(asset.id.uuidString)")
                    .audioMeasured("audio-create-reject-\(asset.id.uuidString)", probe: layoutProbe)
                Button("导出") { _ = AudioCreationButtonHandler.export(asset.id, isBusy: isBusy, actions: actions) }.disabled(isBusy)
                    .accessibilityIdentifier("audio-create-export-\(asset.id.uuidString)")
                    .audioMeasured("audio-create-export-\(asset.id.uuidString)", probe: layoutProbe)
                Button("基于此新建") { actions.createFrom(asset.id) }.disabled(isBusy)
                    .accessibilityIdentifier("audio-create-from-\(asset.id.uuidString)")
                    .audioMeasured("audio-create-from-\(asset.id.uuidString)", probe: layoutProbe)
            }
            if rejected { Text("拒绝不会删除原件或候选。").font(.caption).foregroundStyle(.secondary) }
        }
        .audioMeasured("audio-create-candidate-\(asset.id.uuidString)", probe: layoutProbe)
        .accessibilityIdentifier("audio-create-candidate-\(asset.id.uuidString)")
    }

    private var statusArea: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let progress { ProgressView(value: progress).accessibilityIdentifier("audio-create-progress") }
            Text(status ?? validationMessage).font(.caption)
                .foregroundStyle(status == nil && !canSubmit ? .orange : .secondary)
                .accessibilityIdentifier("audio-create-status")
        }
    }

    private var sourceOperation: Bool { draft.operation != .generate }
    private var canSubmit: Bool {
        canGenerate && rangeInputMessage == nil && AudioCreationButtonHandler.canGenerate(draft, source: source)
    }
    private var validationMessage: String {
        if draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请输入提示词。" }
        if !AudioCreationButtonHandler.numericInputsAreValid(draft) { return "参数不受当前模型支持；输入保持不变。" }
        if sourceOperation && source == nil { return "参考变体和区间重绘需要原声。" }
        if sourceOperation && !AudioCreationButtonHandler.sourceIsEditable(source) { return "当前来源不能由该模型编辑。" }
        if draft.operation == .inpaint && !AudioCreationButtonHandler.canGenerate(draft, source: source) { return "区间必须在原声内且结束大于开始。" }
        return "准备就绪。"
    }
    private var sourceDuration: String? { source.flatMap(assetDuration) }
    private func assetDuration(_ asset: ProjectAsset) -> String? {
        guard let format = asset.metadata.audio?.format, format.sampleRate > 0 else { return nil }
        return String(format: "%.2f 秒", Double(format.frameCount) / format.sampleRate)
    }
    private var rangeMessage: String {
        guard let format = source?.metadata.audio?.format else { return "需要原声才能设置区间。" }
        return "44.1 kHz 帧边界；有效范围为 0–\(format.frameCount)。"
    }
    private func loadRangeText() {
        guard let range = draft.editRegion, let format = source?.metadata.audio?.format, format.sampleRate > 0 else { return }
        rangeStartText = String(Double(range.startFrame) / format.sampleRate)
        rangeEndText = String(Double(range.endFrame) / format.sampleRate)
    }
    private func applyRange() {
        guard let format = source?.metadata.audio?.format,
              let candidate = AudioCreationButtonHandler.frameRange(startText: rangeStartText,
                                                                       endText: rangeEndText, format: format) else {
            rangeInputMessage = "区间无效；没有改动已保存的范围。"
            return
        }
        draft.editRegion = candidate
        rangeInputMessage = nil
    }

    private func assessRangeInput() {
        guard draft.operation == .inpaint else { return }
        guard let format = source?.metadata.audio?.format,
              let candidate = AudioCreationButtonHandler.frameRange(startText: rangeStartText,
                                                                       endText: rangeEndText, format: format) else {
            rangeInputMessage = "区间无效；没有改动已保存的范围。"
            return
        }
        rangeInputMessage = candidate == draft.editRegion ? nil : "请应用区间后再生成。"
    }
}
