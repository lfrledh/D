import Darwin
import DInference
import Dispatch
import Foundation

struct SignalInterruption: Sendable {
    let number: Int32
    let uptimeSeconds: Double
}

/// Serializes signal arrival with run registration, including the gap before submit returns.
actor ExecutionControl {
    private var activeRun: InferenceRun?
    private(set) var interruption: SignalInterruption?

    func activate(_ run: InferenceRun) async {
        activeRun = run
        if interruption != nil { await run.cancel() }
    }

    func clear(_ runID: UUID) {
        if activeRun?.id == runID { activeRun = nil }
    }

    func interrupt(with number: Int32) async {
        if interruption == nil {
            interruption = SignalInterruption(number: number,
                uptimeSeconds: ProcessInfo.processInfo.systemUptime)
            CLIOutput.diagnostic("Received signal \(number); cancelling and waiting for cleanup.")
        }
        await activeRun?.cancel()
    }
}

/// Dispatch callbacks only yield values. One owned task performs asynchronous cancellation.
@MainActor
final class SignalMonitor {
    private let sources: [any DispatchSourceSignal]
    private let continuation: AsyncStream<Int32>.Continuation
    private let task: Task<Void, Never>
    private let restoreDispositions: () -> Void

    init(control: ExecutionControl) {
        let oldInterrupt = signal(SIGINT, SIG_IGN)
        let oldTerminate = signal(SIGTERM, SIG_IGN)
        restoreDispositions = {
            signal(SIGINT, oldInterrupt)
            signal(SIGTERM, oldTerminate)
        }
        let (stream, continuation) = AsyncStream<Int32>.makeStream(bufferingPolicy: .bufferingOldest(1))
        self.continuation = continuation
        self.task = Task {
            for await number in stream { await control.interrupt(with: number) }
        }
        self.sources = [SIGINT, SIGTERM].map { number in
            let source = DispatchSource.makeSignalSource(signal: number,
                queue: DispatchQueue.global(qos: .userInitiated))
            // Dispatch invokes this off the main actor; an explicitly Sendable callback
            // prevents Swift from inheriting the initializer's actor isolation.
            source.setEventHandler { @Sendable [continuation, number] in
                continuation.yield(number)
            }
            source.resume()
            return source
        }
    }

    func stop() async {
        // Cancel handlers run after pending event callbacks. Await them before closing the stream.
        for source in sources {
            await withCheckedContinuation { (completion: CheckedContinuation<Void, Never>) in
                source.setCancelHandler { @Sendable [completion] in completion.resume() }
                source.cancel()
            }
        }
        continuation.finish()
        await task.value
    }

    /// Keep dispositions ignored until the drained report has been written.
    func restore() { restoreDispositions() }
}
