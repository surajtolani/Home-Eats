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
    /// Distinguishes "eating at" a restaurant from "ordering delivery/
    /// takeout from" one — same `restaurant` reference either way, so the
    /// household's restaurant list doesn't need two separate entries per
    /// place. Defaults to `false` (and has a default here, not just in the
    /// initializer) so adding this attribute to existing `PlannedMeal` rows
    /// stays a lightweight SwiftData migration.
    var isOrderIn: Bool = false
    var decidedByMemberID: UUID?
    var decidedAt: Date
    var notes: String?
    /// When set, an exact date/time a one-time "don't forget to place your
    /// order" local notification was scheduled for — only meaningful for
    /// an order-in meal. Kept here (rather than just letting the
    /// notification fire and forget) so the reminder can be shown/edited/
    /// cancelled later, and re-synced if this meal's own date ever changes.
    var orderReminderDate: Date?

    init(
        id: UUID = UUID(),
        date: Date,
        slot: MealSlot,
        recipe: Recipe? = nil,
        restaurant: Restaurant? = nil,
        isOrderIn: Bool = false,
        decidedByMemberID: UUID? = nil,
        decidedAt: Date = .now,
        notes: String? = nil,
        orderReminderDate: Date? = nil
    ) {
        self.id = id
        self.date = Self.normalize(date)
        self.slot = slot
        self.recipe = recipe
        self.restaurant = restaurant
        self.isOrderIn = isOrderIn
        self.decidedByMemberID = decidedByMemberID
        self.decidedAt = decidedAt
        self.notes = notes
        self.orderReminderDate = orderReminderDate
    }

    static func normalize(_ date: Date) -> Date {
        Calendar.current.startOfDay(for: date)
    }

    var isHomeCooked: Bool { recipe != nil }
    /// Dining at the restaurant, as opposed to ordering in from it.
    var isEatingOut: Bool { restaurant != nil && !isOrderIn }
    var isOrderingIn: Bool { restaurant != nil && isOrderIn }

    var displayTitle: String {
        recipe?.title ?? restaurant?.name ?? "Planned"
    }
}
