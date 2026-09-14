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
    private(set) var audioEngineIssue: String?
    private(set) var videoEngineIssue: String?
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
            #if DEBUG
            // UI fixtures exercise the real services and native file panels, while keeping
            // project bookmarks and installation recovery separate from the user's session.
            if let token = ProcessInfo.processInfo.environment["D_UI_TEST_SESSION"],
               let id = UUID(uuidString: token),
               let isolated = UserDefaults(suiteName: "D.UITests.\(id.uuidString)") {
                settings = isolated
                libraryDirectory = support.appendingPathComponent("D/UITests/\(id.uuidString)/ModelLibrary",
                    isDirectory: true)
            }
            #endif
            let consent = AudioModelUsePermission(settings: settings)
            let accessRoot = libraryDirectory.deletingLastPathComponent()
                .appendingPathComponent("AudioProcessAccess", isDirectory: true)
            let availability = Self.prepareAudioEngine(resolve: {
                guard let resources = Bundle.main.resourceURL else { return nil }
                return try BundledAudioEngine.resolve(resourceDirectory: resources)
            }, prepareAccess: {
                try FileManager.default.createDirectory(at: accessRoot, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
            })
            let engine = availability.engine
            let musicConsent = AudioModelUsePermission(settings: settings, model: .mrt2Music)
            let musicAvailability = Self.prepareAudioEngine(resolve: {
                guard let resources = Bundle.main.resourceURL else { return nil }
                return try BundledAudioEngine.resolve(resourceDirectory: resources, family: .mrt2Music)
            }, prepareAccess: {
                try FileManager.default.createDirectory(at: accessRoot, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
            })
            let musicEngine = musicAvailability.engine
            let issues = [availability.issue, musicAvailability.issue].compactMap { $0 }
            audioEngineIssue = issues.isEmpty ? nil : issues.joined(separator: "\n")
            let videoAccessRoot = libraryDirectory.deletingLastPathComponent()
                .appendingPathComponent("VideoProcessAccess", isDirectory: true)
            var resolvedVideo: BundledAudioEngine?
            do {
                resolvedVideo = try Bundle.main.resourceURL.flatMap {
                    try BundledAudioEngine.resolve(resourceDirectory: $0, family: .video)
                }
                if resolvedVideo != nil {
                    try FileManager.default.createDirectory(at: videoAccessRoot, withIntermediateDirectories: true,
                        attributes: [.posixPermissions: 0o700])
                }
                videoEngineIssue = nil
            } catch {
                resolvedVideo = nil
                videoEngineIssue = "视频引擎暂不可用；已有项目与媒体仍可打开。\n" + error.localizedDescription
            }
            let videoEngine = resolvedVideo
            let pitchAvailability = Self.prepareAudioEngine(resolve: {
                guard let resources = Bundle.main.resourceURL else { return nil }
                return try BundledAudioEngine.resolve(resourceDirectory: resources, family: .pitch)
            }, prepareAccess: {
                try FileManager.default.createDirectory(at: accessRoot, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
            })
            if let issue = pitchAvailability.issue {
                audioEngineIssue = [audioEngineIssue, "音高识别暂不可用：" + issue].compactMap { $0 }.joined(separator: "\n")
            }
            let library = try await ModelLibrary(stateDirectory: libraryDirectory)
            let model = WorkbenchModel(sessionFactory: { artifacts in
                try await AppSessionFactory.makeSession(artifactDirectory: artifacts,
                    bundledAudioEngine: engine, audioConsent: consent,
                    bundledMusicEngine: musicEngine, musicConsent: musicConsent, audioAccessRoot: accessRoot,
                    bundledVideoEngine: videoEngine, videoAccessRoot: videoAccessRoot,
                    bundledPitchEngine: pitchAvailability.engine)
            }, settings: settings, modelLibrary: library,
                // Original capture/import/playback are independent of optional model deployment.
                // H09 hardware recording, playback, export and cold reopen are accepted.
                audioEnabled: true, audioRecordingEnabled: true)
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
            startupError = "无法准备工作台或内嵌引擎：\(error.localizedDescription)\n已有项目与模型文件未被删除。请检查存储后重试。"
        }
    }

    /// Audio deployment failure must leave projects and other modalities available.
    static func prepareAudioEngine(resolve: () throws -> BundledAudioEngine?,
                                   prepareAccess: () throws -> Void)
        -> (engine: BundledAudioEngine?, issue: String?) {
        do {
            guard let engine = try resolve() else { return (nil, nil) }
            try prepareAccess()
            return (engine, nil)
        } catch {
            return (nil, "声音引擎暂不可用；图像、文稿与已有作品仍可使用。\n" + error.localizedDescription)
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
