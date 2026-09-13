import Foundation
import SwiftData

/// Local, offline-capable mirror of one row from a group's shared grocery
/// list on the backend (`GET /groups/:groupId/grocery`'s `items` — see
/// `serializeItem` in routes/groupGrocery.js and `prisma/schema.prisma`'s
/// `GroupGroceryItem` model, which this mirrors field-for-field). Named
/// distinctly from the existing local, personal-use `GroceryItem` model
/// (`HomeEats/Models/GroceryItem.swift`) for the same reason the backend's
/// own `GroupGroceryItem` is named distinctly from a plain `GroceryItem`
/// there — see that model's doc comment: this is a deliberately smaller
/// shape (no `weekStartDate`/`selectedProductOptionID`/`quantityCount`/
/// `categoryManuallySet`/`layoutOrderIndex` — v1 has no group-scoped "My
/// Layout" aisle subsystem at all, category-grouped ordering only). Reuses
/// the local `GroceryCategory` type directly (not a duplicate enum) for its
/// existing displayName/symbolName/sortIndex display logic, same "the
/// backend's own enum case names were chosen to match it exactly" reasoning
/// as `GroupPlannedMeal.slot`.
@Model
final class GroupSharedGroceryItem {
    /// Same server-id-as-local-id convention as `GroupPlannedMeal.id` — see
    /// its doc comment for the full reasoning, including the
    /// not-yet-pushed placeholder case.
    @Attribute(.unique) var id: String
    var groupID: String
    var name: String
    var category: GroceryCategory
    var section: GroupGrocerySection
    var quantityText: String
    var isChecked: Bool
    /// Manual sort position within a category, lowest first — same
    /// "average of its new neighbors" fractional-reorder convention as the
    /// local `GroceryItem.orderIndex` (see that field's own doc comment),
    /// and the same `Double`-not-`Int` reasoning: `GroupGroceryItem.orderIndex`
    /// is a Prisma `Float` server-side for exactly this reason too (see
    /// that model's doc comment in prisma/schema.prisma).
    var orderIndex: Double
    /// "My Layout" placement (Phase 4) — mirrors `GroupGroceryItem.aisleId`/
    /// `.aisleManuallySet` on the backend exactly, including `aisleManuallySet
    /// == false` meaning `aisleID` is not meaningful yet and a client should
    /// fall back to whichever `GroupStoreAisle` has `linkedCategory ==
    /// category` (see that field's own doc comment in prisma/schema.prisma,
    /// and `GroupSharedGroceryListView.resolvedAisleID`, which applies that
    /// fallback the same way the local `GroceryListView.resolvedAisleID`
    /// does). Originally this model had no "My Layout" counterpart at all —
    /// see this type's own top doc comment, which predates Phase 4.
    var aisleID: String?
    var aisleManuallySet: Bool
    var addedByUserID: String
    var createdAt: Date
    /// This row's sync-tracking state — see `GroupSyncState`'s own doc
    /// comment. Unlike `GroupPlannedMeal`, this model's `.pendingUpdate` is
    /// real and used: `isChecked`/`orderIndex` changes (the two fields any
    /// member may set — see routes/groupGrocery.js's field-by-field role
    /// split) go through the normal offline-queued path. A manager's edit
    /// to `name`/`category`/`quantityText`/`section` is deliberately
    /// **not** represented as a pending state on this model at all — see
    /// `GroupSyncService.editGroceryItem`'s own doc comment for why that one
    /// case is instead an immediate, online-only call.
    var syncState: GroupSyncState
    /// The backend's real `updatedAt` on `GroupGroceryItem` (unlike
    /// `PlannedMeal`, which has none) — set from the server's value on both
    /// a successful push and a pull's upsert, for display/troubleshooting.
    /// Not itself read by any reconciliation decision (see
    /// `GroupSyncState`'s doc comment on why this whole feature is
    /// state-based, not timestamp-based, even here).
    var serverUpdatedAt: Date?

    init(
        id: String,
        groupID: String,
        name: String,
        category: GroceryCategory,
        section: GroupGrocerySection,
        quantityText: String = "",
        isChecked: Bool = false,
        orderIndex: Double = 0,
        aisleID: String? = nil,
        aisleManuallySet: Bool = false,
        addedByUserID: String,
        createdAt: Date = .now,
        syncState: GroupSyncState = .synced,
        serverUpdatedAt: Date? = nil
    ) {
        self.id = id
        self.groupID = groupID
        self.name = name
        self.category = category
        self.section = section
        self.quantityText = quantityText
        self.isChecked = isChecked
        self.orderIndex = orderIndex
        self.aisleID = aisleID
        self.aisleManuallySet = aisleManuallySet
        self.addedByUserID = addedByUserID
        self.createdAt = createdAt
        self.syncState = syncState
        self.serverUpdatedAt = serverUpdatedAt
    }

    static let localPlaceholderIDPrefix = "local-pending-"

    static func newLocalPlaceholderID() -> String {
        localPlaceholderIDPrefix + UUID().uuidString
    }

    var isLocalPlaceholderID: Bool {
        id.hasPrefix(Self.localPlaceholderIDPrefix)
    }
}
