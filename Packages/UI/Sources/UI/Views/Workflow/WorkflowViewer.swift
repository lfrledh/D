import AppKit
import AVKit
import ImageIO
import DWorkbench
import Observation
import SwiftUI

enum WorkflowViewerValueSide { case input, output, materials }

struct WorkflowViewerTarget {
    let title: String
    let subtitle: String
    var value: WorkflowValue? = nil
    var resource: ProjectReadOnlyAsset? = nil
    var call: WorkflowCallReference? = nil
    var port: String? = nil
    var side: WorkflowViewerValueSide = .output
    var usesCallTitle = false
    var runtimeSource: WorkflowRuntimeAssetSource? = nil
}

struct WorkflowViewerCallIdentity:Hashable {
    let controller:ObjectIdentifier
    let project:UUID
    let instance:UUID
    let address:WorkflowExecutionAddress
    let step:UUID
}

/// A window owns its request, player and fixed content. A new preview never
/// cancels a workflow or replaces a different window's media session.
@MainActor @Observable final class WorkflowViewerSession {
    let id = UUID()
    let store: ProjectStore
    weak var owner: ProjectSession?
    let projectID: UUID
    let instanceID: UUID
    let controller: WorkflowController?
    private(set) var target: WorkflowViewerTarget
    private(set) var generation = UUID()
    private(set) var text: String?
    private(set) var image: CGImage?
    private(set) var mediaURL: URL?
    private(set) var audioFormat: DWorkbench.AudioFormatInfo?
    private(set) var metadata: ProjectAssetMetadataSnapshot?
    private(set) var consumers: [WorkflowConsumerMatch] = []
    private(set) var concept: String?
    private(set) var displayedValue: WorkflowValue?
    private(set) var provenance: String?
    private(set) var failure: String?
    private(set) var loading = false
    private(set) var suspended = false
    private(set) var editingAnnotations = false
    @ObservationIgnored private weak var editingModel: WorkbenchModel?
    @ObservationIgnored private var editingRuntimeTarget: WorkflowLibraryValue?
    func beginAnnotationEditing(model: WorkbenchModel) {
        guard !editingAnnotations else { return }
        editingRuntimeTarget = runtimeAnnotationTarget
        editingAnnotations = true; editingModel = model; model.beginEditing()
    }
    func endAnnotationEditing() {
        guard editingAnnotations else { return }
        editingAnnotations = false; editingModel?.endEditing(); editingModel = nil; editingRuntimeTarget = nil
    }
    let video = VideoPreview.Session()
    let audio = AudioTransport(recordingEnabled:false)
    var library:SharedLibraryStore?
    @ObservationIgnored private var task: Task<Void,Never>?
    @ObservationIgnored private var temporaryMedia: URL?
    @ObservationIgnored private let readSnapshot:(WorkflowAssetReference) async throws -> ProjectAssetMetadataSnapshot
    @ObservationIgnored private let readText:(WorkflowAssetReference) async throws -> String
    @ObservationIgnored private let writeAnnotations:(ProjectAssetEditBaseline,String?,String?,Bool?) async throws -> Void
    init(owner:ProjectSession,store:ProjectStore,projectID:UUID,instanceID:UUID,target:WorkflowViewerTarget,
         readSnapshot:((WorkflowAssetReference) async throws -> ProjectAssetMetadataSnapshot)? = nil,
         readText:((WorkflowAssetReference) async throws -> String)? = nil,
         writeAnnotations:((ProjectAssetEditBaseline,String?,String?,Bool?) async throws -> Void)? = nil) {
        self.owner=owner;self.store=store;self.projectID=projectID;self.instanceID=instanceID;self.target=target
        controller=owner.workflow
        self.readSnapshot=readSnapshot ?? { try await store.assetMetadataSnapshot(id:$0.assetID,reference:$0) }
        self.readText=readText ?? { try await store.workflowText($0) }
        self.writeAnnotations=writeAnnotations ?? { [weak owner] expected,name,note,favorite in
            guard let owner else { throw WorkflowIssue("Metadata owner closed / 元数据所有者已关闭。") }
            try await owner.saveAssetAnnotations(owner:store,expected:expected,name:name,note:note,isFavorite:favorite)
        }
    }
    var ownerIsCurrent: Bool {
        guard let owner else { return false }
        return owner.currentStore === store && owner.manifest?.id == projectID && owner.manifest?.effectiveInstanceID == instanceID
            && (controller == nil || (owner.workflow === controller && controller?.canReadLibraryMetadata == true))
    }
    func displayTitle(_ language: UILanguageStore?) -> String {
        if let metadata { return metadata.asset.name }
        if let key = runtimeAnnotationTarget?.annotationIdentity?.storageKey, let name = library?.metadata.runtimeAnnotations[key]?.name { return name }
        guard target.usesCallTitle, let record = exactRecord else { return target.title }
        let title = record.step.node.title
        guard let port = target.port else { return title }
        return title + " · " + WorkflowCanvasPresentation.portTitle(operationID: record.step.node.operationID, portID: port, fallback: port, input: target.side == .input, language: language)
    }
    func displaySubtitle(_ language: UILanguageStore?) -> String {
        if let call = target.call, let controller, let run = controller.runs.first(where: { $0.id == call.address.runID }) {
            return WorkflowHumanPresentation.run(run, in: controller.runs, language: language)
        }
        if let metadata { return metadata.asset.mediaType + " · " + metadata.asset.createdAt.formatted(date: .abbreviated, time: .shortened) }
        return target.subtitle
    }
    var runtimeAnnotationTarget: WorkflowLibraryValue? {
        if editingAnnotations { return editingRuntimeTarget }
        if let source = target.runtimeSource, let value = target.value, value.asset == nil, exactRecord != nil {
            return .init(projectID: projectID, instanceID: instanceID, call: source.call, port: source.port, value: value,
                createdAt: controller?.runs.first { $0.id == source.call.address.runID }?.createdAt ?? Date(timeIntervalSince1970: 0), source: source)
        }
        guard target.side == .output, let call = target.call, let port = target.port,
              let value = target.value, value.asset == nil, exactRecord != nil else { return nil }
        return .init(projectID: projectID, instanceID: instanceID, call: call, port: port, value: value, createdAt: controller?.runs.first { $0.id == call.address.runID }?.createdAt ?? Date(timeIntervalSince1970: 0))
    }
    var canRead: Bool {
        ownerIsCurrent && owner?.canEditLibraryMetadata == true
    }
    func replace(_ target:WorkflowViewerTarget) {
        guard !editingAnnotations else { return }
        stop();self.target=target;load()
    }
    @discardableResult func load() -> Task<Void,Never>? {
        guard !editingAnnotations else { return nil }
        guard canRead else { suspend();return nil }
        stop(); suspended=false;loading=true;text=nil;image=nil;mediaURL=nil;audioFormat=nil;metadata=nil;provenance=nil;failure=nil
        consumers = []; concept = nil; displayedValue = target.value
        if let value = target.value { inspectCompatibility(value) }
        let request=generation, target=self.target
        task=Task { [weak self] in
            guard let self else { return }
            await self.read(target,request:request)
        }
        return task
    }
    private func current(_ request:UUID) -> Bool { !Task.isCancelled && request == generation && !suspended && canRead }
    private func read(_ target:WorkflowViewerTarget,request:UUID) async {
        do {
            guard current(request) else { return }
            if let token = target.resource {
                let content = try await store.readOnlyAsset(token)
                guard current(request) else { return }
                try await readContent(content, request: request)
                guard current(request) else { return }
                metadata = content.metadata; loading = false; return
            }
            guard let reference=target.value?.asset else { loading=false;return }
            let snapshot=try await readSnapshot(reference)
            guard current(request) else { return }
            switch reference.kind {
            case .text:
                let result=try await readText(reference);guard current(request) else { return };text=result
            case .image:
                let data=try await store.workflowData(reference);guard current(request) else { return }
                let decoded = try await WorkflowReadOnlyImageDecoder.shared.decode(data)
                guard current(request) else { return }; image = decoded
            case .document:
                let content = try await store.readOnlyAsset(id: reference.assetID, reference: reference)
                guard current(request) else { return }
                try await readContent(content, request: request)
            case .video:
                let (url,_)=try await store.workflowMedia(reference);guard current(request) else { return };mediaURL=url
            case .audio:
                let (url,asset)=try await store.workflowMedia(reference)
                let policy=try await store.workflowAudioPlaybackPolicy(reference);guard current(request) else { return }
                guard let format=asset.metadata.audio?.format else { throw WorkflowIssue("Audio format is unavailable / 音频格式不可访问。") }
                try audio.preparePlayback(url:url,format:format,policy:policy);audioFormat=format
            default:
                let bytes = try await store.workflowData(reference);guard current(request) else { return }
                if [.notes, .chords, .tempo].contains(reference.kind) {
                    let datum = try JSONDecoder().decode(WorkflowDatum.self, from: bytes)
                    try datum.validate(); displayedValue = .data(datum); inspectCompatibility(target.value ?? .data(datum), decodedAsset: datum)
                }
            }
            guard current(request) else { return }
            metadata=snapshot
            if let record=snapshot.record {
                let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
                provenance=String(decoding:try encoder.encode(record),as:UTF8.self)
            }
            loading=false
        } catch {
            guard current(request) else { return }
            text=nil;image=nil;mediaURL=nil;audioFormat=nil;metadata=nil;provenance=nil
            video.stopAndClear();audio.shutdown();failure=error.localizedDescription;loading=false
        }
    }
    private func readContent(_ content: ProjectReadOnlyContent, request: UUID) async throws {
        switch content.token.kind {
        case .text:
            guard let value = content.text else { throw WorkflowIssue("文字不是完整 UTF-8。") }; text = value
        case .image:
            let image = try await WorkflowReadOnlyImageDecoder.shared.decode(content.data)
            guard current(request) else { return }; self.image = image
        case .document:
            let result = try await WorkflowReadOnlyImageDecoder.shared.document(content.data, name: content.metadata.asset.relativePath)
            guard current(request) else { return }; text = result
        case .audio, .video:
            let suffix = content.token.kind == .video ? "mp4" : (content.token.mediaType == "audio/x-caf" ? "caf" : "wav")
            let file = try await WorkflowReadOnlyImageDecoder.shared.media(content.data, suffix: suffix)
            guard current(request) else { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()); return }
            temporaryMedia = file
            if content.token.kind == .video { mediaURL = file }
            else {
                let policy = try await store.readOnlyAudioPolicy(content.token)
                guard current(request) else { return }
                guard let format = content.metadata.asset.metadata.audio?.format else { throw WorkflowIssue("音频规格未登记。") }
                try audio.preparePlayback(url: file, format: format, policy: policy); audioFormat = format
            }
        default:
            // Structured content is represented by its real typed data or readable source.
            if let datum = try? JSONDecoder().decode(WorkflowDatum.self, from: content.data) {
                try datum.validate(); displayedValue = .data(datum)
                concept = WorkflowInputContract.concept(of: datum)
                consumers = WorkflowValueCompatibility.registeredAssetConsumers(content.token.registeredReference, decoded: datum,
                    plans: controller?.runs.compactMap(\.planCheckpoint).map(\.plan) ?? [], tools: controller?.tools ?? [], language: nil)
            } else if let source = String(data: content.data, encoding: .utf8) { text = source }
        }
    }
    private func inspectCompatibility(_ value: WorkflowValue, decodedAsset: WorkflowDatum? = nil) {
        concept = (decodedAsset ?? value.datum).flatMap(WorkflowInputContract.concept)
        let frozen = controller?.runs.compactMap(\.planCheckpoint).map(\.plan) ?? []
        consumers = WorkflowValueCompatibility.concreteConsumers(value, decodedAsset: decodedAsset, plans: frozen, tools: controller?.tools ?? [], language: nil)
            + WorkflowValueCompatibility.consumers(value, decodedAsset: decodedAsset, language: nil)
    }
    func validateMetadata() throws {
        guard ownerIsCurrent,let owner,owner.canEditLibraryMetadata,!suspended else { throw WorkflowIssue("Metadata owner changed / 元数据所有者已改变。") }
    }
    func saveMetadata(_ expected:ProjectAssetEditBaseline,_ name:String?,_ note:String?,_ favorite:Bool?) async throws {
        try validateMetadata()
        let resource = target.resource, ref = target.value?.asset
        guard let assetID = resource?.assetID ?? ref?.assetID, expected.projectID == projectID,
              expected.instanceID == instanceID, expected.assetID == assetID else { throw SharedLibraryError.staleAnnotation }
        let request = generation
        do {
            try await writeAnnotations(expected, name, note, favorite)
            guard current(request) else { return }
            let snapshot: ProjectAssetMetadataSnapshot
            if let resource { snapshot = try await store.readOnlyAsset(resource).metadata }
            else if let ref { snapshot = try await readSnapshot(ref) }
            else { throw SharedLibraryError.staleAnnotation }
            guard current(request) else { return }
            metadata = snapshot
        } catch {
            // The captured editor must retain its draft even after its owner or
            // view generation changes. Suppressing a failed write is not success.
            throw error
        }
    }

    func audioAction(_ action:() throws -> Void) {
        guard canRead,!suspended else { suspend();return }
        do { try action() } catch { failure=error.localizedDescription }
    }
    func stop() {
        generation=UUID();task?.cancel();task=nil;video.stopAndClear();audio.shutdown();loading=false
        if let temporaryMedia { try? FileManager.default.removeItem(at: temporaryMedia.deletingLastPathComponent()); self.temporaryMedia = nil }
    }
    func suspend() { stop();suspended=true }
    func reconcile() {
        if !canRead { suspend();failure="Source project is closed or unavailable / 所属项目已关闭或不可访问。" }
    }
    var exactRecord: WorkflowPlanCallRecord? {
        guard canRead, !suspended, let controller, let call=target.call,
              let run=controller.runs.first(where: { $0.id == call.address.runID }) else { return nil }
        guard let record = WorkflowWorkspacePanels.records(in:run).first(where: { $0.address == call.address && $0.id == call.stepID }) else { return nil }
        if let source = target.runtimeSource { return (try? source.resolve(in: controller.runs)) == target.value ? record : nil }
        if let port = target.port {
            let expected = target.side == .input ? record.step.inputs[port] : record.step.outputs[port]
            guard expected == target.value else { return nil }
        } else if target.side == .materials {
            guard record.step.humanTask.map({ WorkflowValue.data($0.materials) }) == target.value else { return nil }
        } else { return nil }
        return record
    }
}

@MainActor final class WorkflowViewerCoordinator {
    @MainActor private final class Window {
        let session: WorkflowViewerSession
        let panel: WorkbenchChildPanelHandle
        weak var ownerWindow: NSWindow?
        var didClose: (() -> Void)?
        init?(session: WorkflowViewerSession, owner: NSWindow, content: AnyView, preferences: ChatDisplayPreferencesState, language: UILanguageStore?) {
            guard let panel = WorkbenchChildPanelHandle(owner: owner, title: session.target.title, content: content, preferences: preferences, language: language) else { return nil }
            self.session = session; self.panel = panel; ownerWindow = owner
            panel.didClose = { [weak self] in self?.session.stop(); self?.didClose?() }
        }
    }
    var library:SharedLibraryStore?
    private var windows:[UUID:Window]=[:]
    private var primary:UUID?
    static let limit=4
    var count:Int { windows.count }
    func open(_ target:WorkflowViewerTarget,model:WorkbenchModel,language:UILanguageStore?,newWindow:Bool=false,ownerWindow capturedWindow:NSWindow?=nil) throws {
        guard let ownerWindow = capturedWindow ?? NSApp.keyWindow, WorkbenchChildPanels.isOwner(ownerWindow),
              ownerWindow.attachedSheet == nil, NSApp.modalWindow == nil, !(ownerWindow is NSSavePanel) else {
            throw WorkflowIssue("所属窗口不可用；未打开查看器。")
        }
        let owner=model.projectSession
        guard owner.canEditLibraryMetadata,let store=owner.currentStore, let project=owner.manifest?.id,let instance=owner.manifest?.effectiveInstanceID else { throw WorkflowIssue("Source instance unavailable / 所属项目实例不可访问。") }
        reconcile()
        if !newWindow,let primary,let existing=windows[primary],existing.session.owner === owner,existing.ownerWindow === ownerWindow,
           existing.session.store === store,existing.session.canRead,!existing.session.editingAnnotations {
            existing.session.replace(target);existing.panel.setTitle(target.title);existing.panel.orderFront();return
        }
        guard windows.count < Self.limit else { throw WorkflowIssue("Close a viewer before opening another (limit 4) / 请先关闭一个查看窗口，最多同时打开 4 个。") }
        let session=WorkflowViewerSession(owner:owner,store:store,projectID:project,instanceID:instance,target:target)
        session.library=library
        let content=WorkflowViewerContent(session:session,titleChanged: { [weak self, weak session] title in
            if let session { self?.windows[session.id]?.panel.setTitle(title) }
        },reopen:{ [weak self,weak model] in
            guard let self,let model,session.canRead else { return }
            do { try self.open(session.target,model:model,language:language,newWindow:true,ownerWindow:ownerWindow) }
            catch { model.errorMessage=error.localizedDescription }
        }).environment(\.workflowViewerOpenAsset, { [weak self,weak session] ref in
            guard let self,let session,session.canRead,!session.suspended else { return }
            let target=WorkflowViewerTarget(title:session.target.title,subtitle:session.target.subtitle,value:.asset(ref))
            self.navigate(target,in:session)
        }).environment(\.dLanguageStore,language).environment(\.workflowViewerModel,model)
            .environment(\.metadataEditorLifecycle, MetadataEditorLifecycle(begin: { [weak session, weak model] in
                if let model { session?.beginAnnotationEditing(model: model) }
            }, end: { [weak session] in session?.endAnnotationEditing() }))
            .workbenchPresentation(state:model.chatDisplaySettings)
        guard let window=Window(session:session, owner: ownerWindow, content:AnyView(content), preferences: model.chatDisplaySettings, language: language) else { throw WorkflowIssue("所属窗口不可用；未打开查看器。") }
        windows[session.id]=window;if !newWindow { primary=session.id }
        window.didClose={ [weak self] in self?.windows[session.id]=nil;if self?.primary == session.id { self?.primary=nil } }
        session.load()
    }
    func navigate(_ target:WorkflowViewerTarget,in session:WorkflowViewerSession) {
        guard session.canRead,!session.suspended,!session.editingAnnotations else { return }
        session.replace(target)
        windows[session.id]?.panel.setTitle(target.title)
    }
    func suspend() { for window in windows.values { window.session.suspend() } }
    func reconcile() { for window in windows.values { window.session.reconcile() } }
}

private struct WorkflowViewerOpenAssetKey:EnvironmentKey { static var defaultValue:((WorkflowAssetReference)->Void)? { nil } }
private struct WorkflowViewerModelKey: EnvironmentKey { static var defaultValue: WorkbenchModel? { nil } }
extension EnvironmentValues {
    var workflowViewerOpenAsset:((WorkflowAssetReference)->Void)? { get { self[WorkflowViewerOpenAssetKey.self] } set { self[WorkflowViewerOpenAssetKey.self]=newValue } }
    var workflowViewerModel:WorkbenchModel? { get { self[WorkflowViewerModelKey.self] } set { self[WorkflowViewerModelKey.self]=newValue } }
}

@MainActor struct WorkflowViewerContent:View {
    let session:WorkflowViewerSession
    var titleChanged: (String) -> Void = { _ in }
    let reopen:() -> Void
    @Environment(\.dLanguageStore) private var language
    @State private var showInfo=false
    @State private var search=""
    @State private var findNext=0
    @State private var zoom:ArtworkZoom = .fit
    private func text(_ key: String) -> String { workspaceText(language, key) }
    var body:some View {
        VStack(spacing:10) {
            HStack {
                VStack(alignment:.leading) { Text(session.displayTitle(language)).font(.headline).lineLimit(2);Text(session.displaySubtitle(language)).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                Spacer()
                Button(text("newViewer"),systemImage:"rectangle.on.rectangle",action:reopen).workbenchHelp("WORKSPACE-VIEWER-NEW").disabled(!session.canRead || session.suspended)
                Button(text("info"),systemImage:"info.circle") { showInfo.toggle() }.workbenchHelp("WORKSPACE-VIEWER-INFO").disabled(session.editingAnnotations)
            }
            if !session.canRead || session.suspended {
                ContentUnavailableView(text("sourceClosed"),systemImage:"externaldrive.badge.exclamationmark")
                if session.canRead { Button(text("reload")) { session.load() } }
            } else if let error=session.failure { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            else if session.loading { ProgressView(text("loading")) }
            else { content.frame(maxWidth:.infinity,maxHeight:.infinity) }
            if session.exactRecord?.step.status == .waiting {
                Text(text("readonlyGate")).font(.caption).foregroundStyle(.secondary)
            }
            if showInfo {
                WorkbenchScrollView {
                    VStack(alignment:.leading,spacing:8) {
                        Text(session.displaySubtitle(language)).font(.callout)
                        if let metadata=session.metadata {
                            SharedAssetMetadataPanel(snapshot: metadata, library: session.library, validate: {
                                guard session.canRead else { throw SharedLibraryError.staleAnnotation }
                            }, save: { expected, name, note, favorite in
                                try await session.saveMetadata(expected, name, note, favorite)
                            })
                        }
                        if let runtime = session.runtimeAnnotationTarget, let identity = runtime.annotationIdentity, let library = session.library {
                            RuntimeValueMetadataPanel(value: runtime, identity: identity, title: session.displayTitle(language), library: library, validate: {
                                guard session.canRead, let controller = session.controller, runtime.isCurrent(in: controller) else { throw SharedLibraryError.staleAnnotation }
                            })
                        }
                        Text((session.target.value?.asset != nil || session.target.resource != nil) ? text("saved") : text("runValue"))
                        if let concept = session.concept { Text(WorkflowValueCompatibility.conceptTitle(concept, language: language)).font(.headline) }
                        if let record = session.exactRecord {
                            let label = workflowText(language, "workflow.compatibility." + (session.target.side == .input ? "consumer" : session.target.side == .materials ? "materials" : "producer"))
                            Text(label + " · " + (session.controller?.registry.operation(record.step.node.operationID).map { WorkflowCanvasPresentation.operationTitle($0.definition, language: language) } ?? record.step.node.title)).font(.callout)
                        } else if let operation = session.metadata?.record?.operationID {
                            Text(workflowText(language, "workflow.compatibility.registeredProducer") + " · " + (WorkflowRegistry.standard.operation(operation).map { WorkflowCanvasPresentation.operationTitle($0.definition, language: language) } ?? operation)).font(.callout)
                        }
                        DisclosureGroup(text("receivers")) {
                            ForEach(session.consumers) { match in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(match.displayTitle(language) + " · " + match.displayPort(language)).font(.callout)
                                    Text(workflowText(language, "workflow.compatibility.status." + match.result.status.rawValue)).font(.caption.weight(.semibold))
                                    if match.result.reasonCode != "diagnostic" { Text(workflowText(language, "workflow.compatibility.reason." + match.result.reasonCode)).font(.caption) }
                                    else { Text(match.result.reason).font(.caption).textSelection(.enabled) }
                                    if let kind = match.modelKind {
                                        let choices = session.controller?.modelChoices.filter { $0.kind == kind && (WorkflowModelRoutes.operation(for: $0) ?? (kind == .music ? "d.music.generate" : kind == .image ? "d.image.generate" : kind == .text ? "d.model.language" : "")) == match.operationID } ?? []
                                        Text(choices.isEmpty ? workflowText(language, "workflow.compatibility.notInstalled") : workflowText(language, "workflow.compatibility.registeredModels", arguments: ["models": choices.map(\.displayName).joined(separator: " · ")])).font(.caption)
                                    }
                                }
                            }
                            if session.consumers.isEmpty { Text(workflowText(language, "workflow.compatibility." + (session.target.resource?.registeredReference == nil && session.target.resource != nil ? "unregisteredAsset" : "noReceivers"))).font(.caption) }
                        }
                        if let record=session.exactRecord {
                            Text(text("frozenConfig")).font(.headline)
                            ForEach(record.step.node.parameters.keys.sorted(),id:\.self) { key in
                                HStack(alignment:.top) {
                                    Text(session.controller?.registry.definition(for:record.step.node,tools:session.controller?.tools ?? [])?.fields.first { $0.id == key }.map { WorkflowCanvasPresentation.fieldTitle(operationID:record.step.node.operationID,field:$0,language:language) } ?? key)
                                    Spacer()
                                    if key == "modelID" {
                                        Text(session.controller?.modelChoices.first { $0.id == record.step.node.parameters[key]?.string }?.displayName ?? text("modelNameUnrecorded"))
                                            .textSelection(.enabled)
                                    } else { Text(scalarText(record.step.node.parameters[key]!)).textSelection(.enabled) }
                                }.font(.caption)
                            }
                            Text(text("frozenInputs")).font(.caption)
                            WorkflowTechnicalDetails(value:String(describing:record.step.node.parameters)+"\n"+String(describing:record.step.inputs))
                        }
                        if let provenance=session.provenance { WorkflowTechnicalDetails(value:provenance) }
                        WorkflowTechnicalDetails(value:String(describing:session.target.value) + "\n" + String(describing:session.target.call))
                    }.frame(maxWidth:.infinity,alignment:.leading)
                        .disabled((!session.canRead || session.suspended) && !session.editingAnnotations)
                }.frame(maxHeight:210)
            }
        }.padding(16).frame(minWidth:480,minHeight:360)
            .onChange(of: session.displayTitle(language), initial: true) { _, title in titleChanged(title) }
            .onChange(of:session.generation) { _,_ in search="";zoom = .fit }
            .onChange(of:session.canRead) { _,_ in session.reconcile() }
    }
    @ViewBuilder private var content:some View {
        if let image=session.image {
            WorkbenchGlassSegments(title:text("imageZoom"),selection:$zoom,choices:[(.fit,text("fit")),(.actual,"1:1"),(.double,"200%"),(.quadruple,"400%")],owner:AnyHashable(session.generation))
            PixelCanvas(image:image,zoom:zoom)
        } else if let value=session.text { textContent(value) }
        else if let url=session.mediaURL { VideoPreview(url:url,identity:session.generation,session:session.video) }
        else if let format=session.audioFormat {
            VStack {
                HStack {
                    Button(text("play"),systemImage:"play.fill") { session.audioAction { try session.audio.play() } }
                    Button(text("pause"),systemImage:"pause.fill") { session.audio.pause() }
                    Text(String(format:"%.1f / %.1f s",Double(session.audio.positionFrame)/format.sampleRate,Double(format.frameCount)/format.sampleRate)).monospacedDigit()
                }
                Slider(value:Binding(get:{Double(session.audio.positionFrame)},set:{ value in session.audioAction { try session.audio.seek(toFrame:Int64(value)) } }),in:0...Double(max(1,format.frameCount-1)))
                    .accessibilityLabel(text("seek"))
                if let error=session.audio.errorMessage { Text(error).foregroundStyle(.red) }
            }
        } else {
            switch session.displayedValue {
            case .data(.text(let value)): textContent(value)
            case .data(let value): WorkbenchScrollView { WorkflowDatumSnapshotView(value:value) }
            case .receipt(let receipt): WorkbenchScrollView { Text(receipt.names.joined(separator:"\n")).textSelection(.enabled) }
            case .collection(let values):
                if let controller=session.controller {
                    WorkbenchScrollView { ForEach(values) { WorkflowCandidatePreview(controller:controller,candidate:$0,selected:false,onSelect:nil) } }
                }
            case .asset, nil: Text(text("unsupportedViewer"))
            }
        }
    }
    private func scalarText(_ value:WorkflowScalar)->String {
        switch value { case .text(let value):value;case .integer(let value):String(value);case .decimal(let value):String(value);case .flag(let value):value ? text("yes"):text("no") }
    }
    private func textContent(_ value:String)->some View {
        VStack {
            HStack {
                TextField(text("find"),text:$search).workbenchInputSurface().onSubmit { findNext += 1 }
                Button(text("findNext")) { findNext += 1 }.disabled(search.isEmpty)
            }
            WorkflowViewerText(text:value,query:search,next:findNext)
        }
    }
}

/// Read-only native text, with native selection/copy/find and stable reading offset.
struct WorkflowViewerText:NSViewRepresentable {
    let text:String
    let query:String
    let next:Int
    @Environment(\.chatDisplayPreferences) private var preferences
    @Environment(\.colorScheme) private var scheme
    final class Coordinator { var query="";var next=0;var last=NSRange(location:0,length:0) }
    func makeCoordinator()->Coordinator { Coordinator() }
    func makeNSView(context:Context)->NSScrollView {
        let view=NSTextView();view.isEditable=false;view.isSelectable=true;view.isRichText=false;view.usesFindBar=true
        view.font = .preferredFont(forTextStyle:.body);view.isVerticallyResizable=true;view.isHorizontallyResizable=false
        view.autoresizingMask=[.width];view.textContainer?.widthTracksTextView=true;view.textContainerInset=CGSize(width:12,height:12)
        let scroll=NSScrollView();scroll.hasVerticalScroller=true;scroll.autohidesScrollers=true;scroll.documentView=view
        return scroll
    }
    func updateNSView(_ scroll:NSScrollView,context:Context) {
        guard let view=scroll.documentView as? NSTextView else { return }
        WorkbenchNativeTextAppearance.apply(scroll,editor:view,color:NSColor(preferences.resolvedAppearance.palette(for:scheme).foregroundColor))
        if !view.string.utf8.elementsEqual(text.utf8) { view.string=text;context.coordinator.last=NSRange(location:0,length:0) }
        guard context.coordinator.query != query || context.coordinator.next != next else { return }
        let changed=context.coordinator.query != query
        context.coordinator.query=query;context.coordinator.next=next
        guard !query.isEmpty else { return }
        let native=text as NSString, start=changed ? 0:min(native.length,NSMaxRange(context.coordinator.last))
        var found=native.range(of:query,options:[.caseInsensitive,.diacriticInsensitive],range:NSRange(location:start,length:native.length-start))
        if found.location == NSNotFound { found=native.range(of:query,options:[.caseInsensitive,.diacriticInsensitive]) }
        if found.location != NSNotFound { context.coordinator.last=found;view.setSelectedRange(found);view.scrollRangeToVisible(found) }
    }
    func sizeThatFits(_ proposal:ProposedViewSize,nsView:NSScrollView,context:Context)->CGSize? { .init(width:proposal.width ?? 400,height:proposal.height ?? 300) }
}

private actor WorkflowReadOnlyImageDecoder {
    static let shared = WorkflowReadOnlyImageDecoder()
    func document(_ data: Data, name: String) async throws -> String {
        try Task.checkCancellation()
        return try await DocumentTextExtractor.extract(data: data, fileName: name, ocr: false).text
    }
    func media(_ data: Data, suffix: String) throws -> URL {
        try Task.checkCancellation()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("D-Viewer-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let file = directory.appendingPathComponent("preview." + suffix)
        do {
            try data.write(to: file, options: .withoutOverwriting)
            try Task.checkCancellation(); return file
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
    func decode(_ data: Data) throws -> CGImage {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw WorkflowIssue("图像无法解码。") }
        return image
    }
}
