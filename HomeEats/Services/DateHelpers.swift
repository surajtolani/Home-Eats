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
