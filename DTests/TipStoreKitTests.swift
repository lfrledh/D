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
    private func coldCheckpoint() throws -> URL {
        let raw = ProcessInfo.processInfo.environment["D_UI_TEST_SESSION"] ?? ""
        let id = try #require(UUID(uuidString: raw))
        return FileManager.default.temporaryDirectory.appendingPathComponent("D-Tip-cold-" + id.uuidString + ".json")
    }

    // Explicitly run these two stages in different test hosts. Ordinary suite
    // runs do not create or consume a cross-process test transaction.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["D_STOREKIT_COLD_STAGE"] == "prepare"))
    func coldUnfinishedPrepare() async throws {
        let file = try coldCheckpoint()
        try #require(!FileManager.default.fileExists(atPath: file.path))
        let session = try testSession()
        var prepared = false
        defer { if !prepared { session.clearTransactions() } }
        guard case .verified(let app) = try await AppTransaction.shared else {
            Issue.record("A verified local StoreKit app is required"); return
        }
        try #require(app.environment == .xcode && app.bundleID == Bundle.main.bundleIdentifier)
        let product = try #require(try await Product.products(for: ["d.localtest.tip.small"]).first)
        try #require(product.id == "d.localtest.tip.small" && product.type == .consumable)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        guard case .success(.verified(let transaction)) = try await product.purchase(confirmIn: window) else {
            Issue.record("Expected a verified local purchase"); return
        }
        try #require(transaction.environment == .xcode && transaction.appBundleID == app.bundleID && transaction.productID == product.id)
        try #require(session.allTransactions().contains { UInt64($0.identifier) == transaction.id })
        let checkpoint: [String: Any] = ["transactionID": String(transaction.id), "pid": ProcessInfo.processInfo.processIdentifier,
            "bundleID": app.bundleID, "created": Date().timeIntervalSince1970,
            "originalID": String(transaction.originalID), "purchaseDate": transaction.purchaseDate.timeIntervalSince1970,
            "productID": transaction.productID, "environment": transaction.environment.rawValue,
            "appTransactionID": transaction.appTransactionID]
        try JSONSerialization.data(withJSONObject: checkpoint).write(to: file, options: .atomic)
        prepared = true
        print("TIP_COLD_PREPARE pid=\(ProcessInfo.processInfo.processIdentifier) verifiedLocal=true acknowledged=false")
        // Intentionally neither finish nor clear. The next host must prove the
        // platform retained this transaction before testing D's recovery.
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["D_STOREKIT_COLD_STAGE"] == "recover"))
    func coldUnfinishedRecover() async throws {
        let file = try coldCheckpoint()
        let checkpoint = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        defer { try? FileManager.default.removeItem(at: file) }
        let previousPID = try #require(checkpoint["pid"] as? Int)
        try #require(previousPID != Int(ProcessInfo.processInfo.processIdentifier))
        try #require(checkpoint["bundleID"] as? String == Bundle.main.bundleIdentifier)
        let created = try #require(checkpoint["created"] as? Double)
        try #require((0...1_800).contains(Date().timeIntervalSince1970 - created))
        let id = try #require((checkpoint["transactionID"] as? String).flatMap(UInt64.init))
        func matches(_ t: Transaction) -> Bool {
            t.id == id && t.environment == .xcode && t.appBundleID == Bundle.main.bundleIdentifier
                && t.productID == "d.localtest.tip.small"
                && String(t.originalID) == checkpoint["originalID"] as? String
                && t.purchaseDate.timeIntervalSince1970 == checkpoint["purchaseDate"] as? Double
                && t.productID == checkpoint["productID"] as? String
                && t.environment.rawValue == checkpoint["environment"] as? String
                && t.appTransactionID == checkpoint["appTransactionID"] as? String
        }
        let config = try #require(Bundle(for: TipStoreKitBundle.self).url(forResource: "Tips", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: config)
        defer { session.clearTransactions() }
        // No reset, clear or new purchase before checking persistence.
        let retained = session.allTransactions().contains { UInt64($0.identifier) == id }
        var unfinishedMatch = false, unfinishedCount = 0
        for await result in Transaction.unfinished {
            unfinishedCount += 1
            if case .verified(let t) = result {
                unfinishedMatch = unfinishedMatch || matches(t)
            }
        }
        print("TIP_COLD_RECOVER oldPID=\(previousPID) pid=\(ProcessInfo.processInfo.processIdentifier) platformRetained=\(retained) unfinishedTotal=\(unfinishedCount) exactUnfinished=\(unfinishedMatch)")
        try #require(retained && unfinishedMatch, "Cross-host platform precondition failed; do not substitute or repurchase a transaction")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("D-Tip-cold-owner-" + UUID().uuidString)
        defer { removeTestRecords(root) }
        let store = owner(root); store.start()
        let journal = root.appendingPathComponent("tips.json")
        try await wait("cross-host recovery", store: store) { FileManager.default.fileExists(atPath: journal.path) }
        let records = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as? [String: [String: Any]])
        #expect(records.count == 1 && records.values.first?["transactionID"] as? String == String(id))
        var remainsUnfinished = true, remainingTotal = 0, remainingUnverified = 0
        for index in 0..<10 {
            remainsUnfinished = false; remainingTotal = 0; remainingUnverified = 0
            for await result in Transaction.unfinished {
                remainingTotal += 1
                switch result {
                case .verified(let t): if matches(t) { remainsUnfinished = true }
                case .unverified: remainingUnverified += 1
                }
            }
            if remainingTotal == 0 { break }
            if index < 9 { try await Task.sleep(for: .milliseconds(100)) }
        }
        print("TIP_COLD_ACK remainingTotal=\(remainingTotal) remainingUnverified=\(remainingUnverified) exactRemaining=\(remainsUnfinished)")
        #expect(!remainsUnfinished && remainingTotal == 0 && remainingUnverified == 0, "Journal recovery alone does not prove acknowledgement")
        #expect(session.allTransactions().count == 1, "Recovery must not purchase again")
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
        var unfinishedIDs: [UInt64] = [], unfinishedTotal = 0, unfinishedUnverified = 0
        for await result in Transaction.unfinished {
            unfinishedTotal += 1
            switch result {
            case .verified(let t): unfinishedIDs.append(t.id)
            case .unverified: unfinishedUnverified += 1
            }
        }
        print("TIP_ISOLATED_FIRST id=\(first.id) unfinished=\(unfinishedIDs) total=\(unfinishedTotal) unverified=\(unfinishedUnverified) rawUpdates=\(observed)")
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
        var revokedIDs: [UInt64] = [], updateTotal = 0, updateUnverified = 0
        let observer = Task { @MainActor in
            for await result in Transaction.updates {
                if Task.isCancelled { return }
                updateTotal += 1
                switch result {
                case .verified(let t): if t.revocationDate != nil { revokedIDs.append(t.id) }
                case .unverified: updateUnverified += 1
                }
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
        // Freeze the automatic-listener result before explicit history reads,
        // which may themselves cause the local StoreKit service to synchronize.
        let automaticRevokedIDs = revokedIDs, automaticStatus = store.status
        let automaticUpdateTotal = updateTotal, automaticUpdateUnverified = updateUnverified
        var historyTotal = 0, historyUnverified = 0, historyTargetRevoked = false
        for await item in Transaction.all {
            historyTotal += 1
            switch item {
            case .verified(let t): if t.id == id { historyTargetRevoked = t.revocationDate != nil }
            case .unverified: historyUnverified += 1
            }
        }
        var latestVerified = false, latestTargetRevoked = false
        if case .verified(let t)? = await Transaction.latest(for: "d.localtest.tip.small") {
            latestVerified = true; latestTargetRevoked = t.id == id && t.revocationDate != nil
        }
        print("TIP_ISOLATED_REFUND id=\(id) rawRevoked=\(automaticRevokedIDs) updateTotal=\(automaticUpdateTotal) updateUnverified=\(automaticUpdateUnverified) journalRevoked=\(String(describing: journalRevoked)) systemRevoked=\(systemRevoked) historyTotal=\(historyTotal) historyUnverified=\(historyUnverified) historyTargetRevoked=\(historyTargetRevoked) latestVerified=\(latestVerified) latestTargetRevoked=\(latestTargetRevoked)")
        #expect(automaticRevokedIDs.contains(id))
        #expect(records.values.first { $0["transactionID"] as? String == String(id) }?["revoked"] as? Bool == true)
        #expect(automaticStatus == .idle)
    }
    /// A single platform observer, without a TipStore owner, bounds the local
    /// refund-delivery failure independently of D's merge and persistence path.
    @Test func isolatedRawRefundWithoutOwner() async throws {
        let session = try testSession(); defer { session.clearTransactions() }
        guard case .verified(let app) = try await AppTransaction.shared else {
            Issue.record("A verified local StoreKit app is required before purchasing"); return
        }
        try #require(app.environment == .xcode && app.bundleID == Bundle.main.bundleIdentifier)
        let product = try #require(try await Product.products(for: ["d.localtest.tip.small"]).first)
        try #require(product.id == "d.localtest.tip.small" && product.type == .consumable)
        var revokedIDs: [UInt64] = [], updateTotal = 0, updateUnverified = 0
        let observer = Task { @MainActor in
            for await result in Transaction.updates {
                if Task.isCancelled { return }
                updateTotal += 1
                switch result {
                case .verified(let t): if t.revocationDate != nil { revokedIDs.append(t.id) }
                case .unverified: updateUnverified += 1
                }
            }
        }
        defer { observer.cancel() }
        await Task.yield()
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        guard case .success(.verified(let purchase)) = try await product.purchase(confirmIn: window) else {
            Issue.record("Expected a verified local purchase without a D owner"); return
        }
        try #require(purchase.environment == .xcode && purchase.productID == product.id && purchase.appBundleID == app.bundleID)
        await purchase.finish()
        let transaction = try #require(session.allTransactions().first { UInt64($0.identifier) == purchase.id })
        let beforeRefundTotal = updateTotal, beforeRefundUnverified = updateUnverified
        try session.refundTransaction(identifier: transaction.identifier)
        for _ in 0..<100 {
            if revokedIDs.contains(purchase.id) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let automaticIDs = revokedIDs
        let automaticDelta = updateTotal - beforeRefundTotal
        let automaticUnverifiedDelta = updateUnverified - beforeRefundUnverified
        let systemRevoked = session.allTransactions().first { UInt64($0.identifier) == purchase.id }?.cancelDate != nil
        // History reads happen only after the automatic observation is frozen.
        var historyTargetRevoked = false
        for await result in Transaction.all {
            if case .verified(let t) = result, t.id == purchase.id { historyTargetRevoked = t.revocationDate != nil }
        }
        var latestTargetRevoked = false
        if case .verified(let t)? = await Transaction.latest(for: product.id) {
            latestTargetRevoked = t.id == purchase.id && t.revocationDate != nil
        }
        print("TIP_RAW_REFUND id=\(purchase.id) preTotal=\(beforeRefundTotal) updateDelta=\(automaticDelta) unverifiedDelta=\(automaticUnverifiedDelta) automaticRevoked=\(automaticIDs) systemRevoked=\(systemRevoked) historyRevoked=\(historyTargetRevoked) latestRevoked=\(latestTargetRevoked)")
        #expect(systemRevoked && historyTargetRevoked && latestTargetRevoked)
        #expect(automaticIDs.contains(purchase.id), "The raw automatic path must deliver the refund without explicit history reads")
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
        let expectedIDs = Set(initial.values.compactMap { $0["transactionID"] as? String })
        var platformIDs: Set<String> = []
        // Establish the platform recovery source before removing local data. Xcode's first
        // immediate all-sequence has previously omitted the just-finished second purchase.
        for index in 0..<5 {
            platformIDs = []
            for await result in Transaction.all {
                if case .verified(let transaction) = result { platformIDs.insert(String(transaction.id)) }
            }
            if expectedIDs.isSubset(of: platformIDs) { break }
            if index < 4 { try await Task.sleep(for: .milliseconds(200)) }
        }
        try #require(expectedIDs.isSubset(of: platformIDs), "Verified platform history must contain the two finished transactions before testing local-data loss")
        try FileManager.default.removeItem(at: file)
        let cold = owner(root); await cold.loadProducts()
        #expect(cold.recoveryStatus == .ready)
        let restored = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: [String: Any]])
        #expect(Set(restored.keys) == Set(initial.keys))
        #expect(cold.status != .thanked, "Historical recovery is not a new payment")
        #expect(session.allTransactions().count == transactionCount, "Recovery never starts another purchase")
    }

    @Test func verifiedRefundIsRecoveredByExplicitHistoryReload() async throws {
        let session = try testSession(); defer { session.clearTransactions() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("D-Tip-refund-history-" + UUID().uuidString)
        defer { removeTestRecords(root) }
        let store = owner(root); store.start(); await store.loadProducts()
        #expect(store.localTest)
        store.selectedID = try #require(store.products.first?.id)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        await store.purchase(confirmIn: window)
        #expect(store.status == .thanked, Comment(rawValue: store.diagnostic ?? "no diagnostic"))
        let transaction = try #require(session.allTransactions().first)
        try session.refundTransaction(identifier: transaction.identifier)
        var platformHasRevocation = false
        for index in 0..<5 {
            for await result in Transaction.all {
                if case .verified(let value) = result, value.id == UInt64(transaction.identifier), value.revocationDate != nil {
                    platformHasRevocation = true
                }
            }
            if platformHasRevocation { break }
            if index < 4 { try await Task.sleep(for: .milliseconds(200)) }
        }
        try #require(platformHasRevocation, "The verified platform history must expose revocation before testing D's explicit reload")
        await store.loadProducts()
        #expect(store.recoveryStatus == .ready)
        let records = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("tips.json"))) as? [String: [String: Any]])
        #expect(records.count == 1 && records.values.first?["revoked"] as? Bool == true)
        #expect(records.values.first?["revocationDate"] != nil)
        #expect(session.allTransactions().count == 1, "Refund recovery never purchases again")
    }

}
