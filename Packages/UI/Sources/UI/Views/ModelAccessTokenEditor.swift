import SwiftUI

struct ModelAccessTokenEditor: View {
    let model: ModelLibraryModel
    @Environment(\.dLanguageStore) private var language
    @WorkbenchDismiss private var dismiss
    @State private var token = ""
    @State private var persistent = false
    @State private var saving = false
    @State private var failure: String?
    private func t(_ key: String) -> String { workflowText(language, "modelManagement." + key) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(t("tokenReadScope")).fixedSize(horizontal: false, vertical: true)
            SecureField(t("accessToken"), text: $token).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("model-access-token")
            Toggle(t("saveKeychain"), isOn: $persistent)
            Text(t("tokenLifetime")).font(.caption).foregroundStyle(.secondary)
            if let failure { Text(failure).foregroundStyle(.red).textSelection(.enabled) }
            Spacer(minLength: 0)
            HStack {
                Button(t("cancel")) { dismiss() }
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button(t("validateConnect")) {
                    saving = true; failure = nil
                    Task { @MainActor in
                        defer { saving = false }
                        do { try await model.connectDownloadToken(token, saveToKeychain: persistent); token = ""; $dismiss() }
                        catch { failure = model.credentialMessage(error) }
                    }
                }.disabled(token.isEmpty || !model.canChangeDownloadCredential)
            }
        }.padding(20).disabled(saving)
        .workbenchCloseProtection(isDirty: !token.isEmpty || persistent, isSaving: saving)
        .onDisappear { token = "" }
    }
}
