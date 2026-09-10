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
                       actions: AudioCreationActions) -> Bool {
        guard hostAllowsGeneration, canGenerate(draft, source: source) else { return false }
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

    static func sourceIsEditable(_ source: ProjectAsset?) -> Bool {
        guard let format = source?.metadata.audio?.format else { return false }
        return format.container == .wav && format.sampleRate == 44_100 && format.channelCount == 2
    }

    static func numericInputsAreValid(_ draft: AudioCreationDraft) -> Bool {
        guard let seed = UInt64(draft.seedText), seed <= 4_294_967_294,
              let steps = Int(draft.stepsText), (1...100).contains(steps),
              let guidance = Double(draft.guidanceText), guidance.isFinite, (1...15).contains(guidance),
              let strength = Double(draft.strengthText), strength.isFinite,
              strength > 0, strength <= 1 else { return false }
        switch draft.operation {
        case .generate:
            guard let duration = Double(draft.durationText), duration.isFinite, duration > 0 else { return false }
            return strength == 1
        case .variation, .inpaint:
            return true
        }
    }

    static func frameRange(startText: String, endText: String, format: AudioFormatInfo) -> AudioFrameRange? {
        guard format.sampleRate.isFinite, format.sampleRate > 0,
              let startSeconds = Double(startText), startSeconds.isFinite,
              let endSeconds = Double(endText), endSeconds.isFinite else { return nil }
        let startFrames = (startSeconds * format.sampleRate).rounded()
        let endFrames = (endSeconds * format.sampleRate).rounded()
        guard startFrames.isFinite, endFrames.isFinite,
              startFrames >= Double(Int64.min), startFrames <= Double(Int64.max),
              endFrames >= Double(Int64.min), endFrames <= Double(Int64.max) else { return nil }
        let range = AudioFrameRange(startFrame: Int64(startFrames), endFrame: Int64(endFrames))
        guard range.startFrame >= 0, range.endFrame > range.startFrame,
              range.endFrame <= format.frameCount else { return nil }
        return range
    }
}
