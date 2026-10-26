import DWorkbench
import SwiftUI

/// One bounded request, using the existing model-library owner and task ledger.
struct ModelAcquisitionView: View {
    @Bindable var model: ModelLibraryModel
    let request: ModelLibraryModel.AcquisitionRequest
    @Environment(\.dLanguageStore) private var language
    @State private var selection: Set<String> = []
    @State private var search = ""
    @State private var confirming = false
    @State private var register = false
    @State private var useTarget = false
    @State private var tokenVisible = false
    @State private var checking: String?
    @State private var accessible: Set<String> = []
    @State private var accessErrors: [String: String] = [:]
    private func t(_ key: String, _ arguments: [String: String] = [:]) -> String {
        workflowText(language, "modelAcquisition." + key, arguments: arguments)
    }
    private var selected: [ModelCatalogEntry] { model.catalog.filter { selection.contains($0.id) } }
    private var pending: Bool { !model.pendingCatalogIDs.isEmpty || checking != nil || model.acquisitionSubmissionID != nil || model.globalOperation != nil }
    private func matchingResources(_ entry: ModelCatalogEntry) -> [ModelResource] {
        ModelLibraryModel.acquisitionResources(entry, snapshot: model.snapshot)
    }
    private func resource(_ entry: ModelCatalogEntry) -> ModelResource? {
        let matches = matchingResources(entry)
        return matches.count == 1 ? matches.first : nil
    }
    private func task(_ entry: ModelCatalogEntry) -> ModelDownloadTask? {
        guard let resource = resource(entry) else { return nil }
        return model.snapshot?.downloads.first { $0.resourceID == resource.id && !$0.state.isTerminal }
    }
    private func accessRequired(_ entry: ModelCatalogEntry) -> Bool {
        let access = entry.acquisitionDisclosure?.access ?? .unverified
        return [.readToken, .sourceWebsiteApproval].contains(access) && !accessible.contains(entry.id)
    }
    private func downloadable(_ entry: ModelCatalogEntry) -> Bool {
        guard matchingResources(entry).count <= 1, resource(entry)?.control.fileState != .verified, task(entry) == nil, !accessRequired(entry) else { return false }
        if let date = resource(entry)?.control.retryNotBefore, date > Date() { return false }
        return true
    }
    private var available: [ModelCatalogEntry] { selected.filter(downloadable) }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !confirming {
                Text(t("choose")).font(.headline).padding([.horizontal, .top], 20)
                TextField(t("search"), text: $search).textFieldStyle(WorkbenchGlassTextFieldStyle()).padding(20)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(model.catalog.filter { search.isEmpty || $0.title.localizedStandardContains(search) }) { entry in
                            VStack(alignment: .leading, spacing: 8) {
                                Toggle(entry.title, isOn: Binding(get: { selection.contains(entry.id) }, set: { if $0 { selection.insert(entry.id) } else { selection.remove(entry.id) } }))
                                ModelSpecificationFields(descriptor: ModelAcquisitionInformation.descriptor(entry), font: .caption)
                                Text(ModelLibraryModel.formatBytes(entry.totalBytes)).font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.padding(.horizontal, 20).padding(.bottom, 20)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(selected) { entry in
                            ModelAcquisitionInformation(entry: entry)
                            existingActions(entry)
                            accessActions(entry)
                            Divider()
                        }
                        storage
                        Text(t("afterDownload")).font(.headline)
                        Toggle(t("register"), isOn: $register).onChange(of: register) { _, value in if !value { useTarget = false } }
                        if let target = request.target {
                            Toggle(t("useTarget", ["target": target.title]), isOn: $useTarget)
                                .disabled(!register || !target.isCurrent())
                            if !target.isCurrent() { Text(t("targetChanged")).foregroundStyle(.orange) }
                        }
                        if model.snapshot?.queueState != .running && !(model.snapshot?.downloads.allSatisfy({ $0.state.isTerminal }) ?? true) || model.snapshot?.queueState == .paused {
                            Text(t("queuePaused")).font(.caption)
                        }
                        if let error = model.errorMessage { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
                    }.padding(20)
                }
            }
            Divider()
            HStack(spacing: 8) {
                WorkbenchRequestCloseButton(title: t("cancel"), fallback: { model.acquisitionRequest = nil })
                if confirming, request.target == nil { Button(t("back")) { confirming = false } }
                Spacer(minLength: 8)
                primary
            }.buttonStyle(WorkbenchGlassButtonStyle()).environment(\.workbenchActionHeight, 36).padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 16)
        }
        .buttonStyle(WorkbenchGlassButtonStyle())
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("model-acquisition-confirmation")
        .workbenchCloseProtection(isDirty: !selection.isEmpty || register || useTarget, isSaving: pending)
        .workbenchSheet(isPresented: $tokenVisible, title: workflowText(language, "modelManagement.accessToken"), size: .init(width: 600, height: 380)) {
            ModelAccessTokenEditor(model: model)
        }
        .onChange(of: tokenVisible) { _, visible in if !visible { accessible = [] } }
        .onAppear { selection = Set(request.catalogIDs); confirming = !request.catalogIDs.isEmpty }
    }
    private var storage: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(t("storage")).font(.headline)
            Text(t("total", ["size": ModelLibraryModel.formatBytes(selected.reduce(0) { $0 + $1.totalBytes })]))
            let bytes = available.map { ModelLibraryModel.additionalDownloadBytes($0, resource: resource($0)) }
            Text(t("additional", ["size": bytes.allSatisfy { $0 != nil } ? ModelLibraryModel.formatBytes(bytes.compactMap { $0 }.reduce(0, +)) : t("unknownBytes")]))
            HStack {
                Text(model.rootURL?.path ?? t("noRoot")).textSelection(.enabled)
                Spacer()
                Button(t("changeRoot")) { Task { await model.chooseRoot() } }.disabled(!model.canChooseRoot)
            }
        }.font(.callout)
    }
    @ViewBuilder private var primary: some View {
        if !confirming {
            Button(t("review", ["count": String(selection.count)])) { confirming = true }
                .buttonStyle(WorkbenchPrimaryButtonStyle()).disabled(selected.isEmpty).keyboardShortcut(.defaultAction)
        } else if model.rootURL == nil && available.count > 0 {
            Button(t("chooseRoot")) { Task { await model.chooseRoot() } }.buttonStyle(WorkbenchPrimaryButtonStyle()).disabled(!model.canChooseRoot)
        } else if selected.count == 1, let entry = selected.first, matchingResources(entry).count > 1 {
            Button(t("viewExisting")) { model.resourceSearch = entry.title; model.workspace = "resources"; model.acquisitionRequest = nil }.buttonStyle(WorkbenchPrimaryButtonStyle())
        } else if selected.count == 1, let entry = selected.first, let current = task(entry) {
            Button(t("viewTask")) { model.selectedTask = current.id; model.workspace = "downloads"; model.acquisitionRequest = nil }.buttonStyle(WorkbenchPrimaryButtonStyle())
        } else if selected.count == 1, let entry = selected.first, let current = resource(entry), current.control.fileState == .verified {
            if register, useTarget, request.target != nil, current.record.state == .installed {
                Button(t("useExisting")) { Task { await model.confirmExistingRegistration(requestID: request.id, resource: current, useTarget: true) } }.buttonStyle(WorkbenchPrimaryButtonStyle()).disabled(pending)
            } else if current.record.registrationState != .registered && current.record.state == .installed {
                Button(t("register")) { Task { await model.confirmExistingRegistration(requestID: request.id, resource: current) } }.buttonStyle(WorkbenchPrimaryButtonStyle()).disabled(pending)
            } else { Button(t("viewExisting")) { viewResource(current) }.buttonStyle(WorkbenchPrimaryButtonStyle()) }
        } else if selected.count == 1, let entry = selected.first, accessRequired(entry) {
            if entry.acquisitionDisclosure?.access == .readToken, !model.downloadCredentialConnected {
                Button(t("setToken")) { tokenVisible = true }.buttonStyle(WorkbenchPrimaryButtonStyle())
            } else if entry.acquisitionDisclosure?.access == .sourceWebsiteApproval, !model.downloadCredentialConnected,
                      let url = URL(string: "https://huggingface.co/" + entry.repository) {
                Link(t("requestAccess"), destination: url).buttonStyle(WorkbenchPrimaryButtonStyle())
            } else { Button(t("recheck")) { check(entry) }.buttonStyle(WorkbenchPrimaryButtonStyle()).disabled(pending) }
        } else {
            let partial = available.count != selected.count
            let held = model.snapshot?.queueState == .paused || (model.snapshot?.queueState == .waitingForResume && model.snapshot?.downloads.contains { !$0.state.isTerminal } == true)
            Button(t(partial ? (held ? "enqueueAvailable" : "startAvailable") : (held ? "enqueue" : "start"), ["count": String(available.count)])) { submit(available) }
                .buttonStyle(WorkbenchPrimaryButtonStyle()).disabled(available.isEmpty || pending || (useTarget && request.target?.isCurrent() != true))
                .keyboardShortcut(.defaultAction)
        }
    }
    @ViewBuilder private func existingActions(_ entry: ModelCatalogEntry) -> some View {
        if matchingResources(entry).count > 1 {
            Button(t("viewExisting")) { model.resourceSearch = entry.title; model.workspace = "resources"; model.acquisitionRequest = nil }
        } else if let current = task(entry) {
            Text(t("existingTask")).font(.caption)
            Button(t("viewTask")) { model.selectedTask = current.id; model.workspace = "downloads"; model.acquisitionRequest = nil }
        } else if let current = resource(entry), current.control.fileState == .verified {
            Text(t("existingFiles")).font(.caption)
            Button(t("viewExisting")) { viewResource(current) }
        } else if let date = resource(entry)?.control.retryNotBefore, date > Date() {
            Text(workflowText(language, "modelManagement.retryAfter", arguments: ["time": date.formatted()]))
        }
    }
    @ViewBuilder private func accessActions(_ entry: ModelCatalogEntry) -> some View {
        if [.readToken, .sourceWebsiteApproval].contains(entry.acquisitionDisclosure?.access ?? .unverified) {
            if entry.acquisitionDisclosure?.access == .sourceWebsiteApproval, let url = URL(string: "https://huggingface.co/" + entry.repository) {
                Link(t("requestAccess"), destination: url)
            }
            HStack {
                Button(t("setToken")) { tokenVisible = true }
                Button(t("recheck")) { check(entry) }.disabled(pending)
                if checking == entry.id { ProgressView().controlSize(.small) }
            }
            if accessible.contains(entry.id) { Text(t("accessVerified")).font(.caption) }
            if let error = accessErrors[entry.id] { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
        }
    }
    private func check(_ entry: ModelCatalogEntry) {
        guard checking == nil else { return }; checking = entry.id
        Task {
            defer { checking = nil }
            do { try await model.library.checkCatalogAccess(catalogID: entry.id); accessible.insert(entry.id); accessErrors[entry.id] = nil }
            catch { accessible.remove(entry.id); accessErrors[entry.id] = model.credentialMessage(error) }
        }
    }
    private func submit(_ entries: [ModelCatalogEntry]) {
        let register = register, use = useTarget
        Task { await model.confirmAcquisition(requestID: request.id, entries: entries, register: register, useTarget: use) }
    }
    private func viewResource(_ resource: ModelResource) {
        model.selectedResource = resource.id; model.workspace = "resources"; model.acquisitionRequest = nil
    }
}

/// Reused for download confirmation and local registration. Facts remain catalog-owned.
struct ModelAcquisitionInformation: View {
    let entry: ModelCatalogEntry
    @Environment(\.dLanguageStore) private var language
    @State private var sourcesVisible = false
    static func descriptor(_ entry: ModelCatalogEntry) -> ModelNodeDescriptor? {
        ModelNodeCatalog.entries.first { $0.revision == entry.revision && ($0.id == entry.workflowIdentity || $0.modelIdentity == entry.repository || (entry.id == "stable-audio-small-music" && $0.id == "sm-music")) }
    }
    private func t(_ key: String) -> String { workflowText(language, "modelAcquisition." + key) }
    var body: some View {
        let disclosure = entry.acquisitionDisclosure ?? .unknown
        VStack(alignment: .leading, spacing: 8) {
            Text(entry.title).font(.headline)
            Text(entry.repository).font(.caption).foregroundStyle(.secondary)
            ModelSpecificationFields(descriptor: Self.descriptor(entry))
            if let descriptor = Self.descriptor(entry) { Text(ModelNodeUILocalization.owned(descriptor.summary, language: language)).font(.callout) }
            Text(t("licenseAccess")).font(.headline).padding(.top, 8)
            field("commercial", "commercial." + disclosure.commercialUse.rawValue)
            field("fee", "fee." + disclosure.licenseFee.rawValue)
            field("access", "access." + disclosure.access.rawValue)
            Text(workflowText(language, disclosure.summaryKey)).font(.callout).textSelection(.enabled)
            Button(t("sources"), systemImage: "chevron.right") { sourcesVisible = true }
            Text(workflowText(language, "modelManagement.catalog." + entry.id + ".memory", fallback: entry.memoryGuidance)).font(.caption).foregroundStyle(.secondary)
            if entry.preparation != .none { Text(workflowText(language, "modelManagement.needsPreparation")).font(.caption) }
        }.frame(maxWidth: .infinity, alignment: .leading)
        .workbenchSheet(isPresented: $sourcesVisible, title: t("sources"), size: .init(width: 640, height: 520)) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(t("sourceNotice")).font(.callout)
                    ForEach(disclosure.components) { component in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(component.scopes.map { t("scope." + $0) }.joined(separator: " · ")).font(.headline)
                            Text(component.license ?? t("unverified"))
                            Text(workflowText(language, component.summaryKey)).textSelection(.enabled)
                            ForEach(Array(component.sources.enumerated()), id: \.offset) { _, source in
                                Text(t("evidence." + source.evidence)).font(.caption)
                                Link(source.url.host ?? t("source"), destination: source.url)
                                WorkflowTechnicalDetails(value: [source.url.absoluteString, source.revision, source.sha256].compactMap { $0 }.joined(separator: "\n"))
                            }
                        }
                    }
                    if disclosure.components.isEmpty { Text(t("unverified")) }
                    WorkflowTechnicalDetails(value: [entry.id, entry.revision, disclosure.checkedAt].joined(separator: "\n"))
                }.padding(20)
            }
        }
    }
    private func field(_ label: String, _ value: String) -> some View {
        (Text(t(label) + ": ").fontWeight(.medium) + Text(t(value))).font(.callout)
    }
}
