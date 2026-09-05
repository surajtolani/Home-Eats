import Foundation
import SwiftData

/// A regular/historical grocery item the household typically buys on its
/// weekly run — independent of any recipe (paper towels, coffee, milk...).
/// This is the digital replacement for "the notepad on the fridge".
@Model
final class StapleItem {
    @Attribute(.unique) var id: UUID
    var name: String
    var category: GroceryCategory
    var defaultQuantityText: String?
    /// Whether this staple should be included the next time a grocery list is generated.
    var isActive: Bool
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        category: GroceryCategory? = nil,
        defaultQuantityText: String? = nil,
        isActive: Bool = true,
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.category = category ?? GroceryCategory.guess(fromIngredientName: name)
        self.defaultQuantityText = defaultQuantityText
        self.isActive = isActive
        self.createdAt = createdAt
    }
}
