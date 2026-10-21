import AppKit
import DWorkbench
import SwiftUI
import Testing
@testable import UI

@Suite("D UI consistency production components", .serialized)
@MainActor struct WorkbenchConsistencyTests {
    private func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
    private func settle(_ root: NSView) async throws {
        for _ in 0..<20 { root.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
    }
    private func window(_ size: CGSize = .init(width: 800,height: 600)) -> NSWindow {
        let window = NSWindow(contentRect: .init(origin: .zero,size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; return window
    }
    private func key(_ code: UInt16, text: String = "") throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
    }
    private func style(_ owner: WorkbenchBackgroundOwner? = nil) -> WorkbenchPopupStyle {
        .init(owner: owner,palette: .defaultLight,strength: 0.55,drawsGlass: true,legacyFill: nil,readability: .init())
    }
    private func button(_ id: String, in root: NSView) throws -> NSButton {
        try #require(views(root).compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == id })
    }

    @Test func nativeGlassPopupPreservesHostingEditorAndCommandOwnership() async throws {
        let w = window(); defer { w.contentView = nil; w.close() }
        let state = ChatDisplayPreferencesState()
        func content(_ heading: String) -> some View {
            VStack {
                Text(heading)
                TextSourcesQuestionEditor(value: "保留输入", editEpoch: 0, isEditable: true, onEdit: { _ in })
            }.modifier(WorkbenchCanvasModifier(state: state, stylesWindowTitlebar: true))
        }
        let host = NSHostingView(rootView: content("Visible workbench foreground"))
        w.contentView = host; host.frame = .init(x: 0, y: 0, width: 800, height: 600)
        try await settle(host)
        let editor = try #require(views(host).compactMap { $0 as? NSTextView }.first)
        try #require(w.makeFirstResponder(editor))
        let canvas = try #require(views(host).compactMap { $0 as? WorkbenchBackgroundNSView }.first { $0.isCanvas })
        let chrome = try #require(canvas.titlebar)
        func checkTitlebar() {
            #expect(chrome.surface.superview === host.superview && chrome.surface.superview !== host)
            let strip = chrome.surface.convert(chrome.surface.bounds, to: nil)
            #expect(abs(strip.minY - w.contentLayoutRect.maxY) < 1)
            #expect(abs(strip.maxY - host.convert(host.bounds, to: nil).maxY) < 1)
            #expect(strip.height > 0 && strip.height < host.bounds.height)
            #expect(chrome.surface.bounds.contains(chrome.surface.visibleRect))
            #expect(chrome.surface.hitTest(.zero) == nil)
        }
        checkTitlebar()
        var calls = 0
        var native = style(canvas.owner); native.nativeGlass = true
        let popup = try #require(WorkbenchPopupOverlay.present(from: editor, contextID: "exact-owner", title: "Menu",
            items: [.init(id: "parent", title: "Parent", children: [
                .init(id: "child", title: "Child", action: { calls += 1 })])],
            style: native, validContext: { true }))
        try await settle(host)
        checkTitlebar()
        #expect(w.contentView === host && editor.window === w && !editor.isHiddenOrHasHiddenAncestor)
        #expect(popup.superview === host.superview && popup.superview !== host)
        #expect(popup.convert(popup.bounds, to: nil) == host.convert(host.bounds, to: nil))
        #expect(editor.string == "保留输入")
        host.rootView = content("Updated workbench foreground"); try await settle(host)
        checkTitlebar()
        #expect(views(host).contains { $0 === editor } && w.firstResponder === popup)
        w.setContentSize(.init(width: 920, height: 720)); try await settle(host)
        checkTitlebar()
        #expect(popup.convert(popup.bounds, to: nil) == host.convert(host.bounds, to: nil))
        popup.keyDown(with: try key(124))
        let child = try button("child", in: popup)
        #expect(child.window === w)
        child.performClick(nil); child.performClick(nil)
        await Task.yield(); try await Task.sleep(for: .milliseconds(10))
        #expect(calls == 1 && popup.superview == nil)
        checkTitlebar()
        #expect(editor.window === w && editor.string == "保留输入")
        // Structural/command coverage only. Native pixels must also prove that
        // the hosting foreground remains visible below the transparent overlay,
        // and the real key window must verify focus restoration separately.
    }

    @Test(arguments: [false, true], [false, true])
    func nativePopupKeepsSourceAppearanceAcrossSubmenusAndRefresh(dark: Bool, highContrast: Bool) async throws {
        let w = window(); defer { w.close() }
        let windowAppearance: NSAppearance.Name = dark ? .aqua : .darkAqua
        w.appearance = NSAppearance(named: windowAppearance)
        let anchor = NSView(frame: .init(x: 20, y: 20, width: 40, height: 30))
        w.contentView?.addSubview(anchor)
        var originalCalls = 0, replacementCalls = 0
        func items(_ action: @escaping () -> Void) -> [WorkbenchPopupItem] {
            [.init(id: "parent", title: "Parent", children: [.init(id: "child", title: "Child", action: action)])]
        }
        func localStyle(dark: Bool) -> WorkbenchPopupStyle {
            .init(owner: nil, palette: dark ? .defaultDark : .defaultLight,
                strength: 0.55, drawsGlass: true, legacyFill: nil, readability: .init(), nativeGlass: true,
                colorScheme: dark ? .dark : .light, increasedContrast: highContrast)
        }
        var local = localStyle(dark: dark)
        let popup = try #require(WorkbenchPopupOverlay.present(from: anchor, contextID: "source", title: "Menu",
            items: items { originalCalls += 1 }, style: local, validContext: { true }))
        popup.keyDown(with: try key(124))
        try await settle(popup)
        let glass = views(popup).compactMap { $0 as? NSGlassEffectView }
        #expect(glass.count == 2)
        let expected: NSAppearance.Name = highContrast
            ? (dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua)
            : (dark ? .darkAqua : .aqua)
        // AppKit may normalize a requested high-contrast appearance to Aqua
        // when that system mode is off. Check the requested contract separately
        // from the effective appearance returned by this host; do not change it.
        #expect(local.appearanceName == expected)
        let resolved = try #require(NSAppearance(named: expected)).name
        #expect(glass.allSatisfy { $0.effectiveAppearance.name == resolved })
        #expect(w.appearance?.name == windowAppearance)
        let identities = glass.map(ObjectIdentifier.init)
        local = localStyle(dark: !dark)
        popup.update(contextID: "source", title: "Updated", items: items { replacementCalls += 1 }, style: local)
        try await settle(popup)
        let nextExpected: NSAppearance.Name = highContrast
            ? (dark ? .accessibilityHighContrastAqua : .accessibilityHighContrastDarkAqua)
            : (dark ? .aqua : .darkAqua)
        #expect(local.appearanceName == nextExpected)
        let nextResolved = try #require(NSAppearance(named: nextExpected)).name
        #expect(glass.allSatisfy { $0.effectiveAppearance.name == nextResolved })
        #expect(views(popup).compactMap { $0 as? NSGlassEffectView }.map(ObjectIdentifier.init) == identities)
        let child = try button("child", in: popup)
        child.performClick(nil); child.performClick(nil)
        await Task.yield(); try await Task.sleep(for: .milliseconds(10))
        #expect(originalCalls == 1 && replacementCalls == 0 && popup.superview == nil)
        #expect(w.appearance?.name == windowAppearance)
    }

    @Test func popupUsesCapturedCommandWhileLanguageRefreshesItsLabel() async throws {
        let w = window(); defer { w.close() }
        let anchor = NSView(frame: .init(x: 20,y: 20,width: 40,height: 30)); w.contentView?.addSubview(anchor)
        var first = 0, replacement = 0
        let popup = try #require(WorkbenchPopupOverlay.present(from: anchor,contextID: "owner-A",title: "Menu",
            items: [.init(id: "save-A",title: "保存",action: { first += 1 })],style: style(),validContext: { true }))
        popup.update(contextID: "owner-A",title: "Menu",items: [.init(id: "save-A",title: "Save",action: { replacement += 1 })],style: style())
        let row = try button("save-A",in: popup)
        #expect(row.title == "Save")
        row.performClick(nil); row.performClick(nil)
        await Task.yield(); try await Task.sleep(for: .milliseconds(10))
        #expect(first == 1 && replacement == 0)
        #expect(popup.superview == nil)
    }

    @Test(arguments: ["context", "disabled", "removed", "ownerChangedBeforeDispatch"])
    func popupRejectsStaleOrUnavailableCommands(reason: String) async throws {
        let w = window(); defer { w.close() }
        let anchor = NSView(frame: .init(x: 10,y: 10,width: 40,height: 30)); w.contentView?.addSubview(anchor)
        var admitted = true, count = 0
        let item = WorkbenchPopupItem(id: "delete",title: "Delete",action: { count += 1 })
        let popup = try #require(WorkbenchPopupOverlay.present(from: anchor,contextID: "A",title: "Menu",items: [item],style: style(),validContext: { admitted }))
        let row = try button("delete",in: popup)
        switch reason {
        case "context": popup.update(contextID: "B",title: "Menu",items: [item],style: style())
        case "disabled": var next = item; next.enabled = false; popup.update(contextID: "A",title: "Menu",items: [next],style: style())
        case "removed": popup.update(contextID: "A",title: "Menu",items: [],style: style())
        default: row.performClick(nil); admitted = false
        }
        row.performClick(nil); await Task.yield(); try await Task.sleep(for: .milliseconds(10))
        #expect(count == 0); popup.cancel()
    }

    @Test func submenuKeyboardBackAndHomeCloseOnlyTheAppropriateLevel() throws {
        let w = window(); defer { w.close() }
        let anchor = NSView(frame: .init(x: 700,y: 500,width: 40,height: 30)); w.contentView?.addSubview(anchor)
        let popup = try #require(WorkbenchPopupOverlay.present(from: anchor,contextID: "A",title: "Menu",items: [
            .init(id:"parent",title:"Parent",children:[.init(id:"child",title:"Child",action:{})]),
            .init(id:"last",title:"Last",action:{})],style:style(),validContext:{true}))
        popup.keyDown(with: try key(124))
        let child = try button("child",in:popup)
        #expect(child.window === w)
        let childRect = child.convert(child.bounds,to:popup)
        #expect(popup.bounds.contains(childRect))
        popup.keyDown(with: try key(53))
        #expect(child.window == nil && popup.window === w)
        popup.keyDown(with: try key(124)); popup.keyDown(with: try key(123))
        #expect(views(popup).compactMap { $0 as? NSButton }.count == 2)
        popup.keyDown(with: try key(119)); popup.keyDown(with: try key(115))
        popup.keyDown(with: try key(53)); #expect(popup.superview == nil)
    }

    @Test func popupRejectsDuplicateIdentityAndForeignBackgroundOwner() {
        let w = window(), other = window(); defer { w.close(); other.close() }
        let anchor = NSView(frame: .init(x:0,y:0,width:40,height:30)); w.contentView?.addSubview(anchor)
        let owner = WorkbenchBackgroundOwner(), root = WorkbenchBackgroundNSView(); other.contentView = root; owner.root = root
        let item = WorkbenchPopupItem(id:"same",title:"Same",action:{})
        #expect(WorkbenchPopupOverlay.present(from:anchor,contextID:"A",title:"Menu",items:[item,item],style:style(),validContext:{true}) == nil)
        #expect(WorkbenchPopupOverlay.present(from:anchor,contextID:"A",title:"Menu",items:[item],style:style(owner),validContext:{true}) == nil)
    }

    @Test func submenuAXLeavesKeepAncestorAdmissionAndStableIDs() {
        var admitted = true, calls = 0
        let rows = WorkbenchSubmenu("Range") { WorkbenchMenuAction("Run",id:"run") { calls += 1 } }.validation { admitted }
        let leaf = rows.accessibleLeaves[0]
        #expect(leaf.id == "run" && leaf.enabled && leaf.isCurrent())
        admitted = false; if leaf.isCurrent() { leaf.action?() }; #expect(calls == 0)
        #expect(WorkbenchSubmenu("Disabled") { WorkbenchMenuAction("Run",id:"run") {} }.disabled(true).accessibleLeaves.allSatisfy { !$0.enabled })
    }

    private func surface(_ owner: WorkbenchBackgroundOwner, in root: NSView, rect: CGRect, group: String) -> WorkbenchBackgroundNSView {
        let view = WorkbenchBackgroundNSView(frame:rect); view.owner = owner; view.surfaceGroup = group
        view.readability = .init(enabled:true,amount:1); view.contour = { rect,inset in CGPath(roundedRect:rect.insetBy(dx:inset,dy:inset),cornerWidth:12,cornerHeight:12,transform:nil) }
        root.addSubview(view); owner.readability.update(view); return view
    }
    private func pixels(_ view: WorkbenchBackgroundNSView) throws -> [UInt8] {
        let c = try #require(WorkbenchLocalRenderer.bitmap(width:Int(view.bounds.width),height:Int(view.bounds.height)))
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext:c,flipped:true); view.draw(view.bounds)
        return Array(UnsafeBufferPointer(start:try #require(c.data).assumingMemoryBound(to:UInt8.self),count:c.bytesPerRow*c.height))
    }
    @Test(arguments:[0.0,0.55,1.0])
    func disabledAndZeroEnhancementKeepExistingGlassBytes(strength:Double) throws {
        let w = window(); defer { w.close() }
        let owner = WorkbenchBackgroundOwner(), root = WorkbenchBackgroundNSView(frame:.init(x:0,y:0,width:800,height:600)); root.isCanvas=true; root.owner=owner;owner.root=root;w.contentView=root
        _ = surface(owner,in:root,rect:.init(x:20,y:20,width:240,height:180),group:"back")
        let front=surface(owner,in:root,rect:.init(x:40,y:40,width:200,height:140),group:"front");front.strength=strength
        front.readability.enabled=false;let off=try pixels(front)
        front.readability = .init(enabled:true,amount:0);#expect(try pixels(front) == off)
        front.readability.amount=1;#expect(try pixels(front) != off)
    }
    @Test func containmentAndIndependentOverlapAreDifferentAndHiddenViewsStopContributing() throws {
        let w=window();defer{w.close()};let owner=WorkbenchBackgroundOwner(),root=WorkbenchBackgroundNSView(frame:.init(x:0,y:0,width:800,height:600));root.isCanvas=true;owner.root=root;root.owner=owner;w.contentView=root
        let back=surface(owner,in:root,rect:.init(x:20,y:20,width:300,height:220),group:"panel")
        let front=surface(owner,in:root,rect:.init(x:40,y:40,width:180,height:120),group:"panel")
        #expect(owner.readability.effect(for:front).contained)
        #expect(owner.readability.effect(for:front).patches.isEmpty)
        front.surfaceGroup="independent"
        #expect(!owner.readability.effect(for:front).contained)
        #expect(!owner.readability.effect(for:front).patches.isEmpty)
        back.isHidden=true;#expect(owner.readability.effect(for:front).patches.isEmpty)
    }
    @Test func manyOverlapsSaturateInsteadOfMultiplyingOpacity() throws {
        let w=window();defer{w.close()};let owner=WorkbenchBackgroundOwner(),root=WorkbenchBackgroundNSView(frame:.init(x:0,y:0,width:800,height:600));root.isCanvas=true;owner.root=root;root.owner=owner;w.contentView=root
        _=surface(owner,in:root,rect:.init(x:20,y:20,width:300,height:220),group:"back0")
        let front=surface(owner,in:root,rect:.init(x:40,y:40,width:180,height:120),group:"front")
        let one=try pixels(front)
        for i in 1...20 { let back=surface(owner,in:root,rect:.init(x:20,y:20,width:300,height:220),group:"back\(i)"); root.addSubview(back,positioned:.below,relativeTo:front);owner.readability.update(back) }
        #expect(try pixels(front) == one)
    }
    @Test func disabledPlatesStillContributeWhenAnotherConsumerEnablesEnhancement() throws {
        let w = window(); defer { w.close() }
        let owner = WorkbenchBackgroundOwner(), root = WorkbenchBackgroundNSView(frame: .init(x: 0, y: 0, width: 800, height: 600))
        root.isCanvas = true; root.owner = owner; owner.root = root; w.contentView = root
        let back = surface(owner, in: root, rect: .init(x: 20, y: 20, width: 300, height: 220), group: "back")
        let front = surface(owner, in: root, rect: .init(x: 40, y: 40, width: 180, height: 120), group: "front")
        front.readability.enabled = false; back.readability.enabled = false
        let off = try pixels(front), before = owner.readability.geometryUpdates
        back.setFrameOrigin(.init(x: 30, y: 30))
        #expect(owner.readability.geometryUpdates == before)
        front.readability.enabled = true
        #expect(!owner.readability.effect(for: front).patches.isEmpty)
        #expect(!(try pixels(front)).elementsEqual(off))
        back.isHidden = true
        #expect(owner.readability.effect(for: front).patches.isEmpty)
        back.isHidden = false; owner.readability.update(back)
        #expect(!owner.readability.effect(for: front).patches.isEmpty)
        front.readability.enabled = false
        #expect(try pixels(front) == off)
        front.readability.enabled = true
        owner.readability.remove(back); back.owner = nil; back.removeFromSuperview()
        #expect(owner.readability.effect(for: front).patches.isEmpty)
    }

    @Test func distantSurfacesDoNotMakeEveryQueryAnAllPairsScan() {
        let w=window(.init(width:12000,height:1000));defer{w.close()};let owner=WorkbenchBackgroundOwner(),root=WorkbenchBackgroundNSView(frame:.init(x:0,y:0,width:12000,height:1000));root.isCanvas=true;owner.root=root;root.owner=owner;w.contentView=root
        var all:[WorkbenchBackgroundNSView]=[]
        for i in 0..<120 {all.append(surface(owner,in:root,rect:.init(x:CGFloat(i)*90,y:20,width:70,height:60),group:"node\(i)"))}
        let before=owner.readability.inspectedCandidates
        _=owner.readability.effect(for:all[30]);#expect(owner.readability.inspectedCandidates-before<12)
        let updates=owner.readability.geometryUpdates
        _=owner.readability.effect(for:all[30]);#expect(owner.readability.geometryUpdates==updates)
    }
    @Test(arguments:[ColorScheme.light,.dark])
    func popupGlassUsesTheSameOwnedBackgroundCoordinates(scheme:ColorScheme) throws {
        let w=window();defer{w.close()};let owner=WorkbenchBackgroundOwner(),root=WorkbenchBackgroundNSView(frame:.init(x:0,y:0,width:800,height:600));root.isCanvas=true;root.owner=owner;owner.root=root;w.contentView=root
        let anchor=NSView(frame:.init(x:350,y:250,width:60,height:30));root.addSubview(anchor)
        var s=style(owner);s = .init(owner:owner,palette:scheme == .dark ? .defaultDark:.defaultLight,strength:s.strength,drawsGlass:true,legacyFill:nil,readability:.init())
        let popup=try #require(WorkbenchPopupOverlay.present(from:anchor,contextID:"A",title:"Menu",items:[.init(id:"one",title:"One",action:{})],style:s,validContext:{true}))
        defer{popup.cancel()};let glass=try #require(views(popup).compactMap{$0 as? WorkbenchBackgroundNSView}.first)
        #expect(glass.owner === owner && glass.surfaceRole == .popup && !glass.isCanvas)
        #expect(glass.convert(glass.bounds,to:root).width>0)
    }
    @Test func keyboardSliderCommitsOneValueWithoutRecreatingNativeControl() {
        let slider=WorkbenchValueSliderView();var commits:[Double]=[];slider.commit={commits.append($0)}
        slider.doubleValue=0.6;slider.changed();#expect(commits == [0.6]);slider.cancelCandidate();#expect(commits == [0.6])
    }
}

private enum ConsistencyPage: String, CaseIterable { case settings, assets, history }
@MainActor @Observable private final class ConsistencyPageState {
    var selection = ConsistencyPage.settings
    var text: [ConsistencyPage: String] = [.settings:"Settings draft",.assets:"Assets draft",.history:"History draft"]
}
@MainActor private struct ConsistencyPagesFixture: View {
    @Bindable var state: ConsistencyPageState
    var body: some View {
        VStack(spacing:0) {
            WorkbenchSidebarTabs(title:"Tools",selection:$state.selection,choices:ConsistencyPage.allCases.map { ($0,$0.rawValue) })
            WorkbenchSidebarPages(selection:state.selection,choices:ConsistencyPage.allCases,identifier:"consistency-page") { page in
                TextSourcesQuestionEditor(value:state.text[page] ?? "",editEpoch:0,isEditable:true,onEdit:{state.text[page]=$0})
            }
        }
    }
}
extension WorkbenchConsistencyTests {
    @Test func retainedPagesKeepNativeEditorIdentityAndDoNotMountColdPages() async throws {
        let state=ConsistencyPageState(),language=UILanguageStore(preferredLanguages:["en"])
        let host=NSHostingView(rootView:ConsistencyPagesFixture(state:state).environment(\.dLanguageStore,language))
        host.frame = .init(x:0,y:0,width:320,height:500);let w=window(host.frame.size);w.contentView=host;defer{w.close()}
        try await settle(host)
        let settings=try #require(views(host).first{$0.accessibilityIdentifier()=="consistency-page-settings"})
        let editor=try #require(views(settings).compactMap{$0 as? NSTextView}.first)
        #expect(!views(host).contains{$0.accessibilityIdentifier()=="consistency-page-assets"})
        editor.setSelectedRange(.init(location:2,length:4));#expect(w.makeFirstResponder(editor))
        state.selection = .assets;try await settle(host)
        let assets=try #require(views(host).first{$0.accessibilityIdentifier()=="consistency-page-assets"})
        #expect(settings.isHiddenOrHasHiddenAncestor && !assets.isHiddenOrHasHiddenAncestor)
        #expect(w.firstResponder !== editor)
        #expect(!views(host).contains{$0.accessibilityIdentifier()=="consistency-page-history"})
        state.selection = .settings;try await settle(host)
        #expect(views(settings).contains{$0 === editor});#expect(editor.string=="Settings draft")
        try language.select("zh-Hans");host.frame.size.width=288;try await settle(host)
        #expect(views(settings).contains{$0 === editor});#expect(!settings.isHiddenOrHasHiddenAncestor)
    }
}

@MainActor private struct ConsistencyScrollFixture: View {
    let owner: WorkbenchBackgroundOwner
    let scrollGroup: String
    var body: some View {
        VStack(spacing: 0) {
            WorkbenchLocalSurface(owner: owner, palette: .defaultLight, surfaceGroup: "scroll-test",
                surfaceRole: .scrollEdge, readability: .init(enabled: true, amount: 1)).frame(height: 40)
            WorkbenchScrollView {
                VStack(spacing: 0) { ForEach(0..<60) { row in Text("Row \(row)").frame(maxWidth: .infinity, minHeight: 24) } }
            }.environment(\.workbenchSurfaceGroup, scrollGroup)
        }.environment(\.workbenchBackground, owner)
    }
}
@MainActor private final class ConsistencyCoordinateHost: NSView {
    let usesFlippedCoordinates: Bool
    init(frame: CGRect, flipped: Bool) { self.usesFlippedCoordinates = flipped; super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    override var isFlipped: Bool { usesFlippedCoordinates }
}
/// Supplies only the component precondition, without ordering an OS window.
@MainActor private final class ConsistencyFocusWindow: NSWindow { override var isKeyWindow: Bool { true } }
@MainActor private final class ConsistencyMouseTarget: NSView {
    var downs = 0, ups = 0
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { downs += 1 }
    override func mouseUp(with event: NSEvent) { ups += 1 }
}
@MainActor private struct ConsistencyMouseTargetHost: NSViewRepresentable {
    let target: ConsistencyMouseTarget
    func makeNSView(context: Context) -> ConsistencyMouseTarget { target }
    func updateNSView(_ view: ConsistencyMouseTarget, context: Context) {}
}
extension WorkbenchConsistencyTests {
    @Test(arguments: ["top", "scrolled", "hidden", "foreignGroup"])
    func realScrollBodyDrivesOnlyItsVisibleMatchingHeader(scenario: String) async throws {
        let w=window(.init(width:320,height:320)); defer{w.close()}
        let owner=WorkbenchBackgroundOwner(),root=WorkbenchBackgroundNSView(frame:.init(x:0,y:0,width:320,height:320))
        root.isCanvas=true;root.owner=owner;owner.root=root;w.contentView=root
        let group=scenario == "foreignGroup" ? "another-panel":"scroll-test"
        let host=NSHostingView(rootView:ConsistencyScrollFixture(owner:owner,scrollGroup:group));host.frame=root.bounds;root.addSubview(host)
        try await settle(root)
        let header=try #require(views(host).compactMap{$0 as? WorkbenchBackgroundNSView}.first{$0.surfaceRole == .scrollEdge})
        let geometry=try #require(views(host).compactMap{$0 as? WorkbenchBackgroundNSView}.first{$0.isGeometryOnly})
        let scroll=try #require(geometry.enclosingScrollView)
        #expect(geometry.owner === owner && geometry.surfaceGroup==group && header.surfaceGroup=="scroll-test")
        #expect(owner.image == nil)
        func scrollTo(_ y:CGFloat) async throws {
            scroll.contentView.scroll(to:.init(x:0,y:y));scroll.reflectScrolledClipView(scroll.contentView);try await settle(root)
        }
        try await scrollTo(0);#expect(abs(scroll.contentView.bounds.minY)<0.01)
        #expect(owner.readability.effect(for:header).patches.isEmpty)
        if scenario == "top" {return}
        try await scrollTo(6);#expect(scroll.contentView.bounds.minY>1)
        let partial=owner.readability.effect(for:header)
        try await scrollTo(48);#expect(scroll.contentView.bounds.minY>12)
        if scenario == "hidden" {scroll.isHidden=true;#expect(geometry.isHiddenOrHasHiddenAncestor);#expect(owner.readability.effect(for:header).patches.isEmpty);return}
        let full=owner.readability.effect(for:header)
        if scenario == "foreignGroup" {#expect(partial.patches.isEmpty && full.patches.isEmpty);return}
        let partialPeak=try #require(partial.patches.map(\.alpha).max()),fullPeak=try #require(full.patches.map(\.alpha).max())
        #expect(partialPeak>0 && fullPeak>partialPeak+0.01)
        #expect(Set(full.patches.map(\.alpha)).count>1)
        #expect(full.patches.allSatisfy{$0.rect.minY>=header.bounds.maxY-12.01 && $0.rect.maxY<=header.bounds.maxY+0.01 && $0.rect.width==header.bounds.width})
        try await scrollTo(0);#expect(owner.readability.effect(for:header).patches.isEmpty)
        #expect(views(host).contains{$0 === geometry})
    }
    @Test(arguments:[false,true])
    func overlapContourPreservesScaleAndCoordinateDirection(flippedParent:Bool) throws {
        let w=window(.init(width:500,height:360));defer{w.close()}
        let owner=WorkbenchBackgroundOwner(),root=WorkbenchBackgroundNSView(frame:.init(x:0,y:0,width:500,height:360));root.isCanvas=true;root.owner=owner;owner.root=root;w.contentView=root
        let container=ConsistencyCoordinateHost(frame:.init(x:35,y:40,width:360,height:260),flipped:flippedParent);root.addSubview(container)
        let back=surface(owner,in:container,rect:.init(x:30,y:35,width:240,height:180),group:"back");back.bounds = .init(x:0,y:0,width:120,height:90);owner.readability.update(back)
        let front=surface(owner,in:root,rect:root.bounds,group:"front")
        let contour=try #require(owner.readability.effect(for:front).patches.compactMap(\.contour).first)
        let expected=front.convert(back.bounds,from:back),actual=contour.boundingBoxOfPath
        #expect(abs(actual.minX-expected.minX)<0.01 && abs(actual.minY-expected.minY)<0.01)
        #expect(abs(actual.width-240)<0.01 && abs(actual.height-180)<0.01)
        #expect(contour.contains(front.convert(CGPoint(x:110,y:45),from:back)))
        #expect(!contour.contains(front.convert(CGPoint(x:0.5,y:0.5),from:back)))
    }
    private func consistencyMousePair(in window:NSWindow,at point:CGPoint,modifiers:NSEvent.ModifierFlags) throws {
        _=NSApplication.shared;let identity=Int.random(in:1...Int(Int16.max))
        func event(_ type:NSEvent.EventType) throws -> NSEvent {try #require(NSEvent.mouseEvent(with:type,location:point,modifierFlags:modifiers,timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:identity,clickCount:1,pressure:type == .leftMouseDown ? 1:0))}
        NSApp.postEvent(try event(.leftMouseUp),atStart:true);NSApp.postEvent(try event(.leftMouseDown),atStart:true)
        for mask:NSEvent.EventTypeMask in [.leftMouseDown,.leftMouseUp] {
            let queued=try #require(NSApp.nextEvent(matching:mask,until:Date(timeIntervalSinceNow:0.1),inMode:.default,dequeue:true))
            guard queued.windowNumber==window.windowNumber,queued.eventNumber==identity else{NSApp.postEvent(queued,atStart:true);Issue.record("Unrelated event in fixture queue");return};NSApp.sendEvent(queued)
        }
    }
    @Test(arguments:[false,true])
    func contextMenuRoutesControlClickAndPreservesOrdinaryClick(control:Bool) async throws {
        let w=ConsistencyFocusWindow(contentRect:.init(x:0,y:0,width:360,height:300),styleMask:[.titled],backing:.buffered,defer:false);w.isReleasedWhenClosed=false;defer{w.close()}
        let target=ConsistencyMouseTarget();var commands=0
        let host=NSHostingView(rootView:ConsistencyMouseTargetHost(target:target).workbenchContextMenu{WorkbenchMenuAction("Inspect",id:"inspect"){commands+=1}}.environment(\.workbenchMenuContext,"mouse-fixture"))
        host.frame = .init(x:0,y:0,width:360,height:300);w.contentView=host;try await settle(host)
        let point=target.convert(CGPoint(x:target.bounds.midX,y:target.bounds.midY),to:nil)
        try consistencyMousePair(in:w,at:point,modifiers:control ? [.control]:[]);try await settle(host)
        let popups=views(try #require(host.superview)).compactMap{$0 as? WorkbenchPopupOverlay};defer{popups.forEach{$0.cancel(restoreFocus:false)}}
        if control {#expect(popups.count==1);#expect(target.downs==0 && target.ups==0);#expect(try button("inspect",in:#require(popups.first)).isEnabled)}
        else {#expect(popups.isEmpty);#expect(target.downs==1 && target.ups==1)}
        #expect(commands==0)
    }
    @Test(arguments:[false,true])
    func tabClosesPopupAndAdvancesTheOriginalKeyViewChain(backwards:Bool) throws {
        let w=ConsistencyFocusWindow(contentRect:.init(x:0,y:0,width:500,height:300),styleMask:[.titled],backing:.buffered,defer:false);w.isReleasedWhenClosed=false;w.autorecalculatesKeyViewLoop=false;defer{w.close()}
        let root=try #require(w.contentView)
        let before=ConsistencyMouseTarget(frame:.init(x:20,y:20,width:80,height:30)),trigger=ConsistencyMouseTarget(frame:.init(x:120,y:20,width:80,height:30)),after=ConsistencyMouseTarget(frame:.init(x:220,y:20,width:80,height:30))
        [before,trigger,after].forEach{root.addSubview($0)};before.nextKeyView=trigger;trigger.nextKeyView=after;after.nextKeyView=before;#expect(w.makeFirstResponder(trigger))
        var commands=0,closes=0
        let popup=try #require(WorkbenchPopupOverlay.present(from:trigger,contextID:"tab-fixture",title:"Menu",items:[.init(id:"run",title:"Run",action:{commands+=1})],style:style(),validContext:{true},didClose:{closes+=1}))
        #expect(w.firstResponder === popup)
        let event=try #require(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:backwards ? [.shift]:[],timestamp:0,windowNumber:w.windowNumber,context:nil,characters:"\t",charactersIgnoringModifiers:"\t",isARepeat:false,keyCode:48))
        popup.keyDown(with:event);#expect(popup.superview==nil);#expect(w.firstResponder === (backwards ? before:after));#expect(commands==0 && closes==1)
    }
}

extension WorkbenchConsistencyTests {
    @Test(arguments: ModelNodeCatalog.entries.map { $0.id })
    func modelDisplayKeepsIdentityAndUsesRealRegisteredPorts(identifier: String) throws {
        let source=try #require(ModelNodeCatalog.entries.first{$0.id==identifier})
        let language=UILanguageStore(preferredLanguages:["en"])
        let display=ModelNodeUILocalization.display(source,language:language)
        #expect(display.id==source.id && display.modelIdentity==source.modelIdentity && display.revision==source.revision && display.evidencePaths==source.evidencePaths)
        #expect("中文".range(of: "[\\p{Han}&&\\p{L}]", options: .regularExpression) != nil)
        #expect("English · BF16".range(of: "[\\p{Han}&&\\p{L}]", options: .regularExpression) == nil)
        let descriptions=[display.summary,display.device,display.precision,display.deploymentNote]+display.notes
        for (index, value) in descriptions.enumerated() { #expect(value.range(of:"[\\p{Han}&&\\p{L}]",options:.regularExpression)==nil, "Owned description \(identifier) [\(index)]: \(value)") }
        for operation in display.operations {
            if ModelNodeUILocalization.usesRegistry(source) {
                let definition=try #require(WorkflowRegistry.standard.operation(operation.id)?.definition)
                #expect(operation.inputs.map(\.id)==definition.inputs.map(\.id))
                #expect(operation.outputs.map(\.id)==definition.outputs.map(\.id))
            }
        }
        let custom=ModelNodeDescriptor(id:source.id,modality:source.modality,title:"用户保留的中文名字",summary:source.summary,modelIdentity:source.modelIdentity,revision:source.revision,engine:source.engine,device:source.device,precision:source.precision,availability:source.availability,deploymentNote:source.deploymentNote,operations:source.operations,notes:source.notes,evidencePaths:source.evidencePaths)
        #expect(ModelNodeUILocalization.display(custom,language:language)==custom)
    }
    @Test func allBuiltInOwnedCopyIsLoadedWithoutExternalPackLimitChanges() throws {
        let en=UILanguageStore(preferredLanguages:["en"]),zh=UILanguageStore(preferredLanguages:["zh-Hans"])
        #expect(en.diagnostics.isEmpty && zh.diagnostics.isEmpty)
        for (source,key) in ModelNodeOwnedCopy.keys {
            #expect(zh.text(key,fallback:"MISSING")==source)
            #expect(en.text(key,fallback:"MISSING") != "MISSING")
        }
        #expect(LanguagePackLimits.maximumBytes==512*1024)
    }
}

extension WorkbenchConsistencyTests {
    @Test func ownedErrorSummariesPreserveUnknownDiagnosticsAndIdentityText() {
        let en = UILanguageStore(preferredLanguages: ["en"]), zh = UILanguageStore(preferredLanguages: ["zh-Hans"])
        for (raw, key) in WorkbenchOwnedIssue.keys {
            #expect(en.text(key, fallback: "MISSING") != "MISSING")
            #expect(WorkbenchOwnedIssue.summary(raw, language: en) == en.text(key, fallback: "MISSING"))
            #expect(WorkbenchOwnedIssue.summary(raw, language: zh) == raw)
        }
        #expect(WorkbenchOwnedIssue.summary("用户自己的中文诊断／模型输出 42", language: en) == nil)
    }
    @Test func collapsedInvalidPropertyDraftReportsFailureWithoutApplying() async throws {
        var query = SharedLibraryQuery(); query.text = "保留关键词"
        query.properties = .init(width: .init(minimum: 20, maximum: 10))
        let before = query
        var applied = 0, failures: [String] = []
        func content(_ request: Int, hidden: Bool) -> some View {
            SharedLibraryPropertyControls(query: Binding(get: { query }, set: { query = $0 }), items: [], context: .init(),
                allowsScopeEditing: false, onApply: { applied += 1 }, showsActions: false, applyRequest: request,
                onValidationFailure: { failures.append($0) })
                .frame(width: 400, height: hidden ? 0 : 500).clipped()
                .environment(\.dLanguageStore, UILanguageStore(preferredLanguages: ["en"]))
        }
        let host = NSHostingView(rootView: content(0, hidden: false)); host.frame = .init(x: 0, y: 0, width: 400, height: 500)
        try await settle(host)
        host.rootView = content(0, hidden: true); try await settle(host)
        host.rootView = content(1, hidden: true); try await settle(host)
        #expect(applied == 0 && failures.count == 1 && query == before)
        #expect(failures.first?.contains("Conditions have not been applied") == true)
    }
}

extension WorkbenchConsistencyTests {
    @Test func actualWireReceiverUsesLocalPopupAndRejectsChangedContext() async throws {
        let w = window(.init(width: 500, height: 360)); defer { w.close() }
        let root = try #require(w.contentView), wire = WorkflowConnectionHitView(frame: root.bounds)
        root.addSubview(wire)
        let path = CGPath(rect: .init(x: 20, y: 100, width: 400, height: 12), transform: nil)
        wire.updateGeometry(path: path, midpoint: .init(x: 220, y: 106), cutAvailable: true)
        var edits = 0; wire.canDisconnect = true; wire.onDisconnect = { edits += 1 }
        wire.updatePopup(context: "original-graph:wire", style: style())
        let point = wire.convert(CGPoint(x: 220, y: 106), to: nil)
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        wire.rightMouseDown(with: event)
        let popupContainer = try #require(root.superview)
        let popup = try #require(views(popupContainer).compactMap { $0 as? WorkbenchPopupOverlay }.first)
        let action = try button("disconnect", in: popup)
        #expect(action.isEnabled)
        wire.updatePopup(context: "replacement-graph:wire", style: style())
        #expect(popup.superview == nil)
        action.performClick(nil); await Task.yield()
        #expect(edits == 0)
        wire.rightMouseDown(with: event)
        let next = try #require(views(popupContainer).compactMap { $0 as? WorkbenchPopupOverlay }.first)
        try button("disconnect", in: next).performClick(nil); await Task.yield()
        #expect(edits == 1 && next.superview == nil)
    }
}


extension WorkbenchConsistencyTests {
    @Test func wireTrackingAreaSurvivesViewportChangesAndRepairsExternalRemoval() throws {
        let w = window(); defer { w.close() }
        let scroll = NSScrollView(frame: .init(x: 0, y: 0, width: 400, height: 300))
        let document = NSView(frame: .init(x: 0, y: 0, width: 1200, height: 900))
        scroll.documentView = document; w.contentView = scroll
        let wire = WorkflowConnectionHitView(frame: document.bounds); document.addSubview(wire)
        let path = CGPath(rect: .init(x: 40, y: 40, width: 300, height: 12), transform: nil)
        wire.updateGeometry(path: path, midpoint: .init(x: 190, y: 46), cutAvailable: true)
        wire.canDisconnect = true
        wire.updateTrackingAreas()
        let original = try #require(wire.trackingAreas.first)
        #expect(original.options.contains(.inVisibleRect))
        for i in 0..<120 {
            scroll.contentView.scroll(to: .init(x: i % 12, y: i % 17))
            wire.updateTrackingAreas()
            #expect(wire.trackingAreas.count == 1 && wire.trackingAreas.first === original)
        }
        wire.bounds.size = .init(width: 600, height: 450)
        wire.updateTrackingAreas()
        #expect(wire.trackingAreas.first === original)
        wire.updateHover(at: .init(x: 100, y: 46)); #expect(wire.hovering)
        wire.isHidden = true; wire.viewDidHide(); #expect(!wire.hovering)
        wire.isHidden = false; wire.updateTrackingAreas()
        #expect(wire.trackingAreas.first === original)
        wire.updateHover(at: .init(x: 100, y: 46)); #expect(wire.hovering)
        wire.updateHover(at: .init(x: 100, y: 70)); #expect(!wire.hovering)
        wire.removeTrackingArea(original); wire.updateTrackingAreas()
        #expect(wire.trackingAreas.count == 1 && wire.trackingAreas.first !== original)
    }
}
