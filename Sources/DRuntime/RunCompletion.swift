import DInference

/// A separate lifetime from the runtime's queue: finished jobs do not accumulate in the scheduler.
actor RunCompletion {
    private var result: RunOutcome?
    private var executionRecord: InferenceExecutionRecord?
    private var waiters: [CheckedContinuation<RunOutcome, Never>] = []

    func record(_ value: InferenceExecutionRecord) { executionRecord = value }
    func record() -> InferenceExecutionRecord? { executionRecord }

    func wait() async -> RunOutcome {
        if let result { return result }
        return await withCheckedContinuation { waiters.append($0) }
    }

    func resolve(_ outcome: RunOutcome) {
        guard result == nil else { return }
        result = outcome
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume(returning: outcome) }
    }
}
