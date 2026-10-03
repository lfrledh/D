import AppKit
import Testing
@testable import UI

@Suite("Native chat action menu lifecycle", .serialized)
@MainActor struct ChatActionMenuTests {
    private func fixture(_ items: [ChatActionMenuItem]) ->
        (ChatActionMenu.Coordinator, NSPopUpButton, NSMenu) {
        let coordinator = ChatActionMenu.Coordinator()
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.usesItemFromMenu = false
        button.autoenablesItems = false
        coordinator.install(on: button)
        coordinator.update(button, title: "Conversation actions",
                           accessibilityIdentifier: "chat-actions", items: items)
        return (coordinator, button, button.menu!)
    }

    private func endTracking(_ coordinator: ChatActionMenu.Coordinator, menu: NSMenu) {
        coordinator.menuDidClose(menu)
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
    }

    @Test func trackingKeepsDisplayedRowsAndOriginalActionUntilNativeEnd() throws {
        var calls: [String] = []
        let original = ChatActionMenuItem(id: "candidate", title: "Original", selected: true) {
            calls.append("original")
        }
        let (coordinator, button, menu) = fixture([original])
        let displayed = try #require(menu.item(at: 0))
        coordinator.menuWillOpen(menu)

        coordinator.update(button, title: "Changed title", accessibilityIdentifier: "changed-id",
                           items: [.init(id: "candidate", title: "Intermediate") { calls.append("intermediate") }])
        coordinator.update(button, title: "Newest title", accessibilityIdentifier: "newest-id",
                           items: [.init(id: "candidate", title: "Newest") { calls.append("newest") }])
        #expect(menu.itemArray.count == 1)
        #expect(menu.item(at: 0) === displayed)
        #expect(displayed.title == "Original")
        #expect(displayed.state == .on)
        #expect(button.title == "Conversation actions")

        coordinator.selectItem(displayed)
        #expect(calls.isEmpty)
        coordinator.menuDidClose(menu)
        coordinator.drainAfterTracking() // Closing alone is still inside native tracking.
        #expect(calls.isEmpty)
        #expect(menu.item(at: 0) === displayed)
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
        #expect(calls.isEmpty)
        coordinator.drainAfterTracking()
        #expect(calls == ["original"])
        #expect(menu.item(at: 0)?.title == "Newest")
        #expect(menu.item(at: 0) !== displayed)
        #expect(button.title == "Newest title")
        coordinator.dismantle(button)
    }

    @Test func selectionDispatchesAtMostOnceAfterBothLifecycleSignals() throws {
        var count = 0
        let (coordinator, button, menu) = fixture([
            .init(id: "one", title: "One") { count += 1 }
        ])
        let item = try #require(menu.item(at: 0))
        coordinator.menuWillOpen(menu)
        coordinator.selectItem(item)
        coordinator.selectItem(item)
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
        coordinator.drainAfterTracking()
        #expect(count == 0)
        coordinator.menuDidClose(menu)
        coordinator.drainAfterTracking()
        #expect(count == 1)
        coordinator.selectItem(item)
        coordinator.drainAfterTracking()
        #expect(count == 1)
        coordinator.dismantle(button)
    }

    @Test func disabledLeafAndDisabledParentCannotDispatch() throws {
        var count = 0
        let (coordinator, button, menu) = fixture([
            .init(id: "disabled", title: "Disabled", enabled: false) { count += 1 },
            .init(id: "parent", title: "Parent", enabled: false, children: [
                .init(id: "child", title: "Child") { count += 1 }
            ])
        ])
        let leaf = try #require(menu.item(at: 0))
        let child = try #require(menu.item(at: 1)?.submenu?.item(at: 0))
        #expect(!leaf.isEnabled)
        #expect(!child.isEnabled)
        coordinator.menuWillOpen(menu)
        coordinator.selectItem(leaf)
        coordinator.selectItem(child)
        endTracking(coordinator, menu: menu)
        coordinator.drainAfterTracking()
        #expect(count == 0)
        coordinator.dismantle(button)
    }

    @Test func dismantleCancelsQueuedActionAndPendingSnapshot() throws {
        var count = 0
        let (coordinator, button, menu) = fixture([
            .init(id: "old", title: "Old") { count += 1 }
        ])
        let oldItem = try #require(menu.item(at: 0))
        coordinator.menuWillOpen(menu)
        coordinator.selectItem(oldItem)
        coordinator.update(button, title: "Stale", accessibilityIdentifier: "stale",
                           items: [.init(id: "new", title: "New") { count += 10 }])
        coordinator.dismantle(button)
        endTracking(coordinator, menu: menu)
        coordinator.selectItem(oldItem)
        coordinator.drainAfterTracking()
        #expect(count == 0)
        #expect(menu.item(at: 0)?.title == "Old")
    }
}
