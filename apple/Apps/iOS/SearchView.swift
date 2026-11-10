import SwiftUI

/// Search across every recording's clean text and titles. Pushed from
/// the magnifier on Days, with the keyboard up.
struct SearchView: View {
    let router: Router
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: SearchResults?
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Back and the field share one bar that stays put while results scroll.
            HStack(spacing: 10) {
                CircleIconButton(glyph: .back, label: "Back") { dismiss() }
                field
            }
            .padding(.leading, 16)
            .padding(.trailing, 20)
            .frame(height: 52)

            ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let results, results.query == trimmed {
                    Text(summary(results))
                        .font(.meta)
                        .foregroundStyle(Color.jText3)
                        .padding(.top, 12)
                    LazyVStack(alignment: .leading, spacing: 28) {
                        ForEach(results.sessions) { session in
                            group(session, query: results.query)
                        }
                    }
                    .padding(.top, 24)
                } else if let error {
                    Text(error).font(.summary).foregroundStyle(Color.jText3).padding(.top, 16)
                } else if trimmed.isEmpty {
                    Text("Words, names, anything someone said")
                        .font(.summary)
                        .foregroundStyle(Color.jText3)
                        .padding(.top, 12)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.bottom, 48)
            }
            .scrollDismissesKeyboard(.immediately)
        }
        .background(Color.jBg)
        .toolbar(.hidden, for: .navigationBar)
        .task(id: trimmed) { await search() }
        .onAppear { if query.isEmpty { focused = true } }
    }

    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }

    private var field: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.jText3)
            TextField("Search recordings", text: $query)
                .font(.rowTitle)
                .foregroundStyle(Color.jText)
                .focused($focused)
                .submitLabel(.search)
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Color.jText4)
                }
                .accessibilityLabel("Clear")
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .frame(height: 44)
        .background(Color.jFill, in: Capsule())
    }

    private func summary(_ r: SearchResults) -> String {
        r.matches == 0
            ? "No matches"
            : "\(r.matches) \(r.matches == 1 ? "match" : "matches") in \(Format.plural(r.sessions.count, "recording"))"
    }

    private func group(_ session: SearchResults.Session, query: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { router.days.append(.transcript(id: session.id)) } label: {
                HStack(alignment: .firstTextBaseline) {
                    Text(session.title ?? Format.provisionalTitle(session.startedAt))
                        .font(.rowTitle)
                        .foregroundStyle(Color.jText)
                    Spacer()
                    Text(Format.weekdayDayMonth(session.startedAt))
                        .font(.metaSmall)
                        .foregroundStyle(Color.jText3)
                }
            }
            .buttonStyle(.plain)

            ForEach(session.hits, id: \.self) { hit in
                Button { router.days.append(.transcript(id: session.id, at: hit.start)) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text(Format.clock(hit.start))
                            .font(.metaSmall)
                            .foregroundStyle(Color.jText3)
                            .frame(width: 48, alignment: .leading)
                        highlighted(hit.text, query)
                            .font(.summary)
                            .lineSpacing(3)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// The query in `text` Semibold, the rest in `text-2`.
    private func highlighted(_ text: String, _ query: String) -> Text {
        var out = AttributedString(text)
        out.foregroundColor = Color.jText2
        var searchRange = out.startIndex..<out.endIndex
        while let range = out[searchRange].range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) {
            out[range].foregroundColor = Color.jText
            out[range].font = .system(size: 15, weight: .semibold)
            searchRange = range.upperBound..<out.endIndex
        }
        return Text(out)
    }

    private func search() async {
        guard trimmed.count >= 2 else {
            results = nil
            error = nil
            return
        }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        do {
            results = try await API.search(trimmed)
            error = nil
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }
}
