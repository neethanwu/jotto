import SwiftUI

// MARK: - Before iOS asks

/// Why jotto wants location, before iOS asks for it: what places give, why
/// Always, and that iOS will ask twice. Continue goes on to iOS's prompts
/// (While Using, then Always).
struct PlacesSheet: View {
    /// Not now or the close button: the Days card goes for good.
    var onDecline: () -> Void = {}
    @Environment(\.closeDrawer) private var closeDrawer
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Text("Location, and text\nas you record")
                    .font(.sheetTitle)
                    .tracking(-0.48)
                    .lineSpacing(2)
                    .foregroundStyle(Color.jText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                CircleIconButton(glyph: .close, label: "Close", fill: .jSheetFill) { decline() }
            }
            .padding(.top, 12)

            point(icon: AnyView(GlyphView(glyph: .pin, color: .jText).frame(width: 16, height: 16)),
                  title: "Where each one was said",
                  text: "Every recording keeps its place, and so does a paragraph said somewhere new. Places stay on this iPhone; they go with a recording only when you add them.")
                .padding(.top, 22)
            point(icon: AnyView(Image(systemName: "waveform").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.jLive)),
                  title: "Text as you record",
                  text: "While your watch records, jotto keeps running on this iPhone, so each part turns into text as it arrives and the recording is ready moments after you stop.")
                .padding(.top, 18)

            VStack(alignment: .leading, spacing: 6) {
                Text("Why Always")
                    .font(.scaled(13, .semibold, relativeTo: .footnote))
                    .foregroundStyle(Color.jText)
                Text("Your watch starts recordings while this iPhone is locked, and only Always lets jotto begin then. jotto uses location only while a recording goes on and until it's transcribed, at low accuracy. iOS asks twice: While Using first, then Always.")
                    .foregroundStyle(Color.jText2)
                Text("Prefer While Using? Then jotto stays running from the last time you open it, and iOS shows the location arrow.")
                    .foregroundStyle(Color.jText3)
            }
            .font(.scaled(13, .regular, relativeTo: .footnote))
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
            .background(Color.jSheetWell, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.jSheetHairline))
            .padding(.top, 20)

            HStack(spacing: 10) {
                Button { decline() } label: {
                    Text("Not now")
                        .font(.label)
                        .foregroundStyle(Color.jText)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(Color.jSheetFill, in: Capsule())
                }
                .buttonStyle(.plain)
                .frame(width: 148)

                Button {
                    close()
                    // After the drawer is down, so iOS's prompt isn't over it.
                    Task {
                        try? await Task.sleep(for: .seconds(0.35))
                        PlaceTracker.shared.turnOn()
                    }
                } label: {
                    Text("Continue")
                        .font(.label)
                        .foregroundStyle(Color.jBg)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(Color.jText, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 20)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private func point(icon: AnyView, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            icon
                .frame(width: 36, height: 36)
                .background(Color.jSheetFill, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.scaled(16, .semibold, relativeTo: .callout))
                    .foregroundStyle(Color.jText)
                Text(text)
                    .font(.summary)
                    .lineSpacing(3)
                    .foregroundStyle(Color.jText2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func decline() {
        onDecline()
        close()
    }

    private func close() {
        if let closeDrawer { closeDrawer() } else { dismiss() }
    }
}

// MARK: - Days: once

/// Offered once, at the top of Days, after a watch recording waited for
/// jotto to be opened; gone for good when closed or turned on.
struct PlacesCard: View {
    let waitedTitle: String?
    let turnOn: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Text as you record")
                    .font(.scaled(16, .semibold, relativeTo: .callout))
                    .foregroundStyle(Color.jText)
                Spacer(minLength: 8)
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { PlaceTracker.shared.cardDismissed = true }
                } label: {
                    GlyphView(glyph: .close, color: .jText4)
                        .frame(width: 16, height: 16)
                        .padding(8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(-8)
                .accessibilityLabel("Close")
            }
            Text("\(waitedTitle ?? "Your last recording") waited until you opened jotto. With Location on, your watch's recordings turn into text while you record.")
                .font(.scaled(14, .regular, relativeTo: .subheadline))
                .lineSpacing(3)
                .foregroundStyle(Color.jText2)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: turnOn) {
                Text("Turn on Location")
                    .font(.scaled(14, .medium, relativeTo: .subheadline))
                    .foregroundStyle(Color.jBg)
                    .padding(.horizontal, 15)
                    .frame(height: 34)
                    .background(Color.jText, in: Capsule())
            }
            .buttonStyle(PressStyle())
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .card()
    }
}

// MARK: - Settings

/// Settings → Location. The switch first, and the state of location under
/// it, with the one thing to do about it when there is one. Then what
/// it gives, the facts about location, and why Always.
/// The switch shows what actually happens: off while iOS doesn't allow
/// location, though the choice is kept, so allowing it again turns
/// places back on.
struct PlacesPage: View {
    @Environment(\.dismiss) private var dismiss
    @State private var asking = false
    private var places: PlaceTracker { .shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader(title: "Location", detail: "Where each recording was made, and text while you record.") { dismiss() }

                VStack(spacing: 0) {
                    Toggle(isOn: Binding(
                        get: { places.isOn },
                        set: { on in
                            if !on {
                                places.turnOff()
                            } else if places.needsAsking {
                                asking = true
                            } else {
                                places.turnOn()
                            }
                        }
                    )) {
                        Text("Note where you record")
                            .font(.scaled(17, .semibold, relativeTo: .body))
                            .foregroundStyle(Color.jText)
                    }
                    .toggleStyle(JottoToggleStyle())
                    .padding(.horizontal, 16)
                    .frame(minHeight: 60)

                    if places.isOn || places.isDenied {
                        Rectangle().fill(Color.jHairline).frame(height: 1).padding(.leading, 16)
                        Link(destination: Self.settings) {
                            CardRow("Allowed", value: places.permissionLabel, accessory: .outside, warns: warns)
                        }
                        .buttonStyle(.plain)
                    }
                    if let note {
                        callout(note)
                    }
                }
                .card()
                .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .padding(.top, 24)
                .animation(.easeOut(duration: 0.2), value: places.isOn)

                CardSectionTitle("What it does").padding(.top, 28)
                VStack(alignment: .leading, spacing: 18) {
                    benefit(icon: AnyView(GlyphView(glyph: .pin, color: .jText).frame(width: 16, height: 16)),
                            title: "Every recording keeps its place",
                            text: "Like \u{201C}Mission District\u{201D} on Days and on the transcript.")
                    benefit(icon: AnyView(Image(systemName: "text.alignleft").font(.system(size: 14, weight: .medium)).foregroundStyle(Color.jText)),
                            title: "Text while you record",
                            text: "Your watch's recordings are written down before you open jotto.")
                }
                .padding(.horizontal, 4)

                VStack(alignment: .leading, spacing: 12) {
                    Text("Your location")
                        .font(.scaled(13, .medium, relativeTo: .footnote))
                        .foregroundStyle(Color.jText2)
                    fact("clock", "Only while recording and transcribing")
                    fact("scope", "Low accuracy: the area, not the address")
                    fact("iphone", "Places stay on this iPhone")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(Color.jWell, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .padding(.top, 28)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Why Always")
                        .font(.scaled(15, .semibold, relativeTo: .subheadline))
                        .foregroundStyle(Color.jText)
                        .accessibilityAddTraits(.isHeader)
                    Text("Your watch starts recordings while this iPhone is locked, and only Always lets jotto begin then. iOS asks twice: While Using first, then Always. With While Using, jotto stays running from the last time you open it, and iOS shows the location arrow.")
                        .font(.scaled(13, .regular, relativeTo: .footnote))
                        .lineSpacing(3)
                        .foregroundStyle(Color.jText2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 4)
                .padding(.top, 24)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 48)
        }
        .statusBarCover()
        .background(Color.jBg)
        .toolbar(.hidden, for: .navigationBar)
        .drawer(isPresented: $asking) { PlacesSheet() }
    }

    private static let settings = URL(string: UIApplication.openSettingsURLString)!

    private var warns: Bool {
        places.isDenied || places.permission == .authorizedWhenInUse || (places.isOn && !places.isPrecise)
    }

    private struct Note {
        let text: String
        let action: String
    }

    /// The one thing to fix, if any, and the button that goes there.
    private var note: Note? {
        if places.isDenied, places.wantsPlaces {
            return Note(text: "Location is off for jotto in Settings, so recordings don't keep a place.", action: "Open Settings")
        }
        guard places.isOn else { return nil }
        if places.permission == .authorizedWhenInUse {
            return Note(text: "jotto stays running so it's ready when your watch records, and iOS shows the location arrow. Choose Always to use location only while you record.", action: "Change to Always")
        }
        if !places.isPrecise {
            return Note(text: "Precise Location is off for jotto, so places are only roughly right.", action: "Open Settings")
        }
        return nil
    }

    private func callout(_ note: Note) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(Color.jLive).frame(width: 7, height: 7).padding(.top, 6)
            VStack(alignment: .leading, spacing: 12) {
                Text(note.text)
                    .font(.scaled(14, .regular, relativeTo: .subheadline))
                    .lineSpacing(2)
                    .foregroundStyle(Color.jText)
                    .fixedSize(horizontal: false, vertical: true)
                Link(destination: Self.settings) {
                    HStack(spacing: 5) {
                        Text(note.action)
                        Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .bold))
                    }
                    .font(.scaled(14, .semibold, relativeTo: .subheadline))
                    .foregroundStyle(Color.jBg)
                    .padding(.horizontal, 14)
                    .frame(height: 32)
                    .background(Color.jText, in: Capsule())
                }
                .buttonStyle(PressStyle())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.jLiveWash)
    }

    private func benefit(icon: AnyView, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            icon
                .frame(width: 36, height: 36)
                .background(Color.jFill, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.scaled(16, .semibold, relativeTo: .callout))
                    .foregroundStyle(Color.jText)
                Text(text)
                    .font(.scaled(13, .regular, relativeTo: .footnote))
                    .foregroundStyle(Color.jText3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func fact(_ icon: String, _ text: String) -> some View {
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
