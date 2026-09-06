import SwiftUI
import Core

struct TextGenerationArea: View {
    @Bindable var viewModel: TextCapabilityViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Prompt")
                .font(.headline)
            TextEditor(text: $viewModel.prompt)
                .font(.body)
                .frame(minHeight: 100)
                .border(Color.gray.opacity(0.2), width: 1)

            HStack {
                Button("Generate") {
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
                Text(viewModel.generatedText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .border(Color.gray.opacity(0.2), width: 1)
        }
        .padding()
    }
}
