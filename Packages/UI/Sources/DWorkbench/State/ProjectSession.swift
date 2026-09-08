import DInference
import Foundation
import Observation

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
        if showingAllArtworks { return manifest.assets }
        let jobs = Set(documentJobs.map(\.id))
        return manifest.assets.filter { $0.id == activeDocument?.sourceAssetID || $0.jobID.map(jobs.contains) == true }
    }
    public var errorMessage: String?
    public private(set) var isChangingProject = false
    public private(set) var phases: [UUID: String] = [:]
    public private(set) var progress: [UUID: Double] = [:]
    public private(set) var liveStates: [UUID: JobState] = [:]
    public private(set) var assetURLs: [UUID: URL] = [:]
    public private(set) var activeJobIDs: Set<UUID> = []
    public private(set) var text: ProjectTextController?
    public private(set) var textModelStatus = "选择已安装的 Qwen2.5 0.5B Instruct 4-bit 文件夹。"
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
    public var isBusy: Bool { !activeJobIDs.isEmpty || isTextWorking }
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
                closeDecision: @escaping @MainActor @Sendable () async -> ProjectCloseDecision = { .keepOpen }) {
        self.closeDecision = closeDecision
        self.factory = sessionFactory
        self.settings = settings
        self.modelLibrary = modelLibrary
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
        applyingDraft = true
        defer { applyingDraft = false }
        let value = activeDocument?.draft ?? .init()
        prompt = value.prompt
        randomSeed = value.randomSeed
        seedText = value.seedText
        selectedAssetID = activeDocument?.selectedAssetID
        selectionVersion &+= 1
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
        guard !isRegisteringTextModel, await drainForClose(), text?.hasPendingCandidate != true else {
            await access.release(lease)
            errorMessage = "请先完成模型校验并处理文字候选，再重新定位项目。"
            return
        }
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
        } catch {
            if projectLease?.id != lease.id { await access.release(lease) }
            report(error, context: "重新定位尚未完成；作品与记录已保留，请检查所选位置后重试")
        }
    }

    private func activate(_ candidate: ProjectStore, lease: LocationAccess.Lease) async throws {
        let createdSession = try await factory(candidate.artifactDirectory)
        textContextID = UUID()
        text = nil
        store = candidate
        session = createdSession
        projectLease = lease
        projectURL = lease.url
        settings.set(lease.bookmark, forKey: Self.projectBookmarkKey)
        manifest = await candidate.snapshot()
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
                    textModelStatus = FixedTextModel.title + " · 已校验"
                } catch { await access.release(lease); throw error }
            } catch { textModelStatus = "文字模型暂不可用，请重新选择原模型文件夹。" }
        }
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
                       savedDraft: Task<ProjectManifest, Error>, store: ProjectStore, session: WorkbenchSession) async {
        do {
            applyManifest(try await savedDraft.value)
            applyManifest(try await store.enqueue(request: request, documentID: documentID))
            if cancellationRequests.contains(request.id) {
                await finish(id: request.id, outcome: .cancelled, store: store)
                return
            }
            let run = try await session.engine.submit(request, backendID: session.backendID)
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
            if automaticResultSelectionEnabled, !showingAllArtworks, origin == activeDocumentID, selection == selectionVersion,
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
        guard textNavigationReady() else { return }
        guard let store, !isChangingProject, !closePending else { return }
        isChangingProject = true
        defer { isChangingProject = false }
        do {
            try await flushDraft(to: store)
            applyManifest(try await store.createDocument(name: name))
            showingAllArtworks = false
            loadActiveDocument()
        } catch { report(error, context: "无法新建创作；当前输入已保留") }
    }

    public func prepareRecipePNG(assetID: UUID, disclosure: RecipeDisclosure) async throws -> Data {
        guard let store, !isChangingProject, !closePending else { throw ProjectStoreError.invalidTransition }
        return try await store.prepareRecipePNG(assetID: assetID, disclosure: disclosure)
    }

    public func createRecipeDocument(_ recipe: GenerationRecipe, expectedProjectID: UUID) async -> Bool {
        guard textNavigationReady() else { return false }
        guard let store, manifest?.id == expectedProjectID, !isChangingProject, !closePending else { return false }
        isChangingProject = true
        defer { isChangingProject = false }
        do {
            try await flushDraft(to: store)
            applyManifest(try await store.createRecipeDocument(recipe))
            showingAllArtworks = false
            loadActiveDocument()
            return true
        } catch { report(error, context: "无法从配方新建创作；当前输入已保留"); return false }
    }

    public func renameDocument(id: UUID, name: String) async {
        guard let store, !isChangingProject, !closePending else { return }
        isChangingProject = true
        defer { isChangingProject = false }
        do { applyManifest(try await store.renameDocument(id: id, name: name)) }
        catch { report(error, context: "创作名称未能保存") }
    }

    public func selectDocument(id: UUID) async {
        guard textNavigationReady() else { return }
        guard let store, !isChangingProject, !closePending else { return }
        isChangingProject = true
        defer { isChangingProject = false }
        do {
            try await flushDraft(to: store)
            applyManifest(try await store.selectDocument(id: id))
            showingAllArtworks = false
            loadActiveDocument()
        } catch { report(error, context: "草稿未能安全保存，仍留在当前创作") }
    }

    public func showAllArtworks() async {
        guard textNavigationReady() else { return }
        guard let store, !isChangingProject, !closePending else { return }
        isChangingProject = true
        defer { isChangingProject = false }
        do {
            try await flushDraft(to: store)
            showingAllArtworks = true
            selectionVersion &+= 1
        } catch { report(error, context: "草稿未能安全保存，仍留在当前创作") }
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
        guard textNavigationReady() else { return }
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
            try await flushDraft(to: store)
            let value = ProjectDraft(prompt: image.prompt, randomSeed: false, seedText: String(image.seed))
            applyManifest(try await store.createDocument(name: "从作品继续", draft: value, sourceAssetID: assetID))
            showingAllArtworks = false
            loadActiveDocument()
        } catch { report(error, context: "无法从作品新建创作；当前输入已保留") }
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
    }

    public func closeProject() async { _ = await requestClose() }

    /// Used by project switching and native window/application close delegates.
    public func requestClose(decision: ProjectCloseDecision? = nil) async -> Bool {
        if isRegisteringTextModel { return false }
        if text?.hasPendingCandidate == true {
            errorMessage = "请先接受或拒绝文字候选，再关闭项目。正文可以随时保存。"
            return false
        }
        guard !isChangingProject, !closePending else { return false }
        closePending = true
        isChangingProject = true
        defer { closePending = false; isChangingProject = false }
        guard await drainForClose(decision: decision) else { return false }
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
        guard !isRegisteringTextModel, !isChangingProject, !closePending else { return false }
        closePending = true
        isChangingProject = true
        defer { closePending = false; isChangingProject = false }
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
            self.store = nil
            session = nil
            await access.release(textModelLease)
            textModelLease = nil
            textReference = nil
            textContextID = UUID()
            text = nil
            textModelStatus = "选择已安装的 Qwen2.5 0.5B Instruct 4-bit 文件夹。"
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
            report(error, context: "项目尚未安全保存，暂不能关闭。请恢复磁盘访问后重试")
            return false
        }
    }


    private func textNavigationReady() -> Bool {
        guard !isTextWorking, !isRegisteringTextModel, text?.hasPendingCandidate != true else {
            errorMessage = "请先取消并等待改写结束，或接受／拒绝文字候选，再切换文档。"
            return false
        }
        return true
    }

    public func createTextDocument(name: String = "新文稿") async {
        guard textNavigationReady(), let store, !isChangingProject, !closePending,
              session?.textBackendID != nil else { return }
        isChangingProject = true
        defer { isChangingProject = false }
        do {
            try await flushDraft(to: store)
            applyManifest(try await store.createTextDocument(name: name))
            showingAllArtworks = false
            loadActiveDocument()
        } catch { report(error, context: "无法新建文稿，当前输入已保留") }
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
                textModelStatus = FixedTextModel.title + " · 已校验"
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

    private func report(_ error: Error, context: String) {
        errorMessage = "\(context)。\n\(error.localizedDescription)"
    }
}
