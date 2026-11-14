import SwiftUI

/// Month calendar for jumping far back, opened by tapping the day's name.
/// Months run from the first recording (at least six months back) to this
/// month, newest at the bottom where it opens. Dots mark days with
/// recordings; only days after today are muted.
struct DayPicker: View {
    @Binding var selection: Date
    let marked: Set<Date>
    let earliest: Date?
    @Environment(\.closeDrawer) private var closeDrawer

    private struct Month: Identifiable {
        let id: Date
        let name: String
        /// Leading blanks then the days, in rows of seven.
        let cells: [Date?]
    }

    private var months: [Month] {
        let calendar = Calendar.current
        let now = Date.now
        guard let thisMonth = calendar.dateInterval(of: .month, for: now)?.start else { return [] }
        let floor = calendar.date(byAdding: .month, value: -5, to: thisMonth) ?? thisMonth
        let first = earliest.flatMap { calendar.dateInterval(of: .month, for: $0)?.start }.map { min($0, floor) } ?? floor
        let showsYear = calendar.component(.year, from: first) != calendar.component(.year, from: now)

        var result: [Month] = []
        var start = first
        while start <= thisMonth {
            let count = calendar.range(of: .day, in: .month, for: start)?.count ?? 30
            let lead = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
            var cells: [Date?] = Array(repeating: nil, count: lead)
            cells += (0..<count).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
            while cells.count % 7 != 0 { cells.append(nil) }
            let name = showsYear
                ? start.formatted(.dateTime.month(.wide).year())
                : start.formatted(.dateTime.month(.wide))
            result.append(Month(id: start, name: name, cells: cells))
            guard let next = calendar.date(byAdding: .month, value: 1, to: start) else { break }
            start = next
        }
        return result
    }

    var body: some View {
        let calendar = Calendar.current
        let firstDay = earliest.map { calendar.startOfDay(for: $0) }
        let now = Date.now

        VStack(spacing: 0) {
            HStack {
                Text("Pick a day")
                    .font(.sheetTitle)
                    .foregroundStyle(Color.jText)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                CircleIconButton(glyph: .close, label: "Close", fill: .jSheetFill) { closeDrawer?() }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 10)

            HStack(spacing: 0) {
                ForEach(Array(weekdayLetters.enumerated()), id: \.offset) { _, letter in
                    Text(letter).font(.weekday).foregroundStyle(Color.jText4).frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.jSheetHairline).frame(height: 1) }
            .accessibilityHidden(true)

            ScrollView {
                // Not lazy: a few hundred cells, and lazy stacks leave gaps
                // when the scroll view starts at the bottom.
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(months) { month in
                        Text(month.name)
                            .font(.label)
                            .foregroundStyle(Color.jText)
                            .padding(.leading, 6)
                            .padding(.top, 16)
                            .padding(.bottom, 6)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(0..<(month.cells.count / 7), id: \.self) { row in
                            HStack(spacing: 0) {
                                ForEach(0..<7, id: \.self) { col in
                                    if let date = month.cells[row * 7 + col] {
                                        cell(date, now: now, firstDay: firstDay)
                                    } else {
                                        Color.clear.frame(maxWidth: .infinity).frame(height: 46)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .defaultScrollAnchor(.bottom)
            .scrollIndicators(.hidden)
        }
        // A drawer like Send's, a little shorter than the screen so the
        // day it was opened from still shows above it.
        .containerRelativeFrame(.vertical) { length, _ in (length * 0.78).rounded() }
    }

    private var weekdayLetters: [String] {
        let calendar = Calendar.current
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let start = calendar.firstWeekday - 1
        return Array(symbols[start...] + symbols[..<start])
    }

    private func cell(_ date: Date, now: Date, firstDay: Date?) -> some View {
        let calendar = Calendar.current
        let selected = calendar.isDate(date, inSameDayAs: selection)
        let isToday = calendar.isDateInToday(date)
        let future = date > now
        // Every day you can pick looks the same; the dot says which have
        // recordings. Only days still to come are faint.
        let muted = future
        let hasRecordings = marked.contains(date)

        return Button {
            selection = date
            closeDrawer?()
        } label: {
            VStack(spacing: 2) {
                let number = date.formatted(.dateTime.day())
                Text(number)
                    .font(.system(size: 16, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Color.jBg : muted ? Color.jText5 : Color.jText)
                    .offset(x: OpticalCentre.nudge(number))
                Circle()
                    .fill(selected && isToday ? Color.jLive : selected ? Color.jBg : Color.jText)
                    .frame(width: 4, height: 4)
                    .opacity(hasRecordings || (selected && isToday) ? 1 : 0)
            }
            .frame(width: 42, height: 42)
            .background {
                if selected { Circle().fill(Color.jText) }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 46)
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
