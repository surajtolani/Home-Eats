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
///
/// **A former sibling type used to live in this file too**: `GroupStapleItem`,
/// the group counterpart of the local `StapleItem` model — a standing
/// "staples" template list, reachable from a `GroupStaplesManagerView`
/// sheet. Removed outright per direct user feedback that the concept added
/// nothing useful, along with its backend model/route/migration and every
/// iOS reference to it — see `backend/README.md`'s "My Layout" section for
/// the removal note. This is unrelated to `GroupGrocerySection.staples`
/// (`AccountModels.swift`), a tag on one specific line already on the live
/// list, which is untouched.
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

// `GroupGroceryHistoryEntry` — a per-group "past groceries" catalog
// (auto-populated by any member checking an item off, `GET
// /groups/:groupId/grocery/history`) — used to live here too. Removed
// outright per direct user feedback ("not sure we need the 'from your
// group's past groceries' section... the 'from your household groceries'
// should just be your standard groceries"): the personal, individualized
// `HistoricalGroceryItem` catalog (surfaced on this same screen via
// `GroupSharedGroceryListView.householdGroceriesSection`) already covers
// the "bring something I usually get onto this list" job, so a second,
// group-shared catalog for the same purpose was redundant — same
// "removed the concept outright, not just its UI" reasoning as
// `GroupStapleItem` above. Also removed alongside this: the backend
// model/route/migration and every other iOS reference (`GroupSyncService`'s
// push/pull, `AccountsAPIClient.getGroupGroceryHistory`,
// `RemoteGroupGroceryHistoryEntry`) — see backend/README.md's "Group
// grocery list" section for the removal note.
