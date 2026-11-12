import Speech
import SwiftUI

/// Where recordings turn into text: on this iPhone, or a service paid for
/// with your own API key (design 13). The key stays in the Keychain.
struct ProcessingView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable private var config: AppConfig = .shared
    @State private var draftKey = ""
    @FocusState private var keyFocused: Bool
    @State private var editingKey = false
    @State private var check: KeyCheck = .unknown
    @State private var typingModel: ModelSlot?

    enum KeyCheck { case unknown, checking, works, fails }
    enum ModelSlot: Identifiable { case transcribe, write; var id: Self { self } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(title: "Processing", detail: "How your recordings turn into text.") { dismiss() }

                VStack(spacing: 10) {
                    ChoiceCard(
                        title: "On this iPhone",
                        detail: "Free, and nothing leaves your phone. Best in one language. Doesn't tell speakers apart.",
                        selected: !config.usesOwnKey
                    ) { choose(ownKey: false) }
                    ChoiceCard(
                        title: "Your own API key",
                        detail: "Handles mixed Chinese and English, and tells speakers apart. You pay the provider directly.",
                        selected: config.usesOwnKey
                    ) { choose(ownKey: true) }
                }
                .padding(.top, 24)

                if config.usesOwnKey {
                    keySettings
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 48)
            .animation(.easeOut(duration: 0.2), value: config.usesOwnKey)
        }
        .scrollDismissesKeyboard(.interactively)
        .statusBarCover()
        .background(Color.jBg)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { loadKey() }
        // Typed, then left without pressing return: keep it all the same.
        .onDisappear { saveKey() }
        .onChange(of: config.usesOwnKey) { saveKey() }
        .onChange(of: config.cloudService) { loadKey() }
        .alert(typingModel == .transcribe ? "Transcription model" : "Model for titles and formatting",
               isPresented: Binding(get: { typingModel != nil }, set: { if !$0 { typingModel = nil } })) {
            ModelField(slot: typingModel ?? .transcribe)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(config.cloudService == .openRouter ? "As OpenRouter names it, like provider/model." : "As your service names it.")
        }
    }

    private func choose(ownKey: Bool) {
        config.usesOwnKey = ownKey
        // Parts waiting for a model can go now, the other way.
        Pipeline.shared.languageChanged()
    }

    // MARK: Your own key

    private var keySettings: some View {
        VStack(alignment: .leading, spacing: 0) {
            label("Provider").padding(.top, 28)
            ServicePicker(selection: $config.cloudService)
            Text(config.cloudService == .openRouter
                 ? "One key for transcription and polish. Recommended."
                 : "Any service with the OpenAI API: OpenAI, Groq, and others.")
                .font(.scaled(13, .regular, relativeTo: .footnote))
                .foregroundStyle(Color.jText3)
                .padding(.top, 8)

            if config.cloudService == .compatible {
                label("Address").padding(.top, 24)
                TextField("https://api.openai.com/v1", text: $config.cloudBaseURL)
                    .font(.system(size: 15, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .onSubmit { Task { await runCheck() } }
                    .padding(.horizontal, 16)
                    .frame(height: 52)
                    .background(Color.jFill, in: Capsule())
            }

            label("API key").padding(.top, 24)
            HStack(spacing: 10) {
                if editingKey || draftKey.isEmpty {
                    SecureField("Paste your key", text: $draftKey)
                        .font(.system(size: 15, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($keyFocused)
                        .onSubmit { keyFocused = false }
                } else {
                    // Saved: just enough of it to recognise. Tap to change it.
                    Text(Self.masked(draftKey))
                        .font(.system(size: 15, design: .monospaced))
                        .foregroundStyle(Color.jText)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                checkMark
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            .background(Color.jFill, in: Capsule())
            .contentShape(Capsule())
            .onTapGesture {
                editingKey = true
                keyFocused = true
            }
            .onChange(of: keyFocused) { _, focused in
                if focused { editingKey = true } else { editingKey = false; saveKey() }
            }

            label("Models").padding(.top, 24).padding(.horizontal, 4)
            VStack(spacing: 0) {
                modelRow("Transcription", slot: .transcribe, value: config.transcribeModel, choices: Cloud.transcribeModels)
                Rectangle().fill(Color.jHairline).frame(height: 1).padding(.horizontal, 16)
                modelRow("Titles and formatting", slot: .write, value: config.writeModel, choices: Cloud.writeModels)
            }
            .card(radius: 20)

            if config.cloudService == .openRouter {
                Link(destination: URL(string: "https://openrouter.ai/keys")!) {
                    HStack(spacing: 6) {
                        Text("How to get a key, and what it costs")
                        Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .semibold))
                    }
                    .font(.scaled(15, .medium, relativeTo: .subheadline))
                    .foregroundStyle(Color.jText)
                }
                .padding(.top, 24)
            }
        }
    }

    @ViewBuilder
    private var checkMark: some View {
        switch check {
        case .unknown: EmptyView()
        case .checking: ProgressView().controlSize(.small)
        case .works:
            HStack(spacing: 5) {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .heavy))
                Text("Works")
            }
            .font(.scaled(13, .medium, relativeTo: .footnote))
            .foregroundStyle(Color.jText)
        case .fails:
            Text("Didn't work")
                .font(.scaled(13, .medium, relativeTo: .footnote))
                .foregroundStyle(Color.jLive)
        }
    }

    private func modelRow(_ title: String, slot: ModelSlot, value: String, choices: [(id: String, name: String)]) -> some View {
        Menu {
            ForEach(choices, id: \.id) { choice in
                Button {
                    if slot == .transcribe { config.transcribeModel = choice.id } else { config.writeModel = choice.id }
                } label: {
                    if choice.id == value { Label(choice.name, systemImage: "checkmark") } else { Text(choice.name) }
                }
            }
            Divider()
            Button("Another model…") { typingModel = slot }
        } label: {
            HStack(spacing: 12) {
                Text(title).font(.reading).foregroundStyle(Color.jText)
                Spacer(minLength: 8)
                Text(Cloud.displayName(value, in: choices))
                    .font(.scaled(15, .medium, relativeTo: .subheadline))
                    .foregroundStyle(Color.jText2)
                    .lineLimit(1)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.jText4)
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            .contentShape(Rectangle())
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.scaled(11, .medium, relativeTo: .caption2))
            .foregroundStyle(Color.jText3)
            .padding(.bottom, 8)
    }

    static func masked(_ key: String) -> String {
        guard key.count > 12 else { return String(repeating: "•", count: key.count) }
        let head = key.prefix(key.hasPrefix("sk-or-v1-") ? 9 : 3)
        return head + "••••••••" + key.suffix(4)
    }

    private func loadKey() {
        draftKey = Keychain.read(account: config.cloudService.rawValue) ?? ""
        check = .unknown
        if !draftKey.isEmpty { Task { await runCheck() } }
    }

    private func saveKey() {
        let key = draftKey.trimmingCharacters(in: .whitespacesAndNewlines)
        draftKey = key
        guard key != (Keychain.read(account: config.cloudService.rawValue) ?? "") else { return }
        Keychain.save(key, account: config.cloudService.rawValue)
        Task { await runCheck() }
        Pipeline.shared.languageChanged()
    }

    private func runCheck() async {
        guard !draftKey.isEmpty else { check = .unknown; return }
        check = .checking
        let ok = await Cloud.check(key: draftKey, service: config.cloudService, base: config.cloudBaseURL)
        check = ok ? .works : .fails
    }
}

/// OpenRouter or any OpenAI-shaped service: a two-way switch.
private struct ServicePicker: View {
    @Binding var selection: Cloud.Service
    @Namespace private var knob

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Cloud.Service.allCases) { service in
                let on = service == selection
                Button {
                    withAnimation(.spring(duration: 0.3, bounce: 0.1)) { selection = service }
                } label: {
                    Text(service.name)
                        .font(.scaled(15, on ? .semibold : .medium, relativeTo: .subheadline))
                        .foregroundStyle(on ? Color.jText : Color.jText2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background {
                            if on {
                                RoundedRectangle(cornerRadius: 11)
                                    .fill(Color.jSurface)
                                    .shadow(color: .black.opacity(0.08), radius: 1.5, y: 1)
                                    .matchedGeometryEffect(id: "knob", in: knob)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .frame(height: 40)
        .background(Color.jFill, in: RoundedRectangle(cornerRadius: 14))
        .sensoryFeedback(.selection, trigger: selection)
    }
}

/// The text field in "Another model…".
private struct ModelField: View {
    let slot: ProcessingView.ModelSlot
    @Bindable private var config: AppConfig = .shared
    @State private var text = ""

    var body: some View {
        TextField("provider/model", text: $text)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .onAppear { text = slot == .transcribe ? config.transcribeModel : config.writeModel }
            .onSubmit(save)
        Button("Use", action: save)
    }

    private func save() {
        let model = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return }
        if slot == .transcribe { config.transcribeModel = model } else { config.writeModel = model }
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

/// The languages people speak in the recordings, one to three. Picked
/// ones sit on top; picking one starts its download right away, with
/// progress. With more than one, each recording is matched to one.
struct LanguageView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var config: AppConfig = .shared
    @State private var all: [Locale] = []
    @State private var loaded = false
    @State private var limitNote = false
    private var models: SpeechModels { .shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(title: "Languages", detail: "The languages people speak in your recordings. With more than one, Jotto listens to the start of each recording and picks.") { dismiss() }

                label("Listening for · \(config.languages.count) of \(AppConfig.maxLanguages)")
                    .padding(.top, 28)
                SettingsGroup {
                    ForEach(config.languages, id: \.self) { id in
                        row(id, picked: true)
                    }
                }
                if config.languages.count > 1 {
                    VStack(alignment: .leading, spacing: 6) {
                        SettingsToggle("Mixed in one recording", isOn: $config.mixesLanguages)
                        Text("Experiment. Transcribes each recording in every language above and keeps whichever is surer, a sentence or two at a time. Takes a little longer.")
                            .font(.metaSmall)
                            .foregroundStyle(Color.jText3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 12)
                }
                if limitNote {
                    Text("Up to three. Remove one first.")
                        .font(.metaSmall)
                        .foregroundStyle(Color.jText3)
                        .padding(.top, 8)
                        .transition(.opacity)
                }

                label("All languages").padding(.top, 28)
                SettingsGroup {
                    ForEach(all.filter { !config.languages.contains($0.identifier) }, id: \.identifier) { locale in
                        row(locale.identifier, picked: false)
                    }
                }

                if loaded && all.isEmpty {
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
        .sensoryFeedback(.selection, trigger: config.languages)
        .animation(.easeOut(duration: 0.2), value: config.languages)
        .animation(.easeOut(duration: 0.2), value: limitNote)
        .task {
            await config.fillLanguagesIfNeeded()
            await models.refresh()
            let supported = await SpeechTranscriber.supportedLocales
            all = supported.sorted { Self.name($0.identifier).localizedStandardCompare(Self.name($1.identifier)) == .orderedAscending }
            loaded = true
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.scaled(13, .semibold, relativeTo: .footnote))
            .foregroundStyle(Color.jText2)
            .padding(.bottom, 2)
    }

    private func row(_ id: String, picked: Bool) -> some View {
        Button { toggle(id) } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Self.name(id)).font(.reading).foregroundStyle(Color.jText)
                    status(id, picked: picked)
                }
                Spacer()
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.jText)
                    .opacity(picked ? 1 : 0)
            }
            .padding(.vertical, 12)
            .frame(minHeight: 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }

    @ViewBuilder
    private func status(_ id: String, picked: Bool) -> some View {
        let here = Locale.current.localizedString(forIdentifier: id)
        let other = here == Self.name(id) ? nil : here
        if let progress = models.progress[id] {
            HStack(spacing: 8) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(Color.jText)
                    .frame(width: 72)
                Text("Downloading · \(Int(progress * 100))%")
                    .monospacedDigit()
            }
            .font(.metaSmall)
            .foregroundStyle(Color.jText3)
        } else {
            let state: String? = models.isInstalled(id) ? "Downloaded"
                : models.failed.contains(id) ? "Couldn't download. Tap to try again"
                : picked ? "Downloads with Jotto open" : nil
            let text = [other, state].compactMap { $0 }.joined(separator: " · ")
            if !text.isEmpty {
                Text(text).font(.metaSmall).foregroundStyle(Color.jText3)
            }
        }
    }

    private func toggle(_ id: String) {
        if config.languages.contains(id), models.failed.contains(id) {
            Task { await models.ensure([id]) }
            return
        }
        if let i = config.languages.firstIndex(of: id) {
            // At least one stays.
            guard config.languages.count > 1 else { return }
            config.languages.remove(at: i)
        } else {
            guard config.languages.count < AppConfig.maxLanguages else {
                limitNote = true
                return
            }
            limitNote = false
            config.languages.append(id)
            Task { await models.ensure([id]) }
        }
        Pipeline.shared.languageChanged()
    }

    /// The language in its own words: "中文（中国大陆）", "English (US)".
    static func name(_ id: String) -> String {
        Locale(identifier: id).localizedString(forIdentifier: id) ?? id
    }

    /// Just the language, in its own words: "中文", "English".
    static func shortName(_ id: String) -> String {
        if id == LocalRecording.mixed { return "Mixed languages" }
        let locale = Locale(identifier: id)
        return locale.language.languageCode.flatMap { locale.localizedString(forLanguageCode: $0.identifier) } ?? name(id)
    }
}
