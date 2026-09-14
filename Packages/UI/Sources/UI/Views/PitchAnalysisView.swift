import DInference
import DWorkbench
import SwiftUI

/// The presentation deliberately distinguishes a valid no-pitch result from invalid data.
enum PitchAnalysisViewResultState: Equatable {
    case absent
    case valid(PitchInterpretation)
    case invalid
}

/// The permitted callback routes for the stateless pitch-analysis presentation.
/// Keeping these rules separate makes the view's action gating independently testable.
enum PitchAnalysisViewActionGate {
    static func resultState(result: PitchAnalysisResult?) -> PitchAnalysisViewResultState {
        guard let result else { return .absent }
        do {
            return .valid(try PitchInterpretation(result: result))
        } catch {
            return .invalid
        }
    }

    static func canAnalyze(result: PitchAnalysisResult?, isBusy: Bool, hasSaved: Bool, canAnalyze: Bool) -> Bool {
        !isBusy && canAnalyze && (result == nil || hasSaved)
    }

    static func canCancel(isBusy: Bool) -> Bool {
        isBusy
    }

    static func canSave(result: PitchAnalysisResult?, isBusy: Bool, isStale: Bool, hasSaved: Bool) -> Bool {
        !isBusy && Self.resultState(result: result).isValid && !isStale && !hasSaved
    }

    static func canReject(result: PitchAnalysisResult?, isBusy: Bool, hasSaved: Bool) -> Bool {
        !isBusy && result != nil && !hasSaved
    }

    static func canExport(result: PitchAnalysisResult?, isBusy: Bool) -> Bool {
        !isBusy && Self.resultState(result: result).isValid
    }

    @discardableResult
    static func analyze(result: PitchAnalysisResult?, isBusy: Bool, hasSaved: Bool, canAnalyze: Bool,
                        action: () -> Void) -> Bool {
        guard Self.canAnalyze(result: result, isBusy: isBusy, hasSaved: hasSaved, canAnalyze: canAnalyze) else { return false }
        action()
        return true
    }

    @discardableResult
    static func cancel(isBusy: Bool, action: () -> Void) -> Bool {
        guard Self.canCancel(isBusy: isBusy) else { return false }
        action()
        return true
    }

    @discardableResult
    static func save(result: PitchAnalysisResult?, isBusy: Bool, isStale: Bool, hasSaved: Bool,
                     action: () -> Void) -> Bool {
        guard Self.canSave(result: result, isBusy: isBusy, isStale: isStale, hasSaved: hasSaved) else { return false }
        action()
        return true
    }

    @discardableResult
    static func reject(result: PitchAnalysisResult?, isBusy: Bool, hasSaved: Bool, action: () -> Void) -> Bool {
        guard Self.canReject(result: result, isBusy: isBusy, hasSaved: hasSaved) else { return false }
        action()
        return true
    }

    @discardableResult
    static func export(result: PitchAnalysisResult?, isBusy: Bool, action: () -> Void) -> Bool {
        guard Self.canExport(result: result, isBusy: isBusy) else { return false }
        action()
        return true
    }
}

private extension PitchAnalysisViewResultState {
    var isValid: Bool {
        if case .valid = self { return true }
        return false
    }
}

public struct PitchAnalysisView: View {
    private let result: PitchAnalysisResult?
    private let isBusy: Bool
    private let isStale: Bool
    private let status: String?
    private let hasSaved: Bool
    private let canAnalyze: Bool
    private let onAnalyze: () -> Void
    private let onCancel: () -> Void
    private let onSave: () -> Void
    private let onReject: () -> Void
    private let onExport: () -> Void

    public init(result: PitchAnalysisResult?, isBusy: Bool, isStale: Bool, status: String?, hasSaved: Bool,
                canAnalyze: Bool, onAnalyze: @escaping () -> Void, onCancel: @escaping () -> Void,
                onSave: @escaping () -> Void, onReject: @escaping () -> Void, onExport: @escaping () -> Void) {
        self.result = result
        self.isBusy = isBusy
        self.isStale = isStale
        self.status = status
        self.hasSaved = hasSaved
        self.canAnalyze = canAnalyze
        self.onAnalyze = onAnalyze
        self.onCancel = onCancel
        self.onSave = onSave
        self.onReject = onReject
        self.onExport = onExport
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                switch PitchAnalysisViewActionGate.resultState(result: result) {
                case .absent:
                    Text("尚无音高分析候选。选择已保存的单声部原声区间后开始分析。")
                        .foregroundStyle(.secondary)
                case .valid(let interpretation):
                    if let result {
                        resultSummary(result, interpretation: interpretation)
                    }
                case .invalid:
                    invalidResultSummary
                }
                if let status {
                    Text(status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                actionRow
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .accessibilityIdentifier("pitch-result")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("音高候选").font(.title3)
            Text("连续音高是模型轨迹；近似音符是按等律半音解释的单声部候选，不是谱面或音符试听。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func resultSummary(_ result: PitchAnalysisResult, interpretation: PitchInterpretation) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("分析时长 \(analysisSeconds(result).formatted(.number.precision(.fractionLength(3)))) 秒")
                .font(.caption).foregroundStyle(.secondary)
            if result.hasVoicedPitch {
                Text("连续音高轨迹（前 \(min(result.frames.count, 12)) / \(result.frames.count) 帧）")
                    .font(.headline)
                ForEach(Array(result.frames.prefix(12).enumerated()), id: \.offset) { pair in
                    frameRow(index: pair.offset, frame: pair.element)
                }
            } else {
                Text("未检测到可靠单声音高").font(.headline)
                Text("这是正常的未可靠识别结果，不表示系统错误。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Text("近似音符候选").font(.headline)
            if !interpretation.notes.isEmpty {
                ForEach(Array(interpretation.notes.prefix(12).enumerated()), id: \.offset) { pair in
                    Text("\(noteName(pair.element.midiNote))（MIDI \(pair.element.midiNote)）：\(pair.element.startSample)–\(pair.element.endSample) 样本（\(sampleSeconds(pair.element.startSample).formatted(.number.precision(.fractionLength(3))))–\(sampleSeconds(pair.element.endSample).formatted(.number.precision(.fractionLength(3)))) 秒），平均分数 \(pair.element.meanConfidence.formatted(.number.precision(.fractionLength(2))))")
                        .fixedSize(horizontal: false, vertical: true)
                }
                if interpretation.notes.count > 12 {
                    Text("另有 \(interpretation.notes.count - 12) 个近似音符未在此列表展开。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("没有满足连续至少 5 帧条件的近似音符。")
                    .foregroundStyle(.secondary)
            }
            Text("仅覆盖完整的 256 样本分析块；最后不足一块的尾部未分析，未纳入音符覆盖。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var invalidResultSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("分析结果无效或不完整").font(.headline).foregroundStyle(.orange)
            Text("不能保存或导出此候选。这不是“未检测到可靠单声音高”；可拒绝后重新分析。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func frameRow(index: Int, frame: PitchFrame) -> some View {
        let pitch = frame.pitchHz.map { $0.formatted(.number.precision(.fractionLength(2))) + " Hz" } ?? "未可靠识别"
        return Text("帧 \(index + 1)：\(pitch)，分数 \(frame.confidence.formatted(.number.precision(.fractionLength(2))))")
            .font(.body.monospacedDigit()).fixedSize(horizontal: false, vertical: true)
    }

    private func analysisSeconds(_ result: PitchAnalysisResult) -> Double {
        Double(result.sampleCount) / 16_000
    }

    private func sampleSeconds(_ sample: Int) -> Double {
        Double(sample) / 16_000
    }

    private func noteName(_ midiNote: Int) -> String {
        let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
        return "\(names[midiNote % 12])\(midiNote / 12 - 1)"
    }

    private var actionRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("开始分析") {
                    _ = PitchAnalysisViewActionGate.analyze(result: result, isBusy: isBusy, hasSaved: hasSaved,
                                                            canAnalyze: canAnalyze, action: onAnalyze)
                }
                    .buttonStyle(.glass)
                    .disabled(!PitchAnalysisViewActionGate.canAnalyze(result: result, isBusy: isBusy, hasSaved: hasSaved, canAnalyze: canAnalyze))
                    .accessibilityIdentifier("pitch-analyze")
                Button("取消", role: .destructive) {
                    _ = PitchAnalysisViewActionGate.cancel(isBusy: isBusy, action: onCancel)
                }
                    .disabled(!PitchAnalysisViewActionGate.canCancel(isBusy: isBusy))
                    .accessibilityIdentifier("pitch-cancel")
            }
            HStack {
                Button("保存") {
                    _ = PitchAnalysisViewActionGate.save(result: result, isBusy: isBusy, isStale: isStale,
                                                         hasSaved: hasSaved, action: onSave)
                }
                    .disabled(!PitchAnalysisViewActionGate.canSave(result: result, isBusy: isBusy, isStale: isStale, hasSaved: hasSaved))
                    .accessibilityIdentifier("pitch-save")
                Button("拒绝", role: .destructive) {
                    _ = PitchAnalysisViewActionGate.reject(result: result, isBusy: isBusy, hasSaved: hasSaved,
                                                           action: onReject)
                }
                    .disabled(!PitchAnalysisViewActionGate.canReject(result: result, isBusy: isBusy, hasSaved: hasSaved))
                    .accessibilityIdentifier("pitch-reject")
                Button("导出 JSON") {
                    _ = PitchAnalysisViewActionGate.export(result: result, isBusy: isBusy, action: onExport)
                }
                    .disabled(!PitchAnalysisViewActionGate.canExport(result: result, isBusy: isBusy))
                    .accessibilityIdentifier("pitch-export")
            }
            if isStale {
                Text("此候选已过期，不能保存；可拒绝并重新分析。")
                    .font(.caption).foregroundStyle(.orange)
            } else if hasSaved {
                Text("此候选已保存；可导出或开始新的分析。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
