import AppKit
import DInference
import Foundation
import Observation
import UniformTypeIdentifiers

/// The application owns jobs, including while their views are absent.
/// Only the composition root constructs an inference implementation.
@MainActor @Observable
public final class WorkbenchModel {
    public private(set) var manifest: ProjectManifest?
    public private(set) var projectURL: URL?
    public private(set) var modelName: String?
    public private(set) var modelStatus = "请选择已安装的 FLUX.2 Klein 4B q8 模型文件夹。"
    public var prompt = "" { didSet { scheduleDraftSave() } }
    public var randomSeed = true { didSet { scheduleDraftSave() } }
    public var seedText = "0" { didSet { scheduleDraftSave() } }
    public var selectedAssetID: UUID?
    public var errorMessage: String?
    public private(set) var isChangingProject = false
    public private(set) var phases: [UUID: String] = [:]
    public private(set) var progress: [UUID: Double] = [:]
    public private(set) var liveStates: [UUID: JobState] = [:]
    public private(set) var assetURLs: [UUID: URL] = [:]
    public private(set) var activeJobIDs: Set<UUID> = []
    public var isBusy: Bool { !activeJobIDs.isEmpty }
    public var canGenerate: Bool {
        manifest != nil && modelLease != nil && !isChangingProject && !isChoosingLocation && !closePending && pendingSaves.isEmpty
        && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && activeJobIDs.count < 8
    }
    public var selectedAsset: ProjectAsset? { manifest?.assets.first { $0.id == selectedAssetID } }
    public var selectedJob: ProjectJob? {
        guard let asset = selectedAsset else { return nil }
        return manifest?.jobs.first { $0.id == asset.jobID }
    }

    @ObservationIgnored private let factory: @Sendable (URL) async throws -> WorkbenchSession
    @ObservationIgnored private let settings: UserDefaults
    @ObservationIgnored private let access = LocationAccess()
    @ObservationIgnored private var projectLease: LocationAccess.Lease?
    @ObservationIgnored private var modelLease: LocationAccess.Lease?
    @ObservationIgnored private var store: ProjectStore?
    @ObservationIgnored private var session: WorkbenchSession?
    @ObservationIgnored private var handles: [UUID: InferenceRun] = [:]
    @ObservationIgnored private var workers: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var cancellationRequests: Set<UUID> = []
    @ObservationIgnored private var pendingSaves: [UUID: RunOutcome] = [:]
    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private var draftWriter: Task<Void, Never>?
    @ObservationIgnored private var draftSaveFailed = false
    @ObservationIgnored private var admissionTail: Task<Void, Never>?
    @ObservationIgnored private var closePending = false
    private var isChoosingLocation = false
    private static let projectBookmarkKey = "workbench.projectBookmark.v1"
    private static let modelBookmarkKey = "workbench.modelBookmark.v1"

    public init(sessionFactory: @escaping @Sendable (URL) async throws -> WorkbenchSession,
                settings: UserDefaults = .standard) {
        self.factory = sessionFactory
        self.settings = settings
    }

    public func clearError() { errorMessage = nil }

    private var draft: ProjectDraft { ProjectDraft(prompt: prompt, randomSeed: randomSeed, seedText: seedText) }

    private func scheduleDraftSave() {
        guard store != nil, !isChangingProject, !closePending else { return }
        draftWriter?.cancel()
        draftWriter = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            guard let self, let store = self.store else { return }
            let value = self.draft
            do {
                let updated = try await store.saveDraft(value)
                guard self.store === store else { return }
                self.applyManifest(updated)
                self.draftSaveFailed = false
            } catch {
                guard self.store === store, !Task.isCancelled else { return }
                if !self.draftSaveFailed { self.report(error, context: "草稿暂未保存，请恢复项目磁盘访问后重试") }
                self.draftSaveFailed = true
            }
        }
    }

    private func flushDraft(to store: ProjectStore) async throws {
        draftWriter?.cancel()
        await draftWriter?.value
        draftWriter = nil
        applyManifest(try await store.saveDraft(draft))
        draftSaveFailed = false
    }

    public func newProject() async {
        guard !isChangingProject, !isChoosingLocation else { return }
        isChoosingLocation = true
        defer { isChoosingLocation = false }
        let panel = NSSavePanel()
        panel.title = "新建 D 项目"
        panel.nameFieldStringValue = "未命名.dproject"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [UTType(filenameExtension: "dproject") ?? .package]
        panel.isExtensionHidden = false
        guard await panel.begin() == .OK, let url = panel.url else { return }
        isChoosingLocation = false
        await createProject(at: url)
    }

    public func openProject() async {
        guard !isChangingProject, !isChoosingLocation else { return }
        isChoosingLocation = true
        defer { isChoosingLocation = false }
        let panel = NSOpenPanel()
        panel.title = "打开 D 项目"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "dproject") ?? .package]
        panel.allowsMultipleSelection = false
        guard await panel.begin() == .OK, let url = panel.url else { return }
        isChoosingLocation = false
        await openProject(at: url)
    }

    public func createProject(at url: URL) async {
        guard !isChangingProject, !isChoosingLocation, await requestClose() else { return }
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
        guard !isChangingProject, !isChoosingLocation else { return }
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
        guard await drainForClose() else { await access.release(lease); return }
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
        store = candidate
        session = createdSession
        projectLease = lease
        projectURL = lease.url
        settings.set(lease.bookmark, forKey: Self.projectBookmarkKey)
        manifest = await candidate.snapshot()
        prompt = manifest?.draft.prompt ?? ""
        randomSeed = manifest?.draft.randomSeed ?? true
        seedText = manifest?.draft.seedText ?? "0"
        selectedAssetID = manifest?.assets.last?.id
        await refreshAssets()
        if let bookmark = settings.data(forKey: Self.modelBookmarkKey) {
            do {
                let model = try await access.restore(bookmark)
                do {
                    try await createdSession.validateModel(model.url)
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

    public func registerModel() async {
        guard manifest != nil, !isBusy, !isChangingProject, !isChoosingLocation else { return }
        isChoosingLocation = true
        defer { isChoosingLocation = false }
        let panel = NSOpenPanel()
        panel.title = "选择 FLUX.2 Klein 4B q8 模型文件夹"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard await panel.begin() == .OK, let url = panel.url else { return }
        isChoosingLocation = false
        await registerModel(at: url)
    }

    public func registerModel(at url: URL) async {
        guard let session, !isBusy, !isChangingProject else { return }
        isChangingProject = true
        defer { isChangingProject = false }
        do {
            let candidate = try await access.acquire(selected: url)
            do { try await session.validateModel(candidate.url) }
            catch { await access.release(candidate); throw error }
            await access.release(modelLease)
            modelLease = candidate
            modelName = candidate.url.lastPathComponent
            modelStatus = "本地模型已登记；生成前会检查全部权重。"
            settings.set(candidate.bookmark, forKey: Self.modelBookmarkKey)
        } catch { report(error, context: "无法登记此模型；请选择完整的 FLUX.2 Klein 4B q8 文件夹") }
    }

    /// Capture all editable values before the first suspension, then persist before admission.
    public func generate() async {
        guard canGenerate, let store, let session, let modelLease else { return }
        let seed: UInt64
        if randomSeed { seed = UInt64.random(in: .min ... .max) }
        else if let parsed = UInt64(seedText.trimmingCharacters(in: .whitespacesAndNewlines)) { seed = parsed }
        else { errorMessage = "Seed 必须是 0 到 18446744073709551615 之间的整数。"; return }
        let request = InferenceRequest(model: ModelReference(directory: modelLease.url),
            input: .image(ImageRequest(prompt: prompt, width: 512, height: 512, steps: 4,
                                       guidanceScale: 1, seed: seed)))
        activeJobIDs.insert(request.id)
        liveStates[request.id] = .queued
        phases[request.id] = "正在保存任务"
        startPolling()
        let preceding = admissionTail
        let admission = Task { [self] in
            if let preceding { await preceding.value }
            await admit(request, store: store, session: session)
        }
        admissionTail = admission
        await admission.value
    }

    private func admit(_ request: InferenceRequest, store: ProjectStore, session: WorkbenchSession) async {
        do {
            try await flushDraft(to: store)
            applyManifest(try await store.enqueue(request: request))
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
                removeActive(request.id)
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
        removeActive(id)
        if pendingSaves[id] == nil { phases.removeValue(forKey: id); liveStates.removeValue(forKey: id) }
        await refreshAssets()
    }

    private func persist(id: UUID, outcome: RunOutcome, store: ProjectStore) async throws {
        switch outcome {
        case .completed(let result):
            applyManifest(try await store.complete(id: id, result: result))
            selectedAssetID = manifest?.jobs.first(where: { $0.id == id })?.artifactIDs.first
        case .cancelled:
            applyManifest(try await store.updateJob(id: id, state: .cancelled))
        case .failed(let failure):
            applyManifest(try await store.updateJob(id: id, state: .failed, error: failure.localizedDescription))
            report(failure, context: "生成失败")
        }
    }

    private func removeActive(_ id: UUID) {
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

    public func copySettings(from jobID: UUID) async {
        guard let job = manifest?.jobs.first(where: { $0.id == jobID }), case .image(let image) = job.request.input else { return }
        prompt = image.prompt
        randomSeed = false
        seedText = String(image.seed)
    }

    public func canCancel(_ id: UUID) -> Bool {
        activeJobIDs.contains(id) && !cancellationRequests.contains(id)
        && liveStates[id] != .saving && liveStates[id] != .releasing
    }

    public func exportSelected() async {
        guard let id = selectedAssetID, let store, !isChoosingLocation, !isChangingProject else { return }
        isChoosingLocation = true
        defer { isChoosingLocation = false }
        let panel = NSSavePanel()
        panel.title = "导出 PNG"
        panel.nameFieldStringValue = "D-\(id.uuidString.prefix(8)).png"
        panel.allowedContentTypes = [.png]
        guard await panel.begin() == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do { try await store.export(assetID: id, to: url) }
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
    public func requestClose() async -> Bool {
        guard !isChangingProject, !isChoosingLocation, !closePending else { return false }
        closePending = true
        isChangingProject = true
        defer { closePending = false; isChangingProject = false }
        guard await drainForClose() else { return false }
        return await closeDrainedProject()
    }

    private func drainForClose() async -> Bool {
        if isBusy {
            let alert = NSAlert()
            alert.messageText = "项目还有运行中或排队的任务"
            alert.informativeText = "关闭前需要等待任务结束并保存记录。取消也需要等待当前计算释放资源。"
            alert.addButton(withTitle: "等待完成后关闭")
            alert.addButton(withTitle: "取消任务后关闭")
            alert.addButton(withTitle: "继续编辑")
            let response = alert.runModal()
            if response == .alertThirdButtonReturn { return false }
            if response == .alertSecondButtonReturn {
                for id in activeJobIDs { await cancel(id) }
            }
            while isBusy { try? await Task.sleep(for: .milliseconds(100)) }
        }
        return true
    }

    /// A deterministic action for harnesses/tests that have already chosen to cancel.
    public func cancelAndCloseProject() async -> Bool {
        guard !isChangingProject, !closePending else { return false }
        closePending = true
        isChangingProject = true
        defer { closePending = false; isChangingProject = false }
        for id in activeJobIDs { await cancel(id) }
        while isBusy { try? await Task.sleep(for: .milliseconds(100)) }
        return await closeDrainedProject()
    }

    private func closeDrainedProject() async -> Bool {
        guard let store else { return true }
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
            await access.release(modelLease)
            await access.release(projectLease)
            projectLease = nil
            modelLease = nil
            modelName = nil
            modelStatus = "请选择已安装的 FLUX.2 Klein 4B q8 模型文件夹。"
            manifest = nil
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

    private func report(_ error: Error, context: String) {
        errorMessage = "\(context)。\n\(error.localizedDescription)"
    }
}
