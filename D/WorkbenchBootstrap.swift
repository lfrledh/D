import AppKit
import DWorkbench
import DInference
import DMLXBackend
import Foundation
import Observation
import UI

/// One application owns the library and presentation observers, including with no project open.
@MainActor @Observable
final class WorkbenchBootstrap {
    nonisolated private static func downloadPreparedValidator(_ shared: WorkbenchSession) -> @Sendable (URL) async throws -> ModelReference {
        { url in
                var matches: [ModelReference] = []
                for adapter in shared.videoAdapters {
                    do { matches.append(try await adapter.validateModel(url)) }
                    catch is CancellationError { throw CancellationError() }
                    catch { }
                }
                if let validate = shared.validateVideoModel {
                    do { matches.append(try await validate(url)) }
                    catch is CancellationError { throw CancellationError() }
                    catch { }
                }
                guard matches.count == 1, let match = matches.first else {
                    throw WorkflowIssue("执行包没有唯一匹配的现有验证引擎。")
                }
                return match
            }
    }
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
    private let launchContext: Result<WorkbenchLaunchContext, Error>
    private var reviewLease: WorkbenchReviewLease?
    private var admittedReview: WorkbenchLaunchContext.Review?
    private let reviewAuthorizer: (@MainActor (URL) async throws -> URL)?

    init(launchContext: Result<WorkbenchLaunchContext, Error> = WorkbenchLaunchContext.current,
         reviewAuthorizer: (@MainActor (URL) async throws -> URL)? = nil) {
        self.launchContext = launchContext
        self.reviewAuthorizer = reviewAuthorizer
    }
    #if DEBUG
    private var reviewRootAccess: URL?
    #endif

    func start() async {
        guard model == nil, !loading else { return }
        loading = true
        startupError = nil
        defer { loading = false }
        do {
            // Resolve the persistent package policy before even selecting ordinary defaults
            // or creating Application Support. The App and deployment entry share this result.
            let context = try launchContext.get()
            if case .review(let review) = context, reviewLease == nil {
                #if DEBUG
                do {
                    reviewLease = try await WorkbenchReviewAdmission.admit(review) { root in
                        if let reviewAuthorizer { return try await reviewAuthorizer(root) }
                        let panel = NSOpenPanel()
                        panel.title = "授权独立评审目录 / Authorize Isolated Review Folder"
                        panel.message = "仅选择此评审目录 / Select only this review folder: " + root.path
                        panel.canChooseDirectories = true; panel.canChooseFiles = false
                        panel.allowsMultipleSelection = false; panel.directoryURL = root
                        guard await panel.begin() == .OK, let selected = panel.url,
                              selected.standardizedFileURL == root else {
                            throw WorkbenchLaunchContext.Rejected(reason: "目录未授权。 / Review folder not authorized.")
                        }
                        _ = selected.startAccessingSecurityScopedResource()
                        reviewRootAccess = selected
                        return selected
                    }
                    admittedReview = review
                } catch {
                    reviewRootAccess?.stopAccessingSecurityScopedResource(); reviewRootAccess = nil
                    throw error
                }
                #else
                throw WorkbenchLaunchContext.Rejected(reason: "This build does not support review fixtures.")
                #endif
            }
            if let review = admittedReview {
                // A retained lease avoids duplicate authorization, but does not make
                // paths immutable after a failed service initialization and Retry.
                try WorkbenchReviewAdmission.validateStorage(review)
            }
            let settings: UserDefaults
            let libraryDirectory: URL
            switch context {
            case .review(let review):
                guard reviewLease != nil, let isolated = UserDefaults(suiteName: "D.UITests.\(review.session.uuidString)") else {
                    throw WorkbenchLaunchContext.Rejected(reason: "Isolated settings unavailable.")
                }
                settings = isolated
                libraryDirectory = review.root.appendingPathComponent("ModelLibrary", isDirectory: true)
                NSLog("D_REVIEW_SERVICES_ADMITTED session=%@ pid=%d", review.session.uuidString, ProcessInfo.processInfo.processIdentifier)
            case .ordinary, .uiTest:
                let support = try FileManager.default.url(for: .applicationSupportDirectory,
                    in: .userDomainMask, appropriateFor: nil, create: true)
                if case .uiTest(let id) = context {
                    guard let isolated = UserDefaults(suiteName: "D.UITests.\(id.uuidString)") else {
                        throw WorkbenchLaunchContext.Rejected(reason: "Isolated test settings unavailable.")
                    }
                    settings = isolated
                    libraryDirectory = support.appendingPathComponent("D/UITests/\(id.uuidString)/ModelLibrary", isDirectory: true)
                } else {
                    settings = UserDefaults.standard
                    libraryDirectory = support.appendingPathComponent("D/ModelLibrary", isDirectory: true)
                }
            }
            languageStore = UILanguageStore(settings: settings, directory: libraryDirectory.deletingLastPathComponent()
                .appendingPathComponent("LanguagePacks", isDirectory: true))
            nodeTags = ModelNodeTagStore(settings: settings)
            do { sharedLibrary = try SharedLibraryStore(fileURL: libraryDirectory.deletingLastPathComponent().appendingPathComponent("shared-library.json")) }
            catch { sharedLibraryIssue = "资料整理记录无法读取，已保留原件：" + error.localizedDescription }
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
            let library: ModelLibrary
            #if DEBUG
            if let review = admittedReview {
                let destination = libraryDirectory.deletingLastPathComponent().appendingPathComponent("Files", isDirectory: true)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                library = try await ModelDownloadReviewFixture.makeLibrary(stateDirectory: libraryDirectory, destination: destination, source: review.source)
            } else { library = try await ModelLibrary(stateDirectory: libraryDirectory, wanPreparation: wanPreparation) }
            #else
            library = try await ModelLibrary(stateDirectory: libraryDirectory, wanPreparation: wanPreparation)
            #endif
            let quickURL = libraryDirectory.deletingLastPathComponent().appendingPathComponent("Quick Creations.dproject", isDirectory: true)
            let quickStore: ProjectStore
            do {
                if FileManager.default.fileExists(atPath: quickURL.path) { quickStore = try await ProjectStore.open(at: quickURL) }
                else { quickStore = try await ProjectStore.create(at: quickURL, name: "快速创作") }
            } catch {
                // A damaged automatic record never becomes an empty replacement or blocks existing named projects.
                startupError = "快速创作记录暂不可用，原件保留；仍可打开已有项目。\n" + error.localizedDescription
                self.library = library
                let observer = ModelLibraryModel(library: library, language: languageStore); self.libraryModel = observer
                self.model = WorkbenchModel(sessionFactory: { artifactDirectory in
                    let created = try await AppSessionFactory.makeSession(artifactDirectory: artifactDirectory,
                        bundledAudioEngine: engine, bundledMusicEngine: musicEngine,
                        audioAccessRoot: accessRoot, bundledVideoEngine: videoEngine,
                        videoAccessRoot: videoAccessRoot, bundledPitchEngine: pitchAvailability.engine, bundledExternalVideoEngine: externalVideoAvailability.engine, bundledACEEngine: aceAvailability.engine, modelLibrary: library)
                    await MainActor.run { observer.preparedValidator = Self.downloadPreparedValidator(created) }
                    return created
                }, settings: settings, modelLibrary: library, audioEnabled: true, audioRecordingEnabled: true, language: languageStore)
                observer.inventoryProvider = { [weak self] in try self?.model?.projectSession.modelInventoryConfigurations() ?? [] }
                observer.explicitRegistration = { [weak self] url, kind in
                    guard let owner = self?.model?.projectSession else { throw WorkflowIssue("Workspace unavailable.") }
                    _ = try await owner.registerExplicitModel(at: url, kind: kind, preserveExistingBinding: true)
                }
                observer.start()
                if let pendingProjectURL { self.pendingProjectURL = nil; await self.model?.openProject(at: pendingProjectURL) }
                recordReviewReadiness(libraryDirectory: libraryDirectory, phase: "quick-unavailable")
                return
            }
            let shared = try await AppSessionFactory.makeSession(artifactDirectory: quickStore.artifactDirectory,
                bundledAudioEngine: engine,
                bundledMusicEngine: musicEngine, audioAccessRoot: accessRoot,
                bundledVideoEngine: videoEngine, videoAccessRoot: videoAccessRoot,
                bundledPitchEngine: pitchAvailability.engine, bundledExternalVideoEngine: externalVideoAvailability.engine, bundledACEEngine: aceAvailability.engine, modelLibrary: library)
            let borrowed = shared.borrowed(artifactStore: quickStore)
            let quickModel = WorkbenchModel(sessionFactory: { _ in borrowed }, settings: settings,
                modelLibrary: library, appearanceDirectory: libraryDirectory.deletingLastPathComponent().appendingPathComponent("Appearance", isDirectory: true), audioEnabled: true, audioRecordingEnabled: true, language: languageStore)
            try await quickModel.projectSession.activateInternalWorkspace(quickStore)
            quickModel.projectSession.refreshWorkflowModels()
            let quick = QuickGenerationController(store: quickStore, allowsSubmission: { [weak self, weak quickModel] in
                guard let self, let quickModel else { return false }
                return !self.isTerminating && quickModel.projectSession.currentStore === quickStore
                    && !quickModel.projectSession.isChangingProject
            }) { [weak quickModel] in
                guard let quickModel else { throw WorkflowIssue("快速工作区已关闭。") }
                return try quickModel.projectSession.makeExplicitOperationServices()
            }
            await quick.load()
            let model = WorkbenchModel(sessionFactory: { _ in borrowed }, settings: settings,
                modelLibrary: library, displaySettingsOwner: quickModel, audioEnabled: true, audioRecordingEnabled: true, language: languageStore)
            model.projectSession.personalChatOwner = { [weak quickModel] in quickModel?.projectSession.chat }
            self.sharedSession = shared
            self.quickModel = quickModel
            self.quick = quick
            let observer = ModelLibraryModel(library: library, language: languageStore)
            observer.inventoryProvider = { [weak model, weak quickModel] in
                let values = (try model?.projectSession.modelInventoryConfigurations() ?? []) + (try quickModel?.projectSession.modelInventoryConfigurations() ?? [])
                var seen = Set<String>()
                return values.filter { seen.insert($0.id).inserted }
            }
            observer.explicitRegistration = { [weak quickModel] url, kind in
                guard let owner = quickModel?.projectSession else { throw WorkflowIssue("Workspace unavailable.") }
                _ = try await owner.registerExplicitModel(at: url, kind: kind, preserveExistingBinding: true)
            }
            observer.preparedValidator = Self.downloadPreparedValidator(shared)
            self.library = library
            self.model = model
            self.libraryModel = observer
            observer.start()
            if let pendingProjectURL {
                self.pendingProjectURL = nil
                await model.openProject(at: pendingProjectURL)
            }
            recordReviewReadiness(libraryDirectory: libraryDirectory, phase: "ready")
            // Ordinary launch remains at the project chooser. A recent project opens only
            // after an explicit selection; Finder open requests above retain their meaning.
        } catch {
            NSLog("D_STARTUP_REJECTED: %@", error.localizedDescription)
            startupError = "无法准备工作台或内嵌引擎：\(error.localizedDescription)\n已有项目与模型文件未被删除。请检查存储后重试。"
        }
    }

    private func recordReviewReadiness(libraryDirectory: URL, phase: String) {
        guard let review = admittedReview else { return }
        let receipt: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier,
            "phase": phase, "session": review.session.uuidString, "bundle": Bundle.main.bundleURL.path,
            "bundleID": Bundle.main.bundleIdentifier ?? "", "executable": Bundle.main.executableURL?.path ?? "",
            "root": review.root.path, "modelIndex": libraryDirectory.appendingPathComponent("index.json").path,
            "quick": review.root.appendingPathComponent("Quick Creations.dproject").path,
            "source": review.source.absoluteString]
        do {
            try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
                .write(to: review.root.appendingPathComponent("review-runtime.json"), options: .atomic)
            NSLog("D_REVIEW_READY phase=%@ session=%@ pid=%d", phase, review.session.uuidString, ProcessInfo.processInfo.processIdentifier)
        } catch {
            // Services are already admitted. Never misreport a receipt error as an isolation rejection.
            startupError = "评审回执无法写入；请停止评审并保留会话。 / Review receipt could not be written; stop review and preserve this session.\n" + error.localizedDescription
            NSLog("D_REVIEW_RECEIPT_FAILED: %@", error.localizedDescription)
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
        do {
            if case .review(let review) = try launchContext.get() {
                let canonical = url.resolvingSymlinksInPath().standardizedFileURL.path
                guard canonical.hasPrefix(review.root.path + "/") else {
                    throw WorkbenchLaunchContext.Rejected(reason: "Review open request is outside the isolated root.")
                }
            }
        } catch { startupError = error.localizedDescription; return }
        if let model { await model.openProject(at: url) }
        else { pendingProjectURL = url; await start() }
    }

    /// Reversible automatic-workspace save gates run before closing a named project.
    /// Closing a project/window or the model sheet alone must not cancel downloads.
    func prepareQuickForTermination() async -> Bool {
        isTerminating = true
        // Both project owners can have independent Viewer annotation drafts.
        // Resolve them before any save, cancellation, or viewer suspension.
        guard model?.hasPendingEditor != true, quickModel?.hasPendingEditor != true else {
            isTerminating = false
            let alert = NSAlert()
            alert.messageText = languageStore.text("app.quit.editing", fallback: "")
            alert.informativeText = languageStore.text("app.quit.editingHelp", fallback: "")
            alert.addButton(withTitle: languageStore.text("app.quit.continue", fallback: ""))
            _ = await WorkbenchConfirmation.present(alert, owner: NSApp.keyWindow ?? NSApp.mainWindow, cancelResponse: .alertFirstButtonReturn)
            return false
        }
        do {
            if let quick, quick.isRunning || quick.isImporting {
                let alert = NSAlert()
                alert.messageText = languageStore.text("app.quit.quickActive", fallback: "")
                alert.informativeText = languageStore.text("app.quit.quickHelp", fallback: "")
                alert.addButton(withTitle: languageStore.text("app.quit.wait", fallback: ""))
                alert.addButton(withTitle: languageStore.text("app.quit.continue", fallback: ""))
                alert.addButton(withTitle: languageStore.text("app.quit.cancel", fallback: ""))
                let response = await WorkbenchConfirmation.present(alert, owner: NSApp.keyWindow ?? NSApp.mainWindow)
                if response == .alertSecondButtonReturn { isTerminating = false; return false }
                if response == .alertThirdButtonReturn { await quick.cancel() }
                else { await quick.waitForCompletion() }
            }
            try await quick?.prepareForTermination()
            guard quick?.pendingSaveRunID == nil else { throw WorkflowIssue("快速生成仍有待保存结果，请恢复保存后退出。") }
            guard model?.hasPendingEditor != true, quickModel?.hasPendingEditor != true else {
                isTerminating = false; return false
            }
            quickModel?.suspendContentViewers()
            guard await quickModel?.projectSession.prepareInternalForTermination() != false else { isTerminating = false; return false }
            return true
        } catch {
            isTerminating = false
            startupError = error.localizedDescription
            let alert = NSAlert(); alert.messageText = languageStore.text("app.quit.quickUnsaved", fallback: "")
            alert.informativeText = error.localizedDescription; alert.addButton(withTitle: languageStore.text("app.quit.continue", fallback: ""))
            _ = await WorkbenchConfirmation.present(alert, owner: NSApp.keyWindow ?? NSApp.mainWindow, cancelResponse: .alertFirstButtonReturn)
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
            #if DEBUG
            reviewRootAccess?.stopAccessingSecurityScopedResource(); reviewRootAccess = nil
            #endif
            return true
        } catch {
            isTerminating = false
            let alert = NSAlert()
            alert.messageText = "模型安装进度暂未保存"
            alert.informativeText = "\(error.localizedDescription)\n请恢复磁盘访问后再次退出。"
            alert.addButton(withTitle: "继续使用 D")
            _ = await WorkbenchConfirmation.present(alert, owner: NSApp.keyWindow ?? NSApp.mainWindow, cancelResponse: .alertFirstButtonReturn)
            return false
        }
    }
}
