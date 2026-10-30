import Foundation
import StoreKit
import Testing
@testable import UI

@Suite(.serialized) @MainActor struct TipStoreTests {
    private func owner(_ url: URL, ids: Set<String> = ["d.localtest.tip.small"]) -> TipStore {
        TipStore(productIDs: ids, bundleID: "D.fixture", journalURL: url, localTest: true, credentials: FixtureTipVault())
    }
    private func fact(_ id: String, revoked: Bool = false) -> TipReceipt {
        .init(transactionID:id,productID:"d.localtest.tip.small",bundleID:"D.fixture",environment:AppStore.Environment.xcode.rawValue,revoked:revoked)
    }
    @Test func verifiedJournalIsIdempotentDurableAndRefundNeverChangesFeatures() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("D-tips-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let url = root.appendingPathComponent("journal.json"), first = owner(root.appendingPathComponent("journal.json"))
        #expect(try first.recordVerified(fact("one")))
        #expect(try !first.recordVerified(fact("one")))
        let cold = owner(url)
        #expect(try !cold.recordVerified(fact("one")))
        #expect(try cold.recordVerified(fact("two")))
        #expect(try !cold.recordVerified(fact("one",revoked:true)))
        #expect(try !cold.recordVerified(fact("one")))
        #expect(throws:(any Error).self) { try cold.recordVerified(.init(transactionID:"bad",productID:"unapproved",bundleID:"D.fixture",environment:AppStore.Environment.xcode.rawValue,revoked:false)) }
        #expect(throws:(any Error).self) { try cold.recordVerified(.init(transactionID:"bad",productID:"d.localtest.tip.small",bundleID:"Other",environment:AppStore.Environment.xcode.rawValue,revoked:false)) }
    }
    @Test func failedJournalWriteNeverAcknowledgesAndCanRetrySameTransaction() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("D-tips-block-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        try Data("keep".utf8).write(to:root)
        let value = owner(root.appendingPathComponent("journal.json"))
        #expect(throws:(any Error).self) { try value.recordVerified(fact("one")) }
        #expect(try Data(contentsOf:root) == Data("keep".utf8))
        try FileManager.default.removeItem(at:root)
        #expect(try value.recordVerified(fact("one")))
    }
    @Test func ordinaryConfigurationHasNoInventedProductOrPurchase() async {
        let value = owner(FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),ids:[])
        await value.loadProducts()
        #expect(value.products.isEmpty && value.status == .unavailable && !value.canPurchase)
    }
    @Test(arguments: [false, true]) func duplicateDeliveryCannotEraseTheFirstSuccessfulAcknowledgment(uncertain: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("D-tips-duplicate-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let value = owner(root.appendingPathComponent("journal.json"))
        if uncertain { value.markUnverified("controlled earlier verification issue") }
        var suspended: CheckedContinuation<Void, Never>?
        let original = Task { await value.acceptVerified(fact("one")) { await withCheckedContinuation { suspended = $0 } } }
        for _ in 0..<100 { if suspended != nil { break }; await Task.yield() }
        #expect(suspended != nil)
        await value.acceptVerified(fact("one")) { }
        suspended?.resume(); await original.value
        #expect(value.status == .thanked)
        let saved = try JSONDecoder().decode([String: TipReceipt].self, from: Data(contentsOf: root.appendingPathComponent("journal.json")))
        #expect(saved.count == 1)
    }
    @Test func failedWriteDoesNotFinishAndRefundWinsSuspendedFinish() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("D-tips-finish-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        try Data("keep".utf8).write(to:root)
        let value = owner(root.appendingPathComponent("journal.json"))
        var finishes = 0
        await value.acceptVerified(fact("one")) { finishes += 1 }
        #expect(finishes == 0 && value.status == .uncertain)
        try FileManager.default.removeItem(at:root)
        var suspended: CheckedContinuation<Void, Never>?
        let original = Task { await value.acceptVerified(fact("one")) { await withCheckedContinuation { suspended = $0 } } }
        for _ in 0..<100 { if suspended != nil { break }; await Task.yield() }
        #expect(suspended != nil)
        await value.acceptVerified(fact("one",revoked:true)) { finishes += 1 }
        suspended?.resume(); await original.value
        #expect(finishes == 1 && value.status == .idle)
        value.markUnverified("controlled signature failure")
        #expect(value.status == .uncertain && value.diagnostic == "controlled signature failure" && !value.canPurchase)
    }

    private func detailed(_ id: String, account: String? = "A", amount: Decimal? = Decimal(string: "1.23456789"),
                          currency: String? = "USD", revoked: Bool = false) -> TipReceipt {
        .init(transactionID: id, productID: "d.localtest.tip.small", bundleID: "D.fixture",
              environment: AppStore.Environment.xcode.rawValue, revoked: revoked, accountID: account,
              purchaseDate: Date(timeIntervalSince1970: 100), amount: amount, currency: currency,
              revocationDate: revoked ? Date(timeIntervalSince1970: 200) : nil)
    }
    private func scope(_ account: String) -> TipAccountScope {
        .init(bundleID: "D.fixture", environment: AppStore.Environment.xcode.rawValue, accountID: account)
    }
    @Test func exactMoneyUnknownValuesCurrenciesAndLegacyEnrichmentAreDurable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("D-tip-history-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("journal.json")
        try JSONEncoder().encode(["one": fact("one")]).write(to: url)
        let value = owner(url), gen = value.beginRecovery()
        try value.acceptScope(scope("A"), generation: gen)
        try await value.mergeHistory(detailed("one"), credential: "signed fixture", generation: gen)
        try await value.mergeHistory(detailed("two", amount: 500, currency: "JPY"), credential: "second fixture", generation: gen)
        try await value.mergeHistory(detailed("unknown", amount: nil, currency: nil), credential: nil, generation: gen)
        value.endRecovery(generation: gen, succeeded: true)
        #expect(value.currentSupportRecords.count == 3)
        #expect(value.currentSupportRecords.first { $0.transactionID == "one" }?.amount == Decimal(string: "1.23456789"))
        #expect(value.currentSupportRecords.first { $0.transactionID == "unknown" }?.amount == nil)
        let data = try Data(contentsOf: url)
        #expect(!String(decoding: data, as: UTF8.self).contains("signed fixture"))
        let saved = try JSONDecoder().decode([String: TipReceipt].self, from: data)
        #expect(saved.count == 3 && saved[detailed("one").key]?.amount == Decimal(string: "1.23456789"))
        #expect(saved[detailed("two").key]?.currency == "JPY")
        #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let cold = owner(url)
        #expect(cold.currentSupportRecords.isEmpty, "A local copy is not a new platform account verification")
        #expect(try !cold.recordVerified(detailed("one")))
    }
    @Test func accountChangeAndLateHistoryCannotClaimCopiedJournal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("D-tip-account-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let value = owner(root.appendingPathComponent("journal.json"))
        let a = value.beginRecovery(); try value.acceptScope(scope("A"), generation: a)
        try await value.mergeHistory(detailed("one"), credential: nil, generation: a)
        value.endRecovery(generation: a, succeeded: true)
        #expect(value.currentSupportRecords.count == 1)
        let b = value.beginRecovery()
        #expect(value.currentSupportRecords.isEmpty)
        try value.acceptScope(scope("B"), generation: b)
        await #expect(throws: (any Error).self) { try await value.mergeHistory(detailed("late"), credential: nil, generation: a) }
        await #expect(throws: (any Error).self) { try await value.mergeHistory(detailed("one"), credential: nil, generation: b) }
        #expect(throws: (any Error).self) { try value.recordVerified(detailed("one", account: "B")) }
        try await value.mergeHistory(detailed("two", account: "B"), credential: nil, generation: b)
        value.endRecovery(generation: b, succeeded: true)
        value.endRecovery(generation: a, succeeded: false)
        #expect(value.currentSupportRecords.map(\.transactionID) == ["two"])
        let failed = value.beginRecovery(); value.endRecovery(generation: failed, succeeded: false)
        #expect(value.currentSupportRecords.isEmpty && value.verifiedScope == nil)
        #expect(try !value.recordVerified(detailed("one")), "Old account record remains, but is not claimed by B")
    }
    @Test func deletedLocalDataRestoresOnlyVerifiedHistoryAndNeverPurchasesOrThanks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("D-tip-restore-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let value = owner(root.appendingPathComponent("journal.json")), gen = value.beginRecovery()
        try value.acceptScope(scope("A"), generation: gen)
        try await value.mergeHistory(detailed("one", revoked: true), credential: nil, generation: gen)
        try await value.mergeHistory(detailed("one"), credential: nil, generation: gen)
        value.endRecovery(generation: gen, succeeded: true)
        #expect(value.currentSupportRecords.count == 1 && value.currentSupportRecords[0].revoked)
        #expect(value.currentSupportRecords[0].revocationDate == Date(timeIntervalSince1970: 200))
        #expect(value.status == .idle && value.selectedProduct == nil)
        #expect(throws: (any Error).self) { try value.recordVerified(detailed("one", amount: 2)) }
        #expect(throws: (any Error).self) { try value.recordVerified(detailed("one", currency: "EUR")) }
    }
    @Test func credentialFailureDoesNotAcknowledgeAndRecoveryUsesSameTransaction() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("D-tip-vault-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = FixtureTipVault(); vault.fail = true
        let value = TipStore(productIDs: ["d.localtest.tip.small"], bundleID: "D.fixture", journalURL: root.appendingPathComponent("journal.json"), localTest: true, credentials: vault)
        let gen = value.beginRecovery(); try value.acceptScope(scope("A"), generation: gen)
        value.endRecovery(generation: gen, succeeded: true)
        var finished = 0
        await value.acceptVerified(detailed("one"), credential: "signed") { finished += 1 }
        #expect(finished == 0 && value.status == .uncertain)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("journal.json").path))
        vault.fail = false
        await value.acceptVerified(detailed("one"), credential: "signed") { finished += 1 }
        #expect(finished == 1 && value.status == .thanked && vault.values.count == 1)
    }
    @Test func historyWinningPurchaseRaceAndAccountRecheckCannotLeavePurchaseSpinning() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("D-tip-race-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let value = owner(root.appendingPathComponent("journal.json"))
        let gen = value.beginRecovery(); try value.acceptScope(scope("A"), generation: gen)
        let purchase = value.beginPurchase()
        try await value.mergeHistory(detailed("one"), credential: nil, generation: gen)
        value.endRecovery(generation: gen, succeeded: true)
        var suspended: CheckedContinuation<Void, Never>?
        let result = Task { await value.acceptVerified(detailed("one"), purchase: purchase) { await withCheckedContinuation { suspended = $0 } } }
        for _ in 0..<100 { if suspended != nil { break }; await Task.yield() }
        #expect(suspended != nil)
        let next = value.beginRecovery(); try value.acceptScope(scope("B"), generation: next)
        value.endRecovery(generation: next, succeeded: true)
        suspended?.resume(); await result.value
        #expect(value.status == .recorded && value.currentSupportRecords.isEmpty)
        let again = value.beginRecovery(); try value.acceptScope(scope("A"), generation: again)
        let second = value.beginPurchase()
        await value.acceptVerified(detailed("one"), purchase: second) { }
        #expect(value.status == .thanked, "An explicit payment response ends even when history already recorded it")
    }
    @Test func completedPurchaseDoesNotEraseANewerUnverifiedTransaction() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("D-tip-new-error-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let value = owner(root.appendingPathComponent("journal.json"))
        let gen = value.beginRecovery(); try value.acceptScope(scope("A"), generation: gen)
        value.endRecovery(generation: gen, succeeded: true)
        let purchase = value.beginPurchase()
        var suspended: CheckedContinuation<Void, Never>?
        let result = Task { await value.acceptVerified(detailed("one"), purchase: purchase) { await withCheckedContinuation { suspended = $0 } } }
        for _ in 0..<100 { if suspended != nil { break }; await Task.yield() }
        #expect(suspended != nil)
        value.markUnverified("second transaction not verified")
        suspended?.resume(); await result.value
        #expect(value.status == .uncertain && value.diagnostic == "second transaction not verified")
        #expect(!value.canPurchase)
    }
    @Test func lateOriginalCannotReplaceSignedRevocationEvidence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("D-tip-proof-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = FixtureTipVault()
        let value = TipStore(productIDs: ["d.localtest.tip.small"], bundleID: "D.fixture", journalURL: root.appendingPathComponent("journal.json"), localTest: true, credentials: vault)
        _ = try await value.persistVerified(detailed("one"), credential: "original signed fixture")
        _ = try await value.persistVerified(detailed("one", revoked: true), credential: "revoked signed fixture")
        _ = try await value.persistVerified(detailed("one"), credential: "original signed fixture")
        #expect(vault.values[detailed("one").key + ":revoked"] == "revoked signed fixture")
        #expect(vault.values[detailed("one").key + ":purchase"] == "original signed fixture")
    }
    @Test func unknownPlatformPriceCannotInheritAnUnverifiedLocalAmount() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("D-tip-cache-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("journal.json")
        _ = try owner(url).recordVerified(detailed("one", amount: 999))
        let cold = owner(url), gen = cold.beginRecovery()
        try cold.acceptScope(scope("A"), generation: gen)
        try await cold.mergeHistory(detailed("one", amount: nil, currency: nil), credential: nil, generation: gen)
        cold.endRecovery(generation: gen, succeeded: true)
        #expect(cold.currentSupportRecords.count == 1 && cold.currentSupportRecords[0].amount == nil)
    }
    @Test func staleHistoryCannotCommitAfterCredentialPersistenceSuspends() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("D-tip-hop-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = FixtureTipVault()
        let value = TipStore(productIDs: ["d.localtest.tip.small"], bundleID: "D.fixture", journalURL: root.appendingPathComponent("journal.json"), localTest: true, credentials: vault)
        let gen = value.beginRecovery(); try value.acceptScope(scope("A"), generation: gen)
        var suspended: CheckedContinuation<Void, Never>?
        vault.pause = { await withCheckedContinuation { suspended = $0 } }
        let write = Task { do { try await value.mergeHistory(detailed("one"), credential: "signed fixture", generation: gen); return true } catch { return false } }
        for _ in 0..<100 { if suspended != nil { break }; await Task.yield() }
        #expect(suspended != nil)
        let next = value.beginRecovery(); try value.acceptScope(scope("B"), generation: next)
        value.endRecovery(generation: next, succeeded: true)
        vault.pause = nil; suspended?.resume()
        #expect(await write.value == false)
        #expect(value.currentSupportRecords.isEmpty && value.verifiedScope == scope("B"))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("journal.json").path))
    }
    @Test func sameTransactionNumberInDifferentEnvironmentsIsNotDeduplicated() throws {
        let a = detailed("same")
        let b = TipReceipt(transactionID: "same", productID: a.productID, bundleID: a.bundleID, environment: AppStore.Environment.sandbox.rawValue, revoked: false)
        #expect(a.key != b.key)
        #expect(throws: (any Error).self) { try a.merging(b) }
    }

}

@MainActor private final class FixtureTipVault: TipCredentialVault {
    var values: [String: String] = [:]
    var fail = false
    var pause: (() async -> Void)?
    func store(_ credential: String, for key: String) async throws {
        if fail { throw CocoaError(.fileWriteNoPermission) }
        await pause?()
        values[key] = credential
    }
}
