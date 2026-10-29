import AppKit
import Darwin
import Observation
import DWorkbench
import SwiftUI
import UniformTypeIdentifiers

enum ProjectFilesPresentation {
    static func selectedStatus(_ item: AssetLocationOverview) -> AssetLocationStatus? {
        item.locations.first(where: { $0.id == item.selectedLocationID })?.status
    }
    static func allSucceeded(_ values: [AssetRelocationResult]) -> Bool {
        values.allSatisfy(\.matched)
    }

    /// A cancelled file job still needs to publish its already committed steps.
    @MainActor static func refreshAfterOperation(store: ProjectStore, instanceID: UUID,
        refreshMedia: Bool = true,
        onContentsChanged: @escaping @MainActor (ProjectStore, UUID, Bool) async -> Void,
        refreshOverview: @escaping @MainActor () async -> Void) async {
        let refresh = Task { @MainActor in
            await onContentsChanged(store, instanceID, refreshMedia)
            await refreshOverview()
        }
        await refresh.value
    }

    @MainActor static func createBackup(at url: URL, store: ProjectStore, instanceID: UUID,
        modelLibrary: ModelLibrary, models: [ModelID], allowIncomplete: Bool,
        isActive: @escaping @MainActor () -> Bool,
        saveDrafts: @escaping @MainActor (ProjectStore, UUID) async throws -> Void) async throws -> ProjectBackupReceipt {
        try Task.checkCancellation()
        guard isActive() else { throw ProjectFilesViewError.staleProject }
        try await saveDrafts(store, instanceID)
        try Task.checkCancellation()
        guard isActive() else { throw ProjectFilesViewError.staleProject }
        return try await store.createBackup(at: url, modelLibrary: modelLibrary,
            includingModels: models, allowIncomplete: allowIncomplete)
    }
}

/// The UI captures its exact destination before opening the native selector.
/// The same admission check runs on both sides of the suspension.
@MainActor struct WorkbenchAssetImportCommand {
    let store: ProjectStore
    let controller: WorkflowController?
    let staleMessage: String
    let isCurrent: () -> Bool
    var didImport: @MainActor () async -> Void = {}
    func perform(choose: () async throws -> (URL, AssetImportMode)?) async throws -> Bool {
        guard isCurrent() else { throw WorkflowIssue(staleMessage) }
        guard let (url, mode) = try await choose() else { return false }
        guard isCurrent() else { throw WorkflowIssue(staleMessage) }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let controller { try await controller.importLibraryFileReportingFailure(url, mode: mode) }
        else { _ = try await store.importWorkflowMediaFile(at: url, mode: mode) }
        if isCurrent() { await didImport() }
        return true
    }
}

/// Existing package exporter, with one immutable source/reference admission on
/// both sides of the destination panel. No external application is launched.
@MainActor struct WorkbenchAssetExportCommand {
    let store: ProjectStore
    let reference: WorkflowAssetReference
    let staleMessage: String
    let isCurrent: () -> Bool
    func perform(choose: () async -> URL?) async throws -> Bool {
        guard isCurrent() else { throw WorkflowIssue(staleMessage) }
        guard let destination = await choose() else { return false }
        guard isCurrent() else { throw WorkflowIssue(staleMessage) }
        let scoped = destination.startAccessingSecurityScopedResource()
        defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
        _ = try await store.exportWorkflowAssets([reference], name: "D-" + UUID().uuidString.prefix(8), exportID: UUID(), directory: destination)
        return true
    }
}

@MainActor
enum NativeAssetImportPanel {
    static func choose(language: UILanguageStore?) async -> (URL, AssetImportMode)? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        let accessory = NativeAssetImportAccessory(panel: panel, language: language)
        let response = await panel.begin()
        defer { withExtendedLifetime(accessory) {} }
        guard response == .OK, let url = panel.url else { return nil }
        return (url, accessory.picker.indexOfSelectedItem == 1 ? .reference : .copy)
    }
}

/// The reference warning belongs only to reference mode. Retain the same native
/// picker across a language refresh, including its selected import semantics.
@MainActor final class NativeAssetImportAccessory: NSObject {
    let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 400, height: 28))
    let note = NSTextField(labelWithString: "")
    private weak var panel: NSOpenPanel?
    private let language: UILanguageStore?
    init(panel: NSOpenPanel, language: UILanguageStore?) {
        self.panel = panel; self.language = language
        super.init()
        picker.target = self; picker.action = #selector(selectionChanged)
        note.lineBreakMode = .byWordWrapping
        let accessory = NSStackView(views: [picker, note])
        accessory.orientation = .vertical; accessory.alignment = .leading; accessory.spacing = 6
        accessory.frame = NSRect(x: 0, y: 0, width: 420, height: 110)
        panel.accessoryView = accessory
        refreshLanguage()
    }
    func refreshLanguage() {
        withObservationTracking {
            let selected = max(0, picker.indexOfSelectedItem)
            panel?.title = workflowText(language, "files.import.title")
            panel?.prompt = workflowText(language, "files.chooseFile")
            picker.removeAllItems()
            picker.addItems(withTitles: [workflowText(language, "files.import.copy"), workflowText(language, "files.import.reference")])
            picker.selectItem(at: selected)
            picker.setAccessibilityLabel(workflowText(language, "files.import.title"))
            note.stringValue = workflowText(language, "files.import.warning")
            selectionChanged()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.refreshLanguage() }
        }
    }
    @objc func selectionChanged() { note.isHidden = picker.indexOfSelectedItem != 1 }
}

/// The sheet owns only presentation state. Every operation captures its original Store and
/// discards completion UI when the active project has changed.
@MainActor
struct ProjectFilesView: View {
    @Environment(\.dLanguageStore) private var consistencyLanguage
    let store: ProjectStore
    let instanceID: UUID
    let isActive: @MainActor () -> Bool
    let modelLibrary: ModelLibrary
    let onContentsChanged: @MainActor (ProjectStore, UUID, Bool) async -> Void
    let saveDraftsForBackup: @MainActor (ProjectStore, UUID) async throws -> Void
    let onOpenRestored: (URL) async -> String?
    var onOpenGraph: (UUID, UUID) -> Bool = { _, _ in false }
    let onClose: () -> Void
    var initialAssetID: UUID? = nil

    @Environment(\.dLanguageStore) private var language
    @State private var overview: ProjectFileOverview?
    @State private var selectedAssetID: UUID?
    @State private var message: ProjectFilesMessage?
    @State private var results: [AssetRelocationResult] = []
    @State private var receipt: ProjectBackupReceipt?
    @State private var receiptKind: ProjectFileOperation?
    @State private var restoredURL: URL?
    @State private var models: [ModelRecord] = []
    @State private var modelTitles: [String: String] = [:]
    @State private var chosenModels: Set<ModelID> = []
    @State private var pendingBackup: (URL, [ModelID], [String])?
    @State private var pendingRestore: (URL, URL)?
    @State private var job: Task<Void, Never>?
    @State private var busy = false

    private func word(_ key: String) -> String { workflowText(language, "files." + key) }
    private var selected: AssetLocationOverview? { overview?.assets.first { $0.asset.id == selectedAssetID } }
    private func bytes(_ value: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file) }
    private func date(_ value: Date?) -> String { value?.formatted(date: .abbreviated, time: .shortened) ?? word("unknown") }
    private func role(_ value: AssetLocationRole) -> String {
        switch value {
        case .externalOriginal: word("role.original")
        case .independentCopy: word("role.library")
        case .projectCopy: word("role.project")
        }
    }
    private func status(_ value: AssetLocationStatus) -> String {
        switch value {
        case .verified: word("status.verified")
        case .pendingVerification: word("status.pending")
        case .offline: word("status.offline")
        case .needsAuthorization: word("status.authorization")
        case .missing: word("status.missing")
        case .changed: word("status.changed")
        case .corrupt: word("status.corrupt")
        case .previewOnly: word("status.preview")
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button(word("back"), action: onClose).keyboardShortcut(.cancelAction)
                Text(word("title")).font(.title2.bold())
                Spacer()
                if busy { ProgressView() }
                Button(word("cancel")) { job?.cancel() }.disabled(!busy)
            }
            ScrollView {
            VStack(alignment: .leading, spacing: 12) {
            if let overview {
                Text("\(word("external")) \(overview.externalCount) · \(word("collectBytes")) \(bytes(overview.bytesToCollect))")
                    .font(.headline)
                Text(consistencyText(consistencyLanguage, "remaining.5e684d0ea7f7"))
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(overview.libraryAvailability.filter { $0.offline + $0.needsAuthorization + $0.missing > 0 }) { library in
                    Text(consistencyText(consistencyLanguage, "remaining.e623bd900e14", arguments: ["v0": String(describing: library.name), "v1": String(describing: library.offline), "v2": String(describing: library.needsAuthorization), "v3": String(describing: library.missing)]))
                        .font(.caption).foregroundStyle(.orange)
                }
                HStack(alignment: .top, spacing: 14) {
                    List(overview.assets, id: \.asset.id, selection: $selectedAssetID) { item in
                        VStack(alignment: .leading) {
                            Text(item.asset.name)
                            Text(ProjectFilesPresentation.selectedStatus(item).map(status) ?? word("unknown"))
                                .font(.caption).foregroundStyle(.secondary)
                        }.tag(item.asset.id)
                    }.frame(minWidth: 220).disabled(busy)
                    ScrollView { if let selected { inspector(selected) } else { Text(word("choose")) } }
                        .frame(minWidth: 370, maxWidth: .infinity)
                }.frame(height: 260)
                HStack {
                    Button(word("collectAll")) { collectAll() }.help(word("collect.help")).disabled(busy || overview.externalCount == 0)
                    Button(word("findFolder")) { relocateFolder() }.help(word("findFolder.help")).disabled(busy)
                    Spacer()
                    Button(word("backup")) { prepareBackup() }.disabled(busy)
                    Button(word("restore")) { prepareRestore() }.disabled(busy)
                }
            } else if isActive() { ProgressView(word("loading")) }
            else { Text(consistencyText(consistencyLanguage, "remaining.de3479cae49b")) }
            if !models.isEmpty {
                DisclosureGroup(word("models")) {
                    ForEach(models, id: \.id) { record in
                        let eligible = (record.state == .installed || record.state == .preparationRequired)
                            && record.availability == .available
                        Toggle(isOn: Binding(get: { chosenModels.contains(record.id) }, set: { enabled in
                            if enabled { chosenModels.insert(record.id) } else { chosenModels.remove(record.id) }
                        })) {
                            Text("\(modelTitles[record.catalogID] ?? record.catalogID) · \(bytes(record.totalBytes))")
                        }.disabled(!eligible || busy)
                        if record.state == .preparationRequired {
                            Text(word("rawUnavailable"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text(word("modelsNote"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !results.isEmpty {
                Text(word("results")).font(.headline)
                ForEach(results) { result in VStack(alignment: .leading, spacing: 3) {
                    Text(result.assetName ?? result.id.uuidString).font(.subheadline.bold())
                    Text(ProjectFilesMessage.result(result).text(language))
                    if results.filter({ $0.assetName == result.assetName }).count > 1 {
                        Text(result.sourcePath ?? String(result.id.uuidString.prefix(8))).font(.caption).foregroundStyle(.secondary)
                    }
                    DisclosureGroup(word("technical")) {
                        Text(result.id.uuidString + "\n" + (ProjectFilesMessage.result(result).diagnostic ?? result.message) + (result.sourcePath.map { "\n" + $0 } ?? "")).font(.caption.monospaced()).textSelection(.enabled)
                    }
                } }
            }
            if let receipt {
                Text(receiptKind == .restore ? (receipt.complete ? word("restoreComplete") : word("restorePartial")) : (receipt.complete ? word("backupComplete") : word("backupPartial")))
                    .font(.headline)
                Text(receipt.directory.path).textSelection(.enabled)
                Text(workflowText(language, "files.receipt.count", arguments: ["count": String(receipt.fileCount)]) + " · " + bytes(receipt.byteCount))
                ForEach(receipt.missing, id: \.self) { Text($0).textSelection(.enabled) }
            }
            if receiptKind == .restore, let restoredURL {
                Button(word("openRestored")) {
                    Task { if let error = await onOpenRestored(restoredURL) { message = .init(key: "files.error.open", diagnostic: error) } }
                }
                    .disabled(busy)
            }
            if let message {
                Text(message.text(language)).foregroundStyle(.secondary).textSelection(.enabled)
                if let diagnostic = message.diagnostic {
                    DisclosureGroup(word("technical")) { Text(diagnostic).font(.caption.monospaced()).textSelection(.enabled) }
                }
            }
            }.frame(maxWidth: .infinity, alignment: .leading)
            }.scrollBounceBehavior(.basedOnSize)
        }
        .padding(20).frame(minWidth: 760, minHeight: 520)
        .task(id: instanceID) { await refresh(); await loadModels() }
        .onDisappear { job?.cancel() }
        .workbenchConfirmation(word("incomplete"), isPresented: Binding(get: { pendingBackup != nil }, set: { if !$0 { pendingBackup = nil } })) {
            Button(workflowText(language, "workflow.action.cancel"), role: .cancel) { pendingBackup = nil }.keyboardShortcut(.defaultAction)
            Button(word("backupIncomplete.continue")) {
                if let pendingBackup { runBackup(at: pendingBackup.0, models: pendingBackup.1, allowIncomplete: true) }
                pendingBackup = nil
            }
        } message: { Text(word("backupIncomplete.help") + "\n\n" + (pendingBackup?.2.joined(separator: "\n") ?? "")) }
        .workbenchConfirmation(word("restoreIncomplete"), isPresented: Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } })) {
            Button(workflowText(language, "workflow.action.cancel"), role: .cancel) { pendingRestore = nil }.keyboardShortcut(.defaultAction)
            Button(word("restoreIncomplete.continue")) {
                if let pendingRestore { runRestore(from: pendingRestore.0, to: pendingRestore.1, allowIncomplete: true) }
                pendingRestore = nil
            }
        } message: { Text(word("restoreWarning")) }
    }
    @ViewBuilder private func inspector(_ item: AssetLocationOverview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.asset.name).font(.headline)
            Text("\(word("knownUse")) \(item.knownUseCount)")
            ForEach(item.knownUses) { use in
                HStack {
                    VStack(alignment: .leading) {
                        Text(ProjectFilesMessage.useTitle(use, language: language)).font(.caption.weight(.semibold))
                        Text(ProjectFilesMessage.useSummary(use, language: language)).font(.caption2).foregroundStyle(.secondary)
                    }
                    DisclosureGroup(word("technical")) {
                        Text(ProjectFilesMessage.usePath(use, language: language) + "\n" + use.id + "\n" + use.title + "\n" + use.detail).font(.caption.monospaced()).textSelection(.enabled)
                    }
                    Spacer()
                    if let graphID = use.graphID, let nodeID = use.nodeID {
                        Button(consistencyText(consistencyLanguage, "remaining.27af6ebe6592")) {
                            if !onOpenGraph(graphID, nodeID) { message = .key("consistency.remaining.2ce262102d83") }
                        }.disabled(busy)
                    } else if let assetID = use.assetID {
                        Button(consistencyText(consistencyLanguage, "remaining.d5ba98aa2f62")) { selectedAssetID = assetID }.disabled(busy)
                    } else {
                        Text(use.kind == .run ? consistencyText(consistencyLanguage, "remaining.ab5c4898f626") : consistencyText(consistencyLanguage, "remaining.978615eb3e7a"))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            DisclosureGroup(word("technical")) {
                Text(item.asset.id.uuidString + "\nSHA-256: " + (item.contentSHA256 ?? word("unknown"))).font(.caption.monospaced()).textSelection(.enabled)
            }
            Text("\(word("size")): \(item.byteCount.map(bytes) ?? word("unknown"))")
            ForEach(item.locations) { location in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(location.id == item.selectedLocationID ? "●" : "○")
                        Text(location.location.libraryName).bold()
                        Text(role(location.location.role))
                        Spacer()
                        Text(status(location.status))
                    }
                    Text(location.resolvedURL?.path ?? location.location.url?.path ?? word("unknown"))
                        .font(.caption).textSelection(.enabled)
                    if let issue = location.issue { Text(word("issue." + issue.rawValue)).font(.caption).foregroundStyle(.orange) }
                    if let reason = location.reason {
                        DisclosureGroup(word("technical")) { Text(reason).font(.caption.monospaced()).textSelection(.enabled) }
                    }
                    if location.status == .needsAuthorization { Text(word("authorization.help")).font(.caption) }
                    Text("\(word("registered")): \(item.asset.fileLocations == nil ? word("unknown") : date(location.location.registeredAt)) · \(word("verified")): \(date(location.location.lastVerifiedAt)) · \(location.location.role == .externalOriginal ? consistencyText(consistencyLanguage, "remaining.19fb176689ad") : consistencyText(consistencyLanguage, "remaining.16bddd9faed3")): \(date(location.location.contentCreatedAt))")
                        .font(.caption).foregroundStyle(.secondary)
                    Button(consistencyText(consistencyLanguage, "remaining.ded07da9efc6")) { reveal(location) }
                        .disabled(busy || !canReveal(location))
                    if location.id != item.selectedLocationID {
                        Button(word("useLocation")) { useLocation(item.asset.id, location.id) }.help(word("useLocation.help")).disabled(busy)
                    }
                }.padding(8).background(Color.secondary.opacity(0.08)).cornerRadius(8)
            }
            ViewThatFits(in: .horizontal) {
                fileActions(item, vertical: false).fixedSize(horizontal: true, vertical: false)
                fileActions(item, vertical: true)
            }
            Text(word("changedNote")).font(.caption).foregroundStyle(.secondary)
            Button(word("importNew")) {
                Task {
                    guard let (url, mode) = await NativeAssetImportPanel.choose(language: language) else { return }
                    start { store in
                        let access = url.startAccessingSecurityScopedResource()
                        defer { if access { url.stopAccessingSecurityScopedResource() } }
                        _ = try await store.importWorkflowMediaFile(at: url, mode: mode)
                        return "files.importedNew"
                    }
                }
            }.disabled(busy)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func fileActions(_ item: AssetLocationOverview, vertical: Bool) -> some View {
        let layout = vertical ? AnyLayout(VStackLayout(alignment: .leading)) : AnyLayout(HStackLayout())
        return layout {
                Button(word("verify")) { start(kind: .verify, refreshMedia: false) { store in
                    try await store.verifyAssetLocation(item.asset.id)
                    return "files.verifiedNow"
                } }.disabled(busy)
                Button(word("findFile")) { relocateFile(item.asset.id) }.help(word("relink.help")).disabled(busy)
                Button(word("collectOne")) { start(kind: .collect) { store in
                    try await store.collectAsset(item.asset.id)
                    return "files.collected"
                } }.help(word("collect.help")).disabled(busy)
                Button(word("copyLibrary")) { collectToFolder(item.asset.id) }.help(word("move.help")).disabled(busy)
            }
    }
    private func clearOutcome() {
        message = nil; results = []; receipt = nil; receiptKind = nil; restoredURL = nil
    }
    private func refresh() async {
        do {
            let value = try await store.projectFileOverview()
            guard isActive() else { return }
            overview = value
            if selectedAssetID == nil { selectedAssetID = initialAssetID ?? value.assets.first?.asset.id }
        } catch { if isActive() { message = .failure(error) } }
    }
    private func loadModels() async {
        let snapshot = await modelLibrary.snapshot()
        guard isActive() else { return }
        models = snapshot.records
        modelTitles = Dictionary(uniqueKeysWithValues: snapshot.catalog.map { ($0.id, $0.title) })
    }
    private func start(kind: ProjectFileOperation = .general, refreshMedia: Bool = true,
                       _ operation: @escaping @MainActor (ProjectStore) async throws -> String) {
        guard !busy, isActive() else { return }
        busy = true; clearOutcome()
        let captured = store
        job = Task {
            do {
                let text = try await operation(captured)
                if isActive() { message = .key(text) }
            } catch is CancellationError { if isActive() { message = .key("files.cancelled.single") } }
            catch { if isActive() { message = .failure(error, operation: kind) } }
            await ProjectFilesPresentation.refreshAfterOperation(store: captured, instanceID: instanceID,
                refreshMedia: refreshMedia,
                onContentsChanged: onContentsChanged, refreshOverview: {
                    if isActive() { await refresh() }
                })
            busy = false; job = nil
        }
    }
    private func chooseFolder(_ title: String, message: String? = nil) async -> URL? {
        let panel = NSOpenPanel(); panel.title = title
        if let message { panel.message = message }
        panel.prompt = word("chooseFolder")
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        return await panel.begin() == .OK ? panel.url : nil
    }
    private func reveal(_ inspection: AssetLocationInspection) {
        guard canReveal(inspection) else { return }
        do {
            let url: URL
            if inspection.location.role == .projectCopy {
                guard let resolved = inspection.resolvedURL else { return }
                url = resolved
                try checkRevealFile(url)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else {
                guard let bookmark = inspection.location.bookmark else { throw ProjectFilesViewError.authorization }
                var stale = false
                url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                    relativeTo: nil, bookmarkDataIsStale: &stale)
                guard !stale else { throw ProjectFilesViewError.authorization }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                try checkRevealFile(url)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        } catch { message = .failure(error) }
    }
    private func canReveal(_ inspection: AssetLocationInspection) -> Bool {
        inspection.status == .verified || inspection.status == .pendingVerification || inspection.status == .changed
    }
    private func checkRevealFile(_ url: URL) throws {
        var file = stat()
        guard lstat(url.path, &file) == 0, file.st_mode & S_IFMT == S_IFREG, file.st_nlink == 1 else {
            throw ProjectFilesViewError.reveal
        }
    }
    private func relocateFile(_ id: UUID) {
        Task {
            let panel = NSOpenPanel(); panel.title = word("findFile")
            panel.prompt = word("chooseFile")
            panel.message = word("relink.help")
            panel.canChooseDirectories = false
            guard await panel.begin() == .OK, let url = panel.url else { return }
            start(kind: .relink) { store in
                let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                try await store.relocateAsset(id, to: url)
                return "files.relocated"
            }
        }
    }
    private func relocateFolder() {
        Task {
            guard let url = await chooseFolder(word("findFolder"), message: word("findFolder.help")) else { return }
            start { store in
                let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                let values = try await store.relocateAssets(in: url)
                if isActive() { results = values }
                return values.contains(where: { $0.outcome == .cancelled || $0.outcome == .notProcessed }) ? "files.cancelled" : (ProjectFilesPresentation.allSucceeded(values) ? "files.relocated" : "files.partial")
            }
        }
    }
    private func useLocation(_ id: UUID, _ location: UUID) {
        start(kind: .verify) { store in try await store.useAssetLocation(id, locationID: location); return "files.locationChosen" }
    }
    private func collectToFolder(_ id: UUID) {
        Task {
            guard let url = await chooseFolder(word("move.destination"), message: word("move.help")) else { return }
            start(kind: .move) { store in
                let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                try await store.collectAsset(id, to: url)
                return "files.libraryCopied"
            }
        }
    }
    private func collectAll() {
        start(kind: .collect) { store in
            let values = try await store.collectProjectMedia()
            if isActive() { results = values }
            return values.contains(where: { $0.outcome == .cancelled || $0.outcome == .notProcessed }) ? "files.cancelled" : (ProjectFilesPresentation.allSucceeded(values) ? "files.collected" : "files.partial")
        }
    }
    private func prepareBackup() {
        Task {
            guard !busy, isActive() else { return }
            let panel = NSSavePanel(); panel.title = word("backup")
            panel.nameFieldStringValue = "D-Backup.dbackup"
            panel.canCreateDirectories = true
            guard await panel.begin() == .OK, let url = panel.url, !busy, isActive() else { return }
            guard !FileManager.default.fileExists(atPath: url.path) else { message = .key("files.exists"); return }
            let ids = Array(chosenModels)
            busy = true; clearOutcome()
            job = Task {
                do {
                    try await saveDraftsForBackup(store, instanceID)
                    try Task.checkCancellation()
                    guard isActive() else { throw ProjectFilesViewError.staleProject }
                    let plan = try await store.backupPlan()
                    try Task.checkCancellation()
                    guard isActive() else { busy = false; job = nil; return }
                    busy = false; job = nil
                    if !plan.missing.isEmpty { pendingBackup = (url, ids, plan.missing) }
                    else { runBackup(at: url, models: ids, allowIncomplete: false) }
                } catch is CancellationError {
                    if isActive() { message = .key("files.cancelled.single") }
                    busy = false; job = nil
                } catch {
                    if isActive() { message = .failure(error, operation: .backup) }
                    busy = false; job = nil
                }
            }
        }
    }
    private func runBackup(at url: URL, models ids: [ModelID], allowIncomplete: Bool) {
        start(kind: .backup) { store in
            let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
            let value = try await ProjectFilesPresentation.createBackup(at: url, store: store,
                instanceID: instanceID, modelLibrary: modelLibrary, models: ids,
                allowIncomplete: allowIncomplete, isActive: isActive, saveDrafts: saveDraftsForBackup)
            if isActive() { receipt = value; receiptKind = .backup }
            return value.complete ? "files.backupComplete" : "files.backupPartial"
        }
    }
    private func prepareRestore() {
        Task {
            let source = NSOpenPanel(); source.title = word("restore")
            source.canChooseFiles = false; source.canChooseDirectories = true
            guard await source.begin() == .OK, let backup = source.url else { return }
            let destination = NSSavePanel(); destination.title = word("restoreDestination")
            destination.message = word("restoreDestination.help")
            destination.nameFieldStringValue = "Restored.dproject"
            destination.allowedContentTypes = ProjectDocumentType.allowedContentTypes
            guard await destination.begin() == .OK, let target = destination.url else { return }
            guard !FileManager.default.fileExists(atPath: target.path) else { message = .key("files.exists"); return }
            runRestore(from: backup, to: target, allowIncomplete: false)
        }
    }
    private func runRestore(from backup: URL, to target: URL, allowIncomplete: Bool) {
        guard !busy, isActive() else { return }
        busy = true; clearOutcome()
        job = Task {
            let sourceAccess = backup.startAccessingSecurityScopedResource()
            let targetAccess = target.startAccessingSecurityScopedResource()
            defer {
                if sourceAccess { backup.stopAccessingSecurityScopedResource() }
                if targetAccess { target.stopAccessingSecurityScopedResource() }
                busy = false; job = nil
            }
            do {
                let value = try await ProjectStore.restoreBackup(at: backup, to: target,
                    allowIncomplete: allowIncomplete)
                guard isActive() else { return }
                receipt = value; receiptKind = .restore
                restoredURL = target
                message = .key(value.complete ? "files.restoreComplete" : "files.restorePartial")
            } catch is CancellationError { if isActive() { message = .key("files.cancelled.single") } }
            catch ProjectBackupError.incompleteRequiresConfirmation where !allowIncomplete {
                if isActive() { pendingRestore = (backup, target) }
            } catch { if isActive() { message = .failure(error, operation: .restore) } }
        }
    }
}
