import Foundation

extension Calendar {
    /// Midnight of the start of the week containing `date`, respecting this
    /// calendar's `firstWeekday`.
    func startOfWeek(containing date: Date) -> Date {
        let startOfDay = self.startOfDay(for: date)
        let components = dateComponents([.yearForWeekOfYear, .weekOfYear], from: startOfDay)
        return self.date(from: components) ?? startOfDay
    }

    /// The 7 calendar days making up the week containing `date`.
    func daysOfWeek(containing date: Date) -> [Date] {
        let start = startOfWeek(containing: date)
        return (0..<7).compactMap { self.date(byAdding: .day, value: $0, to: start) }
    }

    /// Midnight of the 1st of the month containing `date`.
    func startOfMonth(for date: Date) -> Date {
        let components = dateComponents([.year, .month], from: date)
        return self.date(from: components) ?? startOfDay(for: date)
    }

    /// Weekday initials ("S", "M", "T", ...) rotated to start on `firstWeekday`.
    var orderedVeryShortWeekdaySymbols: [String] {
        let symbols = veryShortWeekdaySymbols
        let offset = max(0, min(symbols.count - 1, firstWeekday - 1))
        return Array(symbols[offset...] + symbols[..<offset])
    }

    /// Every day cell a month-grid calendar needs to show `date`'s month,
    /// including the leading/trailing days from adjacent months needed to
    /// fill out complete weeks.
    func gridDays(forMonthContaining date: Date) -> [Date] {
        guard let monthInterval = dateInterval(of: .month, for: date) else { return [] }
        let lastOfMonth = self.date(byAdding: .day, value: -1, to: monthInterval.end) ?? monthInterval.start
        let gridStart = startOfWeek(containing: monthInterval.start)
        let lastWeekStart = startOfWeek(containing: lastOfMonth)
        guard let gridEnd = self.date(byAdding: .day, value: 6, to: lastWeekStart) else { return [] }

        var days: [Date] = []
        var current = gridStart
        while current <= gridEnd {
            days.append(current)
            guard let next = self.date(byAdding: .day, value: 1, to: current) else { break }
            current = next
        }
        return days
    }
}

extension Date {
    var startOfDay: Date { Calendar.current.startOfDay(for: self) }

    func isSameDay(as other: Date) -> Bool {
        Calendar.current.isDate(self, inSameDayAs: other)
    }

    func formatted(as style: Date.FormatStyle) -> String {
        self.formatted(style)
    }

    static let weekdayFull: Date.FormatStyle = .dateTime.weekday(.wide)
    static let monthDay: Date.FormatStyle = .dateTime.month(.abbreviated).day()
}
