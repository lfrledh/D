import AppKit
import SwiftUI
import Testing
@testable import UI

@Suite(.serialized) @MainActor struct WorkbenchChildPanelTests {
    @Test func dirtyCloseNeverDiscardsAndFailureKeepsDraft() async {
        let gate = WorkbenchChildCloseGate()
        var closes = 0, saves = 0
        gate.commit = { closes += 1 }
        gate.update(dirty: true, busy: false, save: { saves += 1; throw NSError(domain: "controlled-save", code: 1) })
        gate.requestClose(); #expect(gate.asksToClose); #expect(closes == 0)
        gate.saveAndClose()
        for _ in 0..<10 { await Task.yield() }
        #expect(saves == 1); #expect(closes == 0); #expect(gate.asksToClose); #expect(gate.failure != nil)
        gate.requestClose() // outside/Escape on confirmation only cancels that intent
        #expect(!gate.asksToClose); #expect(closes == 0)
        gate.requestClose(); gate.discard(); #expect(closes == 1)
    }
    @Test func pendingCloseWaitsForSaveAndDoesNotSubmitTwice() async {
        let gate = WorkbenchChildCloseGate(); var closes = 0
        gate.commit = { closes += 1 }
        gate.update(dirty: true, busy: true, save: nil)
        gate.requestClose(); gate.requestClose(); #expect(closes == 0)
        gate.update(dirty: false, busy: false, save: nil)
        for _ in 0..<10 { await Task.yield() }
        #expect(closes == 1)
    }
    @Test func downloadAndGeneralPanelsFitParentWithoutChangingIt() {
        for size in [CGSize(width: 1080, height: 680), CGSize(width: 1920, height: 1080)] {
            let result = WorkbenchChildPanelSize(download: true).resolve(in: size)
            #expect(result.width <= 840 && result.height <= 560)
            #expect(result.width <= size.width - 64 && result.height <= size.height - 64)
            let general = WorkbenchChildPanelSize(width: 1200, height: 900).resolve(in: size)
            #expect(general.width <= size.width - 48 && general.height <= size.height - 48)
        }
    }
    @Test func toolsAvoidSidebarModeAndRunDock() {
        for w: CGFloat in [1080, 1280, 1920] {
            for right: CGFloat? in [nil, 260, 360] {
                for expanded: CGFloat in [0, 420] {
                    let size = CGSize(width: w, height: 800), mode = CGSize(width: 300, height: 52)
                    let tools = WorkbenchFloatingLayout.canvasTools(viewport: size, rightPanelWidth: right, mode: mode, runPanelHeight: expanded)
                    #expect(tools.width == 88 && tools.height == 40 && tools.minY >= 16)
                    let modeRect = CGRect(x: w-316,y: 732,width:300,height:52)
                    #expect(!tools.intersects(modeRect))
                    if let right { #expect(tools.maxX <= w-16-right-12) }
                    let h = 48 + (expanded > 0 ? expanded + 8 : 0)
                    let dock = CGRect(x: (w-440)/2,y:800-16-h,width:440,height:h)
                    #expect(!tools.intersects(dock))
                }
            }
        }
    }
}

extension WorkbenchChildPanelTests {
    @Test func repeatedEmptyComposerCallbacksKeepTheFirstRealOwner() {
        let empty = UUID(), created = UUID(), other = UUID()
        #expect(ChatComposerIdentity.resolve(captured: empty, empty: empty, created: nil, selected: nil) == .empty)
        #expect(ChatComposerIdentity.resolve(captured: empty, empty: empty, created: created, selected: created) == .current(created))
        #expect(ChatComposerIdentity.resolve(captured: empty, empty: empty, created: created, selected: other) == .stale)
        #expect(ChatComposerIdentity.resolve(captured: created, empty: empty, created: created, selected: other) == .stale)
    }
    @Test func acceptanceDoesNotAnimateHistoryOrRestoration() {
        let owner = NSObject(), session = UUID()
        let old = ChatMessageAcceptance(owner: ObjectIdentifier(owner), session: session, loaded: true, visible: true, count: 1)
        let next = ChatMessageAcceptance(owner: ObjectIdentifier(owner), session: session, loaded: true, visible: true, count: 2)
        #expect(next.acceptsArrival(after: old))
        #expect(!next.acceptsArrival(after: next))
        #expect(!next.acceptsArrival(after: .init(owner: ObjectIdentifier(owner), session: UUID(), loaded: true, visible: true, count: 0)))
        #expect(!next.acceptsArrival(after: .init(owner: ObjectIdentifier(owner), session: session, loaded: false, visible: true, count: 0)))
        #expect(!next.acceptsArrival(after: .init(owner: ObjectIdentifier(owner), session: session, loaded: true, visible: false, count: 0)))
    }
    @Test func terminationWaitersAreResolvedOnceAndCannotDiscardAppliedSave() async {
        let gate = WorkbenchChildCloseGate()
        gate.update(dirty: true, busy: true, allowsDiscard: false, save: {})
        let first = Task { await gate.waitForClose() }
        let second = Task { await gate.waitForClose() }
        for _ in 0..<10 { await Task.yield() }
        #expect(gate.hasCloseWaiter)
        gate.keepEditing(); #expect(gate.hasCloseWaiter)
        gate.update(dirty: true, busy: false, allowsDiscard: false, save: {})
        for _ in 0..<10 { await Task.yield() }
        gate.discard(); #expect(gate.hasCloseWaiter)
        gate.keepEditing()
        let firstResult = await first.value, secondResult = await second.value
        #expect(!firstResult && !secondResult)
        let final = Task { await gate.waitForClose() }
        for _ in 0..<10 { await Task.yield() }
        _ = gate.finishClose()
        #expect(await final.value)
        gate.invalidate(); #expect(!gate.hasCloseWaiter)
    }
    @Test func smallWindowRunPanelLeavesToolClearance() {
        let size = CGSize(width:1080,height:500), h = WorkbenchFloatingLayout.runPanelHeight(available:500)
        let tools = WorkbenchFloatingLayout.canvasTools(viewport:size,rightPanelWidth:320,mode:.init(width:232,height:52),runPanelHeight:h)
        let dock = CGRect(x:320,y:500-16-48-h-8,width:440,height:48+h+8)
        #expect(!tools.intersects(dock))
    }
    @Test func rateHasOneIdentityAndDoesNotInventProgress() {
        var rate = ModelDownloadRate(); let now = ContinuousClock.now
        let id = ModelDownloadRate.Identity(task:UUID(),attempt:UUID(),generation:UUID())
        rate.sample(identity:id,bytes:100,now:now)
        #expect(rate.bytesPerSecond == nil)
        rate.sample(identity:id,bytes:200,now:now.advanced(by:.seconds(1)))
        #expect(rate.bytesPerSecond == 100)
        rate.sample(identity:id,bytes:50,now:now.advanced(by:.seconds(2)))
        #expect(rate.bytesPerSecond == nil)
        rate.sample(identity:nil,bytes:50,now:now.advanced(by:.seconds(3)))
        #expect(rate.identity == nil)
    }
}


extension WorkbenchChildPanelTests {
    @Test func initialPanelHostAcceptsEscapeWithoutClickingAnEditor() throws {
        let window = NSWindow(contentRect: .init(x:0,y:0,width:1080,height:740), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = NSView()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("D-child-escape-" + UUID().uuidString)
        defer { window.close(); try? FileManager.default.removeItem(at: root) }
        let preferences = ChatDisplayPreferencesState(appearanceDirectory: root)
        let panel = try #require(WorkbenchChildPanelHandle(owner: window, title: "Parent", content: AnyView(Text("Controlled panel")), preferences: preferences, language: nil))
        let host = try #require(WorkbenchChildPanels.frontmostSurface(on: window)?.subviews.compactMap { $0 as? WorkbenchChildHostingView }.first)
        let gate = host.closeGate; var closes = 0
        gate.commit = { closes += 1 }
        #expect(host.acceptsFirstResponder)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        gate.update(dirty: true, busy: false, save: nil)
        host.keyDown(with: event)
        #expect(gate.asksToClose && closes == 0)
        host.keyDown(with: event)
        #expect(!gate.asksToClose && closes == 0)
        let child = try #require(WorkbenchChildPanelHandle(owner: window, title: "Child", content: AnyView(Text("Nested panel")), preferences: preferences, language: nil))
        host.keyDown(with: event) // A stale parent responder must not close either surface.
        #expect(!gate.asksToClose && closes == 0 && child.isVisible && panel.isVisible)
        child.close()
        gate.update(dirty: false, busy: false, save: nil)
        host.keyDown(with: event)
        #expect(closes == 1)
        panel.close()
        host.keyDown(with: event) // Detached host is inert.
        #expect(closes == 1)
    }
}


extension WorkbenchChildPanelTests {
    @Test func retainedDraftContributionsCannotOverwriteEachOther() async {
        let gate = WorkbenchChildCloseGate(), first = UUID(), second = UUID()
        var writes: [Int] = [], closes = 0
        gate.commit = { closes += 1 }
        gate.register(first, dirty: true, busy: false, allowsDiscard: true, save: { writes.append(1) })
        gate.register(second, dirty: false, busy: false, allowsDiscard: true, save: nil)
        gate.requestClose(); #expect(gate.asksToClose && gate.save != nil)
        gate.keepEditing()
        gate.register(second, dirty: true, busy: false, allowsDiscard: false, save: { writes.append(2); throw NSError(domain:"second-draft",code:1) })
        gate.requestClose(); gate.discard(); #expect(closes == 0)
        gate.saveAndClose()
        for _ in 0..<10 { await Task.yield() }
        #expect(writes == [1,2] && gate.failure != nil && gate.asksToClose && closes == 0)
        gate.unregister(first); #expect(gate.dirty)
        gate.keepEditing(); gate.unregister(second); #expect(!gate.dirty)
        gate.requestClose(); #expect(closes == 1)
    }
}


extension WorkbenchChildPanelTests {
    @Test func orphanedEscapeIsBoundToOwnerAndNeverStealsChildInput() throws {
        let window = NSWindow(contentRect: .init(x:0,y:0,width:1080,height:740), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = NSView()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("D-orphan-escape-" + UUID().uuidString)
        defer { window.close(); try? FileManager.default.removeItem(at: root) }
        let preferences = ChatDisplayPreferencesState(appearanceDirectory: root)
        let panel = try #require(WorkbenchChildPanelHandle(owner: window, title: "Controlled", content: AnyView(Text("Panel")), preferences: preferences, language: nil))
        let host = try #require(WorkbenchChildPanels.frontmostSurface(on: window)?.subviews.compactMap { $0 as? WorkbenchChildHostingView }.first)
        func key(_ code: UInt16 = 53, _ modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location:.zero, modifierFlags:modifiers, timestamp:0, windowNumber:window.windowNumber,
                context:nil, characters:"\u{1b}", charactersIgnoringModifiers:"\u{1b}", isARepeat:false, keyCode:code))
        }
        window.makeFirstResponder(window)
        #expect(WorkbenchChildPanels.orphanedEscapeTarget(try key(), on:window) === host.closeGate)
        #expect(WorkbenchChildPanels.orphanedEscapeTarget(try key(53,.command), on:window) == nil)
        #expect(WorkbenchChildPanels.orphanedEscapeTarget(try key(36), on:window) == nil)
        #expect(WorkbenchChildPanels.orphanedEscapeTarget(try key(), on:nil) == nil)
        window.makeFirstResponder(host)
        #expect(WorkbenchChildPanels.orphanedEscapeTarget(try key(), on:window) == nil)
        let editor = NSTextView(); window.contentView?.addSubview(editor); window.makeFirstResponder(editor)
        #expect(WorkbenchChildPanels.orphanedEscapeTarget(try key(), on:window) == nil)
        let popup = try #require(WorkbenchPopupOverlay.present(from:host,contextID:"child-menu",title:"Menu",items:[.init(id:"one",title:"One",action:{})],
            style:.init(owner:nil,palette:.defaultLight,strength:0.55,drawsGlass:true,legacyFill:nil,readability:.init()),validContext:{true}))
        window.makeFirstResponder(window) // A menu remains the Escape owner even if its focus is displaced.
        #expect(WorkbenchChildPanels.orphanedEscapeTarget(try key(), on:window) == nil)
        popup.keyDown(with:try key())
        #expect(!WorkbenchPopupOverlay.isPresented(on:window))
        window.makeFirstResponder(window)
        let nested = try #require(WorkbenchChildPanelHandle(owner:window,title:"Nested",content:AnyView(Text("Child")),preferences:preferences,language:nil))
        #expect(WorkbenchChildPanels.orphanedEscapeTarget(try key(), on:window) !== host.closeGate)
        nested.close(); panel.close()
        #expect(WorkbenchChildPanels.orphanedEscapeTarget(try key(), on:window) == nil)
    }
}
