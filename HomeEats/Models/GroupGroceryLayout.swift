import Foundation
import SwiftData

/// Local, offline-capable mirror of one row from a group's "My Layout"
/// aisles (`GET /groups/:groupId/grocery/aisles` — see `serializeAisle(...)`
/// in backend/routes/groupGroceryAisles.js and `GroupStoreAisle` in
/// prisma/schema.prisma, which this mirrors field-for-field). Same
/// "server-id-as-local-id, separate type from the personal-use model"
/// conventions as `GroupPlannedMeal`/`GroupSharedGroceryItem` — see either of
/// their doc comments in `GroupSharedMealPlan.swift`/`GroupSharedGroceryItem.swift`
/// for the full reasoning. This one parallels the local, personal
/// `StoreAisle` model (`HomeEats/Models/StoreAisle.swift`), which per this
/// feature's own scope notes stays untouched — `GroupAislesManagerView`
/// reuses that screen's *visual* language against this new type instead.
///
/// **Any member, not MANAGER-only**: unlike most of a group's other mutable
/// rows, every write to an aisle (create/rename/reorder/delete) is open to
/// any group member — see routes/groupGroceryAisles.js's own doc comment for
/// why an aisle is a display/organization construct, not a planning
/// decision. Nothing about this model itself encodes that; it's simply that
/// `GroupSharedGroceryListView`/`GroupAislesManagerView` never gate any
/// aisle action on `isManager`, mirroring the backend's own uniform
/// "any member" rule.
@Model
final class GroupStoreAisle {
    /// Same server-id-as-local-id convention as `GroupPlannedMeal.id` — see
    /// its doc comment for the full reasoning, including the
    /// not-yet-pushed placeholder case (`isLocalPlaceholderID` below).
    @Attribute(.unique) var id: String
    var groupID: String
    var name: String
    /// A `Double`, matching the backend's own `Float` `GroupStoreAisle
    /// .sortIndex` — see that field's doc comment in prisma/schema.prisma on
    /// why this is a float (reorder-by-inserting-between-neighbors), unlike
    /// the *local*, personal `StoreAisle.sortIndex`'s plain `Int`. This
    /// app's own drag handling (`GroupAislesManagerView.move`) still
    /// renumbers every row to consecutive whole numbers on every reorder,
    /// exactly like the local `AislesManagerView.move` does — matching the
    /// float type is purely about keeping this row's wire shape aligned
    /// with the server's, not because this app's own UI ever computes a
    /// genuinely fractional value here.
    var sortIndex: Double
    /// Set only for the ten starter aisles the backend seeds once per group
    /// (see `ensureDefaultAislesSeeded` in routes/groupGroceryAisles.js) —
    /// same "what a `GroupSharedGroceryItem` falls back to grouping under
    /// when nothing's explicitly placed it elsewhere" role as the local
    /// `StoreAisle.linkedCategory`; see that field's own doc comment for the
    /// identical reasoning.
    var linkedCategory: GroceryCategory?
    var createdAt: Date
    /// This row's sync-tracking state — see `GroupSyncState`'s own doc
    /// comment for the full push/pull/reconcile design `GroupSyncService`
    /// applies identically here (reusing the exact same
    /// `ReconciliationAction.decide` pull-side rule as every other model in
    /// this feature).
    var syncState: GroupSyncState

    init(
        id: String,
        groupID: String,
        name: String,
        sortIndex: Double = 0,
        linkedCategory: GroceryCategory? = nil,
        createdAt: Date = .now,
        syncState: GroupSyncState = .synced
    ) {
        self.id = id
        self.groupID = groupID
        self.name = name
        self.sortIndex = sortIndex
        self.linkedCategory = linkedCategory
        self.createdAt = createdAt
        self.syncState = syncState
    }

    static let localPlaceholderIDPrefix = "local-pending-"

    static func newLocalPlaceholderID() -> String {
        localPlaceholderIDPrefix + UUID().uuidString
    }

    var isLocalPlaceholderID: Bool {
        id.hasPrefix(Self.localPlaceholderIDPrefix)
    }
}

/// Local, offline-capable mirror of one row from a group's standing staples
/// list (`GET /groups/:groupId/grocery/staples` — see `serializeStaple(...)`
/// in backend/routes/groupGroceryStaples.js and `GroupStapleItem` in
/// prisma/schema.prisma, which this mirrors field-for-field). Parallels the
/// local, personal `StapleItem` model (`HomeEats/Models/StapleItem.swift`),
/// untouched per this feature's own scope notes — `GroupStaplesManagerView`
/// reuses that screen's *visual* language against this new type instead.
/// Same any-member reasoning as `GroupStoreAisle` above — see
/// routes/groupGroceryStaples.js's own doc comment.
@Model
final class GroupStapleItem {
    @Attribute(.unique) var id: String
    var groupID: String
    var name: String
    var category: GroceryCategory
    var defaultQuantityText: String?
    /// Whether this staple should be included the next time a grocery list
    /// is generated — carried over field-for-field from the local
    /// `StapleItem.isActive` for interface parity, though (matching both the
    /// local app and the backend today) toggling it has no automated
    /// downstream effect on this group's actual list; see
    /// routes/groupGroceryStaples.js's own doc comment for why.
    var isActive: Bool
    var addedByUserID: String
    var createdAt: Date
    var syncState: GroupSyncState

    init(
        id: String,
        groupID: String,
        name: String,
        category: GroceryCategory,
        defaultQuantityText: String? = nil,
        isActive: Bool = true,
        addedByUserID: String,
        createdAt: Date = .now,
        syncState: GroupSyncState = .synced
    ) {
        self.id = id
        self.groupID = groupID
        self.name = name
        self.category = category
        self.defaultQuantityText = defaultQuantityText
        self.isActive = isActive
        self.addedByUserID = addedByUserID
        self.createdAt = createdAt
        self.syncState = syncState
    }

    static let localPlaceholderIDPrefix = "local-pending-"

    static func newLocalPlaceholderID() -> String {
        localPlaceholderIDPrefix + UUID().uuidString
    }

    var isLocalPlaceholderID: Bool {
        id.hasPrefix(Self.localPlaceholderIDPrefix)
    }
}

/// Local, read-only mirror of one row from a group's "past groceries"
/// catalog (`GET /groups/:groupId/grocery/history` — see
/// routes/groupGrocery.js's own doc comment on that route, and
/// `GroupGroceryHistoryEntry` in prisma/schema.prisma). Parallels the local,
/// personal `HistoricalGroceryItem` model, untouched per this feature's own
/// scope notes.
///
/// Deliberately simpler than every other model in this file: there is no
/// create/update/delete route for this at all (see the wire type
/// `RemoteGroupGroceryHistoryEntry`'s own doc comment in AccountModels.swift)
/// — every row here is written automatically, server-side, and this app
/// never queues a pending local change against one, so there is no
/// `syncState` field here at all. `id` is a locally-computed, deterministic
/// key (`groupID` + normalized `name` — see `makeID(groupID:name:)` below),
/// not a server id (the response itself carries none), so two pulls of the
/// same underlying row always resolve to the same local row rather than
/// duplicating it. `GroupSyncService.reconcileGroceryHistory` simply
/// replaces this group's whole local set with whatever the latest pull
/// returned each cycle — see that method's own doc comment.
@Model
final class GroupGroceryHistoryEntry {
    @Attribute(.unique) var id: String
    var groupID: String
    var name: String
    var category: GroceryCategory
    var addedAt: Date

    init(groupID: String, name: String, category: GroceryCategory, addedAt: Date = .now) {
        self.id = Self.makeID(groupID: groupID, name: name)
        self.groupID = groupID
        self.name = name
        self.category = category
        self.addedAt = addedAt
    }

    /// Deterministic per-(group, item) key — same lowercased/trimmed
    /// normalization as the backend's own `normalizeHistoryName(...)` in
    /// routes/groupGrocery.js, so this local row's identity lines up with
    /// the server's own dedupe key (`@@unique([groupId, normalizedName])`
    /// on `GroupGroceryHistoryEntry` in prisma/schema.prisma) even though
    /// the wire response carries no id of its own to key off directly.
    static func makeID(groupID: String, name: String) -> String {
        groupID + "::" + name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
