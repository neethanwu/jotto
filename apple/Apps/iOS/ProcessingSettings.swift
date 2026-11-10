import Speech
import SwiftUI

/// Where recordings turn into text. On this iPhone is the default; the
/// test server stays for the beta until its recordings are imported.
/// "Your own API key" joins these two in step 3 (docs/06).
struct ProcessingView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var config: AppConfig = .shared
    @State private var check: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(title: "Processing", detail: "How your recordings turn into text.") { dismiss() }

                VStack(spacing: 10) {
                    ChoiceCard(
                        title: "On this iPhone",
                        detail: "Free, and nothing leaves your phone. Best in one language. Doesn't tell speakers apart.",
                        selected: config.processesLocally
                    ) { choose(local: true) }
                    ChoiceCard(
                        title: "Test server",
                        detail: "For the beta. The server transcribes and keeps your recordings, and tells speakers apart.",
                        selected: !config.processesLocally
                    ) { choose(local: false) }
                }
                .padding(.top, 24)

                if !config.processesLocally {
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
                    .padding(.top, 24)
                } else if config.isReady {
                    ImportSection()
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 48)
        }
        .scrollDismissesKeyboard(.immediately)
        .statusBarCover()
        .background(Color.jBg)
        .toolbar(.hidden, for: .navigationBar)
        .sensoryFeedback(.selection, trigger: config.processesLocally)
        .onDisappear {
            if !config.processesLocally { Uploader.shared.retryAll() }
            Task { await Library.shared.refresh() }
        }
    }

    private func choose(local: Bool) {
        guard config.processesLocally != local else { return }
        withAnimation(.easeOut(duration: 0.2)) { config.processesLocally = local }
        Task { await Library.shared.refresh() }
        if local { Pipeline.shared.run() }
    }

    private func field<Field: View>(_ label: String, @ViewBuilder _ content: () -> Field) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.scaled(11, .medium, relativeTo: .caption2))
                .foregroundStyle(Color.jText3)
            content()
                .font(.rowTitle)
                .padding(.horizontal, 16)
                .frame(height: 52)
                .background(Color.jFill, in: RoundedRectangle(cornerRadius: 26))
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

/// Shown on this iPhone while a test server is still set up: brings its
/// recordings over, so nothing is lost when the server goes away.
private struct ImportSection: View {
    let importer = ServerImport.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recordings on the test server")
                .font(.scaled(11, .medium, relativeTo: .caption2))
                .foregroundStyle(Color.jText3)
            Text("Copies finished recordings with their text, speakers and titles. Audio comes too if it is newer than your Keep audio setting. The server keeps its copy.")
                .font(.scaled(14, .regular, relativeTo: .subheadline))
                .foregroundStyle(Color.jText2)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                Button(importer.isRunning ? "Importing" : "Import to this iPhone") { importer.start() }
                    .buttonStyle(PrimaryPillStyle())
                    .fixedSize()
                    .disabled(importer.isRunning)
                if let status {
                    Text(status)
                        .font(.summary)
                        .foregroundStyle(Color.jText2)
                        .contentTransition(.numericText())
                }
            }
            .padding(.top, 8)
        }
        .padding(.top, 32)
        .animation(.easeOut(duration: 0.2), value: importer.state)
    }

    private var status: String? {
        switch importer.state {
        case .idle: nil
        case let .running(done, total): total == 0 ? "Looking" : "\(done) of \(total)"
        case let .finished(imported, unfinished, failed):
            [imported == 0 ? "Nothing new" : "\(Format.plural(imported, "recording")) imported",
             unfinished > 0 ? "\(unfinished) still processing" : nil,
             failed > 0 ? "\(failed) failed, try again" : nil]
                .compactMap { $0 }.joined(separator: " · ")
        case let .failed(message): message
        }
    }
}

/// A large pick-one option: title, a sentence on what it means, and a
/// filled check when chosen.
struct ChoiceCard: View {
    let title: String
    let detail: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle().strokeBorder(Color.jText5, lineWidth: 1.5).opacity(selected ? 0 : 1)
                    Circle().fill(Color.jText).opacity(selected ? 1 : 0)
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(Color.jBg)
                        .opacity(selected ? 1 : 0)
                }
                .frame(width: 22, height: 22)
                .padding(.top, 1)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.rowTitle).foregroundStyle(Color.jText)
                    Text(detail)
                        .font(.scaled(14, .regular, relativeTo: .subheadline))
                        .foregroundStyle(Color.jText2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .background(selected ? Color.jSurface : Color.jBg, in: RoundedRectangle(cornerRadius: 20))
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(selected ? Color.jText : Color.jHairline, lineWidth: selected ? 1.5 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The language on-device transcription listens for. Automatic follows
/// the system's preferred languages.
struct LanguageView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var config: AppConfig = .shared
    @State private var locales: [Locale] = []
    @State private var installed: Set<String> = []
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(title: "Language", detail: "The language people mostly speak in your recordings. Other languages come out garbled.") { dismiss() }

                SettingsGroup {
                    ChoiceRow(label: "Automatic", detail: "Follows your iPhone's languages", selected: config.transcriptionLocale.isEmpty) {
                        pick("")
                    }
                    ForEach(locales, id: \.identifier) { locale in
                        ChoiceRow(
                            label: Self.name(locale.identifier),
                            detail: detail(locale),
                            selected: config.transcriptionLocale == locale.identifier
                        ) { pick(locale.identifier) }
                    }
                }
                .padding(.top, 24)

                if loaded && locales.isEmpty {
                    Text("On-device transcription isn't available on this iPhone.")
                        .font(.summary)
                        .foregroundStyle(Color.jText3)
                        .padding(.top, 16)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 48)
        }
        .statusBarCover()
        .background(Color.jBg)
        .toolbar(.hidden, for: .navigationBar)
        .sensoryFeedback(.selection, trigger: config.transcriptionLocale)
        .task {
            let all = await SpeechTranscriber.supportedLocales
            installed = Set(await SpeechTranscriber.installedLocales.map(\.identifier))
            locales = all.sorted { Self.name($0.identifier).localizedStandardCompare(Self.name($1.identifier)) == .orderedAscending }
            loaded = true
        }
    }

    private func pick(_ id: String) {
        guard config.transcriptionLocale != id else { return }
        config.transcriptionLocale = id
        Pipeline.shared.languageChanged()
    }

    private func detail(_ locale: Locale) -> String? {
        let here = Locale.current.localizedString(forIdentifier: locale.identifier)
        let parts = [here == Self.name(locale.identifier) ? nil : here, installed.contains(locale.identifier) ? "Downloaded" : nil]
        let text = parts.compactMap { $0 }.joined(separator: " · ")
        return text.isEmpty ? nil : text
    }

    /// The language in its own words: "中文（中国大陆）", "English (US)".
    static func name(_ id: String) -> String {
        guard !id.isEmpty else { return "Automatic" }
        return Locale(identifier: id).localizedString(forIdentifier: id) ?? id
    }
}
