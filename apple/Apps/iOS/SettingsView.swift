import SwiftUI

struct SettingsView: View {
    @Bindable var config: AppConfig
    @State private var check: String?

    var body: some View {
        Form {
            Section {
                TextField("https://jotto.up.railway.app", text: $config.serverURL)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Token", text: $config.token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Server")
            } footer: {
                Text("The server admin makes tokens with `bun create-user`.")
            }

            Section {
                Button("Test connection") { Task { await testConnection() } }
                if let check {
                    Text(check).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Settings")
        .onDisappear { Uploader.shared.retryAll() }
    }

    private func testConnection() async {
        check = "Connecting…"
        do {
            let sessions = try await API.sessions()
            check = "✅ Connected, \(sessions.count) recordings"
        } catch {
            check = "❌ \(error.localizedDescription)"
        }
    }
}
