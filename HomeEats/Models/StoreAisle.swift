import Foundation
import SwiftData

/// A user-defined aisle/section in the family's actual grocery store (e.g.
/// "Aisle 3 - Snacks"), independent of the app's fixed `GroceryCategory`
/// list. This is what powers the "My Grocery Layout" view — a shopping list
/// laid out to match how a specific store is physically organized.
@Model
final class StoreAisle {
    @Attribute(.unique) var id: UUID
    var name: String
    /// Controls display order (top-to-bottom = the order you walk the store).
    var sortIndex: Int
    var createdAt: Date
    /// Set only for the ten starter aisles `SampleDataSeeder` seeds one-time
    /// per `GroceryCategory` so "My Layout" opens grouped the same way "By
    /// Category" already is, instead of dumping every item into "Unsorted"
    /// until someone manually places it. `nil` for a genuinely custom aisle
    /// the household typed in themselves. This is what a `GroceryItem`
    /// falls back to grouping under (see `GroceryListView.resolvedAisleID`)
    /// when nothing has explicitly placed it elsewhere — the household can
    /// still rename a starter aisle (e.g. "Dairy & Eggs" -> "Fridge case")
    /// without losing the automatic membership, since matching is by this
    /// category, not by `name`.
    var linkedCategory: GroceryCategory?

    init(
        id: UUID = UUID(),
        name: String,
        sortIndex: Int = 0,
        createdAt: Date = .now,
        linkedCategory: GroceryCategory? = nil
    ) {
        self.id = id
        self.name = name
        self.sortIndex = sortIndex
        self.createdAt = createdAt
        self.linkedCategory = linkedCategory
    }
}

/// Remembers which aisle a given grocery item belongs in, keyed by the
/// item's canonical name (not a specific week's `GroceryItem` row, which
/// gets regenerated every week) so the assignment persists indefinitely.
/// `aisleID == nil` is itself a meaningful, explicit choice — "I want this
/// in Unsorted" — distinct from *no row existing at all*, which means
/// "nothing's been chosen, fall back to the aisle mirroring this item's
/// `GroceryCategory`." Without that distinction, picking "Unsorted" from the
/// move menu could never actually stick for an item whose category already
/// has a starter aisle: the very next lookup would just fall back to that
/// default aisle again.
@Model
final class ItemAisleAssignment {
    @Attribute(.unique) var id: UUID
    var canonicalItemName: String
    var aisleID: UUID?

    init(id: UUID = UUID(), canonicalItemName: String, aisleID: UUID?) {
        self.id = id
        self.canonicalItemName = canonicalItemName
        self.aisleID = aisleID
    }
}
