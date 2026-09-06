// File: Packages/UI/Sources/UI/MainView.swift

import SwiftUI
import Core
import AppKit

public struct MainView: View {
    @Bindable var viewModel: MainViewModel
    @State private var showingSettings = false
    @State private var selectedCapability: ModelCapability = .text
    @State private var leftSidebarTab: LeftSidebarTab = .resources
    @State private var rightSidebarTab: RightSidebarTab = .history
    @State private var sidebarOffset: CGFloat = 0
    @State private var assetOffset: CGFloat = 0
    @State private var contentOpacity: Double = 1
    @State private var leftSidebarTabForCapability: [ModelCapability: LeftSidebarTab] = [:]

    // 标题栏高度（实测大约28-30）
    private let titleBarHeight: CGFloat = 28

    public init(viewModel: MainViewModel) {
        self.viewModel = viewModel
        _selectedCapability = State(initialValue: viewModel.selectedCapability)
    }

    public var body: some View {
        ZStack(alignment: .top) {
            // 主内容区域
            HStack(spacing: 0) {
                SidebarView(tab: $leftSidebarTab, content: { leftSidebarContent }, alignment: .leading)
                    .frame(width: 280)
                    .offset(x: sidebarOffset)
                    .padding(.top, titleBarHeight) // 避开标题栏

                capabilityContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(contentOpacity)
                    .padding(.top, titleBarHeight) // 中央内容也避开标题栏

                SidebarView(tab: $rightSidebarTab, content: { rightSidebarContent }, alignment: .trailing)
                    .frame(width: 280)
                    .offset(x: assetOffset)
                    .padding(.top, titleBarHeight) // 避开标题栏
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // 顶部标签栏（悬浮）
            LiquidGlassTabBar(selectedCapability: $selectedCapability, onCapabilityChange: handleCapabilityChange)
                .padding(.top, titleBarHeight + 8) // 比边栏内容高一点
                .zIndex(1)

            // 设置按钮（左下角）
            VStack {
                Spacer()
                HStack {
                    Button(action: { showingSettings = true }) {
                        Image(systemName: "gear")
                            .font(.title2)
                            .padding(8)
                            .background(.regularMaterial, in: Circle())
                            .shadow(color: .black.opacity(0.1), radius: 5, x: 0, y: 2)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 20)
                    .padding(.bottom, 20)
                    Spacer()
                }
            }
            .zIndex(2)
        }
        .onAppear {
            configureWindow()
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
                .background(.regularMaterial)
        }
    }

    private func configureWindow() {
        if let window = NSApplication.shared.windows.first {
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            // 移除透明设置，恢复默认不透明背景
            // window.isOpaque = false  // 删除
            // window.backgroundColor = .clear  // 删除
            window.setContentSize(NSSize(width: 1200, height: 800))
        }
    }

    // MARK: - 动画处理
    private func handleCapabilityChange(newCapability: ModelCapability) {
        leftSidebarTabForCapability[selectedCapability] = leftSidebarTab

        withAnimation(.easeInOut(duration: 0.2)) {
            sidebarOffset = -300
            assetOffset = 300
            contentOpacity = 0
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            leftSidebarTab = leftSidebarTabForCapability[newCapability] ?? .resources
            selectedCapability = newCapability
            viewModel.selectedCapability = newCapability
            withAnimation(.easeInOut(duration: 0.2)) {
                sidebarOffset = 0
                assetOffset = 0
                contentOpacity = 1
            }
        }
    }

    // MARK: - 左边栏内容
    @ViewBuilder
    private var leftSidebarContent: some View {
        switch leftSidebarTab {
        case .resources:
            ProjectResourcesView(viewModel: viewModel, capability: selectedCapability)
        case .parameters:
            ParameterPanelView(capability: selectedCapability, viewModel: viewModel)
        }
    }

    // MARK: - 右边栏内容
    @ViewBuilder
    private var rightSidebarContent: some View {
        switch rightSidebarTab {
        case .history:
            AssetHistoryView(viewModel: viewModel)
        case .details:
            ResourceDetailPlaceholder()
        }
    }

    // MARK: - 中央内容区域
    @ViewBuilder
    private var capabilityContent: some View {
        switch selectedCapability {
        case .text:
            if let vm = viewModel.currentCapabilityViewModel as? TextCapabilityViewModel {
                TextGenerationArea(viewModel: vm)
            } else {
                Text("Text capability not available")
            }
        case .image:
            if let vm = viewModel.currentCapabilityViewModel as? ImageCapabilityViewModel {
                ImageGenerationArea(viewModel: vm)
            } else {
                Text("Image capability not available")
            }
        case .audio:
            PlaceholderArea(text: "Audio Generation")
        case .video:
            PlaceholderArea(text: "Video Generation")
        case .visionLanguage:
            PlaceholderArea(text: "Vision Language")
        }
    }
}
