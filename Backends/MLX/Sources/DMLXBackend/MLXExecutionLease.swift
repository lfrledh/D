import DInference
import Foundation

/// MLX allocator settings and its default streams are process-wide. This gate covers all
/// text and image backend instances through release, including instances in different runtimes.
/// It cannot coordinate unrelated legacy/third-party MLX callers in the same process.
actor MLXExecutionLease {
    static let shared = MLXExecutionLease()
    private var owner: UUID?

    func acquire(_ token: UUID) throws {
        guard owner == nil else {
            throw InferenceFailure.backendFailed("Another MLX backend still owns the process execution lease.")
        }
        owner = token
    }

    func relinquish(_ token: UUID) {
        if owner == token { owner = nil }
    }
}
