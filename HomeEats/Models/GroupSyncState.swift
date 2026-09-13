import Foundation

/// Local sync-tracking state for a group's shared meal-plan/grocery rows
/// (see `GroupPlannedMeal`, `GroupMealSuggestion`, `GroupSharedGroceryItem`,
/// and `GroupSyncService`'s own doc comment for the full push/pull/reconcile
/// design). Every locally-stored group row carries one of these, alongside
/// whatever wire fields it mirrors from the backend, so the sync engine can
/// tell "already matches the server" apart from "has a local edit still
/// waiting to be pushed" without a live network round-trip just to ask.
///
/// Deliberately state-based rather than timestamp/version-based conflict
/// resolution: the backend itself has no optimistic-concurrency version
/// field on any of these rows (see prisma/schema.prisma — `PlannedMeal`,
/// `MealSuggestion`, and `GroupGroceryItem` all lack one, and none of their
/// routes take an `If-Match`-style precondition), so a `PATCH`/`POST` from
/// this app always just overwrites whatever's there server-side, however
/// server-side request ordering happens to land — there is no richer
/// "reject a stale write" signal this client could even ask for. What this
/// state genuinely protects against, and fully solves on-device, is
/// something different: never letting a *pull* (fetching the server's
/// current state) clobber a local change that hasn't reached the server
/// yet. See `ReconciliationAction.decide` in `GroupSyncService.swift` for
/// the exact per-row rule this drives, and that file's own "Known
/// limitations" note for the one real conflict window this doesn't (and, in
/// the absence of a version field, can't fully) solve.
enum GroupSyncState: String, Codable {
    /// This row's local fields match the last known server state — a pull
    /// is always free to overwrite it with whatever the server says now,
    /// and a push has nothing to do for it.
    case synced
    /// Created locally, not yet pushed — no server id assigned yet (see the
    /// `id` doc comment on each local model below for how a not-yet-synced
    /// row is identified in the meantime). A pull must never delete this
    /// row just because the server doesn't know about it yet.
    case pendingCreate
    /// Exists on the server already, but something about it has changed
    /// locally since the last successful push/pull — a field edit for
    /// `GroupSharedGroceryItem`, or a vote toggle for `GroupMealSuggestion`
    /// (see that model's own doc comment: it's the only kind of "update" a
    /// suggestion can ever have pending, since none of its other fields can
    /// change after creation). A pull must not overwrite this row's
    /// locally-changed fields until the pending push actually succeeds.
    case pendingUpdate
    /// Deleted locally, not yet confirmed deleted on the server. A pull
    /// must not resurrect this row just because the server still lists it —
    /// that delete simply hasn't reached the server yet.
    case pendingDelete
}
