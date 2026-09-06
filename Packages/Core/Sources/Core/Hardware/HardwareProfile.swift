// Path: Core/Sources/Core/Hardware/HardwareProfile.swift

import Foundation
import Darwin

/// Immutable snapshot of system hardware capabilities.
public struct HardwareProfile: Sendable, Equatable {
    public let totalMemoryBytes: UInt64
    public let availableMemoryBytes: UInt64
    public let budgetFraction: Double
    public let inferenceBudgetBytes: UInt64
    public let performanceCoreCount: Int
    public let gpuCoreCount: Int

    public init(budgetFraction: Double = 0.75) {
        precondition(budgetFraction > 0 && budgetFraction <= 1.0)

        self.budgetFraction = budgetFraction
        self.totalMemoryBytes = ProcessInfo.processInfo.physicalMemory

        let available = Self.queryAvailableMemory()
        self.availableMemoryBytes = available

        let budgetFromTotal = UInt64(Double(totalMemoryBytes) * budgetFraction)
        self.inferenceBudgetBytes = min(available, budgetFromTotal)

        self.performanceCoreCount = Self.queryCoreCount(key: "hw.perflevel0.logicalcpu")
        self.gpuCoreCount = Self.queryGPUCoreCount()
    }

    // Test-friendly initializer
    public init(
        totalMemoryBytes: UInt64,
        availableMemoryBytes: UInt64,
        budgetFraction: Double,
        performanceCoreCount: Int,
        gpuCoreCount: Int
    ) {
        precondition(budgetFraction > 0 && budgetFraction <= 1.0)
        self.totalMemoryBytes = totalMemoryBytes
        self.availableMemoryBytes = availableMemoryBytes
        self.budgetFraction = budgetFraction
        self.inferenceBudgetBytes = min(availableMemoryBytes, UInt64(Double(totalMemoryBytes) * budgetFraction))
        self.performanceCoreCount = performanceCoreCount
        self.gpuCoreCount = gpuCoreCount
    }

    public var formattedTotalMemory: String { Self.formatBytes(totalMemoryBytes) }
    public var formattedInferenceBudget: String { Self.formatBytes(inferenceBudgetBytes) }

    // MARK: - Private Helpers
    private static func queryAvailableMemory() -> UInt64 {
        var pagesize: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        if sysctlbyname("hw.pagesize", &pagesize, &size, nil, 0) != 0 {
            pagesize = 16 * 1024
        }

        var vmStats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let hostPort = mach_host_self()

        let result = withUnsafeMutablePointer(to: &vmStats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { bound in
                host_statistics64(hostPort, HOST_VM_INFO64, bound, &count)
            }
        }

        if result == KERN_SUCCESS {
            let freePages = UInt64(vmStats.free_count)
            let purgeablePages = UInt64(vmStats.purgeable_count)
            return (freePages + purgeablePages) * pagesize
        }

        return UInt64(Double(ProcessInfo.processInfo.physicalMemory) * 0.80)
    }

    private static func queryCoreCount(key: String) -> Int {
        var count: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = sysctlbyname(key, &count, &size, nil, 0)
        if result == 0, count > 0 {
            return Int(count)
        }
        return ProcessInfo.processInfo.activeProcessorCount
    }

    private static func queryGPUCoreCount() -> Int {
        var count: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = sysctlbyname("machdep.gpu.core_count", &count, &size, nil, 0)
        if result == 0, count > 0 {
            return Int(count)
        }
        return 0
    }

    private static func formatBytes(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / (1024 * 1024 * 1024)
        return String(format: "%.1f GB", gb)
    }
}
