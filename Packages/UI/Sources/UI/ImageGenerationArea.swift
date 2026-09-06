import SwiftUI
import Core

struct ImageGenerationArea: View {
    @Bindable var viewModel: ImageCapabilityViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Prompt")
                .font(.headline)
            TextEditor(text: $viewModel.prompt)
                .font(.body)
                .frame(minHeight: 100)
                .border(Color.gray.opacity(0.2), width: 1)

            HStack {
                Button("Generate Image") {
                    viewModel.generate()
                }
                .disabled(viewModel.isGenerating || !viewModel.isModelLoaded)
                .buttonStyle(.borderedProminent)

                Button("Cancel") {
                    viewModel.cancel()
                }
                .disabled(!viewModel.isGenerating)
                .buttonStyle(.bordered)
            }

            Text("Output")
                .font(.headline)
            ScrollView {
                if let image = viewModel.generatedImages.last {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Text("No image generated")
                }
            }
            .border(Color.gray.opacity(0.2), width: 1)
        }
        .padding()
    }
}
