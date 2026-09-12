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
        var imageBackend: MLXImageBackend?
        let control = ExecutionControl()
        var signalMonitor: SignalMonitor?

        do {
            guard let options = try CLIOptions.parse(arguments) else {
                try CLIOutput.text(CLIOptions.usage + "\n")
                return
            }
            report.options = options
            reportPath = options.report
            if !options.inspect { signalMonitor = SignalMonitor(control: control) }
            let recorder = LifecycleRecorder()
            let backend: any InferenceBackend
            switch options.capability {
            case .text:
                backend = try MLXTextBackend(
                    configuration: MLXBackendConfiguration(
                        maximumPromptTokens: options.maxPromptTokens,
                        maximumOutputTokens: options.maxOutputTokens,
                        cacheLimitBytes: options.cacheLimitBytes),
                    observer: { event in await recorder.append(event) })
            case .image:
                guard let path = options.artifacts else {
                    throw CLIArgumentError("Image mode requires --artifacts.")
                }
                let directory = URL(fileURLWithPath: path, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let image = try MLXImageBackend(configuration: .init(
                                                   artifactDirectory: directory,
                                                   profile: options.selectedImageProfile,
                                                   memoryLimitBytes: options.imageMemoryLimitBytes),
                                               observer: { event in await recorder.append(event) })
                if !options.inspect { imageBackend = image }
                backend = image
            case .audio:
                guard let artifactPath = options.artifacts,
                      let python = options.audioPython,
                      let script = options.audioScript,
                      let vendor = options.audioVendor,
                      let manifest = options.audioManifest,
                      let profile = options.audioProfile else {
                    throw CLIArgumentError("Audio launch configuration is incomplete.")
                }
                let directory = URL(fileURLWithPath: artifactPath, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                backend = try MLXAudioBackend(configuration: AudioBackendConfiguration(
                    pythonExecutable: URL(fileURLWithPath: python),
                    providerScript: URL(fileURLWithPath: script),
                    vendorDirectory: URL(fileURLWithPath: vendor, isDirectory: true),
                    modelManifest: URL(fileURLWithPath: manifest),
                    artifactDirectory: directory,
                    profile: profile,
                    licenseAcknowledged: options.audioLicenseAcknowledged,
                    timeoutSeconds: options.timeoutSeconds))
            }
            report.backend = backend.descriptor
            if options.inspect {
                let estimate = try await backend.estimate(makeRequest(options: options))
                report.inspection = CLIInspection(
                    estimate: estimate, withinBudget: estimate.peakBytes <= options.memoryBudgetBytes)
            } else {
                let engine = try InferenceRuntime(
                    backends: [backend],
                    configuration: RuntimeConfiguration(memoryBudgetBytes: options.memoryBudgetBytes))
                runtime = engine

                for iteration in 1...options.repeatCount {
                    if await control.interruption != nil { break }
                    let runReport = await execute(iteration: iteration, options: options,
                                                  runtime: engine, recorder: recorder, control: control,
                                                  imageBackend: imageBackend)
                    report.runs.append(runReport)
                    if runReport.outcome == "failed" || runReport.outputError != nil
                        || runReport.artifactCleanupError != nil {
                        report.exitCode = 1
                    } else if runReport.outcome == "cancelled", report.exitCode == 0 {
                        report.exitCode = 130
                    }
                    if options.capability != .text, report.exitCode != 0 { break }
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
        do { try await imageBackend?.cleanupUnpublishedArtifacts() }
        catch {
            report.artifactCleanupError = error.localizedDescription
            report.exitCode = 1
            CLIOutput.diagnostic("Artifact cleanup failed: \(error.localizedDescription)")
        }
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
                                control: ExecutionControl,
                                imageBackend: MLXImageBackend?) async -> CLIRunReport {
        let request = makeRequest(options: options)
        let started = ProcessInfo.processInfo.systemUptime
        var report = CLIRunReport(iteration: iteration, runID: request.id, startedAt: Date())
        report.request = request
        CLIOutput.diagnostic("Run \(iteration)/\(options.repeatCount): \(request.id)")

        do {
            let run = try await runtime.submit(request, backendID: options.backendID)
            await control.activate(run)
            var outputFailure: String?
            do {
                for try await event in run.events {
                    var thresholdReached = false
                    let elapsed = ProcessInfo.processInfo.systemUptime - started
                    switch event {
                    case .textDelta(let fragment):
                        report.chunkCount += 1
                        report.text += fragment
                        if report.firstChunkSeconds == nil { report.firstChunkSeconds = elapsed }
                        if outputFailure == nil {
                            do { try CLIOutput.text(fragment) }
                            catch { outputFailure = error.localizedDescription }
                        }
                        thresholdReached = options.cancelAfterChunks.map { report.chunkCount >= $0 } ?? false
                    case .progress(let completed, let total):
                        report.progress.append(CLIProgress(completed: completed, total: total, elapsedSeconds: elapsed))
                        if report.firstProgressSeconds == nil { report.firstProgressSeconds = elapsed }
                        CLIOutput.diagnostic("[\(request.id)] progress \(completed)/\(total)")
                        thresholdReached = options.cancelAfterSteps.map { completed >= $0 } ?? false
                    case .artifact(let artifact):
                        // Retain the reference before attempting stdout: published files survive
                        // output failure and remain discoverable in the execution report.
                        report.artifacts.append(artifact)
                        if report.firstArtifactSeconds == nil { report.firstArtifactSeconds = elapsed }
                        if outputFailure == nil {
                            do { try CLIOutput.artifact(artifact, runID: request.id) }
                            catch { outputFailure = error.localizedDescription }
                        }
                    case .preview:
                        break
                    }
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
                // A backend may return a final artifact without an earlier artifact event.
                for artifact in result.artifacts where !report.artifacts.contains(artifact) {
                    report.artifacts.append(artifact)
                    if report.firstArtifactSeconds == nil {
                        report.firstArtifactSeconds = ProcessInfo.processInfo.systemUptime - started
                    }
                    if outputFailure == nil, options.capability != .text {
                        do { try CLIOutput.artifact(artifact, runID: request.id) }
                        catch { outputFailure = error.localizedDescription }
                    }
                }
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
            if outputFailure == nil, options.capability == .text {
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
        // The run has drained before this host-owned cleanup. Published artifacts are retained.
        do { try await imageBackend?.cleanupUnpublishedArtifacts() }
        catch {
            report.artifactCleanupError = error.localizedDescription
            CLIOutput.diagnostic("Artifact cleanup failed: \(error.localizedDescription)")
        }
        report.lifecycle = await recorder.take(for: request.id)
        report.elapsedSeconds = ProcessInfo.processInfo.systemUptime - started
        let outputCount = options.capability == .text
            ? "\(report.chunkCount) chunks" : "\(report.artifacts.count) artifacts"
        CLIOutput.diagnostic("Run \(iteration): \(report.outcome), \(outputCount), "
            + String(format: "%.3f seconds", report.elapsedSeconds))
        if let errorMessage = report.errorMessage { CLIOutput.diagnostic(errorMessage) }
        if let outputError = report.outputError { CLIOutput.diagnostic(outputError) }
        return report
    }

    private static func makeRequest(options: CLIOptions) -> InferenceRequest {
        let input: InferenceInput
        switch options.capability {
        case .text:
            input = .text(TextRequest(prompt: options.prompt, maxTokens: options.maxTokens,
                                      temperature: options.temperature, topP: options.topP))
        case .image:
            input = .image(ImageRequest(prompt: options.prompt, width: options.width,
                                        height: options.height, steps: options.steps,
                                        guidanceScale: options.guidance, seed: options.seed))
        case .audio:
            let source: AudioSourceReference? = options.audioSource.map {
                AudioSourceReference(
                    url: URL(fileURLWithPath: $0),
                    sha256: options.audioSourceSHA256!,
                    frameCount: options.audioSourceFrames!, sampleRate: 44_100, channels: 2)
            }
            let region: AudioEditRegion?
            if let start = options.audioEditStartFrame, let end = options.audioEditEndFrame {
                region = AudioEditRegion(startFrame: start, endFrame: end)
            } else { region = nil }
            input = .audio(AudioRequest(
                operation: options.audioOperation, prompt: options.prompt,
                durationSeconds: options.durationSeconds, seed: options.seed,
                steps: options.steps, guidanceScale: options.guidance,
                strength: options.audioStrength, source: source, editRegion: region))
        }
        return InferenceRequest(
            model: ModelReference(directory: URL(fileURLWithPath: options.model), revision: options.revision),
            input: input)
    }
}
