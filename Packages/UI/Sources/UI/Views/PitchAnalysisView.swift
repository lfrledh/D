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
    @Environment(\.dLanguageStore) private var consistencyLanguage
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
                    Text(consistencyText(consistencyLanguage, "remaining.a7cbfa556a1d"))
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
            Text(consistencyText(consistencyLanguage, "remaining.5d82c7269793")).font(.title3)
            Text(consistencyText(consistencyLanguage, "remaining.8e57a953f0a3"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func resultSummary(_ result: PitchAnalysisResult, interpretation: PitchInterpretation) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(consistencyText(consistencyLanguage, "remaining.f130cfb4c000", arguments: ["v0": String(describing: analysisSeconds(result).formatted(.number.precision(.fractionLength(3))))]))
                .font(.caption).foregroundStyle(.secondary)
            if result.hasVoicedPitch {
                Text(consistencyText(consistencyLanguage, "remaining.5784955dce5e", arguments: ["v0": String(describing: min(result.frames.count, 12)), "v1": String(describing: result.frames.count)]))
                    .font(.headline)
                ForEach(Array(result.frames.prefix(12).enumerated()), id: \.offset) { pair in
                    frameRow(index: pair.offset, frame: pair.element)
                }
            } else {
                Text(consistencyText(consistencyLanguage, "remaining.8625fbb2f773")).font(.headline)
                Text(consistencyText(consistencyLanguage, "remaining.eb5ae6c21d61"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Text(consistencyText(consistencyLanguage, "remaining.435b0017dced")).font(.headline)
            if !interpretation.notes.isEmpty {
                ForEach(Array(interpretation.notes.prefix(12).enumerated()), id: \.offset) { pair in
                    Text(consistencyText(consistencyLanguage, "remaining.de18c979ccc0", arguments: ["v0": String(describing: noteName(pair.element.midiNote)), "v1": String(describing: pair.element.midiNote), "v2": String(describing: pair.element.startSample), "v3": String(describing: pair.element.endSample), "v4": String(describing: sampleSeconds(pair.element.startSample).formatted(.number.precision(.fractionLength(3)))), "v5": String(describing: sampleSeconds(pair.element.endSample).formatted(.number.precision(.fractionLength(3)))), "v6": String(describing: pair.element.meanConfidence.formatted(.number.precision(.fractionLength(2))))]))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if interpretation.notes.count > 12 {
                    Text(consistencyText(consistencyLanguage, "remaining.6d4f05767ac4", arguments: ["v0": String(describing: interpretation.notes.count - 12)]))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(consistencyText(consistencyLanguage, "remaining.c91fa1bd3f7c"))
                    .foregroundStyle(.secondary)
            }
            Text(consistencyText(consistencyLanguage, "remaining.31f38fb2bb50"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var invalidResultSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(consistencyText(consistencyLanguage, "remaining.0cad543f8abd")).font(.headline).foregroundStyle(.orange)
            Text(consistencyText(consistencyLanguage, "remaining.838033c2d27f"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func frameRow(index: Int, frame: PitchFrame) -> some View {
        let pitch = frame.pitchHz.map { $0.formatted(.number.precision(.fractionLength(2))) + " Hz" } ?? consistencyText(consistencyLanguage, "remaining.cbe5b27aea89")
        return Text(consistencyText(consistencyLanguage, "remaining.ebb08dd6131a", arguments: ["v0": String(describing: index + 1), "v1": String(describing: pitch), "v2": String(describing: frame.confidence.formatted(.number.precision(.fractionLength(2))))]))
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
                Button(consistencyText(consistencyLanguage, "remaining.b2be5f83c949")) {
                    _ = PitchAnalysisViewActionGate.analyze(result: result, isBusy: isBusy, hasSaved: hasSaved,
                                                            canAnalyze: canAnalyze, action: onAnalyze)
                }
                    .buttonStyle(WorkbenchGlassButtonStyle())
                    .disabled(!PitchAnalysisViewActionGate.canAnalyze(result: result, isBusy: isBusy, hasSaved: hasSaved, canAnalyze: canAnalyze))
                    .accessibilityIdentifier("pitch-analyze")
                Button(consistencyText(consistencyLanguage, "remaining.2cd0f3be8738"), role: .destructive) {
                    _ = PitchAnalysisViewActionGate.cancel(isBusy: isBusy, action: onCancel)
                }
                    .disabled(!PitchAnalysisViewActionGate.canCancel(isBusy: isBusy))
                    .accessibilityIdentifier("pitch-cancel")
            }
            HStack {
                Button(consistencyText(consistencyLanguage, "remaining.a3030bf8f16d")) {
                    _ = PitchAnalysisViewActionGate.save(result: result, isBusy: isBusy, isStale: isStale,
                                                         hasSaved: hasSaved, action: onSave)
                }
                    .disabled(!PitchAnalysisViewActionGate.canSave(result: result, isBusy: isBusy, isStale: isStale, hasSaved: hasSaved))
                    .accessibilityIdentifier("pitch-save")
                Button(consistencyText(consistencyLanguage, "remaining.136de7a8c46f"), role: .destructive) {
                    _ = PitchAnalysisViewActionGate.reject(result: result, isBusy: isBusy, hasSaved: hasSaved,
                                                           action: onReject)
                }
                    .disabled(!PitchAnalysisViewActionGate.canReject(result: result, isBusy: isBusy, hasSaved: hasSaved))
                    .accessibilityIdentifier("pitch-reject")
                Button(consistencyText(consistencyLanguage, "remaining.fb48367b485c")) {
                    _ = PitchAnalysisViewActionGate.export(result: result, isBusy: isBusy, action: onExport)
                }
                    .disabled(!PitchAnalysisViewActionGate.canExport(result: result, isBusy: isBusy))
                    .accessibilityIdentifier("pitch-export")
            }
            if isStale {
                Text(consistencyText(consistencyLanguage, "remaining.b25d32c66e0f"))
                    .font(.caption).foregroundStyle(.orange)
            } else if hasSaved {
                Text(consistencyText(consistencyLanguage, "remaining.ce019a9c96e2"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
