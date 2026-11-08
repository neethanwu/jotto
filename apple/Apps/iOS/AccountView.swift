import SwiftUI

/// Your numbers, then settings. Server and token sit here until Sign in
/// with Apple replaces them; the Spike 0 inbox is at the bottom.
struct AccountView: View {
    @State private var stats: Stats?
    private var config: AppConfig { .shared }
    private var uploader: Uploader { .shared }
    private var inbox: Inbox { .shared }
    private var library: Library { .shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                BrandBar()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Account")
                        .dayTitleStyle()
                    Text("Beta · signed in with a server token")
                        .font(.metaSmall)
                        .foregroundStyle(Color.jText3)
                }
                .padding(.top, 20)

                MonthCard(entries: library.entries)
                    .padding(.top, 24)

                section("Keeping and sending", first: true) {
                    row("Keep audio", value: "\(stats?.audioRetentionDays ?? 30) days")
                    row("Send as", value: "Markdown", last: true)
                }

                section("Devices") {
                    row("Apple Watch", value: inbox.watchStatus.capitalizedFirst)
                    row("Waiting to upload", value: uploader.jobs.isEmpty ? "None" : Format.plural(uploader.jobs.count, "part"),
                        last: uploader.lastError == nil || uploader.jobs.isEmpty)
                    if let error = uploader.lastError, !uploader.jobs.isEmpty {
                        Text(error).font(.metaSmall).foregroundStyle(Color.jText3).padding(.vertical, 8)
                    }
                }

                section("Server") {
                    NavigationLink(value: Route.server) {
                        row("Connection", value: config.isReady ? (config.baseURL?.host() ?? "Set") : "Not set", chevron: true, last: true)
                    }
                    .buttonStyle(.plain)
                }

                section("For testing") {
                    NavigationLink(value: Route.inbox) {
                        row("Files from the watch", value: "\(inbox.items.count)", chevron: true, last: true)
                    }
                    .buttonStyle(.plain)
                }

                HStack {
                    Text("Jotto \(Bundle.main.version) · beta")
                    Spacer()
                    Text("built by neethan")
                }
                .font(.scaled(11, .medium, relativeTo: .caption2).monospacedDigit())
                .foregroundStyle(Color.jText4)
                .padding(.top, 28)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 140)
        }
        .background(Color.jBg)
        .toolbar(.hidden, for: .navigationBar)
        .task { await load() }
        .refreshable { await load() }
    }

    private func section<Content: View>(_ title: String, first: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.scaled(11, .medium, relativeTo: .caption2))
                .foregroundStyle(Color.jText3)
                .padding(.bottom, 6)
            content()
        }
        .padding(.top, first ? 28 : 24)
    }

    private func row(_ label: String, value: String, chevron: Bool = false, last: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.reading).foregroundStyle(Color.jText)
            Spacer()
            Text(value)
                .font(.scaled(15, .medium, relativeTo: .subheadline))
                .foregroundStyle(Color.jText2)
                .lineLimit(1)
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.jText4)
            }
        }
        .frame(minHeight: 50)
        .contentShape(Rectangle())
        .overlay(alignment: .top) { Rectangle().fill(Color.jHairline).frame(height: 1) }
        .overlay(alignment: .bottom) {
            if last { Rectangle().fill(Color.jHairline).frame(height: 1) }
        }
    }

    private func load() async {
        guard config.isReady else { return }
        stats = try? await API.stats()
        await library.refresh()
    }
}

/// This month at a glance: how much was recorded, and a dot per day,
/// filled on days with recordings, orange for today.
struct MonthCard: View {
    let entries: [TimelineEntry]

    var body: some View {
        let calendar = Calendar.current
        let now = Date.now
        let month = calendar.dateInterval(of: .month, for: now)
        let inMonth = entries.filter { month?.contains($0.startedAt) ?? false }
        let seconds = inMonth.compactMap(\.length).reduce(0, +)
        let recordedDays = Set(inMonth.map { calendar.component(.day, from: $0.startedAt) })
        let days = calendar.range(of: .day, in: .month, for: now)?.count ?? 30
        let today = calendar.component(.day, from: now)
        let (big, small) = Self.amount(seconds)

        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(now.formatted(.dateTime.month(.wide)))
                Spacer()
                Text(Format.plural(inMonth.count, "recording"))
            }
            .font(.scaled(11, .medium, relativeTo: .caption2).monospacedDigit())
            .foregroundStyle(Color.jText3)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(big)
                    .font(.scaled(40, .semibold, relativeTo: .largeTitle).monospacedDigit())
                    .tracking(-0.8)
                    .foregroundStyle(Color.jText)
                Text(small)
                    .font(.scaled(15, .medium, relativeTo: .subheadline))
                    .foregroundStyle(Color.jText2)
            }
            .accessibilityElement(children: .combine)

            HStack(spacing: 0) {
                ForEach(1...days, id: \.self) { day in
                    Circle()
                        .fill(day == today ? Color.jLive : recordedDays.contains(day) ? Color.jText : Color.jText5)
                        .frame(width: 6, height: 6)
                        .opacity(day > today ? 0 : 1)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 14)
            .accessibilityHidden(true)
        }
        .padding(18)
        .background(Color.jSurface, in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(Color.jHairline, lineWidth: 1))
    }

    /// "12 h 40" + "min recorded", "46" + "min recorded", "3 h" + "recorded".
    static func amount(_ seconds: TimeInterval) -> (String, String) {
        let minutes = Int(seconds / 60)
        if minutes < 60 { return ("\(minutes)", "min recorded") }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? ("\(h) h", "recorded") : ("\(h) h \(m)", "min recorded")
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
