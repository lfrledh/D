import AppKit
import AVKit
import ImageIO
import DWorkbench
import Observation
import SwiftUI

struct WorkflowViewerTarget {
    let title: String
    let subtitle: String
    let value: WorkflowValue
    var call: WorkflowCallReference? = nil
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
    private(set) var provenance: String?
    private(set) var failure: String?
    private(set) var loading = false
    private(set) var suspended = false
    let video = VideoPreview.Session()
    let audio = AudioTransport(recordingEnabled:false)
    var library:SharedLibraryStore?
    @ObservationIgnored private var task: Task<Void,Never>?
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
    var canRead: Bool {
        ownerIsCurrent && owner?.canEditLibraryMetadata == true
    }
    func replace(_ target:WorkflowViewerTarget) {
        stop();self.target=target;load()
    }
    @discardableResult func load() -> Task<Void,Never>? {
        guard canRead else { suspend();return nil }
        stop(); suspended=false;loading=true;text=nil;image=nil;mediaURL=nil;audioFormat=nil;metadata=nil;provenance=nil;failure=nil
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
            guard let reference=target.value.asset else { loading=false;return }
            let snapshot=try await readSnapshot(reference)
            guard current(request) else { return }
            switch reference.kind {
            case .text:
                let result=try await readText(reference);guard current(request) else { return };text=result
            case .image:
                let data=try await store.workflowData(reference);guard current(request) else { return }
                guard let source=CGImageSourceCreateWithData(data as CFData,nil), let decoded=CGImageSourceCreateImageAtIndex(source,0,nil) else { throw WorkflowIssue("Image cannot be decoded / 图像无法解码。") }
                image=decoded
            case .video:
                let (url,_)=try await store.workflowMedia(reference);guard current(request) else { return };mediaURL=url
            case .audio:
                let (url,asset)=try await store.workflowMedia(reference)
                let policy=try await store.workflowAudioPlaybackPolicy(reference);guard current(request) else { return }
                guard let format=asset.metadata.audio?.format else { throw WorkflowIssue("Audio format is unavailable / 音频格式不可访问。") }
                try audio.preparePlayback(url:url,format:format,policy:policy);audioFormat=format
            default:
                _ = try await store.workflowData(reference);guard current(request) else { return }
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
    func validateMetadata() throws {
        guard ownerIsCurrent,let owner,owner.canEditLibraryMetadata,!suspended else { throw WorkflowIssue("Metadata owner changed / 元数据所有者已改变。") }
    }
    func saveMetadata(_ expected:ProjectAssetEditBaseline,_ name:String?,_ note:String?,_ favorite:Bool?) async throws {
        try validateMetadata()
        guard let ref=target.value.asset, expected.projectID == projectID,
              expected.instanceID == instanceID,expected.assetID == ref.assetID else {
            throw WorkflowIssue("Metadata target changed / 元数据目标已改变。")
        }
        let request=generation
        do {
            try await writeAnnotations(expected,name,note,favorite)
            // A completed save belongs to its original asset. Reusing the
            // window must not publish its metadata or error into a new target.
            guard current(request),target.value.asset == ref else { return }
            let snapshot=try await readSnapshot(ref)
            guard current(request),target.value.asset == ref else { return }
            metadata=snapshot
        } catch {
            guard current(request),target.value.asset == ref else { return }
            throw error
        }
    }
    func audioAction(_ action:() throws -> Void) {
        guard canRead,!suspended else { suspend();return }
        do { try action() } catch { failure=error.localizedDescription }
    }
    func stop() {
        generation=UUID();task?.cancel();task=nil;video.stopAndClear();audio.shutdown();loading=false
    }
    func suspend() { stop();suspended=true }
    func reconcile() {
        if !canRead { suspend();failure="Source project is closed or unavailable / 所属项目已关闭或不可访问。" }
    }
    var exactRecord: WorkflowPlanCallRecord? {
        guard canRead, !suspended, let controller, let call=target.call,
              let run=controller.runs.first(where: { $0.id == call.address.runID }) else { return nil }
        return WorkflowWorkspacePanels.records(in:run).first { $0.address == call.address && $0.id == call.stepID }
    }
}

@MainActor final class WorkflowViewerCoordinator {
    @MainActor private final class Window: NSObject, NSWindowDelegate {
        let session:WorkflowViewerSession
        let window:NSWindow
        var didClose:(() -> Void)?
        init(session:WorkflowViewerSession,content:AnyView) {
            self.session=session
            window=NSWindow(contentRect:CGRect(x:0,y:0,width:800,height:640),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
            super.init();window.isReleasedWhenClosed=false;window.delegate=self
            window.contentMinSize=CGSize(width:480,height:360);window.contentView=NSHostingView(rootView:content)
            window.title=session.target.title;window.center()
        }
        func windowWillClose(_ notification:Notification) { session.stop();window.contentView=nil;didClose?() }
    }
    var library:SharedLibraryStore?
    private var windows:[UUID:Window]=[:]
    private var primary:UUID?
    static let limit=4
    var count:Int { windows.count }
    func open(_ target:WorkflowViewerTarget,model:WorkbenchModel,language:UILanguageStore?,newWindow:Bool=false) throws {
        let owner=model.projectSession
        guard owner.canEditLibraryMetadata,let store=owner.currentStore, let project=owner.manifest?.id,let instance=owner.manifest?.effectiveInstanceID else { throw WorkflowIssue("Source instance unavailable / 所属项目实例不可访问。") }
        reconcile()
        if !newWindow,let primary,let existing=windows[primary],existing.session.owner === owner,
           existing.session.store === store,existing.session.canRead {
            existing.session.replace(target);existing.window.title=target.title;existing.window.makeKeyAndOrderFront(nil);return
        }
        guard windows.count < Self.limit else { throw WorkflowIssue("Close a viewer before opening another (limit 4) / 请先关闭一个查看窗口，最多同时打开 4 个。") }
        let session=WorkflowViewerSession(owner:owner,store:store,projectID:project,instanceID:instance,target:target)
        session.library=library
        let content=WorkflowViewerContent(session:session,reopen:{ [weak self,weak model] in
            guard let self,let model,session.canRead else { return }
            do { try self.open(session.target,model:model,language:language,newWindow:true) }
            catch { model.errorMessage=error.localizedDescription }
        }).environment(\.workflowViewerOpenAsset, { [weak self,weak model,weak session] ref in
            guard let self,let model,let session,session.canRead,!session.suspended else { return }
            let target=WorkflowViewerTarget(title:session.target.title,subtitle:session.target.subtitle,value:.asset(ref),call:session.target.call)
            do { try self.open(target,model:model,language:language) } catch { model.errorMessage=error.localizedDescription }
        }).environment(\.dLanguageStore,language).environment(\.workflowViewerModel,model)
            .workbenchPresentation(state:model.chatDisplaySettings)
        let window=Window(session:session,content:AnyView(content))
        windows[session.id]=window;if !newWindow { primary=session.id }
        window.didClose={ [weak self] in self?.windows[session.id]=nil;if self?.primary == session.id { self?.primary=nil } }
        session.load();window.window.makeKeyAndOrderFront(nil)
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
    let reopen:() -> Void
    @Environment(\.dLanguageStore) private var language
    @State private var showInfo=false
    @State private var search=""
    @State private var findNext=0
    @State private var zoom:ArtworkZoom = .fit
    private func text(_ key:String,_ zh:String,_ en:String)->String { workspaceText(language,key,zh,en) }
    var body:some View {
        VStack(spacing:10) {
            HStack {
                VStack(alignment:.leading) { Text(session.target.title).font(.headline).lineLimit(2);Text(session.target.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                Spacer()
                Button(text("newViewer","新窗口查看","Open another window"),systemImage:"rectangle.on.rectangle",action:reopen).workbenchHelp("WORKSPACE-VIEWER-NEW").disabled(!session.canRead || session.suspended)
                Button(text("info","信息","Information"),systemImage:"info.circle") { showInfo.toggle() }.workbenchHelp("WORKSPACE-VIEWER-INFO")
            }
            if !session.canRead || session.suspended {
                ContentUnavailableView(text("sourceClosed","来源暂不可访问","Source unavailable"),systemImage:"externaldrive.badge.exclamationmark")
                if session.canRead { Button(text("reload","重新读取固定内容","Reload fixed content")) { session.load() } }
            } else if let error=session.failure { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            else if session.loading { ProgressView(text("loading","正在读取固定内容…","Reading fixed content…")) }
            else { content.frame(maxWidth:.infinity,maxHeight:.infinity) }
            if session.canRead, !session.suspended, let record=session.exactRecord,let controller=session.controller {
                if record.step.status == .waiting {
                    WorkbenchScrollView {
                        if let task=record.step.humanTask {
                            WorkflowHumanTaskForm(task:task,onSaveDraft:{ controller.editHumanDraft(stepID:record.id,value:$0) },
                                onSubmit:{ value in Task { await controller.decideHuman(stepID:record.id,value:value,expectedTask:task) } },
                                onReject:{ Task { await controller.decideHuman(stepID:record.id,value:nil,reject:true,expectedTask:task) } })
                        } else { WorkflowWaitingDecision(controller:controller,step:record.step,readOnly:controller.readOnlyReason != nil,preview:controller.preview) }
                    }.frame(maxHeight:260).disabled(controller.isRunning || controller.readOnlyReason != nil)
                }
            }
            if showInfo {
                WorkbenchScrollView {
                    VStack(alignment:.leading,spacing:8) {
                        Text(session.target.subtitle).font(.callout)
                        if let metadata=session.metadata { SharedAssetMetadataPanel(snapshot:metadata,library:session.library,validate:session.validateMetadata,save:session.saveMetadata) }
                        Text(session.target.value.asset != nil ? text("saved","已保存资产","Saved asset") : text("runValue","运行内数据","Run value"))
                        if let record=session.exactRecord {
                            Text(text("frozenConfig","此调用的固定配置","Frozen configuration of this call")).font(.headline)
                            ForEach(record.step.node.parameters.keys.sorted(),id:\.self) { key in
                                HStack(alignment:.top) {
                                    Text(session.controller?.registry.definition(for:record.step.node,tools:session.controller?.tools ?? [])?.fields.first { $0.id == key }.map { WorkflowCanvasPresentation.fieldTitle(operationID:record.step.node.operationID,field:$0,language:language) } ?? key)
                                    Spacer()
                                    if key == "modelID" {
                                        Text(session.controller?.modelChoices.first { $0.id == record.step.node.parameters[key]?.string }?.displayName ?? text("modelNameUnrecorded","模型名称未记录","Model name not recorded"))
                                            .textSelection(.enabled)
                                    } else { Text(scalarText(record.step.node.parameters[key]!)).textSelection(.enabled) }
                                }.font(.caption)
                            }
                            Text(text("frozenInputs","输入绑定保存在技术详情中；不会改用当前节点配置。","Input bindings are retained in technical details; current node settings are never substituted.")).font(.caption)
                            WorkflowTechnicalDetails(value:String(describing:record.step.node.parameters)+"\n"+String(describing:record.step.inputs))
                        }
                        if let provenance=session.provenance { WorkflowTechnicalDetails(value:provenance) }
                        WorkflowTechnicalDetails(value:String(describing:session.target.value) + "\n" + String(describing:session.target.call))
                    }.frame(maxWidth:.infinity,alignment:.leading)
                }.frame(maxHeight:210)
            }
        }.padding(16).frame(minWidth:480,minHeight:360)
            .onChange(of:session.generation) { _,_ in search="";zoom = .fit }
            .onChange(of:session.canRead) { _,_ in session.reconcile() }
    }
    @ViewBuilder private var content:some View {
        if let image=session.image {
            WorkbenchGlassSegments(title:text("imageZoom","图像比例","Image scale"),selection:$zoom,choices:[(.fit,text("fit","适合窗口","Fit")),(.actual,"1:1"),(.double,"200%"),(.quadruple,"400%")])
            PixelCanvas(image:image,zoom:zoom)
        } else if let value=session.text { textContent(value) }
        else if let url=session.mediaURL { VideoPreview(url:url,identity:session.generation,session:session.video) }
        else if let format=session.audioFormat {
            VStack {
                HStack {
                    Button(text("play","播放","Play"),systemImage:"play.fill") { session.audioAction { try session.audio.play() } }
                    Button(text("pause","暂停","Pause"),systemImage:"pause.fill") { session.audio.pause() }
                    Text(String(format:"%.1f / %.1f s",Double(session.audio.positionFrame)/format.sampleRate,Double(format.frameCount)/format.sampleRate)).monospacedDigit()
                }
                Slider(value:Binding(get:{Double(session.audio.positionFrame)},set:{ value in session.audioAction { try session.audio.seek(toFrame:Int64(value)) } }),in:0...Double(max(1,format.frameCount-1)))
                    .accessibilityLabel(text("seek","播放位置","Playback position"))
                if let error=session.audio.errorMessage { Text(error).foregroundStyle(.red) }
            }
        } else {
            switch session.target.value {
            case .data(.text(let value)): textContent(value)
            case .data(let value): WorkbenchScrollView { WorkflowDatumSnapshotView(value:value) }
            case .receipt(let receipt): WorkbenchScrollView { Text(receipt.names.joined(separator:"\n")).textSelection(.enabled) }
            case .collection(let values):
                if let controller=session.controller {
                    WorkbenchScrollView { ForEach(values) { WorkflowCandidatePreview(controller:controller,candidate:$0,selected:false,onSelect:nil) } }
                }
            case .asset: Text(text("unsupportedViewer","原件已保留，此类型暂无可视预览。","Original preserved; no visual preview for this type."))
            }
        }
    }
    private func scalarText(_ value:WorkflowScalar)->String {
        switch value { case .text(let value):value;case .integer(let value):String(value);case .decimal(let value):String(value);case .flag(let value):value ? text("yes","是","Yes"):text("no","否","No") }
    }
    private func textContent(_ value:String)->some View {
        VStack {
            HStack {
                TextField(text("find","查找文本","Find text"),text:$search).workbenchInputSurface().onSubmit { findNext += 1 }
                Button(text("findNext","下一个","Next")) { findNext += 1 }.disabled(search.isEmpty)
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
