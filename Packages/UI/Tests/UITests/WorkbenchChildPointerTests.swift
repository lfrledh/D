import AppKit
import SwiftUI
import Testing
@testable import UI

/// Actual hosted surface, layout-derived coordinates and AppKit responder routing.
/// These are test-process events, not evidence of OS mouse delivery to the signed app.
@Suite(.serialized) @MainActor struct WorkbenchChildPointerTests {
    private func fixture() throws -> (NSWindow, WorkbenchChildPanelHandle, WorkbenchChildHostingView, URL) {
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1080, height: 740),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = ChildBackgroundReceiver()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("D-child-pointer-" + UUID().uuidString)
        let content = AnyView(VStack { Text("Static heading"); Divider(); ScrollView { Text("One row"); Spacer(minLength: 100) }; Spacer() }.padding(16))
        let panel = try #require(WorkbenchChildPanelHandle(owner: window, title: "Model selection", content: content,
            preferences: ChatDisplayPreferencesState(appearanceDirectory: root), language: nil))
        let overlay = try #require(WorkbenchChildPanels.frontmostSurface(on: window))
        overlay.layoutSubtreeIfNeeded()
        let host = try #require(overlay.subviews.compactMap { $0 as? WorkbenchChildHostingView }.first)
        host.layoutSubtreeIfNeeded()
        return (window, panel, host, root)
    }
    private func event(_ point: CGPoint, window: NSWindow, type: NSEvent.EventType = .leftMouseDown) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
    }
    private func route(_ point: CGPoint, window: NSWindow) throws -> NSView {
        let frame = try #require(window.contentView?.superview)
        let hit = try #require(frame.hitTest(frame.superview?.convert(point, from: nil) ?? point))
        hit.mouseDown(with: try event(point, window: window))
        hit.mouseUp(with: try event(point, window: window, type: .leftMouseUp))
        return hit
    }

    @Test func visibleBlankAreasAndForwardedEventsAreInternalAfterResize() throws {
        let (window, panel, host, root) = try fixture()
        defer { panel.close(); window.close(); try? FileManager.default.removeItem(at: root) }
        let gate = host.closeGate
        gate.update(dirty: true, busy: false, save: nil)
        for size in [CGSize(width: 1080, height: 740), CGSize(width: 1400, height: 900)] {
            window.setContentSize(size)
            let overlay = try #require(WorkbenchChildPanels.frontmostSurface(on: window))
            overlay.layoutSubtreeIfNeeded(); host.layoutSubtreeIfNeeded()
            let b = host.bounds
            for p in [CGPoint(x:b.midX,y:26), CGPoint(x:b.midX,y:52), CGPoint(x:b.midX,y:b.midY),
                      CGPoint(x:1,y:b.midY), CGPoint(x:b.maxX-1,y:b.midY),
                      CGPoint(x:b.midX,y:1), CGPoint(x:b.midX,y:b.maxY-1), CGPoint(x:2,y:2)] {
                let point = host.convert(p, to:nil)
                _ = try route(point, window:window)
                #expect(panel.isVisible && !gate.asksToClose, "Internal blank/edge at \(p) must not request close")
                gate.keepEditing()
                // An unhandled NSView mouseDown can arrive through the responder
                // chain even when hit testing originally selected an inner view.
                overlay.mouseDown(with: try event(point, window:window))
                #expect(!gate.asksToClose, "Forwarded internal event must remain internal")
                gate.keepEditing()
            }
        }
    }

    @Test func outsideClickConsumesOnlyTopSurfaceAndKeepsFailedSave() async throws {
        let (window, panel, host, root) = try fixture()
        defer { panel.close(); window.close(); try? FileManager.default.removeItem(at: root) }
        let gate = host.closeGate
        var saves = 0
        gate.update(dirty:true,busy:false,save:{ saves += 1; throw NSError(domain:"controlled",code:1) })
        let overlay = try #require(WorkbenchChildPanels.frontmostSurface(on:window))
        let outside = overlay.convert(CGPoint(x:4,y:4),to:nil)
        let hit = try route(outside,window:window)
        #expect(hit === overlay && gate.asksToClose && panel.isVisible)
        gate.saveAndClose()
        for _ in 0..<10 { await Task.yield() }
        #expect(saves == 1 && gate.failure != nil && panel.isVisible && gate.dirty)
        gate.keepEditing()
        let start = host.convert(CGPoint(x:host.bounds.midX,y:26),to:nil)
        let frame = try #require(window.contentView?.superview)
        let insideHit = try #require(frame.hitTest(frame.superview?.convert(start,from:nil) ?? start))
        insideHit.mouseDown(with:try event(start,window:window))
        insideHit.mouseDragged(with:try event(outside,window:window,type:.leftMouseDragged))
        insideHit.mouseUp(with:try event(outside,window:window,type:.leftMouseUp))
        #expect(!gate.asksToClose && panel.isVisible)
        let nested = try #require(WorkbenchChildPanelHandle(owner:window,title:"Nested",content:AnyView(Text("Child")),
            preferences:ChatDisplayPreferencesState(appearanceDirectory:root),language:nil))
        WorkbenchChildPanels.frontmostSurface(on:window)?.layoutSubtreeIfNeeded()
        overlay.mouseDown(with:try event(outside,window:window))
        #expect(panel.isVisible && nested.isVisible && !gate.asksToClose)
        _ = try route(outside,window:window)
        #expect(!nested.isVisible && panel.isVisible && !gate.asksToClose)
        let background = try #require(window.contentView as? ChildBackgroundReceiver)
        #expect(background.downs == 0 && background.ups == 0)
    }

    @Test func foreignWindowAndOwnedMenuDoNotCloseParent() throws {
        let (window, panel, host, root) = try fixture()
        let other = NSWindow(contentRect:window.frame,styleMask:[.titled],backing:.buffered,defer:false)
        other.isReleasedWhenClosed = false
        defer { panel.close(); window.close(); other.close(); try? FileManager.default.removeItem(at:root) }
        let overlay = try #require(WorkbenchChildPanels.frontmostSurface(on:window))
        overlay.mouseDown(with:try event(.init(x:4,y:4),window:other))
        #expect(panel.isVisible)
        let popup = try #require(WorkbenchPopupOverlay.present(from:host,contextID:"child-pointer-menu",title:"Menu",
            items:[.init(id:"one",title:"One",action:{})],
            style:.init(owner:nil,palette:.defaultLight,strength:0.55,drawsGlass:true,legacyFill:nil,readability:.init()),validContext:{true}))
        overlay.mouseDown(with:try event(overlay.convert(.init(x:4,y:4),to:nil),window:window))
        #expect(panel.isVisible && WorkbenchPopupOverlay.isPresented(on:window))
        let escape = try #require(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,
            windowNumber:window.windowNumber,context:nil,characters:"\u{1b}",charactersIgnoringModifiers:"\u{1b}",isARepeat:false,keyCode:53))
        popup.keyDown(with:escape)
    }
}

@MainActor private final class ChildBackgroundReceiver: NSView {
    var downs = 0, ups = 0
    override func mouseDown(with event: NSEvent) { downs += 1 }
    override func mouseUp(with event: NSEvent) { ups += 1 }
}
