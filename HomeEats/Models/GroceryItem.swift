import Foundation
import SwiftData

enum GroceryListSection: String, Codable {
    /// Ingredients pulled from this week's selected recipes.
    case thisWeek
    /// The household's other regular/historical items (replaces the notepad).
    case staples
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
        isManuallyAdded: Bool = false
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
    }
}
