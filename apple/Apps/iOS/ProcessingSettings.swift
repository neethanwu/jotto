import Speech
import SwiftUI

/// Where recordings turn into text: on this iPhone, or a service paid for
/// with your own API key (design 13). The key stays in the Keychain.
struct ProcessingView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable private var config: AppConfig = .shared
    @State private var draftKey = ""
    @FocusState private var keyFocused: Bool
    @FocusState private var addressFocused: Bool
    @State private var editingKey = false
    @State private var check: KeyCheck = .unknown
    @State private var confirmingRemove = false

    enum KeyCheck { case unknown, checking, works, fails }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(title: "Processing", detail: "How your recordings turn into text.") { dismiss() }

                VStack(spacing: 10) {
                    ChoiceCard(
                        title: "On this iPhone",
                        detail: "Free, and nothing leaves your phone. Doesn't tell speakers apart.",
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
                } else {
                    phoneSettings
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
    }

    private func choose(ownKey: Bool) {
        config.usesOwnKey = ownKey
        // Parts waiting for a model can go now, the other way.
        Pipeline.shared.languageChanged()
    }

    // MARK: On this iPhone (designs 13c–13e)

    private var phoneSettings: some View {
        VStack(alignment: .leading, spacing: 0) {
            label("Speech model").padding(.top, 28).padding(.horizontal, 4)
            VStack(spacing: 0) {
                SpeechModelRow(
                    title: "Apple",
                    detail: "Built in. Best when a recording stays in one language.",
                    selected: !config.usesQwen
                ) { pick(.apple) }
                Rectangle().fill(Color.jHairline).frame(height: 1).padding(.leading, 48).padding(.trailing, 16)
                QwenRow(selected: config.usesQwen) { pick(.qwen) }
            }
            .card()

            if config.usesQwen {
                HStack(spacing: 6) {
                    Text("\(SpeechPack.name) takes \(SpeechPack.sizeLabel) on this phone.")
                        .foregroundStyle(Color.jText3)
                    Button("Remove") { confirmingRemove = true }
                        .font(.scaled(13, .medium, relativeTo: .footnote))
                        .foregroundStyle(Color.jText)
                }
                .font(.scaled(13, .regular, relativeTo: .footnote))
                .padding(.top, 8)
                .padding(.horizontal, 4)
            } else {
                NavigationLink(value: Route.language) {
                    HStack(spacing: 12) {
                        Text("Languages").font(.reading).foregroundStyle(Color.jText)
                        Spacer(minLength: 8)
                        Text(config.languages.count == 1
                             ? LanguageView.name(config.languages[0])
                             : config.languages.map(LanguageView.shortName).joined(separator: ", "))
                            .font(.scaled(15, .medium, relativeTo: .subheadline))
                            .foregroundStyle(Color.jText2)
                            .lineLimit(1)
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.jText4)
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 52)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .card()
                .padding(.top, 12)
                Text("What people speak in your recordings. Only Apple's model needs this; \(SpeechPack.name) tells by itself.")
                    .font(.scaled(13, .regular, relativeTo: .footnote))
                    .foregroundStyle(Color.jText3)
                    .padding(.top, 8)
                    .padding(.horizontal, 4)
            }
        }
        .confirmationDialog("Remove \(SpeechPack.name)?", isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { SpeechPack.shared.remove() }
        } message: {
            Text("Frees \(SpeechPack.sizeLabel). New recordings go back to Apple's model. You can download it again any time.")
        }
    }

    private func pick(_ model: AppConfig.SpeechModel) {
        if model == .qwen, !SpeechPack.shared.isReady {
            SpeechPack.shared.download()
            return
        }
        guard config.speechModel != model else { return }
        config.speechModel = model
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
                HStack(spacing: 4) {
                    TextField("https://api.openai.com/v1", text: $config.cloudBaseURL)
                        .font(.system(size: 15, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .focused($addressFocused)
                        .onSubmit { Task { await runCheck() } }
                    ClearButton(text: $config.cloudBaseURL, label: "Clear address") { addressFocused = true }
                }
                .padding(.leading, 16)
                .padding(.trailing, 10)
                .frame(height: 52)
                .background(Color.jFill, in: Capsule())
                .animation(.easeOut(duration: 0.15), value: config.cloudBaseURL.isEmpty)
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
                    ClearButton(text: $draftKey, visible: keyFocused, label: "Clear key") { keyFocused = true }
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
            .padding(.leading, 16)
            .padding(.trailing, editingKey && !draftKey.isEmpty ? 10 : 16)
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
                modelRow(.transcribe)
                Rectangle().fill(Color.jHairline).frame(height: 1).padding(.horizontal, 16)
                modelRow(.write)
            }
            .card()

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

    /// A row that opens the model's own page: the pick stays in view
    /// while you choose, and another model can be typed in there.
    private func modelRow(_ slot: Cloud.ModelSlot) -> some View {
        NavigationLink(value: Route.model(slot)) {
            HStack(spacing: 12) {
                Text(ModelView.title(slot)).font(.reading).foregroundStyle(Color.jText)
                Spacer(minLength: 8)
                Text(Cloud.displayName(ModelView.value(slot), in: ModelView.choices(slot)))
                    .font(.scaled(15, .medium, relativeTo: .subheadline))
                    .foregroundStyle(Color.jText2)
                    .lineLimit(1)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.jText4)
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

/// One of the speech models, as a row: radio, name, a line about it.
private struct SpeechModelRow<Detail: View, Trailing: View>: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @ViewBuilder let detail: Detail
    @ViewBuilder let trailing: Trailing

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle().strokeBorder(Color.jText5, lineWidth: 1.5).opacity(selected ? 0 : 1)
                    Circle().fill(Color.jText).opacity(selected ? 1 : 0)
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(Color.jBg)
                        .opacity(selected ? 1 : 0)
                }
                .frame(width: 20, height: 20)
                .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.reading).foregroundStyle(Color.jText)
                    detail
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                trailing
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .animation(.easeOut(duration: 0.2), value: selected)
    }
}

extension SpeechModelRow where Detail == Text, Trailing == EmptyView {
    init(title: String, detail: String, selected: Bool, action: @escaping () -> Void) {
        self.init(title: title, selected: selected, action: action) {
            Text(detail)
                .font(.scaled(14, .regular, relativeTo: .subheadline))
                .foregroundStyle(Color.jText2)
        } trailing: {
            EmptyView()
        }
    }
}

/// Qwen3-ASR: download it (size on the button), watch it come, then pick it.
private struct QwenRow: View {
    let selected: Bool
    let action: () -> Void
    private var pack: SpeechPack { .shared }

    var body: some View {
        SpeechModelRow(title: SpeechPack.name, selected: selected, action: action) {
            switch pack.state {
            case let .downloading(fraction):
                VStack(alignment: .leading, spacing: 7) {
                    ProgressBar(fraction: fraction)
                    Text("\(Int(fraction * 950)) of \(SpeechPack.sizeLabel). Fine to leave this page.")
                        .monospacedDigit()
                }
                .padding(.top, 6)
            case .preparing:
                Text("Getting it ready…")
            case let .failed(why):
                Text(why).foregroundStyle(Color.jLive)
            case .absent, .ready:
                Text("Hears Chinese and English mixed together.")
            }
        } trailing: {
            switch pack.state {
            case .absent:
                pill { Label(SpeechPack.sizeLabel, systemImage: "arrow.down.to.line") }
                    .accessibilityLabel("Download \(SpeechPack.sizeLabel)")
            case .failed:
                pill { Text("Try again") }
            case .downloading:
                Button { pack.cancel() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.jText2)
                        .frame(width: 30, height: 30)
                        .background(Color.jFill, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop downloading")
                .padding(.top, 2)
            case .preparing:
                ProgressView().controlSize(.small).frame(width: 30, height: 30)
            case .ready:
                EmptyView()
            }
        }
        .font(.scaled(14, .regular, relativeTo: .subheadline))
        .foregroundStyle(Color.jText2)
        .animation(.easeOut(duration: 0.2), value: pack.state)
    }

    private func pill(@ViewBuilder _ content: () -> some View) -> some View {
        Button { pack.download() } label: {
            content()
                .font(.scaled(14, .semibold, relativeTo: .subheadline))
                .foregroundStyle(Color.jText)
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Color.jFill, in: Capsule())
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
    }
}

private struct ProgressBar: View {
    let fraction: Double
    var body: some View {
        GeometryReader { geo in
            Capsule().fill(Color.jHairline)
                .overlay(alignment: .leading) {
                    Capsule().fill(Color.jText).frame(width: max(4, geo.size.width * fraction))
                }
        }
        .frame(height: 4)
        .animation(.linear(duration: 0.2), value: fraction)
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
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
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
        .background(Color.jFill, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .sensoryFeedback(.selection, trigger: selection)
    }
}

/// One model to pick (design 13f): the suggested ones, then a field for
/// any other the service has. Picking one saves it; a typed one is
/// saved on return or on the way back.
struct ModelView: View {
    let slot: Cloud.ModelSlot
    @Environment(\.dismiss) private var dismiss
    @Bindable private var config: AppConfig = .shared
    @State private var typed = ""
    @FocusState private var typing: Bool

    static func title(_ slot: Cloud.ModelSlot) -> String {
        slot == .transcribe ? "Transcription" : "Titles and formatting"
    }

    static func choices(_ slot: Cloud.ModelSlot) -> [(id: String, name: String)] {
        slot == .transcribe ? Cloud.transcribeModels : Cloud.writeModels
    }

    @MainActor static func value(_ slot: Cloud.ModelSlot) -> String {
        slot == .transcribe ? AppConfig.shared.transcribeModel : AppConfig.shared.writeModel
    }

    private var value: String {
        get { Self.value(slot) }
        nonmutating set {
            if slot == .transcribe { config.transcribeModel = newValue } else { config.writeModel = newValue }
        }
    }

    private var isOther: Bool { !Self.choices(slot).contains { $0.id == value } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(
                    title: Self.title(slot),
                    detail: slot == .transcribe
                        ? "The model that hears your recordings."
                        : "The model that names recordings and tidies the text."
                ) { dismiss() }

                SettingsGroup {
                    ForEach(Self.choices(slot), id: \.id) { choice in
                        ChoiceRow(label: choice.name, detail: choice.id, selected: choice.id == value) {
                            value = choice.id
                            typed = ""
                            typing = false
                        }
                    }
                }
                .padding(.top, 24)

                Text("Another model")
                    .font(.scaled(11, .medium, relativeTo: .caption2))
                    .foregroundStyle(Color.jText3)
                    .padding(.top, 28)
                    .padding(.bottom, 8)
                HStack(spacing: 4) {
                    TextField(config.cloudService == .openRouter ? "provider/model" : "model-name", text: $typed)
                        .font(.system(size: 15, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .focused($typing)
                        .onSubmit(useTyped)
                    ClearButton(text: $typed, label: "Clear model") { typing = true }
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color.jText)
                        .opacity(isOther && !typed.isEmpty && typed == value ? 1 : 0)
                        .frame(width: 24)
                }
                .padding(.leading, 16)
                .padding(.trailing, 10)
                .frame(height: 52)
                .background(Color.jFill, in: Capsule())
                .animation(.easeOut(duration: 0.15), value: typed.isEmpty)
                Text(config.cloudService == .openRouter
                     ? "As OpenRouter names it, like provider/model. Return to use it."
                     : "As your service names it. Return to use it.")
                    .font(.scaled(13, .regular, relativeTo: .footnote))
                    .foregroundStyle(Color.jText3)
                    .padding(.top, 8)
                    .padding(.horizontal, 4)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 48)
        }
        .scrollDismissesKeyboard(.interactively)
        .statusBarCover()
        .background(Color.jBg)
        .toolbar(.hidden, for: .navigationBar)
        .sensoryFeedback(.selection, trigger: value)
        .onAppear { if isOther { typed = value } }
        .onDisappear(perform: useTyped)
    }

    private func useTyped() {
        let model = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, model != value else { return }
        value = model
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
            .background(selected ? Color.jSurface : Color.jBg, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(selected ? Color.jText : Color.jHairline, lineWidth: selected ? 1.5 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
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
