import AppKit
import Foundation
import StoreKit
import StoreKitTest
import Testing
import UI

private final class TipStoreKitBundle: NSObject { }

/// Actual StoreKit APIs under an explicit Xcode local configuration. No App Store account or charge.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["D_STOREKIT_TESTS"] == "1"), .serialized)
@MainActor struct TipStoreKitTests {
    private func testSession() throws -> SKTestSession {
        let file = try #require(Bundle(for: TipStoreKitBundle.self).url(forResource: "Tips", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: file)
        session.resetToDefaultState(); session.clearTransactions(); session.disableDialogs = true
        return session
    }
    private func owner(_ root: URL) -> TipStore {
        TipStore(productIDs:["d.localtest.tip.small"],bundleID:Bundle.main.bundleIdentifier ?? "",journalURL:root.appendingPathComponent("tips.json"),localTest:true)
    }
    private func wait(_ label: String, store: TipStore, _ condition: () -> Bool) async throws {
        for _ in 0..<100 { if condition() { return }; try await Task.sleep(for:.milliseconds(50)) }
        #expect(condition(), Comment(rawValue: label + ": " + store.status.rawValue + " / " + (store.diagnostic ?? "no diagnostic")))
    }
    @Test func actualProductsPurchaseAndOwnerUnfinishedRecovery() async throws {
        let session = try testSession()
        defer { session.clearTransactions() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("D-StoreKit-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store = owner(root)
        await store.loadProducts()
        #expect(store.products.count == 1 && store.products.first?.type == .consumable)
        #expect(store.localTest, "Local status requires verified StoreKit app environment")
        let product = try #require(store.products.first)
        #expect(!product.displayPrice.isEmpty)
        store.selectedID = product.id
        let window = NSWindow(contentRect:.init(x:0,y:0,width:600,height:400),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        await store.purchase(confirmIn:window)
        #expect(store.status == .thanked)
        let firstBytes = try Data(contentsOf:root.appendingPathComponent("tips.json"))
        #expect(try JSONSerialization.jsonObject(with:firstBytes) is [String:Any])
        // A second transaction for the same consumable remains a valid independent tip.
        await store.purchase(confirmIn:window)
        #expect(store.status == .thanked)
        let records = try #require(try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("tips.json"))) as? [String:Any])
        #expect(records.count == 2)
        // Simulate process exit after StoreKit accepted but before D acknowledged.
        let result = try await product.purchase(confirmIn: window)
        guard case .success(.verified(let unfinished)) = result else {
            Issue.record("Expected a verified local transaction before simulated interruption"); return
        }
        #expect(records[String(unfinished.id)] == nil, "The interruption must concern a new transaction, not a previously finished ID")
        var unfinishedCount = 0, unfinishedContainsCurrent = false
        for await item in Transaction.unfinished {
            unfinishedCount += 1
            if case .verified(let t) = item, t.id == unfinished.id { unfinishedContainsCurrent = true }
        }
        print("TIP_LOCAL_RECOVERY environment=\(unfinished.environment.rawValue) unfinished=\(unfinishedCount) containsCurrent=\(unfinishedContainsCurrent)")
        let cold = owner(root); cold.start()
        try await wait("unfinished recovery", store: cold) { cold.status == .thanked }
        let recovered = try #require(try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("tips.json"))) as? [String:Any])
        #expect(recovered.count == 3 && recovered[String(unfinished.id)] != nil)
        #expect(session.allTransactions().count == 3, "Recovery must not purchase again")
    }
    @Test func actualCancellationPendingApprovalAndRefund() async throws {
        let session = try testSession(); defer { session.clearTransactions() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("D-StoreKit-states-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store = owner(root); store.start(); await store.loadProducts()
        store.selectedID = try #require(store.products.first?.id)
        let window = NSWindow(contentRect:.init(x:0,y:0,width:600,height:400),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        try await session.setSimulatedError(.generic(.userCancelled), forAPI: .purchase)
        await store.purchase(confirmIn:window)
        #expect(store.status == .cancelled)
        #expect(!FileManager.default.fileExists(atPath:root.appendingPathComponent("tips.json").path))
        try await session.setSimulatedError(nil, forAPI: .purchase)
        session.askToBuyEnabled = true
        await store.purchase(confirmIn:window)
        #expect(store.status == .pending)
        #expect(!FileManager.default.fileExists(atPath:root.appendingPathComponent("tips.json").path))
        let pending = try #require(session.allTransactions().last)
        try session.approveAskToBuyTransaction(identifier:pending.identifier)
        try await wait("pending approval", store: store) { store.status == .thanked }
        let transaction = try #require(session.allTransactions().last)
        try session.refundTransaction(identifier:transaction.identifier)
        try await wait("refund", store: store) { store.status == .idle }
        if case .verified(let latest)? = await Transaction.latest(for: "d.localtest.tip.small") {
            print("TIP_LOCAL_REFUND latestRevoked=\(latest.revocationDate != nil) environment=\(latest.environment.rawValue)")
        } else { print("TIP_LOCAL_REFUND no verified latest transaction") }
    }
}
