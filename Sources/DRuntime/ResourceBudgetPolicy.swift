import Foundation

/// Host-supplied arithmetic policy for the process inference budget.
/// This is an admission budget, not a measurement of currently available memory
/// or a guarantee that an allocation cannot fail.
public struct ResourceBudgetPolicy: Sendable, Equatable {
    public static let minimumReservedBytes: UInt64 = 4 * 1024 * 1024 * 1024

    /// An optional caller-selected ceiling for a more conservative deployment.
    public let conservativeLimitBytes: UInt64?

    public init(conservativeLimitBytes: UInt64? = nil) {
        self.conservativeLimitBytes = conservativeLimitBytes
    }

    /// Reserves the greater of 4 GiB and one quarter of physical memory.
    /// Subtraction saturates for hosts too small to provide the required reserve.
    public func inferenceBudgetBytes(physicalMemoryBytes: UInt64) -> UInt64 {
        let reservedBytes = max(Self.minimumReservedBytes, physicalMemoryBytes / 4)
        let physicalBudget = physicalMemoryBytes > reservedBytes
            ? physicalMemoryBytes - reservedBytes
            : 0
        return min(physicalBudget, conservativeLimitBytes ?? UInt64.max)
    }
}
