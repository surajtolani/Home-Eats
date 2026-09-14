import Foundation
import SwiftData

/// An item the household has bought before, kept in a browsable catalog
/// (grouped by category) so it can be re-added to a future week's list with
/// one tap instead of retyping it. Populated automatically (checking an item
/// off the live list adds/updates its entry here — see `GroceryListView
/// .recordAsHistorical`), by typing directly into the catalog's own quick-add
/// field, or in bulk by pasting a past grocery list — see
/// `GroceryHistoryImportSheet`.
///
/// Renamed "Household Groceries" in the UI (was "Past Groceries") — direct
/// user framing: this is deliberately *individualized*, a local, per-device/
/// per-account catalog that's never synced to the backend or shared with any
/// group, as opposed to the group-scoped `GroupGroceryHistoryEntry` (shared
/// across every member of one group) that plays the same "add with one tap"
/// role on `GroupSharedGroceryListView`. `GroupSharedGroceryListView`'s own
/// "From Your Household Groceries" section reads directly from this same
/// table to let a group member bring one of their own personal go-tos onto
/// a shared list, without that catalog entry itself ever becoming shared.
@Model
final class HistoricalGroceryItem {
    @Attribute(.unique) var id: UUID
    var name: String
    var category: GroceryCategory
    var addedAt: Date
    /// The `ProductOption` (specific brand/photo) you usually get for this
    /// item, if you've ever picked one — direct user request ("if you
    /// always generally buy a specific brand, you can include that to the
    /// master grocery list"). Set two ways: automatically, whenever
    /// checking off a live `GroceryItem` that already has its own
    /// `selectedProductOptionID` (see `GroceryListView.recordAsHistorical`),
    /// or directly by tapping this entry's own product thumbnail in the
    /// Household Groceries list (the same `ProductOptionPickerView` sheet
    /// the live list's own row already uses). `nil` means "no particular
    /// brand noted" — a perfectly normal, common state, not an error.
    var preferredProductOptionID: UUID?

    init(
        id: UUID = UUID(),
        name: String,
        category: GroceryCategory? = nil,
        addedAt: Date = .now,
        preferredProductOptionID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.category = category ?? GroceryCategory.guess(fromIngredientName: name)
        self.addedAt = addedAt
        self.preferredProductOptionID = preferredProductOptionID
    }
}
