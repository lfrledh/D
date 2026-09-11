import DInference
import Foundation
import Observation

public enum AudioCreationCandidateAction: Sendable {
    case select(UUID?), adopt(UUID?), reject(UUID, Bool)
}

public enum ProjectCloseDecision: Sendable {
    case wait, cancel, keepOpen
}

/// The application owns jobs, including while their views are absent.
/// Only the composition root constructs an inference implementation.
@MainActor @Observable
public final class ProjectSession {
    public private(set) var manifest: ProjectManifest?
    public private(set) var projectURL: URL?
    public private(set) var modelName: String?
    public private(set) var selectedModelID: ModelID?
    public private(set) var imageProfile: ImageModelProfile = .flux2Klein
    private var selectedModelReady = false
    public private(set) var modelStatus = "请选择已安装的 FLUX.2 Klein 4B q8 模型文件夹。"
    public var prompt = "" { didSet { scheduleDraftSave() } }
    public var randomSeed = true { didSet { scheduleDraftSave() } }
    public var seedText = "0" { didSet { scheduleDraftSave() } }
    public private(set) var selectedAssetID: UUID?
    public private(set) var showingAllArtworks = false
    /// Hosts can keep inspection/comparison stable while new results are published.
    public var automaticResultSelectionEnabled = true {
        didSet { selectionVersion &+= 1 }
    }
    public var documents: [ProjectDocument] { manifest?.documents ?? [] }
    public var activeDocumentID: UUID? { manifest?.activeDocumentID }
    public var activeDocument: ProjectDocument? { manifest?.activeDocument }
    public var documentJobs: [ProjectJob] {
        manifest?.jobs.filter { $0.documentID == activeDocumentID } ?? []
    }
    public var visibleAssets: [ProjectAsset] {
        guard let manifest else { return [] }
        guard activeDocument?.kind == .image || showingAllArtworks else { return [] }
        if showingAllArtworks { return manifest.assets.filter { $0.mediaType == "image/png" } }
        let jobs = Set(documentJobs.map(\.id))
        return manifest.assets.filter {
            $0.mediaType == "image/png"
                && ($0.id == activeDocument?.sourceAssetID || $0.jobID.map(jobs.contains) == true)
        }
    }
    public var errorMessage: String?
    public private(set) var isChangingProject = false
    public private(set) var phases: [UUID: String] = [:]
    public private(set) var progress: [UUID: Double] = [:]
    public private(set) var liveStates: [UUID: JobState] = [:]
    public private(set) var assetURLs: [UUID: URL] = [:]
    public private(set) var activeJobIDs: Set<UUID> = []
    public private(set) var text: ProjectTextController?
    public private(set) var audio: ProjectAudioController?
    public private(set) var audioCreationContextID = UUID()
    public private(set) var audioCreationDraft: AudioCreationDraft?
    public private(set) var audioModelStatus = "选择已安装的本地声音模型"
    public private(set) var isRegisteringAudioModel = false
    public let audioCreationTransport = AudioTransport(recordingEnabled: false)
    @ObservationIgnored private var audioCreationDocumentID: UUID?
    @ObservationIgnored private var audioCreationPersistedRevision: UUID?
    @ObservationIgnored private var audioCreationWriteTail: Task<Void, Never>?
    @ObservationIgnored private var audioAdmissions: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var audioAdmissionDocuments: [UUID: UUID] = [:]
    @ObservationIgnored private var audioModelLease: LocationAccess.Lease?
    @ObservationIgnored private var audioReference: ModelReference?
    public private(set) var textModelStatus = "选择已注册的 Qwen2.5 Instruct 4-bit 模型（0.5B／1.5B／7B／32B）"
    public private(set) var isTextWorking = false
    public private(set) var isRegisteringTextModel = false
    public var canRewriteText: Bool {
        text?.canRewrite == true && textReference != nil && !isBusy && !isChangingProject
            && !closePending && !showingAllArtworks && !isRegisteringTextModel
    }
    @ObservationIgnored private var textReference: ModelReference?
    @ObservationIgnored private var textModelLease: LocationAccess.Lease?
    @ObservationIgnored private var textWork: Task<Void, Never>?
    @ObservationIgnored private var textContextID = UUID()
    public var isBusy: Bool { !activeJobIDs.isEmpty || isTextWorking || audio?.isBusy == true }
    public var canGenerate: Bool {
        manifest != nil && activeDocument?.kind == .image && !isTextWorking && ((selectedModelID != nil && selectedModelReady) || modelLease != nil)
        && !isChangingProject && !showingAllArtworks && !closePending && pendingSaves.isEmpty
        && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && activeJobIDs.count < 8
    }
    public var selectedAsset: ProjectAsset? { manifest?.assets.first { $0.id == selectedAssetID } }
    public var selectedJob: ProjectJob? {
        guard let asset = selectedAsset else { return nil }
        return manifest?.jobs.first { $0.id == asset.jobID }
    }

    @ObservationIgnored private let factory: @Sendable (URL) async throws -> WorkbenchSession
    @ObservationIgnored private let closeDecision: @MainActor @Sendable () async -> ProjectCloseDecision
    @ObservationIgnored public let modelLibrary: ModelLibrary?
    @ObservationIgnored private let settings: UserDefaults
    @ObservationIgnored private let audioEnabled: Bool
    @ObservationIgnored private let audioRecordingEnabled: Bool
    @ObservationIgnored private let injectedAudioTransport: AudioTransport?
    @ObservationIgnored private let access = LocationAccess()
    @ObservationIgnored private var projectLease: LocationAccess.Lease?
    @ObservationIgnored private var modelLease: LocationAccess.Lease?
    @ObservationIgnored private var usageLeases: [UUID: ModelUsageLease] = [:]
    @ObservationIgnored private var store: ProjectStore?
    @ObservationIgnored private var session: WorkbenchSession?
    @ObservationIgnored private var handles: [UUID: InferenceRun] = [:]
    @ObservationIgnored private var workers: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var cancellationRequests: Set<UUID> = []
    @ObservationIgnored private var pendingSaves: [UUID: RunOutcome] = [:]
    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private var modelPoller: Task<Void, Never>?
    @ObservationIgnored private var draftWriter: Task<Void, Never>?
    @ObservationIgnored private var draftSaveFailed = false
    @ObservationIgnored private var draftWriteTail: Task<Void, Never>?
    @ObservationIgnored private var selectionWriteTail: Task<Void, Never>?
    @ObservationIgnored private var metadataWriteTail: Task<Void, Never>?
    @ObservationIgnored private var applyingDraft = false
    @ObservationIgnored private var draftEditVersion: UInt64 = 0
    @ObservationIgnored private var selectionVersion: UInt64 = 0
    @ObservationIgnored private var selectedModelRevision: String?
    @ObservationIgnored private var admissionTail: Task<Void, Never>?
    @ObservationIgnored private var closePending = false
    private static let projectBookmarkKey = "workbench.projectBookmark.v1"
    private static let modelBookmarkKey = "workbench.modelBookmark.v1"
    private static let selectedModelKey = "workbench.selectedModelID.v1"

    public init(sessionFactory: @escaping @Sendable (URL) async throws -> WorkbenchSession,
                settings: UserDefaults = .standard,
                modelLibrary: ModelLibrary? = nil,
                audioEnabled: Bool = false,
                audioRecordingEnabled: Bool = false,
                audioTransport: AudioTransport? = nil,
                closeDecision: @escaping @MainActor @Sendable () async -> ProjectCloseDecision = { .keepOpen }) {
        self.closeDecision = closeDecision
        self.factory = sessionFactory
        self.settings = settings
        self.modelLibrary = modelLibrary
        self.audioEnabled = audioEnabled
        self.audioRecordingEnabled = audioRecordingEnabled
        self.injectedAudioTransport = audioTransport
        if modelLibrary != nil { modelStatus = "请在模型库中安装或选择可用模型。" }
    }

    public func clearError() { errorMessage = nil }

    private var draft: ProjectDraft { ProjectDraft(prompt: prompt, randomSeed: randomSeed, seedText: seedText) }

    private func scheduleDraftSave() {
        guard !applyingDraft else { return }
        draftEditVersion &+= 1
        guard let store, let documentID = activeDocumentID, activeDocument?.kind == .image, !isChangingProject, !closePending else { return }
        draftWriter?.cancel()
        let value = draft
        draftWriter = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            guard let self, self.store === store, !Task.isCancelled else { return }
            let write = self.queueDraftWrite(value, documentID: documentID, store: store)
            do {
                let updated = try await write.value
                guard self.store === store else { return }
                self.applyManifest(updated)
                self.draftSaveFailed = false
            } catch {
                guard self.store === store else { return }
                if !self.draftSaveFailed { self.report(error, context: "草稿暂未保存，请恢复项目磁盘访问后重试") }
                self.draftSaveFailed = true
            }
        }
    }

    /// A debounce cancellation must not cancel or overtake an already admitted disk write.
    private func queueDraftWrite(_ value: ProjectDraft, documentID: UUID,
                                 store: ProjectStore) -> Task<ProjectManifest, Error> {
        let preceding = draftWriteTail
        let write = Task {
            if let preceding { await preceding.value }
            return try await store.saveDraft(value, documentID: documentID)
        }
        draftWriteTail = Task { _ = try? await write.value }
        return write
    }

    private func flushDraft(to store: ProjectStore) async throws {
        try await text?.flush()
        // Admission is closed by navigation/close callers, so this is a stable final tail.
        // A selection already issued by the old view must finish before navigation or close.
        await selectionWriteTail?.value
        await metadataWriteTail?.value
        if activeDocument?.kind == .text { return }
        if activeDocument?.kind == .audio {
            try await flushAudioCreation(to: store)
            guard await audio?.flushPendingWrites() != false else {
                throw ProjectStoreError.invalidTransition
            }
            return
        }
        guard let documentID = activeDocumentID else { return }
        draftWriter?.cancel()
        await draftWriter?.value
        draftWriter = nil
        // While saving is suspended, programmatic edits must also survive a navigation.
        repeat {
            let version = draftEditVersion
            let updated = try await queueDraftWrite(draft, documentID: documentID, store: store).value
            applyManifest(updated)
            if version == draftEditVersion { break }
        } while self.store === store && activeDocumentID == documentID
        draftSaveFailed = false
    }

    private func loadActiveDocument() {
        if audioCreationDocumentID != activeDocumentID || activeDocument?.audioCreation == nil {
            audioCreationContextID = UUID()
            audioCreationTransport.stopPlayback()
            audioCreationDocumentID = activeDocument?.audioCreation == nil ? nil : activeDocumentID
            audioCreationDraft = activeDocument?.audioCreation
            audioCreationPersistedRevision = audioCreationDraft?.revision
        }
        if let value = activeDocument?.textDraft, let session, let backendID = session.textBackendID {
            if text?.editor.document.id != value.id {
                let identity = textContextID
                text = ProjectTextController(document: value, engine: session.engine, backendID: backendID) { [weak self] draft, revision in
                    guard let self, self.textContextID == identity, let currentStore = self.store else {
                        throw ProjectStoreError.invalidProject("文字文档所属项目已关闭。")
                    }
                    let updated = try await currentStore.saveTextDraft(draft, documentID: draft.id, expectedRevision: revision)
                    guard self.textContextID == identity else { return }
                    self.applyManifest(updated)
                }
            }
        } else { text = nil }
        if let manifest { audio?.synchronize(manifest) }
        applyingDraft = true
        defer { applyingDraft = false }
        let value = activeDocument?.draft ?? .init()
        prompt = value.prompt
        randomSeed = value.randomSeed
        seedText = value.seedText
        selectedAssetID = activeDocument?.selectedAssetID
        selectionVersion &+= 1
        audio?.resumeAdmissions()
    }

    public func createProject(at url: URL) async {
        guard !isChangingProject, await requestClose() else { return }
        isChangingProject = true
        defer { isChangingProject = false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let candidate = try await ProjectStore.create(at: url, name: url.deletingPathExtension().lastPathComponent)
            try await activate(candidate, selected: url)
        } catch { report(error, context: "无法创建项目") }
    }

    public func openProject(at url: URL) async {
        guard !isChangingProject else { return }
        if url.standardizedFileURL.resolvingSymlinksInPath() == projectURL {
            isChangingProject = true
            defer { isChangingProject = false }
            do {
                let renewed = try await access.acquire(selected: url)
                await access.release(projectLease)
                projectLease = renewed
                settings.set(renewed.bookmark, forKey: Self.projectBookmarkKey)
                isChangingProject = false
                await recoverArtifacts()
            } catch { report(error, context: "无法恢复项目访问权，请连接磁盘并重新选择项目") }
            return
        }
        if let store {
            isChangingProject = true
            do {
                let lease = try await access.acquire(selected: url)
                do {
                    if try await store.matchesLocation(lease.url) {
                        defer { isChangingProject = false }
                        await relocateOpenProject(store, lease: lease)
                        return
                    }
                    await access.release(lease)
                } catch { await access.release(lease); throw error }
            } catch {
                isChangingProject = false
                report(error, context: "无法访问所选项目，请检查磁盘连接和权限")
                return
            }
            isChangingProject = false
        }
        guard await requestClose() else { return }
        isChangingProject = true
        defer { isChangingProject = false }
        do {
            let lease = try await access.acquire(selected: url)
            do {
                let candidate = try await ProjectStore.open(at: lease.url)
                try await activate(candidate, lease: lease)
            } catch {
                await access.release(lease)
                throw error
            }
        } catch { report(error, context: "无法打开项目；请连接外置磁盘或重新选择项目") }
    }

    public func restoreLastProject() async {
        guard manifest == nil, !isChangingProject,
              let bookmark = settings.data(forKey: Self.projectBookmarkKey) else { return }
        isChangingProject = true
        defer { isChangingProject = false }
        do {
            let lease = try await access.restore(bookmark)
            do {
                let candidate = try await ProjectStore.open(at: lease.url)
                try await activate(candidate, lease: lease)
            } catch {
                await access.release(lease)
                throw error
            }
        } catch { report(error, context: "上次的项目无法访问；请连接外置磁盘或使用“打开项目”重新定位") }
    }

    private func activate(_ candidate: ProjectStore, selected: URL) async throws {
        let lease = try await access.acquire(selected: selected)
        do { try await activate(candidate, lease: lease) }
        catch { await access.release(lease); throw error }
    }

    private func relocateOpenProject(_ previousStore: ProjectStore, lease: LocationAccess.Lease) async {
        guard !isRegisteringTextModel, !isRegisteringAudioModel, text?.hasPendingCandidate != true,
              await audio?.prepareForNavigation() != false, await drainForClose() else {
            audio?.resumeAdmissions()
            await access.release(lease)
            errorMessage = "请先完成模型校验并处理文字候选，再重新定位项目。"
            return
        }
        audioCreationTransport.stopPlayback()
        await audioCreationWriteTail?.value
        audioCreationContextID = UUID()
        let previousURL = projectURL
        do {
            let replacement = try await factory(lease.url.appendingPathComponent("Tasks", isDirectory: true))
            let relocated = try await previousStore.relocated(to: lease.url)
            let previousSession = session
            store = relocated
            session = replacement
            projectURL = lease.url
            assetURLs = [:]
            manifest = await relocated.snapshot()
            installAudioController(for: relocated)
            if let backendID = replacement.textBackendID {
                text?.rebind(engine: replacement.engine, backendID: backendID)
            }
            await previousSession?.shutdown()
            // A moved old backend may still own unpublished temporary files. Its path checks
            // deliberately prevent deletion there; leaving those files is safer than guessing.
            await access.release(projectLease)
            projectLease = lease
            settings.set(lease.bookmark, forKey: Self.projectBookmarkKey)
            if let previousURL {
                for (id, outcome) in pendingSaves {
                    guard case .completed(let result) = outcome else { continue }
                    let prefix = previousURL.path + "/"
                    let artifacts = result.artifacts.map { artifact in
                        let url = artifact.url.path.hasPrefix(prefix)
                            ? lease.url.appendingPathComponent(String(artifact.url.path.dropFirst(prefix.count)))
                            : artifact.url
                        return ArtifactReference(url: url, mediaType: artifact.mediaType)
                    }
                    pendingSaves[id] = .completed(InferenceResult(artifacts: artifacts, metadata: result.metadata))
                }
            }
            try await flushDraft(to: relocated)
            for (id, outcome) in pendingSaves {
                try await persist(id: id, outcome: outcome, store: relocated)
                pendingSaves.removeValue(forKey: id)
                phases.removeValue(forKey: id)
                liveStates.removeValue(forKey: id)
            }
            applyManifest(try await relocated.recoverPublishedArtifacts())
            await refreshAssets()
            if let audio, let documentID = activeDocumentID, activeDocument?.kind == .audio {
                _ = await audio.refreshInspection(contextID: audio.contextID, documentID: documentID)
            }
        } catch {
            audio?.resumeAdmissions()
            if projectLease?.id != lease.id { await access.release(lease) }
            report(error, context: "重新定位尚未完成；作品与记录已保留，请检查所选位置后重试")
        }
    }

    private func activate(_ candidate: ProjectStore, lease: LocationAccess.Lease) async throws {
        let createdSession = try await factory(candidate.artifactDirectory)
        textContextID = UUID()
        audioCreationContextID = UUID()
        audioCreationDocumentID = nil
        audioCreationDraft = nil
        text = nil
        store = candidate
        session = createdSession
        projectLease = lease
        projectURL = lease.url
        settings.set(lease.bookmark, forKey: Self.projectBookmarkKey)
        manifest = await candidate.snapshot()
        installAudioController(for: candidate)
        showingAllArtworks = false
        automaticResultSelectionEnabled = true
        loadActiveDocument()
        await refreshAssets()
        await restoreModelSelection(using: createdSession)
        if let bookmark = settings.data(forKey: "workbench.textModelBookmark.v1"), createdSession.validateTextModel != nil {
            do {
                let lease = try await access.restore(bookmark)
                do {
                    textReference = try await createdSession.validateTextModel?(lease.url)
                    textModelLease = lease
                    settings.set(lease.bookmark, forKey: "workbench.textModelBookmark.v1")
                    textModelStatus = (try? TextModelProfiles.status(for: textReference)) ?? "文字模型 · 版本未登记"
                } catch { await access.release(lease); throw error }
            } catch { textModelStatus = "文字模型暂不可用，请重新选择原模型文件夹。" }
        }
        if let bookmark = settings.data(forKey: "workbench.audioModelBookmark.v1"),
           let validate = createdSession.validateAudioModel {
            do {
                let lease = try await access.restore(bookmark)
                do {
                    audioReference = try await validate(lease.url)
                    audioModelLease = lease
                    settings.set(lease.bookmark, forKey: "workbench.audioModelBookmark.v1")
                    audioModelStatus = "本地声音模型已恢复并校验"
                } catch { await access.release(lease); throw error }
            } catch { audioModelStatus = "声音模型暂不可用，请重新选择原模型文件夹" }
        } else if createdSession.audioBackendID == nil {
            audioModelStatus = "本地声音引擎尚未配置；已有作品仍可查看和导出"
        }
    }

    private func installAudioController(for audioStore: ProjectStore) {
        audio?.deactivateAfterClose()
        guard audioEnabled, let manifest else { audio = nil; return }
        let contextID = UUID()
        let transport = injectedAudioTransport ?? AudioTransport(recordingEnabled: audioRecordingEnabled)
        audio = ProjectAudioController(contextID: contextID, store: audioStore,
                                       transport: transport,
                                       recordingEnabled: audioRecordingEnabled) { [weak self] updated in
            guard let self, self.audio?.contextID == contextID else { return }
            let previousDocumentID = self.activeDocumentID
            self.applyManifest(updated)
            if previousDocumentID != self.activeDocumentID { self.loadActiveDocument() }
        }
        audio?.synchronize(manifest)
    }

    private func restoreModelSelection(using runtime: WorkbenchSession) async {
        if let modelLibrary {
            do {
                if let value = settings.string(forKey: Self.selectedModelKey), let rawID = UUID(uuidString: value) {
                    try await applyModelSelection(ModelID(rawValue: rawID), library: modelLibrary)
                } else if let bookmark = settings.data(forKey: Self.modelBookmarkKey) {
                    modelStatus = "正在将已有模型登记到模型库，并校验完整权重。"
                    let previous = try await access.restore(bookmark)
                    do {
                        let id = try await modelLibrary.registerExisting(at: previous.url)
                        await access.release(previous)
                        try await applyModelSelection(id, library: modelLibrary)
                        settings.removeObject(forKey: Self.modelBookmarkKey)
                    } catch { await access.release(previous); throw error }
                }
            } catch {
                modelStatus = "模型不可用，请在模型库中重新授权或选择模型。已有作品仍可查看和导出。"
            }
            return
        }
        // Legacy hosts without a ModelLibrary still supply an explicit backend validator.
        // The production application injects ModelLibrary and never takes this branch.
        if let bookmark = settings.data(forKey: Self.modelBookmarkKey) {
            do {
                let model = try await access.restore(bookmark)
                do {
                    try await runtime.validateModel(model.url)
                    modelLease = model
                    modelName = model.url.lastPathComponent
                    settings.set(model.bookmark, forKey: Self.modelBookmarkKey)
                    modelStatus = "本地模型已登记；生成前会检查全部权重。"
                } catch { await access.release(model); throw error }
            } catch {
                modelStatus = "模型不可用，请重新选择模型文件夹。已有作品仍可查看和导出。"
            }
        }
    }

    public func selectModel(id: ModelID) async {
        guard let modelLibrary, !isChangingProject, !closePending else { return }
        isChangingProject = true
        defer { isChangingProject = false }
        do { try await applyModelSelection(id, library: modelLibrary) }
        catch { report(error, context: "无法使用所选模型，请检查安装状态和磁盘访问权") }
    }

    private func applyModelSelection(_ id: ModelID, library: ModelLibrary) async throws {
        let reference = try await library.resolve(id)
        let profile = try await library.profile(for: id)
        let snapshot = await library.snapshot()
        await access.release(modelLease)
        modelLease = nil
        selectedModelID = id
        selectedModelRevision = reference.revision
        selectedModelReady = true
        imageProfile = profile
        modelName = snapshot.records.first(where: { $0.id == id }).map {
            Self.modelTitle(for: $0, in: snapshot)
        } ?? reference.directory.lastPathComponent
        modelStatus = "模型库已校验此模型；生成前会检查全部权重。"
        settings.set(id.rawValue.uuidString, forKey: Self.selectedModelKey)
        startModelReadinessPolling(id: id, library: library)
    }

    private static func modelTitle(for record: ModelRecord, in snapshot: ModelLibrarySnapshot) -> String {
        snapshot.catalog.first(where: { $0.id == record.catalogID })?.title ?? record.catalogID
    }

    private func startModelReadinessPolling(id: ModelID, library: ModelLibrary) {
        modelPoller?.cancel()
        modelPoller = Task { [weak self] in
            while !Task.isCancelled {
                let snapshot = await library.snapshot()
                guard let self, !Task.isCancelled, self.selectedModelID == id else { return }
                if let record = snapshot.records.first(where: { $0.id == id }) {
                    self.selectedModelReady = record.state == .installed && record.availability == .available
                    self.modelName = Self.modelTitle(for: record, in: snapshot)
                    if self.selectedModelReady {
                        self.modelStatus = "模型库已校验此模型；生成前会检查全部权重。"
                    } else if record.availability == .needsAuthorization {
                        self.modelStatus = "所选模型需要重新授权，请在模型库中重新选择它的位置。"
                    } else if record.availability == .unavailable {
                        self.modelStatus = "所选模型所在磁盘不可用。请连接磁盘；已有作品仍可查看和导出。"
                    } else {
                        self.modelStatus = "所选模型尚未安装并校验完成，请在模型库中检查进度。"
                    }
                } else {
                    self.selectedModelReady = false
                    self.modelStatus = "所选模型已从模型库移除，请重新选择可用模型。"
                }
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            }
        }
    }

    public func registerModel(at url: URL) async {
        guard !isBusy, !isChangingProject, !closePending else { return }
        isChangingProject = true
        defer { isChangingProject = false }
        do {
            if let modelLibrary {
                let id = try await modelLibrary.registerExisting(at: url)
                try await applyModelSelection(id, library: modelLibrary)
                return
            }
            guard let session else { return }
            let candidate = try await access.acquire(selected: url)
            do { try await session.validateModel(candidate.url) }
            catch { await access.release(candidate); throw error }
            await access.release(modelLease)
            modelLease = candidate
            selectedModelID = nil
            selectedModelRevision = nil
            selectedModelReady = false
            imageProfile = .flux2Klein
            modelName = candidate.url.lastPathComponent
            modelStatus = "本地模型已登记；生成前会检查全部权重。"
            settings.set(candidate.bookmark, forKey: Self.modelBookmarkKey)
        } catch { report(error, context: "无法登记此模型；请选择完整的 FLUX.2 Klein 4B q8 文件夹") }
    }

    /// Capture all editable values before the first suspension, then persist before admission.
    public func generate() async {
        guard canGenerate, let store, let session, let documentID = activeDocumentID else { return }
        let seed: UInt64
        if randomSeed { seed = UInt64.random(in: .min ... .max) }
        else if let parsed = UInt64(seedText.trimmingCharacters(in: .whitespacesAndNewlines)) { seed = parsed }
        else { errorMessage = "Seed 必须是 0 到 18446744073709551615 之间的整数。"; return }
        let id = UUID()
        let input = imageProfile.request(prompt: prompt, seed: seed)
        let savedDraft = queueDraftWrite(draft, documentID: documentID, store: store)
        draftWriter?.cancel()
        let selectedID = selectedModelID
        let legacyReference = modelLease.map { ModelReference(directory: $0.url) }
        activeJobIDs.insert(id)
        liveStates[id] = .queued
        phases[id] = "正在保存任务"
        startPolling()
        let preceding = admissionTail
        let admission = Task { [self] in
            if let preceding { await preceding.value }
            do {
                let reference: ModelReference
                if let selectedID, let modelLibrary {
                    let lease = try await modelLibrary.acquire(selectedID)
                    usageLeases[id] = lease
                    reference = lease.reference
                } else if let legacyReference {
                    reference = legacyReference
                } else {
                    throw ModelLibraryError.unavailable("尚未选择可用模型。")
                }
                let request = InferenceRequest(id: id, model: reference, input: .image(input))
                await admit(request, documentID: documentID, savedDraft: savedDraft, store: store, session: session)
            } catch {
                await removeActive(id)
                phases.removeValue(forKey: id)
                liveStates.removeValue(forKey: id)
                report(error, context: "模型当前不可用，因此没有开始生成")
            }
        }
        admissionTail = admission
        await admission.value
    }

    private func admit(_ request: InferenceRequest, documentID: UUID,
                       savedDraft: Task<ProjectManifest, Error>, store: ProjectStore, session: WorkbenchSession,
                       backendID: String? = nil) async {
        do {
            applyManifest(try await savedDraft.value)
            applyManifest(try await store.enqueue(request: request, documentID: documentID))
            if cancellationRequests.contains(request.id) {
                await finish(id: request.id, outcome: .cancelled, store: store)
                return
            }
            let run = try await session.engine.submit(request, backendID: backendID ?? session.backendID)
            handles[run.id] = run
            phases[run.id] = cancellationRequests.contains(run.id) ? "正在取消" : "排队中"
            // This task belongs to the workbench, not to a SwiftUI view's lifetime.
            workers[run.id] = Task { [self] in
                do {
                    for try await event in run.events {
                        if case .progress(let completed, let total) = event, total > 0 {
                            progress[run.id] = min(1, max(0, Double(completed) / Double(total)))
                        }
                    }
                } catch {
                    // The authoritative outcome follows release, even after stream failure.
                }
                let outcome = await run.outcome()
                await finish(id: run.id, outcome: outcome, store: store)
            }
            if cancellationRequests.contains(run.id) { await run.cancel() }
        } catch {
            let failure = (error as? InferenceFailure) ?? .backendFailed(error.localizedDescription)
            if (await store.snapshot()).jobs.contains(where: { $0.id == request.id }) {
                await finish(id: request.id, outcome: .failed(failure), store: store)
            } else {
                await removeActive(request.id)
                phases.removeValue(forKey: request.id)
                liveStates.removeValue(forKey: request.id)
                report(error, context: "任务未能保存，因此没有开始生成")
            }
        }
    }

    public func cancel(_ id: UUID) async {
        guard activeJobIDs.contains(id) else { return }
        cancellationRequests.insert(id)
        audioAdmissions[id]?.cancel()
        liveStates[id] = .cancelling
        phases[id] = "正在取消，等待计算结束并释放资源"
        if let run = handles[id] { await run.cancel() }
    }

    private func finish(id: UUID, outcome: RunOutcome, store: ProjectStore) async {
        liveStates[id] = .saving
        phases[id] = "正在保存作品与记录"
        do {
            try await persist(id: id, outcome: outcome, store: store)
            pendingSaves.removeValue(forKey: id)
        } catch {
            pendingSaves[id] = outcome
            phases[id] = "保存未完成，请连接磁盘后重试恢复"
            report(error, context: "计算已结束，但记录尚未保存。作品文件会保留；请使用“恢复作品”重试")
        }
        await removeActive(id)
        if pendingSaves[id] == nil { phases.removeValue(forKey: id); liveStates.removeValue(forKey: id) }
        await refreshAssets()
    }

    private func persist(id: UUID, outcome: RunOutcome, store: ProjectStore) async throws {
        switch outcome {
        case .completed(let result):
            let origin = manifest?.jobs.first(where: { $0.id == id })?.documentID
            let selection = selectionVersion
            applyManifest(try await store.complete(id: id, result: result))
            if automaticResultSelectionEnabled, activeDocument?.kind == .image, !showingAllArtworks, origin == activeDocumentID, selection == selectionVersion,
               let assetID = manifest?.jobs.first(where: { $0.id == id })?.artifactIDs.first {
                await selectAsset(assetID)
            }
        case .cancelled:
            applyManifest(try await store.updateJob(id: id, state: .cancelled))
        case .failed(let failure):
            applyManifest(try await store.updateJob(id: id, state: .failed, error: failure.localizedDescription))
            report(failure, context: "生成失败")
        }
    }

    private func removeActive(_ id: UUID) async {
        // The authoritative run outcome has drained and released compute before this point.
        // Hold the library lease through cancellation, then release before declaring the job idle.
        if let lease = usageLeases.removeValue(forKey: id), let modelLibrary {
            await modelLibrary.release(lease)
        }
        activeJobIDs.remove(id)
        handles.removeValue(forKey: id)
        workers.removeValue(forKey: id)
        cancellationRequests.remove(id)
        if activeJobIDs.isEmpty { poller?.cancel(); poller = nil }
    }

    private func startPolling() {
        guard poller == nil, let session else { return }
        poller = Task { [weak self] in
            while !Task.isCancelled {
                let snapshot = await session.status()
                guard let self, !Task.isCancelled else { return }
                for id in snapshot.queuedRunIDs where self.activeJobIDs.contains(id)
                    && !self.cancellationRequests.contains(id) && self.liveStates[id] != .saving {
                    self.phases[id] = "排队中"
                    self.liveStates[id] = .queued
                }
                if let id = snapshot.activeRunID, self.activeJobIDs.contains(id), self.liveStates[id] != .saving {
                    self.phases[id] = self.cancellationRequests.contains(id)
                        ? "正在取消，等待计算结束并释放资源" : (snapshot.phase ?? "正在生成")
                    self.liveStates[id] = self.cancellationRequests.contains(id) ? .cancelling : (snapshot.state ?? .generating)
                }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
        }
    }

    public func recoverArtifacts() async {
        guard let store, !isBusy, !isChangingProject else { return }
        isChangingProject = true
        defer { isChangingProject = false }
        do {
            try await flushDraft(to: store)
            for (id, outcome) in pendingSaves {
                try await persist(id: id, outcome: outcome, store: store)
                pendingSaves.removeValue(forKey: id)
                phases.removeValue(forKey: id)
                liveStates.removeValue(forKey: id)
            }
            applyManifest(try await store.recoverPublishedArtifacts())
            await refreshAssets()
        } catch { report(error, context: "恢复尚未完成，请确认项目磁盘可用且允许写入") }
    }

    /// Compatibility entry point: reuse always creates a separate creative document.
    public func copySettings(from jobID: UUID) async {
        guard let assetID = manifest?.jobs.first(where: { $0.id == jobID })?.artifactIDs.first else { return }
        await forkDocument(from: assetID)
    }

    public func createDocument(name: String = "新创作") async {
        guard navigationReady() else { return }
        guard let store, !isChangingProject, !closePending else { return }
        isChangingProject = true
        defer { isChangingProject = false }
        do {
            try await prepareAudioNavigation()
            try await flushDraft(to: store)
            applyManifest(try await store.createDocument(name: name))
            showingAllArtworks = false
            loadActiveDocument()
        } catch { audio?.resumeAdmissions(); report(error, context: "无法新建创作；当前输入已保留") }
    }

    /// Imports into project ownership and switches only after all current editor state is safe.
    public func importAudio(at url: URL, name: String) async -> Bool {
        guard navigationReady(), let store, let audio, !isChangingProject, !closePending else { return false }
        isChangingProject = true
        defer { isChangingProject = false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            try await prepareAudioNavigation()
            try await flushDraft(to: store)
            let contextID = audio.contextID
            let updated = try await store.importAudio(at: url, name: name)
            guard self.store === store, self.audio?.contextID == contextID else {
                audio.resumeAdmissions(); return false
            }
            applyManifest(updated)
            showingAllArtworks = false
            loadActiveDocument()
            guard let documentID = activeDocumentID else { return false }
            return await audio.refreshInspection(contextID: contextID, documentID: documentID)
        } catch {
            audio.resumeAdmissions()
            report(error, context: "原声导入失败；来源和当前文档均已保留")
            return false
        }
    }

    public func startAudioRecording(name: String) async -> Bool {
        guard audioRecordingEnabled else {
            errorMessage = "无法开始录音。\n当前项目会话未启用录音能力。"
            return false
        }
        guard navigationReady(), let store, let audio, !isChangingProject, !closePending else { return false }
        do { try await flushDraft(to: store) }
        catch { report(error, context: "当前文档尚未安全保存，不能开始录音"); return false }
        let result = await audio.startRecording(name: name)
        if !result, let message = audio.errorMessage { errorMessage = message }
        return result
    }

    public func finishAudioRecording() async -> Bool {
        guard let audio, !isChangingProject, !closePending else { return false }
        let result = await audio.finishRecording()
        if !result, let message = audio.errorMessage { errorMessage = message }
        return result
    }

    public func retryPendingAudioCapture(id: UUID) async -> Bool {
        guard !isTextWorking, !isRegisteringTextModel, text?.hasPendingCandidate != true,
              let store, let audio, !isChangingProject, !closePending else { return false }
        isChangingProject = true
        defer { isChangingProject = false }
        guard await audio.prepareForRecovery(id: id) else {
            if let message = audio.errorMessage { errorMessage = message }
            return false
        }
        do { try await flushDraft(to: store) }
        catch {
            audio.resumeAdmissions()
            report(error, context: "当前文档尚未安全保存，不能恢复录音")
            return false
        }
        let result = await audio.retryPendingCapture(id: id)
        if !result {
            audio.resumeAdmissions()
            if let message = audio.errorMessage { errorMessage = message }
        }
        return result
    }

    @discardableResult
    public func keepPendingAudioCaptureForRecovery(id: UUID) -> Bool {
        guard !isChangingProject, !closePending else { return false }
        return audio?.keepPendingCaptureForRecovery(id: id) ?? false
    }

    @discardableResult
    public func setAudioNoteInput(_ value: String, contextID: UUID, documentID: UUID) -> Bool {
        guard !isChangingProject, !closePending else { return false }
        return audio?.setNoteInput(value, contextID: contextID, documentID: documentID) ?? false
    }

    @discardableResult
    public func setAudioClipInput(name: String, range: AudioFrameRange?, note: String = "",
                                  contextID: UUID, documentID: UUID) -> Bool {
        guard !isChangingProject, !closePending else { return false }
        return audio?.setClipInput(name: name, range: range, note: note,
                                   contextID: contextID, documentID: documentID) ?? false
    }

    @discardableResult
    public func discardAudioEditorInput(contextID: UUID, documentID: UUID) -> Bool {
        guard !isChangingProject, !closePending else { return false }
        return audio?.discardUnsubmittedInput(contextID: contextID, documentID: documentID) ?? false
    }

    public func saveAudioNote(contextID: UUID, documentID: UUID) async -> Bool {
        guard !isChangingProject, !closePending else { return false }
        return await audio?.saveNote(contextID: contextID, documentID: documentID) ?? false
    }

    public func addAudioClip(contextID: UUID, documentID: UUID) async -> Bool {
        guard !isChangingProject, !closePending else { return false }
        return await audio?.addClip(contextID: contextID, documentID: documentID) ?? false
    }

    public func selectFullAudio(contextID: UUID, documentID: UUID) async -> Bool {
        guard !isChangingProject, !closePending else { return false }
        return await audio?.selectFullAudio(contextID: contextID, documentID: documentID) ?? false
    }

    public func selectAudioClip(id: UUID, contextID: UUID, documentID: UUID) async -> Bool {
        guard !isChangingProject, !closePending else { return false }
        return await audio?.selectClip(id: id, contextID: contextID, documentID: documentID) ?? false
    }

    public func refreshActiveAudioInspection(contextID: UUID, documentID: UUID) async -> Bool {
        guard !isChangingProject, !closePending else { return false }
        return await audio?.refreshInspection(contextID: contextID, documentID: documentID) ?? false
    }

    public func prepareAudioPlayback(range: AudioFrameRange? = nil,
                                     contextID: UUID, documentID: UUID) async -> Bool {
        guard !isChangingProject, !closePending else { return false }
        return await audio?.preparePlayback(range: range, contextID: contextID,
                                            documentID: documentID) ?? false
    }

    public func exportOriginalAudio(to url: URL, contextID: UUID, documentID: UUID) async -> Bool {
        guard !isChangingProject, !closePending else { return false }
        return await audio?.exportOriginal(to: url, contextID: contextID, documentID: documentID) ?? false
    }

    public func exportAudioClip(id: UUID, to url: URL,
                                contextID: UUID, documentID: UUID) async -> Bool {
        guard !isChangingProject, !closePending else { return false }
        return await audio?.exportClip(id: id, to: url, contextID: contextID, documentID: documentID) ?? false
    }

    public func exportAudioRange(_ range: AudioFrameRange, to url: URL,
                                 contextID: UUID, documentID: UUID) async -> Bool {
        guard !isChangingProject, !closePending else { return false }
        return await audio?.exportRange(range, to: url, contextID: contextID,
                                        documentID: documentID) ?? false
    }

    public func prepareRecipePNG(assetID: UUID, disclosure: RecipeDisclosure) async throws -> Data {
        guard let store, !isChangingProject, !closePending else { throw ProjectStoreError.invalidTransition }
        return try await store.prepareRecipePNG(assetID: assetID, disclosure: disclosure)
    }

    public func createRecipeDocument(_ recipe: GenerationRecipe, expectedProjectID: UUID) async -> Bool {
        guard navigationReady() else { return false }
        guard let store, manifest?.id == expectedProjectID, !isChangingProject, !closePending else { return false }
        isChangingProject = true
        defer { isChangingProject = false }
        do {
            try await prepareAudioNavigation()
            try await flushDraft(to: store)
            applyManifest(try await store.createRecipeDocument(recipe))
            showingAllArtworks = false
            loadActiveDocument()
            return true
        } catch { audio?.resumeAdmissions(); report(error, context: "无法从配方新建创作；当前输入已保留"); return false }
    }

    public func renameDocument(id: UUID, name: String) async {
        guard let store, !isChangingProject, !closePending else { return }
        isChangingProject = true
        defer { isChangingProject = false }
        do { applyManifest(try await store.renameDocument(id: id, name: name)) }
        catch { report(error, context: "创作名称未能保存") }
    }

    public func selectDocument(id: UUID) async {
        guard navigationReady() else { return }
        guard let store, !isChangingProject, !closePending else { return }
        isChangingProject = true
        defer { isChangingProject = false }
        do {
            try await prepareAudioNavigation()
            try await flushDraft(to: store)
            applyManifest(try await store.selectDocument(id: id))
            showingAllArtworks = false
            loadActiveDocument()
        } catch { audio?.resumeAdmissions(); report(error, context: "草稿未能安全保存，仍留在当前创作") }
    }

    public func showAllArtworks() async {
        guard navigationReady() else { return }
        guard let store, !isChangingProject, !closePending else { return }
        isChangingProject = true
        defer { isChangingProject = false }
        do {
            try await prepareAudioNavigation()
            try await flushDraft(to: store)
            showingAllArtworks = true
            selectionVersion &+= 1
            audio?.resumeAdmissions()
        } catch { audio?.resumeAdmissions(); report(error, context: "草稿未能安全保存，仍留在当前创作") }
    }

    public func selectAsset(_ id: UUID?) async {
        guard let store, !isChangingProject, !closePending else { return }
        if let id, !visibleAssets.contains(where: { $0.id == id }) { return }
        selectionVersion &+= 1
        let version = selectionVersion
        if showingAllArtworks { selectedAssetID = id; return }
        guard let documentID = activeDocumentID else { return }
        let preceding = selectionWriteTail
        let write = Task {
            if let preceding { await preceding.value }
            return try await store.setSelectedAsset(id, documentID: documentID)
        }
        selectionWriteTail = Task { _ = try? await write.value }
        do {
            let updated = try await write.value
            guard self.store === store else { return }
            applyManifest(updated)
            if activeDocumentID == documentID, !showingAllArtworks, version == selectionVersion {
                selectedAssetID = id
            }
        } catch { report(error, context: "作品选择未能保存") }
    }

    private func queueMetadataWrite(
        _ operation: @escaping @Sendable () async throws -> ProjectManifest
    ) -> Task<ProjectManifest, Error> {
        let preceding = metadataWriteTail
        let write = Task {
            if let preceding { await preceding.value }
            return try await operation()
        }
        metadataWriteTail = Task { _ = try? await write.value }
        return write
    }

    public func updateCandidate(assetID: UUID, name: String? = nil, isFavorite: Bool? = nil, note: String? = nil) async {
        guard let store, !isChangingProject, !closePending else { return }
        let write = queueMetadataWrite {
            try await store.updateAsset(id: assetID, name: name, note: note, isFavorite: isFavorite)
        }
        do { applyManifest(try await write.value) }
        catch { report(error, context: "作品名称、收藏或备注未能保存") }
    }

    public func adoptAsset(id: UUID) async {
        guard let store, !isChangingProject, !closePending,
              let asset = manifest?.assets.first(where: { $0.id == id }),
              let owner = manifest?.jobs.first(where: { $0.id == asset.jobID })?.documentID else { return }
        let write = queueMetadataWrite { try await store.adoptAsset(id: id, documentID: owner) }
        do { applyManifest(try await write.value) }
        catch { report(error, context: "采用状态未能保存") }
    }

    public func clearAdoptedAsset(documentID: UUID) async {
        guard let store, !isChangingProject, !closePending else { return }
        let write = queueMetadataWrite { try await store.adoptAsset(id: nil, documentID: documentID) }
        do { applyManifest(try await write.value) }
        catch { report(error, context: "取消采用未能保存") }
    }

    public func forkCompatibilityWarning(for assetID: UUID) -> String? {
        guard let asset = manifest?.assets.first(where: { $0.id == assetID }),
              let job = manifest?.jobs.first(where: { $0.id == asset.jobID }),
              case .image(let image) = job.request.input else {
            return "此作品缺少可复用的图像生成条件。"
        }
        guard image.width == imageProfile.width, image.height == imageProfile.height,
              image.steps == imageProfile.steps, image.guidanceScale == imageProfile.guidanceScale,
              let revision = job.request.model.revision, revision == selectedModelRevision else {
            return "原作品的模型版本或参数与当前模型不同，或无法确认。继续将只复用提示词和实际 Seed，并使用当前模型及其参数；不能保证得到相同图片。"
        }
        return nil
    }

    public func forkDocument(from assetID: UUID, acknowledgeCurrentModel: Bool = false) async {
        guard navigationReady() else { return }
        guard let store, !isChangingProject, !closePending,
              let asset = manifest?.assets.first(where: { $0.id == assetID }),
              let job = manifest?.jobs.first(where: { $0.id == asset.jobID }),
              case .image(let image) = job.request.input else { return }
        if let warning = forkCompatibilityWarning(for: assetID), !acknowledgeCurrentModel {
            errorMessage = warning
            return
        }
        isChangingProject = true
        defer { isChangingProject = false }
        do {
            try await prepareAudioNavigation()
            try await flushDraft(to: store)
            let value = ProjectDraft(prompt: image.prompt, randomSeed: false, seedText: String(image.seed))
            applyManifest(try await store.createDocument(name: "从作品继续", draft: value, sourceAssetID: assetID))
            showingAllArtworks = false
            loadActiveDocument()
        } catch { audio?.resumeAdmissions(); report(error, context: "无法从作品新建创作；当前输入已保留") }
    }

    public func canCancel(_ id: UUID) -> Bool {
        activeJobIDs.contains(id) && !cancellationRequests.contains(id)
        && liveStates[id] != .saving && liveStates[id] != .releasing
    }

    /// A reusable application operation; the caller chooses a destination and grants access.
    public func export(assetID: UUID, to url: URL) async {
        guard let store, !isChangingProject else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do { try await store.export(assetID: assetID, to: url) }
        catch { report(error, context: "导出失败；请使用新文件名并检查目标磁盘") }
    }

    private func refreshAssets() async {
        guard let store, let manifest else { return }
        var urls: [UUID: URL] = [:]
        var firstFailure: Error?
        for asset in manifest.assets {
            do { urls[asset.id] = try await store.assetURL(for: asset) }
            catch { if firstFailure == nil { firstFailure = error } }
        }
        guard self.store === store, self.manifest?.id == manifest.id,
              self.manifest?.assets == manifest.assets else { return }
        assetURLs = urls
        if let firstFailure { report(firstFailure, context: "部分作品暂时无法读取，请检查项目所在磁盘") }
    }

    private func applyManifest(_ updated: ProjectManifest) {
        // Actor calls can resume out of order on the main executor. A stale snapshot must not
        // hide a later saved artwork or queued request.
        guard manifest?.id == updated.id, updated.revision >= (manifest?.revision ?? 0) else { return }
        manifest = updated
        audio?.synchronize(updated)
    }

    public func closeProject() async { _ = await requestClose() }

    /// Used by project switching and native window/application close delegates.
    public func requestClose(decision: ProjectCloseDecision? = nil) async -> Bool {
        if isRegisteringTextModel || isRegisteringAudioModel { return false }
        if text?.hasPendingCandidate == true {
            errorMessage = "请先接受或拒绝文字候选，再关闭项目。正文可以随时保存。"
            return false
        }
        guard !isChangingProject, !closePending else { return false }
        closePending = true
        isChangingProject = true
        defer { closePending = false; isChangingProject = false }
        guard await audio?.prepareForNavigation() != false else {
            if let message = audio?.errorMessage { errorMessage = message }
            return false
        }
        guard await drainForClose(decision: decision) else { audio?.resumeAdmissions(); return false }
        return await closeDrainedProject()
    }

    private func drainForClose(decision: ProjectCloseDecision? = nil) async -> Bool {
        if isBusy {
            let selected = if let decision { decision } else { await closeDecision() }
            if selected == .keepOpen { return false }
            if selected == .cancel {
                await cancelTextRewrite()
                for id in activeJobIDs { await cancel(id) }
            }
            while isBusy { try? await Task.sleep(for: .milliseconds(100)) }
        }
        return true
    }

    /// A deterministic action for harnesses/tests that have already chosen to cancel.
    public func cancelAndCloseProject() async -> Bool {
        guard !isRegisteringTextModel, !isRegisteringAudioModel, !isChangingProject, !closePending else { return false }
        closePending = true
        isChangingProject = true
        defer { closePending = false; isChangingProject = false }
        guard await audio?.prepareForNavigation() != false else {
            if let message = audio?.errorMessage { errorMessage = message }
            return false
        }
        await cancelTextRewrite()
        for id in activeJobIDs { await cancel(id) }
        while isBusy { try? await Task.sleep(for: .milliseconds(100)) }
        return await closeDrainedProject()
    }

    private func closeDrainedProject() async -> Bool {
        if text?.hasPendingCandidate == true {
            errorMessage = "请先接受或拒绝文字候选，再关闭项目。"
            return false
        }
        guard let store else {
            modelPoller?.cancel()
            modelPoller = nil
            return true
        }
        do {
            try await flushDraft(to: store)
            for (id, outcome) in pendingSaves {
                try await persist(id: id, outcome: outcome, store: store)
                pendingSaves.removeValue(forKey: id)
            }
            if let session {
                try await session.cleanup()
            }
            // There are no unsaved drafts or terminal outcomes now. If another editor changed
            // the manifest, closing preserves their bytes; the next open validates that file.
            try await store.close(preserveExternalChanges: true)
            // Admission stays closed during this entire operation. Preserve a usable runtime
            // if a preceding disk/cleanup operation fails and the user needs to retry.
            if let session { await session.shutdown() }
            audio?.deactivateAfterClose()
            audioCreationTransport.shutdown()
            await access.release(audioModelLease)
            audioModelLease = nil
            audioReference = nil
            audioCreationContextID = UUID()
            audioCreationDocumentID = nil
            audioCreationDraft = nil
            audioCreationPersistedRevision = nil
            audioModelStatus = "选择已安装的本地声音模型"
            audio = nil
            self.store = nil
            session = nil
            await access.release(textModelLease)
            textModelLease = nil
            textReference = nil
            textContextID = UUID()
            text = nil
            textModelStatus = "选择已注册的 Qwen2.5 Instruct 4-bit 模型（0.5B／1.5B／7B／32B）"
            await access.release(modelLease)
            await access.release(projectLease)
            projectLease = nil
            modelLease = nil
            modelName = nil
            selectedModelID = nil
            selectedModelRevision = nil
            selectedModelReady = false
            modelPoller?.cancel()
            modelPoller = nil
            imageProfile = .flux2Klein
            modelStatus = modelLibrary == nil ? "请选择已安装的 FLUX.2 Klein 4B q8 模型文件夹。" : "请在模型库中安装或选择可用模型。"
            manifest = nil
            showingAllArtworks = false
            projectURL = nil
            selectedAssetID = nil
            assetURLs = [:]
            phases = [:]
            progress = [:]
            liveStates = [:]
            return true
        } catch {
            audio?.resumeAdmissions()
            report(error, context: "项目尚未安全保存，暂不能关闭。请恢复磁盘访问后重试")
            return false
        }
    }


    private func navigationReady() -> Bool {
        guard !isTextWorking, !isRegisteringTextModel, !isRegisteringAudioModel, text?.hasPendingCandidate != true else {
            errorMessage = "请先取消并等待改写结束，或接受／拒绝文字候选，再切换文档。"
            return false
        }
        if let message = audio?.navigationBlockMessage {
            errorMessage = message
            return false
        }
        return true
    }

    private func prepareAudioNavigation() async throws {
        audioCreationTransport.stopPlayback()
        guard await audio?.prepareForNavigation() != false else {
            throw ProjectStoreError.invalidTransition
        }
    }

    public func createTextDocument(name: String = "新文稿") async {
        guard navigationReady(), let store, !isChangingProject, !closePending,
              session?.textBackendID != nil else { return }
        isChangingProject = true
        defer { isChangingProject = false }
        do {
            try await prepareAudioNavigation()
            try await flushDraft(to: store)
            applyManifest(try await store.createTextDocument(name: name))
            showingAllArtworks = false
            loadActiveDocument()
        } catch { audio?.resumeAdmissions(); report(error, context: "无法新建文稿，当前输入已保留") }
    }

    public func editText(_ value: String, documentID: UUID) {
        guard !isChangingProject, !closePending, activeDocumentID == documentID else { return }
        text?.edit(value, documentID: documentID)
    }
    public func selectText(_ range: NSRange, documentID: UUID) {
        guard !isChangingProject, !closePending, activeDocumentID == documentID else { return }
        text?.select(range, documentID: documentID)
    }
    public func saveText() async {
        do { try await text?.flush() }
        catch { report(error, context: "正文尚未保存，输入仍在当前窗口") }
    }
    public func registerTextModel(at url: URL) async {
        guard !isBusy, !isChangingProject, !closePending, !isRegisteringTextModel,
              let validator = session?.validateTextModel else { return }
        isRegisteringTextModel = true
        defer { isRegisteringTextModel = false }
        do {
            let lease = try await access.acquire(selected: url)
            do {
                let reference = try await validator(lease.url)
                await access.release(textModelLease)
                textModelLease = lease
                textReference = reference
                settings.set(lease.bookmark, forKey: "workbench.textModelBookmark.v1")
                textModelStatus = (try? TextModelProfiles.status(for: reference)) ?? "文字模型 · 版本未登记"
            } catch { await access.release(lease); throw error }
        } catch { report(error, context: "文字模型未能登记，未下载或更改任何权重") }
    }
    public func rewriteText() async {
        guard canRewriteText, let controller = text, let reference = textReference,
              let validator = session?.validateTextModel else { return }
        isTextWorking = true
        let work = Task { [self] in
            defer { isTextWorking = false; textWork = nil }
            await controller.rewrite(using: reference) { reference in
                try await validator(reference.directory)
            }
        }
        textWork = work
        await work.value
    }
    public func cancelTextRewrite() async {
        let work = textWork
        work?.cancel()
        await text?.cancel()
        await work?.value
    }

    // AW1: generation documents share the authoritative runtime and project task journal.
    public var audioCreationCandidates: [ProjectAsset] {
        guard activeDocument?.audioCreation != nil, let manifest else { return [] }
        let jobs = Set(documentJobs.map(\.id))
        return manifest.assets.filter { $0.mediaType == "audio/wav" && $0.jobID.map(jobs.contains) == true }
    }
    public var audioCreationSource: ProjectAsset? {
        guard let id = activeDocument?.sourceAssetID else { return nil }
        return manifest?.assets.first { $0.id == id && $0.metadata.audio != nil }
    }
    public var canGenerateAudioCreation: Bool {
        audioEnabled && audioCreationDraft != nil && audioReference != nil && session?.audioBackendID != nil
            && !isBusy && !isChangingProject && !closePending && !isRegisteringAudioModel && pendingSaves.isEmpty
            && !showingAllArtworks
    }
    public var audioCreationSaveStatus: String {
        audioCreationDraft?.revision == audioCreationPersistedRevision ? "创作条件已保存" : "创作条件尚未保存"
    }

    public func updateAudioCreationDraft(_ value: AudioCreationDraft, contextID: UUID, documentID: UUID) {
        guard contextID == audioCreationContextID, documentID == activeDocumentID,
              activeDocument?.audioCreation != nil, !isBusy, !isChangingProject, !closePending,
              var previous = audioCreationDraft else { return }
        let decisions = previous.rejectedAssetIDs
        previous = value
        previous.rejectedAssetIDs = decisions
        previous.revision = UUID()
        audioCreationDraft = previous
    }

    private func queueAudioCreationSave(_ value: AudioCreationDraft, documentID: UUID,
                                       store: ProjectStore) -> Task<ProjectManifest, Error> {
        let preceding = audioCreationWriteTail
        let context = audioCreationContextID
        let write = Task { [self] in
            if let preceding { await preceding.value }
            guard self.store === store, context == audioCreationContextID else { throw CancellationError() }
            let snapshot = await store.snapshot()
            guard let current = snapshot.documents.first(where: { $0.id == documentID })?.audioCreation else {
                throw ProjectStoreError.missingDocument
            }
            // A previously accepted decision cannot be overwritten by stale editor input.
            guard current.rejectedAssetIDs == value.rejectedAssetIDs else {
                throw ProjectStoreError.externalModification
            }
            let result: ProjectManifest
            if current == value { result = snapshot }
            else {
                guard documentID == audioCreationDocumentID,
                      current.revision == audioCreationPersistedRevision else {
                    throw ProjectStoreError.externalModification
                }
                result = try await store.saveAudioCreation(value, documentID: documentID,
                                                          expectedRevision: current.revision)
            }
            guard self.store === store, context == audioCreationContextID else { throw CancellationError() }
            applyManifest(result)
            if audioCreationDocumentID == documentID { audioCreationPersistedRevision = value.revision }
            return result
        }
        audioCreationWriteTail = Task { _ = try? await write.value }
        return write
    }

    private func flushAudioCreation(to store: ProjectStore) async throws {
        guard let documentID = audioCreationDocumentID, documentID == activeDocumentID else { return }
        repeat {
            guard let value = audioCreationDraft else { return }
            _ = try await queueAudioCreationSave(value, documentID: documentID, store: store).value
            if audioCreationDraft?.revision == value.revision { return }
        } while self.store === store && activeDocumentID == documentID
    }

    @discardableResult public func saveAudioCreation(contextID: UUID, documentID: UUID) async -> Bool {
        guard contextID == audioCreationContextID, documentID == activeDocumentID,
              let store, !isChangingProject, !closePending else { return false }
        do { try await flushAudioCreation(to: store); return true }
        catch { report(error, context: "声音创作尚未保存，原件与输入均保留"); return false }
    }

    public func createAudioCreation(sourceAssetID: UUID? = nil) async {
        guard audioEnabled, navigationReady(), let store, !isChangingProject, !closePending else { return }
        isChangingProject = true
        defer { isChangingProject = false }
        do {
            audioCreationTransport.stopPlayback()
            try await prepareAudioNavigation()
            try await flushDraft(to: store)
            applyManifest(try await store.createAudioCreation(sourceAssetID: sourceAssetID))
            showingAllArtworks = false
            loadActiveDocument()
        } catch { audio?.resumeAdmissions(); report(error, context: "声音创作未能新建；已有作品未改变") }
    }

    public func registerAudioModel(at url: URL) async {
        guard let session, let validate = session.validateAudioModel, !isBusy,
              !isChangingProject, !closePending, !isRegisteringAudioModel else {
            errorMessage = "本地声音引擎尚未就绪，当前没有开始加载或生成。"
            return
        }
        isRegisteringAudioModel = true
        defer { isRegisteringAudioModel = false }
        let context = audioCreationContextID
        do {
            let lease = try await access.acquire(selected: url)
            do {
                let reference = try await validate(lease.url)
                guard context == audioCreationContextID else { throw CancellationError() }
                await access.release(audioModelLease)
                audioModelLease = lease
                audioReference = reference
                settings.set(lease.bookmark, forKey: "workbench.audioModelBookmark.v1")
                audioModelStatus = "本地声音模型已校验；支持提示生成、参考变体和区间重绘"
            } catch { await access.release(lease); throw error }
        } catch { report(error, context: "声音模型未能就绪，已有作品保持不变") }
    }

    public func generateAudioCreation(contextID: UUID, documentID: UUID) async {
        guard contextID == audioCreationContextID, documentID == activeDocumentID,
              canGenerateAudioCreation, let value = audioCreationDraft,
              let reference = audioReference, let store, let session,
              let backendID = session.audioBackendID else { return }
        let sourceID = activeDocument?.sourceAssetID
        let id = UUID()
        let saved = queueAudioCreationSave(value, documentID: documentID, store: store)
        activeJobIDs.insert(id)
        liveStates[id] = .queued
        phases[id] = "正在保存声音任务"
        audioCreationTransport.stopPlayback()
        startPolling()
        let preceding = admissionTail
        audioAdmissionDocuments[id] = documentID
        let admission = Task { [self] in
            defer {
                audioAdmissions.removeValue(forKey: id)
                audioAdmissionDocuments.removeValue(forKey: id)
            }
            if let preceding { await preceding.value }
            do {
                try Task.checkCancellation()
                _ = try await saved.value
                try Task.checkCancellation()
                let source: AudioSourceReference?
                if value.operation == .generate { source = nil }
                else {
                    guard let sourceID else { throw AudioMediaError.unavailable("此操作需要参考原声") }
                    source = try await store.prepareAudioCreationSource(assetID: sourceID, runID: id)
                }
                try Task.checkCancellation()
                let input = try value.makeRequest(source: source)
                let request = InferenceRequest(id: id, model: reference, input: .audio(input))
                await admit(request, documentID: documentID, savedDraft: saved, store: store,
                            session: session, backendID: backendID)
            } catch {
                await removeActive(id)
                phases.removeValue(forKey: id)
                liveStates.removeValue(forKey: id)
                report(error, context: "声音任务未提交，原声和已有候选没有改变")
            }
        }
        audioAdmissions[id] = admission
        admissionTail = admission
        await admission.value
    }

    public func cancelAudioCreation(contextID: UUID, documentID: UUID) async {
        guard contextID == audioCreationContextID, documentID == activeDocumentID else { return }
        let journalIDs = Set(documentJobs.map(\.id))
        let ids = activeJobIDs.filter {
            journalIDs.contains($0) || audioAdmissionDocuments[$0] == documentID
        }
        for id in ids { await cancel(id) }
    }

    public func mutateAudioCreationCandidate(_ action: AudioCreationCandidateAction,
                                             contextID: UUID, documentID: UUID) async {
        guard contextID == audioCreationContextID, documentID == activeDocumentID,
              activeDocument?.audioCreation != nil, let store, !isBusy,
              !isChangingProject, !closePending else { return }
        isChangingProject = true
        defer { isChangingProject = false }
        do {
            try await flushAudioCreation(to: store)
            let updated: ProjectManifest
            switch action {
            case .select(let id): updated = try await store.setSelectedAsset(id, documentID: documentID)
            case .adopt(let id): updated = try await store.adoptAsset(id: id, documentID: documentID)
            case .reject(let id, let rejected):
                updated = try await store.setAudioCandidateRejected(id: id, rejected: rejected, documentID: documentID)
            }
            guard contextID == audioCreationContextID, self.store === store else { return }
            applyManifest(updated)
            audioCreationDraft = activeDocument?.audioCreation
            audioCreationPersistedRevision = audioCreationDraft?.revision
            selectedAssetID = activeDocument?.selectedAssetID
        } catch { report(error, context: "候选选择未保存，原件与已有作品均保留") }
    }

    public func playAudioCreationAsset(id: UUID, contextID: UUID, documentID: UUID) async {
        guard contextID == audioCreationContextID, documentID == activeDocumentID,
              !isBusy, !isChangingProject, !closePending, let store,
              let asset = ([audioCreationSource].compactMap { $0 } + audioCreationCandidates).first(where: { $0.id == id }) else { return }
        do {
            let inspection = try await store.inspectAudioAsset(id: id)
            let url = try await store.assetURL(for: asset)
            guard contextID == audioCreationContextID, documentID == activeDocumentID, self.store === store,
                  !isChangingProject, !closePending else { return }
            audio?.transport.stopPlayback()
            try audioCreationTransport.preparePlayback(url: url, format: inspection.format,
                policy: asset.metadata.audio?.origin == .modelGenerated ? .generated : .original)
            try audioCreationTransport.play()
        } catch { report(error, context: "试听未开始；文件没有改变") }
    }

    public func exportAudioCreationAsset(id: UUID, to url: URL, contextID: UUID, documentID: UUID) async {
        guard contextID == audioCreationContextID, documentID == activeDocumentID, let store,
              !isChangingProject, !closePending,
              id == audioCreationSource?.id || audioCreationCandidates.contains(where: { $0.id == id }) else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do { try await store.exportAudioAsset(id: id, to: url) }
        catch { report(error, context: "声音导出未完成，原件与已有目标未被覆盖") }
    }

    private func report(_ error: Error, context: String) {
        errorMessage = "\(context)。\n\(error.localizedDescription)"
    }
}
