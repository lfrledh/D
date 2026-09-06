// File: Packages/UI/Sources/UI/SidebarView.swift

import SwiftUI

enum LeftSidebarTab {
    case resources, parameters
}

enum RightSidebarTab {
    case history, details
}

struct SidebarView<Tab: Hashable, Content: View>: View {
    let tab: Binding<Tab>
    let content: Content
    let alignment: Edge

    init(tab: Binding<Tab>, @ViewBuilder content: () -> Content, alignment: Edge) {
        self.tab = tab
        self.content = content()
        self.alignment = alignment
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if Tab.self == LeftSidebarTab.self {
                Picker("", selection: tab) {
                    Text("Resources").tag(LeftSidebarTab.resources)
                    Text("Parameters").tag(LeftSidebarTab.parameters)
                }
                .pickerStyle(.segmented)
                .padding()
            } else if Tab.self == RightSidebarTab.self {
                Picker("", selection: tab) {
                    Text("History").tag(RightSidebarTab.history)
                    Text("Details").tag(RightSidebarTab.details)
                }
                .pickerStyle(.segmented)
                .padding()
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // 为悬浮的标签栏留出空间，避免内容被遮挡
                    Color.clear.frame(height: 40)
                    content
                        .padding()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: 20)
        )
        .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 5)
        .padding(alignment == .leading ? .leading : .trailing, 10)
        // 移除 .ignoresSafeArea，改用外层 padding
    }
}
