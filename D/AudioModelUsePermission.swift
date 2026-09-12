import AppKit
import DMLXBackend
import Foundation

/// A user's acknowledgement of existing usage rights, not acceptance on their behalf.
/// The key is specific to the supported music profile and fixed model revision.
@MainActor final class AudioModelUsePermission {
    enum Model { case stableAudio, mrt2Music }
    private let model: Model
    private let settings: UserDefaults
    private var key: String {
        switch model {
        case .stableAudio: "audio.model-use.sm-music." + AudioBackendConfiguration.registeredModelRevision
        case .mrt2Music: "audio.model-use.mrt2-small." + MRT2BackendConfiguration.registeredModelRevision
        }
    }
    init(settings: UserDefaults, model: Model = .stableAudio) { self.settings = settings; self.model = model }
    var isAcknowledged: Bool { settings.bool(forKey: key) }

    func confirm() async -> Bool {
        if isAcknowledged { return true }
        let alert = NSAlert()
        alert.messageText = "确认本地声音模型的使用资格"
        switch model {
        case .stableAudio:
            alert.informativeText = "此声音模型适用 Stable Audio 3 与 Gemma 的模型条款。请选择你已经取得适用资格的模型；D 不代你注册或接受条款。确认仅记录在这台 Mac 的当前应用设置中，不上传资料。"
        case .mrt2Music:
            alert.informativeText = "Magenta RealTime 2 模型采用 CC BY 4.0，并附有模型卡中的负责任使用说明。请选择你已确认适用资格的固定模型；使用与分发时保留要求的署名。D 只在当前应用设置记录确认，不代你接受条款，也不上传素材。"
        }
        alert.addButton(withTitle: "我已确认具有适用资格")
        alert.addButton(withTitle: "暂不使用此模型")
        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            response = await alert.beginSheetModal(for: window)
        } else { response = alert.runModal() }
        guard response == .alertFirstButtonReturn, !Task.isCancelled else { return false }
        settings.set(true, forKey: key)
        return true
    }
}
