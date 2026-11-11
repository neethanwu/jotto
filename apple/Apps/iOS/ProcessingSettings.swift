import Speech
import SwiftUI

/// Where recordings turn into text. On this iPhone, for now; "Your own
/// API key" arrives in step 3 (docs/06) as the other choice.
struct ProcessingView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(title: "Processing", detail: "How your recordings turn into text.") { dismiss() }

                VStack(spacing: 10) {
                    ChoiceCard(
                        title: "On this iPhone",
                        detail: "Free, and nothing leaves your phone. Best in one language. Doesn't tell speakers apart.",
                        selected: true
                    ) {}
                    comingSoon
                }
                .padding(.top, 24)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 48)
        }
        .statusBarCover()
        .background(Color.jBg)
        .toolbar(.hidden, for: .navigationBar)
    }

    /// The other choice, shown so people know it is coming.
    private var comingSoon: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle().strokeBorder(Color.jText5, lineWidth: 1.5)
                .frame(width: 22, height: 22)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Your own API key").font(.rowTitle).foregroundStyle(Color.jText3)
                    Spacer(minLength: 8)
                    Text("Coming soon")
                        .font(.scaled(12, .semibold, relativeTo: .caption1))
                        .foregroundStyle(Color.jText2)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(Color.jFill, in: Capsule())
                }
                Text("Send the audio to a transcription service you pay for. Tells speakers apart and handles mixed languages.")
                    .font(.scaled(14, .regular, relativeTo: .subheadline))
                    .foregroundStyle(Color.jText3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.jHairline, lineWidth: 1))
        .accessibilityElement(children: .combine)
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

/// The language on-device transcription listens for. Automatic listens to
/// the start of each recording and picks from the iPhone's languages and
/// keyboards. "Downloaded" marks models already on the phone; others
/// download when picked.
struct LanguageView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var config: AppConfig = .shared
    @State private var locales: [Locale] = []
    @State private var installed: Set<String> = []
    @State private var loaded = false
    /// The languages Automatic chooses between on this iPhone.
    @State private var automatic: String?

    private var automaticDetail: String {
        guard let automatic else { return "Hears which of your iPhone's languages each recording is in" }
        return "Hears which one each recording is in: \(automatic)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(title: "Language", detail: "The language people mostly speak in your recordings. A recording in mixed languages comes out in the main one.") { dismiss() }

                SettingsGroup {
                    ChoiceRow(label: "Automatic", detail: automaticDetail, selected: config.transcriptionLocale.isEmpty) {
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

                Text("Downloaded languages are already on your iPhone. Others download when you pick them, with Jotto open.")
                    .font(.metaSmall)
                    .foregroundStyle(Color.jText3)
                    .padding(.top, 12)

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
        .onChange(of: Pipeline.shared.waiting) {
            Task { installed = Set(await SpeechTranscriber.installedLocales.map(\.identifier)) }
        }
        .task {
            let all = await SpeechTranscriber.supportedLocales
            installed = Set(await SpeechTranscriber.installedLocales.map(\.identifier))
            automatic = await OnDeviceTranscriber.candidates().map { Self.name($0.identifier) }.joined(separator: ", ")
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
        let state: String? = installed.contains(locale.identifier) ? "Downloaded"
            : config.transcriptionLocale == locale.identifier ? (Pipeline.shared.waiting == nil ? "Downloads when needed" : "Downloading") : nil
        let parts = [here == Self.name(locale.identifier) ? nil : here, state]
        let text = parts.compactMap { $0 }.joined(separator: " · ")
        return text.isEmpty ? nil : text
    }

    /// The language in its own words: "中文（中国大陆）", "English (US)".
    static func name(_ id: String) -> String {
        guard !id.isEmpty else { return "Automatic" }
        return Locale(identifier: id).localizedString(forIdentifier: id) ?? id
    }
}
