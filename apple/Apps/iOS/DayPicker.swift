import SwiftUI

/// The month under the day's name: tap the title, pick a day. A popover
/// rather than a page, since it's a quick jump. One month at a time with
/// arrows; dots mark days with recordings; future days and days before
/// the first recording are muted.
struct MonthPopover: View {
    @Binding var selection: Date
    let marked: Set<Date>
    let earliest: Date?
    @Environment(\.dismiss) private var dismiss
    @State private var month: Date

    init(selection: Binding<Date>, marked: Set<Date>, earliest: Date?) {
        _selection = selection
        self.marked = marked
        self.earliest = earliest
        _month = State(initialValue: Self.monthStart(selection.wrappedValue))
    }

    private static func monthStart(_ date: Date) -> Date {
        Calendar.current.dateInterval(of: .month, for: date)?.start ?? date
    }

    /// From the first recording's month (at least five months back) to this one.
    private var firstMonth: Date {
        let back = Calendar.current.date(byAdding: .month, value: -5, to: Self.monthStart(.now)) ?? .now
        return min(earliest.map(Self.monthStart) ?? back, back)
    }

    private var cells: [Date?] {
        let calendar = Calendar.current
        let count = calendar.range(of: .day, in: .month, for: month)?.count ?? 30
        let lead = (calendar.component(.weekday, from: month) - calendar.firstWeekday + 7) % 7
        var out: [Date?] = Array(repeating: nil, count: lead)
        out += (0..<count).compactMap { calendar.date(byAdding: .day, value: $0, to: month) }
        while out.count % 7 != 0 { out.append(nil) }
        return out
    }

    var body: some View {
        let calendar = Calendar.current
        let canGoBack = month > firstMonth
        let canGoOn = month < Self.monthStart(.now)
        VStack(spacing: 10) {
            HStack {
                Text(month.formatted(.dateTime.month(.wide).year()))
                    .font(.scaled(17, .semibold, relativeTo: .headline))
                    .foregroundStyle(Color.jText)
                    .contentTransition(.numericText())
                Spacer()
                HStack(spacing: 8) {
                    step(.back, label: "Previous month", enabled: canGoBack) { move(-1) }
                    step(.back, label: "Next month", enabled: canGoOn) { move(1) }
                        .scaleEffect(x: -1)
                }
            }
            .padding(.leading, 6)

            HStack(spacing: 0) {
                ForEach(Array(weekdayLetters.enumerated()), id: \.offset) { _, letter in
                    Text(letter).font(.weekday).foregroundStyle(Color.jText4).frame(maxWidth: .infinity)
                }
            }
            .accessibilityHidden(true)

            VStack(spacing: 0) {
                ForEach(0..<(cells.count / 7), id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(0..<7, id: \.self) { col in
                            if let date = cells[row * 7 + col] {
                                cell(date)
                            } else {
                                Color.clear.frame(maxWidth: .infinity).frame(height: 40)
                            }
                        }
                    }
                }
            }

            Button("Go to today") {
                selection = calendar.startOfDay(for: .now)
                dismiss()
            }
            .font(.scaled(13, .semibold, relativeTo: .footnote))
            .foregroundStyle(Color.jText2)
            .padding(.top, 2)
        }
        .padding(.horizontal, 14)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .frame(width: 322)
        .presentationBackground(Color.jSheet)
        .sensoryFeedback(.selection, trigger: month)
    }

    private func move(_ months: Int) {
        guard let next = Calendar.current.date(byAdding: .month, value: months, to: month) else { return }
        withAnimation(.snappy(duration: 0.25)) { month = next }
    }

    private func step(_ glyph: Glyph, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            GlyphView(glyph: glyph)
                .frame(width: 16, height: 16)
                .frame(width: 32, height: 32)
                .overlay(Circle().strokeBorder(Color.jRing, lineWidth: 1))
                .contentShape(Circle().inset(by: -6))
        }
        .buttonStyle(PressStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.3)
        .accessibilityLabel(label)
    }

    private var weekdayLetters: [String] {
        let calendar = Calendar.current
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let start = calendar.firstWeekday - 1
        return Array(symbols[start...] + symbols[..<start])
    }

    private func cell(_ date: Date) -> some View {
        let calendar = Calendar.current
        let selected = calendar.isDate(date, inSameDayAs: selection)
        let isToday = calendar.isDateInToday(date)
        let future = date > .now
        let beforeFirst = earliest.map { date < calendar.startOfDay(for: $0) } ?? false
        let hasRecordings = marked.contains(date)

        return Button {
            selection = date
            dismiss()
        } label: {
            VStack(spacing: 1) {
                Text(date.formatted(.dateTime.day()))
                    .font(.system(size: 15, weight: selected ? .semibold : .medium).monospacedDigit())
                    .foregroundStyle(selected ? Color.jBg : future || beforeFirst ? Color.jText5 : Color.jText)
                Circle()
                    .fill(selected && isToday ? Color.jLive : selected ? Color.jBg : Color.jText)
                    .frame(width: 4, height: 4)
                    .opacity(hasRecordings || (selected && isToday) ? 1 : 0)
            }
            .frame(width: 36, height: 36)
            .background { if selected { Circle().fill(Color.jText) } }
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(future)
        .accessibilityLabel(date.formatted(date: .complete, time: .omitted))
        .accessibilityValue(hasRecordings ? "Has recordings" : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The last few searches, newest first.
enum RecentSearches {
    private static let key = "recentSearches"

    static var all: [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }

    static func add(_ query: String) {
        guard query.count >= 2 else { return }
        let list = [query] + all.filter { $0.caseInsensitiveCompare(query) != .orderedSame }
        UserDefaults.standard.set(Array(list.prefix(5)), forKey: key)
    }
}
