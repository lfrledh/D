import SwiftUI
import Core

struct ParameterPanelView: View {
    let capability: ModelCapability
    let viewModel: MainViewModel

    var body: some View {
        switch capability {
        case .text:
            if let textVM = viewModel.currentCapabilityViewModel as? TextCapabilityViewModel {
                TextParameterPanel(viewModel: textVM)
            } else {
                Text("Text parameters unavailable")
            }
        case .image:
            if let imageVM = viewModel.currentCapabilityViewModel as? ImageCapabilityViewModel {
                ImageParameterPanel(viewModel: imageVM)
            } else {
                Text("Image parameters unavailable")
            }
        default:
            Text("No parameters for this modality")
                .foregroundColor(.secondary)
        }
    }
}

struct TextParameterPanel: View {
    @Bindable var viewModel: TextCapabilityViewModel

    var body: some View {
        Form {
            Section("Sampling") {
                VStack(alignment: .leading) {
                    Text("Temperature: \(viewModel.temperature, specifier: "%.2f")")
                    Slider(value: $viewModel.temperature, in: 0.0...2.0, step: 0.05)
                }
                VStack(alignment: .leading) {
                    Text("Top-K: \(viewModel.topK)")
                    Slider(value: .init(
                        get: { Double(viewModel.topK) },
                        set: { viewModel.topK = Int($0) }
                    ), in: 1...100, step: 1)
                }
                VStack(alignment: .leading) {
                    Text("Top-P: \(viewModel.topP, specifier: "%.2f")")
                    Slider(value: $viewModel.topP, in: 0.0...1.0, step: 0.01)
                }
            }
            Section("Repetition Penalty") {
                VStack(alignment: .leading) {
                    Text("Penalty: \(viewModel.repetitionPenalty, specifier: "%.2f")")
                    Slider(value: $viewModel.repetitionPenalty, in: 1.0...2.0, step: 0.05)
                }
                VStack(alignment: .leading) {
                    Text("Window Size: \(viewModel.penaltyWindowSize)")
                    Slider(value: .init(
                        get: { Double(viewModel.penaltyWindowSize) },
                        set: { viewModel.penaltyWindowSize = Int($0) }
                    ), in: 0...512, step: 8)
                }
            }
            Section("Generation") {
                VStack(alignment: .leading) {
                    Text("Max New Tokens: \(viewModel.maxTokens)")
                    Slider(value: .init(
                        get: { Double(viewModel.maxTokens) },
                        set: { viewModel.maxTokens = Int($0) }
                    ), in: 1...2048, step: 16)
                }
            }
        }
    }
}

struct ImageParameterPanel: View {
    @Bindable var viewModel: ImageCapabilityViewModel

    var body: some View {
        Form {
            Section("Image Generation") {
                VStack(alignment: .leading) {
                    Text("Steps: \(viewModel.steps)")
                    Slider(value: .init(
                        get: { Double(viewModel.steps) },
                        set: { viewModel.steps = Int($0) }
                    ), in: 1...50, step: 1)
                }
                VStack(alignment: .leading) {
                    Text("Guidance Scale: \(viewModel.guidanceScale, specifier: "%.1f")")
                    Slider(value: $viewModel.guidanceScale, in: 1.0...15.0, step: 0.5)
                }
                VStack(alignment: .leading) {
                    Text("Seed: \(viewModel.seed ?? 0)")
                    HStack {
                        TextField("Seed", value: Binding(
                            get: { viewModel.seed ?? 0 },
                            set: { viewModel.seed = $0 == 0 ? nil : $0 }
                        ), format: .number)
                            .textFieldStyle(.roundedBorder)
                        Button("Random") {
                            viewModel.seed = UInt64.random(in: 0..<UInt64.max)
                        }
                    }
                }
                VStack(alignment: .leading) {
                    Text("Width: \(viewModel.width)")
                    Slider(value: .init(
                        get: { Double(viewModel.width) },
                        set: { viewModel.width = Int($0) }
                    ), in: 64...1024, step: 64)
                }
                VStack(alignment: .leading) {
                    Text("Height: \(viewModel.height)")
                    Slider(value: .init(
                        get: { Double(viewModel.height) },
                        set: { viewModel.height = Int($0) }
                    ), in: 64...1024, step: 64)
                }
            }
        }
    }
}
