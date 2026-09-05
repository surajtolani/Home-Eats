import Foundation
import SwiftData

/// Singleton-style settings row (there's always exactly one, looked up by
/// `AppSettings.singletonID`). Holds the configurable weekly planning
/// reminder and the phase-2 cloud sync placeholder toggle.
@Model
final class AppSettings {
    @Attribute(.unique) var id: UUID
    var householdName: String
    var reminderEnabled: Bool
    /// 1 = Sunday ... 7 = Saturday, matching `Calendar.current.component(.weekday, ...)`.
    var reminderWeekday: Int
    var reminderHour: Int
    var reminderMinute: Int
    /// Placeholder for the optional account/cloud-sync phase described in the
    /// spec. Local storage is always the source of truth; this only flags
    /// intent until sync is implemented.
    var cloudSyncEnabled: Bool

    init(
        id: UUID = AppSettings.singletonID,
        householdName: String = "Our Family",
        reminderEnabled: Bool = true,
        reminderWeekday: Int = 1, // Sunday
        reminderHour: Int = 18,
        reminderMinute: Int = 0,
        cloudSyncEnabled: Bool = false
    ) {
        self.id = id
        self.householdName = householdName
        self.reminderEnabled = reminderEnabled
        self.reminderWeekday = reminderWeekday
        self.reminderHour = reminderHour
        self.reminderMinute = reminderMinute
        self.cloudSyncEnabled = cloudSyncEnabled
    }

    static let singletonID = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!

    var weekdaySymbol: String {
        let symbols = Calendar.current.weekdaySymbols
        let index = max(0, min(symbols.count - 1, reminderWeekday - 1))
        return symbols[index]
    }
}
