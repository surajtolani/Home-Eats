import Foundation
import SwiftData

/// One decided meal for a given day and slot (breakfast/lunch/dinner/other).
/// A day can have several `PlannedMeal`s in the same slot — e.g. "Dinner:
/// Tacos" plus a separate "Other: Ice cream run" — since real days aren't
/// always one meal per slot.
@Model
final class PlannedMeal {
    @Attribute(.unique) var id: UUID
    /// Normalized to midnight, local time.
    var date: Date
    var slot: MealSlot

    var recipe: Recipe?
    var restaurant: Restaurant?
    var decidedByMemberID: UUID?
    var decidedAt: Date
    var notes: String?

    init(
        id: UUID = UUID(),
        date: Date,
        slot: MealSlot,
        recipe: Recipe? = nil,
        restaurant: Restaurant? = nil,
        decidedByMemberID: UUID? = nil,
        decidedAt: Date = .now,
        notes: String? = nil
    ) {
        self.id = id
        self.date = Self.normalize(date)
        self.slot = slot
        self.recipe = recipe
        self.restaurant = restaurant
        self.decidedByMemberID = decidedByMemberID
        self.decidedAt = decidedAt
        self.notes = notes
    }

    static func normalize(_ date: Date) -> Date {
        Calendar.current.startOfDay(for: date)
    }

    var isHomeCooked: Bool { recipe != nil }
    var isEatingOut: Bool { restaurant != nil }

    var displayTitle: String {
        recipe?.title ?? restaurant?.name ?? "Planned"
    }
}
