import DWorkbench
import Foundation

/// The creation view owns presentation only; its host supplies every state-changing operation.
@MainActor
public struct AudioCreationActions {
    public var generate: () -> Void
    public var cancel: () -> Void
    public var save: () -> Void
    public var select: (UUID?) -> Void
    public var play: (UUID) -> Void
    public var stop: () -> Void
    public var adopt: (UUID?) -> Void
    public var reject: (UUID, Bool) -> Void
    public var export: (UUID) -> Void
    public var createFrom: (UUID) -> Void
    public var chooseModel: () -> Void

    public init(generate: @escaping () -> Void, cancel: @escaping () -> Void,
                save: @escaping () -> Void, select: @escaping (UUID?) -> Void,
                play: @escaping (UUID) -> Void, stop: @escaping () -> Void,
                adopt: @escaping (UUID?) -> Void, reject: @escaping (UUID, Bool) -> Void,
                export: @escaping (UUID) -> Void, createFrom: @escaping (UUID) -> Void,
                chooseModel: @escaping () -> Void) {
        self.generate = generate
        self.cancel = cancel
        self.save = save
        self.select = select
        self.play = play
        self.stop = stop
        self.adopt = adopt
        self.reject = reject
        self.export = export
        self.createFrom = createFrom
        self.chooseModel = chooseModel
    }
}

@MainActor
enum AudioCreationButtonHandler {
    @discardableResult
    static func submit(_ draft: AudioCreationDraft, source: ProjectAsset?, hostAllowsGeneration: Bool,
                       hasPendingRangeInput: Bool = false, actions: AudioCreationActions) -> Bool {
        guard canSubmit(draft, source: source, hostAllowsGeneration: hostAllowsGeneration,
                        hasPendingRangeInput: hasPendingRangeInput) else { return false }
        actions.generate()
        return true
    }

    @discardableResult
    static func select(_ id: UUID?, isBusy: Bool, actions: AudioCreationActions) -> Bool {
        guard !isBusy else { return false }
        actions.select(id)
        return true
    }

    @discardableResult
    static func adopt(_ id: UUID?, isRejected: Bool, isBusy: Bool,
                      actions: AudioCreationActions) -> Bool {
        guard !isBusy, !isRejected else { return false }
        actions.adopt(id)
        return true
    }

    @discardableResult
    static func setRejected(_ id: UUID, currentlyRejected: Bool, isBusy: Bool,
                            actions: AudioCreationActions) -> Bool {
        guard !isBusy else { return false }
        actions.reject(id, !currentlyRejected)
        return true
    }

    @discardableResult
    static func play(_ id: UUID, isBusy: Bool, actions: AudioCreationActions) -> Bool {
        guard !isBusy else { return false }
        actions.play(id)
        return true
    }

    @discardableResult
    static func export(_ id: UUID, isBusy: Bool, actions: AudioCreationActions) -> Bool {
        guard !isBusy else { return false }
        actions.export(id)
        return true
    }

    static func canGenerate(_ draft: AudioCreationDraft, source: ProjectAsset?) -> Bool {
        guard numericInputsAreValid(draft), !draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        switch draft.operation {
        case .generate:
            return true
        case .variation:
            return sourceIsEditable(source)
        case .inpaint:
            guard sourceIsEditable(source), let range = draft.editRegion,
                  let format = source?.metadata.audio?.format else { return false }
            return range.startFrame >= 0 && range.endFrame > range.startFrame
                && range.endFrame <= format.frameCount
        }
    }

    static func canSubmit(_ draft: AudioCreationDraft, source: ProjectAsset?, hostAllowsGeneration: Bool,
                          hasPendingRangeInput: Bool) -> Bool {
        guard hostAllowsGeneration, canGenerate(draft, source: source) else { return false }
        return draft.operation != .inpaint || !hasPendingRangeInput
    }

    static func sourceIsEditable(_ source: ProjectAsset?) -> Bool {
        guard let format = source?.metadata.audio?.format else { return false }
        return format.container == .wav && format.sampleRate == 44_100 && format.channelCount == 2
    }

    static func numericInputsAreValid(_ draft: AudioCreationDraft) -> Bool {
        guard let seed = UInt64(draft.seedText), seed <= 4_294_967_294,
              let steps = Int(draft.stepsText), (1...100).contains(steps),
              let guidance = Double(draft.guidanceText), guidance.isFinite, (1...15).contains(guidance) else { return false }
        switch draft.operation {
        case .generate:
            guard let duration = Double(draft.durationText), duration.isFinite, duration > 0 else { return false }
            return true
        case .variation, .inpaint:
            guard let strength = Double(draft.strengthText), strength.isFinite else { return false }
            return strength > 0 && strength <= 1
        }
    }

    static func displayedRange(_ range: AudioFrameRange?, source: ProjectAsset?) -> (String, String) {
        guard let range, let format = source?.metadata.audio?.format, format.sampleRate > 0 else { return ("", "") }
        return (String(Double(range.startFrame) / format.sampleRate), String(Double(range.endFrame) / format.sampleRate))
    }

    static func submissionMessage(_ draft: AudioCreationDraft, source: ProjectAsset?,
                                  hostAllowsGeneration: Bool, hasPendingRangeInput: Bool) -> String {
        if draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请输入提示词。" }
        if !numericInputsAreValid(draft) { return "参数不受当前模型支持；输入保持不变。" }
        if draft.operation != .generate && source == nil { return "参考变体和区间重绘需要原声。" }
        if draft.operation != .generate && !sourceIsEditable(source) { return "当前来源不能由该模型编辑。" }
        if draft.operation == .inpaint && hasPendingRangeInput { return "请先应用有效区间，再生成。" }
        if !canGenerate(draft, source: source) { return "区间必须在原声内且结束大于开始。" }
        if !hostAllowsGeneration { return "尚不能生成，请检查模型状态或等待当前任务结束。" }
        return "准备就绪。"
    }

    static func frameRange(startText: String, endText: String, format: AudioFormatInfo) -> AudioFrameRange? {
        guard format.sampleRate.isFinite, format.sampleRate > 0,
              let startSeconds = Double(startText), startSeconds.isFinite,
              let endSeconds = Double(endText), endSeconds.isFinite else { return nil }
        let startFrames = (startSeconds * format.sampleRate).rounded()
        let endFrames = (endSeconds * format.sampleRate).rounded()
        guard startFrames.isFinite, endFrames.isFinite,
              let startFrame = Int64(exactly: startFrames), let endFrame = Int64(exactly: endFrames) else { return nil }
        let range = AudioFrameRange(startFrame: startFrame, endFrame: endFrame)
        guard range.startFrame >= 0, range.endFrame > range.startFrame,
              range.endFrame <= format.frameCount else { return nil }
        return range
    }
}
