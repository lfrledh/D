import SwiftUI
import Core

struct AssetHistoryView: View {
    let viewModel: MainViewModel

    var body: some View {
        if let imageVM = viewModel.currentCapabilityViewModel as? ImageCapabilityViewModel {
            if imageVM.generatedImages.isEmpty {
                Text("No generated images yet")
                    .foregroundColor(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))], spacing: 8) {
                    ForEach(imageVM.generatedImages.indices, id: \.self) { index in
                        Image(nsImage: imageVM.generatedImages[index])
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 80, height: 80)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        } else {
            Text("No image capability")
                .foregroundColor(.secondary)
        }
    }
}
