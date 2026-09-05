import Foundation
import SwiftData

enum DayPlanKind: String, Codable {
    case unplanned
    case homeCookedRecipe
    case eatingOut
}

/// The plan for a single calendar day. This is the heart of the "day-by-day"
/// planning requirement: every day gets its own entry rather than one big
/// weekly blob, so travel days / activity nights can differ from the rest
/// of the week.
@Model
final class DayPlan {
    @Attribute(.unique) var id: UUID
    /// Normalized to midnight, local time, so each day has exactly one DayPlan.
    var date: Date
    var kind: DayPlanKind

    /// Set once someone finalizes the plan for the day.
    var decidedRecipe: Recipe?
    var decidedRestaurant: Restaurant?
    var decidedByMemberID: UUID?
    var decidedAt: Date?

    var notes: String?

    /// Lightweight proposals from family members before the day is decided.
    /// Multiple people can each suggest a recipe/restaurant, and everyone
    /// can upvote any suggestion (see MealSuggestion.votedMemberIDs).
    @Relationship(deleteRule: .cascade, inverse: \MealSuggestion.dayPlan)
    var suggestions: [MealSuggestion] = []

    init(
        id: UUID = UUID(),
        date: Date,
        kind: DayPlanKind = .unplanned,
        decidedRecipe: Recipe? = nil,
        decidedRestaurant: Restaurant? = nil,
        decidedByMemberID: UUID? = nil,
        decidedAt: Date? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.date = DayPlan.normalize(date)
        self.kind = kind
        self.decidedRecipe = decidedRecipe
        self.decidedRestaurant = decidedRestaurant
        self.decidedByMemberID = decidedByMemberID
        self.decidedAt = decidedAt
        self.notes = notes
    }

    static func normalize(_ date: Date) -> Date {
        Calendar.current.startOfDay(for: date)
    }

    var isDecided: Bool {
        switch kind {
        case .unplanned: return false
        case .homeCookedRecipe: return decidedRecipe != nil
        case .eatingOut: return decidedRestaurant != nil
        }
    }

    func finalize(recipe: Recipe, by memberID: UUID?) {
        kind = .homeCookedRecipe
        decidedRecipe = recipe
        decidedRestaurant = nil
        decidedByMemberID = memberID
        decidedAt = .now
    }

    func finalize(restaurant: Restaurant, by memberID: UUID?) {
        kind = .eatingOut
        decidedRestaurant = restaurant
        decidedRecipe = nil
        decidedByMemberID = memberID
        decidedAt = .now
    }

    func clearDecision() {
        kind = .unplanned
        decidedRecipe = nil
        decidedRestaurant = nil
        decidedByMemberID = nil
        decidedAt = nil
    }
}
