import AppKit
import Foundation
import CryptoKit
import Security
import StoreKit
import StoreKitTest
import Testing
import UI
import SwiftUI

private typealias Transaction = StoreKit.Transaction

private final class TipStoreKitBundle: NSObject { }

/// Actual StoreKit APIs under an explicit Xcode local configuration. No App Store account or charge.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["D_STOREKIT_TESTS"] == "1"), .serialized)
@MainActor struct TipStoreKitTests {
    @Test(arguments: ["USD", "EUR", "GBP", "JPY", "CNY"])
    func localStorefrontReturnsApprovedTierAmountsWithItsOwnFormatting(currency: String) async throws {
        // Local configuration values are placeholders, not a readback of formal
        // price points. One representative EUR storefront is a formatting test.
        let cases: [String: (String, String, [String])] = [
            "USD": ("USA", "en_US", ["1", "5", "10", "50", "100"]),
            "EUR": ("DEU", "de_DE", ["1", "5", "10", "50", "100"]),
            "GBP": ("GBR", "en_GB", ["1", "5", "10", "50", "100"]),
            "JPY": ("JPN", "ja_JP", ["100", "500", "1000", "5000", "10000"]),
            "CNY": ("CHN", "zh_CN", ["5", "10", "20", "50", "100"])
        ]
        let (storefront, locale, amounts) = try #require(cases[currency])
        let original = try #require(Bundle(for: TipStoreKitBundle.self).url(forResource: "Tips", withExtension: "storekit"))
        var configuration = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: original)) as? [String: Any])
        var rows = try #require(configuration["products"] as? [[String: Any]])
        try #require(rows.count == 5)
        for index in rows.indices { rows[index]["displayPrice"] = amounts[index] }
        configuration["products"] = rows
        var settings = try #require(configuration["settings"] as? [String: Any])
        settings["_storefront"] = storefront; settings["_locale"] = locale; configuration["settings"] = settings
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("D-Tip-" + UUID().uuidString + ".storekit")
        try JSONSerialization.data(withJSONObject: configuration).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let session = try SKTestSession(contentsOf: file)
        session.resetToDefaultState(); session.clearTransactions(); session.disableDialogs = true
        session.storefront = storefront
        defer { session.clearTransactions() }
        let ids = Set((1...5).map { "d.localtest.tip.tier\($0)" })
        let products = try await Product.products(for: ids).sorted { $0.id < $1.id }
        try #require(products.count == 5)
        for (index, product) in products.enumerated() {
            #expect(product.id == "d.localtest.tip.tier\(index + 1)")
            #expect(product.price == Decimal(string: amounts[index]))
            #expect(product.priceFormatStyle.currencyCode == currency)
            #expect(!product.displayPrice.isEmpty)
            print("TIP_CURRENCY_LOCAL \(currency) \(product.id) \(product.displayPrice)")
        }
        #expect(session.allTransactions().isEmpty)
    }
    @Test func fiveActualTierSelectionsPurchaseExactProductsAndJournalReopenWithoutRepurchase() async throws {
        let session = try testSession(); defer { session.clearTransactions() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("D-StoreKit-five-" + UUID().uuidString)
        defer { removeTestRecords(root) }
        let ids = Set((1...5).map { "d.localtest.tip.tier\($0)" })
        let store = TipStore(productIDs: ids, bundleID: Bundle.main.bundleIdentifier ?? "",
                             journalURL: root.appendingPathComponent("tips.json"), localTest: true)
        store.start(); await store.loadProducts()
        try #require(store.products.count == 5 && store.catalogStatus == .available && store.localTest)
        let expected = [Decimal(1), 5, 10, 50, 100]
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        for (index, product) in store.products.enumerated() {
            #expect(product.id == "d.localtest.tip.tier\(index + 1)" && product.type == .consumable)
            #expect(product.price == expected[index] && product.priceFormatStyle.currencyCode == "USD")
            #expect(!product.displayPrice.isEmpty)
            store.selectedID = product.id
            #expect(store.selectedProduct?.id == product.id && store.canPurchase)
            await store.purchase(confirmIn: window)
            try #require(store.status == .thanked, Comment(rawValue: store.diagnostic ?? "Payment did not complete"))
            // Store's public purchase path can only acknowledge a verified SDK
            // result after persistence and finish. Finished consumables need not
            // appear in Transaction.latest; compare its exact durable receipt to
            // the independent local platform transaction instead.
            let journal = try receiptRecords(root.appendingPathComponent("tips.json"))
            let receipt = try #require(journal.values.first { $0["productID"] as? String == product.id })
            let transactionID = try #require((receipt["transactionID"] as? String).flatMap(UInt64.init))
            let transaction = try #require(session.allTransactions().first { UInt64($0.identifier) == transactionID })
            #expect(transaction.productIdentifier == product.id && transaction.state == .purchased)
            #expect(receipt["bundleID"] as? String == Bundle.main.bundleIdentifier)
            #expect(receipt["currency"] as? String == "USD" && receipt["environment"] as? String == AppStore.Environment.xcode.rawValue)
            let amount = try #require(receipt["amount"] as? NSNumber)
            #expect(amount.decimalValue == expected[index])
        }
        let records = try receiptRecords(root.appendingPathComponent("tips.json"))
        #expect(records.count == 5 && Set(records.values.compactMap { $0["productID"] as? String }) == ids)
        await store.recoverHistory(recheckAccount: true)
        let cold = TipStore(productIDs: ids, bundleID: Bundle.main.bundleIdentifier ?? "",
                            journalURL: root.appendingPathComponent("tips.json"), localTest: true)
        await cold.loadProducts()
        let after = try receiptRecords(root.appendingPathComponent("tips.json"))
        #expect(after.count == 5 && session.allTransactions().count == 5)
        #expect(Set(after.keys) == Set(records.keys))
        print("TIP_FIVE exactIDs=5 verifiedLocal=5 recordKeysUnchanged=true purchaseCount=5")
    }
    /// Explicit attended capture only; never a normal suite delay or a real payment.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["D_STOREKIT_PANEL_CAPTURE"] == "1"))
    func localFiveTierPanelNativeCapture() async throws {
        let session = try testSession(); defer { session.clearTransactions() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("D-Tip-panel-" + UUID().uuidString)
        defer { removeTestRecords(root) }
        let store = TipStore(productIDs: Set((1...5).map { "d.localtest.tip.tier\($0)" }),
                             bundleID: Bundle.main.bundleIdentifier ?? "", journalURL: root.appendingPathComponent("tips.json"), localTest: true)
        await store.loadProducts()
        try #require(store.products.count == 5 && store.localTest)
        let suite = "D.TipPanel." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let language = UILanguageStore(settings: defaults, directory: root.appendingPathComponent("LanguagePacks"))
        let window = NSWindow(contentRect: .init(x: 150, y: 150, width: 640, height: 640), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { store.presented = false; window.close() }
        window.contentView = NSHostingView(rootView: Text("StoreKit local test · no real charge").frame(maxWidth: .infinity, maxHeight: .infinity)
            .modifier(TipPresenter(owner: store)).environment(\.dLanguageStore, language))
        for locale in ["zh-Hans", "en"] {
            try language.select(locale); window.title = "D Tip QA " + locale
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            store.selectedID = "d.localtest.tip.tier4"; store.presented = true
            try await Task.sleep(for: .seconds(1))
            print("TIP_PANEL_READY language=\(locale) pid=\(ProcessInfo.processInfo.processIdentifier) window=\(window.windowNumber)")
            fflush(stdout)
            try await Task.sleep(for: .seconds(24))
        }
        #expect(session.allTransactions().isEmpty, "Visual capture never pays")
    }
    private func journalObject(_ file: URL) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    }
    private func receiptRecords(_ file: URL) throws -> [String: [String: Any]] {
        let object = try journalObject(file)
        if object["version"] != nil {
            try #require(object["version"] as? Int == 1)
            return try #require(object["receipts"] as? [String: [String: Any]])
        }
        return try #require(object as? [String: [String: Any]])
    }
    private func attemptRecords(_ file: URL) throws -> [String: [String: Any]] {
        try #require(journalObject(file)["attempts"] as? [String: [String: Any]])
    }

    @Test func requestWriteFailureMakesZeroActualStoreKitPurchasesThenOneExplicitRetry() async throws {
        let session = try testSession(); defer { session.clearTransactions() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("D-Tip-request-failure-" + UUID().uuidString)
        defer { removeTestRecords(root) }
        try Data("controlled file blocks journal directory".utf8).write(to: root)
        let store = owner(root); await store.loadProducts()
        store.selectedID = try #require(store.products.first?.id)
        try #require(store.canPurchase)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        await store.purchase(confirmIn: window)
        #expect(store.status == .failed && session.allTransactions().isEmpty)
        try FileManager.default.removeItem(at: root)
        await store.purchase(confirmIn: window)
        #expect(store.status == .thanked && session.allTransactions().count == 1)
        let file = root.appendingPathComponent("tips.json")
        let receipts = try receiptRecords(file), attempts = try attemptRecords(file)
        let receiptKey = try #require(receipts.keys.first), attempt = try #require(attempts.values.first)
        #expect(receipts.count == 1 && attempts.count == 1 && attempt["phase"] as? String == "completed")
        #expect(attempt["receiptKey"] as? String == receiptKey)
        #expect(attempt["productID"] as? String == store.selectedID)
        print("TIP_REQUEST_WRITE_FAILURE actualPurchasesBeforeRepair=0 afterExplicitRetry=1 exactAssociation=true")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["D_STOREKIT_COLD_STAGE"] == "pending-prepare"))
    func coldPendingRequestPrepare() async throws {
        let file = try coldCheckpoint(), root = file.deletingPathExtension().appendingPathExtension("request")
        try #require(!FileManager.default.fileExists(atPath: file.path) && !FileManager.default.fileExists(atPath: root.path))
        let session = try testSession(); session.askToBuyEnabled = true
        var prepared = false
        defer { if !prepared { session.clearTransactions(); removeTestRecords(root) } }
        let store = owner(root); await store.loadProducts()
        store.selectedID = try #require(store.products.first?.id)
        try #require(store.localTest && store.canPurchase)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        await store.purchase(confirmIn: window)
        try #require(store.status == .pending && !store.canPurchase)
        let journal = root.appendingPathComponent("tips.json"), attempts = try attemptRecords(journal)
        let id = try #require(attempts.keys.first), request = try #require(attempts[id])
        try #require(attempts.count == 1 && request["phase"] as? String == "pending" && request["receiptKey"] == nil)
        try #require(try receiptRecords(journal).isEmpty)
        let pending = try #require(session.allTransactions().last)
        let checkpoint: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier,
            "bundleID": Bundle.main.bundleIdentifier ?? "", "created": Date().timeIntervalSince1970,
            "attemptID": id, "productID": try #require(store.selectedID),
            "scope": try #require(request["scope"] as? [String: Any]), "platformTestIdentifier": pending.identifier]
        try JSONSerialization.data(withJSONObject: checkpoint).write(to: file, options: .atomic)
        prepared = true
        print("TIP_PENDING_PREPARE pid=\(ProcessInfo.processInfo.processIdentifier) attempt=\(id) durablePending=true")
        // No finish/clear/reset; the next host reads this exact request and platform session.
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["D_STOREKIT_COLD_STAGE"] == "pending-recover"))
    func coldPendingRequestRecover() async throws {
        let file = try coldCheckpoint(), root = file.deletingPathExtension().appendingPathExtension("request")
        let checkpoint = try journalObject(file), previousPID = try #require(checkpoint["pid"] as? Int)
        try #require(previousPID != Int(ProcessInfo.processInfo.processIdentifier))
        try #require(checkpoint["bundleID"] as? String == Bundle.main.bundleIdentifier)
        let created = try #require(checkpoint["created"] as? Double)
        try #require((0...1_800).contains(Date().timeIntervalSince1970 - created))
        let attemptID = try #require(checkpoint["attemptID"] as? String)
        let identifier = try #require((checkpoint["platformTestIdentifier"] as? NSNumber)?.uintValue)
        let configuration = try #require(Bundle(for: TipStoreKitBundle.self).url(forResource: "Tips", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: configuration) // No reset, clear, or new purchase.
        let retained = session.allTransactions().contains { $0.identifier == identifier && $0.productIdentifier == checkpoint["productID"] as? String }
        try #require(retained, "Platform cross-host precondition failed; never substitute another transaction")
        let store = owner(root), journal = root.appendingPathComponent("tips.json")
        try #require(store.status == .pending && !store.canPurchase)
        let initial = try attemptRecords(journal)
        try #require(initial.count == 1 && initial[attemptID]?["phase"] as? String == "pending")
        try #require(initial[attemptID]?["productID"] as? String == checkpoint["productID"] as? String)
        let scope = try #require(initial[attemptID]?["scope"] as? [String: String])
        let previousScope = try #require(checkpoint["scope"] as? [String: String])
        try #require(scope == previousScope && scope["bundleID"] == Bundle.main.bundleIdentifier)
        try #require(scope["environment"] == AppStore.Environment.xcode.rawValue && scope["accountID"]?.isEmpty == false)
        // Match the App's listener-before-user-action order. Loading products
        // suspends after start, before this test sends the external approval.
        store.start(); await store.loadProducts(); store.selectedID = checkpoint["productID"] as? String
        try #require(store.localTest && !store.canPurchase)
        // The local test knows which platform request it approved. D's production
        // listener is deliberately not given that test-only association.
        try session.approveAskToBuyTransaction(identifier: identifier)
        for _ in 0..<100 {
            if (try? receiptRecords(journal))?.count == 1 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        var verifiedHistory = 0, unverifiedHistory = 0, exactHistory = false
        for await result in Transaction.all {
            switch result {
            case .verified(let transaction):
                verifiedHistory += 1
                if transaction.id == UInt64(identifier) { exactHistory = true }
            case .unverified: unverifiedHistory += 1
            }
        }
        print("TIP_PENDING_PLATFORM approvedStates=\(session.allTransactions().map { $0.state.rawValue }) verifiedHistory=\(verifiedHistory) unverifiedHistory=\(unverifiedHistory) exactHistory=\(exactHistory) journalReceipts=\((try? receiptRecords(journal))?.count ?? -1)")
        try #require((try? receiptRecords(journal))?.count == 1, "Approval did not reach D's journal; preserve the checkpoint, do not report success or reset the platform session")
        let receipts = try receiptRecords(journal), after = try attemptRecords(journal)
        try #require(receipts.values.first?["transactionID"] as? String == String(identifier))
        try #require(after[attemptID]?["phase"] as? String == "pending" && after[attemptID]?["receiptKey"] == nil)
        try #require(!store.canPurchase && session.allTransactions().count == 1)
        var exactUnfinished = true, unfinishedCount = 0, unverifiedCount = 0
        for index in 0..<20 {
            exactUnfinished = false; unfinishedCount = 0; unverifiedCount = 0
            for await result in Transaction.unfinished {
                unfinishedCount += 1
                switch result {
                case .verified(let transaction): if transaction.id == UInt64(identifier) { exactUnfinished = true }
                case .unverified: unverifiedCount += 1
                }
            }
            if unfinishedCount == 0 { break }
            if index < 19 { try await Task.sleep(for: .milliseconds(100)) }
        }
        try #require(!exactUnfinished && unfinishedCount == 0 && unverifiedCount == 0)
        print("TIP_PENDING_RECOVER oldPID=\(previousPID) pid=\(ProcessInfo.processInfo.processIdentifier) exactRequestRetained=true globalReceiptPersisted=true anonymousPendingStillProtected=true")
        session.clearTransactions(); removeTestRecords(root); try FileManager.default.removeItem(at: file)
    }

    private func testSession() throws -> SKTestSession {
        let file = try #require(Bundle(for: TipStoreKitBundle.self).url(forResource: "Tips", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: file)
        session.resetToDefaultState(); session.clearTransactions(); session.disableDialogs = true
        return session
    }
    private func owner(_ root: URL) -> TipStore {
        TipStore(productIDs:["d.localtest.tip.tier1"],bundleID:Bundle.main.bundleIdentifier ?? "",journalURL:root.appendingPathComponent("tips.json"),localTest:true)
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
        let product = try #require(try await Product.products(for: ["d.localtest.tip.tier1"]).first)
        try #require(product.id == "d.localtest.tip.tier1" && product.type == .consumable)
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
                && t.productID == "d.localtest.tip.tier1"
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
        let records = try receiptRecords(journal)
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
        let records = try receiptRecords(root.appendingPathComponent("tips.json"))
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
        try await wait("unfinished recovery", store: cold) { (try? receiptRecords(root.appendingPathComponent("tips.json")))?.count == 3 }
        let recovered = try receiptRecords(root.appendingPathComponent("tips.json"))
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
        #expect(try receiptRecords(root.appendingPathComponent("tips.json")).isEmpty)
        try await session.setSimulatedError(nil, forAPI: .purchase)
        session.askToBuyEnabled = true
        await store.purchase(confirmIn:window)
        #expect(store.status == .pending && !store.canPurchase)
        #expect(try receiptRecords(root.appendingPathComponent("tips.json")).isEmpty)
        let pending = try #require(session.allTransactions().last)
        try session.approveAskToBuyTransaction(identifier:pending.identifier)
        try await wait("approved transaction persisted", store: store) {
            (try? receiptRecords(root.appendingPathComponent("tips.json")))?.count == 1
        }
        let accepted = try receiptRecords(root.appendingPathComponent("tips.json"))
        let acceptedID = try #require(accepted.values.compactMap { ($0 as? [String: Any])?["transactionID"] as? String }.first.flatMap(UInt64.init))
        #expect(acceptedID == UInt64(pending.identifier) && accepted.count == 1)
        let transaction = try #require(session.allTransactions().first { UInt64($0.identifier) == acceptedID })
        #expect(transaction.state == .purchased && transaction.productIdentifier == store.selectedID)
        try await wait("unresolved request stays protected", store: store) { store.status == .uncertain }
        #expect(!store.canPurchase)
        var exactUnfinished = false, unverifiedUnfinished = 0
        for await result in Transaction.unfinished {
            switch result {
            case .verified(let value): exactUnfinished = exactUnfinished || value.id == acceptedID
            case .unverified: unverifiedUnfinished += 1
            }
        }
        let platformRows = session.allTransactions()
        #expect(!exactUnfinished && unverifiedUnfinished == 0)
        #expect(platformRows.filter { $0.state == .purchased }.count == 1)
        #expect(platformRows.contains { $0.state == .failed }, "The earlier user cancellation remains a platform attempt, not a payment")
        try session.refundTransaction(identifier:transaction.identifier)
        print("TIP_LOCAL_REFUND requested=\(acceptedID) facts=\(session.allTransactions().map { "\($0.identifier):\($0.state.rawValue):\($0.cancelDate != nil)" })")
        // Local refund notifications have a separately recorded delivery failure.
        // Qualify the platform's exact verified history before testing explicit Reload.
        var platformHasRevocation = false
        for index in 0..<5 {
            for await result in Transaction.all {
                if case .verified(let value) = result, value.id == acceptedID, value.revocationDate != nil { platformHasRevocation = true }
            }
            if platformHasRevocation { break }
            if index < 4 { try await Task.sleep(for: .milliseconds(200)) }
        }
        try #require(platformHasRevocation, "Platform history must expose the exact refund; no injected fact substitutes for it")
        await store.recoverHistory(recheckAccount: true)
        #expect(store.status == .uncertain && !store.canPurchase)
        try await wait("exact approved transaction refund persisted", store: store) {
            guard let records = try? receiptRecords(root.appendingPathComponent("tips.json")) else { return false }
            return records.values.contains { $0["transactionID"] as? String == String(acceptedID) && $0["revoked"] as? Bool == true }
        }
        if case .verified(let latest)? = await Transaction.latest(for: "d.localtest.tip.tier1") {
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
            let records = try receiptRecords(file)
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
        let initial = try receiptRecords(file)
        let id = try #require(initial.values.compactMap { ($0 as? [String: Any])?["transactionID"] as? String }.first.flatMap(UInt64.init))
        let transaction = try #require(session.allTransactions().first { UInt64($0.identifier) == id })
        try session.refundTransaction(identifier: transaction.identifier)
        for _ in 0..<100 {
            if revokedIDs.contains(id), store.status == .idle { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let records = try receiptRecords(file)
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
        if case .verified(let t)? = await Transaction.latest(for: "d.localtest.tip.tier1") {
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
        let product = try #require(try await Product.products(for: ["d.localtest.tip.tier1"]).first)
        try #require(product.id == "d.localtest.tip.tier1" && product.type == .consumable)
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
        let initial = try receiptRecords(file)
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
        let restored = try receiptRecords(file)
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
        let records = try receiptRecords(root.appendingPathComponent("tips.json"))
        #expect(records.count == 1 && records.values.first?["revoked"] as? Bool == true)
        #expect(records.values.first?["revocationDate"] != nil)
        #expect(session.allTransactions().count == 1, "Refund recovery never purchases again")
    }

}
