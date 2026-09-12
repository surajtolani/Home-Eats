import Foundation
import SwiftData

/// One configured "time to do the grocery run" notification. Unlike the
/// single weekly planning reminder (`AppSettings.reminder*`), a household
/// can have several of these — some families grocery shop/order more than
/// once a week — so this is its own table rather than a handful of fixed
/// fields, and `NotificationScheduler` schedules one repeating local
/// notification per enabled row.
@Model
final class GroceryReminder {
    @Attribute(.unique) var id: UUID
    /// 1 = Sunday ... 7 = Saturday, matching `Calendar.current.component(.weekday, ...)`.
    var weekday: Int
    var hour: Int
    var minute: Int
    var isEnabled: Bool
    var createdAt: Date

    init(
        id: UUID = UUID(),
        weekday: Int = 1,
        hour: Int = 10,
        minute: Int = 0,
        isEnabled: Bool = true,
        createdAt: Date = .now
    ) {
        self.id = id
        self.weekday = weekday
        self.hour = hour
        self.minute = minute
        self.isEnabled = isEnabled
        self.createdAt = createdAt
    }

    var weekdaySymbol: String {
        let symbols = Calendar.current.weekdaySymbols
        let index = max(0, min(symbols.count - 1, weekday - 1))
        return symbols[index]
    }

    /// A time-only `Date` (today's date, this reminder's hour/minute) for
    /// binding to a `DatePicker`'s `.hourAndMinute` display.
    var timeAsDate: Date {
        Calendar.current.date(from: DateComponents(hour: hour, minute: minute)) ?? .now
    }
}
