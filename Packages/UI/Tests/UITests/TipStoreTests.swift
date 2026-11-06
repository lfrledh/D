import Foundation
import StoreKit
import Testing
@testable import UI

@Suite(.serialized) @MainActor struct TipStoreTests {
    @Test func catalogReloadNeverClearsUnmatchedOrUnverifiedPayment() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("D-tip-catalog-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let value = owner(root.appendingPathComponent("journal.json"))
        let generation = value.beginRecovery()
        try value.acceptScope(scope("B"), generation: generation)
        value.endRecovery(generation: generation, succeeded: true)
        let purchase = value.beginPurchase()
        await value.acceptVerified(detailed("one", account: "A"), purchase: purchase) {}
        #expect(value.status == .recorded && value.hasUnresolvedPayment)
        await value.acceptVerified(detailed("other-refund", account: "B", revoked: true)) {}
        await value.acceptVerified(detailed("other-fresh", account: "B")) {}
        #expect(value.status == .recorded && value.hasUnresolvedPayment)
        value.finishProductLoad([], failure: "controlled catalog failure")
        #expect(value.catalogStatus == .unavailable && value.status == .recorded && !value.canPurchase)
        value.finishProductLoad([])
        #expect(value.status == .recorded && value.catalogDiagnostic == nil)
        let recheck = value.beginRecovery()
        try value.acceptScope(scope("A"), generation: recheck)
        try await value.mergeHistory(detailed("one", account: "A"), credential: nil, generation: recheck)
        value.endRecovery(generation: recheck, succeeded: true)
        #expect(value.status == .thanked && value.currentSupportRecords.count == 1 && !value.hasUnresolvedPayment)
        value.markUnverified("exact verification failure")
        value.finishProductLoad([], failure: "independent catalog failure")
        #expect(value.status == .uncertain && value.diagnostic == "exact verification failure")
        #expect(value.catalogDiagnostic == "independent catalog failure")
        let failure = value.beginRecovery()
        value.endRecovery(generation: failure, succeeded: false, failure: .credentials, diagnostic: "vault failure")
        #expect(value.recoveryFailure == .credentials && value.recoveryDiagnostic == "vault failure")
        #expect(value.diagnostic == "exact verification failure")
    }

    @Test func tierIdentitiesNeverEncodePricesOrUseLocalProductsInProduction() {
        #expect(TipProducts.productionIDs == Set(["d.tip.tier1", "d.tip.tier2", "d.tip.tier3", "d.tip.tier4", "d.tip.tier5"]))
        #expect(TipProducts.localTestIDs.count == 5)
        #expect(TipProducts.productionIDs.isDisjoint(with: TipProducts.localTestIDs))
    }
    @Test func exactFailedReceiptCanRecoverButUnrelatedRefundCannotResolveUnknownPayment() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("D-tip-protected-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let value = owner(root.appendingPathComponent("journal.json"))
        let target = fact("target")
        value.markUnverified("known receipt save failure", receiptKey: target.key)
        await value.acceptVerified(fact("unrelated", revoked: true)) {}
        #expect(value.status == .uncertain && value.hasUnresolvedPayment)
        await value.acceptVerified(target) {}
        #expect(value.status == .thanked && !value.hasUnresolvedPayment)
        value.markUnverified("unknown signature failure")
        await value.acceptVerified(fact("later", revoked: true)) {}
        await value.acceptVerified(fact("other-new")) {}
        #expect(value.status == .uncertain && value.hasUnresolvedPayment)
        let production = TipStore(productIDs: ["d.localtest.tip.small"], bundleID: "D.fixture",
            journalURL: root.appendingPathComponent("production.json"), localTest: false, credentials: FixtureTipVault())
        var finished = false
        await production.acceptVerified(fact("xcode-in-normal-app")) { finished = true }
        #expect(!finished && production.status == .uncertain)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("production.json").path))
    }
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
        #expect(value.products.isEmpty && value.catalogStatus == .notConfigured && !value.canPurchase)
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
        #expect(value.status == (uncertain ? .uncertain : .thanked),
                "An unrelated verified delivery cannot resolve an earlier unknown verification failure")
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
        #expect(Set(vault.values.values) == ["original signed fixture", "revoked signed fixture"])
    }
    private func versioned(_ time: Double, revoked: Bool = false, percentage: Decimal? = nil) -> TipReceipt {
        .init(transactionID: "versioned", productID: "d.localtest.tip.small", bundleID: "D.fixture",
              environment: AppStore.Environment.xcode.rawValue, revoked: revoked, accountID: "A",
              purchaseDate: Date(timeIntervalSince1970: 100), amount: Decimal(string: "2.99"), currency: "USD",
              revocationDate: revoked ? Date(timeIntervalSince1970: 200) : nil,
              signedDate: Date(timeIntervalSince1970: time), revocationType: revoked ? "REFUND" : nil,
              revocationPercentage: percentage)
    }
    @Test func verifiedRefundSnapshotsOrderPartialRefundAndReversalWithoutNewPurchase() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("D-tip-refund-snapshots-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = FixtureTipVault(), url = root.appendingPathComponent("journal.json")
        let value = TipStore(productIDs: ["d.localtest.tip.small"], bundleID: "D.fixture", journalURL: url, localTest: true, credentials: vault)
        let gen = value.beginRecovery(); try value.acceptScope(scope("A"), generation: gen)
        let bought = versioned(101), refund = versioned(201, revoked: true, percentage: Decimal(string: "33.333")), reversed = versioned(301)
        try await value.mergeHistory(bought, credential: "bought", generation: gen)
        try await value.mergeHistory(refund, credential: "partial", generation: gen)
        value.endRecovery(generation: gen, succeeded: true)
        #expect(value.currentSupportRecords.first?.revocationPercentage == Decimal(string: "33.333"))
        try await value.mergeHistory(reversed, credential: "reversed", generation: gen)
        try await value.mergeHistory(refund, credential: "late partial", generation: gen)
        try await value.mergeHistory(bought, credential: "late bought", generation: gen)
        let current = try #require(value.currentSupportRecords.first)
        #expect(value.currentSupportRecords.count == 1 && !current.revoked)
        #expect(current.signedDate == reversed.signedDate && current.revocationPercentage == nil && current.revocationDate == nil)
        #expect(current.amount == bought.amount && current.purchaseDate == bought.purchaseDate)
        #expect(Set(vault.values.values) == ["bought", "partial", "reversed", "late partial", "late bought"])
        #expect(value.status != .thanked)
        await #expect(throws: (any Error).self) {
            try await value.mergeHistory(versioned(301, revoked: true), credential: "conflicting same version", generation: gen)
        }
        for bad in [Decimal(-1), Decimal(101), Decimal.nan] {
            await #expect(throws: (any Error).self) { try await value.mergeHistory(versioned(401, revoked: true, percentage: bad), credential: nil, generation: gen) }
        }
        #expect(try versioned(201, revoked: true).merging(versioned(202, revoked: true)).revocationPercentage == nil)
        #expect(try versioned(201, revoked: true).merging(versioned(202, revoked: true, percentage: 0)).revocationPercentage == 0)
        let cold = owner(url)
        #expect(cold.currentSupportRecords.isEmpty)
        let recovery = cold.beginRecovery(); try cold.acceptScope(scope("A"), generation: recovery)
        try await cold.mergeHistory(reversed, credential: nil, generation: recovery)
        cold.endRecovery(generation: recovery, succeeded: true)
        #expect(cold.currentSupportRecords.first == reversed)
    }
    @Test func newerVerifiedSnapshotWinsVaultSuspensionAndUnverifiedLocalFutureDate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("D-tip-version-race-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = FixtureTipVault(), url = root.appendingPathComponent("journal.json")
        let value = TipStore(productIDs: ["d.localtest.tip.small"], bundleID: "D.fixture", journalURL: url, localTest: true, credentials: vault)
        var held: CheckedContinuation<Void, Never>?
        vault.pause = { await withCheckedContinuation { held = $0 } }
        let old = Task { try await value.persistVerified(versioned(201, revoked: true, percentage: 50), credential: "old") }
        for _ in 0..<100 { if held != nil { break }; await Task.yield() }
        try #require(held != nil); vault.pause = nil
        _ = try await value.persistVerified(versioned(301), credential: "new")
        held?.resume(); _ = try await old.value
        #expect(Set(vault.values.values) == ["old", "new"])
        let data = try JSONDecoder().decode([String: TipReceipt].self, from: Data(contentsOf: url))
        #expect(data.values.first?.revoked == false)
        try JSONEncoder().encode([versioned(999999).key: versioned(999999, revoked: true)]).write(to: url)
        let cold = owner(url)
        _ = try cold.recordVerified(versioned(301))
        let restored = try JSONDecoder().decode([String: TipReceipt].self, from: Data(contentsOf: url))
        #expect(restored.values.first?.signedDate == versioned(301).signedDate && restored.values.first?.revoked == false)
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
        let saved = try JSONDecoder().decode([String: TipReceipt].self, from: Data(contentsOf: url))
        #expect(saved[detailed("one").key]?.amount == nil)
        try await cold.mergeHistory(detailed("one", amount: Decimal(string: "2.99")), credential: nil, generation: gen)
        #expect(cold.currentSupportRecords[0].amount == Decimal(string: "2.99"))
        // A fresh platform result also replaces conflicting unverified cache facts directly.
        _ = try owner(url).recordVerified(detailed("one", account: "wrong", amount: 999, currency: "BAD"))
        let fresh = owner(url), freshGen = fresh.beginRecovery()
        try fresh.acceptScope(scope("A"), generation: freshGen)
        try await fresh.mergeHistory(detailed("one", amount: Decimal(string: "2.99")), credential: nil, generation: freshGen)
        fresh.endRecovery(generation: freshGen, succeeded: true)
        #expect(fresh.currentSupportRecords[0].accountID == "A" && fresh.currentSupportRecords[0].amount == Decimal(string: "2.99"))
    }
    @Test func coldCredentialEvidencePreservesNewerProofAndBoundedLegacySlots() throws {
        let latest = versioned(301), old = versioned(101)
        let saved = try TipCredentialEvidence.adding("reversal", for: latest, to: [latest.key + ":revoked": "legacy refund"])
        let cold = try JSONDecoder().decode([String: String].self, from: JSONEncoder().encode(saved))
        let late = try TipCredentialEvidence.adding("purchase", for: old, to: cold)
        #expect(Set(late.values) == ["reversal", "legacy refund", "purchase"])
        #expect(try TipCredentialEvidence.adding("purchase", for: old, to: late) == late)
        let full = Dictionary(uniqueKeysWithValues: (0..<4096).map { (String($0), "existing") })
        #expect(throws: (any Error).self) { try TipCredentialEvidence.adding("new", for: old, to: full) }
        #expect(full.count == 4096)
        var legacyFull = full; legacyFull.removeValue(forKey: "0")
        legacyFull[old.key + ":purchase"] = "already signed"
        #expect(try TipCredentialEvidence.adding("already signed", for: old, to: legacyFull) == legacyFull)
        #expect(throws: (any Error).self) { try TipCredentialEvidence.adding("new signature", for: old, to: legacyFull) }
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
    func store(_ credential: String, for fact: TipReceipt) async throws {
        if fail { throw CocoaError(.fileWriteNoPermission) }
        await pause?()
        values = try TipCredentialEvidence.adding(credential, for: fact, to: values)
    }
}
