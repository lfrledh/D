import SwiftUI

public struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("downloadPath") private var downloadPath: String = {
        // 默认路径：Documents/huggingface_cache
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documents.appendingPathComponent("huggingface_cache").path
    }()
    @State private var isShowingFilePicker = false
    @State private var tempPath: String = ""

    public init() {
        // 初始化时从 UserDefaults 读取，但 @AppStorage 会自动处理
    }

    public var body: some View {
        Form {
            Section(header: Text("Download Location")) {
                HStack {
                    TextField("Path", text: $tempPath)
                        .textFieldStyle(.roundedBorder)
                        .onAppear {
                            // 初始化临时路径为当前存储值
                            tempPath = downloadPath
                        }
                    Button("Browse...") {
                        isShowingFilePicker = true
                    }
                }
            }

            Section {
                HStack {
                    Button("Cancel") {
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)

                    Spacer()

                    Button("Save") {
                        // 保存新路径
                        downloadPath = tempPath
                        setenv("HF_HOME", tempPath, 1)
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding()
        .frame(width: 500, height: 200)
        .fileImporter(
            isPresented: $isShowingFilePicker,
            allowedContentTypes: [.folder],
            onCompletion: { result in
                switch result {
                case .success(let url):
                    // 用户选择的文件夹路径
                    tempPath = url.path
                case .failure(let error):
                    print("Error selecting folder: \(error)")
                }
            }
        )
    }
}
