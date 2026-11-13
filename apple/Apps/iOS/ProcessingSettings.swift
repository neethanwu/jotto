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
    @FocusState private var modelFocused: Bool
    @State private var editingKey = false
    @State private var check: KeyCheck = .unknown
    @State private var confirmingRemove = false
    /// The model row open in place, showing its choices.
    @State private var openSlot: Cloud.ModelSlot?
    /// Another model, typed into the open row's last line.
    @State private var typedModel = ""

    enum KeyCheck { case unknown, checking, works, fails, unanswered }

    /// Nothing to send recordings with: no key, or one the service
    /// turned down. Until there is, they stay on this iPhone.
    private var keyMissing: Bool {
        draftKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || check == .fails
    }

    var body: some View {
        ScrollViewReader { proxy in
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
            .keyboardFriendly()
        }
        // A row opened low on the page: its choices come up into view,
        // no further than needed.
        .onChange(of: openSlot) { _, slot in
            guard slot != nil else { return }
            Task {
                try? await Task.sleep(for: .milliseconds(60))
                withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo(Self.modelsEnd) }
            }
        }
        }
        .scrollDismissesKeyboard(.immediately)
        .statusBarCover()
        .background(Color.jBg)
        .toolbar(.hidden, for: .navigationBar)
        .sensoryFeedback(.selection, trigger: config.transcribeModel)
        .sensoryFeedback(.selection, trigger: config.writeModel)
        .onAppear { loadKey() }
        .onDisappear(perform: leave)
        .onChange(of: config.usesOwnKey) { saveKey() }
        .onChange(of: config.cloudService) {
            loadKey()
            openSlot = nil
        }
    }

    /// Typed, then left without pressing return: keep it all the same.
    /// Your own key picked but nothing that works to use it with: back
    /// to this iPhone, which always does, rather than recordings waiting.
    private func leave() {
        saveKey()
        useTypedModel()
        if config.usesOwnKey, keyMissing {
            config.usesOwnKey = false
            Pipeline.shared.languageChanged()
        }
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
                .fieldBackground()
                .animation(.easeOut(duration: 0.15), value: config.cloudBaseURL.isEmpty)
            }

            label("API key").padding(.top, 24)
            HStack(spacing: 10) {
                if editingKey || draftKey.isEmpty {
                    SecureField("Paste your key", text: $draftKey)
                        .font(.system(size: 15, design: .monospaced))
                        // A key, not a password: no offer to save it as one.
                        .textContentType(.oneTimeCode)
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
            .fieldBackground()
            .contentShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .onTapGesture {
                editingKey = true
                keyFocused = true
            }
            .onChange(of: keyFocused) { _, focused in
                if focused { editingKey = true } else { editingKey = false; saveKey() }
            }
            if keyMissing {
                Text("Until there's a key that works, recordings stay on this iPhone.")
                    .font(.scaled(13, .regular, relativeTo: .footnote))
                    .foregroundStyle(Color.jText3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                    .transition(.opacity)
            }

            label("Models").padding(.top, 24).padding(.horizontal, 4)
            VStack(spacing: 0) {
                modelRow(.transcribe)
                Rectangle().fill(Color.jHairline).frame(height: 1).padding(.horizontal, 16)
                modelRow(.write)
            }
            .card()
            if openSlot != nil {
                Text(config.cloudService == .openRouter
                     ? "Any other model goes in as OpenRouter names it, like provider/model. Return to use it."
                     : "Any other model goes in as your service names it. Return to use it.")
                    .font(.scaled(13, .regular, relativeTo: .footnote))
                    .foregroundStyle(Color.jText3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                    .padding(.horizontal, 4)
                    .transition(.opacity)
            }
            Color.clear.frame(height: 8).id(Self.modelsEnd)

            if config.cloudService == .openRouter {
                Link(destination: URL(string: "https://openrouter.ai/keys")!) {
                    HStack(spacing: 6) {
                        Text("How to get a key, and what it costs")
                        Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .semibold))
                    }
                    .font(.scaled(15, .medium, relativeTo: .subheadline))
                    .foregroundStyle(Color.jText)
                }
                .padding(.top, 16)
            }
        }
        .animation(.easeOut(duration: 0.2), value: keyMissing)
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
        case .unanswered:
            Text("Couldn't check")
                .font(.scaled(13, .medium, relativeTo: .footnote))
                .foregroundStyle(Color.jText3)
        }
    }

    /// A model, picked in place (design 13f): tap the row and its
    /// choices open under it, with a last line to type any other. The
    /// pick stays in the row while you choose.
    private func modelRow(_ slot: Cloud.ModelSlot) -> some View {
        let open = openSlot == slot
        return VStack(spacing: 0) {
            Button { toggle(slot) } label: {
                HStack(spacing: 6) {
                    Text(ModelPick.title(slot))
                        .font(.reading)
                        .foregroundStyle(Color.jText)
                        .lineLimit(1)
                        .layoutPriority(1)
                    Spacer(minLength: 6)
                    Text(Cloud.displayName(ModelPick.value(slot), in: ModelPick.choices(slot)))
                        .font(.scaled(15, .medium, relativeTo: .subheadline))
                        .foregroundStyle(Color.jText2)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.jText4)
                        .rotationEffect(.degrees(open ? 180 : 0))
                }
                .padding(.horizontal, 16)
                .frame(height: 52)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(open ? "Hides the models" : "Shows the models to choose from")

            if open {
                ModelChoices(slot: slot, typed: $typedModel, focused: $modelFocused) { id in
                    ModelPick.set(id, for: slot)
                    typedModel = ""
                    modelFocused = false
                    // A beat to see the check move, then fold away.
                    Task {
                        try? await Task.sleep(for: .milliseconds(250))
                        if openSlot == slot { withAnimation(Self.fold) { openSlot = nil } }
                    }
                } submit: {
                    useTypedModel()
                    withAnimation(Self.fold) { openSlot = nil }
                }
                .transition(.opacity)
            }
        }
    }

    private static let fold = Animation.easeOut(duration: 0.24)
    private static let modelsEnd = "models-end"

    private func toggle(_ slot: Cloud.ModelSlot) {
        useTypedModel()
        modelFocused = false
        let opening = openSlot != slot
        typedModel = opening && !ModelPick.isListed(ModelPick.value(slot), for: slot) ? ModelPick.value(slot) : ""
        withAnimation(Self.fold) { openSlot = opening ? slot : nil }
    }

    /// The typed model, if there is one and it isn't already in use.
    private func useTypedModel() {
        guard let slot = openSlot else { return }
        let model = typedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, model != ModelPick.value(slot) else { return }
        ModelPick.set(model, for: slot)
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
        switch await Cloud.check(key: draftKey, service: config.cloudService, base: config.cloudBaseURL) {
        case .works: check = .works
        case .turnedDown: check = .fails
        case .unanswered: check = .unanswered
        }
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
                    Text("\(Int(fraction * 950)) of \(SpeechPack.sizeLabel). Apple's model carries on until this is done, then it takes over. Fine to leave this page.")
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

/// The models you can pick for transcription and for writing (titles,
/// summaries, formatting), and how to set them.
@MainActor
enum ModelPick {
    static func title(_ slot: Cloud.ModelSlot) -> String {
        slot == .transcribe ? "Transcription" : "Titles and formatting"
    }

    static func choices(_ slot: Cloud.ModelSlot) -> [(id: String, name: String)] {
        slot == .transcribe ? Cloud.transcribeModels : Cloud.writeModels
    }

    static func value(_ slot: Cloud.ModelSlot) -> String {
        slot == .transcribe ? AppConfig.shared.transcribeModel : AppConfig.shared.writeModel
    }

    static func set(_ model: String, for slot: Cloud.ModelSlot) {
        if slot == .transcribe { AppConfig.shared.transcribeModel = model } else { AppConfig.shared.writeModel = model }
    }

    static func isListed(_ model: String, for slot: Cloud.ModelSlot) -> Bool {
        choices(slot).contains { $0.id == model }
    }
}

/// Under an open model row: the suggested models, each with its full
/// name, a check on the one in use, then a line to type any other.
private struct ModelChoices: View {
    let slot: Cloud.ModelSlot
    @Binding var typed: String
    var focused: FocusState<Bool>.Binding
    let pick: (String) -> Void
    let submit: () -> Void
    @Bindable private var config: AppConfig = .shared

    private var value: String { ModelPick.value(slot) }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(ModelPick.choices(slot).enumerated()), id: \.element.id) { i, choice in
                if i > 0 { line }
                Button { pick(choice.id) } label: {
                    HStack(spacing: 12) {
                        check(choice.id == value)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(choice.name)
                                .font(.scaled(16, .regular, relativeTo: .body))
                                .foregroundStyle(Color.jText)
                            Text(choice.id)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Color.jText3)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .frame(minHeight: 54)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(choice.id == value ? .isSelected : [])
            }
            line
            HStack(spacing: 12) {
                check(!typed.isEmpty && typed == value && !ModelPick.isListed(value, for: slot))
                TextField(config.cloudService == .openRouter ? "Another, like provider/model" : "Another model",
                          text: $typed)
                    .font(.system(size: 15, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .focused(focused)
                    .onSubmit(submit)
                ClearButton(text: $typed, label: "Clear model") { focused.wrappedValue = true }
            }
            .padding(.leading, 16)
            .padding(.trailing, 10)
            .frame(height: 54)
            .animation(.easeOut(duration: 0.15), value: typed.isEmpty)
        }
        .padding(.bottom, 2)
    }

    /// Hairlines start where the names do.
    private var line: some View {
        Rectangle().fill(Color.jHairline).frame(height: 1).padding(.leading, 48).padding(.trailing, 16)
    }

    private func check(_ on: Bool) -> some View {
        Image(systemName: "checkmark")
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(Color.jText)
            .opacity(on ? 1 : 0)
            .frame(width: 20)
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
