import AppKit
import SwiftUI

/// Appearance-only preferences. Never serialized into a project or a run.
struct WorkbenchReadabilitySettings: Codable, Equatable {
    var enabled = false
    var amount = 0.35
    var isValid: Bool { amount.isFinite && (0...1).contains(amount) }
}

enum WorkbenchSurfaceRole: String { case panel, node, control, popup, scrollEdge }
private struct WorkbenchSurfaceGroupKey: EnvironmentKey { static let defaultValue: String? = nil }
private struct WorkbenchSurfaceRoleKey: EnvironmentKey { static let defaultValue = WorkbenchSurfaceRole.panel }
extension EnvironmentValues {
    var workbenchSurfaceGroup: String? {
        get { self[WorkbenchSurfaceGroupKey.self] }
        set { self[WorkbenchSurfaceGroupKey.self] = newValue }
    }
    var workbenchSurfaceRole: WorkbenchSurfaceRole {
        get { self[WorkbenchSurfaceRoleKey.self] }
        set { self[WorkbenchSurfaceRoleKey.self] = newValue }
    }
}
extension View {
    func workbenchSurface(_ role: WorkbenchSurfaceRole, group: String? = nil) -> some View {
        modifier(WorkbenchSurfaceModifier(role: role, group: group))
    }
}

private struct WorkbenchSurfaceModifier: ViewModifier {
    let role: WorkbenchSurfaceRole
    let group: String?
    @Environment(\.workbenchSurfaceGroup) private var inherited
    func body(content: Content) -> some View {
        content.environment(\.workbenchSurfaceRole, role).environment(\.workbenchSurfaceGroup, group ?? inherited)
    }
}
/// Records only a scroll body's geometry; it never reads or paints its content.
struct WorkbenchScrollGeometry: NSViewRepresentable {
    @Environment(\.workbenchBackground) private var owner
    @Environment(\.workbenchSurfaceGroup) private var group
    func makeNSView(context: Context) -> WorkbenchBackgroundNSView {
        let view = WorkbenchBackgroundNSView(); view.isGeometryOnly = true; view.setAccessibilityElement(false); return view
    }
    func updateNSView(_ view: WorkbenchBackgroundNSView, context: Context) {
        if view.owner !== owner { view.owner?.readability.remove(view) }
        view.owner = owner; view.surfaceGroup = group; view.surfaceRole = .panel
        owner?.readability.update(view)
    }
    static func dismantleNSView(_ view: WorkbenchBackgroundNSView, coordinator: ()) { view.owner?.readability.remove(view); view.owner = nil }
}
struct WorkbenchScrollView<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View { ScrollView { content().background(WorkbenchScrollGeometry().allowsHitTesting(false)) } }
}

/// A small immutable summary of the owned wallpaper, never of application content.
struct WorkbenchBackgroundSummary {
    let edges: [Double]
    static let side = 32
    init?(image: CGImage) {
        guard let c = WorkbenchLocalRenderer.bitmap(width: Self.side, height: Self.side) else { return nil }
        c.draw(image, in: CGRect(x: 0, y: 0, width: Self.side, height: Self.side))
        guard let p = c.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        var light = [Double](repeating: 0, count: Self.side * Self.side)
        for i in light.indices { light[i] = (Double(p[i * 4]) * 0.2126 + Double(p[i * 4 + 1]) * 0.7152 + Double(p[i * 4 + 2]) * 0.0722) / 255 }
        edges = light.indices.map { i in
            let x = i % Self.side, y = i / Self.side
            return min(1, ((x > 0 ? abs(light[i] - light[i - 1]) : 0) + (y > 0 ? abs(light[i] - light[i - Self.side]) : 0)) * 3)
        }
    }
    func complexity(rect: CGRect, viewport: CGSize, image: CGSize) -> Double {
        let map = WorkbenchLocalRenderer.mapping(image: image, viewport: viewport)
        guard map.width > 0, map.height > 0 else { return 0 }
        var sum = 0.0
        for fy in [0.2, 0.5, 0.8] { for fx in [0.2, 0.5, 0.8] {
            let x = max(0, min(Self.side - 1, Int((rect.minX + rect.width * fx - map.minX) / map.width * Double(Self.side))))
            let y = max(0, min(Self.side - 1, Int((rect.minY + rect.height * fy - map.minY) / map.height * Double(Self.side))))
            sum += edges[y * Self.side + x]
        } }
        return sum / 9
    }
}

/// Window-local, weak geometry records; bucket queries touch nearby surfaces only.
/// This is D's finite separation policy, not a system backdrop algorithm.
@MainActor final class WorkbenchReadabilityRegistry {
    struct Cell: Hashable { let x: Int; let y: Int }
    struct Record {
        weak var view: WorkbenchBackgroundNSView?
        let rect: CGRect
        let group: String
        let role: WorkbenchSurfaceRole
        let order: [Int]
        let scroll: Double
    }
    struct Patch: Equatable { let rect: CGRect; let alpha: Double; var contour: CGPath? = nil }
    struct Effect: Equatable {
        var contained = false
        var patches: [Patch] = []
        static var none: Effect { Effect() }
    }
    private let members = NSHashTable<WorkbenchBackgroundNSView>.weakObjects()
    private let consumers = NSHashTable<WorkbenchBackgroundNSView>.weakObjects()
    func configure(_ view: WorkbenchBackgroundNSView) {
        let wasActive = !consumers.allObjects.isEmpty
        members.add(view)
        if view.readability.enabled && view.readability.amount > 0 && view.drawsGlass && !view.isCanvas && !view.isGeometryOnly { consumers.add(view) }
        else { consumers.remove(view) }
        if consumers.allObjects.isEmpty {
            records.removeAll(); cells.removeAll(); memberships.removeAll(); exposure.removeAll()
        } else if !wasActive {
            // Disabled plates and geometry-only scroll bodies still contribute
            // to an enabled consumer. Rebuild when the first consumer appears.
            for member in members.allObjects { update(member) }
        }
    }
    private var records: [ObjectIdentifier: Record] = [:]
    private var cells: [Cell: Set<ObjectIdentifier>] = [:]
    private var memberships: [ObjectIdentifier: Set<Cell>] = [:]
    private(set) var queries = 0
    private(set) var inspectedCandidates = 0
    private(set) var geometryUpdates = 0
    private var summaryImage: CGImage?
    private var summary: WorkbenchBackgroundSummary?
    private var exposure: [ObjectIdentifier: Double] = [:]
    private(set) var summaryBuilds = 0

    private func keys(_ rect: CGRect) -> Set<Cell> {
        guard !rect.isNull, !rect.isEmpty, rect.width.isFinite, rect.height.isFinite else { return [] }
        let x0 = Int(floor(rect.minX / 160)), x1 = Int(floor(rect.maxX / 160))
        let y0 = Int(floor(rect.minY / 160)), y1 = Int(floor(rect.maxY / 160))
        guard x1 - x0 < 256, y1 - y0 < 256 else { return [] }
        return Set((x0...x1).flatMap { x in (y0...y1).map { Cell(x: x, y: $0) } })
    }
    func remove(_ view: WorkbenchBackgroundNSView) {
        members.remove(view); consumers.remove(view); remove(ObjectIdentifier(view))
        if consumers.allObjects.isEmpty { records.removeAll(); cells.removeAll(); memberships.removeAll(); exposure.removeAll() }
    }
    private func remove(_ id: ObjectIdentifier) {
        for cell in memberships.removeValue(forKey: id) ?? [] {
            cells[cell]?.remove(id); if cells[cell]?.isEmpty == true { cells.removeValue(forKey: cell) }
        }
        records.removeValue(forKey: id); exposure.removeValue(forKey: id)
    }
    func update(_ view: WorkbenchBackgroundNSView) {
        guard !consumers.allObjects.isEmpty else { return }
        let id = ObjectIdentifier(view)
        guard !view.isCanvas, !view.isHiddenOrHasHiddenAncestor, let window = view.window,
              let root = view.owner?.root, root.window === window else { remove(id); return }
        let clipped = view.visibleRect.intersection(view.bounds)
        let rect = view.convert(clipped, to: root).intersection(root.bounds)
        guard !rect.isEmpty, !rect.isNull else { remove(id); return }
        var order: [Int] = [], current: NSView? = view
        while let child = current, let parent = child.superview {
            order.append(parent.subviews.firstIndex { $0 === child } ?? 0); current = parent
        }
        order.reverse()
        let record = Record(view: view, rect: rect, group: view.surfaceGroup ?? String(describing: id),
            role: view.surfaceRole, order: order, scroll: min(1, max(0, (view.enclosingScrollView?.contentView.bounds.minY ?? 0) / 12)))
        if let old = records[id], old.rect == record.rect, old.order == record.order,
           old.group == record.group, old.role == record.role, old.scroll == record.scroll { return }
        let previous = records[id]?.rect ?? rect
        let previousExposure = exposure[id]
        remove(id); records[id] = record; exposure[id] = previousExposure; geometryUpdates += 1
        let occupied = keys(rect.insetBy(dx: -16, dy: -16)); memberships[id] = occupied
        for cell in occupied { cells[cell, default: []].insert(id) }
        let affected = keys(previous.union(rect).insetBy(dx: -16, dy: -16)).reduce(into: Set<ObjectIdentifier>()) { $0.formUnion(cells[$1] ?? []) }
        for other in affected { records[other]?.view?.needsDisplay = true }
    }
    private func samplesIntersect(_ front: WorkbenchBackgroundNSView, _ back: WorkbenchBackgroundNSView, in rect: CGRect, root: NSView) -> Bool {
        // Test actual contours, excluding the empty corners of rounded plates.
        for fy in [0.15, 0.5, 0.85] { for fx in [0.15, 0.5, 0.85] {
            let point = CGPoint(x: rect.minX + rect.width * fx, y: rect.minY + rect.height * fy)
            let a = front.convert(point, from: root), b = back.convert(point, from: root)
            if (front.contour?(front.bounds, 0).contains(a) ?? front.bounds.contains(a)) &&
                (back.contour?(back.bounds, 0).contains(b) ?? back.bounds.contains(b)) { return true }
        } }
        return false
    }
    func effect(for view: WorkbenchBackgroundNSView) -> Effect {
        let settings = view.readability
        guard settings.enabled, settings.amount > 0, view.drawsGlass,
              let root = view.owner?.root, root.window === view.window else { return .none }
        update(view)
        let id = ObjectIdentifier(view)
        guard let own = records[id] else { return .none }
        queries += 1
        let near = keys(own.rect.insetBy(dx: -16, dy: -16)).reduce(into: Set<ObjectIdentifier>()) { $0.formUnion(cells[$1] ?? []) }
        var effect = Effect(), overlap: [Patch] = [], edge = 0.0
        for otherID in near where otherID != id {
            inspectedCandidates += 1
            guard let other = records[otherID], let back = other.view else { remove(otherID); continue }
            guard !back.isHiddenOrHasHiddenAncestor, back.window === view.window else { continue }
            if other.group == own.group {
                if !back.isGeometryOnly, other.rect.contains(own.rect), other.rect.width > own.rect.width + 1 { effect.contained = true }
                if own.role == .scrollEdge, other.scroll > 0, other.rect.minY < own.rect.maxY + 16,
                   other.rect.maxY > own.rect.minY, other.rect.maxX > own.rect.minX, other.rect.minX < own.rect.maxX {
                    edge = max(edge, other.scroll)
                }
                continue
            }
            guard !back.isGeometryOnly, other.order.lexicographicallyPrecedes(own.order) else { continue }
            let area = other.rect.intersection(own.rect)
            guard !area.isEmpty, !area.isNull, samplesIntersect(view, back, in: area, root: root) else { continue }
            let origin = view.convert(CGPoint.zero, from: back)
            let x = view.convert(CGPoint(x: 1,y: 0), from: back), y = view.convert(CGPoint(x: 0,y: 1), from: back)
            var transform = CGAffineTransform(a: x.x-origin.x, b: x.y-origin.y, c: y.x-origin.x, d: y.y-origin.y, tx: origin.x, ty: origin.y)
            let contour = back.contour?(back.bounds, 0).copy(using: &transform)
            overlap.append(.init(rect: view.convert(area, from: root), alpha: settings.amount * (own.role == .popup ? 0.36 : 0.28), contour: contour))
        }
        let source = view.owner?.image
        if summaryImage !== source {
            summaryImage = source; summary = source.flatMap { WorkbenchBackgroundSummary(image: $0) }
            if source != nil { summaryBuilds += 1 }
        }
        let coordinates = view.owner?.coordinates(for: view) ?? (rect: own.rect, viewport: root.bounds.size)
        let complexity = source.map { summary?.complexity(rect: coordinates.rect, viewport: coordinates.viewport, image: CGSize(width: $0.width, height: $0.height)) ?? 0 } ?? 0
        let measured = (complexity * 8).rounded() / 8
        let previous = exposure[id] ?? measured
        let smooth = abs(measured - previous) < 0.125 ? previous : measured
        exposure[id] = smooth
        let amount = settings.amount
        if smooth > 0 { effect.patches.append(.init(rect: view.bounds, alpha: amount * smooth * 0.20)) }
        // Each area uses max alpha, never one layer per overlapping object.
        effect.patches.append(contentsOf: overlap)
        if edge > 0 {
            // Six finite bands fade toward the body; scroll exposure rises over
            // twelve points instead of snapping at a one-point threshold.
            let height = min(12, view.bounds.height)
            for band in 0..<6 {
                effect.patches.append(.init(rect: CGRect(x: 0, y: view.bounds.height - height + height * Double(band) / 6,
                    width: view.bounds.width, height: height / 6), alpha: amount * edge * 0.32 * Double(band + 1) / 6))
            }
        }
        return effect
    }

    static func paint(_ effect: Effect, in c: CGContext, view: WorkbenchBackgroundNSView) {
        guard !effect.patches.isEmpty else { return }
        c.saveGState(); defer { c.restoreGState() }
        if let path = view.contour?(view.bounds, 0) { c.addPath(path); c.clip() }
        // Ascending source-copy rectangles form an exact maximum mask. A
        // transparency layer keeps the existing glass pixels intact; no alpha
        // accumulates when many surfaces overlap and work is O(k log k).
        c.beginTransparencyLayer(auxiliaryInfo: nil)
        c.setBlendMode(.copy)
        for patch in effect.patches.sorted(by: { $0.alpha < $1.alpha }) where patch.alpha > 0 {
            c.saveGState()
            if let contour = patch.contour { c.addPath(contour); c.clip() }
            c.setFillColor(WorkbenchLocalRenderer.color(view.palette.panel).copy(alpha: patch.alpha)!)
            c.fill(patch.rect)
            c.restoreGState()
        }
        c.endTransparencyLayer()
    }
}
