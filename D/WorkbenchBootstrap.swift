import AppKit
import DWorkbench
import Foundation
import Observation
import UI

/// One application owns the library and presentation observers, including with no project open.
@MainActor @Observable
final class WorkbenchBootstrap {
    private(set) var model: WorkbenchModel?
    private(set) var libraryModel: ModelLibraryModel?
    private(set) var startupError: String?
    private(set) var isTerminating = false
    private var library: ModelLibrary?
    private var loading = false
    private var pendingProjectURL: URL?

    func start() async {
        guard model == nil, !loading else { return }
        loading = true
        startupError = nil
        defer { loading = false }
        do {
            // Only the small installation index/bookmarks live in the app container.
            // Model bytes and partial downloads go to the user-selected external library.
            let support = try FileManager.default.url(for: .applicationSupportDirectory,
                in: .userDomainMask, appropriateFor: nil, create: true)
            var settings = UserDefaults.standard
            var libraryDirectory = support.appendingPathComponent("D/ModelLibrary", isDirectory: true)
            var audioWorkbenchEnabled = false
            #if DEBUG
            // UI fixtures exercise the real services and native file panels, while keeping
            // project bookmarks and installation recovery separate from the user's session.
            if let token = ProcessInfo.processInfo.environment["D_UI_TEST_SESSION"],
               let id = UUID(uuidString: token),
               let isolated = UserDefaults(suiteName: "D.UITests.\(id.uuidString)") {
                settings = isolated
                libraryDirectory = support.appendingPathComponent("D/UITests/\(id.uuidString)/ModelLibrary",
                    isDirectory: true)
                audioWorkbenchEnabled = AudioWorkbenchIsolation.isEnabled(
                    environment: ProcessInfo.processInfo.environment
                )
            }
            #endif
            let library = try await ModelLibrary(stateDirectory: libraryDirectory)
            let model = WorkbenchModel(sessionFactory: AppSessionFactory.makeSession,
                settings: settings, modelLibrary: library,
                audioEnabled: audioWorkbenchEnabled, audioRecordingEnabled: audioWorkbenchEnabled)
            let observer = ModelLibraryModel(library: library)
            self.library = library
            self.model = model
            self.libraryModel = observer
            observer.start()
            if let pendingProjectURL {
                self.pendingProjectURL = nil
                await model.openProject(at: pendingProjectURL)
            }
            // Ordinary launch remains at the project chooser. A recent project opens only
            // after an explicit selection; Finder open requests above retain their meaning.
        } catch {
            startupError = "无法打开模型库记录：\(error.localizedDescription)\n已有项目与模型文件未被删除。请检查存储后重试。"
        }
    }

    func openProject(at url: URL) async {
        if let model { await model.openProject(at: url) }
        else { pendingProjectURL = url; await start() }
    }

    /// Invoked for app Quit after the project close gate has drained inference and saved files.
    /// Closing a project/window or the model sheet alone must not cancel downloads.
    func prepareLibraryForTermination() async -> Bool {
        isTerminating = true
        do {
            try await library?.shutdown()
            libraryModel?.stop()
            return true
        } catch {
            isTerminating = false
            let alert = NSAlert()
            alert.messageText = "模型安装进度暂未保存"
            alert.informativeText = "\(error.localizedDescription)\n请恢复磁盘访问后再次退出。"
            alert.addButton(withTitle: "继续使用 D")
            if let window = NSApp.keyWindow ?? NSApp.mainWindow {
                await alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
            return false
        }
    }
}
