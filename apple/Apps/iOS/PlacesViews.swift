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
                Text("Places, and text\nas you record")
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
            Text("\(waitedTitle ?? "Your last recording") waited until you opened jotto. With Places on, your watch's recordings turn into text while you record.")
                .font(.scaled(14, .regular, relativeTo: .subheadline))
                .lineSpacing(3)
                .foregroundStyle(Color.jText2)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: turnOn) {
                Text("Turn on Places")
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

/// Settings → Places. The switch shows what actually happens: off while
/// iOS doesn't allow location, though the choice is kept, so allowing it
/// again turns places back on.
struct PlacesSettings: View {
    let ask: () -> Void
    private var places: PlaceTracker { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection("Places") {
                SettingsToggle("Note where you record", isOn: Binding(
                    get: { places.isOn },
                    set: { on in
                        if !on {
                            places.turnOff()
                        } else if places.needsAsking {
                            ask()
                        } else {
                            places.turnOn()
                        }
                    }
                ))
                if places.isOn || places.isDenied, let settings = URL(string: UIApplication.openSettingsURLString) {
                    Link(destination: settings) {
                        SettingsRow("Location", value: places.permissionLabel, opensOutside: true, warns: places.isDenied)
                    }
                }
            }
            Text(footer)
                .font(.scaled(13, .regular, relativeTo: .footnote))
                .lineSpacing(3)
                .foregroundStyle(Color.jText3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
        }
    }

    private var footer: String {
        if places.isDenied {
            return "Location is off for jotto in Settings, so recordings don't keep a place. Turn this on to allow it there."
        }
        guard places.isOn else {
            return "Keep the place each recording was made, and have your watch's recordings turn into text while you record. Places stay on this iPhone."
        }
        let rough = places.isPrecise ? "" : " Precise Location is off for jotto, so places are only roughly right."
        if places.permission == .authorizedWhenInUse {
            return "jotto stays running from the last time you opened it, so it's ready when your watch records, and iOS shows the location arrow the whole time. Set Location to Always to use it only while you record." + rough
        }
        return "Each recording keeps the place it was made. While you record, jotto also stays running, so your watch's recording turns into text as you go. Location is used only then and until it's transcribed, and places stay on this iPhone." + rough
    }
}
