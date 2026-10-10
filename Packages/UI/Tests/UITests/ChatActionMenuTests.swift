import AppKit
import Testing
@testable import UI

@Suite("Native chat action menu lifecycle", .serialized)
@MainActor struct ChatActionMenuTests {
    @Test func groupedSeparatorsKeepUnlistedActionsAndTrackedSelectionRunsOnce() throws {
        var calls: [String] = []
        let grouped = ChatActionMenuItem.grouped([
            .init(id: "first", title: "First") { calls.append("original") },
            .init(id: "last", title: "Last") { calls.append("last") },
            .init(id: "unlisted", title: "Unlisted") { calls.append("unlisted") }
        ], ids: [["first"], [], ["missing"], ["last"]])
        #expect(grouped.filter { !$0.isSeparator }.map(\.id) == ["first", "last", "unlisted"])
        #expect(grouped.filter(\.isSeparator).count == 2)
        let (coordinator, button, menu) = fixture(grouped)
        defer { coordinator.dismantle(button) }
        coordinator.menuWillOpen(menu)
        let original = try #require(menu.item(at: 1))
        let separator = try #require(menu.item(at: 2))
        #expect(separator.isSeparatorItem && separator.representedObject == nil)
        coordinator.update(button, title: "Changed", accessibilityIdentifier: "actions",
            items: [.init(id: "first", title: "New title") { calls.append("new") }])
        coordinator.selectItem(separator)
        coordinator.selectItem(original)
        coordinator.selectItem(original)
        endTracking(coordinator, menu: menu)
        coordinator.drainAfterTracking()
        #expect(calls == ["original"])
    }

    @Test func disablingControlRejectsTrackedSelectionAndCanEnableAgain() throws {
        var calls = 0
        let items: [ChatActionMenuItem] = [.init(id: "rename", title: "Rename") { calls += 1 }]
        let (coordinator, button, menu) = fixture(items)
        defer { coordinator.dismantle(button) }
        coordinator.menuWillOpen(menu)
        let original = try #require(menu.item(at: 1))
        coordinator.update(button, title: "Actions", accessibilityIdentifier: "actions", items: items, isEnabled: false)
        #expect(!button.isEnabled)
        coordinator.selectItem(original)
        endTracking(coordinator, menu: menu)
        coordinator.drainAfterTracking()
        coordinator.selectItem(original)
        #expect(!button.isEnabled && calls == 0)
        coordinator.update(button, title: "Actions", accessibilityIdentifier: "actions", items: items, isEnabled: true)
        #expect(button.isEnabled)
        coordinator.selectItem(original)
        #expect(calls == 0)
        coordinator.menuWillOpen(menu)
        coordinator.selectItem(try #require(menu.item(at: 1)))
        endTracking(coordinator, menu: menu)
        coordinator.drainAfterTracking()
        #expect(calls == 1)
    }

    @Test func pullDownTitleCannotConsumeTheFirstAction() throws {
        var calls = 0
        let (coordinator, button, menu) = fixture([
            .init(id: "first", title: "Rename") { calls += 1 }
        ])
        defer { coordinator.dismantle(button) }
        #expect(button.usesItemFromMenu)
        #expect(menu.items.count == 2)
        let title = try #require(menu.item(at: 0))
        #expect(title.title == "Conversation actions")
        // AppKit may attach its own private selector to menu rows. The title
        // must not acquire a business action or dispatch through our coordinator.
        #expect(title.target !== coordinator)
        #expect(title.representedObject == nil)
        let first = try #require(menu.item(at: 1))
        #expect(first.title == "Rename")
        #expect(first.representedObject as? String == "first")
        #expect(!first.isHidden)
        coordinator.update(button, title: "Updated title", accessibilityIdentifier: "chat-actions",
            items: [.init(id: "first", title: "Rename") { calls += 1 }])
        #expect(button.title == "Updated title")
        #expect(menu.item(at: 0) === title)
        #expect(menu.item(at: 1) === first)
        coordinator.menuWillOpen(menu)
        coordinator.selectItem(title)
        #expect(calls == 0)
        coordinator.selectItem(first)
        endTracking(coordinator, menu: menu)
        coordinator.drainAfterTracking()
        #expect(calls == 1)
    }

    @MainActor private final class MeasuredButton: NSPopUpButton {
        var invalidations = 0
        override func invalidateIntrinsicContentSize() {
            invalidations += 1
            super.invalidateIntrinsicContentSize()
        }
    }

    @Test func unchangedPresentationKeepsNativeRowsAndSizeButRefreshesActions() throws {
        var calls: [Int] = []
        let coordinator = ChatActionMenu.Coordinator()
        let button = MeasuredButton(frame: .zero, pullsDown: true)
        button.usesItemFromMenu = true
        coordinator.install(on: button)
        func update(_ generation: Int) {
            coordinator.update(button, title: "Actions", accessibilityIdentifier: "actions", items: [
                .init(id: "parent", title: "Parent", children: [
                    .init(id: "child", title: "Same title") { calls.append(generation) }
                ])
            ])
        }
        update(0)
        let menu = try #require(button.menu)
        let parent = try #require(menu.item(at: 1))
        let child = try #require(parent.submenu?.item(at: 0))
        let cellItem = (button.cell as? NSPopUpButtonCell)?.menuItem
        let invalidations = button.invalidations
        for generation in 1...20 { update(generation) }
        #expect(menu.item(at: 1) === parent)
        #expect(menu.item(at: 1)?.submenu?.item(at: 0) === child)
        #expect((button.cell as? NSPopUpButtonCell)?.menuItem === cellItem)
        #expect(button.invalidations == invalidations)
        coordinator.menuWillOpen(menu)
        coordinator.selectItem(try #require(menu.item(at: 1)?.submenu?.item(at: 0)))
        endTracking(coordinator, menu: menu)
        coordinator.drainAfterTracking()
        #expect(calls == [20])
        coordinator.dismantle(button)
    }

    @Test func samePresentationPendingUpdateRetainsEndedCycleAction() throws {
        var calls: [String] = []
        let (coordinator, button, menu) = fixture([
            .init(id: "same", title: "Same") { calls.append("displayed") }
        ])
        let item = try #require(menu.item(at: 1))
        coordinator.menuWillOpen(menu)
        coordinator.update(button, title: "Conversation actions", accessibilityIdentifier: "chat-actions",
            items: [.init(id: "same", title: "Same") { calls.append("next") }])
        endTracking(coordinator, menu: menu)
        coordinator.drainAfterTracking()
        coordinator.selectItem(item)
        #expect(calls == ["displayed"])
        coordinator.menuWillOpen(menu)
        coordinator.selectItem(item) // Late sender from the previous cycle is not this cycle's row.
        #expect(calls == ["displayed"])
        coordinator.selectItem(try #require(menu.item(at: 1)))
        endTracking(coordinator, menu: menu)
        coordinator.drainAfterTracking()
        #expect(calls == ["displayed", "next"])
        coordinator.dismantle(button)
    }

    @Test func samePresentationReopenBeforeDrainRejectsOldSelectedRow() throws {
        var calls: [String] = []
        let (coordinator, button, menu) = fixture([
            .init(id: "same", title: "Same") { calls.append("original") }
        ])
        let oldItem = try #require(menu.item(at: 1))
        coordinator.menuWillOpen(menu)
        coordinator.selectItem(oldItem)
        coordinator.update(button, title: "Conversation actions", accessibilityIdentifier: "chat-actions",
            items: [.init(id: "same", title: "Same") { calls.append("replacement") }])
        endTracking(coordinator, menu: menu)
        coordinator.menuNeedsUpdate(menu) // A native reopen can precede the deferred drain.
        #expect(menu.item(at: 1) !== oldItem)
        coordinator.menuWillOpen(menu)
        coordinator.selectItem(oldItem)
        endTracking(coordinator, menu: menu)
        coordinator.drainAfterTracking()
        #expect(calls == ["original"])
        coordinator.dismantle(button)
    }

    @Test func changedPresentationUpdatesStateAndAvailability() throws {
        let (coordinator, button, menu) = fixture([.init(id: "one", title: "One") {}])
        coordinator.update(button, title: "Conversation actions", accessibilityIdentifier: "chat-actions",
            items: [.init(id: "one", title: "Changed", enabled: false, selected: true) {}])
        #expect(menu.item(at: 1)?.title == "Changed")
        #expect(menu.item(at: 1)?.isEnabled == false)
        #expect(menu.item(at: 1)?.state == .on)
        coordinator.update(button, title: "Empty", accessibilityIdentifier: "empty", items: [])
        #expect(!button.isEnabled)
        #expect(menu.items.count == 1)
        #expect(menu.item(at: 0)?.target !== coordinator)
        coordinator.update(button, title: "Ready", accessibilityIdentifier: "ready",
            items: [.init(id: "two", title: "Two") {}])
        #expect(button.isEnabled)
        #expect(button.title == "Ready")
        #expect(menu.item(at: 1)?.title == "Two")
        coordinator.dismantle(button)
    }

    @Test func idleUpdateAfterSelectedCycleRenewsRowsOnlyOnce() throws {
        var calls: [String] = []
        let (coordinator, button, menu) = fixture([
            .init(id: "same", title: "Same") { calls.append("original") }
        ])
        let oldItem = try #require(menu.item(at: 1))
        coordinator.menuWillOpen(menu)
        coordinator.selectItem(oldItem)
        endTracking(coordinator, menu: menu)
        coordinator.drainAfterTracking()
        func update() {
            coordinator.update(button, title: "Conversation actions", accessibilityIdentifier: "chat-actions",
                items: [.init(id: "same", title: "Same") { calls.append("replacement") }])
        }
        update()
        let newItem = try #require(menu.item(at: 1))
        #expect(newItem !== oldItem)
        update()
        #expect(menu.item(at: 1) === newItem)
        coordinator.menuWillOpen(menu)
        coordinator.selectItem(oldItem)
        endTracking(coordinator, menu: menu)
        coordinator.drainAfterTracking()
        #expect(calls == ["original"])
        coordinator.dismantle(button)
    }

    private func fixture(_ items: [ChatActionMenuItem]) ->
        (ChatActionMenu.Coordinator, NSPopUpButton, NSMenu) {
        let coordinator = ChatActionMenu.Coordinator()
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.usesItemFromMenu = true
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
        let displayed = try #require(menu.item(at: 1))
        coordinator.menuWillOpen(menu)

        coordinator.update(button, title: "Changed title", accessibilityIdentifier: "changed-id",
                           items: [.init(id: "candidate", title: "Intermediate") { calls.append("intermediate") }])
        coordinator.update(button, title: "Newest title", accessibilityIdentifier: "newest-id",
                           items: [.init(id: "candidate", title: "Newest") { calls.append("newest") }])
        #expect(menu.items.count == 2)
        #expect(menu.item(at: 1) === displayed)
        #expect(displayed.title == "Original")
        #expect(displayed.state == .on)
        #expect(button.title == "Conversation actions")

        coordinator.selectItem(displayed)
        #expect(calls.isEmpty)
        coordinator.menuDidClose(menu)
        #expect(menu.item(at: 1) === displayed)
        #expect(calls.isEmpty)
        coordinator.drainAfterTracking() // Closing alone is still inside native tracking.
        #expect(calls.isEmpty)
        #expect(menu.item(at: 1) === displayed)
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
        #expect(calls.isEmpty)
        coordinator.drainAfterTracking()
        #expect(calls == ["original"])
        #expect(menu.item(at: 1)?.title == "Newest")
        #expect(menu.item(at: 1) !== displayed)
        #expect(button.title == "Newest title")
        coordinator.dismantle(button)
    }

    @Test func selectionDispatchesAtMostOnceAfterBothLifecycleSignals() throws {
        var count = 0
        let (coordinator, button, menu) = fixture([
            .init(id: "one", title: "One") { count += 1 }
        ])
        let item = try #require(menu.item(at: 1))
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

    @Test func actionAfterCloseAndDrainUsesTheDisplayedCycle() throws {
        var calls: [String] = []
        let (coordinator, button, menu) = fixture([
            .init(id: "same", title: "Original") { calls.append("original") }
        ])
        let oldItem = try #require(menu.item(at: 1))
        coordinator.menuWillOpen(menu)
        coordinator.update(button, title: "Replacement", accessibilityIdentifier: "replacement",
                           items: [.init(id: "same", title: "New") { calls.append("new") }])
        endTracking(coordinator, menu: menu)
        coordinator.drainAfterTracking()
        let newItem = try #require(menu.item(at: 1))
        #expect(newItem !== oldItem)
        #expect(calls.isEmpty)

        coordinator.selectItem(oldItem) // AppKit may dispatch after end-tracking and the drain.
        coordinator.selectItem(oldItem)
        coordinator.selectItem(newItem)
        #expect(calls == ["original"])
        coordinator.dismantle(button)
    }

    @Test func actionAfterCloseBeforeEndWaitsForTrackingAndKeepsOriginal() throws {
        var calls: [String] = []
        let (coordinator, button, menu) = fixture([
            .init(id: "same", title: "Original") { calls.append("original") }
        ])
        let oldItem = try #require(menu.item(at: 1))
        coordinator.menuWillOpen(menu)
        coordinator.update(button, title: "Replacement", accessibilityIdentifier: "replacement",
                           items: [.init(id: "same", title: "New") { calls.append("new") }])
        coordinator.menuDidClose(menu)
        coordinator.selectItem(oldItem)
        coordinator.drainAfterTracking()
        #expect(calls.isEmpty)
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
        coordinator.drainAfterTracking()
        #expect(calls == ["original"])
        coordinator.dismantle(button)
    }

    @Test func escapeThenReopenInvalidatesTheEndedCycle() throws {
        var calls: [String] = []
        let (coordinator, button, menu) = fixture([
            .init(id: "same", title: "Original") { calls.append("original") }
        ])
        let oldItem = try #require(menu.item(at: 1))
        coordinator.menuWillOpen(menu)
        coordinator.update(button, title: "Replacement", accessibilityIdentifier: "replacement",
                           items: [.init(id: "same", title: "New") { calls.append("new") }])
        endTracking(coordinator, menu: menu) // Escape: no action was sent.
        #expect(menu.item(at: 1) === oldItem)
        #expect(calls.isEmpty)
        // AppKit asks for an update before the next opening.
        coordinator.menuNeedsUpdate(menu)
        let newItem = try #require(menu.item(at: 1))
        #expect(newItem !== oldItem)
        coordinator.menuWillOpen(menu)
        coordinator.selectItem(oldItem)
        coordinator.selectItem(newItem)
        endTracking(coordinator, menu: menu)
        coordinator.drainAfterTracking()
        #expect(calls == ["new"])
        coordinator.dismantle(button)
    }

    @Test func callbacksDoNotPublishRowsOrInvokeQueuedParentAction() throws {
        var calls: [String] = []
        let (coordinator, button, menu) = fixture([
            .init(id: "old", title: "Old") { calls.append("old") }
        ])
        let oldItem = try #require(menu.item(at: 1))
        coordinator.menuWillOpen(menu)
        coordinator.selectItem(oldItem)
        coordinator.update(button, title: "New", accessibilityIdentifier: "new",
                           items: [.init(id: "new", title: "New") { calls.append("new") }])
        coordinator.menuDidClose(menu)
        #expect(menu.item(at: 1) === oldItem)
        #expect(calls.isEmpty)
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)

        // Synthetic race: the next willOpen arrives before its deferred drain.
        coordinator.menuWillOpen(menu)
        #expect(menu.item(at: 1) === oldItem)
        #expect(calls.isEmpty)
        coordinator.menuNeedsUpdate(menu) // Documented menu update point.
        #expect(menu.item(at: 1)?.title == "New")
        #expect(calls.isEmpty)
        endTracking(coordinator, menu: menu)
        coordinator.drainAfterTracking()
        #expect(calls == ["old"])
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
        let leaf = try #require(menu.item(at: 1))
        let child = try #require(menu.item(at: 2)?.submenu?.item(at: 0))
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
        let oldItem = try #require(menu.item(at: 1))
        coordinator.menuWillOpen(menu)
        coordinator.selectItem(oldItem)
        coordinator.update(button, title: "Stale", accessibilityIdentifier: "stale",
                           items: [.init(id: "new", title: "New") { count += 10 }])
        coordinator.dismantle(button)
        endTracking(coordinator, menu: menu)
        coordinator.selectItem(oldItem)
        coordinator.drainAfterTracking()
        #expect(count == 0)
        #expect(menu.item(at: 1)?.title == "Old")
    }

    @Test func dismantleInvalidatesLateItemAfterDrain() throws {
        var count = 0
        let (coordinator, button, menu) = fixture([
            .init(id: "old", title: "Old") { count += 1 }
        ])
        let oldItem = try #require(menu.item(at: 1))
        coordinator.menuWillOpen(menu)
        coordinator.update(button, title: "New", accessibilityIdentifier: "new",
                           items: [.init(id: "new", title: "New") { count += 10 }])
        endTracking(coordinator, menu: menu)
        coordinator.drainAfterTracking()
        coordinator.dismantle(button)
        coordinator.selectItem(oldItem)
        #expect(count == 0)
    }
}
