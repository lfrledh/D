import DInference
import CryptoKit
import Darwin
import Foundation
import ImageIO
import zlib

/// Internal fault injection points exercise actual durable migration boundaries in CPU tests.
enum ProjectMigrationCheckpoint: Sendable { case backupDurable, beforePublication, publicationDurable }
enum ProjectExportCheckpoint: Sendable { case contentDurable(URL), published(URL) }

/// Owns durable project records and media. Its actor keeps file I/O off the UI executor.
/// The lock prevents two application sessions from silently replacing each other's manifest.
public actor ProjectStore {
    public nonisolated let rootURL: URL
    public nonisolated var artifactDirectory: URL { rootURL.appendingPathComponent("Tasks", isDirectory: true) }
    public static let manifestFilename = "project.json"
    public static let versionOneBackupFilename = "project.v1.backup.json"
    public static let versionTwoBackupFilename = "project.v2.backup.json"
    public static let versionThreeBackupFilename = "project.v3.backup.json"
    public static let versionFourBackupFilename = "project.v4.backup.json"
    public static let versionFiveBackupFilename = "project.v5.backup.json"
    public static let versionSixBackupFilename = "project.v6.backup.json"
    public static let versionSevenBackupFilename = "project.v7.backup.json"
    public static let versionEightBackupFilename = "project.v8.backup.json"
    public static let versionNineBackupFilename = "project.v9.backup.json"
    public static let versionTenBackupFilename = "project.v10.backup.json"
    private let rootFD: Int32
    private let lockFD: Int32
    private var manifest: ProjectManifest
    private var isClosed = false
    private let emptyWorkflowRevision = UUID()
    private var captureDirectories: [UUID: Int32] = [:]
    private var preparedImageReferences: [UUID: (assetID: UUID, reference: ImageReference)] = [:]

    private init(rootURL: URL, rootFD: Int32, lockFD: Int32, manifest: ProjectManifest, invalidatedPitchRuns: Set<UUID> = []) {
        self.rootURL = rootURL
        self.rootFD = rootFD
        self.lockFD = lockFD
        self.manifest = manifest
        self.invalidatedPitchRuns = invalidatedPitchRuns
    }

    deinit {
        for descriptor in captureDirectories.values { Darwin.close(descriptor) }
        if !isClosed {
            // A child may temporarily hold a pre-exec copy even with CLOEXEC. This
            // session owns the lock; descriptor lifetime alone is not its lifetime.
            try? ProjectFiles.unlock(lockFD)
            Darwin.close(lockFD); Darwin.close(rootFD)
        }
    }

    public static func create(at url: URL, name: String) async throws -> ProjectStore {
        let root = try ProjectFiles.projectURL(url)
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProjectStoreError.invalidProject("项目名称不能为空。")
        }
        let parent = try ProjectFiles.openDirectory(root.deletingLastPathComponent())
        defer { Darwin.close(parent) }
        guard mkdirat(parent, root.lastPathComponent, 0o700) == 0 else {
            if errno == EEXIST { throw ProjectStoreError.alreadyExists(root.path) }
            throw ProjectFiles.error()
        }
        let descriptor = openat(parent, root.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw ProjectFiles.error() }
        do {
            let lock = try ProjectFiles.lock(in: descriptor)
            do {
                guard mkdirat(descriptor, "Tasks", 0o700) == 0 else { throw ProjectFiles.error() }
                guard mkdirat(descriptor, "Audio", 0o700) == 0 else { throw ProjectFiles.error() }
                let initial = ProjectManifest(name: name)
                try ProjectFiles.writeManifest(initial, in: descriptor, replacing: false)
                return ProjectStore(rootURL: root, rootFD: descriptor, lockFD: lock, manifest: initial)
            } catch {
                try? ProjectFiles.unlock(lock)
                Darwin.close(lock)
                throw error
            }
        } catch { Darwin.close(descriptor); throw error }
    }

    public static func open(at url: URL) async throws -> ProjectStore {
        try await open(at: url, migrationCheckpoint: nil)
    }

    static func open(at url: URL, migrationCheckpoint: (@Sendable (ProjectMigrationCheckpoint) throws -> Void)?) async throws -> ProjectStore {
        let root = try ProjectFiles.projectURL(url)
        let descriptor = try ProjectFiles.openDirectory(root)
        var lock: Int32 = -1
        var transferred = false
        defer {
            if !transferred {
                if lock >= 0 {
                    // A descriptor copy can outlive this failed opener. Release our
                    // acquired lock explicitly, just as normal close/deinit do.
                    try? ProjectFiles.unlock(lock)
                    Darwin.close(lock)
                }
                Darwin.close(descriptor)
            }
        }
        lock = try ProjectFiles.lock(in: descriptor)
        let data = try ProjectFiles.read(relative: manifestFilename, in: descriptor, limit: 32 * 1_024 * 1_024)
        struct Header: Decodable { let schemaVersion: Int }
        let decoder = JSONDecoder()
        let header: Header
        do { header = try decoder.decode(Header.self, from: data) }
        catch { throw ProjectStoreError.invalidProject("项目清单不是有效的 JSON。") }
        guard ProjectManifest.readableSchemaVersions.contains(header.schemaVersion) else {
            throw ProjectStoreError.unsupportedSchema(header.schemaVersion)
        }
        var loaded: ProjectManifest
        do { loaded = try decoder.decode(ProjectManifest.self, from: data) }
        catch { throw ProjectStoreError.invalidProject("项目清单缺少必要字段或已经损坏。") }
        let tasks = try ProjectFiles.openRelativeDirectory("Tasks", in: descriptor)
        Darwin.close(tasks)
        if loaded.schemaVersion == 1 {
            loaded = try ProjectFiles.migrateVersionOne(loaded, original: data, in: descriptor,
                                                      checkpoint: migrationCheckpoint)
        } else if loaded.schemaVersion == 2 {
            loaded = try ProjectFiles.migrateVersionTwo(loaded, original: data, in: descriptor,
                                                      checkpoint: migrationCheckpoint)
        } else if loaded.schemaVersion == 3 {
            loaded = try ProjectFiles.migrateVersionThree(loaded, original: data, in: descriptor,
                                                        checkpoint: migrationCheckpoint)
        } else if loaded.schemaVersion == 4 {
            loaded = try ProjectFiles.migrateVersionFour(loaded, original: data, in: descriptor,
                                                       checkpoint: migrationCheckpoint)
        } else if loaded.schemaVersion == 5 {
            loaded = try ProjectFiles.migrateVersionFive(loaded, original: data, in: descriptor,
                                                       checkpoint: migrationCheckpoint)
        } else if loaded.schemaVersion == 6 {
            loaded = try ProjectFiles.migrateVersionSix(loaded, original: data, in: descriptor,
                                                      checkpoint: migrationCheckpoint)
        } else if loaded.schemaVersion == 7 {
            loaded = try ProjectFiles.migrateVersionSeven(loaded, original: data, in: descriptor, checkpoint: migrationCheckpoint)
        } else if loaded.schemaVersion == 8 {
            loaded = try ProjectFiles.migrateVersionEight(loaded, original: data, in: descriptor, checkpoint: migrationCheckpoint)
        } else if loaded.schemaVersion == 9 {
            loaded = try ProjectFiles.migrateVersionNine(loaded, original: data, in: descriptor, checkpoint: migrationCheckpoint)
        } else if loaded.schemaVersion == 10 {
            loaded = try ProjectFiles.migrateVersionTen(loaded, original: data, in: descriptor, checkpoint: migrationCheckpoint)
        } else if loaded.schemaVersion == 11 {
            loaded = try ProjectFiles.migrateVersionEleven(loaded, original: data, in: descriptor, checkpoint: migrationCheckpoint)
        } else if loaded.schemaVersion == 12 {
            loaded = try ProjectFiles.migrateVersionTwelve(loaded, original: data, in: descriptor, checkpoint: migrationCheckpoint)
        } else { try ProjectFiles.validate(loaded) }
        let store = ProjectStore(rootURL: root, rootFD: descriptor, lockFD: lock, manifest: loaded)
        // Ownership of both descriptors has moved to the actor before recovery can throw.
        transferred = true
        return try await store.recoverOnOpen()
    }

    public func snapshot() -> ProjectManifest { manifest }

    /// Copies one immutable original into project ownership before attaching it.
    public func importImageReference(at source: URL, name: String, documentID: UUID) throws -> ProjectManifest {
        try checkLocation()
        let index = try documentIndex(documentID)
        guard manifest.documents[index].kind == .image, source.isFileURL,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProjectStoreError.invalidProject("请选择图像文档和本地参考 PNG。")
        }
        let parent = try ProjectFiles.openDirectory(source.deletingLastPathComponent())
        defer { Darwin.close(parent) }
        let data = try ProjectFiles.read(relative: source.lastPathComponent, in: parent, limit: 64 * 1024 * 1024)
        let pixels = try ImageReferencePixels.decodePNG(data)
        let id = UUID()
        let root = try ProjectFiles.openOrCreateDirectory("Images", in: rootFD)
        defer { Darwin.close(root) }
        guard mkdirat(root, id.uuidString, 0o700) == 0 else { throw ProjectFiles.error() }
        let directory = try ProjectFiles.openRelativeDirectory(id.uuidString, in: root)
        defer { Darwin.close(directory) }
        try ProjectFiles.publish(in: directory, name: "original.png", replacing: false) { fd in
            try data.withUnsafeBytes { try ProjectFiles.writeAll($0, to: fd) }
        }
        guard fsync(root) == 0 else { throw ProjectFiles.error() }
        var candidate = manifest
        candidate.assets.append(ProjectAsset(id: id, relativePath: "Images/\(id.uuidString)/original.png",
            role: .original, metadata: .init(width: pixels.width, height: pixels.height,
                                           imageContentSHA256: pixels.sourceSHA256), name: name))
        clearDetachedReferenceSelection(in: &candidate, index: index)
        candidate.documents[index].draft.referenceImageAssetID = id
        try commit(candidate)
        return manifest
    }

    public func setImageReference(_ assetID: UUID?, documentID: UUID) throws -> ProjectManifest {
        try checkLocation()
        let index = try documentIndex(documentID)
        guard manifest.documents[index].kind == .image else { throw ProjectStoreError.missingAsset }
        var candidate = manifest
        clearDetachedReferenceSelection(in: &candidate, index: index)
        if let assetID {
            let (assetIndex, pixels) = try imageReferencePixels(assetID)
            candidate.assets[assetIndex].metadata.imageContentSHA256 = pixels.sourceSHA256
        }
        candidate.documents[index].draft.referenceImageAssetID = assetID
        try commit(candidate)
        return manifest
    }

    private func imageReferencePixels(_ assetID: UUID) throws -> (Int, ImageReferencePixels) {
        guard let index = manifest.assets.firstIndex(where: { $0.id == assetID }),
              manifest.assets[index].mediaType == "image/png" else { throw ProjectStoreError.missingAsset }
        let asset = manifest.assets[index]
        let bytes = try ProjectFiles.read(relative: asset.relativePath, in: rootFD, limit: 64 * 1024 * 1024)
        let pixels = try ImageReferencePixels.decodePNG(bytes)
        if let expected = asset.metadata.imageContentSHA256, pixels.sourceSHA256 != expected {
            throw ProjectStoreError.externalModification
        }
        return (index, pixels)
    }

    private func clearDetachedReferenceSelection(in candidate: inout ProjectManifest, index: Int) {
        let document = candidate.documents[index]
        if let selected = document.selectedAssetID, selected == document.draft.referenceImageAssetID,
           selected != document.sourceAssetID,
           !candidate.jobs.contains(where: { $0.documentID == document.id && $0.artifactIDs.contains(selected) }) {
            candidate.documents[index].selectedAssetID = nil
        }
    }

    /// One request owns one derivative. Never replace a previous job's input.
    public func prepareImageReference(assetID: UUID, runID: UUID) throws -> ImageReference {
        try checkLocation()
        let (index, pixels) = try imageReferencePixels(assetID)
        guard manifest.assets[index].metadata.imageContentSHA256 == pixels.sourceSHA256 else {
            throw ProjectStoreError.invalidProject("请重新显式选择参考图，再生成。")
        }
        let inputs = try ProjectFiles.openOrCreateDirectory("ImageInputs", in: rootFD)
        defer { Darwin.close(inputs) }
        guard mkdirat(inputs, runID.uuidString, 0o700) == 0 else { throw ProjectFiles.error() }
        let directory = try ProjectFiles.openRelativeDirectory(runID.uuidString, in: inputs)
        defer { Darwin.close(directory) }
        try ProjectFiles.publish(in: directory, name: "reference.rgb", replacing: false) { fd in
            try pixels.rgb.withUnsafeBytes { try ProjectFiles.writeAll($0, to: fd) }
        }
        guard fsync(inputs) == 0 else { throw ProjectFiles.error() }
        let reference = ImageReference(url: rootURL.appendingPathComponent("ImageInputs/\(runID.uuidString)/reference.rgb"),
            sha256: SHA256.hash(data: pixels.rgb).map { String(format: "%02x", $0) }.joined(),
            byteCount: UInt64(pixels.rgb.count), width: pixels.width, height: pixels.height)
        preparedImageReferences[runID] = (assetID, reference)
        return reference
    }

    public func saveDraft(_ draft: ProjectDraft, documentID: UUID? = nil) throws -> ProjectManifest {
        let index = try documentIndex(documentID ?? manifest.activeDocumentID)
        guard manifest.documents[index].kind == .image else {
            throw ProjectStoreError.invalidProject("文字文档不能保存图像创作条件。")
        }
        guard manifest.documents[index].draft != draft else { return manifest }
        var candidate = manifest
        candidate.documents[index].draft = draft
        try commit(candidate)
        return manifest
    }

    public func createDocument(name: String, draft: ProjectDraft = .init(), sourceAssetID: UUID? = nil) throws -> ProjectManifest {
        try checkLocation()
        if let sourceAssetID, !manifest.assets.contains(where: { $0.id == sourceAssetID }) {
            throw ProjectStoreError.missingAsset
        }
        let document = ProjectDocument(name: name, draft: draft, sourceAssetID: sourceAssetID,
                                       selectedAssetID: sourceAssetID)
        var candidate = manifest
        candidate.documents.append(document)
        candidate.activeDocumentID = document.id
        try commit(candidate)
        return manifest
    }

    public func createTextDocument(name: String = "新文稿", text: String = "") throws -> ProjectManifest {
        try checkLocation()
        let textDraft = try TextDraftDocument(text: text)
        let document = ProjectDocument(id: textDraft.id, name: name, kind: .text, textDraft: textDraft, textSources: .init())
        var candidate = manifest
        candidate.documents.append(document)
        candidate.activeDocumentID = document.id
        try commit(candidate)
        return manifest
    }

    public func createAudioCreation(name: String = "声音创作",
                                    sourceAssetID: UUID? = nil) throws -> ProjectManifest {
        try checkLocation()
        if let sourceAssetID {
            guard let source = manifest.assets.first(where: { $0.id == sourceAssetID }),
                  source.metadata.audio != nil else { throw ProjectStoreError.missingAsset }
        }
        let draft = AudioCreationDraft(operation: sourceAssetID == nil ? .generate : .variation)
        let document = ProjectDocument(name: name, kind: .audio, audioCreation: draft,
                                       sourceAssetID: sourceAssetID)
        var candidate = manifest
        candidate.documents.append(document)
        candidate.activeDocumentID = document.id
        try commit(candidate)
        return manifest
    }

    public func createVideoCreation(name: String = "视频创作") throws -> ProjectManifest {
        try checkLocation()
        let document = ProjectDocument(name: name, kind: .video, videoCreation: .init())
        var candidate = manifest
        candidate.documents.append(document)
        candidate.activeDocumentID = document.id
        try commit(candidate)
        return manifest
    }

    public func saveVideoCreation(_ draft: VideoCreationDraft, documentID: UUID,
                                  expectedRevision: UUID) throws -> ProjectManifest {
        let index = try documentIndex(documentID)
        guard manifest.documents[index].kind == .video,
              let current = manifest.documents[index].videoCreation,
              manifest.documents[index].audioDraft == nil else {
            throw ProjectStoreError.invalidProject("视频创作稿与文档不匹配。")
        }
        guard current.revision == expectedRevision else { throw ProjectStoreError.externalModification }
        guard current.rejectedAssetIDs == draft.rejectedAssetIDs else {
            throw ProjectStoreError.invalidProject("候选拒绝状态必须通过独立操作修改。")
        }
        if current == draft { return manifest }
        guard current.revision != draft.revision else {
            throw ProjectStoreError.invalidProject("视频创作内容已改变，修订编号不能重复。")
        }
        var candidate = manifest
        candidate.documents[index].videoCreation = draft
        try commit(candidate)
        return manifest
    }

    public func saveAudioCreation(_ draft: AudioCreationDraft, documentID: UUID,
                                  expectedRevision: UUID) throws -> ProjectManifest {
        let index = try documentIndex(documentID)
        guard manifest.documents[index].kind == .audio,
              let current = manifest.documents[index].audioCreation,
              manifest.documents[index].audioDraft == nil else {
            throw ProjectStoreError.invalidProject("声音创作稿与文档不匹配。")
        }
        guard current.revision == expectedRevision else { throw ProjectStoreError.externalModification }
        guard current.rejectedAssetIDs == draft.rejectedAssetIDs else {
            throw ProjectStoreError.invalidProject("候选拒绝状态必须通过独立操作修改。")
        }
        if current == draft { return manifest }
        guard current.revision != draft.revision else {
            throw ProjectStoreError.invalidProject("声音创作内容已改变，修订编号不能重复。")
        }
        var candidate = manifest
        candidate.documents[index].audioCreation = draft
        try commit(candidate)
        return manifest
    }

    private var invalidatedPitchRuns: Set<UUID> = []
    private var preparedPitchInputs: [UUID: PitchAnalysisRequest] = [:]

    /// Own the original snapshot before converting it; no shared editor URL crosses execution.
    public func preparePitchInput(documentID: UUID, runID: UUID) throws -> PitchAnalysisRequest {
        let inspected = try inspectAudio(documentID: documentID)
        let draft = inspected.document
        let range = draft.selectedClipID.flatMap { id in draft.clips.first { $0.id == id }?.range }
            ?? AudioFrameRange(startFrame: 0, endFrame: inspected.metadata.format.frameCount)
        let source = PitchSourceIdentity(assetID: draft.assetID, documentID: documentID,
            documentRevision: draft.revision, contentSHA256: inspected.metadata.contentSHA256,
            sampleRate: inspected.metadata.format.sampleRate, frameCount: inspected.metadata.format.frameCount,
            startFrame: range.startFrame, endFrame: range.endFrame)
        try source.validate()
        let parent = try ProjectFiles.openOrCreateDirectory("PitchInputs", in: rootFD)
        defer { Darwin.close(parent) }
        let name = runID.uuidString
        guard mkdirat(parent, name, 0o700) == 0 else { throw ProjectStoreError.alreadyExists("PitchInputs/" + name) }
        let directory = try ProjectFiles.openRelativeDirectory(name, in: parent)
        defer { Darwin.close(directory) }
        let leaf = "source." + inspected.metadata.format.container.rawValue
        try ProjectFiles.publish(in: directory, name: leaf, replacing: false) { output in
            try AudioMediaInspector.withOriginalSource(at: inspected.url) { input, count in
                try AudioMediaInspector.copyOriginal(from: input, byteCount: count, to: output)
            }
        }
        let location = rootURL.appendingPathComponent("PitchInputs/" + name)
        let data = try PitchInputPreparer.prepare(at: location.appendingPathComponent(leaf), source: source)
        try ProjectFiles.publish(in: directory, name: "input.f32", replacing: false) { output in
            try data.withUnsafeBytes { try ProjectFiles.writeAll($0, to: output) }
        }
        let request = PitchAnalysisRequest(source: source, inputURL: location.appendingPathComponent("input.f32"),
            inputSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), sampleCount: data.count / 4)
        try request.validate()
        // Re-read the registered original and manifest after conversion. Stale source is never admitted.
        let current = try inspectAudio(documentID: documentID)
        guard current.document == draft, current.metadata == inspected.metadata else { throw ProjectStoreError.externalModification }
        preparedPitchInputs[runID] = request
        return request
    }

    public func readPitchAnalysis(assetID: UUID) throws -> PitchAnalysisResult {
        guard let asset = manifest.assets.first(where: { $0.id == assetID }), let metadata = asset.metadata.pitch,
              let jobID = asset.jobID, let job = manifest.jobs.first(where: { $0.id == jobID }),
              case .pitch(let request) = job.request.input else { throw ProjectStoreError.missingAsset }
        try checkLocation()
        let data = try ProjectFiles.read(relative: asset.relativePath, in: rootFD, limit: PitchAnalysisResult.maximumJSONBytes)
        guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == metadata.contentSHA256 else {
            throw ProjectStoreError.externalModification
        }
        let result = try PitchResultFile.decode(data)
        try Self.validatePitchResult(result, request: request, runID: jobID)
        return result
    }

    public func decidePitchAnalysis(assetID: UUID, documentID: UUID, accept: Bool) throws -> ProjectManifest {
        let index = try documentIndex(documentID)
        guard let asset = manifest.assets.first(where: { $0.id == assetID }), let jobID = asset.jobID,
              let job = manifest.jobs.first(where: { $0.id == jobID }), job.documentID == documentID,
              job.state == .completed, let draft = manifest.documents[index].audioDraft else {
            throw ProjectStoreError.missingAsset
        }
        var state = manifest.documents[index].pitchAnalysis ?? PitchDocumentState()
        guard state.selectedAssetID == assetID, !state.acceptedAssetIDs.contains(assetID),
              !state.rejectedAssetIDs.contains(assetID) else { throw ProjectStoreError.invalidTransition }
        if accept {
            let result = try readPitchAnalysis(assetID: assetID)
            guard !state.expiredAssetIDs.contains(assetID) else { throw ProjectStoreError.invalidTransition }
            guard result.source.documentRevision == draft.revision, result.source.assetID == draft.assetID else {
                throw ProjectStoreError.invalidProject("原声备注或片段已改变，请重新识别；原件和历史结果已保留。")
            }
            let original = try inspectAudio(documentID: documentID)
            guard original.metadata.contentSHA256 == result.source.contentSHA256,
                  original.metadata.format.sampleRate == result.source.sampleRate,
                  original.metadata.format.frameCount == result.source.frameCount else { throw ProjectStoreError.externalModification }
            state.acceptedAssetIDs.append(assetID)
        } else {
            state.rejectedAssetIDs.append(assetID)
            state.selectedAssetID = state.acceptedAssetIDs.last
        }
        var next = manifest; next.documents[index].pitchAnalysis = state
        try commit(next)
        return manifest
    }

    /// A navigation boundary invalidates pending interpretation, while preserving its evidence.
    public func invalidatePitchCandidates(documentID: UUID) throws -> ProjectManifest {
        let index = try documentIndex(documentID)
        for job in manifest.jobs where job.documentID == documentID && !job.state.isTerminal {
            if case .pitch = job.request.input { invalidatedPitchRuns.insert(job.id) }
        }
        guard var state = manifest.documents[index].pitchAnalysis, let id = state.selectedAssetID,
              !state.acceptedAssetIDs.contains(id), !state.expiredAssetIDs.contains(id) else { return manifest }
        state.expiredAssetIDs.append(id)
        var next = manifest; next.documents[index].pitchAnalysis = state
        try commit(next)
        return manifest
    }

    public func exportPitchAnalysis(assetID: UUID, to destination: URL) throws {
        let result = try readPitchAnalysis(assetID: assetID)
        guard destination.isFileURL, destination.path.hasPrefix("/"), !destination.lastPathComponent.isEmpty else {
            throw ProjectStoreError.unsafePath(destination.path)
        }
        struct Export: Encodable {
            let schemaVersion: Int
            let result: PitchAnalysisResult
            let interpretationVersion: String
            let notes: [PitchNote]
            let sourceNotes: [PitchSourceNote]
            let sourceRole: String
            let meaning: String
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let value = Export(schemaVersion: 1, result: result, interpretationVersion: PitchInterpretation.version,
            notes: try PitchInterpretation(result: result).notes,
            sourceNotes: try PitchSourceNote.map(result), sourceRole: "original-human-or-imported-audio; machine-analysis",
            meaning: "Analysis of original source audio; approximate free-time notes, no beat/velocity inference.")
        let data = try encoder.encode(value)
        let parent = try ProjectFiles.openDirectory(destination.deletingLastPathComponent())
        defer { Darwin.close(parent) }
        try ProjectFiles.publishExport(to: destination, parent: parent, checkpoint: nil, validate: { url in
            guard try Data(contentsOf: url) == data else { throw ProjectStoreError.externalModification }
        }) { output in try data.withUnsafeBytes { try ProjectFiles.writeAll($0, to: output) } }
    }

    /// Export a retained interpretation; the original recording and analysis stay authoritative.
    public func exportPitchMIDI(assetID: UUID, documentID: UUID, to destination: URL) throws {
        try exportPitchMIDI(assetID: assetID, documentID: documentID, to: destination, checkpoint: nil)
    }

    func exportPitchMIDI(assetID: UUID, documentID: UUID, to destination: URL,
                         checkpoint: (@Sendable (ProjectExportCheckpoint) throws -> Void)?) throws {
        try publishPitchDerivative(assetID: assetID, documentID: documentID, to: destination,
                                   checkpoint: checkpoint, encode: PitchMIDIFile.encode(result:))
    }

    /// An ordinary synthetic note preview, never a reconstruction of the singer's voice.
    public func exportPitchNotePreview(assetID: UUID, documentID: UUID, to destination: URL) throws {
        try exportPitchNotePreview(assetID: assetID, documentID: documentID, to: destination, checkpoint: nil)
    }

    func exportPitchNotePreview(assetID: UUID, documentID: UUID, to destination: URL,
                                checkpoint: (@Sendable (ProjectExportCheckpoint) throws -> Void)?) throws {
        try publishPitchDerivative(assetID: assetID, documentID: documentID, to: destination,
                                   checkpoint: checkpoint, encode: PitchNotePreview.encodeWAV(result:))
    }

    private func currentAcceptedPitch(assetID: UUID, documentID: UUID, checkCancellation: Bool = true) throws -> PitchAnalysisResult {
        if checkCancellation { try Task.checkCancellation() }
        try checkLocation()
        try verifyUnchangedManifest()
        let index = try documentIndex(documentID)
        guard let state = manifest.documents[index].pitchAnalysis,
              state.acceptedAssetIDs.contains(assetID), !state.rejectedAssetIDs.contains(assetID),
              !state.expiredAssetIDs.contains(assetID),
              let asset = manifest.assets.first(where: { $0.id == assetID }),
              let job = manifest.jobs.first(where: { $0.id == asset.jobID }),
              job.documentID == documentID, job.state == .completed else {
            throw ProjectStoreError.invalidProject("请先保留当前原声的有效音高结果，再导出音符。")
        }
        let result = try readPitchAnalysis(assetID: assetID)
        guard manifest.documents[index].kind == .audio,
              let draft = manifest.documents[index].audioDraft, draft.id == documentID,
              let original = manifest.assets.first(where: { $0.id == draft.assetID }),
              original.role == .original, original.jobID == nil, let metadata = original.metadata.audio,
              result.source.documentID == documentID,
              result.source.assetID == draft.assetID,
              result.source.documentRevision == draft.revision,
              result.source.contentSHA256 == metadata.contentSHA256,
              result.source.sampleRate == metadata.format.sampleRate,
              result.source.frameCount == metadata.format.frameCount else {
            throw ProjectStoreError.invalidProject("原声或片段已改变，请重新识别并保留结果；历史结果仍保留。")
        }
        // An exact hash of the bounded, registered original proves its admitted format is
        // unchanged. No decoder or cancellation-aware media inspector is needed here.
        // In particular, cancellation cannot skip this finite cleanup verification.
        let digest = try AudioMediaInspector.withOriginalSource(at: rootURL.appendingPathComponent(original.relativePath)) { descriptor, byteCount in
            var hasher = SHA256(), offset = 0
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while offset < byteCount {
                let count = pread(descriptor, &buffer, min(buffer.count, byteCount - offset), off_t(offset))
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw ProjectStoreError.externalModification }
                buffer.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[..<count])) }
                offset += count
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
        guard digest == metadata.contentSHA256 else { throw ProjectStoreError.externalModification }
        if checkCancellation { try Task.checkCancellation() }
        return result
    }

    private func publishPitchDerivative(assetID: UUID, documentID: UUID, to destination: URL,
                                         checkpoint: (@Sendable (ProjectExportCheckpoint) throws -> Void)?,
                                         encode: (PitchAnalysisResult) throws -> Data) throws {
        let result = try currentAcceptedPitch(assetID: assetID, documentID: documentID)
        do {
            guard destination.isFileURL, destination.path.hasPrefix("/"),
                  destination.standardizedFileURL.path == destination.path,
                  !destination.lastPathComponent.isEmpty else { throw ProjectStoreError.unsafePath(destination.path) }
            let parent = try ProjectFiles.openDirectory(destination.deletingLastPathComponent())
            defer { Darwin.close(parent) }
            try requireExternalPitchExportParent(parent)
            let data = try encode(result)
            var temporaryIdentity: (device: dev_t, inode: ino_t)?
            try ProjectFiles.publishExport(to: destination, parent: parent, checkpoint: checkpoint, validate: { url in
                try Task.checkCancellation()
                _ = try self.currentAcceptedPitch(assetID: assetID, documentID: documentID)
                let directory = try ProjectFiles.openDirectory(url.deletingLastPathComponent())
                defer { Darwin.close(directory) }
                var before = stat(), after = stat()
                guard fstatat(directory, url.lastPathComponent, &before, AT_SYMLINK_NOFOLLOW) == 0,
                      before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1,
                      before.st_size == data.count else { throw ProjectStoreError.externalModification }
                if let identity = temporaryIdentity {
                    guard before.st_dev == identity.device, before.st_ino == identity.inode else {
                        throw ProjectStoreError.externalModification
                    }
                } else { temporaryIdentity = (before.st_dev, before.st_ino) }
                guard try ProjectFiles.read(relative: url.lastPathComponent, in: directory, limit: data.count) == data,
                      fstatat(directory, url.lastPathComponent, &after, AT_SYMLINK_NOFOLLOW) == 0,
                      after.st_mode & S_IFMT == S_IFREG, after.st_nlink == 1,
                      after.st_dev == before.st_dev, after.st_ino == before.st_ino,
                      after.st_size == before.st_size else { throw ProjectStoreError.externalModification }
                try self.requireExternalPitchExportParent(parent)
            }) { output in
                try Task.checkCancellation()
                try data.withUnsafeBytes { try ProjectFiles.writeAll($0, to: output) }
            }
        } catch {
            let publicationError = error
            do { _ = try currentAcceptedPitch(assetID: assetID, documentID: documentID, checkCancellation: false) }
            catch {
                throw ProjectStoreError.io("导出失败（\(publicationError)）；来源复核失败（\(error)）。若文件已经发布则保留，原件不会被回滚。")
            }
            throw publicationError
        }
        // Check the source even if cancellation arrived just after publication. Neither path
        // deletes a delivered file; a source failure is reported before a late cancellation.
        do { _ = try currentAcceptedPitch(assetID: assetID, documentID: documentID, checkCancellation: false) }
        catch { throw ProjectStoreError.io("导出文件已保留；来源复核失败（\(error)）。请检查项目。") }
        try Task.checkCancellation()
    }

    /// Compare directory identities, including on case-insensitive volumes. A textual prefix
    /// would allow another spelling of the project directory to receive unregistered files.
    private func requireExternalPitchExportParent(_ parent: Int32) throws {
        var current = dup(parent)
        guard current >= 0 else { throw ProjectFiles.error() }
        defer { Darwin.close(current) }
        var root = stat()
        guard fstat(rootFD, &root) == 0 else { throw ProjectFiles.error() }
        while true {
            var here = stat()
            guard fstat(current, &here) == 0 else { throw ProjectFiles.error() }
            guard here.st_dev != root.st_dev || here.st_ino != root.st_ino else {
                throw ProjectStoreError.invalidProject("请选择项目包之外的导出位置；项目中的原件和记录不会被改写。")
            }
            let ancestor = openat(current, "..", O_SEARCH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard ancestor >= 0 else { throw ProjectFiles.error() }
            var above = stat()
            guard fstat(ancestor, &above) == 0 else { Darwin.close(ancestor); throw ProjectFiles.error() }
            if here.st_dev == above.st_dev && here.st_ino == above.st_ino { Darwin.close(ancestor); return }
            Darwin.close(current); current = ancestor
        }
    }

    private static func validatePitchResult(_ result: PitchAnalysisResult, request: PitchAnalysisRequest, runID: UUID) throws {
        try result.validate()
        guard result.runID == runID, result.source == request.source,
              result.inputSHA256 == request.inputSHA256, result.sampleCount == request.sampleCount else {
            throw ProjectStoreError.invalidProject("音高结果与冻结的原声、区间或任务不一致。")
        }
    }

    public func prepareAudioCreationSource(assetID: UUID, runID: UUID) throws -> AudioSourceReference {
        guard let asset = manifest.assets.first(where: { $0.id == assetID }),
              let registered = asset.metadata.audio else { throw ProjectStoreError.missingAsset }
        try checkLocation()
        let policy = try ProjectFiles.inspectionPolicy(for: asset, jobs: manifest.jobs)
        let sourceURL = try assetURL(for: asset)
        let sourceInspection = try AudioMediaInspector.inspect(at: sourceURL, policy: policy)
        try ProjectFiles.requireRegisteredAudio(sourceInspection, matches: registered)
        try ProjectFiles.validateCreationSource(sourceInspection.format)

        let inputRoot = try ProjectFiles.openOrCreateDirectory("AudioInputs", in: rootFD)
        defer { Darwin.close(inputRoot) }
        let runName = runID.uuidString
        guard mkdirat(inputRoot, runName, 0o700) == 0 else {
            if errno == EEXIST { throw ProjectStoreError.alreadyExists("AudioInputs/\(runName)") }
            throw ProjectFiles.error()
        }
        guard fsync(inputRoot) == 0 else { throw ProjectFiles.error() }
        let runDirectory = try ProjectFiles.openRelativeDirectory(runName, in: inputRoot)
        defer { Darwin.close(runDirectory) }
        let destination = openat(runDirectory, "source.wav",
                                 O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard destination >= 0 else {
            if errno == EEXIST { throw ProjectStoreError.alreadyExists("AudioInputs/\(runName)/source.wav") }
            throw ProjectFiles.error()
        }
        do {
            try AudioMediaInspector.withOriginalSource(at: sourceURL, policy: policy) { source, byteCount in
                try AudioMediaInspector.copyOriginal(from: source, byteCount: byteCount, to: destination)
            }
            guard fsync(destination) == 0 else { throw ProjectFiles.error() }
            Darwin.close(destination)
        } catch {
            Darwin.close(destination)
            throw error
        }
        guard fsync(runDirectory) == 0 else { throw ProjectFiles.error() }

        let frozenURL = rootURL.appendingPathComponent("AudioInputs/\(runName)/source.wav")
        let frozen = try AudioMediaInspector.inspect(at: frozenURL, policy: policy)
        try ProjectFiles.requireRegisteredAudio(frozen, matches: registered)
        try ProjectFiles.validateCreationSource(frozen.format)
        let finalSource = try AudioMediaInspector.inspect(at: sourceURL, policy: policy)
        try ProjectFiles.requireRegisteredAudio(finalSource, matches: registered)
        return AudioSourceReference(url: frozenURL, sha256: frozen.contentSHA256,
                                    frameCount: frozen.format.frameCount,
                                    sampleRate: Int(frozen.format.sampleRate),
                                    channels: frozen.format.channelCount)
    }

    public func saveTextDraft(_ draft: TextDraftDocument, documentID: UUID,
                              expectedRevision: UUID) throws -> ProjectManifest {
        let index = try documentIndex(documentID)
        guard manifest.documents[index].kind == .text,
              let current = manifest.documents[index].textDraft,
              current.id == documentID,
              draft.id == documentID else {
            throw ProjectStoreError.invalidProject("文字稿与文字文档编号不匹配。")
        }
        guard current.revision == expectedRevision else { throw ProjectStoreError.externalModification }
        try TextDraftDocument.validate(draft.text)
        let bytesChanged = !current.text.utf8.elementsEqual(draft.text.utf8)
        if !bytesChanged, draft.generationSettings == current.generationSettings,
           draft.revision == current.revision { return manifest }
        guard draft.revision != current.revision else {
            throw ProjectStoreError.invalidProject("文字内容已改变，修订编号不能重复。")
        }
        var candidate = manifest
        candidate.documents[index].textDraft = draft
        try commit(candidate)
        return manifest
    }

    /// Compare both authorities and publish the optional accepted answer with its record in one transaction.
    public func saveTextSources(_ notebook: TextSourcesNotebook, documentID: UUID,
                                expectedRevision: UUID, expectedDocumentRevision: UUID,
                                replacingText: TextDraftDocument? = nil) throws -> ProjectManifest {
        let index = try documentIndex(documentID)
        guard manifest.documents[index].kind == .text,
              let current = manifest.documents[index].textSources,
              let draft = manifest.documents[index].textDraft else {
            throw ProjectStoreError.invalidProject("文字资料记录与文档不匹配。")
        }
        guard current.revision == expectedRevision, draft.revision == expectedDocumentRevision else {
            throw ProjectStoreError.externalModification
        }
        try TextSourcesArchive.validate(notebook)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let changed = try encoder.encode(current) != encoder.encode(notebook)
        if changed && current.revision == notebook.revision {
            throw ProjectStoreError.invalidProject("资料记录改变时必须更新修订编号。")
        }
        if let replacingText {
            guard replacingText.id == documentID, replacingText.revision != draft.revision else {
                throw ProjectStoreError.invalidProject("采用或撤销回答必须产生本稿的新正文修订。")
            }
            try TextDraftDocument.validate(replacingText.text)
        }
        guard changed || replacingText != nil else { return manifest }
        var candidate = manifest
        candidate.documents[index].textSources = notebook
        if let replacingText { candidate.documents[index].textDraft = replacingText }
        try commit(candidate)
        return manifest
    }

    public func selectDocument(id: UUID) throws -> ProjectManifest {
        _ = try documentIndex(id)
        guard manifest.activeDocumentID != id else { return manifest }
        var candidate = manifest
        candidate.activeDocumentID = id
        try commit(candidate)
        return manifest
    }

    public func renameDocument(id: UUID, name: String) throws -> ProjectManifest {
        let index = try documentIndex(id)
        guard manifest.documents[index].name != name else { return manifest }
        var candidate = manifest
        candidate.documents[index].name = name
        try commit(candidate)
        return manifest
    }

    public func setSelectedAsset(_ id: UUID?, documentID: UUID) throws -> ProjectManifest {
        let index = try documentIndex(documentID)
        let document = manifest.documents[index]
        guard document.kind == .image || document.audioCreation != nil || document.videoCreation != nil else {
            throw ProjectStoreError.invalidProject("该文档不能选择候选作品。")
        }
        guard document.selectedAssetID != id else { return manifest }
        var candidate = manifest
        candidate.documents[index].selectedAssetID = id
        try commit(candidate)
        return manifest
    }

    /// Adoption is an explicit creative choice. Generating, selecting, favoriting or recovering
    /// a candidate never silently replaces the document's adopted result.
    public func adoptAsset(id: UUID?, documentID: UUID) throws -> ProjectManifest {
        let index = try documentIndex(documentID)
        let document = manifest.documents[index]
        guard document.kind == .image || document.audioCreation != nil || document.videoCreation != nil else {
            throw ProjectStoreError.invalidProject("该文档不能采用候选作品。")
        }
        guard document.adoptedAssetID != id else { return manifest }
        var candidate = manifest
        candidate.documents[index].adoptedAssetID = id
        try commit(candidate)
        return manifest
    }

    public func setAudioCandidateRejected(id: UUID, rejected: Bool,
                                          documentID: UUID) throws -> ProjectManifest {
        let index = try documentIndex(documentID)
        guard var draft = manifest.documents[index].audioCreation,
              let asset = manifest.assets.first(where: { $0.id == id }),
              asset.role == .result, let jobID = asset.jobID,
              manifest.jobs.first(where: { $0.id == jobID })?.documentID == documentID else {
            throw ProjectStoreError.invalidProject("候选不属于该声音创作文档。")
        }
        let contains = draft.rejectedAssetIDs.contains(id)
        guard contains != rejected else { return manifest }
        if rejected { draft.rejectedAssetIDs.append(id) }
        else { draft.rejectedAssetIDs.removeAll { $0 == id } }
        draft.revision = UUID()
        var candidate = manifest
        candidate.documents[index].audioCreation = draft
        if rejected, candidate.documents[index].selectedAssetID == id {
            candidate.documents[index].selectedAssetID = nil
        }
        if rejected, candidate.documents[index].adoptedAssetID == id {
            candidate.documents[index].adoptedAssetID = nil
        }
        try commit(candidate)
        return manifest
    }

    public func setVideoCandidateRejected(id: UUID, rejected: Bool,
                                          documentID: UUID) throws -> ProjectManifest {
        let index = try documentIndex(documentID)
        guard var draft = manifest.documents[index].videoCreation,
              let asset = manifest.assets.first(where: { $0.id == id }),
              asset.role == .result, let jobID = asset.jobID,
              manifest.jobs.first(where: { $0.id == jobID })?.documentID == documentID else {
            throw ProjectStoreError.invalidProject("候选不属于该视频创作文档。")
        }
        let contains = draft.rejectedAssetIDs.contains(id)
        guard contains != rejected else { return manifest }
        if rejected { draft.rejectedAssetIDs.append(id) }
        else { draft.rejectedAssetIDs.removeAll { $0 == id } }
        draft.revision = UUID()
        var candidate = manifest
        candidate.documents[index].videoCreation = draft
        if rejected, candidate.documents[index].selectedAssetID == id {
            candidate.documents[index].selectedAssetID = nil
        }
        if rejected, candidate.documents[index].adoptedAssetID == id {
            candidate.documents[index].adoptedAssetID = nil
        }
        try commit(candidate)
        return manifest
    }

    public func updateAsset(id: UUID, name: String? = nil, note: String? = nil, isFavorite: Bool? = nil) throws -> ProjectManifest {
        try checkLocation()
        guard let index = manifest.assets.firstIndex(where: { $0.id == id }) else { throw ProjectStoreError.missingAsset }
        var candidate = manifest
        if let name { candidate.assets[index].name = name }
        if let note { candidate.assets[index].note = note }
        if let isFavorite { candidate.assets[index].isFavorite = isFavorite }
        if candidate != manifest { try commit(candidate) }
        return manifest
    }

    private func documentIndex(_ id: UUID) throws -> Int {
        guard !isClosed else { throw ProjectStoreError.io("项目会话已关闭，请重新打开项目") }
        guard let index = manifest.documents.firstIndex(where: { $0.id == id }) else { throw ProjectStoreError.missingDocument }
        return index
    }

    /// Recognize the same directory after a Finder move without trusting its displayed name
    /// or a copied manifest UUID. The caller must hold access to the newly selected location.
    public func matchesLocation(_ url: URL) throws -> Bool {
        guard !isClosed else { throw ProjectStoreError.io("项目会话已关闭，请重新打开项目") }
        let directory = try ProjectFiles.openDirectory(ProjectFiles.projectURL(url))
        defer { Darwin.close(directory) }
        return try sameDirectory(directory)
    }

    /// Transfers a drained session to the same physical directory at its new authorized URL.
    /// An arbitrary project copy cannot take over the lock or unsaved terminal result records.
    public func relocated(to url: URL) throws -> ProjectStore {
        guard !isClosed else { throw ProjectStoreError.io("项目会话已关闭，请重新打开项目") }
        let location = try ProjectFiles.projectURL(url)
        let directory = try ProjectFiles.openDirectory(location)
        var transferred = false
        defer { if !transferred { Darwin.close(directory) } }
        guard try sameDirectory(directory) else {
            throw ProjectStoreError.invalidProject("所选目录不是当前项目的移动后位置，请选择原项目。")
        }
        try verifyUnchangedManifest()
        guard fsync(rootFD) == 0 else { throw ProjectFiles.error() }
        let lock = fcntl(lockFD, F_DUPFD_CLOEXEC, 0)
        guard lock >= 0 else { throw ProjectFiles.error() }
        let replacement = ProjectStore(rootURL: location, rootFD: directory, lockFD: lock, manifest: manifest,
                                       invalidatedPitchRuns: invalidatedPitchRuns)
        transferred = true
        Darwin.close(lockFD)
        Darwin.close(rootFD)
        isClosed = true
        return replacement
    }

    /// The captured document must be the result of a successful host save. Later
    /// draft edits cannot replace this immutable admission snapshot.
    public func enqueue(request: InferenceRequest, documentID: UUID? = nil,
                        capturedVideoDocument: ProjectDocument? = nil,
                        capturedImageReferenceAssetID: UUID? = nil) throws -> ProjectManifest {
        try request.validate()
        let index = try documentIndex(documentID ?? manifest.activeDocumentID)
        let document = manifest.documents[index]
        switch request.input {
        case .singing:
            throw ProjectStoreError.invalidTransition
        case .pitch(let pitch):
            guard document.kind == .audio, let draft = document.audioDraft,
                  preparedPitchInputs[request.id] == pitch, pitch.source.documentID == document.id,
                  draft.revision == pitch.source.documentRevision, draft.assetID == pitch.source.assetID else {
                throw ProjectStoreError.invalidProject("音高任务没有当前原声的冻结输入。")
            }
            if let selected = document.pitchAnalysis?.selectedAssetID,
               document.pitchAnalysis?.acceptedAssetIDs.contains(selected) != true {
                throw ProjectStoreError.invalidProject("请先保留或拒绝当前音高候选。")
            }
            _ = try inspectAudio(documentID: document.id)
        case .video(let video):
            let captured = capturedVideoDocument ?? document
            guard document.kind == .video, captured.kind == .video, captured.id == document.id,
                  let draft = captured.videoCreation, try draft.makeRequest() == video,
                  try draft.selectedMemoryBudgetBytes() == request.memoryBudgetBytes else {
                throw ProjectStoreError.invalidProject("视频请求与保存的创作条件或预算不一致。")
            }
        case .image(let image):
            guard document.kind == .image else {
                throw ProjectStoreError.invalidProject("只有图像文档能创建图像任务。")
            }
            if image.referenceImage != nil || image.executionProfile == ImageExecutionCapability.referenceKlein4B.profile {
                try ImageExecutionCapability.scalableKlein4B.validate(image)
            }
            if let reference = image.referenceImage {
                guard let sourceID = capturedImageReferenceAssetID,
                      let prepared = preparedImageReferences[request.id],
                      prepared.assetID == sourceID, prepared.reference == reference,
                      let source = manifest.assets.first(where: { $0.id == sourceID }),
                      source.mediaType == "image/png", source.metadata.imageContentSHA256 != nil,
                      reference.url == rootURL.appendingPathComponent("ImageInputs/\(request.id.uuidString)/reference.rgb") else {
                    throw ProjectStoreError.invalidProject("参考任务缺少已冻结的项目来源。")
                }
                let bytes = try ProjectFiles.read(relative: "ImageInputs/\(request.id.uuidString)/reference.rgb", in: rootFD,
                                                  limit: Int(reference.byteCount))
                guard bytes.count == reference.byteCount,
                      SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == reference.sha256 else {
                    throw ProjectStoreError.externalModification
                }
            } else if capturedImageReferenceAssetID != nil {
                throw ProjectStoreError.invalidProject("不能忽略已指定的参考图。")
            }
        case .audio(let audio):
            guard document.kind == .audio, let draft = document.audioCreation,
                  document.audioDraft == nil else {
                throw ProjectStoreError.invalidProject("只有声音创作文档能创建音频任务。")
            }
            try ProjectFiles.validateCurrentAudioProfile(audio)
            if let sourceID = document.sourceAssetID {
                guard let asset = manifest.assets.first(where: { $0.id == sourceID }),
                      let metadata = asset.metadata.audio, let source = audio.source else {
                    throw ProjectStoreError.invalidProject("声音创作来源不存在或请求未携带来源快照。")
                }
                let expectedURL = rootURL.appendingPathComponent(
                    "AudioInputs/\(request.id.uuidString)/source.wav")
                guard source.url.path == expectedURL.path,
                      source.url.standardizedFileURL == expectedURL.standardizedFileURL else {
                    throw ProjectStoreError.unsafePath(source.url.path)
                }
                let policy = try ProjectFiles.inspectionPolicy(for: asset, jobs: manifest.jobs)
                let inspection = try AudioMediaInspector.inspect(at: expectedURL, policy: policy)
                try ProjectFiles.requireRegisteredAudio(inspection, matches: metadata)
                try ProjectFiles.validateCreationSource(inspection.format)
                guard source.sha256 == inspection.contentSHA256,
                      source.frameCount == inspection.format.frameCount,
                      source.sampleRate == Int(inspection.format.sampleRate),
                      source.channels == inspection.format.channelCount else {
                    throw ProjectStoreError.externalModification
                }
            } else if audio.source != nil {
                throw ProjectStoreError.invalidProject("无来源的声音创作文档不能提交参考音频。")
            }
            guard try draft.makeRequest(source: audio.source) == audio else {
                throw ProjectStoreError.invalidProject("音频请求与当前声音创作条件不一致。")
            }
        case .text:
            throw ProjectStoreError.invalidProject("文字任务不由项目作品队列持久化。")
        }
        guard !manifest.jobs.contains(where: { $0.id == request.id }) else {
            throw ProjectStoreError.invalidProject("任务编号重复。")
        }
        var candidate = manifest
        candidate.jobs.append(ProjectJob(id: request.id, documentID: manifest.documents[index].id, request: request,
                                        imageReferenceAssetID: capturedImageReferenceAssetID))
        try commit(candidate)
        preparedImageReferences.removeValue(forKey: request.id)
        return manifest
    }

    public func updateJob(id: UUID, state: JobState, error: String? = nil) throws -> ProjectManifest {
        guard let index = manifest.jobs.firstIndex(where: { $0.id == id }) else { throw ProjectStoreError.missingJob }
        let current = manifest.jobs[index]
        guard !current.state.isTerminal || current.state == state else { throw ProjectStoreError.invalidTransition }
        guard current.state != state || current.error != error else { return manifest }
        var candidate = manifest
        candidate.jobs[index].state = state
        candidate.jobs[index].error = error
        try commit(candidate)
        return manifest
    }

    /// Only an authoritative runtime completion may make a task completed. Every PNG is decoded
    /// and the complete candidate manifest is durable before the caller receives success.
    public func complete(id: UUID, result: InferenceResult) async throws -> ProjectManifest {
        if let job = manifest.jobs.first(where: { $0.id == id }), case .video(let request) = job.request.input {
            return try await completeVideo(job: job, request: request, result: result)
        }
        guard let index = manifest.jobs.firstIndex(where: { $0.id == id }) else { throw ProjectStoreError.missingJob }
        guard !manifest.jobs[index].state.isTerminal else { throw ProjectStoreError.invalidTransition }
        try checkLocation()
        var candidate = manifest
        switch candidate.jobs[index].request.input {
        case .singing: throw ProjectStoreError.invalidTransition
        case .video: throw ProjectStoreError.invalidTransition
        case .pitch(let request):
            guard result.artifacts.count == 1, let artifact = result.artifacts.first,
                  artifact.mediaType == PitchAnalysisResult.mediaType else { throw ProjectStoreError.invalidTransition }
            let expected = "Tasks/\(id.uuidString)/pitch.json"
            guard artifact.url == rootURL.appendingPathComponent(expected) else { throw ProjectStoreError.unsafePath(artifact.url.path) }
            let data = try ProjectFiles.read(relative: expected, in: rootFD, limit: PitchAnalysisResult.maximumJSONBytes)
            let analysis = try PitchResultFile.decode(data)
            try Self.validatePitchResult(analysis, request: request, runID: id)
            guard !candidate.assets.contains(where: { $0.relativePath == expected }) else { throw ProjectStoreError.invalidTransition }
            let metadata = PitchAssetMetadata(contentSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                                               source: analysis.source)
            let asset = ProjectAsset(jobID: id, relativePath: expected, mediaType: PitchAnalysisResult.mediaType,
                                     metadata: .init(pitch: metadata), name: "音高分析候选")
            candidate.assets.append(asset); candidate.jobs[index].artifactIDs.append(asset.id)
            if let documentIndex = candidate.documents.firstIndex(where: { $0.id == analysis.source.documentID }) {
                var state = candidate.documents[documentIndex].pitchAnalysis ?? PitchDocumentState()
                state.selectedAssetID = asset.id
                if invalidatedPitchRuns.contains(id) { state.expiredAssetIDs.append(asset.id) }
                candidate.documents[documentIndex].pitchAnalysis = state
            }
        case .image:
            guard !result.artifacts.isEmpty else { throw ProjectStoreError.invalidProject("生成任务没有交付图片。") }
            for artifact in result.artifacts {
                guard artifact.mediaType == "image/png" else {
                    throw ProjectStoreError.invalidProject("当前图像任务只登记 PNG 生成结果。")
                }
                let relative = try ProjectFiles.relativeArtifact(artifact.url, root: rootURL, jobID: id)
                guard !candidate.assets.contains(where: { $0.relativePath == relative }) else {
                    throw ProjectStoreError.invalidProject("图片已登记，不能重复引用。")
                }
                let metadata = try readPNG(relative: relative, job: candidate.jobs[index])
                let asset = ProjectAsset(jobID: id, relativePath: relative, metadata: metadata,
                                         name: "候选 \(candidate.assets.count + 1)")
                candidate.assets.append(asset)
                candidate.jobs[index].artifactIDs.append(asset.id)
            }
        case .audio(let audio):
            guard result.artifacts.count == 1, let artifact = result.artifacts.first,
                  artifact.mediaType == "audio/wav" else {
                throw ProjectStoreError.invalidProject("音频任务必须交付唯一 WAV 结果。")
            }
            let relative = try ProjectFiles.relativeAudioArtifact(artifact.url, root: rootURL, jobID: id)
            guard !candidate.assets.contains(where: { $0.relativePath == relative }) else {
                throw ProjectStoreError.invalidProject("音频结果已登记，不能重复引用。")
            }
            let inspection = try AudioMediaInspector.inspect(at: artifact.url, policy: .generated)
            let expectedFrames = try ProjectFiles.expectedAudioFrames(audio)
            guard inspection.format.container == .wav, inspection.format.sampleRate == Double(audio.outputSampleRate),
                  inspection.format.channelCount == 2, inspection.format.floatingPoint,
                  inspection.format.bitDepth == 32, inspection.format.frameCount == expectedFrames else {
                throw AudioMediaError.invalidMedia("生成音频格式或帧数与固定请求不一致")
            }
            let metadata = AudioAssetMetadata(format: inspection.format,
                                              contentSHA256: inspection.contentSHA256,
                                              origin: .modelGenerated)
            let asset = ProjectAsset(jobID: id, relativePath: relative, mediaType: "audio/wav",
                                     role: .result, metadata: .init(audio: metadata),
                                     name: "候选 \(candidate.assets.count + 1)")
            candidate.assets.append(asset)
            candidate.jobs[index].artifactIDs.append(asset.id)
        case .text:
            throw ProjectStoreError.invalidProject("文字任务不产生项目媒体作品。")
        }
        candidate.jobs[index].state = .completed
        candidate.jobs[index].error = nil
        candidate.jobs[index].resultMetadata = result.metadata
        try commit(candidate)
        return manifest
    }

    private func completeVideo(job: ProjectJob, request: VideoRequest,
                               result: InferenceResult) async throws -> ProjectManifest {
        guard !job.state.isTerminal, result.artifacts.count == 1,
              let artifact = result.artifacts.first, artifact.mediaType == "video/mp4" else {
            throw ProjectStoreError.invalidProject("视频任务必须交付唯一 MP4 结果且尚未结束。")
        }
        try checkLocation()
        let relative = try ProjectFiles.relativeVideoArtifact(artifact.url, root: rootURL, jobID: job.id)
        let metadata = try await VideoMediaInspector.inspect(at: artifact.url, expected: request)
        try checkLocation()
        // Other documents/drafts may change while inspection awaits; the original job
        // must still be the same nonterminal job. Build from the latest manifest.
        guard let index = manifest.jobs.firstIndex(where: { $0.id == job.id }),
              manifest.jobs[index].request == job.request, !manifest.jobs[index].state.isTerminal,
              !manifest.assets.contains(where: { $0.relativePath == relative }) else {
            throw ProjectStoreError.invalidTransition
        }
        var candidate = manifest
        let asset = ProjectAsset(jobID: job.id, relativePath: relative, mediaType: "video/mp4",
            metadata: .init(width: metadata.width, height: metadata.height, video: metadata),
            name: "视频候选 \(candidate.assets.count + 1)")
        candidate.assets.append(asset)
        candidate.jobs[index].artifactIDs = [asset.id]
        candidate.jobs[index].state = .completed
        candidate.jobs[index].error = nil
        var record = result.metadata
        for key in ["recordPath", "mediaRecordPath"] {
            if let path = record[key] {
                let root = artifact.url.deletingLastPathComponent().path + "/"
                guard path.hasPrefix(root), !path.dropFirst(root.count).split(separator: "/").contains("..") else {
                    throw ProjectStoreError.unsafePath(path)
                }
                record[key] = String(path.dropFirst(rootURL.path.count + 1))
            }
        }
        candidate.jobs[index].resultMetadata = record
        try commit(candidate)
        return manifest
    }

    public func inspectVideoAsset(id: UUID) async throws -> URL {
        guard let asset = manifest.assets.first(where: { $0.id == id }), let metadata = asset.metadata.video,
              let job = manifest.jobs.first(where: { $0.id == asset.jobID }),
              case .video(let request) = job.request.input else { throw ProjectStoreError.missingAsset }
        let url = try assetURL(for: asset)
        let actual = try await VideoMediaInspector.inspect(at: url, expected: request)
        guard actual == metadata else { throw ProjectStoreError.externalModification }
        _ = try assetURL(for: asset)
        return url
    }

    /// Reconcile only published PNGs in a recorded task's precisely named private directory.
    /// Never starts inference, deletes media, follows a symlink, or adopts an unknown task.
    public func recoverPublishedArtifacts() async throws -> ProjectManifest {
        try await recover(markInterrupted: false)
    }

    public func assetURL(for asset: ProjectAsset) throws -> URL {
        guard let registered = manifest.assets.first(where: { $0.id == asset.id }), registered == asset else {
            throw ProjectStoreError.missingAsset
        }
        try checkLocation()
        let file = try ProjectFiles.openRelativeFile(asset.relativePath, in: rootFD)
        Darwin.close(file)
        return rootURL.appendingPathComponent(asset.relativePath)
    }

    /// Re-reads and verifies the registered original before returning display-only audio data.
    /// The service exposes a resource URL plus bounded metadata, never the media bytes themselves.
    public func inspectAudio(documentID: UUID) throws -> ProjectAudioInspection {
        let index = try documentIndex(documentID)
        guard manifest.documents[index].kind == .audio,
              let draft = manifest.documents[index].audioDraft,
              draft.id == documentID,
              let asset = manifest.assets.first(where: { $0.id == draft.assetID }),
              asset.role == .original, asset.jobID == nil,
              let metadata = asset.metadata.audio else {
            throw ProjectStoreError.invalidProject("原声文档没有有效的已登记原件。")
        }
        let url = try assetURL(for: asset)
        let inspected = try AudioMediaInspector.inspect(at: url)
        try ProjectFiles.requireRegisteredAudio(inspected, matches: metadata)
        return ProjectAudioInspection(document: draft, asset: asset, url: url,
                                      metadata: metadata, waveform: inspected.waveform)
    }

    public func inspectAudioAsset(id: UUID) throws -> AudioInspection {
        guard let asset = manifest.assets.first(where: { $0.id == id }),
              let metadata = asset.metadata.audio else { throw ProjectStoreError.missingAsset }
        let policy = try ProjectFiles.inspectionPolicy(for: asset, jobs: manifest.jobs)
        let inspection = try AudioMediaInspector.inspect(at: try assetURL(for: asset), policy: policy)
        try ProjectFiles.requireRegisteredAudio(inspection, matches: metadata)
        return inspection
    }

    public func exportVideoAsset(id: UUID, to destination: URL) async throws {
        try await exportVideoAsset(id: id, to: destination, checkpoint: nil)
    }

    func exportVideoAsset(id: UUID, to destination: URL,
                          checkpoint: (@Sendable (ProjectExportCheckpoint) throws -> Void)?) async throws {
        guard let asset = manifest.assets.first(where: { $0.id == id }),
              let registered = asset.metadata.video else { throw ProjectStoreError.missingAsset }
        try checkLocation()
        guard destination.isFileURL, destination.path.hasPrefix("/"),
              !destination.lastPathComponent.isEmpty else {
            throw ProjectStoreError.unsafePath(destination.path)
        }
        let sourceURL = try await inspectVideoAsset(id: id)
        guard manifest.assets.first(where: { $0.id == id }) == asset else { throw ProjectStoreError.externalModification }
        try checkLocation()
        let source = try ProjectFiles.openRelativeFile(asset.relativePath, in: rootFD)
        defer { Darwin.close(source) }
        let parent = try ProjectFiles.openDirectory(destination.deletingLastPathComponent())
        defer { Darwin.close(parent) }
        try ProjectFiles.publishExport(to: destination, parent: parent, checkpoint: checkpoint,
                                       validate: { temporary in
            guard try VideoMediaInspector.contentSHA256(at: temporary, maximumBytes: registered.byteCount)
                    == registered.contentSHA256 else { throw ProjectStoreError.externalModification }
            guard try VideoMediaInspector.contentSHA256(at: sourceURL, maximumBytes: registered.byteCount)
                    == registered.contentSHA256 else { throw ProjectStoreError.externalModification }
        }) { target in
            var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
            var copied: UInt64 = 0
            while true {
                let count = Darwin.read(source, &buffer, buffer.count)
                if count == 0 {
                    guard copied == registered.byteCount else { throw ProjectStoreError.externalModification }
                    break
                }
                if count < 0 {
                    if errno == EINTR { continue }
                    throw ProjectFiles.error()
                }
                guard copied <= registered.byteCount, UInt64(count) <= registered.byteCount - copied else {
                    throw ProjectStoreError.externalModification
                }
                copied += UInt64(count)
                try buffer.withUnsafeBytes { bytes in
                    try ProjectFiles.writeAll(
                        UnsafeRawBufferPointer(rebasing: bytes[..<count]), to: target)
                }
            }
        }
    }

    public func exportAudioAsset(id: UUID, to destination: URL) throws {
        try exportAudioAsset(id: id, to: destination, checkpoint: nil)
    }

    func exportAudioAsset(id: UUID, to destination: URL,
                          checkpoint: (@Sendable (ProjectExportCheckpoint) throws -> Void)?) throws {
        guard let asset = manifest.assets.first(where: { $0.id == id }),
              let registered = asset.metadata.audio else { throw ProjectStoreError.missingAsset }
        try checkLocation()
        guard destination.isFileURL, destination.path.hasPrefix("/"),
              !destination.lastPathComponent.isEmpty else {
            throw ProjectStoreError.unsafePath(destination.path)
        }
        let policy = try ProjectFiles.inspectionPolicy(for: asset, jobs: manifest.jobs)
        let sourceURL = rootURL.appendingPathComponent(asset.relativePath)
        let sourceInspection = try AudioMediaInspector.inspect(at: sourceURL, policy: policy)
        try ProjectFiles.requireRegisteredAudio(sourceInspection, matches: registered)
        let source = try ProjectFiles.openRelativeFile(asset.relativePath, in: rootFD)
        defer { Darwin.close(source) }
        let parent = try ProjectFiles.openDirectory(destination.deletingLastPathComponent())
        defer { Darwin.close(parent) }
        try ProjectFiles.publishExport(to: destination, parent: parent, checkpoint: checkpoint,
                                       validate: { temporary in
            let staged = try AudioMediaInspector.inspect(at: temporary, policy: policy)
            try ProjectFiles.requireRegisteredAudio(staged, matches: registered)
        }) { target in
            var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
            while true {
                let count = Darwin.read(source, &buffer, buffer.count)
                if count == 0 { break }
                if count < 0 {
                    if errno == EINTR { continue }
                    throw ProjectFiles.error()
                }
                try buffer.withUnsafeBytes { bytes in
                    try ProjectFiles.writeAll(
                        UnsafeRawBufferPointer(rebasing: bytes[..<count]), to: target)
                }
            }
        }
    }

    /// Copies the selected inode into project ownership before validating the owned bytes.
    /// A failed import may leave only that unregistered file for manual recovery; opening a
    /// project never scans for or guesses ownership of such files.
    public func importAudio(at source: URL, name: String,
                            origin: AudioOrigin = .importedFile) throws -> ProjectManifest {
        try ProjectFiles.validateAudioName(name)
        try checkLocation()
        let imported = try AudioMediaInspector.withOriginalSource(at: source) { sourceFD, byteCount in
            let (assetID, directory) = try ProjectFiles.createAudioDirectory(in: rootFD)
            defer { Darwin.close(directory) }
            let pendingName = "source.pending"
            let destination = openat(directory, pendingName,
                                     O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard destination >= 0 else { throw ProjectFiles.error() }
            do {
                try AudioMediaInspector.copyOriginal(from: sourceFD, byteCount: byteCount, to: destination)
                guard fsync(destination) == 0 else { throw ProjectFiles.error() }
                Darwin.close(destination)
            } catch {
                Darwin.close(destination)
                throw error
            }
            let pendingURL = rootURL.appendingPathComponent("Audio/\(assetID.uuidString)/\(pendingName)")
            let inspection = try AudioMediaInspector.inspect(at: pendingURL)
            let finalName = inspection.format.container == .wav ? "source.wav" : "source.caf"
            guard renameatx_np(directory, pendingName, directory, finalName, UInt32(RENAME_EXCL)) == 0 else {
                if errno == EEXIST { throw ProjectStoreError.alreadyExists(finalName) }
                throw ProjectFiles.error()
            }
            guard fsync(directory) == 0 else { throw ProjectFiles.error() }
            return (assetID, inspection, finalName)
        }
        let (assetID, inspection, finalName) = imported
        let directoryName = assetID.uuidString
        let relative = "Audio/\(directoryName)/\(finalName)"
        let audio = AudioAssetMetadata(format: inspection.format, contentSHA256: inspection.contentSHA256,
                                       origin: origin)
        let asset = ProjectAsset(id: assetID, jobID: nil, relativePath: relative,
                                 mediaType: ProjectFiles.audioMediaType(inspection.format.container),
                                 role: .original, metadata: .init(audio: audio), name: name)
        let documentID = UUID()
        let draft = AudioDraftDocument(id: documentID, assetID: assetID)
        let document = ProjectDocument(id: documentID, name: name, kind: .audio, audioDraft: draft)
        var candidate = manifest
        candidate.assets.append(asset)
        candidate.documents.append(document)
        candidate.activeDocumentID = documentID
        try commit(candidate)
        return manifest
    }

    /// Persists the exact capture destination before returning it to a recorder.
    public func reserveAudioCapture(name: String) throws -> AudioCaptureReservation {
        try ProjectFiles.validateAudioName(name)
        try checkLocation()
        let (id, directory) = try ProjectFiles.createAudioDirectory(in: rootFD)
        var retained = false
        defer { if !retained { Darwin.close(directory) } }
        var info = stat()
        guard fstatat(directory, "source.caf", &info, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else {
            throw ProjectStoreError.alreadyExists("Audio/\(id.uuidString)/source.caf")
        }
        let reservation = AudioCaptureReservation(id: id,
            relativePath: "Audio/\(id.uuidString)/source.caf", name: name)
        var candidate = manifest
        candidate.pendingAudioCaptures.append(reservation)
        try commit(candidate)
        captureDirectories[id] = directory
        retained = true
        return reservation
    }

    public func audioCaptureURL(id: UUID) throws -> URL {
        guard let reservation = manifest.pendingAudioCaptures.first(where: { $0.id == id }) else {
            throw ProjectStoreError.invalidProject("找不到待录制的音频预约。")
        }
        try checkLocation()
        let directory = try retainedCaptureDirectory(id: id)
        try verifyRootedCaptureDirectory(id: id, retained: directory)
        var info = stat()
        let status = fstatat(directory, "source.caf", &info, AT_SYMLINK_NOFOLLOW)
        guard status != 0, errno == ENOENT else {
            throw ProjectStoreError.alreadyExists(reservation.relativePath)
        }
        return rootURL.appendingPathComponent(reservation.relativePath)
    }

    /// Creates the recording leaf exactly once beneath the retained reservation directory.
    /// The returned owner keeps both the leaf and its original parent open through flush.
    func createAudioCaptureFile(id: UUID) throws -> AudioCaptureFile {
        guard let reservation = manifest.pendingAudioCaptures.first(where: { $0.id == id }) else {
            throw ProjectStoreError.invalidProject("找不到待录制的音频预约。")
        }
        try Task.checkCancellation()
        try checkLocation()
        let directory = try retainedCaptureDirectory(id: id)
        try verifyRootedCaptureDirectory(id: id, retained: directory)
        try Task.checkCancellation()
        let descriptor = openat(directory, "source.caf",
                                O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            if errno == EEXIST { throw ProjectStoreError.alreadyExists(reservation.relativePath) }
            throw ProjectFiles.error()
        }
        var transferred = false
        var parentDuplicate: Int32 = -1
        defer {
            if !transferred {
                if parentDuplicate >= 0 { Darwin.close(parentDuplicate) }
                Darwin.close(descriptor)
            }
        }
        var rootInfo = stat(), directoryInfo = stat(), fileInfo = stat()
        guard fstat(rootFD, &rootInfo) == 0, fstat(directory, &directoryInfo) == 0,
              fstat(descriptor, &fileInfo) == 0 else { throw ProjectFiles.error() }
        guard fileInfo.st_mode & S_IFMT == S_IFREG, fileInfo.st_nlink == 1 else {
            throw ProjectStoreError.unsafePath(reservation.relativePath)
        }
        parentDuplicate = dup(directory)
        guard parentDuplicate >= 0 else { throw ProjectFiles.error() }
        guard fsync(directory) == 0 else { throw ProjectFiles.error() }
        let capture = AudioCaptureFile(
            id: id, url: rootURL.appendingPathComponent(reservation.relativePath),
            fileDescriptor: descriptor, directoryDescriptor: parentDuplicate,
            rootIdentity: AudioCaptureIdentity(rootInfo),
            directoryIdentity: AudioCaptureIdentity(directoryInfo),
            fileIdentity: AudioCaptureIdentity(fileInfo)
        )
        transferred = true
        return capture
    }

    /// Finalization never removes or rewrites the capture. Any validation or save failure keeps
    /// both the persisted reservation and its raw file available for an explicit retry.
    public func finalizeAudioCapture(id: UUID) throws -> ProjectManifest {
        let capture = try openExistingAudioCapture(id: id)
        return try finalizeAudioCapture(id: id, capture: capture)
    }

    func finalizeAudioCapture(
        id: UUID,
        capture: AudioCaptureFile,
        afterInspection: (@Sendable (Int32) throws -> Void)? = nil
    ) throws -> ProjectManifest {
        guard let reservationIndex = manifest.pendingAudioCaptures.firstIndex(where: { $0.id == id }) else {
            throw ProjectStoreError.invalidProject("找不到待恢复的音频预约。")
        }
        guard capture.id == id else { throw ProjectStoreError.unsafePath("capture identity") }
        try verifyCapture(capture, expectedFingerprint: nil)
        _ = try capture.sealAndFingerprint()
        if let error = capture.synchronize() { throw AudioMediaError.io(error) }
        let reservation = manifest.pendingAudioCaptures[reservationIndex]
        let descriptor = try capture.duplicateDescriptor()
        defer { Darwin.close(descriptor) }
        let checked = try AudioMediaInspector.inspectCapture(descriptor: descriptor)
        let inspection = checked.inspection
        guard inspection.format.container == .caf else { throw AudioMediaError.unsupportedFormat }
        try afterInspection?(descriptor)
        try verifyCapture(capture, expectedFingerprint: checked.fingerprint)

        let metadata = AudioAssetMetadata(format: inspection.format,
                                          contentSHA256: inspection.contentSHA256,
                                          origin: .microphone)
        let asset = ProjectAsset(id: id, jobID: nil, relativePath: reservation.relativePath,
                                 mediaType: ProjectFiles.audioMediaType(.caf), role: .original,
                                 metadata: .init(audio: metadata), name: reservation.name)
        let documentID = UUID()
        let document = ProjectDocument(id: documentID, name: reservation.name, kind: .audio,
                                       audioDraft: .init(id: documentID, assetID: id))
        var candidate = manifest
        candidate.pendingAudioCaptures.remove(at: reservationIndex)
        candidate.assets.append(asset)
        candidate.documents.append(document)
        candidate.activeDocumentID = documentID
        // This is the observed-boundary seal: the inode fingerprint used for metadata is
        // checked again immediately before publishing the manifest mutation.
        try verifyCapture(capture, expectedFingerprint: checked.fingerprint)
        try commit(candidate)
        if let directory = captureDirectories.removeValue(forKey: id) { Darwin.close(directory) }
        return manifest
    }

    private func retainedCaptureDirectory(id: UUID) throws -> Int32 {
        if let descriptor = captureDirectories[id] { return descriptor }
        let descriptor = try ProjectFiles.openRelativeDirectory("Audio/\(id.uuidString)", in: rootFD)
        captureDirectories[id] = descriptor
        return descriptor
    }

    private func verifyRootedCaptureDirectory(id: UUID, retained: Int32) throws {
        let rooted = try ProjectFiles.openRelativeDirectory("Audio/\(id.uuidString)", in: rootFD)
        defer { Darwin.close(rooted) }
        var expected = stat(), actual = stat()
        guard fstat(retained, &expected) == 0, fstat(rooted, &actual) == 0 else {
            throw ProjectFiles.error()
        }
        guard AudioCaptureIdentity(expected) == AudioCaptureIdentity(actual) else {
            throw ProjectStoreError.unsafePath("Audio/\(id.uuidString)")
        }
    }

    private func openExistingAudioCapture(id: UUID) throws -> AudioCaptureFile {
        guard let reservation = manifest.pendingAudioCaptures.first(where: { $0.id == id }) else {
            throw ProjectStoreError.invalidProject("找不到待恢复的音频预约。")
        }
        try checkLocation()
        let directory = try retainedCaptureDirectory(id: id)
        try verifyRootedCaptureDirectory(id: id, retained: directory)
        let descriptor = openat(directory, "source.caf", O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw ProjectFiles.error() }
        var transferred = false
        var parentDuplicate: Int32 = -1
        defer {
            if !transferred {
                if parentDuplicate >= 0 { Darwin.close(parentDuplicate) }
                Darwin.close(descriptor)
            }
        }
        var rootInfo = stat(), directoryInfo = stat(), fileInfo = stat()
        guard fstat(rootFD, &rootInfo) == 0, fstat(directory, &directoryInfo) == 0,
              fstat(descriptor, &fileInfo) == 0 else { throw ProjectFiles.error() }
        guard fileInfo.st_mode & S_IFMT == S_IFREG, fileInfo.st_nlink == 1 else {
            throw ProjectStoreError.unsafePath(reservation.relativePath)
        }
        parentDuplicate = dup(directory)
        guard parentDuplicate >= 0 else { throw ProjectFiles.error() }
        let capture = AudioCaptureFile(
            id: id, url: rootURL.appendingPathComponent(reservation.relativePath),
            fileDescriptor: descriptor, directoryDescriptor: parentDuplicate,
            rootIdentity: AudioCaptureIdentity(rootInfo),
            directoryIdentity: AudioCaptureIdentity(directoryInfo),
            fileIdentity: AudioCaptureIdentity(fileInfo)
        )
        transferred = true
        return capture
    }

    private func verifyCapture(_ capture: AudioCaptureFile,
                               expectedFingerprint: AudioCaptureFingerprint?) throws {
        try checkLocation()
        var rootInfo = stat()
        guard fstat(rootFD, &rootInfo) == 0,
              AudioCaptureIdentity(rootInfo) == capture.rootIdentity else {
            throw ProjectStoreError.unsafePath("project root")
        }
        let retained = try retainedCaptureDirectory(id: capture.id)
        try verifyRootedCaptureDirectory(id: capture.id, retained: retained)
        let held = try capture.currentIdentities()
        guard held.0 == capture.directoryIdentity, held.1 == capture.fileIdentity else {
            throw ProjectStoreError.externalModification
        }
        if let expectedFingerprint,
           try capture.fingerprint() != expectedFingerprint {
            throw ProjectStoreError.externalModification
        }
        var directoryInfo = stat()
        guard fstat(retained, &directoryInfo) == 0,
              AudioCaptureIdentity(directoryInfo) == capture.directoryIdentity else {
            throw ProjectStoreError.unsafePath("Audio/\(capture.id.uuidString)")
        }
        let rootedFile = openat(retained, "source.caf", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard rootedFile >= 0 else { throw ProjectFiles.error() }
        defer { Darwin.close(rootedFile) }
        var fileInfo = stat()
        guard fstat(rootedFile, &fileInfo) == 0,
              fileInfo.st_mode & S_IFMT == S_IFREG, fileInfo.st_nlink == 1,
              AudioCaptureIdentity(fileInfo) == capture.fileIdentity else {
            throw ProjectStoreError.externalModification
        }
        if let expectedFingerprint,
           AudioCaptureFingerprint(fileInfo) != expectedFingerprint {
            throw ProjectStoreError.externalModification
        }
    }

    public func saveAudioDraft(_ draft: AudioDraftDocument, documentID: UUID,
                               expectedRevision: UInt64) throws -> ProjectManifest {
        let index = try documentIndex(documentID)
        guard manifest.documents[index].kind == .audio,
              let current = manifest.documents[index].audioDraft,
              current.id == documentID, draft.id == documentID,
              current.assetID == draft.assetID else {
            throw ProjectStoreError.invalidProject("原声稿与原声文档或原件编号不匹配。")
        }
        guard current.revision == expectedRevision else { throw ProjectStoreError.externalModification }
        guard expectedRevision < UInt64.max, draft.revision == expectedRevision + 1 else {
            throw ProjectStoreError.invalidProject("原声稿修订编号必须连续递增且不能溢出。")
        }
        try ProjectFiles.validateAudioDraft(draft, asset: manifest.assets.first { $0.id == draft.assetID })
        var candidate = manifest
        candidate.documents[index].audioDraft = draft
        try commit(candidate)
        return manifest
    }

    public func exportAudioClip(documentID: UUID, range: AudioFrameRange,
                                to destination: URL) throws {
        let index = try documentIndex(documentID)
        guard manifest.documents[index].kind == .audio,
              let draft = manifest.documents[index].audioDraft,
              let asset = manifest.assets.first(where: { $0.id == draft.assetID }),
              let audio = asset.metadata.audio else { throw ProjectStoreError.missingAsset }
        try ProjectFiles.validateAudioRange(range, frameCount: audio.format.frameCount)
        try checkLocation()
        guard destination.isFileURL, destination.path.hasPrefix("/"),
              !destination.lastPathComponent.isEmpty else { throw ProjectStoreError.unsafePath(destination.path) }
        let source = try assetURL(for: asset)
        let sourceInspection = try AudioMediaInspector.inspect(at: source)
        try ProjectFiles.requireRegisteredAudio(sourceInspection, matches: audio)
        let parent = try ProjectFiles.openDirectory(destination.deletingLastPathComponent())
        defer { Darwin.close(parent) }
        try ProjectFiles.publishExport(to: destination, parent: parent, checkpoint: nil, validate: { temporary in
            let output = try AudioMediaInspector.inspect(at: temporary)
            guard output.format.container == .wav, output.format.floatingPoint,
                  output.format.bitDepth == 32, output.format.sampleRate == audio.format.sampleRate,
                  output.format.channelCount == audio.format.channelCount,
                  output.format.frameCount == range.endFrame - range.startFrame else {
                throw AudioMediaError.invalidMedia("选区导出文件的格式或帧数验证失败")
            }
        }) { target in
            try AudioMediaInspector.writeFloat32WAV(from: source, registered: audio,
                                                    range: range, to: target)
        }
    }

    /// Export is a byte-for-byte copy staged in the system's same-volume replacement
    /// directory. A Save panel grants the destination file, not permission to create siblings.
    /// RENAME_EXCL publishes atomically without replacing a destination that appeared meanwhile.
    public func export(assetID: UUID, to destination: URL) throws {
        try export(assetID: assetID, to: destination, checkpoint: nil)
    }

    func export(assetID: UUID, to destination: URL,
                checkpoint: (@Sendable (ProjectExportCheckpoint) throws -> Void)?) throws {
        guard let asset = manifest.assets.first(where: { $0.id == assetID }) else { throw ProjectStoreError.missingAsset }
        try checkLocation()
        guard asset.metadata.video == nil else { throw ProjectStoreError.invalidProject("请使用视频安全导出入口。") }
        guard destination.isFileURL, destination.path.hasPrefix("/"),
              !destination.lastPathComponent.isEmpty else { throw ProjectStoreError.unsafePath(destination.path) }
        if let audio = asset.metadata.audio {
            let policy = try ProjectFiles.inspectionPolicy(for: asset, jobs: manifest.jobs)
            let inspection = try AudioMediaInspector.inspect(
                at: rootURL.appendingPathComponent(asset.relativePath), policy: policy)
            try ProjectFiles.requireRegisteredAudio(inspection, matches: audio)
        }
        let source = try ProjectFiles.openRelativeFile(asset.relativePath, in: rootFD)
        defer { Darwin.close(source) }
        let parent = try ProjectFiles.openDirectory(destination.deletingLastPathComponent())
        defer { Darwin.close(parent) }
        try ProjectFiles.publishExport(to: destination, parent: parent, checkpoint: checkpoint) { target in
            var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
            while true {
                let count = Darwin.read(source, &buffer, buffer.count)
                if count == 0 { break }
                if count < 0 {
                    if errno == EINTR { continue }
                    throw ProjectFiles.error()
                }
                try buffer.withUnsafeBytes { bytes in
                    try ProjectFiles.writeAll(UnsafeRawBufferPointer(rebasing: bytes[..<count]), to: target)
                }
            }
        }
    }

    /// Capture a persisted run, never the current parameter panel. This version identifies
    /// the new export snapshot; schema2 did not record historical asset versions.
    public func prepareRecipePNG(assetID: UUID, disclosure: RecipeDisclosure) throws -> Data {
        if let asset = manifest.assets.first(where: { $0.id == assetID }),
           let job = manifest.jobs.first(where: { $0.id == asset.jobID }), job.imageReferenceAssetID != nil {
            throw ProjectStoreError.invalidProject("此候选需要项目内的参考图，当前 PNG 配方不能完整携带该依赖。请保存项目；仍可普通导出 PNG。")
        }
        try checkLocation()
        try verifyUnchangedManifest()
        guard let asset = manifest.assets.first(where: { $0.id == assetID }),
              let job = manifest.jobs.first(where: { $0.id == asset.jobID }),
              job.state == .completed, job.artifactIDs.contains(asset.id),
              case .image(let input) = job.request.input else { throw ProjectStoreError.missingAsset }
        let png = try ProjectFiles.read(relative: asset.relativePath, in: rootFD, limit: 32 * 1024 * 1024)
        _ = try Self.validateRecipePNG(png)
        func field(_ value: String?) -> RecipeField<String> {
            guard let value, !value.isEmpty, value != "unrecorded" else { return .unknown }
            return .value(value)
        }
        let recipe = GenerationRecipe(assetID: asset.id, assetVersion: UUID(), runID: job.id,
            modelSource: field(job.resultMetadata["modelRepository"]),
            modelRevision: field(job.resultMetadata["modelRevision"] ?? job.request.model.revision),
            weightsManifestSHA256: .unknown, prompt: .value(input.prompt), structuredInputRevision: .notApplicable,
            seed: .value(String(input.seed)), steps: .value(input.steps), guidance: .value(Double(input.guidanceScale)),
            width: .value(input.width), height: .value(input.height), scheduler: .unknown,
            computePrecision: .unknown, quantization: .unknown, implementationVersion: .unknown,
            mediaPayloadSHA256: .unknown, parents: [], claim: .callerDeclared)
        return try PNGRecipeCodec.embedding(recipe, in: png, disclosure: disclosure)
    }

    /// Open only the explicitly selected regular file, with the same no-follow walk as projects.
    public static func readRecipePNG(at url: URL) throws -> (Data, PNGRecipeInspection) {
        guard url.isFileURL else { throw ProjectStoreError.unsafePath(url.path) }
        let parent = try ProjectFiles.openDirectory(url.deletingLastPathComponent())
        defer { Darwin.close(parent) }
        let data = try ProjectFiles.read(relative: url.lastPathComponent, in: parent, limit: 32 * 1024 * 1024)
        return (data, try validateRecipePNG(data))
    }

    public static func readMusicCondition(at url: URL) throws -> (draft: MusicCreationDraft, durationText: String) {
        guard url.isFileURL else { throw ProjectStoreError.unsafePath(url.path) }
        let parent = try ProjectFiles.openDirectory(url.deletingLastPathComponent())
        defer { Darwin.close(parent) }
        let data = try ProjectFiles.read(relative: url.lastPathComponent, in: parent, limit: 128 * 1024)
        return try MusicConditionFile.decode(data)
    }

    public static func publishMusicCondition(_ data: Data, to destination: URL) throws {
        _ = try MusicConditionFile.decode(data)
        guard destination.isFileURL, destination.path.hasPrefix("/"), !destination.lastPathComponent.isEmpty else {
            throw ProjectStoreError.unsafePath(destination.path)
        }
        let parent = try ProjectFiles.openDirectory(destination.deletingLastPathComponent())
        defer { Darwin.close(parent) }
        try ProjectFiles.publishExport(to: destination, parent: parent, checkpoint: nil, validate: { temporary in
            let directory = try ProjectFiles.openDirectory(temporary.deletingLastPathComponent())
            defer { Darwin.close(directory) }
            let actual = try ProjectFiles.read(relative: temporary.lastPathComponent, in: directory, limit: 128 * 1024)
            guard actual == data else { throw ProjectStoreError.externalModification }
            _ = try MusicConditionFile.decode(actual)
        }) { target in
            try data.withUnsafeBytes { try ProjectFiles.writeAll($0, to: target) }
        }
    }

    public static func publishRecipePNG(_ data: Data, to destination: URL) throws {
        try publishRecipePNG(data, to: destination, checkpoint: nil)
    }

    static func publishRecipePNG(_ data: Data, to destination: URL,
                                 checkpoint: (@Sendable (ProjectExportCheckpoint) throws -> Void)?) throws {
        let inspection = try validateRecipePNG(data)
        guard inspection.recipe != nil else { throw PNGRecipeError.invalidRecipe }
        guard destination.isFileURL, destination.path.hasPrefix("/"), !destination.lastPathComponent.isEmpty else {
            throw ProjectStoreError.unsafePath(destination.path)
        }
        let parent = try ProjectFiles.openDirectory(destination.deletingLastPathComponent())
        defer { Darwin.close(parent) }
        try ProjectFiles.publishExport(to: destination, parent: parent, checkpoint: checkpoint) { target in
            try data.withUnsafeBytes { try ProjectFiles.writeAll($0, to: target) }
        }
    }

    /// Source metadata is displayed separately. Only editable prompt/seed enter a NEW draft.
    public func createRecipeDocument(_ recipe: GenerationRecipe) throws -> ProjectManifest {
        _ = try GenerationRecipeCodec.encode(recipe, disclosure: .privateArchive)
        guard case .value(let prompt) = recipe.prompt else { throw PNGRecipeError.invalidRecipe }
        let seed: String?
        if case .value(let value) = recipe.seed { seed = value } else { seed = nil }
        return try createDocument(name: "来自 PNG 配方", draft: .init(prompt: prompt, randomSeed: seed == nil, seedText: seed ?? "0"))
    }

    private static func validateRecipePNG(_ data: Data) throws -> PNGRecipeInspection {
        let inspection = try PNGRecipeCodec.inspect(data)
        // Decode bounded pixels without sending compressed profiles, EXIF or arbitrary text
        // to ImageIO. Original chunks remain byte-exact in the actual exported data.
        let bytes = [UInt8](data)
        var pixels = Data(bytes.prefix(8)); var compressed = Data(); var header: [UInt8] = []; var offset = 8
        while offset < bytes.count {
            let length = bytes[offset..<offset+4].reduce(0) { ($0 << 8) | Int($1) }
            let type = String(bytes: bytes[offset+4..<offset+8], encoding: .ascii)!
            let end = offset + 12 + length
            if type == "IHDR" { header = Array(bytes[offset+8..<end-4]) }
            if type == "IDAT" { compressed.append(contentsOf: bytes[offset+8..<end-4]) }
            if ["IHDR", "PLTE", "IDAT", "IEND", "tRNS"].contains(type) { pixels.append(contentsOf: bytes[offset..<end]) }
            offset = end
        }
        try verifyPNGScanlines(compressed, header: header)
        guard let source = CGImageSourceCreateWithData(pixels as CFData, nil),
              CGImageSourceGetCount(source) == 1, CGImageSourceGetStatus(source) == .statusComplete,
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              image.width == inspection.width, image.height == inspection.height else {
            throw ProjectStoreError.invalidImage("PNG")
        }
        return inspection
    }

    /// ImageIO can repair invalid zlib streams. Require exact filtered scanline bytes first,
    /// with a 64KiB output window, declared pixel budget and no compressed metadata parsing.
    private static func verifyPNGScanlines(_ compressed: Data, header: [UInt8]) throws {
        let width = header[0..<4].reduce(0) { $0 << 8 | Int($1) }
        let height = header[4..<8].reduce(0) { $0 << 8 | Int($1) }
        let channels = [0: 1, 2: 3, 3: 1, 4: 2, 6: 4][Int(header[9])]!
        let bits = channels * Int(header[8])
        let passes: [(Int, Int, Int, Int)] = header[12] == 0
            ? [(0, 0, 1, 1)]
            : [(0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4), (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)]
        var rowStarts = Set<Int>(); var expected = 0
        for (x, y, dx, dy) in passes where width > x && height > y {
            let columns = (width - x + dx - 1) / dx
            let rows = (height - y + dy - 1) / dy
            let rowBytes = (columns * bits + 7) / 8 + 1
            for _ in 0..<rows { rowStarts.insert(expected); expected += rowBytes }
        }
        var stream = z_stream()
        guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw ProjectStoreError.invalidImage("PNG 压缩流")
        }
        defer { inflateEnd(&stream) }
        var output = [UInt8](repeating: 0, count: 64 * 1024)
        try compressed.withUnsafeBytes { raw in
            stream.next_in = UnsafeMutablePointer(mutating: raw.bindMemory(to: UInt8.self).baseAddress)
            stream.avail_in = uInt(raw.count)
            var produced = 0
            while true {
                let previousIn = stream.avail_in
                let status: Int32 = output.withUnsafeMutableBytes { buffer in
                    stream.next_out = buffer.bindMemory(to: UInt8.self).baseAddress
                    stream.avail_out = uInt(buffer.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let count = output.count - Int(stream.avail_out)
                guard produced + count <= expected else { throw ProjectStoreError.invalidImage("PNG 像素数据超长") }
                for offset in 0..<count where rowStarts.contains(produced + offset) {
                    guard output[offset] <= 4 else { throw ProjectStoreError.invalidImage("PNG 滤波数据") }
                }
                produced += count
                if status == Z_STREAM_END {
                    guard stream.avail_in == 0, produced == expected else { throw ProjectStoreError.invalidImage("PNG 压缩流长度") }
                    break
                }
                guard status == Z_OK, count > 0 || stream.avail_in < previousIn else { throw ProjectStoreError.invalidImage("PNG 压缩流损坏") }
            }
        }
    }

    public func flush() throws {
        try checkLocation()
        // Each mutation is already durable. Verify the manifest still exists; a disconnected
        // volume must not be mistaken for a successful close merely because state is in memory.
        try verifyUnchangedManifest()
        guard fsync(rootFD) == 0 else { throw ProjectFiles.error() }
    }

    private func verifyUnchangedManifest() throws {
        let data = try ProjectFiles.read(relative: Self.manifestFilename, in: rootFD, limit: 32 * 1_024 * 1_024)
        let current: ProjectManifest
        do { current = try JSONDecoder().decode(ProjectManifest.self, from: data) }
        catch { throw ProjectStoreError.externalModification }
        guard current == manifest else {
            throw ProjectStoreError.externalModification
        }
        // Swift String equality accepts canonically equivalent Unicode. That is useful for
        // structural JSON equivalence, but a text draft is user-authored bytes: an external
        // normalization change must not be overwritten by this session's next save.
        for (persisted, expected) in zip(current.documents, manifest.documents) {
            switch (persisted.textDraft, expected.textDraft) {
            case let (.some(actual), .some(saved)):
                guard actual.text.utf8.elementsEqual(saved.text.utf8) else {
                    throw ProjectStoreError.externalModification
                }
            case (.none, .none):
                break
            default:
                throw ProjectStoreError.externalModification
            }
            switch (persisted.textSources, expected.textSources) {
            case let (.some(actual), .some(saved)):
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                guard try encoder.encode(actual) == encoder.encode(saved) else {
                    throw ProjectStoreError.externalModification
                }
            case (.none, .none): break
            default: throw ProjectStoreError.externalModification
            }
            switch (persisted.audioDraft, expected.audioDraft) {
            case let (.some(actual), .some(saved)):
                guard actual.note.utf8.elementsEqual(saved.note.utf8),
                      actual.clips.count == saved.clips.count else {
                    throw ProjectStoreError.externalModification
                }
                for (actualClip, savedClip) in zip(actual.clips, saved.clips) {
                    guard actualClip.name.utf8.elementsEqual(savedClip.name.utf8),
                          actualClip.note.utf8.elementsEqual(savedClip.note.utf8) else {
                        throw ProjectStoreError.externalModification
                    }
                }
            case (.none, .none):
                break
            default:
                throw ProjectStoreError.externalModification
            }
            switch (persisted.videoCreation, expected.videoCreation) {
            case let (.some(actual), .some(saved)):
                guard actual.hasSameEditableRepresentation(as: saved) else { throw ProjectStoreError.externalModification }
            case (.none, .none): break
            default: throw ProjectStoreError.externalModification
            }
            switch (persisted.audioCreation, expected.audioCreation) {
            case let (.some(actual), .some(saved)):
                guard actual.prompt.utf8.elementsEqual(saved.prompt.utf8),
                      actual.durationText.utf8.elementsEqual(saved.durationText.utf8),
                      actual.seedText.utf8.elementsEqual(saved.seedText.utf8),
                      actual.stepsText.utf8.elementsEqual(saved.stepsText.utf8),
                      actual.guidanceText.utf8.elementsEqual(saved.guidanceText.utf8),
                      actual.strengthText.utf8.elementsEqual(saved.strengthText.utf8) else {
                    throw ProjectStoreError.externalModification
                }
            case (.none, .none):
                break
            default:
                throw ProjectStoreError.externalModification
            }
        }
        guard current.assets.count == manifest.assets.count else {
            throw ProjectStoreError.externalModification
        }
        for (persisted, expected) in zip(current.assets, manifest.assets) {
            guard persisted.name.utf8.elementsEqual(expected.name.utf8),
                  persisted.note.utf8.elementsEqual(expected.note.utf8) else {
                throw ProjectStoreError.externalModification
            }
        }
        guard current.pendingAudioCaptures.count == manifest.pendingAudioCaptures.count else {
            throw ProjectStoreError.externalModification
        }
        for (persisted, expected) in zip(current.pendingAudioCaptures, manifest.pendingAudioCaptures) {
            guard persisted.name.utf8.elementsEqual(expected.name.utf8) else {
                throw ProjectStoreError.externalModification
            }
        }
    }

    /// The host calls this only after all jobs have drained and terminal records are saved.
    /// Failure leaves the session open, so the user can reconnect the drive and retry.
    /// A host with no pending outcome or changed draft may explicitly preserve an external
    /// edit while releasing its session. This never writes the in-memory snapshot over it.
    public func close(preserveExternalChanges: Bool = false) throws {
        guard !isClosed else { return }
        do { try flush() }
        catch ProjectStoreError.externalModification where preserveExternalChanges {
            try checkLocation()
            guard fsync(rootFD) == 0 else { throw ProjectFiles.error() }
        }
        for descriptor in captureDirectories.values { Darwin.close(descriptor) }
        captureDirectories.removeAll()
        try ProjectFiles.unlock(lockFD)
        Darwin.close(lockFD)
        Darwin.close(rootFD)
        isClosed = true
    }

    private func recoverOnOpen() async throws -> ProjectStore {
        _ = try await recover(markInterrupted: true)
        return self
    }

    private func recover(markInterrupted: Bool) async throws -> ProjectManifest {
        try checkLocation()
        let revision = manifest.revision
        var candidate = manifest
        if markInterrupted {
            for index in candidate.documents.indices {
                guard var state = candidate.documents[index].pitchAnalysis, let id = state.selectedAssetID,
                      !state.acceptedAssetIDs.contains(id), !state.expiredAssetIDs.contains(id) else { continue }
                state.expiredAssetIDs.append(id); candidate.documents[index].pitchAnalysis = state
            }
            for index in candidate.jobs.indices where !candidate.jobs[index].state.isTerminal {
                candidate.jobs[index].state = .interrupted
                candidate.jobs[index].error = "上次运行未正常结束。已保留记录，不会自动重新生成。"
            }
        }
        let taskFD = try ProjectFiles.openRelativeDirectory("Tasks", in: rootFD)
        defer { Darwin.close(taskFD) }
        let names = try ProjectFiles.directoryNames(taskFD)
        for name in names.sorted() {
            guard let jobID = ProjectFiles.taskOwner(name),
                  let index = candidate.jobs.firstIndex(where: { $0.id == jobID }) else { continue }
            if case .pitch = candidate.jobs[index].request.input { continue }
            if case .singing = candidate.jobs[index].request.input { continue }
            let isAudio: Bool, isVideo: Bool
            switch candidate.jobs[index].request.input {
            case .audio: isAudio = true; isVideo = false
            case .video: isAudio = false; isVideo = true
            default: isAudio = false; isVideo = false
            }
            // One video request publishes at most one candidate. Extra owned task
            // directories remain untouched for diagnosis; they must not invalidate
            // a project that already recovered or registered its candidate.
            if isVideo, !candidate.jobs[index].artifactIDs.isEmpty { continue }
            let relative = isAudio ? "Tasks/\(name)/job/output.wav" :
                (isVideo ? "Tasks/\(name)/output.mp4" : "Tasks/\(name)/image.png")
            guard !candidate.assets.contains(where: { $0.relativePath == relative }) else { continue }
            do {
                // Inspect the final entry through a safely opened directory descriptor as well;
                // AT_SYMLINK_NOFOLLOW alone does not protect intermediate path components.
                let publishedDirectory = try ProjectFiles.openRelativeDirectory(name, in: taskFD)
                var leafDirectory = publishedDirectory
                if isAudio {
                    guard name == name.lowercased() else {
                        Darwin.close(publishedDirectory)
                        throw ProjectStoreError.unsafePath(relative)
                    }
                    do {
                        leafDirectory = try ProjectFiles.openRelativeDirectory("job", in: publishedDirectory)
                    } catch {
                        Darwin.close(publishedDirectory)
                        throw error
                    }
                    Darwin.close(publishedDirectory)
                }
                var info = stat()
                let leaf = isAudio ? "output.wav" : (isVideo ? "output.mp4" : "image.png")
                let status = fstatat(leafDirectory, leaf, &info, AT_SYMLINK_NOFOLLOW)
                let failure = errno
                Darwin.close(leafDirectory)
                // Partial directories are normal after interruption. A missing final leaf is not an error.
                if status != 0, failure == ENOENT { continue }
                guard status == 0 else { throw ProjectStoreError.io(String(cString: strerror(failure))) }
                let asset: ProjectAsset
                if case .video(let video) = candidate.jobs[index].request.input {
                    let url = rootURL.appendingPathComponent(relative)
                    _ = try ProjectFiles.relativeVideoArtifact(url, root: rootURL, jobID: jobID)
                    let metadata = try await VideoMediaInspector.inspect(at: url, expected: video)
                    try checkLocation()
                    guard manifest.revision == revision else { throw ProjectStoreError.externalModification }
                    asset = ProjectAsset(jobID: jobID, relativePath: relative, mediaType: "video/mp4",
                        metadata: .init(width: metadata.width, height: metadata.height, video: metadata),
                        name: "恢复的视频候选")
                } else if case .audio(let audio) = candidate.jobs[index].request.input {
                    let url = rootURL.appendingPathComponent(relative)
                    let inspection = try AudioMediaInspector.inspect(at: url, policy: .generated)
                    guard inspection.format.container == .wav,
                          inspection.format.sampleRate == Double(audio.outputSampleRate),
                          inspection.format.channelCount == 2,
                          inspection.format.floatingPoint, inspection.format.bitDepth == 32,
                          inspection.format.frameCount == (try ProjectFiles.expectedAudioFrames(audio)) else {
                        throw AudioMediaError.invalidMedia("恢复的生成音频与固定请求不一致")
                    }
                    let audioMetadata = AudioAssetMetadata(format: inspection.format,
                                                           contentSHA256: inspection.contentSHA256,
                                                           origin: .modelGenerated)
                    asset = ProjectAsset(jobID: jobID, relativePath: relative,
                                         mediaType: "audio/wav", role: .result,
                                         metadata: .init(audio: audioMetadata),
                                         name: "候选 \(candidate.assets.count + 1)")
                } else {
                    let metadata = try readPNG(relative: relative, job: candidate.jobs[index])
                    asset = ProjectAsset(jobID: jobID, relativePath: relative, metadata: metadata,
                                         name: "候选 \(candidate.assets.count + 1)")
                }
                candidate.assets.append(asset)
                candidate.jobs[index].artifactIDs.append(asset.id)
                if candidate.jobs[index].state != .completed {
                    if (!isAudio && !isVideo) || !candidate.jobs[index].state.isTerminal {
                        candidate.jobs[index].state = .interrupted
                    }
                    candidate.jobs[index].error = isVideo ? "已恢复未登记的视频；权威完成记录缺失，不能采用为成功候选。" : isAudio
                        ? "已恢复生成后尚未登记的音频；权威完成记录缺失，不能采用为成功候选。"
                        : "已恢复生成后尚未登记的图片；任务完整结束记录缺失，请检查作品。"
                }
            } catch {
                // Keep both the original file and job record for diagnosis. Never turn corrupt
                // or redirected files into artwork just to make project opening succeed.
                candidate.jobs[index].error = isVideo ? "发现未登记视频，但无法安全恢复：\(error.localizedDescription)" : isAudio
                    ? "发现未登记的音频，但无法安全恢复：\(error.localizedDescription)"
                    : "发现未登记的图片，但无法安全恢复：\(error.localizedDescription)"
            }
        }
        try checkLocation()
        guard manifest.revision == revision else { throw ProjectStoreError.externalModification }
        if candidate != manifest { try commit(candidate) }
        return manifest
    }

    private func readPNG(relative: String, job: ProjectJob) throws -> MediaMetadata {
        let data = try ProjectFiles.read(relative: relative, in: rootFD, limit: 64 * 1_024 * 1_024)
        let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        guard data.starts(with: signature),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetStatus(source) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
              width > 0, height > 0, width <= 32_768, height <= 32_768,
              width * height <= 100_000_000 else { throw ProjectStoreError.invalidImage(relative) }
        if case .image(let request) = job.request.input {
            guard width == request.width, height == request.height else { throw ProjectStoreError.invalidImage(relative) }
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              image.width == width, image.height == height else { throw ProjectStoreError.invalidImage(relative) }
        return MediaMetadata(width: width, height: height,
                             bitDepth: properties[kCGImagePropertyDepth as String] as? Int,
                             colorSpace: properties[kCGImagePropertyProfileName as String] as? String)
    }

    private func checkLocation() throws {
        guard !isClosed else { throw ProjectStoreError.io("项目会话已关闭，请重新打开项目") }
        let current = try ProjectFiles.openDirectory(rootURL)
        defer { Darwin.close(current) }
        guard try sameDirectory(current) else {
            throw ProjectStoreError.io("项目位置已改变，请重新定位项目")
        }
    }

    private func sameDirectory(_ descriptor: Int32) throws -> Bool {
        var expected = stat(), actual = stat()
        guard fstat(rootFD, &expected) == 0, fstat(descriptor, &actual) == 0 else { throw ProjectFiles.error() }
        return expected.st_dev == actual.st_dev && expected.st_ino == actual.st_ino
    }

    private func commit(_ value: ProjectManifest) throws {
        try checkLocation()
        // flock protects cooperating sessions; also detect an editor that ignores the lock.
        // This is an optimistic check, not a promise of exclusion against hostile concurrent writes.
        try verifyUnchangedManifest()
        guard manifest.revision < UInt64.max else {
            throw ProjectStoreError.invalidProject("项目修订编号已经达到上限，无法安全保存更多更改。")
        }
        var candidate = value
        candidate.revision = manifest.revision + 1
        candidate.updatedAt = Date()
        try ProjectFiles.validate(candidate)
        try ProjectFiles.writeManifest(candidate, in: rootFD, replacing: true)
        manifest = candidate
    }
}

private enum ProjectFiles {
    static func error() -> ProjectStoreError { .io(String(cString: strerror(errno))) }

    static func projectURL(_ url: URL) throws -> URL {
        guard url.isFileURL, url.path.hasPrefix("/"), url.pathExtension.lowercased() == "dproject",
              url.standardizedFileURL.path == url.path else { throw ProjectStoreError.unsafePath(url.path) }
        _ = try components(String(url.path.dropFirst()))
        return url.standardizedFileURL
    }

    static func components(_ path: String) throws -> [String] {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") && !$0.contains("\0") }) else {
            throw ProjectStoreError.unsafePath(path)
        }
        return parts
    }

    /// Walk every component using directory descriptors; a renamed/symlinked ancestor cannot
    /// redirect a write outside the project between a path check and the actual operation.
    static func openDirectory(_ url: URL) throws -> Int32 {
        guard url.isFileURL, url.path.hasPrefix("/") else { throw ProjectStoreError.unsafePath(url.path) }
        // A security-scoped grant covers the selected project, not directory listings of
        // every ancestor. O_SEARCH permits anchored traversal without requesting
        // those unrelated listings, while O_NOFOLLOW still rejects every symlink.
        let descriptor = Darwin.open("/", O_SEARCH | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw error() }
        if url.path == "/" { return descriptor }
        do {
            let result = try descend(try components(String(url.path.dropFirst())), from: descriptor, leafFlags: O_SEARCH)
            Darwin.close(descriptor)
            return result
        } catch { Darwin.close(descriptor); throw error }
    }

    static func descend(_ parts: [String], from parent: Int32, leafFlags: Int32 = O_RDONLY) throws -> Int32 {
        var current = dup(parent)
        guard current >= 0 else { throw error() }
        for (index, part) in parts.enumerated() {
            let access = index == parts.count - 1 ? leafFlags : O_SEARCH
            let next = openat(current, part, access | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let failure = errno
            Darwin.close(current)
            guard next >= 0 else {
                if failure == ELOOP || failure == ENOTDIR { throw ProjectStoreError.unsafePath(part) }
                throw ProjectStoreError.io("\(part)：\(String(cString: strerror(failure)))")
            }
            current = next
        }
        return current
    }

    static func openRelativeDirectory(_ relative: String, in root: Int32) throws -> Int32 {
        try descend(components(relative), from: root)
    }

    static func openOrCreateDirectory(_ name: String, in root: Int32) throws -> Int32 {
        guard try components(name).count == 1 else { throw ProjectStoreError.unsafePath(name) }
        if mkdirat(root, name, 0o700) == 0 {
            guard fsync(root) == 0 else { throw error() }
        } else if errno != EEXIST {
            throw error()
        }
        return try openRelativeDirectory(name, in: root)
    }

    static func openRelativeFile(_ relative: String, in root: Int32) throws -> Int32 {
        var parts = try components(relative)
        let filename = parts.removeLast()
        let parent = try descend(parts, from: root)
        defer { Darwin.close(parent) }
        let descriptor = openat(parent, filename, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw error() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
            Darwin.close(descriptor)
            throw ProjectStoreError.unsafePath(relative)
        }
        return descriptor
    }

    static func read(relative: String, in root: Int32, limit: Int) throws -> Data {
        let descriptor = try openRelativeFile(relative, in: root)
        defer { Darwin.close(descriptor) }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { return result }
            if count < 0 {
                if errno == EINTR { continue }
                throw error()
            }
            guard result.count <= limit - count else { throw ProjectStoreError.invalidProject("文件超过当前工作台的安全读取上限。") }
            result.append(contentsOf: buffer[..<count])
        }
    }

    static func unlock(_ descriptor: Int32) throws {
        while flock(descriptor, LOCK_UN) != 0 {
            if errno != EINTR { throw error() }
        }
    }

    static func lock(in root: Int32) throws -> Int32 {
        let descriptor = openat(root, ".project.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw error() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
            Darwin.close(descriptor)
            throw ProjectStoreError.unsafePath(".project.lock")
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            throw ProjectStoreError.io("此项目已被另一窗口或应用实例打开")
        }
        return descriptor
    }

    static func writeManifest(_ manifest: ProjectManifest, in root: Int32, replacing: Bool) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(manifest)
        guard data.count <= 32 * 1_024 * 1_024 else {
            throw ProjectStoreError.invalidProject("项目清单超过当前工作台的 32 MiB 上限，请新建项目；本次更改尚未写入。")
        }
        try publish(in: root, name: ProjectStore.manifestFilename, replacing: replacing) { descriptor in
            try data.withUnsafeBytes { try writeAll($0, to: descriptor) }
        }
    }

    /// Back up the exact v1 bytes durably before publishing v2. The backup is immutable;
    /// its equality to the still-current v1 manifest is the restart marker. A crash before
    /// publication leaves a readable v1 project, and a crash afterwards leaves valid v2.
    static func migrateVersionOne(_ legacy: ProjectManifest, original: Data, in root: Int32,
                                  checkpoint: (@Sendable (ProjectMigrationCheckpoint) throws -> Void)?) throws -> ProjectManifest {
        try migrate(legacy, original: original, in: root, backup: ProjectStore.versionOneBackupFilename,
                    checkpoint: checkpoint)
    }

    static func migrateVersionTwo(_ legacy: ProjectManifest, original: Data, in root: Int32,
                                  checkpoint: (@Sendable (ProjectMigrationCheckpoint) throws -> Void)?) throws -> ProjectManifest {
        try migrate(legacy, original: original, in: root, backup: ProjectStore.versionTwoBackupFilename,
                    checkpoint: checkpoint)
    }

    static func migrateVersionThree(_ legacy: ProjectManifest, original: Data, in root: Int32,
                                    checkpoint: (@Sendable (ProjectMigrationCheckpoint) throws -> Void)?) throws -> ProjectManifest {
        try migrate(legacy, original: original, in: root, backup: ProjectStore.versionThreeBackupFilename,
                    checkpoint: checkpoint)
    }

    static func migrateVersionFour(_ legacy: ProjectManifest, original: Data, in root: Int32,
                                   checkpoint: (@Sendable (ProjectMigrationCheckpoint) throws -> Void)?) throws -> ProjectManifest {
        try migrate(legacy, original: original, in: root, backup: ProjectStore.versionFourBackupFilename,
                    checkpoint: checkpoint)
    }

    static func migrateVersionFive(_ legacy: ProjectManifest, original: Data, in root: Int32,
                                   checkpoint: (@Sendable (ProjectMigrationCheckpoint) throws -> Void)?) throws -> ProjectManifest {
        try migrate(legacy, original: original, in: root, backup: ProjectStore.versionFiveBackupFilename,
                    checkpoint: checkpoint)
    }

    static func migrateVersionSix(_ legacy: ProjectManifest, original: Data, in root: Int32,
                                  checkpoint: (@Sendable (ProjectMigrationCheckpoint) throws -> Void)?) throws -> ProjectManifest {
        try migrate(legacy, original: original, in: root, backup: ProjectStore.versionSixBackupFilename,
                    checkpoint: checkpoint)
    }

    static func migrateVersionSeven(_ legacy: ProjectManifest, original: Data, in root: Int32,
                                    checkpoint: (@Sendable (ProjectMigrationCheckpoint) throws -> Void)?) throws -> ProjectManifest {
        try migrate(legacy, original: original, in: root, backup: ProjectStore.versionSevenBackupFilename,
                    checkpoint: checkpoint)
    }

    static func migrateVersionEight(_ legacy: ProjectManifest, original: Data, in root: Int32,
                                    checkpoint: (@Sendable (ProjectMigrationCheckpoint) throws -> Void)?) throws -> ProjectManifest {
        try migrate(legacy, original: original, in: root, backup: ProjectStore.versionEightBackupFilename,
                    checkpoint: checkpoint)
    }

    static func migrateVersionNine(_ legacy: ProjectManifest, original: Data, in root: Int32,
                                   checkpoint: (@Sendable (ProjectMigrationCheckpoint) throws -> Void)?) throws -> ProjectManifest {
        try migrate(legacy, original: original, in: root, backup: ProjectStore.versionNineBackupFilename,
                    checkpoint: checkpoint)
    }

    static func migrateVersionTen(_ legacy: ProjectManifest, original: Data, in root: Int32,
                                  checkpoint: (@Sendable (ProjectMigrationCheckpoint) throws -> Void)?) throws -> ProjectManifest {
        try migrate(legacy, original: original, in: root, backup: ProjectStore.versionTenBackupFilename,
                    checkpoint: checkpoint)
    }

    static func migrateVersionEleven(_ legacy: ProjectManifest, original: Data, in root: Int32,
                                    checkpoint: (@Sendable (ProjectMigrationCheckpoint) throws -> Void)?) throws -> ProjectManifest {
        try migrate(legacy, original: original, in: root, backup: "project.v11.backup.json", checkpoint: checkpoint)
    }

    static func migrateVersionTwelve(_ legacy: ProjectManifest, original: Data, in root: Int32,
                                     checkpoint: (@Sendable (ProjectMigrationCheckpoint) throws -> Void)?) throws -> ProjectManifest {
        try migrate(legacy, original: original, in: root, backup: "project.v12.backup.json", checkpoint: checkpoint)
    }

    private static func migrate(_ legacy: ProjectManifest, original: Data, in root: Int32, backup: String,
                                checkpoint: (@Sendable (ProjectMigrationCheckpoint) throws -> Void)?) throws -> ProjectManifest {
        try validate(legacy, allowingLegacySchema: true)
        var migrated = legacy
        migrated.schemaVersion = ProjectManifest.currentSchemaVersion
        // Only formats predating text-sources lack notebooks. Schema10 already owns
        // authoritative snapshots and immutable prompt history, which must survive.
        if legacy.schemaVersion <= 9 {
            for index in migrated.documents.indices where migrated.documents[index].kind == .text {
                migrated.documents[index].textSources = TextSourcesNotebook()
            }
        }
        guard migrated.revision < UInt64.max else {
            throw ProjectStoreError.invalidProject("项目修订编号已经达到上限，无法安全升级。")
        }
        migrated.revision += 1
        migrated.updatedAt = Date()
        try validate(migrated)
        var info = stat()
        if fstatat(root, backup, &info, AT_SYMLINK_NOFOLLOW) == 0 {
            guard try read(relative: backup, in: root, limit: 32 * 1_024 * 1_024) == original else {
                throw ProjectStoreError.invalidProject("已有的格式升级备份与当前项目不同，已保留两者；请检查后再升级。")
            }
        } else {
            guard errno == ENOENT else { throw error() }
            try publish(in: root, name: backup, replacing: false) { descriptor in
                try original.withUnsafeBytes { try writeAll($0, to: descriptor) }
            }
        }
        try checkpoint?(.backupDurable)
        guard try read(relative: ProjectStore.manifestFilename, in: root, limit: 32 * 1_024 * 1_024) == original else {
            throw ProjectStoreError.externalModification
        }
        try checkpoint?(.beforePublication)
        try writeManifest(migrated, in: root, replacing: true)
        try checkpoint?(.publicationDurable)
        return migrated
    }

    static func writeAll(_ bytes: UnsafeRawBufferPointer, to descriptor: Int32) throws {
        var offset = 0
        while offset < bytes.count {
            let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw error() }
            offset += count
        }
    }

    static func publish(in parent: Int32, name: String, replacing: Bool, write: (Int32) throws -> Void) throws {
        let temporary = ".d-\(UUID().uuidString).partial"
        let descriptor = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw error() }
        defer { Darwin.close(descriptor); unlinkat(parent, temporary, 0) }
        try write(descriptor)
        guard fsync(descriptor) == 0 else { throw error() }
        if replacing {
            var info = stat()
            guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw ProjectStoreError.unsafePath(name) }
            guard renameat(parent, temporary, parent, name) == 0 else { throw error() }
        } else {
            guard renameatx_np(parent, temporary, parent, name, UInt32(RENAME_EXCL)) == 0 else {
                if errno == EEXIST { throw ProjectStoreError.alreadyExists(name) }
                throw error()
            }
        }
        guard fsync(parent) == 0 else { throw error() }
    }

    static func publishExport(to destination: URL, parent: Int32,
                              checkpoint: (@Sendable (ProjectExportCheckpoint) throws -> Void)?,
                              validate: ((URL) throws -> Void)? = nil,
                              write: (Int32) throws -> Void) throws {
        _ = try components(destination.lastPathComponent)
        // Apple documents this API for atomic safe-save on the destination's volume:
        // https://developer.apple.com/documentation/foundation/filemanager/url(for:in:appropriatefor:create:)
        let temporary = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                    appropriateFor: destination, create: true)
        // Only the OS-created temporary directory is canonicalized. User-selected destination
        // components still go through the unchanged O_NOFOLLOW descriptor walk above.
        guard let resolved = realpath(temporary.path, nil) else { throw error() }
        defer { free(resolved) }
        let location = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        let directory = try openDirectory(location)
        defer { Darwin.close(directory) }
        var temporaryInfo = stat(), destinationInfo = stat()
        guard fstat(directory, &temporaryInfo) == 0, fstat(parent, &destinationInfo) == 0 else { throw error() }
        defer {
            // Remove only this operation's empty directory, never recursively delete content
            // whose ownership is unknown. The temporary filename is handled by its own defer.
            if let owner = try? openDirectory(location.deletingLastPathComponent()) {
                var current = stat()
                if fstatat(owner, location.lastPathComponent, &current, AT_SYMLINK_NOFOLLOW) == 0,
                   current.st_dev == temporaryInfo.st_dev, current.st_ino == temporaryInfo.st_ino {
                    _ = unlinkat(owner, location.lastPathComponent, AT_REMOVEDIR)
                }
                Darwin.close(owner)
            }
        }
        guard temporaryInfo.st_dev == destinationInfo.st_dev else {
            throw ProjectStoreError.io("系统未能提供与导出目标同卷的临时位置，无法安全完成原子导出")
        }
        let name = "export-\(UUID().uuidString).partial"
        let descriptor = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw error() }
        defer { Darwin.close(descriptor); _ = unlinkat(directory, name, 0) }
        try write(descriptor)
        guard fsync(descriptor) == 0 else { throw error() }
        let temporaryFile = location.appendingPathComponent(name)
        try validate?(temporaryFile)
        try checkpoint?(.contentDurable(temporaryFile))
        try validate?(temporaryFile)
        guard renameatx_np(directory, name, parent, destination.lastPathComponent, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { throw ProjectStoreError.alreadyExists(destination.path) }
            throw error()
        }
        try checkpoint?(.published(destination))
        // After publication no failure path deletes the delivered file. In particular, a
        // disconnected volume during directory synchronization must not trigger a rollback.
        guard fsync(parent) == 0 else {
            throw ProjectStoreError.io("导出文件已发布并保留，但无法确认目标目录已同步：\(String(cString: strerror(errno)))")
        }
    }

    static func taskOwner(_ name: String) -> UUID? {
        guard name.count == 73 else { return nil }
        let separator = name.index(name.startIndex, offsetBy: 36)
        guard name[separator] == "-", UUID(uuidString: String(name[name.index(after: separator)...])) != nil else { return nil }
        return UUID(uuidString: String(name[..<separator]))
    }

    static func relativeArtifact(_ url: URL, root: URL, jobID: UUID) throws -> String {
        let prefix = root.path + "/"
        guard url.isFileURL, url.path.hasPrefix(prefix), url.standardizedFileURL.path == url.path else {
            throw ProjectStoreError.unsafePath(url.path)
        }
        let relative = String(url.path.dropFirst(prefix.count))
        let parts = try components(relative)
        guard parts.count == 3, parts[0] == "Tasks", taskOwner(parts[1]) == jobID, parts[2] == "image.png" else {
            throw ProjectStoreError.unsafePath(relative)
        }
        return relative
    }

    static func relativeVideoArtifact(_ url: URL, root: URL, jobID: UUID) throws -> String {
        let prefix = root.path + "/"
        guard url.isFileURL, url.path.hasPrefix(prefix), url.standardizedFileURL.path == url.path else {
            throw ProjectStoreError.unsafePath(url.path)
        }
        let relative = String(url.path.dropFirst(prefix.count)), parts = try components(relative)
        guard parts.count == 3, parts[0] == "Tasks", parts[1] == parts[1].lowercased(),
              taskOwner(parts[1]) == jobID, parts[2] == "output.mp4" else { throw ProjectStoreError.unsafePath(relative) }
        return relative
    }

    static func relativeAudioArtifact(_ url: URL, root: URL, jobID: UUID) throws -> String {
        let prefix = root.path + "/"
        guard url.isFileURL, url.path.hasPrefix(prefix),
              url.standardizedFileURL.path == url.path else {
            throw ProjectStoreError.unsafePath(url.path)
        }
        let relative = String(url.path.dropFirst(prefix.count))
        let parts = try components(relative)
        guard parts.count == 4, parts[0] == "Tasks",
              parts[1] == parts[1].lowercased(), taskOwner(parts[1]) == jobID,
              parts[2] == "job", parts[3] == "output.wav" else {
            throw ProjectStoreError.unsafePath(relative)
        }
        return relative
    }

    static func directoryNames(_ descriptor: Int32) throws -> [String] {
        let duplicate = dup(descriptor)
        guard duplicate >= 0 else { throw error() }
        guard let directory = fdopendir(duplicate) else { Darwin.close(duplicate); throw error() }
        defer { closedir(directory) }
        var result: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0 else { throw error() }
                break
            }
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name != ".", name != ".." { result.append(name) }
        }
        return result
    }

    static func createAudioDirectory(in root: Int32) throws -> (UUID, Int32) {
        var info = stat()
        if fstatat(root, "Audio", &info, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw error() }
            if mkdirat(root, "Audio", 0o700) != 0, errno != EEXIST { throw error() }
            guard fsync(root) == 0 else { throw error() }
        }
        let audio = try openRelativeDirectory("Audio", in: root)
        defer { Darwin.close(audio) }
        for _ in 0..<128 {
            let id = UUID()
            guard mkdirat(audio, id.uuidString, 0o700) == 0 else {
                if errno == EEXIST { continue }
                throw error()
            }
            guard fsync(audio) == 0 else { throw error() }
            let directory = try openRelativeDirectory(id.uuidString, in: audio)
            return (id, directory)
        }
        throw ProjectStoreError.io("无法分配唯一的音频目录")
    }

    static func audioMediaType(_ container: AudioContainer) -> String {
        container == .wav ? "audio/wav" : "audio/x-caf"
    }

    static func requireRegisteredAudio(_ inspection: AudioInspection,
                                       matches metadata: AudioAssetMetadata) throws {
        guard inspection.format == metadata.format,
              inspection.contentSHA256 == metadata.contentSHA256 else {
            throw ProjectStoreError.externalModification
        }
    }

    static func inspectionPolicy(for asset: ProjectAsset,
                                 jobs: [ProjectJob]) throws -> AudioInspectionPolicy {
        guard let audio = asset.metadata.audio else { throw ProjectStoreError.missingAsset }
        switch audio.origin {
        case .importedFile, .microphone:
            guard asset.role == .original, asset.jobID == nil else {
                throw ProjectStoreError.invalidProject("原声音频登记关系无效。")
            }
            return .original
        case .modelGenerated:
            guard asset.role == .result, let jobID = asset.jobID,
                  let job = jobs.first(where: { $0.id == jobID }),
                  job.artifactIDs.contains(asset.id) else {
                throw ProjectStoreError.invalidProject("生成音频缺少可信任务关系。")
            }
            guard case .audio = job.request.input else {
                throw ProjectStoreError.invalidProject("生成音频对应的任务类型无效。")
            }
            return .generated
        }
    }

    static func validateCreationSource(_ format: AudioFormatInfo) throws {
        guard format.container == .wav, format.sampleRate == 44_100,
              format.channelCount == 2 else { throw AudioMediaError.unsupportedFormat }
    }

    static func validateCurrentAudioProfile(_ request: AudioRequest) throws {
        try request.validate()
        if request.noteSequence != nil { return }
        guard let diffusion = request.diffusion, request.seed <= UInt64(UInt32.max) - 1,
              (1...100).contains(diffusion.steps), diffusion.guidanceScale.isFinite,
              (1...15).contains(diffusion.guidanceScale) else {
            throw ProjectStoreError.invalidProject("音频请求超出当前支持的 seed、steps 或 guidance 范围。")
        }
    }

    static func expectedAudioFrames(_ request: AudioRequest) throws -> Int64 {
        if let source = request.source { return source.frameCount }
        if let sequence = request.noteSequence { return Int64(sequence.durationFrames) * 1_920 }
        let value = request.durationSeconds * 44_100
        let rounded = value.rounded(.toNearestOrEven)
        guard value.isFinite, value > 0, rounded.isFinite,
              rounded > 0, rounded < Double(Int64.max) else {
            throw ProjectStoreError.invalidProject("音频请求帧数不可表示。")
        }
        return Int64(rounded)
    }

    static func validateAudioName(_ name: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.utf8.count <= AudioLimits.maximumNameBytes else {
            throw ProjectStoreError.invalidProject("原声名称不能为空且不能超过 256 个 UTF-8 字节。")
        }
    }

    static func validateAudioRange(_ range: AudioFrameRange, frameCount: Int64) throws {
        guard range.startFrame >= 0, range.startFrame < range.endFrame,
              range.endFrame <= frameCount else { throw AudioMediaError.invalidRange }
    }

    static func validateAudioFormat(_ format: AudioFormatInfo,
                                    policy: AudioInspectionPolicy = .original) throws {
        guard format.sampleRate.isFinite, (8_000...96_000).contains(format.sampleRate),
              format.channelCount == 1 || format.channelCount == 2,
              (format.floatingPoint && format.bitDepth == 32) ||
                (!format.floatingPoint && [16, 24, 32].contains(format.bitDepth)),
              format.frameCount > 0 else {
            throw ProjectStoreError.invalidProject("原声音频格式元数据无效。")
        }
        let duration = Double(format.frameCount) / format.sampleRate
        guard duration.isFinite, duration <= policy.maximumSeconds else {
            throw ProjectStoreError.invalidProject("原声音频时长元数据超出限制。")
        }
    }

    static func validateAudioDraft(_ draft: AudioDraftDocument, asset: ProjectAsset?) throws {
        guard let asset, let audio = asset.metadata.audio, asset.role == .original, asset.jobID == nil else {
            throw ProjectStoreError.invalidProject("原声稿引用的原件不存在或类型不正确。")
        }
        guard draft.note.utf8.count <= AudioLimits.maximumNoteBytes,
              draft.clips.count <= AudioLimits.maximumClips,
              Set(draft.clips.map(\.id)).count == draft.clips.count,
              draft.selectedClipID == nil || draft.clips.contains(where: { $0.id == draft.selectedClipID }) else {
            throw ProjectStoreError.invalidProject("原声稿的备注、片段数量、编号或选择无效。")
        }
        for clip in draft.clips {
            try validateAudioName(clip.name)
            guard clip.note.utf8.count <= AudioLimits.maximumNoteBytes else {
                throw ProjectStoreError.invalidProject("原声片段备注超过 16 KiB UTF-8 上限。")
            }
            try validateAudioRange(clip.range, frameCount: audio.format.frameCount)
        }
    }

    static func validate(_ value: ProjectManifest, allowingLegacySchema: Bool = false) throws {
        guard value.schemaVersion == ProjectManifest.currentSchemaVersion ||
              (allowingLegacySchema && ProjectManifest.readableSchemaVersions.contains(value.schemaVersion)) else {
            throw ProjectStoreError.unsupportedSchema(value.schemaVersion)
        }
        guard !value.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !value.documents.isEmpty,
              Set(value.documents.map(\.id)).count == value.documents.count,
              value.documents.contains(where: { $0.id == value.activeDocumentID }),
              Set(value.jobs.map(\.id)).count == value.jobs.count,
              Set(value.assets.map(\.id)).count == value.assets.count,
              Set(value.assets.map(\.relativePath)).count == value.assets.count,
              Set(value.pendingAudioCaptures.map(\.id)).count == value.pendingAudioCaptures.count,
              Set(value.pendingAudioCaptures.map(\.relativePath)).count == value.pendingAudioCaptures.count else {
            throw ProjectStoreError.invalidProject("项目名称为空，文档选择无效，或包含重复的文档、任务、作品编号。")
        }
        guard value.documents.allSatisfy({ $0.kind == .text || $0.textSources == nil }) else {
            throw ProjectStoreError.invalidProject("非文字文档包含文字资料记录。")
        }
        let documents = Set(value.documents.map(\.id))
        let jobs = Dictionary(uniqueKeysWithValues: value.jobs.map { ($0.id, $0) })
        let assets = Dictionary(uniqueKeysWithValues: value.assets.map { ($0.id, $0) })
        let assetPaths = Set(value.assets.map(\.relativePath))
        for reservation in value.pendingAudioCaptures {
            try validateAudioName(reservation.name)
            guard reservation.relativePath == "Audio/\(reservation.id.uuidString)/source.caf",
                  assets[reservation.id] == nil, !assetPaths.contains(reservation.relativePath) else {
                throw ProjectStoreError.invalidProject("待录音预约路径、编号或作品登记冲突。")
            }
        }
        for job in value.jobs {
            if job.imageReferenceAssetID != nil {
                guard case .image = job.request.input else {
                    throw ProjectStoreError.invalidProject("非图像任务不能包含参考图来源。")
                }
            }
            guard documents.contains(job.documentID), job.id == job.request.id,
                  Set(job.artifactIDs).count == job.artifactIDs.count,
                  job.artifactIDs.allSatisfy({ assets[$0]?.jobID == job.id }),
                  job.state != .completed || !job.artifactIDs.isEmpty else {
                throw ProjectStoreError.invalidProject("任务与作品的对应关系已损坏。")
            }
            try job.request.validate()
            guard let document = value.documents.first(where: { $0.id == job.documentID }) else {
                throw ProjectStoreError.invalidProject("任务缺少文档。")
            }
            switch job.request.input {
            case .singing:
                throw ProjectStoreError.invalidTransition
            case .pitch(let request):
                guard value.schemaVersion >= 12, let draft = document.audioDraft, document.kind == .audio,
                      request.source.documentID == document.id, request.source.assetID == draft.assetID,
                      request.source.documentRevision <= draft.revision, job.artifactIDs.count <= 1,
                      let original = assets[draft.assetID], let media = original.metadata.audio,
                      request.source.contentSHA256 == media.contentSHA256,
                      request.source.sampleRate == media.format.sampleRate,
                      request.source.frameCount == media.format.frameCount, media.format.channelCount == 1,
                      job.request.model.revision == PitchAnalysisRequest.modelSHA256,
                      request.inputURL.path.hasSuffix("/PitchInputs/\(job.id.uuidString)/input.f32") else {
                    throw ProjectStoreError.invalidProject("音高分析任务不属于原声文档。")
                }
            case .video(let request):
                guard value.schemaVersion >= 8, document.kind == .video, document.videoCreation != nil,
                      job.artifactIDs.count <= 1 else { throw ProjectStoreError.invalidProject("视频任务归属无效。") }
                try VideoExecutionCapability.wan21.validate(request)
            case .image(let image):
                guard document.kind == .image else {
                    throw ProjectStoreError.invalidProject("图像任务不属于图像文档。")
                }
                if let reference = image.referenceImage {
                    guard [9, 11, 12, 16].contains(value.schemaVersion), let id = job.imageReferenceAssetID,
                          let asset = assets[id], asset.mediaType == "image/png",
                          asset.metadata.imageContentSHA256 != nil,
                          reference.url.path.hasSuffix("/ImageInputs/\(job.id.uuidString)/reference.rgb") else {
                        throw ProjectStoreError.invalidProject("参考图片任务的来源或输入路径无效。")
                    }
                    try ImageExecutionCapability.scalableKlein4B.validate(image)
                } else if job.imageReferenceAssetID != nil || image.executionProfile == ImageExecutionCapability.referenceKlein4B.profile {
                    throw ProjectStoreError.invalidProject("参考图片任务不能省略输入。")
                }
            case .audio(let request):
                guard document.kind == .audio, document.audioCreation != nil else {
                    throw ProjectStoreError.invalidProject("音频任务不属于声音创作文档。")
                }
                try validateCurrentAudioProfile(request)
                if let sourceID = document.sourceAssetID {
                    guard let sourceAsset = assets[sourceID], let metadata = sourceAsset.metadata.audio,
                          metadata.format.sampleRate.isFinite else {
                        throw ProjectStoreError.invalidProject("音频任务的来源元数据无效。")
                    }
                    try validateAudioFormat(metadata.format,
                        policy: metadata.origin == .modelGenerated ? .generated : .original)
                    guard metadata.format.sampleRate.rounded() == metadata.format.sampleRate,
                          let source = request.source,
                          source.url.path.hasSuffix("/AudioInputs/\(job.id.uuidString)/source.wav"),
                          source.sha256 == metadata.contentSHA256,
                          source.frameCount == metadata.format.frameCount,
                          source.sampleRate == Int(metadata.format.sampleRate),
                          source.channels == metadata.format.channelCount,
                          request.operation != .generate else {
                        throw ProjectStoreError.invalidProject("音频任务的来源快照关系无效。")
                    }
                } else {
                    guard request.source == nil, request.operation == .generate else {
                        throw ProjectStoreError.invalidProject("无来源声音创作包含参考音频任务。")
                    }
                }
            case .text:
                throw ProjectStoreError.invalidProject("项目媒体任务不能登记文字请求。")
            }
        }
        for asset in value.assets {
            guard !asset.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ProjectStoreError.invalidProject("作品名称不能为空。")
            }
            _ = try components(asset.relativePath)
            if let jobID = asset.jobID {
                guard let job = jobs[jobID], job.artifactIDs.contains(asset.id) else {
                    throw ProjectStoreError.invalidProject("作品缺少对应的任务记录。")
                }
            }
            let isDeclaredAudio = asset.metadata.audio != nil || asset.mediaType == "audio/wav" ||
                asset.mediaType == "audio/x-caf" || asset.relativePath.hasPrefix("Audio/")
            if asset.relativePath.hasPrefix("WorkflowAssets/") {
                guard value.schemaVersion == 16, value.workflowSnapshot != nil,
                      asset.jobID == nil, asset.role == .original || asset.role == .result,
                      let suffix = ["text/plain": "txt", "image/png": "png", "image/jpeg": "jpg"][asset.mediaType],
                      asset.relativePath == "WorkflowAssets/\(asset.id.uuidString)/content.\(suffix)",
                      asset.metadata.audio == nil, asset.metadata.video == nil, asset.metadata.pitch == nil else {
                    throw ProjectStoreError.invalidProject("流程资产的路径或类型无效。")
                }
            } else if asset.mediaType == PitchAnalysisResult.mediaType || asset.metadata.pitch != nil {
                guard value.schemaVersion >= 12, asset.mediaType == PitchAnalysisResult.mediaType,
                      asset.role == .result, let metadata = asset.metadata.pitch, let jobID = asset.jobID,
                      let job = jobs[jobID], case .pitch(let request) = job.request.input,
                      asset.relativePath == "Tasks/\(jobID.uuidString)/pitch.json", metadata.source == request.source,
                      PitchSourceIdentity.isDigest(metadata.contentSHA256),
                      metadata.interpretationVersion == "equal-tempered-contiguous-5-v1",
                      asset.metadata.audio == nil, asset.metadata.video == nil, asset.metadata.width == nil,
                      asset.metadata.height == nil, asset.metadata.bitDepth == nil, asset.metadata.colorSpace == nil,
                      asset.metadata.imageContentSHA256 == nil else { throw ProjectStoreError.invalidProject("音高分析资产格式无效。") }
            } else if asset.metadata.video != nil || asset.mediaType.hasPrefix("video/") {
                guard value.schemaVersion >= 8, let metadata = asset.metadata.video,
                      asset.metadata.audio == nil, asset.metadata.bitDepth == nil, asset.metadata.colorSpace == nil,
                      asset.metadata.width == metadata.width, asset.metadata.height == metadata.height,
                      asset.mediaType == "video/mp4", asset.role == .result,
                      let jobID = asset.jobID, let job = jobs[jobID], case .video(let request) = job.request.input else {
                    throw ProjectStoreError.invalidProject("视频作品格式或任务关系无效。")
                }
                _ = try relativeVideoArtifact(URL(fileURLWithPath: "/project/" + asset.relativePath),
                                              root: URL(fileURLWithPath: "/project"), jobID: jobID)
                try metadata.validate(matching: request)
            } else if isDeclaredAudio {
                guard let audio = asset.metadata.audio,
                      asset.metadata.width == nil, asset.metadata.height == nil,
                      asset.metadata.bitDepth == nil, asset.metadata.colorSpace == nil else {
                    throw ProjectStoreError.invalidProject("音频作品不能伪装为图片或缺少音频元数据。")
                }
                try validateAudioName(asset.name)
                guard asset.note.utf8.count <= AudioLimits.maximumNoteBytes else {
                    throw ProjectStoreError.invalidProject("原声作品备注超过 16 KiB UTF-8 上限。")
                }
                guard audio.contentSHA256.count == 64,
                      audio.contentSHA256.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }) else {
                    throw ProjectStoreError.invalidProject("音频作品 SHA-256 元数据无效。")
                }
                switch audio.origin {
                case .importedFile, .microphone:
                    let expectedExtension = audio.format.container == .wav ? "wav" : "caf"
                    guard asset.jobID == nil, asset.role == .original,
                          asset.relativePath == "Audio/\(asset.id.uuidString)/source.\(expectedExtension)",
                          asset.mediaType == audioMediaType(audio.format.container) else {
                        throw ProjectStoreError.invalidProject("原声音频路径、角色或媒体类型无效。")
                    }
                    try validateAudioFormat(audio.format)
                case .modelGenerated:
                    let parts = try components(asset.relativePath)
                    guard asset.role == .result, let jobID = asset.jobID,
                          let job = jobs[jobID], case .audio(let request) = job.request.input,
                          asset.mediaType == "audio/wav",
                          parts.count == 4, parts[0] == "Tasks",
                          parts[1] == parts[1].lowercased(), taskOwner(parts[1]) == jobID,
                          parts[2] == "job", parts[3] == "output.wav",
                          audio.format.container == .wav, audio.format.sampleRate == Double(request.outputSampleRate),
                          audio.format.channelCount == 2, audio.format.floatingPoint,
                          audio.format.bitDepth == 32,
                          audio.format.frameCount == (try expectedAudioFrames(request)) else {
                        throw ProjectStoreError.invalidProject("生成音频路径、角色或格式无效。")
                    }
                    try validateAudioFormat(audio.format, policy: .generated)
                }
            } else if asset.metadata.audio != nil {
                throw ProjectStoreError.invalidProject("非音频作品不能包含音频元数据。")
            } else if asset.role == .original && asset.metadata.imageContentSHA256 != nil {
                // Explicitly selecting a legacy original pins its digest without relocating it.
                // Safe relative paths are validated above; only new import publication owns the UUID layout.
                guard [9, 11, 12, 16].contains(value.schemaVersion), asset.jobID == nil, asset.mediaType == "image/png" else {
                    throw ProjectStoreError.invalidProject("原参考图的路径或身份无效。")
                }
            } else if asset.role == .result {
                let parts = try components(asset.relativePath)
                guard asset.jobID != nil, parts.count == 3, parts[0] == "Tasks",
                      taskOwner(parts[1]) == asset.jobID, parts[2] == "image.png",
                      asset.mediaType == "image/png",
                      asset.jobID.flatMap({ jobs[$0] }).map({ if case .image = $0.request.input { true } else { false } }) == true else {
                    throw ProjectStoreError.unsafePath(asset.relativePath)
                }
            }
            for dimension in [asset.metadata.width, asset.metadata.height, asset.metadata.bitDepth].compactMap({ $0 }) {
                guard dimension > 0 else { throw ProjectStoreError.invalidProject("媒体元数据包含无效尺寸或位深。") }
            }
            if let digest = asset.metadata.imageContentSHA256 {
                guard [9, 11, 12, 16].contains(value.schemaVersion), asset.mediaType == "image/png", digest.utf8.count == 64,
                      digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                    throw ProjectStoreError.invalidProject("参考图摘要无效。")
                }
            }
        }
        for document in value.documents {
            if let pitch = document.pitchAnalysis {
                guard value.schemaVersion >= 12, document.audioDraft != nil,
                      pitch.acceptedAssetIDs.count <= value.assets.count, pitch.rejectedAssetIDs.count <= value.assets.count,
                      pitch.expiredAssetIDs.count <= value.assets.count,
                      Set(pitch.expiredAssetIDs).count == pitch.expiredAssetIDs.count,
                      Set(pitch.expiredAssetIDs).isDisjoint(with: pitch.acceptedAssetIDs),
                      Set(pitch.acceptedAssetIDs).count == pitch.acceptedAssetIDs.count,
                      Set(pitch.rejectedAssetIDs).count == pitch.rejectedAssetIDs.count,
                      Set(pitch.acceptedAssetIDs).isDisjoint(with: pitch.rejectedAssetIDs) else {
                    throw ProjectStoreError.invalidProject("音高候选决定记录无效。")
                }
                for id in pitch.acceptedAssetIDs + pitch.rejectedAssetIDs + pitch.expiredAssetIDs + [pitch.selectedAssetID].compactMap({ $0 }) {
                    guard let asset = assets[id], asset.metadata.pitch != nil, let jobID = asset.jobID,
                          jobs[jobID]?.documentID == document.id, jobs[jobID]?.state == .completed else {
                        throw ProjectStoreError.invalidProject("音高候选不属于当前原声。")
                    }
                }
                if let selected = pitch.selectedAssetID, pitch.rejectedAssetIDs.contains(selected) {
                    throw ProjectStoreError.invalidProject("拒绝的音高候选不能选中。")
                }
            }

            if let reference = document.draft.referenceImageAssetID {
                guard [9, 11, 12, 16].contains(value.schemaVersion), document.kind == .image,
                      let asset = assets[reference], asset.mediaType == "image/png",
                      asset.metadata.imageContentSHA256 != nil else {
                    throw ProjectStoreError.invalidProject("图像草稿的参考来源无效。")
                }
            }
            guard !document.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ProjectStoreError.invalidProject("探索文档名称不能为空。")
            }
            guard document.kind == .video || document.videoCreation == nil else {
                throw ProjectStoreError.invalidProject("非视频文档不能包含视频创作稿。")
            }
            switch document.kind {
            case .video:
                guard value.schemaVersion >= 8, let creation = document.videoCreation,
                      document.audioDraft == nil, document.audioCreation == nil, document.textDraft == nil,
                      document.sourceAssetID == nil,
                      Set(creation.rejectedAssetIDs).count == creation.rejectedAssetIDs.count else {
                    throw ProjectStoreError.invalidProject("视频文档内容或候选关系无效。")
                }
                for id in creation.rejectedAssetIDs {
                    guard let asset = assets[id], asset.metadata.video != nil,
                          let jobID = asset.jobID, jobs[jobID]?.documentID == document.id else {
                        throw ProjectStoreError.invalidProject("拒绝的视频候选不属于本创作稿。")
                    }
                }
            case .image:
                guard document.textDraft == nil, document.audioDraft == nil,
                      document.audioCreation == nil,
                      document.sourceAssetID.flatMap({ assets[$0]?.metadata.audio }) == nil,
                      document.sourceAssetID.flatMap({ assets[$0]?.metadata.video }) == nil else {
                    throw ProjectStoreError.invalidProject("图像文档不能包含文字稿。")
                }
            case .text:
                guard let textDraft = document.textDraft, textDraft.id == document.id,
                      document.audioDraft == nil, document.audioCreation == nil,
                      document.sourceAssetID == nil, document.adoptedAssetID == nil,
                      document.selectedAssetID == nil else {
                    throw ProjectStoreError.invalidProject("文字文档包含无效内容或图像引用。")
                }
                try TextDraftDocument.validate(textDraft.text)
                if [10, 11, 12, 16].contains(value.schemaVersion) {
                    guard let sources = document.textSources else {
                        throw ProjectStoreError.invalidProject("文字资料记录缺失。")
                    }
                    try TextSourcesArchive.validate(sources)
                    guard sources.records.allSatisfy({ $0.submission.targetDocumentID == document.id }) else {
                        throw ProjectStoreError.invalidProject("回答属于其他文字文档。")
                    }
                } else if document.textSources != nil {
                    throw ProjectStoreError.invalidProject("旧项目包含未经声明的文字资料记录。")
                }
            case .audio:
                guard document.textDraft == nil,
                      (document.audioDraft == nil) != (document.audioCreation == nil) else {
                    throw ProjectStoreError.invalidProject("音频文档必须且只能包含原声稿或声音创作稿。")
                }
                if let draft = document.audioDraft {
                    guard draft.id == document.id, document.sourceAssetID == nil,
                          document.adoptedAssetID == nil, document.selectedAssetID == nil else {
                        throw ProjectStoreError.invalidProject("原声文档包含创作引用或编号不匹配。")
                    }
                    try validateAudioDraft(draft, asset: assets[draft.assetID])
                } else if let creation = document.audioCreation {
                    guard Set(creation.rejectedAssetIDs).count == creation.rejectedAssetIDs.count else {
                        throw ProjectStoreError.invalidProject("声音创作包含重复的拒绝候选。")
                    }
                    if let sourceID = document.sourceAssetID {
                        guard let source = assets[sourceID], source.metadata.audio != nil,
                              source.role == .original || (source.role == .result &&
                                source.jobID.flatMap({ jobs[$0]?.state }) == .completed),
                              creation.operation != .generate else {
                            throw ProjectStoreError.invalidProject("声音创作来源或操作无效。")
                        }
                    } else if creation.operation != .generate {
                        throw ProjectStoreError.invalidProject("参考音频操作缺少固定来源。")
                    }
                }
            }
            if let source = document.sourceAssetID, assets[source] == nil {
                throw ProjectStoreError.invalidProject("探索文档引用的来源作品不存在。")
            }
            func isCandidate(_ id: UUID) -> Bool {
                guard let asset = assets[id], asset.role == .result, let jobID = asset.jobID else { return false }
                guard jobs[jobID]?.documentID == document.id else { return false }
                if let creation = document.videoCreation {
                    return jobs[jobID]?.state == .completed && !creation.rejectedAssetIDs.contains(id)
                }
                if let creation = document.audioCreation {
                    return jobs[jobID]?.state == .completed && !creation.rejectedAssetIDs.contains(id)
                }
                return true
            }
            if let creation = document.audioCreation,
               creation.rejectedAssetIDs.contains(where: { id in
                   guard let asset = assets[id], asset.role == .result, let jobID = asset.jobID else { return true }
                   return jobs[jobID]?.documentID != document.id
               }) {
                throw ProjectStoreError.invalidProject("拒绝候选不属于声音创作文档。")
            }
            if let adopted = document.adoptedAssetID, !isCandidate(adopted) {
                throw ProjectStoreError.invalidProject("采用的作品不属于该探索文档。")
            }
            if let selected = document.selectedAssetID,
               !(isCandidate(selected) || selected == document.sourceAssetID || selected == document.draft.referenceImageAssetID) {
                throw ProjectStoreError.invalidProject("选中的作品不属于该探索文档或其来源。")
            }
        }
    }
}

// Workflow records extend the existing project owner. There is no second database or project lock.
extension ProjectStore {
    private static func workflowHash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public func workflowState() throws -> WorkflowStoredState {
        try checkLocation(); try verifyUnchangedManifest()
        guard let pointer = manifest.workflowSnapshot else { return .init(archive: WorkflowArchive(revision: emptyWorkflowRevision)) }
        guard pointer.byteCount > 0, pointer.byteCount <= 32 * 1_024 * 1_024,
              PitchSourceIdentity.isDigest(pointer.sha256) else { throw WorkflowIssue("流程快照索引无效。") }
        let data = try ProjectFiles.read(relative: pointer.relativePath, in: rootFD, limit: 32 * 1_024 * 1_024)
        guard data.count == pointer.byteCount, Self.workflowHash(data) == pointer.sha256 else {
            throw WorkflowIssue("流程快照与已保存摘要不符；已停止写入，不覆盖原记录。")
        }
        struct Header: Decodable { let version: Int }
        let decoder = JSONDecoder()
        guard let header = try? decoder.decode(Header.self, from: data) else { throw WorkflowIssue("流程快照已损坏，原件已保留。") }
        guard header.version == 1 else {
            return .init(archive: nil, readOnlyReason: "流程格式 v\(header.version) 尚不支持；原始数据与连接已保留，只读。", originalBytes: data)
        }
        // Inspect just identities before full decoding: an unknown node may contain new scalar shapes.
        struct Identities: Decodable {
            struct Graph: Decodable {
                struct Node: Decodable { let operationID: String; let definitionVersion: Int }
                let nodes: [Node]
            }
            struct Run: Decodable {
                struct Step: Decodable { let node: Graph.Node }
                let graph: Graph; let steps: [Step]
            }
            let graphs: [Graph]; let runs: [Run]
        }
        guard let identities = try? decoder.decode(Identities.self, from: data) else { throw WorkflowIssue("流程身份记录损坏，未改写原件。") }
        for node in (identities.graphs + identities.runs.map(\.graph)).flatMap(\.nodes) + identities.runs.flatMap({ $0.steps.map(\.node) }) {
            guard let op = WorkflowRegistry.standard.operation(node.operationID), op.definition.version == node.definitionVersion else {
                return .init(archive: nil, readOnlyReason: "未知操作或版本：\(node.operationID) v\(node.definitionVersion)。保留整份原始流程，只读。", originalBytes: data)
            }
        }
        let archive: WorkflowArchive
        do { archive = try decoder.decode(WorkflowArchive.self, from: data) }
        catch { throw WorkflowIssue("流程数据无法解码；原始数据已保留。") }
        try validateWorkflowArchive(archive, assets: manifest.assets)
        return .init(archive: archive)
    }

    private func editableWorkflow() throws -> WorkflowArchive {
        let state = try workflowState()
        guard let archive = state.archive else { throw WorkflowIssue(state.readOnlyReason ?? "流程只读。") }
        return archive
    }

    /// Draft configuration and execution history are saved together; Store retains all published asset records.
    public func saveWorkflow(graphs: [WorkflowGraph], runs: [WorkflowRun], expectedRevision: UUID) throws -> WorkflowArchive {
        var archive = try editableWorkflow()
        guard archive.revision == expectedRevision else { throw WorkflowIssue("流程已被另一操作修改，请重新读取后保存。") }
        archive.graphs = graphs; archive.runs = runs; archive.revision = UUID()
        try commitWorkflow(archive, assets: manifest.assets)
        return archive
    }

    private func validateWorkflowArchive(_ archive: WorkflowArchive, assets: [ProjectAsset]) throws {
        guard archive.version == 1, archive.graphs.count <= 256, archive.runs.count <= 4_096,
              archive.assets.count <= 32_768, Set(archive.graphs.map(\.id)).count == archive.graphs.count,
              Set(archive.runs.map(\.id)).count == archive.runs.count,
              Set(archive.assets.map { $0.reference.assetID }).count == archive.assets.count else {
            throw WorkflowIssue("流程数量、版本或身份不合法；请另存项目或检查数据。")
        }
        let known = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        for record in archive.assets {
            let ref = record.reference
            guard ref.projectID == manifest.id, ref.kind == .text || ref.kind == .image,
                  PitchSourceIdentity.isDigest(ref.sha256), let asset = known[ref.assetID],
                  (ref.kind == .text && asset.mediaType == "text/plain") ||
                  (ref.kind == .image && ["image/png", "image/jpeg"].contains(asset.mediaType)) else {
                throw WorkflowIssue("流程资产身份或媒体类型不合法。")
            }
        }
        let refs = Set(archive.assets.map(\.reference))
        func validateRef(_ ref: WorkflowAssetReference) throws {
            guard refs.contains(ref) else { throw WorkflowIssue("流程引用不属于本项目的已发布版本。") }
        }
        func validateValue(_ value: WorkflowValue) throws {
            switch value {
            case .asset(let ref): try validateRef(ref)
            case .collection(let items):
                guard items.count <= 8, Set(items.map(\.id)).count == items.count else { throw WorkflowIssue("候选集合身份或数量无效。") }
                for item in items { if let ref = item.asset { try validateRef(ref) } }
            case .receipt(let receipt):
                guard receipt.names.count == receipt.hashes.count else { throw WorkflowIssue("导出回执无效。") }
            }
        }
        for record in archive.assets { for parent in record.parents { try validateRef(parent) } }
        for graph in archive.graphs + archive.runs.map(\.graph) {
            // Missing values in editable drafts are allowed; topology and identity must remain valid.
            try WorkflowRegistry.standard.validate(graph)
            for node in graph.nodes { if let ref = node.assetReference { try validateRef(ref) } }
        }
        for run in archive.runs {
            guard run.graph.nodes.contains(where: { $0.id == run.targetNodeID }),
                  Set(run.steps.map(\.id)).count == run.steps.count else { throw WorkflowIssue("流程运行快照无效。") }
            for step in run.steps {
                guard run.graph.nodes.contains(step.node) else { throw WorkflowIssue("步骤不属于运行快照。") }
                for v in Array(step.inputs.values) + Array(step.outputs.values) { try validateValue(v) }
                if let decision = step.decision {
                    guard decision.waitingStepID == step.id else { throw WorkflowIssue("人工决定不属于此等待点。") }
                    if let ref = decision.output { try validateRef(ref) }
                }
            }
        }
    }

    private func commitWorkflow(_ archive: WorkflowArchive, assets: [ProjectAsset],
                                checkpoint: (@Sendable (WorkflowStoreCheckpoint) throws -> Void)? = nil) throws {
        try validateWorkflowArchive(archive, assets: assets)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(archive)
        guard data.count <= 32 * 1_024 * 1_024 else { throw WorkflowIssue("流程快照超过 32 MiB；未覆盖原记录。") }
        let pointer = WorkflowSnapshotPointer(generation: UUID(), byteCount: data.count, sha256: Self.workflowHash(data))
        let directory = try ProjectFiles.openOrCreateDirectory("Workflows", in: rootFD)
        defer { Darwin.close(directory) }
        try ProjectFiles.publish(in: directory, name: "\(pointer.generation.uuidString).json", replacing: false) { fd in
            try data.withUnsafeBytes { try ProjectFiles.writeAll($0, to: fd) }
        }
        try checkpoint?(.snapshotDurable)
        var candidate = manifest; candidate.workflowSnapshot = pointer; candidate.assets = assets
        try checkpoint?(.beforeManifest)
        try commit(candidate)
    }

    public func publishWorkflowAsset(data: Data, mediaType: String, metadata: MediaMetadata = .init(),
                                      name: String, parents: [WorkflowAssetReference] = [], operationID: String,
                                      stepID: UUID? = nil, request: InferenceRequest? = nil,
                                      details: [String: String] = [:], assetID: UUID = UUID()) throws -> WorkflowPublishedAsset {
        try publishWorkflowAsset(data: data, mediaType: mediaType, metadata: metadata, name: name, parents: parents,
                                 operationID: operationID, stepID: stepID, request: request, details: details, assetID: assetID, checkpoint: nil)
    }

    func publishWorkflowAsset(data: Data, mediaType: String, metadata: MediaMetadata, name: String,
                              parents: [WorkflowAssetReference], operationID: String, stepID: UUID?,
                              request: InferenceRequest?, details: [String: String], assetID: UUID,
                              checkpoint: (@Sendable (WorkflowStoreCheckpoint) throws -> Void)?) throws -> WorkflowPublishedAsset {
        var archive = try editableWorkflow()
        let hash = Self.workflowHash(data)
        if let record = archive.assets.first(where: { $0.reference.assetID == assetID }),
           let asset = manifest.assets.first(where: { $0.id == assetID }) {
            guard record.reference.sha256 == hash, asset.mediaType == mediaType,
                  record.operationID == operationID, asset.role == (operationID == "d.asset.import" ? .original : .result) else { throw WorkflowIssue("资产身份重复且内容不符。") }
            _ = try workflowData(record.reference)
            return .init(record: record, asset: asset)
        }
        guard !manifest.assets.contains(where: { $0.id == assetID }), !name.isEmpty,
              let suffix = ["text/plain": "txt", "image/png": "png", "image/jpeg": "jpg"][mediaType],
              data.count <= 64 * 1_024 * 1_024 else { throw WorkflowIssue("发布内容类型、大小或身份不合法。") }
        if mediaType == "text/plain" {
            guard data.count <= 1_048_576, String(data: data, encoding: .utf8) != nil else { throw WorkflowIssue("文字必须为不超过 1 MiB 的 UTF-8。") }
        } else {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) == 1,
                  CGImageSourceGetStatus(source) == .statusComplete,
                  (CGImageSourceGetType(source) as String?) == (mediaType == "image/png" ? "public.png" : "public.jpeg"),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
                  let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
                  width > 0, height > 0, width <= 8192, height <= 8192, width * height <= 32 * 1_024 * 1_024,
                  metadata.width == width, metadata.height == height,
                  CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else { throw WorkflowIssue("图片内容与声明不符或无法完整解码。") }
        }
        for parent in parents { _ = try workflowData(parent) }
        let ref = WorkflowAssetReference(projectID: manifest.id, assetID: assetID,
                                         kind: mediaType == "text/plain" ? .text : .image, sha256: hash)
        var media = metadata
        if mediaType == "image/png" { media.imageContentSHA256 = hash }
        else { media.imageContentSHA256 = nil }
        let asset = ProjectAsset(id: assetID, relativePath: "WorkflowAssets/\(assetID.uuidString)/content.\(suffix)",
                                 mediaType: mediaType, role: operationID == "d.asset.import" ? .original : .result, metadata: media, name: name)
        let record = WorkflowAssetRecord(reference: ref, parents: parents, operationID: operationID,
                                          stepID: stepID, request: request, metadata: details)
        let folder = try ProjectFiles.openOrCreateDirectory("WorkflowAssets", in: rootFD)
        defer { Darwin.close(folder) }
        let directory = try ProjectFiles.openOrCreateDirectory(assetID.uuidString, in: folder)
        defer { Darwin.close(directory) }
        let filename = "content.\(suffix)"
        var statInfo = stat()
        if fstatat(directory, filename, &statInfo, AT_SYMLINK_NOFOLLOW) == 0 {
            // Retry publication after manifest failure, never overwrite an unrelated orphan.
            guard try ProjectFiles.read(relative: filename, in: directory, limit: 64 * 1_024 * 1_024) == data else {
                throw WorkflowIssue("已有未登记资产内容不同，保留原件并停止。")
            }
        } else {
            guard errno == ENOENT else { throw ProjectFiles.error() }
            try ProjectFiles.publish(in: directory, name: filename, replacing: false) { fd in
                try data.withUnsafeBytes { try ProjectFiles.writeAll($0, to: fd) }
            }
        }
        try checkpoint?(.assetDurable)
        archive.assets.append(record); archive.revision = UUID()
        try commitWorkflow(archive, assets: manifest.assets + [asset], checkpoint: checkpoint)
        return .init(record: record, asset: asset)
    }

    public func workflowData(_ ref: WorkflowAssetReference) throws -> Data {
        let archive = try editableWorkflow()
        guard ref.projectID == manifest.id, archive.assets.contains(where: { $0.reference == ref }),
              let asset = manifest.assets.first(where: { $0.id == ref.assetID }) else { throw WorkflowIssue("资产版本不属于当前项目。") }
        let data = try ProjectFiles.read(relative: asset.relativePath, in: rootFD, limit: 64 * 1_024 * 1_024)
        guard Self.workflowHash(data) == ref.sha256 else { throw WorkflowIssue("原始资产已改变；停止执行，未重新绑定新内容。") }
        return data
    }

    /// Pin an existing project asset, without copying it into a second asset system.
    public func pinWorkflowAsset(_ id: UUID) throws -> WorkflowAssetReference {
        var archive = try editableWorkflow()
        if let record = archive.assets.first(where: { $0.reference.assetID == id }) {
            _ = try workflowData(record.reference); return record.reference
        }
        guard let asset = manifest.assets.first(where: { $0.id == id }),
              ["text/plain", "image/png", "image/jpeg"].contains(asset.mediaType) else { throw WorkflowIssue("此资产不属于 M0 支持的文字或图像类型。") }
        let data = try ProjectFiles.read(relative: asset.relativePath, in: rootFD, limit: 64 * 1_024 * 1_024)
        let ref = WorkflowAssetReference(projectID: manifest.id, assetID: id,
            kind: asset.mediaType == "text/plain" ? .text : .image, sha256: Self.workflowHash(data))
        let job = manifest.jobs.first { $0.id == asset.jobID }
        archive.assets.append(.init(reference: ref, parents: [], operationID: "d.asset.existing", request: job?.request,
                                    metadata: ["source": "existing-project-asset"]))
        archive.revision = UUID(); try commitWorkflow(archive, assets: manifest.assets)
        return ref
    }

    /// Import snapshots approved files. Subsequent source changes do not change the published version.
    public func importWorkflowFile(at source: URL) throws -> WorkflowPublishedAsset {
        try checkLocation()
        let parent = try ProjectFiles.openDirectory(source.deletingLastPathComponent())
        defer { Darwin.close(parent) }
        let data = try ProjectFiles.read(relative: source.lastPathComponent, in: parent, limit: 64 * 1_024 * 1_024)
        if ["txt", "md"].contains(source.pathExtension.lowercased()) {
            return try publishWorkflowAsset(data: data, mediaType: "text/plain", name: source.lastPathComponent,
                                             operationID: "d.asset.import", details: ["origin": "explicit-file-snapshot"])
        }
        guard let image = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(image) as String?, ["public.png", "public.jpeg"].contains(type),
              let props = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [String: Any] else { throw WorkflowIssue("请选择 TXT、MD、PNG 或 JPEG。") }
        let media = MediaMetadata(width: props[kCGImagePropertyPixelWidth as String] as? Int,
                                  height: props[kCGImagePropertyPixelHeight as String] as? Int,
                                  bitDepth: props[kCGImagePropertyDepth as String] as? Int,
                                  colorSpace: props[kCGImagePropertyProfileName as String] as? String)
        return try publishWorkflowAsset(data: data, mediaType: type == "public.png" ? "image/png" : "image/jpeg",
                                         metadata: media, name: source.lastPathComponent, operationID: "d.asset.import",
                                         details: ["origin": "explicit-file-snapshot", "sourceName": source.lastPathComponent])
    }
}

extension ProjectStore {
    public func readWorkflowBackendImage(_ artifact: ArtifactReference, runID: UUID) throws -> Data {
        try checkLocation()
        // Same backend-owned output convention used by ProjectJob. Never follow an arbitrary backend URL.
        guard artifact.mediaType == "image/png" else { throw WorkflowIssue("后端媒体类型无效。") }
        let relative = try ProjectFiles.relativeArtifact(artifact.url, root: rootURL, jobID: runID)
        return try ProjectFiles.read(relative: relative, in: rootFD, limit: 64 * 1_024 * 1_024)
    }

    /// A directory package atomically publishes media, a portable recipe and a receipt as one unit.
    /// Export never includes model paths, bookmarks, account information, or the private inference request.
    public func exportWorkflowAssets(_ refs: [WorkflowAssetReference], name: String, exportID: UUID,
                                      directory: URL) throws -> WorkflowExportReceipt {
        let archive = try editableWorkflow()
        guard !refs.isEmpty, refs.count <= 8, !name.isEmpty, name.utf8.count <= 128,
              !name.contains("/"), !name.contains("\\"), !name.contains(".."), !name.contains("\0") else {
            throw WorkflowIssue("导出名称必须是单个安全文件名。")
        }
        let parent = try ProjectFiles.openDirectory(directory); defer { Darwin.close(parent) }
        let packageName = name + "-" + exportID.uuidString + ".dexport"
        let destination = directory.appendingPathComponent(packageName, isDirectory: true)
        struct Recipe: Codable {
            struct Item: Codable {
                let reference: WorkflowAssetReference; let filename: String?; let parents: [WorkflowAssetReference]
                let operationID: String; let stepID: UUID?; let modelRevision: String?; let input: InferenceInput?
                let mediaType: String; let metadata: MediaMetadata
                let seedDecimal: String?; let processing: [String: String]
            }
            let version: Int; let exportID: UUID; let items: [Item]; let provenance: [Item]; let promptDisclosure: String
        }
        func item(_ ref: WorkflowAssetReference, filename: String?) throws -> Recipe.Item {
            guard let asset = manifest.assets.first(where: { $0.id == ref.assetID }),
                  let record = archive.assets.first(where: { $0.reference == ref }) else { throw WorkflowIssue("来源资产缺失。") }
            // Reference-image requests contain a private normalized-pixel URL; portable recipe retains only source IDs.
            let input: InferenceInput?
            var seed: String?
            if let request = record.request, case .image(let image) = request.input {
                input = .image(ImageRequest(prompt: "[withheld]", width: image.width, height: image.height,
                    steps: image.steps, guidanceScale: image.guidanceScale, seed: image.seed, executionProfile: image.executionProfile))
                seed = String(image.seed)
            } else if let request = record.request, case .text(let text) = request.input {
                input = .text(TextRequest(prompt: "[withheld]", maxTokens: text.maxTokens,
                    temperature: text.temperature, topP: text.topP, execution: text.execution))
            }
            else { input = nil }
            let permitted: Set<String> = ["scalePolicy", "scale", "backgroundPolicy", "quality", "alpha",
                "originalFormat", "originalOrientation", "originalColorSpace", "normalizedOrientation", "normalizedColorSpace",
                "outputEncoding", "processor", "colorConversion", "encoding", "operation"]
            return .init(reference: ref, filename: filename, parents: record.parents, operationID: record.operationID,
                stepID: record.stepID, modelRevision: record.request?.model.revision, input: input,
                mediaType: asset.mediaType, metadata: asset.metadata, seedDecimal: seed,
                processing: record.metadata.filter { permitted.contains($0.key) })
        }
        var files: [(String, Data)] = []; var recipeItems: [Recipe.Item] = []; var provenance: [Recipe.Item] = []
        var visited = Set<WorkflowAssetReference>(), active = Set<WorkflowAssetReference>()
        func collect(_ ref: WorkflowAssetReference, depth: Int) throws {
            guard depth <= 128, visited.count < 4096, !active.contains(ref) else { throw WorkflowIssue("来源链循环或超出导出预算。") }
            if visited.contains(ref) { return }
            active.insert(ref)
            let record = try item(ref, filename: nil)
            for parent in record.parents.sorted(by: { $0.assetID.uuidString < $1.assetID.uuidString }) { try collect(parent, depth: depth + 1) }
            active.remove(ref); visited.insert(ref); provenance.append(record)
        }
        for (i, ref) in refs.enumerated() {
            let data = try workflowData(ref)
            let record = try item(ref, filename: nil)
            guard let ext = ["text/plain":"txt", "image/png":"png", "image/jpeg":"jpg"][record.mediaType] else { throw WorkflowIssue("导出资产类型无效。") }
            let file = "\(i + 1).\(ext)"; files.append((file, data)); recipeItems.append(try item(ref, filename: file))
            try collect(ref, depth: 0)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let recipe = try encoder.encode(Recipe(version: 1, exportID: exportID, items: recipeItems,
            provenance: provenance, promptDisclosure: "withheld; full requests remain in the private project"))
        files.append(("recipe.json", recipe))
        let receipt = WorkflowExportReceipt(id: exportID, names: files.map(\.0), hashes: files.map { Self.workflowHash($0.1) })
        let receiptData = try encoder.encode(receipt)
        var info = stat()
        if fstatat(parent, packageName, &info, AT_SYMLINK_NOFOLLOW) == 0 {
            let existing = try ProjectFiles.openRelativeDirectory(packageName, in: parent); defer { Darwin.close(existing) }
            let saved = try JSONDecoder().decode(WorkflowExportReceipt.self,
                from: ProjectFiles.read(relative: "receipt.json", in: existing, limit: 1_048_576))
            guard saved.id == receipt.id, saved.names == receipt.names, saved.hashes == receipt.hashes else {
                throw ProjectStoreError.alreadyExists(packageName)
            }
            for (filename, data) in files {
                guard try ProjectFiles.read(relative: filename, in: existing, limit: 64 * 1_024 * 1_024) == data else {
                    throw WorkflowIssue("同名导出包内容改变，未覆盖。")
                }
            }
            return saved
        }
        guard errno == ENOENT else { throw ProjectFiles.error() }
        let temporary = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
            appropriateFor: destination, create: true).resolvingSymlinksInPath()
        let staging = try ProjectFiles.openDirectory(temporary); defer { Darwin.close(staging) }
        var stagingInfo = stat(), targetInfo = stat()
        guard fstat(staging, &stagingInfo) == 0, fstat(parent, &targetInfo) == 0,
              stagingInfo.st_dev == targetInfo.st_dev else { throw WorkflowIssue("导出暂存位置不在目标卷；未发布。") }
        let content = try ProjectFiles.openOrCreateDirectory("content", in: staging); defer { Darwin.close(content) }
        for (filename, data) in files + [("receipt.json", receiptData)] {
            try ProjectFiles.publish(in: content, name: filename, replacing: false) { fd in
                try data.withUnsafeBytes { try ProjectFiles.writeAll($0, to: fd) }
            }
            guard try ProjectFiles.read(relative: filename, in: content, limit: 64 * 1_024 * 1_024) == data else { throw WorkflowIssue("导出回读不一致，未发布。") }
        }
        guard fsync(content) == 0 else { throw ProjectFiles.error() }
        guard renameatx_np(staging, "content", parent, packageName, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { throw ProjectStoreError.alreadyExists(packageName) }
            throw ProjectFiles.error()
        }
        guard fsync(parent) == 0 else { throw WorkflowIssue("导出包已发布，但目录同步失败；请保留并检查，重试不会覆盖。") }
        // Remove only our now-empty OS-created staging directory. A failed partial package is deliberately retained.
        if let owner = try? ProjectFiles.openDirectory(temporary.deletingLastPathComponent()) {
            _ = unlinkat(owner, temporary.lastPathComponent, AT_REMOVEDIR); Darwin.close(owner)
        }
        return receipt
    }
}
