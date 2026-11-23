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
    @FocusState private var modelFocus: Cloud.ModelSlot?
    @State private var editingKey = false
    @State private var check: KeyCheck = .unknown
    @State private var confirmingRemove = false
    /// The model row open in place, showing its choices.
    @State private var openSlot: Cloud.ModelSlot?
    /// Speech to text or Service, open in place. One row open at a time,
    /// these or a model's.
    @State private var openPick: Pick?
    enum Pick { case speech, service }
    /// The row that opens once the other one has folded away.
    @State private var nextSlot: Cloud.ModelSlot?
    /// Another model, typed into a row's last line.
    @State private var typed: [Cloud.ModelSlot: String] = [:]
    /// Each row's choices, open, measured.
    @State private var choicesHeight: [Cloud.ModelSlot: CGFloat] = [:]
    /// Room kept at the bottom of the page while one row folds and the
    /// other opens, so a page scrolled to its end isn't pulled down by
    /// the fold and then pushed back up.
    @State private var reserve: CGFloat = 0

    enum KeyCheck { case unknown, checking, works, fails, unanswered }

    /// From the App Store in China mainland, only services that operate there.
    private var region: StoreRegion { .shared }

    /// Nothing to send recordings with: no key, or one the service
    /// turned down. Until there is, they stay on this iPhone.
    private var keyMissing: Bool {
        draftKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || check == .fails || Cloud.addressBlocked
    }

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(title: "Processing", detail: "How your recordings turn into text.") { dismiss() }

                HStack(alignment: .top, spacing: 10) {
                    ChoiceCard(
                        title: "On this iPhone",
                        detail: "Free. Nothing leaves your phone.",
                        icon: "iphone",
                        selected: !config.usesOwnKey
                    ) { choose(ownKey: false) }
                    ChoiceCard(
                        title: "Your own key",
                        // Bailian's speech model gives no times, so no speakers either.
                        detail: region.isChinaMainland ? "Larger models. You pay the service." : "Tells speakers apart. You pay the service.",
                        icon: "key.horizontal",
                        selected: config.usesOwnKey
                    ) { choose(ownKey: true) }
                }
                .fixedSize(horizontal: false, vertical: true)
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
            .padding(.bottom, 48 + reserve)
            .animation(.easeOut(duration: 0.2), value: config.usesOwnKey)
            .keyboardFriendly()
        }
        // A row opened low on the page: its choices come up into view,
        // no further than needed.
        .onChange(of: openSlot) { _, slot in
            // Not when changing from one row to the other: the page holds
            // still for that (see `reserve`).
            guard slot != nil, reserve == 0 else { return }
            Task {
                // Once it has unfolded, so the page doesn't move with it.
                try? await Task.sleep(for: .milliseconds(280))
                withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo(Self.modelsEnd) }
            }
        }
        }
        .scrollDismissesKeyboard(.immediately)
        .statusBarCover()
        .background(Color.jBg)
        .toolbar(.hidden, for: .navigationBar)
        .sensoryFeedback(.selection, trigger: ModelPick.value(.transcribe))
        .sensoryFeedback(.selection, trigger: ModelPick.value(.write))
        .onAppear {
            Cloud.settle()
            loadKey()
        }
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
            CardSectionTitle("On this iPhone").padding(.top, 28)
            VStack(spacing: 0) {
                SpeechMenuRow(open: openBinding(.speech), pick: pick, remove: { confirmingRemove = true })
                if !config.usesQwen {
                    Rectangle().fill(Color.jHairline).frame(height: 1).padding(.leading, 36)
                    // Only Apple's model needs telling; it belongs to the row above.
                    NavigationLink(value: Route.language) {
                        HStack(spacing: 6) {
                            Text("Languages").font(.scaled(15, .regular, relativeTo: .subheadline)).foregroundStyle(Color.jText)
                            Spacer(minLength: 8)
                            Text(config.languages.count == 1
                                 ? LanguageView.name(config.languages[0])
                                 : config.languages.map(LanguageView.shortName).joined(separator: ", "))
                                .font(.scaled(15, .medium, relativeTo: .subheadline))
                                .foregroundStyle(Color.jText2)
                                .lineLimit(1)
                            Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(Color.jText4)
                        }
                        .padding(.leading, 36)
                        .padding(.trailing, 16)
                        .frame(minHeight: 48)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Rectangle().fill(Color.jHairline).frame(height: 1).padding(.leading, 16)
                HStack(spacing: 6) {
                    Text("Tidying and titles").font(.reading).foregroundStyle(Color.jText)
                    Spacer(minLength: 8)
                    Text(Editor.isAvailable ? "Apple" : "Not on this iPhone")
                        .font(.scaled(15, .medium, relativeTo: .subheadline))
                        .foregroundStyle(Editor.isAvailable ? Color.jText2 : Color.jText3)
                        .lineLimit(1)
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 56)
                .accessibilityElement(children: .combine)
            }
            .card()
            .animation(.easeOut(duration: 0.2), value: config.usesQwen)

            Text(Editor.isAvailable
                 ? "Tidying takes out fillers and gives each recording a title."
                 : "Without Apple Intelligence, recordings keep the words as said, without a title.")
                .font(.scaled(13, .regular, relativeTo: .footnote))
                .foregroundStyle(Color.jText3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
                .padding(.horizontal, 4)

            OwnKeyExtras()
                .padding(.top, 28)
        }
        // The same centred alert as deleting a recording.
        .alert("Remove \(SpeechPack.name)?", isPresented: $confirmingRemove) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) { SpeechPack.shared.remove() }
        } message: {
            Text("Frees \(SpeechPack.sizeLabel). New recordings go back to Apple's model; you can download it again any time.")
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
            CardSectionTitle("Service").padding(.top, 28)
            VStack(spacing: 0) {
                ExpandRow(title: "Service", value: Cloud.service.name, open: openBinding(.service)) {
                    ForEach(Array(Cloud.services.enumerated()), id: \.element) { i, service in
                        ChoiceLine(name: service.name, detail: Self.shortDetail(service),
                                   selected: service == Cloud.service, first: i == 0) {
                            config.cloudService = service
                            Task {
                                try? await Task.sleep(for: .milliseconds(250))
                                withAnimation(ExpandRow<EmptyView>.fold) { openPick = nil }
                            }
                        }
                    }
                }
                .sensoryFeedback(.selection, trigger: config.cloudService)

                if Cloud.service == .compatible {
                    hairline
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Address")
                            .font(.scaled(13, .regular, relativeTo: .footnote))
                            .foregroundStyle(Color.jText3)
                        HStack(spacing: 4) {
                            TextField(region.isChinaMainland ? "https://api.deepseek.com/v1" : "https://api.openai.com/v1",
                                      text: $config.cloudBaseURL)
                                .font(.system(size: 15, design: .monospaced))
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.URL)
                                .focused($addressFocused)
                                .onSubmit {
                                    Cloud.matchModelsToAddress()
                                    Task { await runCheck() }
                                }
                                .onChange(of: addressFocused) { _, focused in
                                    if !focused { Cloud.matchModelsToAddress() }
                                }
                            ClearButton(text: $config.cloudBaseURL, label: "Clear address") { addressFocused = true }
                        }
                    }
                    .padding(.leading, 16)
                    .padding(.trailing, 10)
                    .padding(.vertical, 10)
                    .animation(.easeOut(duration: 0.15), value: config.cloudBaseURL.isEmpty)
                }

                hairline
                HStack(spacing: 10) {
                    Text("API key").font(.reading).foregroundStyle(Color.jText)
                        .layoutPriority(1)
                    Spacer(minLength: 8)
                    if editingKey || draftKey.isEmpty {
                        SecureField("Paste your key", text: $draftKey)
                            .font(.system(size: 15, design: .monospaced))
                            .multilineTextAlignment(.trailing)
                            // A key, not a password: no offer to save it as one.
                            .textContentType(.oneTimeCode)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($keyFocused)
                            .onSubmit { keyFocused = false }
                        ClearButton(text: $draftKey, visible: keyFocused, label: "Clear key") { keyFocused = true }
                    } else {
                        checkMark
                        // Saved: just enough of it to recognise. Tap to change it.
                        Text(Self.masked(draftKey))
                            .font(.system(size: 15, design: .monospaced))
                            .foregroundStyle(Color.jText2)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                .padding(.leading, 16)
                .padding(.trailing, editingKey && !draftKey.isEmpty ? 10 : 16)
                .frame(minHeight: 56)
                .contentShape(Rectangle())
                .onTapGesture {
                    editingKey = true
                    keyFocused = true
                }
                .onChange(of: keyFocused) { _, focused in
                    if focused { editingKey = true } else { editingKey = false; saveKey() }
                }
            }
            .card()

            if Cloud.addressBlocked {
                Text("This service doesn't operate in China mainland. Here, jotto works with services that do, like Bailian, SiliconFlow or DeepSeek.")
                    .font(.scaled(13, .regular, relativeTo: .footnote))
                    .foregroundStyle(Color.jLive)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                    .padding(.horizontal, 4)
            } else if Cloud.service == .compatible {
                Text(serviceDetail)
                    .font(.scaled(13, .regular, relativeTo: .footnote))
                    .foregroundStyle(Color.jText3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                    .padding(.horizontal, 4)
            }

            CardSectionTitle("Models").padding(.top, 28)
            VStack(spacing: 0) {
                modelRow(.transcribe)
                hairline
                modelRow(.write)
            }
            .card()
            if openSlot != nil || nextSlot != nil {
                Text(Cloud.service == .openRouter
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

            // Said either way: where recordings go with this key, before and after it works.
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.jText4)
                Text(keyMissing
                     ? "Until a key works, recordings stay on this iPhone."
                     : "Audio goes from this iPhone straight to \(Cloud.sendsTo). You pay them, not jotto.")
                    .font(.scaled(13, .regular, relativeTo: .footnote))
                    .foregroundStyle(Color.jText3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 8)
            .padding(.horizontal, 4)

            if let keys = keyPage {
                Link(destination: keys) {
                    HStack(spacing: 6) {
                        Text(Cloud.service == .bailian ? "Get a Bailian key, and what it costs" : "How to get a key, and what it costs")
                        Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .semibold))
                    }
                    .font(.scaled(15, .medium, relativeTo: .subheadline))
                    .foregroundStyle(Color.jText)
                }
                .padding(.top, 20)
                .padding(.horizontal, 4)
            }
        }
        .animation(.easeOut(duration: 0.2), value: keyMissing)
    }

    private func openBinding(_ pick: Pick) -> Binding<Bool> {
        Binding(get: { openPick == pick }, set: { open in
            if open {
                openPick = pick
                openSlot = nil
            } else if openPick == pick {
                openPick = nil
            }
        })
    }

    /// Under each service's name, in its open list.
    static func shortDetail(_ service: Cloud.Service) -> String {
        switch service {
        case .openRouter: "One key for everything. Recommended."
        case .bailian: "Alibaba Cloud. One key for everything. Recommended."
        case .siliconFlow: "One key for everything."
        case .compatible: "Any service built like OpenAI's, at its address."
        }
    }

    private var hairline: some View {
        Rectangle().fill(Color.jHairline).frame(height: 1).padding(.leading, 16)
    }

    /// What the service picked is, under the switch.
    private var serviceDetail: String {
        switch Cloud.service {
        case .openRouter: "One key for transcription and polish. Recommended."
        case .bailian: "Alibaba Cloud's model service (Bailian). One key for transcription and polish. Recommended."
        case .siliconFlow: "A model service in China mainland. One key for transcription and polish."
        case .compatible where region.isChinaMainland:
            "Another service in China mainland that takes the same requests, like DeepSeek. The address and the key both come from that service."
        case .compatible: "For services built to the same standard as OpenAI's, like Groq, Together or OpenAI itself. The address and the key both come from that service."
        }
    }

    /// Where the service picked hands out keys.
    private var keyPage: URL? {
        switch Cloud.service {
        case .openRouter: URL(string: "https://openrouter.ai/keys")
        case .bailian: URL(string: "https://bailian.console.aliyun.com/?tab=model#/api-key")
        case .siliconFlow: URL(string: "https://cloud.siliconflow.cn/account/ak")
        case .compatible: nil
        }
    }

    @ViewBuilder
    private var checkMark: some View {
        switch check {
        case .unknown: EmptyView()
        case .checking: ProgressView().controlSize(.small)
        case .works:
            HStack(spacing: 4) {
                Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy))
                Text("Works")
            }
            .font(.scaled(13, .semibold, relativeTo: .footnote))
            .foregroundStyle(Color.jText)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(Color.jFill, in: Capsule())
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

            // Always there, folded to nothing when closed: it opens and
            // closes as a fold (cut off at its bottom edge) rather than
            // fading in place while the row under it slides over.
            ModelChoices(slot: slot, typed: typedBinding(slot), focus: $modelFocus) { id in
                ModelPick.set(id, for: slot)
                typed[slot] = ""
                modelFocus = nil
                // A beat to see the check move, then fold away.
                Task {
                    try? await Task.sleep(for: .milliseconds(250))
                    if openSlot == slot {
                        withAnimation(Self.fold) {
                            openSlot = nil
                            reserve = 0
                        }
                    }
                }
            } submit: {
                useTypedModel()
                withAnimation(Self.fold) {
                    openSlot = nil
                    reserve = 0
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { choicesHeight[slot] = $0 }
            .frame(height: open ? nil : 0, alignment: .top)
            .clipped()
            .allowsHitTesting(open)
            .accessibilityHidden(!open)
        }
    }

    private static let fold = Animation.smooth(duration: 0.26)
    private static let modelsEnd = "models-end"

    private func typedBinding(_ slot: Cloud.ModelSlot) -> Binding<String> {
        Binding(get: { typed[slot] ?? "" }, set: { typed[slot] = $0 })
    }

    /// Open a row, or close it. With the other row open, that one folds
    /// away first and this one opens after: one closing, then one
    /// opening, rather than both at once with the rows sliding past.
    private func toggle(_ slot: Cloud.ModelSlot) {
        if openPick != nil { withAnimation(Self.fold) { openPick = nil } }
        useTypedModel()
        modelFocus = nil
        if openSlot == slot {
            withAnimation(Self.fold) {
                openSlot = nil
                reserve = 0
            }
            return
        }
        typed[slot] = ModelPick.isListed(ModelPick.value(slot), for: slot) ? "" : ModelPick.value(slot)
        guard openSlot != nil else {
            reserve = 0
            withAnimation(Self.fold) { openSlot = slot }
            return
        }
        nextSlot = slot
        reserve = choicesHeight[openSlot!] ?? 0
        withAnimation(Self.fold) { openSlot = nil }
        Task {
            try? await Task.sleep(for: .milliseconds(230))
            guard nextSlot == slot else { return }
            // In one transaction: withAnimation first applies changes made
            // outside it, which for a moment left neither row open nor
            // waiting, and the footnote under the card went and came back.
            withAnimation(Self.fold) {
                openSlot = slot
                nextSlot = nil
            }
            try? await Task.sleep(for: .milliseconds(300))
            // Keep the page as long as it was: if the new choices are
            // shorter, the difference stays as room at the bottom, so a
            // page at its end doesn't settle down by a row afterwards.
            let kept = max(0, reserve - (choicesHeight[slot] ?? 0))
            var quiet = Transaction()
            quiet.disablesAnimations = true
            withTransaction(quiet) { reserve = kept }
        }
    }

    /// The typed model, if there is one and it isn't already in use.
    private func useTypedModel() {
        guard let slot = openSlot else { return }
        let model = (typed[slot] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, model != ModelPick.value(slot) else { return }
        ModelPick.set(model, for: slot)
    }

    static func masked(_ key: String) -> String {
        guard key.count > 12 else { return String(repeating: "•", count: key.count) }
        let head = key.prefix(key.hasPrefix("sk-or-v1-") ? 9 : 3)
        return head + "••••••••" + key.suffix(4)
    }

    private func loadKey() {
        draftKey = Keychain.read(account: Cloud.service.rawValue) ?? ""
        check = .unknown
        if !draftKey.isEmpty { Task { await runCheck() } }
    }

    private func saveKey() {
        let key = draftKey.trimmingCharacters(in: .whitespacesAndNewlines)
        draftKey = key
        guard key != (Keychain.read(account: Cloud.service.rawValue) ?? "") else { return }
        Keychain.save(key, account: Cloud.service.rawValue)
        Task { await runCheck() }
        Pipeline.shared.languageChanged()
    }

    private func runCheck() async {
        guard !draftKey.isEmpty, !Cloud.addressBlocked else { check = .unknown; return }
        check = .checking
        switch await Cloud.check(key: draftKey, service: Cloud.service, base: config.cloudBaseURL) {
        case .works: check = .works
        case .turnedDown: check = .fails
        case .unanswered: check = .unanswered
        }
    }
}

extension Cloud {
    /// Who gets the recordings with your own key: the service picked, or
    /// the one at the address.
    @MainActor static var sendsTo: String {
        if service != .compatible { return service.name }
        return URL(string: config.cloudBaseURL.trimmingCharacters(in: .whitespaces))?.host() ?? "the service at that address"
    }
}

/// A row that opens its choices in place, under it, as the model rows
/// do (design 13f): its name, what's picked, and a chevron that turns.
/// The choices fold open and shut at their bottom edge.
struct ExpandRow<Choices: View>: View {
    let title: String
    var icon: String? = nil
    let value: String
    @Binding var open: Bool
    @ViewBuilder var choices: Choices

    static var fold: Animation { .smooth(duration: 0.26) }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(Self.fold) { open.toggle() }
            } label: {
                HStack(spacing: 6) {
                    if let icon { RowIcon(icon).padding(.trailing, 6) }
                    Text(title).font(.reading).foregroundStyle(Color.jText)
                        .lineLimit(1)
                        .layoutPriority(1)
                    Spacer(minLength: 8)
                    Text(value)
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
                .frame(minHeight: 56)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(open ? "Hides the choices" : "Shows the choices")

            VStack(spacing: 0) { choices }
                .padding(.bottom, 2)
                .frame(height: open ? nil : 0, alignment: .top)
                .clipped()
                .allowsHitTesting(open)
                .accessibilityHidden(!open)
        }
    }
}

/// One choice under an open row: the check, its name and a line about
/// it, and anything it carries at the end (a size, a bin).
struct ChoiceLine<Trailing: View>: View {
    let name: String
    var detail: String?
    let selected: Bool
    var first = false
    /// Under a row with an icon: the check sits in the icon's column, so
    /// the names line up with the row's.
    var underIcon = false
    let action: () -> Void
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(spacing: 0) {
            if !first {
                // Hairlines start where the names do.
                Rectangle().fill(Color.jHairline).frame(height: 1).padding(.leading, underIcon ? 56 : 48).padding(.trailing, 16)
            }
            HStack(spacing: 12) {
                Button(action: action) {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Color.jText)
                            .opacity(selected ? 1 : 0)
                            .frame(width: underIcon ? 28 : 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(name)
                                .font(.scaled(16, .regular, relativeTo: .body))
                                .foregroundStyle(Color.jText)
                            if let detail {
                                Text(detail)
                                    .font(.scaled(12, .regular, relativeTo: .caption1))
                                    .foregroundStyle(Color.jText3)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
                trailing
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .frame(minHeight: 54)
        }
    }
}

extension ChoiceLine where Trailing == EmptyView {
    init(name: String, detail: String? = nil, selected: Bool, first: Bool = false, underIcon: Bool = false,
         action: @escaping () -> Void) {
        self.init(name: name, detail: detail, selected: selected, first: first, underIcon: underIcon, action: action) { EmptyView() }
    }
}

/// Speech to text on this iPhone, picked in place: Apple's model, or
/// Qwen3-ASR, downloaded the first time it's picked. While it comes, the
/// row shows how far; once here, the menu can remove it (design 13h).
private struct SpeechMenuRow: View {
    @Binding var open: Bool
    let pick: (AppConfig.SpeechModel) -> Void
    let remove: () -> Void
    private var pack: SpeechPack { .shared }
    private var config: AppConfig { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ExpandRow(title: "Speech to text", value: value, open: $open) {
                ChoiceLine(name: "Apple", detail: "Built in", selected: !config.usesQwen, first: true) { choose(.apple) }
                ChoiceLine(name: SpeechPack.name,
                           detail: pack.isReady ? "Many languages, even mixed" : "Many languages · \(SpeechPack.sizeLabel)",
                           selected: config.usesQwen) { choose(.qwen) } trailing: {
                    switch pack.state {
                    case .absent, .failed:
                        Image(systemName: "arrow.down.to.line")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.jText3)
                            .accessibilityHidden(true)
                    case .downloading:
                        circle(label: "Stop downloading", action: pack.cancel) {
                            Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                        }
                    case .preparing:
                        ProgressView().controlSize(.small)
                    case .ready:
                        circle(label: "Remove \(SpeechPack.name)", action: remove) {
                            GlyphView(glyph: .trash, color: .jText2).frame(width: 15, height: 15)
                        }
                    }
                }
            }

            if let line = statusLine {
                VStack(alignment: .leading, spacing: 7) {
                    if case let .downloading(fraction) = pack.state {
                        ProgressBar(fraction: fraction)
                    }
                    Text(line)
                        .font(.scaled(13, .regular, relativeTo: .footnote).monospacedDigit())
                        .foregroundStyle(warns ? Color.jLive : Color.jText3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 16)
                .padding(.top, -6)
                .padding(.bottom, 14)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: pack.state)
    }

    /// Picked: a beat to see the check move, then fold away. Qwen3-ASR
    /// not here yet starts coming, its progress under the row.
    private func choose(_ model: AppConfig.SpeechModel) {
        pick(model)
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            withAnimation(ExpandRow<EmptyView>.fold) { open = false }
        }
    }

    private func circle(label: String, action: @escaping () -> Void, @ViewBuilder _ glyph: () -> some View) -> some View {
        Button(action: action) {
            glyph()
                .foregroundStyle(Color.jText2)
                .frame(width: 30, height: 30)
                .background(Color.jFill, in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        // Laid out as the 30-pt circle, touched as 44 pt.
        .padding(-7)
    }

    private var value: String {
        switch pack.state {
        case .downloading, .preparing: SpeechPack.name
        default: config.usesQwen ? SpeechPack.name : "Apple"
        }
    }

    private var warns: Bool {
        if case .failed = pack.state { return true }
        return pack.stalled
    }

    /// How far, how long to go, and what to do meanwhile: keep jotto
    /// open for the App Store, which loses a download sent to the
    /// background; Hugging Face carries on with jotto closed.
    private var statusLine: String? {
        switch pack.state {
        case .absent, .ready: return nil
        case .preparing: return "Getting it ready…"
        case let .failed(why): return why
        case let .downloading(fraction):
            if pack.stalled {
                return pack.fromApple
                    ? "Waiting for the network. Keep jotto open."
                    : "Can't reach the download server yet. It keeps trying; Apple's model works meanwhile."
            }
            var parts = ["\(Int(fraction * 100))%"]
            if let left = pack.secondsLeft { parts.append(Self.timeLeft(left)) }
            if pack.fromApple {
                parts.append(pack.startedOver ? "started over · keep jotto open" : "keep jotto open")
            }
            return parts.joined(separator: " · ")
        }
    }

    static func timeLeft(_ seconds: Double) -> String {
        if seconds < 60 { return "under a minute left" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 90 { return "about \(minutes) min left" }
        return "about \(Int((seconds / 3600).rounded())) h left"
    }
}

/// Under On this iPhone: what your own key would add, said once.
private struct OwnKeyExtras: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("With your own key you'd also get")
                .font(.scaled(13, .medium, relativeTo: .footnote))
                .foregroundStyle(Color.jText2)
            if StoreRegion.shared.isChinaMainland {
                item("character.bubble", "Mixed languages, heard better")
            } else {
                item("person.2", "Who said what")
            }
            item("square.stack.3d.up", "Larger models, run by the service")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.jWell, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }

    private func item(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.jText2)
                .frame(width: 18)
            Text(text)
                .font(.scaled(15, .regular, relativeTo: .subheadline))
                .foregroundStyle(Color.jText)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ProgressBar: View {
    let fraction: Double
    var body: some View {
        GeometryReader { geo in
            Capsule().fill(Color.jHairline)
                .overlay(alignment: .leading) {
                    Capsule().fill(Color.jLive).frame(width: max(4, geo.size.width * fraction))
                }
        }
        .frame(height: 4)
        .animation(.linear(duration: 0.2), value: fraction)
    }
}

/// The models you can pick for transcription and for writing (titles,
/// summaries, formatting), and how to set them.
@MainActor
enum ModelPick {
    static func title(_ slot: Cloud.ModelSlot) -> String {
        slot == .transcribe ? "Speech to text" : "Tidying and titles"
    }

    /// For the service in use: OpenRouter's names, or the service at the
    /// address's own.
    static func choices(_ slot: Cloud.ModelSlot) -> [Cloud.Suggestion] {
        Cloud.suggestions(slot)
    }

    static func value(_ slot: Cloud.ModelSlot) -> String {
        slot == .transcribe ? Cloud.transcribeModel : Cloud.writeModel
    }

    static func set(_ model: String, for slot: Cloud.ModelSlot) {
        Cloud.setModel(model, for: slot)
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
    var focus: FocusState<Cloud.ModelSlot?>.Binding
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
                            HStack(spacing: 0) {
                                Text(choice.name).foregroundStyle(Color.jText)
                                // Which service it's on, at an address.
                                if let by = choice.by { Text(" · \(by)").foregroundStyle(Color.jText3) }
                            }
                            .font(.scaled(16, .regular, relativeTo: .body))
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
                TextField(Cloud.service == .openRouter ? "Another, like provider/model" : "Another model",
                          text: $typed)
                    .font(.system(size: 15, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .focused(focus, equals: slot)
                    .onSubmit(submit)
                ClearButton(text: $typed, label: "Clear model") { focus.wrappedValue = slot }
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

/// A large pick-one option, one of two side by side: an icon and the
/// check on top, then its name and a sentence on what it means.
struct ChoiceCard: View {
    let title: String
    let detail: String
    let icon: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(Color.jText)
                    Spacer()
                    ZStack {
                        Circle().strokeBorder(Color.jText5, lineWidth: 1.5).opacity(selected ? 0 : 1)
                        Circle().fill(Color.jText).opacity(selected ? 1 : 0)
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundStyle(Color.jBg)
                            .opacity(selected ? 1 : 0)
                    }
                    .frame(width: 20, height: 20)
                }
                .frame(height: 22)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.scaled(16, .semibold, relativeTo: .callout))
                        .foregroundStyle(Color.jText)
                    Text(detail)
                        .font(.scaled(13, .regular, relativeTo: .footnote))
                        .foregroundStyle(Color.jText2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(Color.jBg, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(selected ? Color.jText : Color.jHairline, lineWidth: selected ? 1.5 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .animation(.easeOut(duration: 0.2), value: selected)
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
                PageHeader(title: "Languages", detail: "The languages people speak in your recordings. With more than one, jotto listens to the start of each recording and picks.") { dismiss() }

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
            // Picked but not usable yet (one iOS has for dictation isn't
            // jotto's until asked for): ask now, while jotto is in front.
            await models.ensure(config.languages)
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
                : picked ? "Downloads with jotto open" : nil
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
            models.release(id)
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
