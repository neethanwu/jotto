import SwiftUI

/// Your numbers, then settings. Server and token sit here until Sign in
/// with Apple replaces them; the Spike 0 inbox is at the bottom.
struct AccountView: View {
    @State private var stats: Stats?
    private var config: AppConfig { .shared }
    private var uploader: Uploader { .shared }
    private var inbox: Inbox { .shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Account")
                    .dayTitleStyle()
                    .padding(.top, 72)

                numbers.padding(.top, 24)

                section("Recording") {
                    row("Audio kept", value: "\(stats?.audioRetentionDays ?? 30) days")
                    row("Text kept", value: "Always")
                    row("Share as", value: "Markdown")
                }

                section("Devices") {
                    row("Apple Watch", value: inbox.watchStatus.capitalizedFirst)
                    row("Waiting to upload", value: uploader.jobs.isEmpty ? "None" : Format.plural(uploader.jobs.count, "part"))
                    if let error = uploader.lastError, !uploader.jobs.isEmpty {
                        Text(error).font(.metaSmall).foregroundStyle(Color.jText3).padding(.vertical, 8)
                    }
                }

                section("Server") {
                    NavigationLink(value: Route.server) {
                        row("Connection", value: config.isReady ? (config.baseURL?.host() ?? "Set") : "Not set", chevron: true)
                    }
                    .buttonStyle(.plain)
                }

                section("For testing") {
                    NavigationLink(value: Route.inbox) {
                        row("Files from the watch", value: "\(inbox.items.count)", chevron: true)
                    }
                    .buttonStyle(.plain)
                }

                Text("Jotto \(Bundle.main.version)")
                    .font(.metaSmall)
                    .foregroundStyle(Color.jText4)
                    .padding(.top, 32)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 140)
        }
        .background(Color.jBg)
        .toolbar(.hidden, for: .navigationBar)
        .task { await load() }
        .refreshable { await load() }
    }

    private var numbers: some View {
        HStack(alignment: .top, spacing: 0) {
            stat(stats.map { "\($0.recordings)" } ?? "–", "recordings")
            stat(stats.map { Format.hours($0.seconds) } ?? "–", "recorded")
            stat(stats.map { Format.hours($0.lastSevenDays.seconds) } ?? "–", "last 7 days")
        }
        .padding(.vertical, 20)
        .overlay(alignment: .top) { Rectangle().fill(Color.jHairline).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(Color.jHairline).frame(height: 1) }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.scaled(28, .bold, relativeTo: .title1).monospacedDigit())
                .tracking(-0.56)
                .foregroundStyle(Color.jText)
            Text(label).font(.metaSmall).foregroundStyle(Color.jText3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.speaker)
                .foregroundStyle(Color.jText3)
                .padding(.bottom, 4)
            content()
        }
        .padding(.top, 32)
    }

    private func row(_ label: String, value: String, chevron: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.rowTitle).foregroundStyle(Color.jText)
            Spacer()
            Text(value).font(.settingValue).foregroundStyle(Color.jText2).lineLimit(1)
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.jText4)
            }
        }
        .frame(minHeight: 52)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) { Rectangle().fill(Color.jHairline).frame(height: 1) }
    }

    private func load() async {
        guard config.isReady else { return }
        stats = try? await API.stats()
    }
}

/// Server address and token, with a connection check.
struct ServerSettingsView: View {
    @Bindable var config: AppConfig
    @Environment(\.dismiss) private var dismiss
    @State private var check: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                CircleIconButton(systemName: "chevron.left", label: "Back") { dismiss() }
                Spacer()
            }
            .frame(height: 52)

            Text("Server").font(.transcriptTitle).tracking(-0.68).foregroundStyle(Color.jText).padding(.top, 12)

            field("Address") {
                TextField("https://jotto.up.railway.app", text: $config.serverURL)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            field("Token") {
                SecureField("From bun create-user", text: $config.token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            HStack(spacing: 12) {
                Button("Check connection") { Task { await testConnection() } }
                    .buttonStyle(PrimaryPillStyle())
                if let check {
                    Text(check).font(.summary).foregroundStyle(Color.jText2)
                }
            }
            .padding(.top, 28)
            Spacer()
        }
        .padding(.horizontal, 20)
        .background(Color.jBg)
        .toolbar(.hidden, for: .navigationBar)
        .onDisappear {
            Uploader.shared.retryAll()
            Task { await Library.shared.refresh() }
        }
    }

    private func field<Field: View>(_ label: String, @ViewBuilder _ content: () -> Field) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.speaker).foregroundStyle(Color.jText3)
            content()
                .font(.rowTitle)
                .padding(.horizontal, 16)
                .frame(height: 52)
                .background(Color.jFill, in: RoundedRectangle(cornerRadius: 16))
        }
        .padding(.top, 24)
    }

    private func testConnection() async {
        check = "Checking"
        do {
            let sessions = try await API.sessions()
            check = "Connected · \(Format.plural(sessions.count, "recording"))"
        } catch {
            check = error.localizedDescription
        }
    }
}

extension Format {
    /// "3 h 18", "46 min", for the Account numbers.
    static func hours(_ seconds: Int) -> String {
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) min" }
        return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60)"
    }
}

extension Bundle {
    var version: String {
        let v = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
