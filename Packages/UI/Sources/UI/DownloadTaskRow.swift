import SwiftUI
import Core

struct DownloadTaskRow: View {
    let task: DownloadTaskHandle
    let viewModel: MainViewModel
    @State private var status: DownloadStatus = .waiting

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(task.modelId)
                .font(.caption)
                .lineLimit(1)

            switch status {
            case .waiting:
                Text("Waiting...")
                    .font(.caption2)
            case .downloading(let progress, let speed):
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                HStack {
                    Text("\(Int(progress * 100))%")
                    if let speed = speed {
                        Text(formatSpeed(speed))
                    }
                    Spacer()
                    Button("Pause") { task.pause() }
                        .font(.caption2)
                    Button("Cancel") { task.cancel(deleteFiles: false) }
                        .font(.caption2)
                }
                .font(.caption2)
            case .paused:
                Text("Paused")
                    .font(.caption2)
                HStack {
                    Button("Resume") { task.resume() }
                        .font(.caption2)
                    Button("Cancel") { task.cancel(deleteFiles: false) }
                        .font(.caption2)
                }
            case .completed(let modelDir):
                HStack {
                    Text("Completed")
                        .font(.caption2)
                        .foregroundColor(.green)
                    Spacer()
                    // 暂时禁用 Load 按钮，待后续完善
                    // Button("Load") {
                    //     Task { await viewModel.loadDownloadedModel(from: modelDir, for: ...) }
                    // }
                    // .font(.caption2)
                    Button("Delete") {
                        task.cancel(deleteFiles: true)
                    }
                    .font(.caption2)
                }
            case .failed(let errorMessage):
                Text("Failed: \(errorMessage)")
                    .font(.caption2)
                    .foregroundColor(.red)
                Button("Delete") {
                    task.cancel(deleteFiles: true)
                }
                .font(.caption2)
            }
        }
        .padding(4)
        .background(Color.gray.opacity(0.1))
        .cornerRadius(4)
        .onReceive(NotificationCenter.default.publisher(for: .downloadTaskUpdated)) { notification in
            if let id = notification.userInfo?["id"] as? UUID, id == task.id {
                status = task.status
            }
        }
    }

    private func formatSpeed(_ bytesPerSec: Double) -> String {
        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var converted = bytesPerSec
        var unitIndex = 0
        while converted > 1024 && unitIndex < units.count - 1 {
            converted /= 1024
            unitIndex += 1
        }
        return String(format: "%.1f %@", converted, units[unitIndex])
    }
}
