import AppKit
import DWorkbench
import DMLXBackend
import Foundation
import Observation
import UI

/// One application owns the library and presentation observers, including with no project open.
@MainActor @Observable
final class WorkbenchBootstrap {
    private(set) var quickModel: WorkbenchModel?
    private(set) var quick: QuickGenerationController?
    private var sharedSession: WorkbenchSession?
    private(set) var model: WorkbenchModel?
    private(set) var libraryModel: ModelLibraryModel?
    private(set) var nodeTags: ModelNodeTagStore?
    private(set) var sharedLibrary: SharedLibraryStore?
    private(set) var sharedLibraryIssue: String?
    private(set) var languageStore = UILanguageStore()
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
            languageStore = UILanguageStore(settings: settings, directory: libraryDirectory.deletingLastPathComponent()
                .appendingPathComponent("LanguagePacks", isDirectory: true))
            nodeTags = ModelNodeTagStore(settings: settings)
            do { sharedLibrary = try SharedLibraryStore(fileURL: libraryDirectory.deletingLastPathComponent().appendingPathComponent("shared-library.json")) }
            catch { sharedLibraryIssue = "资料整理记录无法读取，已保留原件：" + error.localizedDescription }
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
            let aceAvailability = Self.prepareAudioEngine(resolve: {
                guard let resources = Bundle.main.resourceURL else { return nil }
                return try BundledAudioEngine.resolve(resourceDirectory: resources, family: .aceMusic)
            }, prepareAccess: {
                try FileManager.default.createDirectory(at: accessRoot, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
            })
            let musicEngine = musicAvailability.engine
            let issues = [availability.issue, musicAvailability.issue, aceAvailability.issue].compactMap { $0 }
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
            let externalVideoAvailability = Self.prepareAudioEngine(resolve: {
                guard let resources = Bundle.main.resourceURL else { return nil }
                return try BundledAudioEngine.resolve(resourceDirectory: resources, family: .externalVideo)
            }, prepareAccess: {
                try FileManager.default.createDirectory(at: videoAccessRoot, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
            })
            if let issue = externalVideoAvailability.issue {
                videoEngineIssue = [videoEngineIssue, "H3/LTX 引擎暂不可用：" + issue].compactMap { $0 }.joined(separator: "\n")
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
            let wanPreparation: (@Sendable (URL, URL) async throws -> Void)?
            if let videoEngine, let script = videoEngine.videoPreparationScript {
                let preparer = try WanModelPreparation(configuration: .init(pythonExecutable: videoEngine.pythonExecutable,
                    providerScript: script, accessBootstrapRoot: videoAccessRoot))
                wanPreparation = { source, destination in
                    try videoEngine.confirmUnchanged()
                    try await preparer.prepare(source: source, destination: destination)
                }
            } else { wanPreparation = nil }
            let library = try await ModelLibrary(stateDirectory: libraryDirectory, wanPreparation: wanPreparation)
            let quickURL = libraryDirectory.deletingLastPathComponent().appendingPathComponent("Quick Creations.dproject", isDirectory: true)
            let quickStore: ProjectStore
            do {
                if FileManager.default.fileExists(atPath: quickURL.path) { quickStore = try await ProjectStore.open(at: quickURL) }
                else { quickStore = try await ProjectStore.create(at: quickURL, name: "快速创作") }
            } catch {
                // A damaged automatic record never becomes an empty replacement or blocks existing named projects.
                startupError = "快速创作记录暂不可用，原件保留；仍可打开已有项目。\n" + error.localizedDescription
                self.library = library
                let observer = ModelLibraryModel(library: library); self.libraryModel = observer
                self.model = WorkbenchModel(sessionFactory: { artifactDirectory in
                    try await AppSessionFactory.makeSession(artifactDirectory: artifactDirectory,
                        bundledAudioEngine: engine, audioConsent: consent, bundledMusicEngine: musicEngine,
                        musicConsent: musicConsent, audioAccessRoot: accessRoot, bundledVideoEngine: videoEngine,
                        videoAccessRoot: videoAccessRoot, bundledPitchEngine: pitchAvailability.engine, bundledExternalVideoEngine: externalVideoAvailability.engine, bundledACEEngine: aceAvailability.engine)
                }, settings: settings, modelLibrary: library, audioEnabled: true, audioRecordingEnabled: true)
                observer.start()
                if let pendingProjectURL { self.pendingProjectURL = nil; await self.model?.openProject(at: pendingProjectURL) }
                return
            }
            let shared = try await AppSessionFactory.makeSession(artifactDirectory: quickStore.artifactDirectory,
                bundledAudioEngine: engine, audioConsent: consent,
                bundledMusicEngine: musicEngine, musicConsent: musicConsent, audioAccessRoot: accessRoot,
                bundledVideoEngine: videoEngine, videoAccessRoot: videoAccessRoot,
                bundledPitchEngine: pitchAvailability.engine, bundledExternalVideoEngine: externalVideoAvailability.engine, bundledACEEngine: aceAvailability.engine)
            let borrowed = shared.borrowed(artifactStore: quickStore)
            let quickModel = WorkbenchModel(sessionFactory: { _ in borrowed }, settings: settings,
                modelLibrary: library, audioEnabled: true, audioRecordingEnabled: true)
            try await quickModel.projectSession.activateInternalWorkspace(quickStore)
            quickModel.projectSession.refreshWorkflowModels()
            let quick = QuickGenerationController(store: quickStore) { [weak quickModel] in
                guard let quickModel else { throw WorkflowIssue("快速工作区已关闭。") }
                return try quickModel.projectSession.makeExplicitOperationServices()
            }
            await quick.load()
            let model = WorkbenchModel(sessionFactory: { _ in borrowed }, settings: settings,
                modelLibrary: library, audioEnabled: true, audioRecordingEnabled: true)
            model.projectSession.personalChatOwner = { [weak quickModel] in quickModel?.projectSession.chat }
            self.sharedSession = shared
            self.quickModel = quickModel
            self.quick = quick
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
        guard !isTerminating else { return }
        if let model { await model.openProject(at: url) }
        else { pendingProjectURL = url; await start() }
    }

    /// Reversible automatic-workspace save gates run before closing a named project.
    /// Closing a project/window or the model sheet alone must not cancel downloads.
    func prepareQuickForTermination() async -> Bool {
        isTerminating = true
        do {
            if let quick, quick.isRunning {
                let alert = NSAlert()
                alert.messageText = "快速生成仍在运行"
                alert.informativeText = "可以等待完成后退出，或取消本次生成。已保存的创作会保留。"
                alert.addButton(withTitle: "等待完成并退出")
                alert.addButton(withTitle: "继续使用 D")
                alert.addButton(withTitle: "取消生成并退出")
                let response = alert.runModal()
                if response == .alertSecondButtonReturn { isTerminating = false; return false }
                if response == .alertThirdButtonReturn { await quick.cancel() }
                else { await quick.waitForCompletion() }
            }
            try await quick?.prepareForTermination()
            guard quick?.pendingSaveRunID == nil else { throw WorkflowIssue("快速生成仍有待保存结果，请恢复保存后退出。") }
            guard await quickModel?.projectSession.prepareInternalForTermination() != false else { isTerminating = false; return false }
            return true
        } catch {
            isTerminating = false
            startupError = error.localizedDescription
            let alert = NSAlert(); alert.messageText = "快速创作尚未保存"
            alert.informativeText = error.localizedDescription; alert.addButton(withTitle: "继续使用 D")
            alert.runModal()
            return false
        }
    }
    func cancelTermination() { isTerminating = false }

    func prepareLibraryForTermination() async -> Bool {
        isTerminating = true
        do {
            try await library?.shutdown()
            // Every fallible admission/save gate has now accepted Quit. Only here
            // discard temporary conversations; an earlier refusal keeps them intact.
            do { try await quickModel?.endTemporaryChat() }
            catch { NSLog("D: temporary chat cleanup incomplete; owned cache preserved: %@", error.localizedDescription) }
            await sharedSession?.shutdown()
            // All fallible save gates have accepted Quit; process termination releases the
            // automatic Store's descriptor/lock. Do not close it before another owner can refuse.
            // Compute has drained. Cleanup only owns unpublished
            // temporaries; failure must not return the user to a dead runtime/closed Store.
            do { try await sharedSession?.cleanup() }
            catch { NSLog("D: shutdown completed; temporary cleanup pending: %@", error.localizedDescription) }
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
