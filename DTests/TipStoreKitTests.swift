import AppKit
import Foundation
import CryptoKit
import Security
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
    private func removeTestRecords(_ root: URL) {
        let url = root.appendingPathComponent("tips.json")
        let scope = SHA256.hash(data: Data(url.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "") + ".verified-support-receipts",
            kSecAttrAccount as String: scope]
        let status = SecItemDelete(query as CFDictionary)
        #expect(status == errSecSuccess || status == errSecItemNotFound || status == errSecMissingEntitlement)
        try? FileManager.default.removeItem(at: root)
    }
    private func wait(_ label: String, store: TipStore, _ condition: () -> Bool) async throws {
        for _ in 0..<100 { if condition() { return }; try await Task.sleep(for:.milliseconds(50)) }
        #expect(condition(), Comment(rawValue: label + ": " + store.status.rawValue + " / " + (store.diagnostic ?? "no diagnostic")))
    }
    @Test func actualProductsPurchaseAndOwnerUnfinishedRecovery() async throws {
        let session = try testSession()
        defer { session.clearTransactions() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("D-StoreKit-" + UUID().uuidString)
        defer { removeTestRecords(root) }
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
        #expect(store.status == .thanked, Comment(rawValue: store.diagnostic ?? "no diagnostic"))
        let firstBytes = try Data(contentsOf:root.appendingPathComponent("tips.json"))
        #expect(try JSONSerialization.jsonObject(with:firstBytes) is [String:Any])
        // A second transaction for the same consumable remains a valid independent tip.
        await store.purchase(confirmIn:window)
        #expect(store.status == .thanked, Comment(rawValue: store.diagnostic ?? "no diagnostic"))
        let records = try #require(try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("tips.json"))) as? [String:Any])
        #expect(records.count == 2)
        // Simulate process exit after StoreKit accepted but before D acknowledged.
        let result = try await product.purchase(confirmIn: window)
        guard case .success(.verified(let unfinished)) = result else {
            Issue.record("Expected a verified local transaction before simulated interruption"); return
        }
        #expect(!records.values.contains { ($0 as? [String: Any])?["transactionID"] as? String == String(unfinished.id) }, "The interruption must concern a new transaction, not a previously finished ID")
        print("TIP_LOCAL_THIRD id=\(unfinished.id) recorded=\(records.keys.sorted()) testTransactions=\(session.allTransactions().map { "\($0.identifier):\($0.state.rawValue)" })")
        var unfinishedCount = 0, unfinishedContainsCurrent = false
        for await item in Transaction.unfinished {
            unfinishedCount += 1
            if case .verified(let t) = item, t.id == unfinished.id { unfinishedContainsCurrent = true }
        }
        print("TIP_LOCAL_RECOVERY environment=\(unfinished.environment.rawValue) unfinished=\(unfinishedCount) containsCurrent=\(unfinishedContainsCurrent)")
        let cold = owner(root); cold.start()
        try await wait("unfinished recovery", store: cold) { (try? Data(contentsOf: root.appendingPathComponent("tips.json"))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?.count == 3 }
        let recovered = try #require(try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("tips.json"))) as? [String:Any])
        #expect(recovered.count == 3 && recovered.values.contains { ($0 as? [String: Any])?["transactionID"] as? String == String(unfinished.id) })
        #expect(session.allTransactions().count == 3, "Recovery must not purchase again")
    }
    @Test func actualCancellationPendingApprovalAndRefund() async throws {
        let session = try testSession(); defer { session.clearTransactions() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("D-StoreKit-states-" + UUID().uuidString)
        defer { removeTestRecords(root) }
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
        #expect(store.status == .pending && !store.canPurchase)
        #expect(!FileManager.default.fileExists(atPath:root.appendingPathComponent("tips.json").path))
        let pending = try #require(session.allTransactions().last)
        try session.approveAskToBuyTransaction(identifier:pending.identifier)
        try await wait("pending approval", store: store) { store.status == .thanked }
        let accepted = try #require(try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("tips.json"))) as? [String:Any])
        let acceptedID = try #require(accepted.values.compactMap { ($0 as? [String: Any])?["transactionID"] as? String }.first.flatMap(UInt64.init))
        let transaction = try #require(session.allTransactions().first { UInt64($0.identifier) == acceptedID })
        try session.refundTransaction(identifier:transaction.identifier)
        print("TIP_LOCAL_REFUND requested=\(acceptedID) facts=\(session.allTransactions().map { "\($0.identifier):\($0.state.rawValue):\($0.cancelDate != nil)" })")
        try await wait("refund", store: store) { store.status == .idle }
        if case .verified(let latest)? = await Transaction.latest(for: "d.localtest.tip.small") {
            print("TIP_LOCAL_REFUND latestRevoked=\(latest.revocationDate != nil) environment=\(latest.environment.rawValue)")
        } else { print("TIP_LOCAL_REFUND no verified latest transaction") }
    }

    // Run each isolated test in a fresh test host. These observers never acknowledge
    // transactions; they distinguish StoreKit delivery from D's journal handling.
    @Test func isolatedFirstUnfinishedRecovery() async throws {
        let session = try testSession(); defer { session.clearTransactions() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("D-Tip-first-" + UUID().uuidString)
        defer { removeTestRecords(root) }
        let store = owner(root); await store.loadProducts()
        #expect(store.localTest)
        let product = try #require(store.products.first)
        var observed: [UInt64] = []
        let observer = Task { @MainActor in
            for await result in Transaction.updates {
                if Task.isCancelled { return }
                if case .verified(let t) = result { observed.append(t.id) }
            }
        }
        defer { observer.cancel() }
        await Task.yield()
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        guard case .success(.verified(let first)) = try await product.purchase(confirmIn: window) else {
            Issue.record("Expected the first verified local purchase"); return
        }
        var unfinishedIDs: [UInt64] = []
        for await result in Transaction.unfinished {
            if case .verified(let t) = result { unfinishedIDs.append(t.id) }
        }
        print("TIP_ISOLATED_FIRST id=\(first.id) unfinished=\(unfinishedIDs) rawUpdates=\(observed)")
        #expect(unfinishedIDs.contains(first.id))
        store.start()
        try await wait("isolated first recovery", store: store) { FileManager.default.fileExists(atPath: root.appendingPathComponent("tips.json").path) }
        let file = root.appendingPathComponent("tips.json")
        #expect(FileManager.default.fileExists(atPath: file.path))
        if FileManager.default.fileExists(atPath: file.path) {
            let records = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            #expect(records.count == 1 && records.values.contains { ($0 as? [String: Any])?["transactionID"] as? String == String(first.id) })
        }
        #expect(session.allTransactions().count == 1, "Recovery never purchases again")
    }

    @Test func isolatedRefundRecorded() async throws {
        let session = try testSession(); defer { session.clearTransactions() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("D-Tip-refund-" + UUID().uuidString)
        defer { removeTestRecords(root) }
        let store = owner(root); store.start(); await store.loadProducts()
        #expect(store.localTest)
        store.selectedID = try #require(store.products.first?.id)
        var revokedIDs: [UInt64] = []
        let observer = Task { @MainActor in
            for await result in Transaction.updates {
                if Task.isCancelled { return }
                if case .verified(let t) = result, t.revocationDate != nil { revokedIDs.append(t.id) }
            }
        }
        defer { observer.cancel() }
        await Task.yield()
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        await store.purchase(confirmIn: window)
        #expect(store.status == .thanked, Comment(rawValue: store.diagnostic ?? "no diagnostic"))
        let file = root.appendingPathComponent("tips.json")
        let initial = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let id = try #require(initial.values.compactMap { ($0 as? [String: Any])?["transactionID"] as? String }.first.flatMap(UInt64.init))
        let transaction = try #require(session.allTransactions().first { UInt64($0.identifier) == id })
        try session.refundTransaction(identifier: transaction.identifier)
        for _ in 0..<100 {
            if revokedIDs.contains(id), store.status == .idle { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let records = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: [String: Any]])
        let journalRevoked = records.values.first { $0["transactionID"] as? String == String(id) }?["revoked"] as? Bool
        let systemRevoked = session.allTransactions().first { UInt64($0.identifier) == id }?.cancelDate != nil
        print("TIP_ISOLATED_REFUND id=\(id) rawRevoked=\(revokedIDs) journalRevoked=\(String(describing: journalRevoked)) systemRevoked=\(systemRevoked)")
        #expect(revokedIDs.contains(id))
        #expect(records.values.first { $0["transactionID"] as? String == String(id) }?["revoked"] as? Bool == true)
        #expect(store.status == .idle)
    }
    @Test func verifiedFinishedConsumablesRestoreFromStoreKitAfterLocalJournalLoss() async throws {
        let session = try testSession(); defer { session.clearTransactions() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("D-Tip-finished-history-" + UUID().uuidString)
        defer { removeTestRecords(root) }
        let store = owner(root); await store.loadProducts()
        #expect(store.localTest)
        store.selectedID = try #require(store.products.first?.id)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        await store.purchase(confirmIn: window)
        #expect(store.status == .thanked, Comment(rawValue: store.diagnostic ?? "no diagnostic"))
        await store.purchase(confirmIn: window)
        #expect(store.status == .thanked, Comment(rawValue: store.diagnostic ?? "no diagnostic"))
        let file = root.appendingPathComponent("tips.json")
        let initial = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: [String: Any]])
        #expect(initial.count == 2)
        #expect(initial.values.allSatisfy { $0["purchaseDate"] != nil && $0["accountID"] != nil })
        let transactionCount = session.allTransactions().count
        try FileManager.default.removeItem(at: file)
        let cold = owner(root); await cold.loadProducts()
        #expect(cold.recoveryStatus == .ready)
        let restored = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: [String: Any]])
        #expect(Set(restored.keys) == Set(initial.keys))
        #expect(cold.status != .thanked, "Historical recovery is not a new payment")
        #expect(session.allTransactions().count == transactionCount, "Recovery never starts another purchase")
    }

}
