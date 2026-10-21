import DInference
import DWorkbench
import SwiftUI

struct WorkbenchTasks: View {
    @Environment(\.dLanguageStore) private var consistencyLanguage
    @Bindable var model: WorkbenchModel
    @Binding var isExpanded: Bool

    private var jobs: [ProjectJob] { model.manifest?.jobs ?? [] }
    private var activeCount: Int { model.activeJobIDs.count }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(jobs.reversed(), id: \.id) { job in
                        taskRow(job)
                        if job.id != jobs.first?.id { Divider().padding(.leading, 32) }
                    }
                }
            }
            .frame(maxHeight: min(CGFloat(jobs.count) * 76, 200))
            .accessibilityIdentifier("task-list")
        } label: {
            HStack(spacing: 8) {
                Label(consistencyText(consistencyLanguage, "remaining.5253040db864"), systemImage: "list.bullet.rectangle")
                    .font(.callout.weight(.medium))
                if activeCount > 0 {
                    Text(consistencyText(consistencyLanguage, "remaining.ffe9e45f850a", arguments: ["v0": String(describing: activeCount)])).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(consistencyText(consistencyLanguage, "remaining.def1f85c66f0", arguments: ["v0": String(describing: jobs.count)])).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if activeCount > 0 { ProgressView().controlSize(.small) }
            }
            .padding(.vertical, 5)
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .background(.background)
    }

    private func taskRow(_ job: ProjectJob) -> some View {
        let state = model.liveStates[job.id] ?? job.state
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol(for: state))
                .foregroundStyle(color(for: state))
                .frame(width: 20).padding(.top, 2)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(prompt(for: job)).font(.callout).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(model.projectSession.phaseCodes[job.id].map { workspaceText(consistencyLanguage, "phase." + $0) } ?? model.phases[job.id] ?? workflowText(consistencyLanguage, "workflow.jobStatus." + state.rawValue))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(color(for: state))
                        .lineLimit(1)
                        .help(model.projectSession.phaseCodes[job.id].map { workspaceText(consistencyLanguage, "phase." + $0) } ?? model.phases[job.id] ?? workflowText(consistencyLanguage, "workflow.jobStatus." + state.rawValue))
                        .accessibilityIdentifier("task-state-\(job.id.uuidString)")
                }
                if let error = job.error {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2).help(error).textSelection(.enabled)
                } else {
                    HStack(spacing: 8) {
                        Text(job.createdAt.formatted(date: .omitted, time: .shortened))
                        if case .image(let image) = job.request.input {
                            Text(workflowText(consistencyLanguage, "workbench.seedValue", arguments: ["seed": String(image.seed)])).monospacedDigit()
                        }
                        if state == .cancelling || state == .releasing {
                            Text(consistencyText(consistencyLanguage, "remaining.4db1b71be31b"))
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if model.activeJobIDs.contains(job.id), let progress = model.progress[job.id] {
                    ProgressView(value: min(max(progress, 0), 1))
                        .controlSize(.small)
                        .accessibilityLabel(consistencyText(consistencyLanguage, "remaining.65d984613714"))
                }
            }
            if model.activeJobIDs.contains(job.id) {
                Button {
                    Task { await model.cancel(job.id) }
                } label: {
                    Image(systemName: "xmark.circle")
                        .font(.body).foregroundStyle(.secondary)
                }
                .buttonStyle(WorkbenchGlassButtonStyle(compact: true))
                .disabled(!model.canCancel(job.id))
                .help(consistencyText(consistencyLanguage, "remaining.fb653466ebee"))
                .accessibilityLabel(consistencyText(consistencyLanguage, "remaining.537d17f1c531"))
                .accessibilityIdentifier("cancel-task-\(job.id.uuidString)")
            } else if let assetID = job.artifactIDs.first {
                Button {
                    Task { await model.revealAsset(assetID) }
                } label: {
                    Image(systemName: "arrow.up.right.square")
                }
                .buttonStyle(WorkbenchGlassButtonStyle(compact: true))
                .help(consistencyText(consistencyLanguage, "remaining.cc40ce33895e"))
                .accessibilityLabel(consistencyText(consistencyLanguage, "remaining.cc40ce33895e"))
            }
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("task-\(job.id.uuidString)")
    }

    private func prompt(for job: ProjectJob) -> String {
        switch job.request.input {
        case .image(let request): request.prompt
        case .text(let request): request.prompt
        case .audio(let request): request.prompt
        case .video(let request): request.prompt
        case .pitch: consistencyText(consistencyLanguage, "remaining.39f01774c448")
        case .singing: consistencyText(consistencyLanguage, "remaining.25bc4d7a7980")
        }
    }

    private func symbol(for state: JobState) -> String {
        switch state {
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        case .cancelled, .interrupted: "minus.circle"
        case .queued: "clock"
        case .cancelling, .releasing: "hourglass"
        case .saving: "externaldrive"
        case .preparing, .generating: "sparkles"
        }
    }

    private func color(for state: JobState) -> Color {
        switch state {
        case .completed: .green
        case .failed: .orange
        case .cancelled, .interrupted, .queued: .secondary
        case .preparing, .generating, .cancelling, .releasing, .saving: .primary
        }
    }
}
