import AppKit
import DInference
import DWorkbench
import SwiftUI
import Testing
@testable import UI

private final class FixtureWheel: NSEvent {
 let base: NSEvent
 let owner: NSWindow
 let number: Int
 let point: CGPoint
 @MainActor init(base: NSEvent, owner: NSWindow, point: CGPoint) {
  self.base = base; self.owner = owner; self.number = owner.windowNumber; self.point = point; super.init()
 }
 required init?(coder: NSCoder) { fatalError() }
 override var window: NSWindow? { owner }
 override var windowNumber: Int { number }
 override var locationInWindow: NSPoint { point }
 override var type: NSEvent.EventType { .scrollWheel }
 override var scrollingDeltaY: CGFloat { base.scrollingDeltaY }
 override var scrollingDeltaX: CGFloat { base.scrollingDeltaX }
 override var hasPreciseScrollingDeltas: Bool { base.hasPreciseScrollingDeltas }
 override var deltaY: CGFloat { base.deltaY }
 override var deltaX: CGFloat { base.deltaX }
 override var cgEvent: CGEvent? { base.cgEvent }
 override var phase: NSEvent.Phase { base.phase }
 override var momentumPhase: NSEvent.Phase { base.momentumPhase }
}

private actor AddendumNoEngine: InferenceEngine {
    private(set) var calls = 0
    func submit(_ request: InferenceRequest, backendID: String) async throws -> InferenceRun {
        calls += 1; throw WorkflowIssue("Presentation must not run inference")
    }
}
@MainActor private final class AddendumInnerScroll: NSScrollView {
    var deliveredWheels = 0
    override func scrollWheel(with event: NSEvent) { deliveredWheels += 1; super.scrollWheel(with: event) }
}
@MainActor private final class AddendumDocument: NSView {
    override var isFlipped: Bool { true }
}
@Suite("Canvas language and help addendum", .serialized) @MainActor
struct WorkbenchAddendumTests {
    private func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    private func settle(_ view: NSView) async throws {
        for _ in 0..<20 { view.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
    }
    @Test func missingTranslationFallsBackAndRepairUpdatesTheSameEntry() throws {
        let language = UILanguageStore(preferredLanguages: ["en"]), key = "consistency.test.source"
        language.testingBuiltIn(.init(schemaVersion: 1, locale: "zh-Hans", displayName: "中文", strings: [key: "保存 {name} 的失败记录"]))
        language.testingBuiltIn(.init(schemaVersion: 1, locale: "en", displayName: "English", strings: [:]))
        #expect(consistencyText(language, "test.source", arguments: ["name": "用户正文"]) == "保存 用户正文 的失败记录")
        language.testingBuiltIn(.init(schemaVersion: 1, locale: "en", displayName: "English", strings: [key: "Save the failed record for {name}"]))
        #expect(consistencyText(language, "test.source", arguments: ["name": "用户正文"]) == "Save the failed record for 用户正文")
        #expect(language.text("absent", fallback: "可读原文") == "可读原文")
    }
    @Test(arguments: ["zh-Hans", "en"])
    func featureCatalogueKeepsNamesPurposeAndObjectReadable(locale: String) throws {
        let language = UILanguageStore(preferredLanguages: [locale])
        #expect(WorkbenchFeatures.all.count == 114)
        #expect(Set(WorkbenchFeatures.all.map(\.id)).count == 114)
        for feature in WorkbenchFeatures.all {
            for key in [feature.name_key, feature.help_key, feature.object_key, feature.conditions_key] {
                let value = WorkbenchFeatures.text(key, language: language)
                #expect(!value.isEmpty && !value.contains("consistency.") && value != String(key.dropFirst(12)))
            }
            #expect(WorkbenchFeatures.purpose(feature.id, language: language) == WorkbenchFeatures.text(feature.help_key, language: language))
        }
    }
    @Test func pinnedHelpRetainsItsContextAndCannotFollowANewTarget() throws {
        let store = WorkbenchHelpStore(), token = UUID()
        let a = WorkbenchHelpContext(featureID: "RECOVERY-SAVE-FAILURE", owner: "run-A:attempt-1", unavailableReason: "Saving")
        store.update(token, context: a); store.pin(token)
        let pinned = try #require(store.presentation)
        #expect(store.isCurrent(pinned))
        store.update(token, context: .init(featureID: "RECOVERY-RECOMPUTE", owner: "run-B:attempt-2", unavailableReason: nil))
        #expect(!store.isCurrent(pinned)); #expect(pinned.context == a)
        store.remove(token); #expect(!store.isCurrent(pinned))
        #expect(store.presentation?.featureID == "RECOVERY-SAVE-FAILURE")
    }
    @Test(arguments: [0, 1, 2, 3])
    func actualCanvasOverlayKeepsViewportAndNodeScreenPositions(layout: Int) async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["D_TEST_TEMP_DIR"] ?? NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try await ProjectStore.create(at: root.appendingPathComponent("overlay.dproject"), name: "Overlay fixture")
        let engine = AddendumNoEngine()
        let runtime = WorkbenchSession(engine: engine, backendID: "never", status: { .init(activeRunID: nil, phase: nil, queuedRunIDs: []) }, shutdown: {}, cleanup: {}, validateModel: { _ in })
        let services = WorkflowServices(store: store, session: runtime, resolveText: { throw WorkflowIssue("No model") }, resolveImage: { throw WorkflowIssue("No model") })
        let controller = WorkflowController(services: services); await controller.load(); controller.addExample("template")
        if layout >= 2, let first = controller.graph?.nodes.first {
            controller.moveNode(id: first.id, x: -12000, y: 8500)
            await controller.save()
            await controller.load()
        }
        let graphs = controller.graphs, undo = controller.canUndo
        let state = WorkbenchSidebarState(leading: false, trailing: false)
        let language = UILanguageStore(preferredLanguages: ["zh-Hans"])
        var commands = 0
        let host = NSHostingView(rootView: WorkflowCanvasView(controller: controller, onTextModel: { commands += 1 }, onImageModel: { commands += 1 }, onImport: { _ in commands += 1 }, onDestination: { commands += 1 }, onPublishText: { commands += 1 }, onReturnText: { _ in commands += 1 }).testingOverlayState(state).environment(\.dLanguageStore, language))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: layout % 2 == 1 ? 900 : 1440, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; defer { window.close() }
        try await settle(host)
        let probe = try #require(views(host).compactMap { $0 as? WorkflowCanvasViewportInput.ProbeView }.first)
        let scroll = try #require(probe.enclosingScrollView), clip = scroll.contentView
        if layout >= 2 {
            #expect(probe.dispatchWheel(layout == 2 ? -10 : 12, .init(x: 200, y: 200), clip.bounds.origin, clip.bounds.size))
            try await settle(host)
        }
        let plates = views(host).compactMap { $0 as? WorkflowNodePlateView }; try #require(!plates.isEmpty)
        let frame = scroll.convert(scroll.bounds, to: host), bounds = clip.bounds
        let positions = plates.map { $0.convert($0.bounds, to: host) }, documentSize = scroll.documentView?.frame.size
        for (left, right, locale) in [(true,false,"zh-Hans"),(true,true,"zh-Hans"),(false,true,"en"),(false,false,"en"),(true,true,"en"),(false,false,"zh-Hans")] {
            withAnimation(.easeInOut(duration: 0.22)) { state.leading = left; state.trailing = right }
            try language.select(locale)
            for _ in 0..<14 {
                host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10))
                #expect(scroll.convert(scroll.bounds, to: host) == frame); #expect(clip.bounds == bounds)
                #expect(scroll.documentView?.frame.size == documentSize)
                #expect(plates.map { $0.convert($0.bounds, to: host) } == positions)
                #expect(!scroll.hasHorizontalScroller && !scroll.hasVerticalScroller)
            }
        }
        // Native hit chain must still reach the canvas in the released middle
        // and after either retained overlay closes. No click/action is injected.
        func hitsCanvas(_ point: CGPoint) -> Bool {
            var hit = host.hitTest(host.convert(point, to: host.superview))
            while let current = hit, current !== scroll { hit = current.superview }
            return hit === scroll
        }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        #expect(hitsCanvas(center))
        let leftPoint = CGPoint(x: frame.minX + 70, y: frame.midY)
        state.leading = true; try await settle(host)
        #expect(!hitsCanvas(leftPoint)); #expect(hitsCanvas(center))
        state.leading = false; try await settle(host)
        #expect(hitsCanvas(leftPoint)); #expect(hitsCanvas(center))
        #expect(controller.graphs == graphs && controller.runs.isEmpty && controller.canUndo == undo)
        #expect(commands == 0); #expect(await engine.calls == 0)
        try await controller.close(); try await store.close()
    }
    @Test(arguments: ["blank", "node", "nested-middle", "nested-end", "control"])
    func realWheelRouteHasOneOwnerAndNoCanvasScroll(surface: String) throws {
        let window = NSWindow(contentRect: .init(x: 0,y: 0,width: 640,height: 480), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let scroll = NSScrollView(frame: .init(x: 0,y: 0,width: 640,height: 480))
        let document = AddendumDocument(frame: .init(x: 0,y: 0,width: 4000,height: 3000)); scroll.documentView = document; window.contentView = scroll
        let probe = WorkflowCanvasViewportInput.ProbeView(frame: .init(x: 0,y: 0,width: 1,height: 1)); document.addSubview(probe)
        probe.navigationAllowed = { true }; probe.reportViewportSize()
        let clip = scroll.contentView; clip.scroll(to: .init(x: 800,y: 700)); scroll.reflectScrolledClipView(clip)
        let before = clip.bounds
        var owner: NSView = document; var nested: AddendumInnerScroll?
        if surface == "node" {
            let plate = WorkflowNodePlateView(frame: .init(x: 840,y: 740,width: 200,height: 180)); document.addSubview(plate); owner = plate
        } else if surface.hasPrefix("nested") {
            let inner = AddendumInnerScroll(frame: .init(x: 840,y: 740,width: 200,height: 180)); inner.hasVerticalScroller = true
            inner.documentView = AddendumDocument(frame: .init(x: 0,y: 0,width: 200,height: 900)); document.addSubview(inner); inner.layoutSubtreeIfNeeded()
            inner.contentView.scroll(to: .init(x: 0,y: surface == "nested-end" ? 900 : 250)); owner = inner; nested = inner
        } else if surface == "control" {
            let button = NSButton(frame: .init(x: 840,y: 740,width: 200,height: 80)); document.addSubview(button); owner = button
        }
        var zooms = 0
        probe.onWheel = { delta, point, offset, size in
            zooms += 1; #expect(delta != 0); #expect(offset == before.origin && size == before.size); #expect(point.x >= 0 && point.y >= 0)
        }
        let point = owner === document ? clip.convert(.init(x: 900,y: 800), to: nil) : owner.convert(.init(x: 70,y: 60), to: nil)
        let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -3,wheel2: 0,wheel3: 0))
        let located = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0,windowNumber: window.windowNumber,context: nil,eventNumber: 1,clickCount: 0,pressure: 0))
        cg.location = try #require(located.cgEvent).location
        cg.setIntegerValueField(.mouseEventWindowUnderMousePointer,value: Int64(window.windowNumber)); cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent,value: Int64(window.windowNumber))
        let event = FixtureWheel(base: try #require(NSEvent(cgEvent: cg)), owner: window, point: point); try #require(event.window === window && !event.hasPreciseScrollingDeltas)
        let nestedBefore = nested?.contentView.bounds.origin
        #expect(probe.routeWheel(event)); #expect(clip.bounds == before)
        #expect(zooms == (["blank","node"].contains(surface) ? 1 : 0))
        // Hidden native scroll views do not animate scrolling in this environment.
        // Assert delivery to the actual native owner here; the visible-window
        // integration test retains its separate scroll-movement assertion.
        if let nested { #expect(nested.deliveredWheels == 1) }
        if surface == "nested-end" { #expect(nested?.contentView.bounds.origin == nestedBefore) }
        #expect(!scroll.hasHorizontalScroller && !scroll.hasVerticalScroller)
        if let nested { #expect(nested.hasVerticalScroller) }
    }
}

extension WorkbenchAddendumTests {
    @Test(arguments: [false, true])
    func gestureAndMomentumKeepTheStartingOwner(startsInside: Bool) throws {
        let window = NSWindow(contentRect: .init(x: 0,y: 0,width: 640,height: 480), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        let scroll = AddendumInnerScroll(frame: .init(x: 0,y: 0,width: 640,height: 480))
        let document = AddendumDocument(frame: .init(x: 0,y: 0,width: 2500,height: 2000))
        scroll.documentView = document; window.contentView = scroll
        let probe = WorkflowCanvasViewportInput.ProbeView(frame: .init(x: 0,y: 0,width: 1,height: 1)); document.addSubview(probe)
        probe.navigationAllowed = { true }; probe.reportViewportSize()
        let inner = AddendumInnerScroll(frame: .init(x: 40,y: 40,width: 200,height: 180))
        inner.documentView = AddendumDocument(frame: .init(x: 0,y: 0,width: 200,height: 900)); document.addSubview(inner)
        let inside = inner.convert(.init(x: 70,y: 60),to: nil)
        let outside = document.convert(.init(x: 400,y: 300),to: nil)
        let before = scroll.contentView.bounds
        var zooms = 0; probe.onWheel = { _, _, _, _ in zooms += 1 }
        func event(_ point: CGPoint, phase: Int64 = 0, momentum: Int64 = 0, horizontal: Bool = false) throws -> NSEvent {
            let cg = try #require(CGEvent(scrollWheelEvent2Source: nil,units: .pixel,wheelCount: 2,wheel1: horizontal ? 0 : -12,wheel2: horizontal ? -12 : 0,wheel3: 0))
            cg.setIntegerValueField(.scrollWheelEventScrollPhase,value: phase)
            cg.setIntegerValueField(.scrollWheelEventMomentumPhase,value: momentum)
            return FixtureWheel(base: try #require(NSEvent(cgEvent: cg)),owner: window,point: point)
        }
        let began = try event(startsInside ? inside : outside,phase: 1)
        try #require(began.phase.contains(.began))
        #expect(probe.routeWheel(began))
        let horizontal = try event(startsInside ? outside : inside,phase: 2,horizontal: true)
        try #require(horizontal.scrollingDeltaY == 0 && horizontal.scrollingDeltaX != 0)
        #expect(probe.routeWheel(horizontal))
        #expect(scroll.deliveredWheels == (startsInside ? 0 : 1))
        #expect(probe.routeWheel(try event(startsInside ? outside : inside,phase: 4)))
        let inertia = try event(startsInside ? outside : inside,momentum: 1)
        try #require(inertia.momentumPhase.contains(.began))
        #expect(probe.routeWheel(inertia))
        #expect(probe.routeWheel(try event(startsInside ? outside : inside,momentum: 3)))
        #expect(zooms == (startsInside ? 0 : 4)); #expect(inner.deliveredWheels == (startsInside ? 5 : 0))
        #expect(scroll.contentView.bounds == before)
        #expect(probe.routeWheel(try event(startsInside ? outside : inside,phase: 1)))
        #expect(zooms == (startsInside ? 1 : 4)); #expect(inner.deliveredWheels == (startsInside ? 5 : 1))
        #expect(!scroll.hasHorizontalScroller && !scroll.hasVerticalScroller)
    }
}

extension WorkbenchAddendumTests {
    @Test func persistentGuideKeepsItsSearchInputAcrossLanguageChanges() async throws {
        let language = UILanguageStore(preferredLanguages: ["zh-Hans"]), store = WorkbenchHelpStore()
        let presentation = WorkbenchHelpPresentation(featureID: nil, token: nil, context: nil)
        let host = NSHostingView(rootView: WorkbenchFeatureGuide(presentation: presentation, store: store).environment(\.dLanguageStore, language))
        let window = NSWindow(contentRect: .init(x: 0,y: 0,width: 800,height: 600),styleMask: [.titled],backing: .buffered,defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; defer { window.close() }
        try await settle(host)
        let input = try #require(views(host).compactMap { $0 as? NSTextField }.first { $0.isEditable })
        input.stringValue = "用户文字 / 保存"; let identity = ObjectIdentifier(input)
        try language.select("en"); try await settle(host)
        let current = try #require(views(host).compactMap { $0 as? NSTextField }.first { $0.isEditable })
        #expect(ObjectIdentifier(current) == identity && current.stringValue == "用户文字 / 保存")
        #expect(store.presentation == nil) // Reading the guide does not dispatch another presentation or command.
    }
}
