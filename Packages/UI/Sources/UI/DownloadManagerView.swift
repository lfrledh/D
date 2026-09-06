import SwiftUI
import Core

struct DownloadManagerView: View {
    @Bindable var viewModel: MainViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Download from Hugging Face")
                .font(.headline)

            TextField("Model ID", text: $viewModel.downloadModelID)
                .textFieldStyle(.roundedBorder)

            Button("Download") {
                Task { await viewModel.downloadModel() }
            }
            .disabled(viewModel.downloadModelID.isEmpty)

            Button("Open Downloads Folder") {
                viewModel.openDownloadsFolder()
            }
            .font(.caption)

            if !viewModel.downloadTasks.isEmpty {
                Text("Active Downloads")
                    .font(.headline)
                    .padding(.top, 8)
                ForEach(viewModel.downloadTasks, id: \.id) { task in
                    DownloadTaskRow(task: task, viewModel: viewModel)
                }
            }
        }
    }
}
