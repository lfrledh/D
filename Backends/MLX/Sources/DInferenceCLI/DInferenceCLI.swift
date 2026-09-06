import Darwin
import DInference
import DMLXBackend
import DRuntime
import Foundation

@main
@MainActor
struct DInferenceCLI {
    static func main() async {
        // A closed stdout pipe should trigger managed cancellation, not terminate before cleanup.
        signal(SIGPIPE, SIG_IGN)
        let arguments = Array(CommandLine.arguments.dropFirst())
        let started = ProcessInfo.processInfo.systemUptime
        var report = CLIReport()
        var reportPath = CLIOptions.reportDestination(in: arguments)
        var runtime: InferenceRuntime?
        let control = ExecutionControl()
        var signalMonitor: SignalMonitor?

        do {
            guard let options = try CLIOptions.parse(arguments) else {
                try CLIOutput.text(CLIOptions.usage + "\n")
                return
            }
            report.options = options
            reportPath = options.report
            signalMonitor = SignalMonitor(control: control)
            let recorder = LifecycleRecorder()
            let backend = try MLXTextBackend(observer: { event in await recorder.append(event) })
            report.backend = backend.descriptor
            let engine = try InferenceRuntime(
                backends: [backend],
                configuration: RuntimeConfiguration(memoryBudgetBytes: options.memoryBudgetBytes))
            runtime = engine

            for iteration in 1...options.repeatCount {
                if await control.interruption != nil { break }
                let runReport = await execute(iteration: iteration, options: options,
                                              runtime: engine, recorder: recorder, control: control)
                report.runs.append(runReport)
                if runReport.outcome == "failed" || runReport.outputError != nil {
                    report.exitCode = 1
                } else if runReport.outcome == "cancelled", report.exitCode == 0 {
                    report.exitCode = 130
                }
            }
        } catch let error as CLIArgumentError {
            report.failure = error.localizedDescription
            report.exitCode = 2
            CLIOutput.diagnostic(error.localizedDescription + "\n" + CLIOptions.usage)
        } catch {
            report.failure = error.localizedDescription
            report.exitCode = 1
            CLIOutput.diagnostic("Execution failed: \(error.localizedDescription)")
        }

        // Outcome awaits per-run cleanup; shutdown also closes admission and drains any residual work.
        await runtime?.shutdown()
        await signalMonitor?.stop()
        if let interruption = await control.interruption {
            report.terminationSignal = interruption.number
            report.exitCode = 130
        }
        report.elapsedSeconds = ProcessInfo.processInfo.systemUptime - started
        if let reportPath {
            do {
                try report.write(to: reportPath)
                CLIOutput.diagnostic("Report saved: \(URL(fileURLWithPath: reportPath).path)")
            } catch {
                report.exitCode = 1
                CLIOutput.diagnostic("Cannot save report: \(error.localizedDescription)")
            }
        }
        signalMonitor?.restore()
        exit(report.exitCode)
    }

    private static func execute(iteration: Int, options: CLIOptions,
                                runtime: InferenceRuntime,
                                recorder: LifecycleRecorder,
                                control: ExecutionControl) async -> CLIRunReport {
        let request = InferenceRequest(
            model: ModelReference(directory: URL(fileURLWithPath: options.model), revision: options.revision),
            input: .text(TextRequest(prompt: options.prompt, maxTokens: options.maxTokens,
                                     temperature: options.temperature, topP: options.topP)))
        let started = ProcessInfo.processInfo.systemUptime
        var report = CLIRunReport(iteration: iteration, runID: request.id, startedAt: Date())
        CLIOutput.diagnostic("Run \(iteration)/\(options.repeatCount): \(request.id)")

        do {
            let run = try await runtime.submit(request, backendID: "mlx.text")
            await control.activate(run)
            var outputFailure: String?
            do {
                for try await event in run.events {
                    guard case .textDelta(let fragment) = event else { continue }
                    report.chunkCount += 1
                    report.text += fragment
                    if report.firstChunkSeconds == nil {
                        report.firstChunkSeconds = ProcessInfo.processInfo.systemUptime - started
                    }
                    if outputFailure == nil {
                        do { try CLIOutput.text(fragment) }
                        catch { outputFailure = error.localizedDescription }
                    }
                    let thresholdReached = options.cancelAfterChunks.map { report.chunkCount >= $0 } ?? false
                    if report.cancellationRequestedSeconds == nil, thresholdReached || outputFailure != nil {
                        report.cancellationRequestedSeconds = ProcessInfo.processInfo.systemUptime - started
                        await run.cancel()
                        // Keep consuming until the stream terminates; never abandon the task here.
                    }
                }
            } catch {
                report.streamError = error.localizedDescription
            }

            let outcome = await run.outcome()
            await control.clear(run.id)
            let finished = ProcessInfo.processInfo.systemUptime - started
            if report.cancellationRequestedSeconds == nil, case .cancelled = outcome,
               let interruption = await control.interruption {
                report.cancellationRequestedSeconds = max(0, interruption.uptimeSeconds - started)
            }
            if let requested = report.cancellationRequestedSeconds {
                report.cancellationLatencySeconds = max(0, finished - requested)
            }
            switch outcome {
            case .completed(let result):
                report.outcome = "completed"
                report.result = result
            case .cancelled:
                report.outcome = "cancelled"
            case .failed(let failure):
                report.outcome = "failed"
                report.failure = failure
                report.errorMessage = failure.localizedDescription
            }
            if let outputFailure {
                report.outputError = "Cannot write stdout: \(outputFailure)"
            }
            if outputFailure == nil {
                do { try CLIOutput.text("\n") }
                catch {
                    report.outputError = "Cannot write stdout: \(error.localizedDescription)"
                }
            }
        } catch {
            report.outcome = "failed"
            report.failure = error as? InferenceFailure
            report.errorMessage = error.localizedDescription
        }
        report.lifecycle = await recorder.take(for: request.id)
        report.elapsedSeconds = ProcessInfo.processInfo.systemUptime - started
        CLIOutput.diagnostic("Run \(iteration): \(report.outcome), \(report.chunkCount) chunks, "
            + String(format: "%.3f seconds", report.elapsedSeconds))
        if let errorMessage = report.errorMessage { CLIOutput.diagnostic(errorMessage) }
        if let outputError = report.outputError { CLIOutput.diagnostic(outputError) }
        return report
    }
}
