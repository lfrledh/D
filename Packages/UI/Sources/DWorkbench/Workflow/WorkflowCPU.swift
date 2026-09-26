import Foundation

/// Owns a bounded CPU operation; cancellation is forwarded and the child is always drained.
/// This does not allocate a model lease or a second inference runtime.
enum WorkflowCPU {
    static func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try Task.checkCancellation()
        let child = Task.detached(priority: .userInitiated) { try Task.checkCancellation(); return try body() }
        return try await withTaskCancellationHandler {
            let result = try await child.value
            try Task.checkCancellation()
            return result
        } onCancel: { child.cancel() }
    }
}
