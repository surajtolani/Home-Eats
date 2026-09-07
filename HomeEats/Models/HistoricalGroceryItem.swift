import Foundation
import SwiftData

/// An item the household has bought before, kept in a browsable catalog
/// (grouped by category) so it can be re-added to a future week's list with
/// one tap instead of retyping it. Populated either automatically (nothing
/// yet) or in bulk by pasting a past grocery list — see `GroceryHistoryImportSheet`.
@Model
final class HistoricalGroceryItem {
    @Attribute(.unique) var id: UUID
    var name: String
    var category: GroceryCategory
    var addedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        category: GroceryCategory? = nil,
        addedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.category = category ?? GroceryCategory.guess(fromIngredientName: name)
        self.addedAt = addedAt
    }
}
