import AppKit
import Foundation
import Observation
import StoreKit
import CryptoKit
import Security

/// Proposed consumable IDs, pending App Store Connect creation. Currency is never
/// encoded into identity, and no client price is substituted for StoreKit displayPrice.
public enum TipProducts {
    public static let productionIDs: Set<String> = Set((1...5).map { "d.tip.tier\($0)" })
    #if DEBUG
    public static let localTestIDs: Set<String> = Set((1...5).map { "d.localtest.tip.tier\($0)" })
    #endif
}

/// Application-owned StoreKit listener. No project, model or feature entitlement depends on tips.
@MainActor @Observable public final class TipStore {
    public enum Status: String { case idle, loading, unavailable, purchasing, pending, cancelled, thanked, recorded, failed, uncertain }
    public enum CatalogStatus: String { case idle, loading, notConfigured, available, partial, unavailable }
    public private(set) var catalogStatus: CatalogStatus = .idle
    public private(set) var catalogDiagnostic: String?
    public private(set) var products: [Product] = []
    public private(set) var status: Status = .idle
    public private(set) var diagnostic: String?
    public var selectedID: String?
    public var presented = false
    public private(set) var localTest = false
    public enum RecoveryFailure: String { case platform, verification, storage, credentials, capacity }
    public private(set) var recoveryFailure: RecoveryFailure?
    public private(set) var recoveryDiagnostic: String?
    public enum RecoveryStatus { case idle, loading, ready, unavailable, failed }
    public private(set) var recoveryStatus: RecoveryStatus = .idle
    private(set) var verifiedScope: TipAccountScope?
    private(set) var recoveryGeneration: UInt64 = 0
    private var verifiedHistory: [String: TipReceipt] = [:]
    private var verifiedJournalKeys: Set<String> = []
    private var unmatchedPurchaseKey: String?
    private var unresolvedReceiptKeys: Set<String> = []
    private var unknownPaymentOutcome = false
    private(set) var attempts: [String: TipAttempt] = [:]
    public private(set) var needsRetrySave = false
    private let credentials: any TipCredentialVault
    private let expectsLocalTest: Bool
    private var eventRevision: UInt64 = 0
    private let allowedIDs: Set<String>
    private let bundleID: String
    private let journalURL: URL
    private var journal: [String: TipReceipt] = [:]
    private var journalIssue: String?
    @ObservationIgnored private var listener: Task<Void, Never>?
    @ObservationIgnored private var recovery: Task<Void, Never>?
    @ObservationIgnored private var historyTask: Task<Void, Never>?
    @ObservationIgnored private var loading = false
    @ObservationIgnored private var purchasing = false
    @ObservationIgnored private var purchaseID: UUID?
    // Only in-flight verified handlers own entries; defer removes them after finish.
    @ObservationIgnored private var pendingAcknowledgments: Set<String> = []
    /// Stable tier identifiers are injected by the app; StoreKit owns prices and storefront.
    public convenience init(productIDs: Set<String>, bundleID: String, journalURL: URL, localTest: Bool = false) {
        self.init(productIDs: productIDs, bundleID: bundleID, journalURL: journalURL, localTest: localTest,
                  credentials: TipKeychainVault(bundleID: bundleID, journalURL: journalURL))
    }
    init(productIDs: Set<String>, bundleID: String, journalURL: URL, localTest: Bool, credentials: any TipCredentialVault) {
        allowedIDs = productIDs; self.bundleID = bundleID; self.journalURL = journalURL; self.expectsLocalTest = localTest
        self.credentials = credentials
        do {
            if FileManager.default.fileExists(atPath: journalURL.path) {
                let data = try Data(contentsOf: journalURL)
                guard data.count <= 2_097_152 else { throw TipIssue.journalTooLarge }
                let stored: TipJournal
                if (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["version"] != nil {
                    stored = try JSONDecoder().decode(TipJournal.self, from: data)
                    guard stored.version == 1 else { throw TipIssue.invalidJournal }
                } else {
                    stored = TipJournal(receipts: try JSONDecoder().decode([String: TipReceipt].self, from: data))
                }
                guard stored.receipts.count <= 4096, stored.attempts.count <= 1024,
                      stored.unresolvedReceiptKeys.count <= 4096 else { throw TipIssue.journalTooLarge }
                for (key, fact) in stored.receipts {
                    // Legacy transaction-only keys migrate in memory, without assigning an account or price.
                    guard (key == fact.transactionID || key == fact.key), fact.bundleID == bundleID,
                          !fact.transactionID.isEmpty, journal[fact.key] == nil else { throw TipIssue.invalidJournal }
                    journal[fact.key] = fact
                }
                for (key, attempt) in stored.attempts {
                    guard key == attempt.id.uuidString, attempt.scope.bundleID == bundleID,
                          !attempt.scope.accountID.isEmpty, !attempt.productID.isEmpty,
                          validEnvironment(attempt.scope.environment),
                          attempt.created.timeIntervalSince1970.isFinite,
                          [TipAttempt.Phase.awaitingRecord, .completed].contains(attempt.phase) == (attempt.receiptKey != nil),
                          attempt.phase != .completed || journal[attempt.receiptKey ?? ""] != nil else { throw TipIssue.invalidJournal }
                    if let receipt = journal[attempt.receiptKey ?? ""] {
                        guard receipt.productID == attempt.productID, receipt.bundleID == attempt.scope.bundleID,
                              receipt.environment == attempt.scope.environment else { throw TipIssue.invalidJournal }
                    }
                }
                attempts = stored.attempts; unknownPaymentOutcome = stored.unknownPaymentOutcome
                unresolvedReceiptKeys = stored.unresolvedReceiptKeys; unmatchedPurchaseKey = stored.unmatchedPurchaseKey
                status = protectedPaymentStatus ?? .idle
            }
        } catch { journalIssue = String(describing: error); diagnostic = journalIssue; status = .uncertain }
    }
    deinit { listener?.cancel(); recovery?.cancel(); historyTask?.cancel() }
    public func start() {
        guard listener == nil, !allowedIDs.isEmpty else { return }
        listener = Task { [weak self] in
            for await result in Transaction.updates {
                guard !Task.isCancelled else { return }; await self?.receive(result)
            }
        }
        recovery = Task { [weak self] in
            await self?.recoverHistory()
            for await result in Transaction.unfinished {
                guard !Task.isCancelled else { return }; await self?.receive(result)
            }
        }
    }
    public func loadProducts() async {
        guard !loading, !purchasing else { return }
        guard journalIssue == nil else { status = .uncertain; return }
        guard !allowedIDs.isEmpty else { products = []; catalogStatus = .notConfigured; return }
        loading = true; defer { loading = false }
        catalogStatus = .loading; catalogDiagnostic = nil
        do {
            await recoverHistory()
            if expectsLocalTest && !localTest { throw TipIssue.invalidTransaction }
            for await result in Transaction.unfinished { await receive(result) }
            let loaded = try await Product.products(for: allowedIDs)
            finishProductLoad(loaded)
        } catch {
            finishProductLoad([], failure: String(describing: error))
        }
    }
    /// Catalog refresh never acknowledges or clears an unresolved payment.
    func finishProductLoad(_ loaded: [Product], failure: String? = nil) {
        products = loaded.filter { allowedIDs.contains($0.id) && $0.type == .consumable }
            .sorted { $0.id < $1.id }
        if let selectedID, !products.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
        catalogDiagnostic = failure
        catalogStatus = allowedIDs.isEmpty ? .notConfigured : products.isEmpty ? .unavailable :
            products.count == allowedIDs.count ? .available : .partial
    }
    public var selectedProduct: Product? { products.first { $0.id == selectedID } }
    var hasUnresolvedPayment: Bool {
        protectedPaymentStatus != nil || [.uncertain, .recorded, .pending].contains(status)
    }
    private var protectedPaymentStatus: Status? {
        if needsRetrySave || unknownPaymentOutcome || !unresolvedReceiptKeys.isEmpty { return .uncertain }
        let open = attempts.values.filter { $0.phase.isUnresolved }
        if !open.isEmpty { return open.allSatisfy { $0.phase == .pending } ? .pending : .uncertain }
        if unmatchedPurchaseKey != nil { return .recorded }
        return nil
    }
    public var capacityLimitReached: Bool { journal.count >= 4096 || attempts.count >= 1024 }
    public var canRetrySave: Bool { needsRetrySave && !purchasing }
    public var canPurchase: Bool { !capacityLimitReached && selectedProduct != nil && !purchasing && !loading && recoveryStatus == .ready && journalIssue == nil && !hasUnresolvedPayment && (!expectsLocalTest || localTest) }
    public func purchase(confirmIn window: NSWindow) async {
        guard canPurchase, let product = selectedProduct else { return }
        var attempt: UUID?
        defer { purchasing = false; if purchaseID == attempt { purchaseID = nil } }
        do {
            let id = try preparePurchase(productID: product.id); attempt = id
            try dispatchPurchase(id)
            // No suspension between the durable dispatch marker and this API.
            // A crash in that narrow interval remains conservatively unknown.
            switch try await product.purchase(confirmIn: window) {
            case .success(let result): await receive(result, purchase: id)
            case .userCancelled: completePurchase(id, phase: .cancelled)
            case .pending: completePurchase(id, phase: .pending)
            @unknown default: completePurchase(id, phase: .unknown, reason: "Unknown StoreKit purchase outcome")
            }
        } catch StoreKitError.userCancelled {
            if let attempt { completePurchase(attempt, phase: .cancelled) }
        } catch {
            if let attempt, attempts[attempt.uuidString]?.phase != .prepared {
                completePurchase(attempt, phase: .unknown, reason: String(describing: error))
            } else { diagnostic = String(describing: error); status = .failed }
        }
    }
    /// Only currently platform-verified records may be projected for the verified application account.
    /// Loading a local journal is never equivalent to platform verification after a cold start.
    var currentSupportRecords: [TipReceipt] {
        guard recoveryStatus == .ready, let scope = verifiedScope else { return [] }
        return verifiedHistory.values.filter { scope.contains($0) }
            .sorted { ($0.purchaseDate ?? .distantPast, $0.key) < ($1.purchaseDate ?? .distantPast, $1.key) }
    }
    @discardableResult func beginRecovery() -> UInt64 {
        recoveryGeneration &+= 1; verifiedScope = nil; verifiedHistory.removeAll()
        recoveryStatus = .loading; recoveryFailure = nil; recoveryDiagnostic = nil; return recoveryGeneration
    }
    func acceptScope(_ scope: TipAccountScope, generation: UInt64) throws {
        guard generation == recoveryGeneration, scope.bundleID == bundleID, !scope.accountID.isEmpty,
              validEnvironment(scope.environment) else { throw TipIssue.invalidTransaction }
        verifiedScope = scope
    }
    func mergeHistory(_ fact: TipReceipt, credential: String?, generation: UInt64) async throws {
        guard generation == recoveryGeneration, verifiedScope?.contains(fact) == true else { throw TipIssue.invalidTransaction }
        let revision = eventRevision
        _ = try await persistVerified(fact, credential: credential, generation: generation)
        if revision == eventRevision, unresolvedReceiptKeys.remove(fact.key) != nil { persistProtection() }
    }
    func endRecovery(generation: UInt64, succeeded: Bool, failure: RecoveryFailure? = nil, diagnostic: String? = nil) {
        guard generation == recoveryGeneration else { return }
        recoveryStatus = succeeded ? .ready : .failed
        recoveryFailure = succeeded ? nil : failure ?? .platform
        recoveryDiagnostic = succeeded ? nil : diagnostic
        if !succeeded { verifiedScope = nil; verifiedHistory.removeAll() }
        if succeeded, protectedPaymentStatus == nil, status == .uncertain { status = .idle }
        if succeeded, let key = unmatchedPurchaseKey,
           let fact = verifiedHistory[key], verifiedScope?.contains(fact) == true {
            unmatchedPurchaseKey = nil; persistProtection()
            status = protectedPaymentStatus ?? (fact.revoked ? .idle : .thanked)
            eventRevision &+= 1
        }
    }
    public func recoverHistory(recheckAccount: Bool = false) async {
        guard !allowedIDs.isEmpty else { recoveryStatus = .unavailable; return }
        if historyTask == nil || recheckAccount {
            historyTask?.cancel()
            let generation = beginRecovery()
            historyTask = Task { [weak self] in await self?.readVerifiedHistory(generation: generation) }
        }
        // Startup and panel opening share the same finite read. If reactivation replaces
        // it, callers await the replacement rather than inspecting half-initialized state.
        while let task = historyTask {
            let generation = recoveryGeneration
            await task.value
            if generation == recoveryGeneration { historyTask = nil; return }
            if Task.isCancelled { return }
        }
    }
    private func readVerifiedHistory(generation: UInt64) async {
        do {
            // shared updates through StoreKit. Do not invoke refresh/sync (account authentication)
            // automatically; this finite read runs at launch, panel opening and app reactivation.
            guard case .verified(let app) = try await AppTransaction.shared else { throw TipIssue.invalidTransaction }
            guard generation == recoveryGeneration else { return }
            let scope = TipAccountScope(bundleID: app.bundleID, environment: app.environment.rawValue,
                                        accountID: app.appTransactionID)
            try acceptScope(scope, generation: generation)
            localTest = expectsLocalTest && app.environment == .xcode
            for await result in Transaction.all {
                guard generation == recoveryGeneration else { return }
                if Task.isCancelled { endRecovery(generation: generation, succeeded: false); return }
                guard case .verified(let transaction) = result else { throw TipIssue.invalidTransaction }
                guard allowedIDs.contains(transaction.productID), transaction.productType == .consumable else { continue }
                let fact = Self.fact(transaction)
                // Transactions retain their own verified owner, never the currently selected account.
                guard scope.contains(fact) else { continue }
                try await mergeHistory(fact, credential: result.jwsRepresentation, generation: generation)
            }
            endRecovery(generation: generation, succeeded: true)
        } catch {
            let failure: RecoveryFailure
            switch error {
            case TipIssue.invalidTransaction: failure = .verification
            case TipIssue.invalidJournal: failure = .storage
            case TipIssue.credentialUnavailable, TipIssue.credentialStatus: failure = .credentials
            case TipIssue.journalTooLarge: failure = .capacity
            case is CocoaError: failure = .storage
            default: failure = .platform
            }
            endRecovery(generation: generation, succeeded: false, failure: failure, diagnostic: String(describing: error))
        }
    }
    private static func fact(_ transaction: Transaction) -> TipReceipt {
        TipReceipt(transactionID: String(transaction.id), productID: transaction.productID,
            bundleID: transaction.appBundleID, environment: transaction.environment.rawValue,
            revoked: transaction.revocationDate != nil, accountID: transaction.appTransactionID.nilIfEmpty,
            purchaseDate: transaction.purchaseDate, amount: transaction.price,
            currency: transaction.currency?.identifier, revocationDate: transaction.revocationDate,
            signedDate: transaction.signedDate, revocationType: transaction.revocationTypeStringRepresentation,
            revocationPercentage: transaction.revocationPercentage,
            revocationReason: transaction.revocationReason?.rawValue)
    }
    /// A prepared record is known not to have reached StoreKit. A dispatch
    /// marker is conservative: the API may have received the request.
    func preparePurchase(productID: String) throws -> UUID {
        guard !capacityLimitReached else { throw TipIssue.journalTooLarge }
        guard !purchasing, !hasUnresolvedPayment, let scope = verifiedScope,
              allowedIDs.contains(productID), validEnvironment(scope.environment) else { throw TipIssue.invalidTransaction }
        let id = UUID()
        var next = durableJournal
        next.attempts[id.uuidString] = .init(id: id, productID: productID, scope: scope,
                                           created: Date(), phase: .prepared, receiptKey: nil)
        try writeJournal(next)
        attempts = next.attempts; purchaseID = id; purchasing = true; status = .purchasing; diagnostic = nil
        return id
    }
    func dispatchPurchase(_ id: UUID) throws {
        guard purchaseID == id, attempts[id.uuidString]?.phase == .prepared else { throw TipIssue.invalidTransaction }
        var next = durableJournal; next.attempts[id.uuidString]?.phase = .dispatching
        // Failure must leave this request prepared, with zero purchase calls.
        try writeJournal(next); attempts = next.attempts
    }
    func completePurchase(_ id: UUID, phase: TipAttempt.Phase, reason: String? = nil) {
        guard purchaseID == id, let old = attempts[id.uuidString],
              [.dispatching, .pending, .unknown].contains(old.phase),
              [.cancelled, .pending, .unknown].contains(phase) else { return }
        attempts[id.uuidString]?.phase = phase
        if let reason { diagnostic = reason }
        persistProtection()
        status = protectedPaymentStatus ?? (phase == .cancelled ? .cancelled : .uncertain)
    }
    private var durableJournal: TipJournal {
        .init(receipts: journal, attempts: attempts, unknownPaymentOutcome: unknownPaymentOutcome,
              unresolvedReceiptKeys: unresolvedReceiptKeys, unmatchedPurchaseKey: unmatchedPurchaseKey)
    }
    private func writeJournal(_ value: TipJournal) throws {
        guard journalIssue == nil else { throw TipIssue.invalidJournal }
        let data = try JSONEncoder().encode(value)
        guard data.count <= 2_097_152, value.receipts.count <= 4096,
              value.attempts.count <= 1024, value.unresolvedReceiptKeys.count <= 4096 else { throw TipIssue.journalTooLarge }
        try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: journalURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalURL.path)
    }
    private func persistProtection() {
        do { try writeJournal(durableJournal); needsRetrySave = false }
        catch { needsRetrySave = true; diagnostic = String(describing: error); status = .uncertain }
    }
    /// Persists already captured facts only. Never calls purchase or invents an outcome.
    public func retrySave() {
        guard needsRetrySave, !purchasing else { return }
        persistProtection(); status = protectedPaymentStatus ?? .idle
    }
    private func associateVerified(_ fact: TipReceipt, purchase: UUID) throws {
        _ = try validatedReceipt(fact)
        guard purchaseID == purchase, let attempt = attempts[purchase.uuidString],
              attempt.productID == fact.productID, attempt.scope.bundleID == fact.bundleID,
              attempt.scope.environment == fact.environment,
              attempt.receiptKey == nil || attempt.receiptKey == fact.key,
              [.dispatching, .awaitingRecord, .completed].contains(attempt.phase) else { throw TipIssue.invalidTransaction }
        if attempt.phase == .completed { return }
        attempts[purchase.uuidString]?.phase = .awaitingRecord
        attempts[purchase.uuidString]?.receiptKey = fact.key
        // Retain the exact captured association in memory on a write failure,
        // and persist it before credentials/receipt acknowledgment. Cold recovery
        // may resolve only an association that actually reached durable storage.
        do { try writeJournal(durableJournal); needsRetrySave = false }
        catch { needsRetrySave = true; throw error }
    }
    private func receive(_ result: VerificationResult<Transaction>, purchase: UUID? = nil) async {
        switch result {
        case .unverified(_, _):
            if let purchase { completePurchase(purchase, phase: .unknown, reason: "StoreKit transaction verification failed") }
            else { markUnverified("StoreKit transaction verification failed") }
        case .verified(let transaction):
            guard transaction.productType == .consumable else { markUnverified("Unexpected StoreKit product type"); return }
            await acceptVerified(Self.fact(transaction), credential: result.jwsRepresentation, purchase: purchase) { await transaction.finish() }
        }
    }
    func acceptVerified(_ fact: TipReceipt, credential: String? = nil, purchase: UUID? = nil, finish: () async -> Void) async {
        do {
            let revision = eventRevision, scopeGeneration = recoveryGeneration
            if let purchase { try associateVerified(fact, purchase: purchase) }
            let fresh = try await persistVerified(fact, credential: credential)
            if fresh { pendingAcknowledgments.insert(fact.key) }
            defer { if fresh { pendingAcknowledgments.remove(fact.key) } }
            // No acknowledgment before persistence; callbacks can reenter while finishing.
            await finish()
            // An older completion must not erase a newer failure for the same receipt.
            let resolvedReceipt = eventRevision == revision && unresolvedReceiptKeys.remove(fact.key) != nil
            if resolvedReceipt { persistProtection() }
            if let purchase, purchaseID == purchase {
                if eventRevision != revision && [.uncertain, .failed].contains(status) { return }
                // An explicit purchase finishes even if history/updates recorded it first or
                // app reactivation rechecked the same account while StoreKit was finishing.
                // Never attribute the old account's acknowledgment to a newly verified account.
                let sameAccount = fact.accountID == nil || verifiedScope?.contains(fact) == true
                let active = journal[fact.key]?.revoked == false
                if active && !sameAccount { unmatchedPurchaseKey = fact.key }
                else if unmatchedPurchaseKey == fact.key { unmatchedPurchaseKey = nil }
                persistProtection()
                status = protectedPaymentStatus ?? (active ? .thanked : .idle)
                if protectedPaymentStatus == nil { diagnostic = nil }
                eventRevision &+= 1
                return
            }
            guard eventRevision == revision, recoveryGeneration == scopeGeneration,
                  fact.accountID == nil || verifiedScope?.contains(fact) == true,
                  journal[fact.key]?.revoked == fact.revoked else { return }
            let resolvedUnmatched = unmatchedPurchaseKey == fact.key
            if resolvedUnmatched { unmatchedPurchaseKey = nil; persistProtection() }
            if let protected = protectedPaymentStatus {
                // Retain real, durably verified history without treating an
                // unrelated update/refund as resolution of a protected payment.
                status = protected == .pending && fresh && !fact.revoked ? .uncertain : protected
                return
            }
            if (fresh || resolvedReceipt || resolvedUnmatched) && !fact.revoked {
                eventRevision &+= 1; diagnostic = nil; status = .thanked
            } else if fact.revoked || (status == .uncertain && !pendingAcknowledgments.contains(fact.key)) {
                eventRevision &+= 1; diagnostic = nil; status = .idle
            }
        } catch { markUnverified(String(describing: error), receiptKey: fact.key) }
    }
    func markUnverified(_ reason: String, receiptKey: String? = nil) {
        if let receiptKey, unresolvedReceiptKeys.count < 4096 { unresolvedReceiptKeys.insert(receiptKey) }
        else { unknownPaymentOutcome = true }
        eventRevision &+= 1; diagnostic = reason; status = .uncertain
        persistProtection()
    }
    /// Called only after StoreKit verification; fact injection is restricted to @testable tests.
    func persistVerified(_ fact: TipReceipt, credential: String?, generation: UInt64? = nil) async throws -> Bool {
        // Validate before writing sensitive material, then revalidate after the actor hop.
        // Keychain access can involve system services; it must not block the UI executor.
        _ = try preparedRecord(fact)
        if let credential { try await credentials.store(credential, for: fact) }
        if let generation {
            guard generation == recoveryGeneration, verifiedScope?.contains(fact) == true else { throw TipIssue.invalidTransaction }
        }
        return try recordVerified(fact)
    }
    private func validatedReceipt(_ fact: TipReceipt) throws -> TipReceipt {
        guard journalIssue == nil else { throw TipIssue.invalidJournal }
        guard allowedIDs.contains(fact.productID), fact.bundleID == bundleID,
              !fact.transactionID.isEmpty, validEnvironment(fact.environment),
              fact.amount.map({ !$0.isNaN && $0 >= 0 }) ?? true else { throw TipIssue.invalidTransaction }
        try fact.validateRefundSnapshot()
        let old = journal[fact.key]
        return try old?.merging(fact, currentSnapshotVerified: verifiedJournalKeys.contains(fact.key)) ?? fact
    }
    private func preparedRecord(_ fact: TipReceipt) throws -> [String: TipReceipt] {
        let merged = try validatedReceipt(fact)
        var next = journal; next[fact.key] = merged
        let data = try JSONEncoder().encode(next)
        guard data.count <= 2_097_152, next.count <= 4096 else { throw TipIssue.journalTooLarge }
        return next
    }
    func recordVerified(_ fact: TipReceipt) throws -> Bool {
        let old = journal[fact.key], next = try preparedRecord(fact)
        var envelope = durableJournal; envelope.receipts = next
        // Only associations established by a direct verified purchase callback
        // may settle here, including recovery through verified Transaction.all.
        for (id, attempt) in envelope.attempts where attempt.phase == .awaitingRecord && attempt.receiptKey == fact.key {
            guard attempt.productID == fact.productID, attempt.scope.bundleID == fact.bundleID,
                  attempt.scope.environment == fact.environment else { throw TipIssue.invalidTransaction }
            envelope.attempts[id]?.phase = .completed
            if fact.accountID != nil && verifiedScope?.contains(fact) != true { envelope.unmatchedPurchaseKey = fact.key }
        }
        if next != journal || envelope.attempts != attempts || envelope.unmatchedPurchaseKey != unmatchedPurchaseKey || needsRetrySave {
            try writeJournal(envelope)
            journal = next; attempts = envelope.attempts; unmatchedPurchaseKey = envelope.unmatchedPurchaseKey; needsRetrySave = false
        }
        verifiedJournalKeys.insert(fact.key)
        if verifiedScope?.contains(fact) == true {
            // Display facts come from this process's verified platform results, never a copied
            // local JSON field (even when this platform result has an unknown price).
            verifiedHistory[fact.key] = try verifiedHistory[fact.key]?.merging(fact) ?? fact
        }
        return old == nil
    }
    private func validEnvironment(_ environment: String) -> Bool {
        expectsLocalTest ? environment == AppStore.Environment.xcode.rawValue :
            [AppStore.Environment.production.rawValue, AppStore.Environment.sandbox.rawValue].contains(environment)
    }
}
/// Bounded local request evidence, separate from platform-verified receipts.
/// An account is a scope, never an order identifier.
struct TipAttempt: Codable, Equatable {
    enum Phase: String, Codable {
        case prepared, dispatching, pending, unknown, awaitingRecord, completed, cancelled
        var isUnresolved: Bool { [.dispatching, .pending, .unknown, .awaitingRecord].contains(self) }
    }
    let id: UUID
    let productID: String
    let scope: TipAccountScope
    let created: Date
    var phase: Phase
    var receiptKey: String?
}
struct TipJournal: Codable {
    let version: Int
    var receipts: [String: TipReceipt]
    var attempts: [String: TipAttempt]
    var unknownPaymentOutcome: Bool
    var unresolvedReceiptKeys: Set<String>
    var unmatchedPurchaseKey: String?
    init(receipts: [String: TipReceipt], attempts: [String: TipAttempt] = [:], unknownPaymentOutcome: Bool = false,
         unresolvedReceiptKeys: Set<String> = [], unmatchedPurchaseKey: String? = nil) {
        version = 1; self.receipts = receipts; self.attempts = attempts; self.unknownPaymentOutcome = unknownPaymentOutcome
        self.unresolvedReceiptKeys = unresolvedReceiptKeys; self.unmatchedPurchaseKey = unmatchedPurchaseKey
    }
}
struct TipAccountScope: Codable, Equatable {
    let bundleID: String
    let environment: String
    let accountID: String
    func contains(_ fact: TipReceipt) -> Bool {
        !accountID.isEmpty && fact.bundleID == bundleID && fact.environment == environment && fact.accountID == accountID
    }
}
struct TipReceipt: Codable, Equatable {
    let transactionID: String
    let productID: String
    let bundleID: String
    let environment: String
    let revoked: Bool
    let accountID: String?
    let purchaseDate: Date?
    let amount: Decimal?
    let currency: String?
    let revocationDate: Date?
    let signedDate: Date?
    let revocationType: String?
    let revocationPercentage: Decimal?
    let revocationReason: Int?
    init(transactionID: String, productID: String, bundleID: String, environment: String, revoked: Bool,
         accountID: String? = nil, purchaseDate: Date? = nil, amount: Decimal? = nil,
         currency: String? = nil, revocationDate: Date? = nil, signedDate: Date? = nil,
         revocationType: String? = nil, revocationPercentage: Decimal? = nil, revocationReason: Int? = nil) {
        self.transactionID = transactionID; self.productID = productID; self.bundleID = bundleID
        self.environment = environment; self.revoked = revoked; self.accountID = accountID?.nilIfEmpty
        self.purchaseDate = purchaseDate; self.amount = amount; self.currency = currency?.nilIfEmpty
        self.revocationDate = revocationDate; self.signedDate = signedDate
        self.revocationType = revocationType; self.revocationPercentage = revocationPercentage
        self.revocationReason = revocationReason
    }
    func validateRefundSnapshot() throws {
        guard revocationPercentage.map({ !$0.isNaN && $0 >= 0 && $0 <= 100 }) ?? true,
              signedDate.map({ $0.timeIntervalSince1970.isFinite }) ?? true,
              (revocationType?.utf8.count ?? 0) <= 256,
              revoked || (revocationDate == nil && revocationPercentage == nil && revocationType == nil && revocationReason == nil) else { throw TipIssue.invalidTransaction }
    }
    private func hasSameRefundSnapshot(as other: Self) -> Bool {
        revoked == other.revoked && revocationDate == other.revocationDate && revocationType == other.revocationType &&
        revocationPercentage == other.revocationPercentage && revocationReason == other.revocationReason
    }
    // Unambiguous composite encoding, including application and StoreKit environment.
    var key: String { [bundleID, environment, transactionID].map { "\($0.utf8.count):\($0)" }.joined() }
    func merging(_ newer: Self, currentSnapshotVerified: Bool = true) throws -> Self {
        try newer.validateRefundSnapshot()
        guard key == newer.key else { throw TipIssue.invalidTransaction }
        // A decoded cache is not evidence of any platform fact, not even immutable
        // price/account fields. Only compare facts verified in this process.
        guard currentSnapshotVerified else { return newer }
        guard productID == newer.productID,
              accountID == nil || newer.accountID == nil || accountID == newer.accountID,
              amount == nil || newer.amount == nil || amount == newer.amount,
              currency == nil || newer.currency == nil || currency == newer.currency,
              purchaseDate == nil || newer.purchaseDate == nil || purchaseDate == newer.purchaseDate else { throw TipIssue.invalidTransaction }
        let snapshot: Self
        if let oldDate = signedDate, let newDate = newer.signedDate {
            guard oldDate != newDate || hasSameRefundSnapshot(as: newer) else { throw TipIssue.invalidTransaction }
            snapshot = newDate > oldDate ? newer : self
        } else if newer.signedDate != nil {
            snapshot = newer
        } else if signedDate != nil {
            snapshot = self
        } else {
            // Legacy records carry no ordering proof. Retain their conservative refund rule.
            snapshot = revoked ? self : newer
        }
        return .init(transactionID: transactionID, productID: productID, bundleID: bundleID, environment: environment,
            revoked: snapshot.revoked, accountID: accountID ?? newer.accountID,
            purchaseDate: purchaseDate ?? newer.purchaseDate, amount: amount ?? newer.amount,
            currency: currency ?? newer.currency, revocationDate: snapshot.revocationDate,
            signedDate: snapshot.signedDate, revocationType: snapshot.revocationType,
            revocationPercentage: snapshot.revocationPercentage, revocationReason: snapshot.revocationReason)
    }
}
private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }
private enum TipIssue: Error { case invalidTransaction, invalidJournal, journalTooLarge, credentialUnavailable, credentialStatus(Int32) }

protocol TipCredentialVault: Sendable { func store(_ credential: String, for fact: TipReceipt) async throws }
/// Opaque signed evidence is append-only and deduplicated within the existing
/// bounded Keychain item. A late callback, including after a cold start, cannot
/// replace another signed snapshot. These bytes never authorize UI history;
/// that still requires current StoreKit verification and the matching account.
enum TipCredentialEvidence {
    static func adding(_ credential: String, for fact: TipReceipt, to values: [String: String]) throws -> [String: String] {
        guard credential.utf8.count <= 65_536 else { throw TipIssue.credentialUnavailable }
        if [":purchase", ":revoked"].contains(where: { values[fact.key + $0] == credential }) { return values }
        let digest = SHA256.hash(data: Data(credential.utf8)).map { String(format: "%02x", $0) }.joined()
        let key = fact.key + ":jws:" + digest
        var next = values; next[key] = credential
        guard next.count <= 4096, try JSONEncoder().encode(next).count <= 2_097_152 else { throw TipIssue.credentialUnavailable }
        return next
    }
}
/// One bounded item per app/journal, protected by the login Keychain and excluded from cloud sync.
/// The path digest isolates local-test sessions; StoreKit is the cross-device recovery source.
private actor TipKeychainVault: TipCredentialVault {
    private let query: [String: Any]
    init(bundleID: String, journalURL: URL) {
        let scope = SHA256.hash(data: Data(journalURL.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
        query = [kSecClass as String: kSecClassGenericPassword,
                 kSecAttrService as String: bundleID + ".verified-support-receipts",
                 kSecAttrAccount as String: scope]
        // Use D's existing macOS login-Keychain mechanism (as ModelDownloadKeychain does).
        // No shared access group or cloud synchronization is requested. The separate data-
        // protection store requires provisioned app-identifier entitlements absent from the
        // current normal development candidate; do not broaden signing privileges here.
    }
    func store(_ credential: String, for fact: TipReceipt) throws {
        var lookup = query; lookup[kSecReturnData as String] = true
        var raw: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &raw)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw TipIssue.credentialStatus(status) }
        var values: [String: String] = [:]
        if let data = raw as? Data {
            guard data.count <= 2_097_152 else { throw TipIssue.credentialUnavailable }
            values = try JSONDecoder().decode([String: String].self, from: data)
        }
        let next = try TipCredentialEvidence.adding(credential, for: fact, to: values)
        // Comparison and write occur in this actor without suspension. Old
        // purchase/refund slots remain readable; no signed evidence is removed.
        if next == values { return }
        let data = try JSONEncoder().encode(next)
        if status == errSecItemNotFound {
            var insert = query; insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let result = SecItemAdd(insert as CFDictionary, nil)
            guard result == errSecSuccess else { throw TipIssue.credentialStatus(result) }
        } else {
            let result = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            guard result == errSecSuccess else { throw TipIssue.credentialStatus(result) }
        }
    }
}
