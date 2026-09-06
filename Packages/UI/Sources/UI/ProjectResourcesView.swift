// File: Packages/UI/Sources/UI/ProjectResourcesView.swift

import SwiftUI
import Core

struct ProjectResourcesView: View {
    @Bindable var viewModel: MainViewModel
    let capability: ModelCapability

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 通用组件：下载管理器放在最上面
            DownloadManagerView(viewModel: viewModel)

            Divider()
                .padding(.vertical, 4)

            // 模态敏感组件：模型加载区域
            Group {
                if capability == .text {
                    textModelSection
                } else if capability == .image {
                    imageModelSection
                } else {
                    Text("Model loading not yet implemented for this modality")
                        .foregroundColor(.secondary)
                }
            }

            Spacer()
        }
    }

    @ViewBuilder
    private var textModelSection: some View {
        if let textVM = viewModel.currentCapabilityViewModel as? TextCapabilityViewModel {
            VStack(alignment: .leading, spacing: 12) {
                Text("Text Model")
                    .font(.headline)

                Button("Select Model Folder") {
                    textVM.selectModelFolder()
                }
                .buttonStyle(.bordered)

                if let url = textVM.selectedModelURL {
                    Text(url.lastPathComponent)
                        .font(.caption)
                }

                if textVM.isModelLoading {
                    ProgressView()
                }

                HStack {
                    Button("Load") {
                        Task { await textVM.loadSelectedModel() }
                    }
                    .disabled(textVM.selectedModelURL == nil || textVM.isModelLoading)

                    Button("Unload") {
                        Task { await textVM.unloadModel() }
                    }
                    .disabled(!textVM.isModelLoaded)
                }

                if textVM.isModelLoaded {
                    Label("Model loaded", systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green)
                }

                if let error = textVM.errorMessage {
                    Text(error)
                        .foregroundColor(.red)
                }
            }
        } else {
            Text("Text capability not available")
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private var imageModelSection: some View {
        if let imageVM = viewModel.currentCapabilityViewModel as? ImageCapabilityViewModel {
            VStack(alignment: .leading, spacing: 12) {
                Text("Image Model")
                    .font(.headline)

                Button("Select Model Folder") {
                    imageVM.selectModelFolder()
                }
                .buttonStyle(.bordered)

                if let url = imageVM.selectedModelURL {
                    Text(url.lastPathComponent)
                        .font(.caption)
                }

                if imageVM.isModelLoading {
                    ProgressView()
                }

                HStack {
                    Button("Load") {
                        Task { await imageVM.loadSelectedModel() }
                    }
                    .disabled(imageVM.selectedModelURL == nil || imageVM.isModelLoading)

                    Button("Unload") {
                        Task { await imageVM.unloadModel() }
                    }
                    .disabled(!imageVM.isModelLoaded)
                }

                if imageVM.isModelLoaded {
                    Label("Model loaded", systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green)
                }

                if let error = imageVM.errorMessage {
                    Text(error)
                        .foregroundColor(.red)
                }
            }
        } else {
            Text("Image capability not available")
                .foregroundColor(.secondary)
        }
    }
}
