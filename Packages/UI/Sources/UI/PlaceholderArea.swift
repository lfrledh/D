import SwiftUI

struct PlaceholderArea: View {
    let text: String
    var body: some View {
        Text(text)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
