import AppKit
import Foundation
import Observation
import StoreKit
import CryptoKit
import Security

/// Application-owned StoreKit listener. No project, model or feature entitlement depends on tips.
@MainActor @Observable public final class TipStore {
    public enum Status: String { case idle, loading, unavailable, purchasing, pending, cancelled, thanked, recorded, failed, uncertain }
    public private(set) var products: [Product] = []
    public private(set) var status: Status = .idle
    public private(set) var diagnostic: String?
    public var selectedID: String?
    public var presented = false
    public private(set) var localTest = false
    public enum RecoveryFailure: String { case platform, verification, storage, credentials, capacity }
    public private(set) var recoveryFailure: RecoveryFailure?
    public enum RecoveryStatus { case idle, loading, ready, unavailable, failed }
    public private(set) var recoveryStatus: RecoveryStatus = .idle
    private(set) var verifiedScope: TipAccountScope?
    private(set) var recoveryGeneration: UInt64 = 0
    private var verifiedHistory: [String: TipReceipt] = [:]
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
    @ObservationIgnored private var loading = false
    @ObservationIgnored private var purchasing = false
    @ObservationIgnored private var purchaseID: UUID?
    // Only in-flight verified handlers own entries; defer removes them after finish.
    @ObservationIgnored private var pendingAcknowledgments: Set<String> = []
    /// Formal product identifiers remain undecided. The ordinary app supplies an empty allowlist.
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
                let old = try JSONDecoder().decode([String: TipReceipt].self, from: data)
                for (key, fact) in old {
                    // Legacy transaction-only keys migrate in memory, without assigning an account or price.
                    guard (key == fact.transactionID || key == fact.key), fact.bundleID == bundleID,
                          !fact.transactionID.isEmpty, journal[fact.key] == nil else { throw TipIssue.invalidJournal }
                    journal[fact.key] = fact
                }
            }
        } catch { journalIssue = String(describing: error); diagnostic = journalIssue; status = .uncertain }
    }
    deinit { listener?.cancel(); recovery?.cancel() }
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
        guard !allowedIDs.isEmpty else { products = []; status = .unavailable; return }
        loading = true; defer { loading = false }
        let revision = eventRevision, previous = status
        if ![.pending, .uncertain, .thanked].contains(status) { status = .loading; diagnostic = nil }
        do {
            await recoverHistory()
            if expectsLocalTest && !localTest { throw TipIssue.invalidTransaction }
            for await result in Transaction.unfinished { await receive(result) }
            let loaded = try await Product.products(for: allowedIDs)
            products = loaded.filter { allowedIDs.contains($0.id) && $0.type == .consumable }.sorted { $0.price < $1.price }
            if let selectedID, !products.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
            if eventRevision == revision {
                status = products.isEmpty ? .unavailable : [.pending, .uncertain, .thanked].contains(previous) ? previous : .idle
            }
        } catch {
            products = []
            if eventRevision == revision { diagnostic = String(describing: error); status = .unavailable }
        }
    }
    public var selectedProduct: Product? { products.first { $0.id == selectedID } }
    public var canPurchase: Bool { selectedProduct != nil && !purchasing && !loading && journalIssue == nil && ![.uncertain, .recorded, .pending].contains(status) && (!expectsLocalTest || localTest) }
    public func purchase(confirmIn window: NSWindow) async {
        guard canPurchase, let product = selectedProduct else { return }
        let attempt = beginPurchase()
        defer { purchasing = false; if purchaseID == attempt { purchaseID = nil } }
        do {
            switch try await product.purchase(confirmIn: window) {
            case .success(let result): await receive(result, purchase: attempt)
            case .userCancelled: status = .cancelled
            case .pending: status = .pending
            @unknown default: status = .uncertain
            }
        } catch StoreKitError.userCancelled { status = .cancelled }
        catch { diagnostic = String(describing: error); status = .failed }
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
        recoveryStatus = .loading; recoveryFailure = nil; return recoveryGeneration
    }
    func acceptScope(_ scope: TipAccountScope, generation: UInt64) throws {
        guard generation == recoveryGeneration, scope.bundleID == bundleID, !scope.accountID.isEmpty,
              validEnvironment(scope.environment) else { throw TipIssue.invalidTransaction }
        verifiedScope = scope
    }
    func mergeHistory(_ fact: TipReceipt, credential: String?, generation: UInt64) throws {
        guard generation == recoveryGeneration, verifiedScope?.contains(fact) == true else { throw TipIssue.invalidTransaction }
        _ = try recordVerified(fact, credential: credential)
    }
    func endRecovery(generation: UInt64, succeeded: Bool, failure: RecoveryFailure? = nil) {
        guard generation == recoveryGeneration else { return }
        recoveryStatus = succeeded ? .ready : .failed
        recoveryFailure = succeeded ? nil : failure ?? .platform
        if !succeeded { verifiedScope = nil; verifiedHistory.removeAll() }
    }
    public func recoverHistory() async {
        guard !allowedIDs.isEmpty else { recoveryStatus = .unavailable; return }
        let generation = beginRecovery()
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
                try mergeHistory(fact, credential: result.jwsRepresentation, generation: generation)
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
            endRecovery(generation: generation, succeeded: false, failure: failure)
        }
    }
    private static func fact(_ transaction: Transaction) -> TipReceipt {
        TipReceipt(transactionID: String(transaction.id), productID: transaction.productID,
            bundleID: transaction.appBundleID, environment: transaction.environment.rawValue,
            revoked: transaction.revocationDate != nil, accountID: transaction.appTransactionID.nilIfEmpty,
            purchaseDate: transaction.purchaseDate, amount: transaction.price,
            currency: transaction.currency?.identifier, revocationDate: transaction.revocationDate)
    }
    func beginPurchase() -> UUID {
        let id = UUID(); purchaseID = id; purchasing = true; status = .purchasing; diagnostic = nil; return id
    }
    private func receive(_ result: VerificationResult<Transaction>, purchase: UUID? = nil) async {
        switch result {
        case .unverified(_, _): markUnverified("StoreKit transaction verification failed")
        case .verified(let transaction):
            guard transaction.productType == .consumable else { markUnverified("Unexpected StoreKit product type"); return }
            await acceptVerified(Self.fact(transaction), credential: result.jwsRepresentation, purchase: purchase) { await transaction.finish() }
        }
    }
    func acceptVerified(_ fact: TipReceipt, credential: String? = nil, purchase: UUID? = nil, finish: () async -> Void) async {
        do {
            let fresh = try recordVerified(fact, credential: credential), revision = eventRevision, scopeGeneration = recoveryGeneration
            if fresh { pendingAcknowledgments.insert(fact.key) }
            defer { if fresh { pendingAcknowledgments.remove(fact.key) } }
            // No acknowledgment before persistence; callbacks can reenter while finishing.
            await finish()
            if let purchase, purchaseID == purchase {
                if eventRevision != revision && [.uncertain, .failed].contains(status) { return }
                // An explicit purchase finishes even if history/updates recorded it first or
                // app reactivation rechecked the same account while StoreKit was finishing.
                // Never attribute the old account's acknowledgment to a newly verified account.
                let sameAccount = fact.accountID == nil || verifiedScope?.contains(fact) == true
                status = journal[fact.key]?.revoked == false ? (sameAccount ? .thanked : .recorded) : .idle
                diagnostic = nil; eventRevision &+= 1
                return
            }
            guard eventRevision == revision, recoveryGeneration == scopeGeneration,
                  fact.accountID == nil || verifiedScope?.contains(fact) == true,
                  journal[fact.key]?.revoked == fact.revoked else { return }
            if fresh && !fact.revoked {
                eventRevision &+= 1; diagnostic = nil; status = .thanked
            } else if fact.revoked || (status == .uncertain && !pendingAcknowledgments.contains(fact.key)) {
                eventRevision &+= 1; diagnostic = nil; status = .idle
            }
        } catch { markUnverified(String(describing: error)) }
    }
    func markUnverified(_ reason: String) { eventRevision &+= 1; diagnostic = reason; status = .uncertain }
    /// Called only after StoreKit verification; fact injection is restricted to @testable tests.
    func recordVerified(_ fact: TipReceipt, credential: String? = nil) throws -> Bool {
        guard journalIssue == nil else { throw TipIssue.invalidJournal }
        guard allowedIDs.contains(fact.productID), fact.bundleID == bundleID,
              !fact.transactionID.isEmpty, validEnvironment(fact.environment),
              fact.amount.map({ !$0.isNaN && $0 >= 0 }) ?? true else { throw TipIssue.invalidTransaction }
        let old = journal[fact.key]
        let merged = try old?.merging(fact) ?? fact
        var next = journal; next[fact.key] = merged
        let data = try JSONEncoder().encode(next)
        guard data.count <= 2_097_152, next.count <= 4096 else { throw TipIssue.journalTooLarge }
        // Signed credentials stay in a bounded, app-local Keychain item, never in the JSON,
        // project, log or screenshot. A credential/write failure leaves StoreKit unacknowledged.
        if let credential { try credentials.store(credential, for: fact.key + (fact.revoked ? ":revoked" : ":purchase")) }
        if next != journal {
            try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: journalURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalURL.path)
            journal = next
        }
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
struct TipAccountScope: Equatable {
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
    init(transactionID: String, productID: String, bundleID: String, environment: String, revoked: Bool,
         accountID: String? = nil, purchaseDate: Date? = nil, amount: Decimal? = nil,
         currency: String? = nil, revocationDate: Date? = nil) {
        self.transactionID = transactionID; self.productID = productID; self.bundleID = bundleID
        self.environment = environment; self.revoked = revoked; self.accountID = accountID?.nilIfEmpty
        self.purchaseDate = purchaseDate; self.amount = amount; self.currency = currency?.nilIfEmpty
        self.revocationDate = revocationDate
    }
    // Unambiguous composite encoding, including application and StoreKit environment.
    var key: String { [bundleID, environment, transactionID].map { "\($0.utf8.count):\($0)" }.joined() }
    func merging(_ newer: Self) throws -> Self {
        guard key == newer.key, productID == newer.productID,
              accountID == nil || newer.accountID == nil || accountID == newer.accountID,
              amount == nil || newer.amount == nil || amount == newer.amount,
              currency == nil || newer.currency == nil || currency == newer.currency,
              purchaseDate == nil || newer.purchaseDate == nil || purchaseDate == newer.purchaseDate else { throw TipIssue.invalidTransaction }
        return .init(transactionID: transactionID, productID: productID, bundleID: bundleID, environment: environment,
            revoked: revoked || newer.revoked, accountID: accountID ?? newer.accountID,
            purchaseDate: purchaseDate ?? newer.purchaseDate, amount: amount ?? newer.amount,
            currency: currency ?? newer.currency, revocationDate: revocationDate ?? newer.revocationDate)
    }
}
private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }
private enum TipIssue: Error { case invalidTransaction, invalidJournal, journalTooLarge, credentialUnavailable, credentialStatus(Int32) }

@MainActor protocol TipCredentialVault { func store(_ credential: String, for key: String) throws }
/// One bounded item per app/journal, protected by the login Keychain and excluded from cloud sync.
/// The path digest isolates local-test sessions; StoreKit is the cross-device recovery source.
@MainActor private final class TipKeychainVault: TipCredentialVault {
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
    func store(_ credential: String, for key: String) throws {
        guard credential.utf8.count <= 65_536 else { throw TipIssue.credentialUnavailable }
        var lookup = query; lookup[kSecReturnData as String] = true
        var raw: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &raw)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw TipIssue.credentialStatus(status) }
        var values: [String: String] = [:]
        if let data = raw as? Data {
            guard data.count <= 2_097_152 else { throw TipIssue.credentialUnavailable }
            values = try JSONDecoder().decode([String: String].self, from: data)
        }
        if values[key] == credential { return }
        values[key] = credential
        let data = try JSONEncoder().encode(values)
        guard data.count <= 2_097_152, values.count <= 4096 else { throw TipIssue.credentialUnavailable }
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
