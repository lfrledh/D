import DWorkbench
import Foundation

/// The creation surface presents state only.  Its host owns every operation which changes a
/// project, task, model installation, or exported media.
@MainActor
public struct VideoCreationActions {
    public var generate: () -> Void
    public var cancel: () -> Void
    public var save: () -> Void
    public var chooseModel: () -> Void
    public var stop: () -> Void
    public var select: (UUID?) -> Void
    public var adopt: (UUID?) -> Void
    public var preview: (UUID) -> Void
    public var export: (UUID) -> Void
    public var reject: (UUID, Bool) -> Void

    public init(generate: @escaping () -> Void, cancel: @escaping () -> Void,
                save: @escaping () -> Void, chooseModel: @escaping () -> Void,
                stop: @escaping () -> Void, select: @escaping (UUID?) -> Void,
                adopt: @escaping (UUID?) -> Void, preview: @escaping (UUID) -> Void,
                export: @escaping (UUID) -> Void, reject: @escaping (UUID, Bool) -> Void) {
        self.generate = generate
        self.cancel = cancel
        self.save = save
        self.chooseModel = chooseModel
        self.stop = stop
        self.select = select
        self.adopt = adopt
        self.preview = preview
        self.export = export
        self.reject = reject
    }
}

@MainActor
enum VideoCreationButtonHandler {
    @discardableResult
    static func submit(_ draft: VideoCreationDraft, hostAllowsGeneration: Bool,
                       isBusy: Bool, actions: VideoCreationActions) -> Bool {
        guard !isBusy, hostAllowsGeneration, isValid(draft) else { return false }
        actions.generate()
        return true
    }

    @discardableResult
    static func select(_ id: UUID?, isBusy: Bool, actions: VideoCreationActions) -> Bool {
        guard !isBusy else { return false }
        actions.select(id)
        return true
    }

    @discardableResult
    static func adopt(_ id: UUID?, isRejected: Bool, isBusy: Bool,
                      actions: VideoCreationActions) -> Bool {
        guard !isBusy, !isRejected else { return false }
        actions.adopt(id)
        return true
    }

    @discardableResult
    static func setRejected(_ id: UUID, currentlyRejected: Bool, isBusy: Bool,
                            actions: VideoCreationActions) -> Bool {
        guard !isBusy else { return false }
        actions.reject(id, !currentlyRejected)
        return true
    }

    @discardableResult
    static func preview(_ id: UUID, isBusy: Bool, actions: VideoCreationActions) -> Bool {
        guard !isBusy else { return false }
        actions.preview(id)
        return true
    }

    @discardableResult
    static func export(_ id: UUID, isBusy: Bool, actions: VideoCreationActions) -> Bool {
        guard !isBusy else { return false }
        actions.export(id)
        return true
    }

    static func isValid(_ draft: VideoCreationDraft) -> Bool {
        guard !draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return (try? draft.makeRequest()) != nil
    }

    static func submissionMessage(_ draft: VideoCreationDraft, hostAllowsGeneration: Bool) -> String {
        guard !draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "请输入提示词。" }
        guard isValid(draft) else { return "参数不受当前视频模型支持；输入保持不变。" }
        guard hostAllowsGeneration else { return "尚不能生成，请检查模型状态或等待当前任务结束。" }
        return "准备就绪。"
    }
}
