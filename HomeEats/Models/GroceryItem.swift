import Foundation
import SwiftData

enum GroceryListSection: String, Codable {
    /// Freshly pulled from this week's recipes, not yet reviewed — shown in
    /// the "Suggested" section with Add/Reject actions, per item, before it
    /// ever counts as something you're actually buying. Lets a week where
    /// you already have half the ingredients on hand skip those instead of
    /// silently re-buying them.
    case suggested
    /// Accepted (or manually typed/quick-added) — actually on the list.
    case thisWeek
    /// The household's other regular/historical items (replaces the notepad).
    case staples
    /// Explicitly rejected out of `suggested` ("I already have this") —
    /// kept, not deleted, so it's easy to change your mind and add it after all.
    case rejected
}

/// A single line on the shopping list for a given week. `GroceryItem`s are
/// (re)generated from the week's recipes by `GroceryListBuilder`, but the
/// checked state, chosen product, and any manual additions persist so the
/// list behaves like a normal shopping list app while someone is in the store.
@Model
final class GroceryItem {
    @Attribute(.unique) var id: UUID
    /// Normalized display name, e.g. "onion" (duplicates across recipes are merged into this one row).
    var name: String
    var category: GroceryCategory
    var section: GroceryListSection
    /// Human-readable combined quantity, e.g. "3 cups" or "2 (from 2 recipes)".
    var quantityText: String
    var isChecked: Bool
    /// Which week (Sunday start date, normalized) this line belongs to.
    var weekStartDate: Date
    /// Recipes that contributed to this line, for provenance ("needed for: Tacos, Chili").
    var sourceRecipeIDs: [UUID]
    /// The brand/product the family wants for this generic item, if one is set.
    var selectedProductOptionID: UUID?
    /// True for lines the user typed in by hand rather than ones generated from recipes/staples.
    var isManuallyAdded: Bool
    /// How many of this item to get — independent of `quantityText` (which
    /// is a description like "3 cups", not necessarily a whole-item count).
    /// Defaulted so this stays a lightweight migration.
    var quantityCount: Int = 1
    /// True once the user has dragged this item to a different category
    /// than it was auto-guessed/configured into — `GroceryListBuilder`
    /// checks this before overwriting `category` on a regenerate, the same
    /// way a "My Layout" aisle placement is never overwritten automatically.
    var categoryManuallySet: Bool = false
    /// Manual sort position within a category, lowest first. A `Double`
    /// (rather than an `Int`) so reordering can slot an item between two
    /// existing ones (new value = the average of its new neighbors) without
    /// ever needing to renumber every other row in the category. Freshly
    /// generated items are appended after everything that already exists
    /// this week, so an existing manual order is never disturbed by a
    /// regenerate.
    var orderIndex: Double = 0

    init(
        id: UUID = UUID(),
        name: String,
        category: GroceryCategory,
        section: GroceryListSection,
        quantityText: String = "",
        isChecked: Bool = false,
        weekStartDate: Date,
        sourceRecipeIDs: [UUID] = [],
        selectedProductOptionID: UUID? = nil,
        isManuallyAdded: Bool = false,
        quantityCount: Int = 1,
        categoryManuallySet: Bool = false,
        orderIndex: Double = 0
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.section = section
        self.quantityText = quantityText
        self.isChecked = isChecked
        self.weekStartDate = weekStartDate
        self.sourceRecipeIDs = sourceRecipeIDs
        self.selectedProductOptionID = selectedProductOptionID
        self.isManuallyAdded = isManuallyAdded
        self.quantityCount = quantityCount
        self.categoryManuallySet = categoryManuallySet
        self.orderIndex = orderIndex
    }
}
