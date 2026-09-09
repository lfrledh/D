@testable import DRuntime
import Testing

@Suite("Inference resource budget policy")
struct ResourceBudgetPolicyTests {
    struct HostBudget: Sendable {
        let totalGiB: UInt64
        let expectedGiB: UInt64
    }

    private let gibibyte = UInt64(1024 * 1024 * 1024)

    @Test("Common host sizes retain one quarter", arguments: [
        HostBudget(totalGiB: 16, expectedGiB: 12),
        HostBudget(totalGiB: 32, expectedGiB: 24),
        HostBudget(totalGiB: 64, expectedGiB: 48),
        HostBudget(totalGiB: 128, expectedGiB: 96),
    ])
    func commonHostSizes(host: HostBudget) {
        let budget = ResourceBudgetPolicy().inferenceBudgetBytes(
            physicalMemoryBytes: host.totalGiB * gibibyte)
        #expect(budget == host.expectedGiB * gibibyte)
    }

    @Test("Small and boundary hosts saturate without a fallback", arguments: [
        UInt64(0), UInt64(1), UInt64(4 * 1024 * 1024 * 1024 - 1), UInt64(4 * 1024 * 1024 * 1024),
    ])
    func smallHosts(totalBytes: UInt64) {
        #expect(ResourceBudgetPolicy().inferenceBudgetBytes(physicalMemoryBytes: totalBytes) == 0)
    }

    @Test("A byte above the fixed reserve yields a one-byte budget")
    func fixedReserveBoundary() {
        let total = ResourceBudgetPolicy.minimumReservedBytes + 1
        #expect(ResourceBudgetPolicy().inferenceBudgetBytes(physicalMemoryBytes: total) == 1)
    }

    @Test("UInt64 maximum is handled without overflow")
    func maximumHostSize() {
        let total = UInt64.max
        #expect(ResourceBudgetPolicy().inferenceBudgetBytes(physicalMemoryBytes: total) == total - total / 4)
    }

    @Test("A conservative limit can only reduce the computed budget")
    func conservativeLimit() {
        let total = UInt64(32) * gibibyte
        #expect(ResourceBudgetPolicy(conservativeLimitBytes: 6 * gibibyte)
            .inferenceBudgetBytes(physicalMemoryBytes: total) == 6 * gibibyte)
        #expect(ResourceBudgetPolicy(conservativeLimitBytes: 30 * gibibyte)
            .inferenceBudgetBytes(physicalMemoryBytes: total) == 24 * gibibyte)
        #expect(ResourceBudgetPolicy(conservativeLimitBytes: 0)
            .inferenceBudgetBytes(physicalMemoryBytes: total) == 0)
    }

    @Test("The uncapped policy is monotonic across arithmetic boundaries")
    func monotonic() {
        let totals: [UInt64] = [
            0, 1, 4 * gibibyte, 4 * gibibyte + 1, 16 * gibibyte,
            32 * gibibyte, UInt64.max - 1, UInt64.max,
        ]
        let budgets = totals.map { ResourceBudgetPolicy().inferenceBudgetBytes(physicalMemoryBytes: $0) }
        #expect(zip(budgets, budgets.dropFirst()).allSatisfy { $0.0 <= $0.1 })
    }
}
