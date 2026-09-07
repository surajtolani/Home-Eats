import Foundation

/// The meal slots within a single day. `other` covers anything beyond the
/// standard three — an ice cream run after dinner, a snack, a coffee outing
/// — and, like every slot, can have more than one entry (see `PlannedMeal`).
enum MealSlot: String, Codable, CaseIterable, Identifiable {
    case breakfast
    case lunch
    case dinner
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .breakfast: return "Breakfast"
        case .lunch: return "Lunch"
        case .dinner: return "Dinner"
        case .other: return "Other"
        }
    }

    var symbolName: String {
        switch self {
        case .breakfast: return "sunrise"
        case .lunch: return "sun.max"
        case .dinner: return "moon.stars"
        case .other: return "sparkles"
        }
    }

    /// Display order within a day: breakfast, lunch, dinner, then anything extra.
    var sortIndex: Int {
        switch self {
        case .breakfast: return 0
        case .lunch: return 1
        case .dinner: return 2
        case .other: return 3
        }
    }
}
