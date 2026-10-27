import AppKit
import DWorkbench
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// One owner for SwiftUI library drags. AppKit's ordinary hit test may identify a
/// port while NSHostingView still receives the system drop; use the same rendered
/// port centers and plates here, before treating a drop as blank canvas.
enum WorkflowLibraryDropTarget: Equatable {
    case canvas, blocked, port(WorkflowPortIdentity)

    static func hit(_ point: CGPoint, graph: WorkflowGraph, geometry: WorkflowGraphGeometry,
                    centers: [WorkflowPortIdentity: CGPoint], sizes: [UUID: CGSize]) -> Self {
        WorkflowLibraryDropHitMap(graph: graph, geometry: geometry, centers: centers, sizes: sizes).hit(point)
    }
}

/// Created once on drag entry; mouse updates do not rebuild all node geometry.
struct WorkflowLibraryDropHitMap {
    let entries: [(plate: CGPath?, ports: [(WorkflowPortIdentity, CGPoint)], halfHeight: CGFloat)]
    init(graph: WorkflowGraph, geometry: WorkflowGraphGeometry, centers: [WorkflowPortIdentity: CGPoint], sizes: [UUID: CGSize]) {
        let frames = WorkflowConnectionGeometry.nodeFrames(geometry: geometry, sizes: sizes)
        let grouped = Dictionary(grouping: centers.map { ($0.key, $0.value) }, by: { $0.0.nodeID })
        let heights = Dictionary(uniqueKeysWithValues: graph.layout.map { ($0.nodeID, WorkflowNodePortLayout.hitHeight(collapsed: $0.collapsed) / 2) })
        entries = graph.nodes.reversed().map { node in
            (frames[node.id].map { WorkflowConnectionGeometry.nodePlate($0).cgPath }, grouped[node.id] ?? [], heights[node.id] ?? 11)
        }
    }
    func hit(_ point: CGPoint) -> WorkflowLibraryDropTarget {
        for entry in entries {
            for (port, center) in entry.ports {
                if pow((point.x - center.x) / 11, 2) + pow((point.y - center.y) / entry.halfHeight, 2) <= 1 { return .port(port) }
            }
            if entry.plate?.contains(point) == true { return .blocked }
        }
        return .canvas
    }
}

enum WorkflowLibraryDropAdmission: Equatable {
    case ready, checking, blocked(String)
    var permitsDrop: Bool { if case .blocked = self { false } else { true } }
    var key: String {
        switch self { case .ready: "container.dropConnect"; case .checking: "container.dropChecking"; case .blocked(let key): key }
    }
}

@MainActor enum WorkflowLibraryPortDrop {
    /// Read-only preview: never registers originals, reads files, mutates a graph or runs a model.
    static func admission(_ value: WorkflowCanvasTransfer?, port: WorkflowPortIdentity,
                          scope: WorkflowCanvasScope, controller: WorkflowController) -> WorkflowLibraryDropAdmission {
        guard port.input, scope.isCurrent(in: controller), controller.canEditCanvas,
              let graph = controller.graph, let node = graph.nodes.first(where: { $0.id == port.nodeID }) else { return .blocked("container.dropTarget") }
        guard !graph.connections.contains(where: { $0.targetNode == port.nodeID && $0.targetPort == port.port }) else { return .blocked("container.dropOccupied") }
        guard let value else { return .checking }
        guard let payload = value.libraryPayload, payload.owner == controller.assetLibraryOwner, payload.items.count == 1 else { return .blocked("container.dropTarget") }
        do {
            let contract = try WorkflowInputContract(step: .init(node: node, inputs: []), portID: port.port, tools: controller.tools, registry: controller.registry)
            let source: WorkflowLibrarySource
            switch payload.items[0] {
            case .source(let captured): source = captured
            case .original(let token):
                guard token.projectID == payload.owner.projectID, token.instanceID == payload.owner.instanceID,
                      contract.port.kinds.contains(token.kind) else { return .blocked("container.dropIncompatible") }
                // A read token is not a fabricated published reference. Verify/pin only on release.
                guard let reference = token.registeredReference, reference.sha256 == token.sha256 else { return .checking }
                source = .asset(reference)
            }
            let values = try WorkflowAssetContainer.sourceValues([source], runs: controller.runs)
            guard let output = values.first else { return .blocked("container.dropTarget") }
            switch contract.compatibility(with: output).status {
            case .direct: return .ready
            case .unverified: return .checking
            case .conversion, .incompatible: return .blocked("container.dropIncompatible")
            }
        } catch { return .blocked("container.stale") }
    }

    static func submit(_ value: WorkflowCanvasTransfer, port: WorkflowPortIdentity,
                       scope: WorkflowCanvasScope, controller: WorkflowController, language: UILanguageStore?,
                       onIssue: @escaping @MainActor (String) -> Void = { _ in }) -> Bool {
        guard let payload = value.libraryPayload else { return false }
        let admission = admission(value, port: port, scope: scope, controller: controller)
        guard admission.permitsDrop, let target = controller.canvasInsertionTarget() else {
            let message = workflowText(language, admission.key)
            controller.errorMessage = message; onIssue(message); return true
        }
        let origin = controller.graph?.layout.first { $0.nodeID == port.nodeID }
        Task {
            do {
                let sources = try await controller.resolveLibraryDrop(payload.items, owner: payload.owner, target: target)
                try await controller.insertLibrarySources(sources, owner: payload.owner, target: target,
                    x: (origin?.x ?? 100) - 420, y: origin?.y ?? 100, inputNode: port.nodeID, inputPort: port.port)
            } catch { controller.errorMessage = error.localizedDescription; onIssue(error.localizedDescription) }
        }
        return true
    }
}

/// Capacity one, owned by this graph surface. Exit, release, scope changes and
/// disappearance invalidate late callbacks. Do not cancel a provider's shared
/// source capture: leaving hover must not poison a later drop. No disk work on hover.
@Observable @MainActor final class WorkflowLibraryDropPreview {
    private(set) var value: WorkflowCanvasTransfer?
    private(set) var location: CGPoint?
    private(set) var feedback: WorkflowLibraryDropAdmission?
    private var cachedTarget: WorkflowLibraryDropTarget?
    private var hit: ((CGPoint) -> WorkflowLibraryDropTarget)?
    private var assess: ((WorkflowCanvasTransfer?, WorkflowPortIdentity) -> WorkflowLibraryDropAdmission)?
    private var identity: UUID?
    private var progress: Progress?
    private var activeScope: WorkflowCanvasScope?
    private var isCanvasItem = false
    func begin(_ provider: NSItemProvider?, scope: WorkflowCanvasScope, hit: @escaping (CGPoint) -> WorkflowLibraryDropTarget,
               assess: @escaping (WorkflowCanvasTransfer?, WorkflowPortIdentity) -> WorkflowLibraryDropAdmission) {
        clear(); activeScope = scope; self.hit = hit; self.assess = assess
        isCanvasItem = provider?.hasItemConformingToTypeIdentifier(UTType.workflowCanvasItem.identifier) == true
        guard let provider, isCanvasItem else { return }
        let id = UUID(); identity = id
        progress = provider.loadDataRepresentation(forTypeIdentifier: UTType.workflowCanvasItem.identifier) { [weak self] bytes, _ in
            let decoded = bytes.flatMap { try? WorkflowCanvasTransfer.decode($0) }
            Task { @MainActor [weak self] in
                guard let self, self.identity == id else { return }
                self.value = decoded; self.progress = nil; self.cachedTarget = nil
                if let point = self.location { self.move(to: point) }
            }
        }
    }
    func move(to point: CGPoint) {
        guard activeScope != nil else { return }
        location = point
        let target = hit?(point)
        guard target != cachedTarget else { return }
        cachedTarget = target
        if !isCanvasItem { feedback = target == .canvas ? nil : .blocked("container.dropTarget") }
        else if let value, value.libraryPayload == nil { feedback = nil }
        else if case .port(let port) = target { feedback = assess?(value, port) }
        else { feedback = nil }
    }
    func consume(scope: WorkflowCanvasScope) -> Bool {
        guard activeScope == scope else { return false }
        clear(); return true
    }
    func clear() {
        identity = nil; activeScope = nil; isCanvasItem = false; progress = nil; value = nil; location = nil
        feedback = nil; cachedTarget = nil; hit = nil; assess = nil
    }
}

@MainActor struct WorkflowLibrarySurfaceDrop: DropDelegate {
    let preview: WorkflowLibraryDropPreview
    let scope: WorkflowCanvasScope
    let makeHit: () -> (CGPoint) -> WorkflowLibraryDropTarget
    let assess: (WorkflowCanvasTransfer?, WorkflowPortIdentity) -> WorkflowLibraryDropAdmission
    let perform: ([NSItemProvider], CGPoint) -> Bool
    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.workflowCanvasItem, .fileURL]) }
    func dropEntered(info: DropInfo) {
        preview.begin(info.itemProviders(for: [.workflowCanvasItem]).first, scope: scope, hit: makeHit(), assess: assess)
        preview.move(to: info.location)
    }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        preview.move(to: info.location)
        // Rejections are consumed at release so they never bubble into a blank-canvas insertion.
        return DropProposal(operation: .copy)
    }
    func dropExited(info: DropInfo) { preview.clear() }
    func performDrop(info: DropInfo) -> Bool {
        guard preview.consume(scope: scope) else { return false }
        return perform(info.itemProviders(for: [.workflowCanvasItem, .fileURL]), info.location)
    }
}

/// Observe mouse movement here, not in the graph/card layout body.
struct WorkflowLibraryDropFeedback: View {
    let preview: WorkflowLibraryDropPreview
    @Environment(\.dLanguageStore) private var language
    var body: some View {
        if let point = preview.location, let admission = preview.feedback {
            Text(workflowText(language, admission.key)).font(.caption)
                .padding(6).workbenchPanel(cornerRadius: 6)
                .foregroundStyle(admission.permitsDrop ? Color.primary : .red)
                .fixedSize().offset(x: point.x + 16, y: point.y - 32)
                .allowsHitTesting(false).accessibilityIdentifier("workflow-asset-drop-feedback")
        }
    }
}

/// Presentation only; the controller retains the original error/diagnostic. A late
/// failure from another graph must not become a banner in the newly selected one.
struct WorkflowLibraryDropIssue: Equatable {
    let scope: WorkflowCanvasScope
    let message: String
    func isVisible(in current: WorkflowCanvasScope) -> Bool { scope.identity == current.identity }
}

/// Capacity one, scoped to a graph surface and one drag attempt, including async completion.
@Observable @MainActor final class WorkflowLibraryDropIssues {
    private(set) var issue: WorkflowLibraryDropIssue?
    private var token: UUID?
    private var scope: WorkflowCanvasScopeIdentity?
    @discardableResult func begin(scope: WorkflowCanvasScope) -> UUID {
        let next = UUID(); token = next; self.scope = scope.identity; issue = nil; return next
    }
    func token(for scope: WorkflowCanvasScope) -> UUID? { self.scope == scope.identity ? token : nil }
    func report(_ message: String, scope: WorkflowCanvasScope, token: UUID) {
        guard self.token == token, self.scope == scope.identity else { return }
        issue = .init(scope: scope, message: message)
    }
    func clear() { token = nil; scope = nil; issue = nil }
}

struct WorkflowLibraryDropIssueView: View {
    let message: String
    let dismiss: () -> Void
    @Environment(\.dLanguageStore) private var language
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            Button(workflowText(language, "workflow.action.close"), systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly).buttonStyle(WorkbenchGlassButtonStyle(compact: true))
        }.font(.caption).padding(10).frame(maxWidth: 420)
            .workbenchPanel(cornerRadius: 10).padding(.horizontal, 20).padding(.bottom, 72)
            .accessibilityIdentifier("workflow-asset-drop-issue")
    }
}
