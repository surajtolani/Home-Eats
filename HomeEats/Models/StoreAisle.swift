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

    init(
        id: UUID = UUID(),
        name: String,
        sortIndex: Int = 0,
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.sortIndex = sortIndex
        self.createdAt = createdAt
    }
}

/// Remembers which aisle a given grocery item belongs in, keyed by the
/// item's canonical name (not a specific week's `GroceryItem` row, which
/// gets regenerated every week) so the assignment persists indefinitely.
@Model
final class ItemAisleAssignment {
    @Attribute(.unique) var id: UUID
    var canonicalItemName: String
    var aisleID: UUID

    init(id: UUID = UUID(), canonicalItemName: String, aisleID: UUID) {
        self.id = id
        self.canonicalItemName = canonicalItemName
        self.aisleID = aisleID
    }
}
