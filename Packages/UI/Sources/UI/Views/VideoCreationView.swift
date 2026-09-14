import DInference
import DWorkbench
import Foundation
import SwiftUI

public enum VideoCreationPresentation { case complete, content, parameters }

public struct VideoCreationView: View {
    @Binding private var draft: VideoCreationDraft
    private let candidates: [ProjectAsset]
    private let selectedAssetID: UUID?
    private let adoptedAssetID: UUID?
    private let modelStatus: String
    private let canGenerate: Bool
    private let isBusy: Bool
    private let progress: Double?
    private let status: String?
    private let previewURL: URL?
    private let previewIdentity: UUID
    private let defaultMemoryBudgetBytes: UInt64
    private let actions: VideoCreationActions
    private var presentation: VideoCreationPresentation = .complete
    private var layoutProbe: ((String, CGRect) -> Void)?

    public init(draft: Binding<VideoCreationDraft>, candidates: [ProjectAsset], selectedAssetID: UUID?,
                adoptedAssetID: UUID?, modelStatus: String, canGenerate: Bool, isBusy: Bool,
                progress: Double?, status: String?, previewURL: URL?, previewIdentity: UUID,
                defaultMemoryBudgetBytes: UInt64, actions: VideoCreationActions) {
        _draft = draft
        self.candidates = candidates
        self.selectedAssetID = selectedAssetID
        self.adoptedAssetID = adoptedAssetID
        self.modelStatus = modelStatus
        self.canGenerate = canGenerate
        self.isBusy = isBusy
        self.progress = progress
        self.status = status
        self.previewURL = previewURL
        self.previewIdentity = previewIdentity
        self.defaultMemoryBudgetBytes = defaultMemoryBudgetBytes
        self.actions = actions
    }

    public func presenting(_ presentation: VideoCreationPresentation) -> Self {
        var copy = self
        copy.presentation = presentation
        return copy
    }

    func observingLayout(_ observer: @escaping (String, CGRect) -> Void) -> Self {
        var copy = self
        copy.layoutProbe = observer
        return copy
    }

    public var body: some View {
        GeometryReader { viewport in
            ScrollView {
                let layout = viewport.size.width >= 720
                    ? AnyLayout(HStackLayout(alignment: .top, spacing: 16))
                    : AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
                VStack(alignment: .leading, spacing: 16) {
                    if presentation != .content { header }
                    if presentation == .parameters {
                        controls
                    } else if presentation == .content {
                        previewAndCandidates
                    } else {
                        layout { controls; previewAndCandidates }
                    }
                    if presentation != .content { statusArea }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
        }
        .coordinateSpace(name: "video-workbench-layout")
        .onChange(of: isBusy) { _, busy in
            if busy && presentation != .parameters { actions.stop() }
        }
        .onDisappear {
            if presentation != .parameters { actions.stop() }
        }
        .accessibilityIdentifier("video-create-view")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("视频创作").font(.title2.weight(.semibold))
            Text("生成候选不会自动采用；预览、采用、拒绝和导出都需要明确操作。")
                .font(.caption).foregroundStyle(.secondary)
            Text(modelStatus).font(.caption).foregroundStyle(.secondary)
            Button("选择模型…", action: actions.chooseModel).disabled(isBusy)
                .accessibilityIdentifier("video-create-choose-model")
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("当前视频能力").font(.subheadline.weight(.semibold))
            Text("Wan2.1 T2V-1.3B：宽高为 16 的倍数，帧数为 4n+1，步数 1…1000；T5/DiT BF16（保留原 FP32 张量），VAE FP32。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("描述想要的视频", text: $draft.prompt, axis: .vertical)
                .lineLimit(3...6).textFieldStyle(.roundedBorder).disabled(isBusy)
                .accessibilityIdentifier("video-create-prompt")
            TextField("负面提示（可选）", text: $draft.negativePrompt, axis: .vertical)
                .lineLimit(2...4).textFieldStyle(.roundedBorder).disabled(isBusy)
                .accessibilityIdentifier("video-create-negative-prompt")
            parameterFields
            Text("当前样本为 832×480、17 帧、16 fps、50 步；实际范围由已部署适配器核验，长序列估计未校准。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(memoryHint).font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("video-create-memory-hint")
            actionRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("video-workbench-layout")) } action: {
            layoutProbe?("video-create-controls", $0)
        }
    }

    private var parameterFields: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            parameterRow("宽", text: $draft.widthText, id: "width")
            parameterRow("高", text: $draft.heightText, id: "height")
            parameterRow("帧数", text: $draft.framesText, id: "frames")
            parameterRow("帧率分子", text: $draft.fpsNumeratorText, id: "fps-numerator")
            parameterRow("帧率分母", text: $draft.fpsDenominatorText, id: "fps-denominator")
            parameterRow("步数", text: $draft.stepsText, id: "steps")
            parameterRow("Guidance", text: $draft.guidanceText, id: "guidance")
            parameterRow("Shift", text: $draft.shiftText, id: "shift")
            parameterRow("Seed", text: $draft.seedText, id: "seed")
            parameterRow("内存预算（MiB，留空自动）", text: $draft.memoryBudgetMiBText, id: "memory-budget")
        }
    }

    private func parameterRow(_ title: String, text: Binding<String>, id: String) -> some View {
        GridRow {
            Text(title)
            TextField(title, text: text).textFieldStyle(.roundedBorder).disabled(isBusy)
                .accessibilityIdentifier("video-create-\(id)")
        }
    }

    private var actionRow: some View {
        HStack {
            if isBusy {
                Button("取消", role: .destructive, action: actions.cancel)
                    .accessibilityIdentifier("video-create-cancel")
            } else {
                Button("生成") {
                    _ = VideoCreationButtonHandler.submit(draft, hostAllowsGeneration: canGenerate,
                                                          isBusy: isBusy, actions: actions)
                }
                .buttonStyle(.glass).disabled(!canSubmit)
                .accessibilityIdentifier("video-create-generate")
            }
            Button("保存", action: actions.save).disabled(isBusy)
                .accessibilityIdentifier("video-create-save")
        }
    }

    private var previewAndCandidates: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("预览").font(.headline)
            VideoPreview(url: isBusy ? nil : previewURL, identity: previewIdentity)
                .frame(minHeight: 220).clipShape(RoundedRectangle(cornerRadius: 12))
                .accessibilityIdentifier("video-create-preview")
            Divider()
            Text("候选").font(.headline)
            if candidates.isEmpty { Text("还没有候选。可以先填写提示词创建。").font(.caption).foregroundStyle(.secondary) }
            ForEach(candidates) { candidateRow($0) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
    }

    private func candidateRow(_ asset: ProjectAsset) -> some View {
        let rejected = draft.rejectedAssetIDs.contains(asset.id)
        return VStack(alignment: .leading, spacing: 6) {
            Button { _ = VideoCreationButtonHandler.select(asset.id, isBusy: isBusy, actions: actions) } label: {
                Text(asset.name).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(isBusy).accessibilityIdentifier("video-create-select-\(asset.id.uuidString)")
            HStack {
                if selectedAssetID == asset.id { Text("已选择").font(.caption) }
                if adoptedAssetID == asset.id { Text("已采用").font(.caption) }
                if rejected { Text("已拒绝").font(.caption).foregroundStyle(.secondary) }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 86), spacing: 8)], alignment: .leading, spacing: 8) {
                Button("预览") { _ = VideoCreationButtonHandler.preview(asset.id, isBusy: isBusy, actions: actions) }
                    .disabled(isBusy).accessibilityIdentifier("video-create-preview-\(asset.id.uuidString)")
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("video-workbench-layout")) } action: {
                        layoutProbe?("video-create-preview-\(asset.id.uuidString)", $0)
                    }
                Button("采用") { _ = VideoCreationButtonHandler.adopt(asset.id, isRejected: rejected, isBusy: isBusy, actions: actions) }
                    .disabled(isBusy || rejected).accessibilityIdentifier("video-create-adopt-\(asset.id.uuidString)")
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("video-workbench-layout")) } action: {
                        layoutProbe?("video-create-adopt-\(asset.id.uuidString)", $0)
                    }
                Button(rejected ? "恢复" : "拒绝") { _ = VideoCreationButtonHandler.setRejected(asset.id, currentlyRejected: rejected, isBusy: isBusy, actions: actions) }
                    .disabled(isBusy).accessibilityIdentifier("video-create-reject-\(asset.id.uuidString)")
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("video-workbench-layout")) } action: {
                        layoutProbe?("video-create-reject-\(asset.id.uuidString)", $0)
                    }
                Button("导出") { _ = VideoCreationButtonHandler.export(asset.id, isBusy: isBusy, actions: actions) }
                    .disabled(isBusy).accessibilityIdentifier("video-create-export-\(asset.id.uuidString)")
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("video-workbench-layout")) } action: {
                        layoutProbe?("video-create-export-\(asset.id.uuidString)", $0)
                    }
            }
            if rejected { Text("拒绝不会删除原件或候选。").font(.caption).foregroundStyle(.secondary) }
        }
        .accessibilityIdentifier("video-create-candidate-\(asset.id.uuidString)")
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("video-workbench-layout")) } action: {
            layoutProbe?("video-create-candidate-\(asset.id.uuidString)", $0)
        }
    }

    private var canSubmit: Bool { !isBusy && canGenerate && VideoCreationButtonHandler.isValid(draft) }
    private var memoryHint: String {
        let historical = "历史样本：M4/16 GiB 上 832×480、17 帧、16 fps、50 步、Seed 42 的 MLX 运行约 28 分钟、峰值 18.294 GiB；非 ETA、非 RSS 保证，其他硬件与配置未实测。"
        let selected: UInt64
        do {
            selected = try draft.selectedMemoryBudgetBytes() ?? defaultMemoryBudgetBytes
        } catch {
            return "内存预算“\(draft.memoryBudgetMiBText)”无效，不能提交；原始输入已保留。\n\(historical)"
        }
        guard let request = try? draft.makeRequest(),
              let estimate = try? VideoExecutionCapability.wan21.estimatedPeakBytes(for: request) else {
            return "参数未通过已部署适配器核验；不能计算内存估计，输入保持不变。\n\(historical)"
        }
        let selectedMiB = selected / 1_048_576
        let estimateMiB = estimate / 1_048_576
        let source = draft.memoryBudgetMiBText.isEmpty ? "自动" : "显式"
        let risk = selected < estimate ? "所选预算低于估计，可能无法准入或运行失败；主机仍会最终核验。" : "估计不等于实际占用，主机仍会最终核验。"
        return "内存估计约 \(estimateMiB) MiB；\(source)预算 \(selectedMiB) MiB。\(risk)\n\(historical)"
    }
    private var statusArea: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let progress { ProgressView(value: progress).accessibilityIdentifier("video-create-progress") }
            if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
            if !isBusy { Text(VideoCreationButtonHandler.submissionMessage(draft, hostAllowsGeneration: canGenerate))
                .font(.caption).foregroundStyle(canSubmit ? Color.secondary : Color.orange)
                .accessibilityIdentifier("video-create-status") }
        }
    }
}
