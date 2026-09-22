import Foundation
import SwiftData

/// The reconciliation decision for a single locally-known-or-not row,
/// identified by id, given its local sync state (or the fact that there's
/// no local row for that id at all) and whether the pull that's currently
/// running still includes it. Exposed standalone from the SwiftData-touching
/// pull/reconcile methods below — this is the actual conflict-resolution
/// rule this whole sync engine exists to get right, and keeping it a pure
/// function of two small enums (no `ModelContext`, no network) is what lets
/// it be unit tested directly, table-driven, with no SwiftData store or live
/// backend needed at all (see `GroupSyncReconciliationTests`).
enum ReconciliationAction: Equatable {
    /// Insert/overwrite the local row with the server's fields — either a
    /// fresh row the server has and this device doesn't yet, or an existing
    /// `.synced` row the server has since changed or re-affirmed.
    case upsertFromServer
    /// Leave the local row exactly as it is: it has a pending local change
    /// that hasn't been acknowledged yet, so whatever the pull says about
    /// this row (present or not) is stale from this device's point of view
    /// and must not be allowed to overwrite it.
    case keepLocal
    /// Remove the local row: it was `.synced` (no pending local change of
    /// any kind) but no longer appears in the pull, meaning someone else
    /// deleted it on the server since this device last synced.
    case deleteLocal

    /// - Parameters:
    ///   - localSyncState: The local row's `GroupSyncState`, or `nil` if
    ///     there's no local row for this id at all yet.
    ///   - presentInPull: Whether the just-completed `GET` for this group
    ///     still includes a row with this id.
    static func decide(localSyncState: GroupSyncState?, presentInPull: Bool) -> ReconciliationAction {
        switch (localSyncState, presentInPull) {
        case (nil, true):
            // No local row at all yet, the server has it -> bring it down.
            return .upsertFromServer
        case (nil, false):
            // Nothing local, nothing remote — there's genuinely nothing to
            // reconcile; this case isn't expected to actually be asked for
            // (callers only ever call this per-id for ids appearing on at
            // least one side), but answering "do nothing" is still correct
            // if it ever is.
            return .keepLocal
        case (.synced, true):
            // No pending local change -> the server's current view always
            // wins outright, matching or replacing this row's fields.
            return .upsertFromServer
        case (.synced, false):
            // No pending local change, and the server no longer has it ->
            // someone else deleted it since the last sync.
            return .deleteLocal
        case (.pendingCreate, _):
            // Not pushed yet, so the pull can't possibly know about it
            // under its eventual real id (it's still keyed by a local
            // placeholder) -> never touch it here; `push` is what clears
            // this state once the create actually lands.
            return .keepLocal
        case (.pendingUpdate, _):
            // A local edit (or, for a suggestion, a vote change) is still
            // waiting to be pushed -> don't let the pull stomp it, whether
            // or not the server's own copy of this row still exists at all.
            return .keepLocal
        case (.pendingDelete, _):
            // A local delete is still waiting to be pushed -> don't
            // resurrect this row just because the pull still lists it.
            return .keepLocal
        }
    }
}

/// The concurrent-edit-during-create-dispatch decision for a
/// `GroupSharedGroceryItem`'s `isChecked`/`orderIndex` fields — see the
/// `.pendingCreate` case of `GroupSyncService.pushGroceryItems` for the race
/// this exists to close (a local checkbox toggle or reorder, made at any
/// point before that row's create call has actually been acknowledged,
/// would otherwise be silently overwritten by the create response's values
/// once it comes back). A pure function, exposed standalone for the same
/// reason `ReconciliationAction.decide` is: unit-testable with no
/// `ModelContext` and no network at all (see `GroupGroceryItemCreateRaceTests`).
///
/// Compares the row's **current** value against the value the **create
/// response itself just returned** — not against a snapshot taken when the
/// create request was dispatched. That distinction matters: `POST
/// .../grocery` never accepts `isChecked` at all (see `CreateItemSchema` in
/// routes/groupGrocery.js — a freshly created row is always `isChecked:
/// false` server-side, no exceptions), so comparing "current" only against
/// "value at dispatch time" misses the very common case of a user checking
/// a brand-new item off (or reordering it) *before* its first sync ever
/// runs, not just during one already in flight — at dispatch time,
/// `dispatchedIsChecked` would already equal `currentIsChecked` (both
/// `true`, since the checkbox was tapped before this push started, not
/// during it), so a dispatch-time comparison sees no discrepancy and lets
/// `applyRemote` overwrite the checked-off state with the server's `false`
/// the moment the create response lands — a real, silent loss this
/// design once had. Comparing against what the response actually says
/// closes that gap uniformly, for both the "changed before dispatch" and
/// the "changed during flight" cases, since either way the server's
/// response is the one source of truth for "what the create call was even
/// capable of communicating."
enum GroceryCreateReconciliation {
    /// - Returns: `true` if the row's current value differs from what the
    ///   create response says — meaning the local value, not the server's
    ///   response, should win, and the row should be marked `.pendingUpdate`
    ///   (not `.synced`) so the corrected value still gets pushed via a
    ///   follow-up `PATCH`. `false` (the common case — nothing local ever
    ///   diverged from what got created) means the response is fully
    ///   authoritative.
    /// `currentQuantityCount`/`remoteQuantityCount` default to `1`/`1` (a
    /// no-op comparison) so every pre-existing call site — including this
    /// suite's own tests, written before `quantityCount` existed on either
    /// side of this comparison — keeps compiling and passing unchanged;
    /// `pushGroceryItems` below passes real values now that `POST
    /// .../grocery` accepts `quantityCount` too, same race as
    /// `isChecked`/`orderIndex` (a user bumping a brand-new item's count
    /// before its first sync ever completes).
    static func shouldPreserveLocalCheckedAndOrder(
        currentIsChecked: Bool, remoteIsChecked: Bool,
        currentOrderIndex: Double, remoteOrderIndex: Double,
        currentQuantityCount: Int = 1, remoteQuantityCount: Int = 1
    ) -> Bool {
        currentIsChecked != remoteIsChecked
            || currentOrderIndex != remoteOrderIndex
            || currentQuantityCount != remoteQuantityCount
    }
}

/// The "which direction do we actually send?" decision for a
/// `GroupMealSuggestion` sitting in `.pendingUpdate` (a local vote change
/// still waiting to be pushed — see that model's `syncState` doc comment).
/// Exposed standalone as a pure function, same reasoning as
/// `ReconciliationAction`/`GroceryCreateReconciliation` above: this is the
/// one piece of the vote-push path that's actually a judgment call (not just
/// "call the API with the obvious value"), and past bugs in this exact sync
/// engine have come from exactly this kind of decision living inline and
/// untested inside an `async` method instead (see this file's own "Known
/// limitations" note, and the create-race-condition history
/// `GroupGroceryItemCreateRaceTests` covers).
///
/// `POST .../vote` toggles-or-switches unconditionally rather than "set my
/// vote to X" (see that route's own doc comment in
/// routes/groupMealPlan.js): sending the same direction the server already
/// has for this caller retracts it, sending the other direction switches it.
/// That asymmetry is what makes a single, uniform rule possible here even
/// though any number of local vote changes (up, down, retract, up again, ...)
/// may have happened offline before this push ever runs:
///
/// - If `myVote` is non-nil, it's the caller's actual current target —
///   sending it always lands correctly, whether the server currently has no
///   vote from this caller (adds it) or the opposite one (switches it) —
///   the server's current state is EITHER of those, never already
///   `myVote` itself, since this is only ever called when
///   `myVote != lastKnownServerVote`.
/// - If `myVote` is `nil` (the caller's local changes net out to "no vote at
///   all"), there's nothing to "set" — the only way to reach that state is
///   to retract whatever the server currently has, i.e. send
///   `lastKnownServerVote` right back at it (same-direction-retracts).
///
/// So `myVote ?? lastKnownServerVote` is correct in both cases — no need to
/// separately track *which* directions were tapped along the way, only
/// where the caller's local state ended up versus what the server last
/// confirmed.
enum SuggestionVoteReconciliation {
    /// - Returns: the direction to send to `POST .../vote`, or `nil` if
    ///   there's genuinely nothing to push (`myVote == lastKnownServerVote`
    ///   — both `nil`, both `.up`, or both `.down`). Callers only ever
    ///   invoke this for a row already in `.pendingUpdate`, which guarantees
    ///   the two differ and this never actually returns `nil` in practice —
    ///   it's still handled explicitly (never force-unwrapped) so a future
    ///   change to that invariant fails safe instead of crashing.
    static func directionToPush(myVote: VoteDirection?, lastKnownServerVote: VoteDirection?) -> VoteDirection? {
        myVote ?? lastKnownServerVote
    }
}

/// Pushes local pending group meal-plan/grocery-list edits to the backend,
/// then pulls the server's current state back down and reconciles it into
/// the local SwiftData store — the offline-capable sync engine behind
/// `GroupSharedMealPlanView`/`GroupSharedGroceryListView`. A plain `enum`
/// namespace (no instance state of its own), mirroring `AccountsAPIClient`'s
/// own "stateless namespace" shape: every method here takes the `groupID`
/// and `ModelContext` it needs explicitly, since — unlike `AccountSession` —
/// there's nothing instance-specific for this to hold onto between calls.
///
/// **Design**: see `GroupSyncState`'s own doc comment for why conflict
/// resolution here is state-based (pending-wins-until-acknowledged) rather
/// than timestamp/version-based, and `ReconciliationAction` above for the
/// exact per-row decision table `pull` applies uniformly across all three
/// entity types (planned meals, suggestions, grocery items).
///
/// **Known limitations** (flagged plainly, not glossed over):
/// - **True concurrent-edit conflicts aren't detected, only ordered.** If
///   two devices both have a genuinely different pending change to the
///   *same* row — say, two members reorder the same category differently
///   while both offline — whichever device's push lands on the server
///   *last* simply overwrites the other's, silently, with no merge and no
///   error shown to either side; the loser only finds out on its next pull,
///   when the row just changes out from under it. This isn't a gap in this
///   client's logic so much as a ceiling imposed by the backend itself
///   having no version/`If-Match` field to detect the collision with in the
///   first place (see `GroupSyncState`'s doc comment) — a real fix would
///   need a backend schema change, out of scope for this iOS-only task.
/// - **A suggestion's vote can still race a fellow member's vote.**
///   `POST .../vote` toggles/switches unconditionally rather than
///   "set my vote to X, whatever it currently is" — this client compensates
///   for *its own* multiple-changes-while-offline case by always deriving
///   the direction it sends from `myVote ?? lastKnownServerVote` (see
///   `GroupMealSuggestion.lastKnownServerVote`'s doc comment), but if the
///   caller's own pending vote change sits queued for a while (offline) and,
///   in the meantime, a push from a *different* device changes that same
///   suggestion's counts, this device's eventual push still lands correctly
///   for the caller's own vote (voting is per-user, keyed by
///   `@@unique([suggestionId, userId])` — see that model's doc comment in
///   prisma/schema.prisma) — so this particular case is actually fine; it's
///   called out here only because it's the one place a toggle-style endpoint
///   could plausibly have been a problem, and it's worth being explicit
///   that it isn't.
/// - **Changing your vote on your own suggestion before it's ever synced is
///   a no-op until the sync happens.** `GroupMealSuggestion.voteLocally(_:)`
///   deliberately never promotes a still-`.pendingCreate` row to
///   `.pendingUpdate` (see that method's own doc comment for the stuck-row
///   bug that would otherwise cause) — the practical effect is that
///   proposing a suggestion and immediately changing your own default
///   upvote (retracting it, or switching it to a downvote), all before the
///   next sync, has that vote silently reset back to the auto-applied
///   upvote once the create succeeds (the backend always auto-votes the
///   proposer up on creation). One extra tap after syncing fixes it; a real
///   fix would mean queuing a separate "vote intent" ahead of a still-
///   unconfirmed create, which isn't worth the complexity for what's a
///   narrow, low-stakes edge case.
/// - **`adopt`/`accept` are immediate/online-only, not queued.** Turning a
///   suggestion into a decided meal, or a suggested grocery item into a
///   real one, is a compound server-side transaction with no sensible
///   local-only optimistic equivalent — seeing "Use This" succeed locally
///   before the transaction that makes it real has actually run would be
///   actively misleading. Both are simply disabled in the UI while offline
///   instead (see each view's own `isOffline`-gated actions) rather than
///   queued for later.
@MainActor
enum GroupSyncService {

    // MARK: - Entry point

    /// Runs a full push-then-pull-then-reconcile cycle for one group's
    /// shared meal plan AND grocery list together — both new screens
    /// trigger this exact same call (on appearance, on pull-to-refresh, and
    /// from a light periodic timer while on-screen; see each view's own
    /// `.task`/`.refreshable` wiring) rather than exposing separate
    /// meal-plan-only/grocery-only entry points that could drift out of
    /// sync with each other's timing for no real benefit. Never throws:
    /// every failure (no network, a `403` because the caller's role changed
    /// mid-session, a decode mismatch, ...) is caught and folded into the
    /// returned `SyncOutcome` instead, so a failed sync can never crash the
    /// caller or force it into its own try/catch — the whole point of
    /// local-first is that a sync failure is just "try again later," never
    /// a hard error the UI has to handle specially, and local reads/writes
    /// must keep working regardless of whether this succeeds.
    ///
    /// **Single-flight per `groupID`**: every local write in the grocery/
    /// meal-plan screens fires its own untracked `Task { await
    /// GroupSyncService.sync(...) }` on top of the 25s periodic loop and
    /// `.refreshable` — with no coordination between them, two of those
    /// calls overlapping (trivial with drag-and-drop, which can trigger
    /// several moves in quick succession) each independently `fetch()` the
    /// same still-`.pendingCreate` row before either's `POST` response
    /// lands, so both push it — the second response's `applyRemote`
    /// overwrites `row.id` out from under the first, and the next pull
    /// re-inserts the now-untracked first server row as a "new" local one:
    /// a visible duplicate. A `groupID`-keyed in-flight `Task` closes this
    /// at the entry point rather than in every caller: a `sync` call for a
    /// group that's already mid-cycle awaits and returns that same task's
    /// result instead of starting a second, overlapping one — every caller
    /// still gets a `SyncOutcome` reflecting the most recent local state by
    /// the time it resolves, since nothing here returns early or drops a
    /// call, it only coalesces genuinely-concurrent ones.
    private static var inFlightSyncs: [String: Task<SyncOutcome, Never>] = [:]

    static func sync(groupID: String, modelContext: ModelContext) async -> SyncOutcome {
        if let existing = inFlightSyncs[groupID] {
            return await existing.value
        }
        let task = Task<SyncOutcome, Never> {
            let pushSucceeded = await push(groupID: groupID, modelContext: modelContext)
            let pullSucceeded = await pull(groupID: groupID, modelContext: modelContext)
            return SyncOutcome(pushSucceeded: pushSucceeded, pullSucceeded: pullSucceeded)
        }
        inFlightSyncs[groupID] = task
        let outcome = await task.value
        inFlightSyncs[groupID] = nil
        return outcome
    }

    struct SyncOutcome {
        let pushSucceeded: Bool
        let pullSucceeded: Bool
        /// Whether this cycle fully caught the local store up with the
        /// server — used to drive the "not synced yet"/offline indicator
        /// the new screens show; a caller doesn't need to separately
        /// re-query every pending row just to decide whether to show it
        /// (though the screens also check for pending rows directly, since
        /// a *stale* outcome — from before the screen's most recent local
        /// edit — shouldn't report as synced either; see each view's
        /// `hasPendingChanges` computed property).
        var isFullySynced: Bool { pushSucceeded && pullSucceeded }
    }

    // MARK: - Push

    private static func push(groupID: String, modelContext: ModelContext) async -> Bool {
        var allSucceeded = true
        allSucceeded = await pushPlannedMeals(groupID: groupID, modelContext: modelContext) && allSucceeded
        allSucceeded = await pushSuggestions(groupID: groupID, modelContext: modelContext) && allSucceeded
        allSucceeded = await pushGroceryItems(groupID: groupID, modelContext: modelContext) && allSucceeded
        // Phase 4 — "My Layout" aisles. A former sibling call here,
        // `pushStaples`, was removed along with the rest of the standing
        // "staples" template-list feature — see `GroupStoreAisle`'s doc
        // comment in HomeEats/Models/GroupGroceryLayout.swift for the
        // removal note.
        allSucceeded = await pushAisles(groupID: groupID, modelContext: modelContext) && allSucceeded
        try? modelContext.save()
        return allSucceeded
    }

    private static func localPlannedMeals(groupID: String, modelContext: ModelContext) -> [GroupPlannedMeal] {
        // Fetched unfiltered-by-anything-but-groupID and filtered further in
        // Swift, not via `#Predicate` on `syncState`/other enum fields —
        // matching the established caution elsewhere in this codebase (see
        // `SampleDataSeeder.seedLibraryRecipesIfNeeded`'s own comment on
        // custom-enum `#Predicate` filtering being unreliable on early iOS
        // 17 SwiftData) rather than risking silently-wrong results for a
        // dataset that's household-sized either way.
        let descriptor = FetchDescriptor<GroupPlannedMeal>(predicate: #Predicate { $0.groupID == groupID })
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    private static func pushPlannedMeals(groupID: String, modelContext: ModelContext) async -> Bool {
        var allOK = true
        for row in localPlannedMeals(groupID: groupID, modelContext: modelContext) {
            switch row.syncState {
            case .synced, .pendingUpdate:
                // No update path exists for a decided meal on the backend
                // (see `GroupPlannedMeal.syncState`'s own doc comment) —
                // nothing to push for either state.
                continue
            case .pendingCreate:
                do {
                    let created: RemotePlannedMeal
                    if let recipeID = row.recipeID {
                        created = try await AccountsAPIClient.decideGroupMeal(
                            groupID: groupID, date: row.date, slot: row.slot, recipeID: recipeID
                        )
                    } else if let restaurantName = row.restaurantName {
                        created = try await AccountsAPIClient.decideGroupMeal(
                            groupID: groupID, date: row.date, slot: row.slot,
                            restaurantName: restaurantName, isOrderIn: row.isOrderIn
                        )
                    } else {
                        // Malformed row (neither set) — nothing sensible to
                        // push. Leave it for a human to notice via the
                        // "not synced" indicator rather than silently
                        // discarding it.
                        allOK = false
                        continue
                    }
                    row.id = created.id
                    row.decidedByUserID = created.decidedByUserID
                    row.decidedByDisplayName = created.decidedByDisplayName
                    row.decidedAt = created.decidedAt
                    row.serverUpdatedAt = created.decidedAt
                    row.syncState = .synced
                } catch {
                    allOK = false
                }
            case .pendingDelete:
                if row.isLocalPlaceholderID {
                    // Never reached the server in the first place (created
                    // and deleted again before ever syncing) — nothing to
                    // tell it, just drop the row.
                    modelContext.delete(row)
                    continue
                }
                do {
                    try await AccountsAPIClient.deleteGroupPlannedMeal(groupID: groupID, id: row.id)
                    modelContext.delete(row)
                } catch {
                    allOK = false
                }
            }
        }
        return allOK
    }

    private static func localSuggestions(groupID: String, modelContext: ModelContext) -> [GroupMealSuggestion] {
        let descriptor = FetchDescriptor<GroupMealSuggestion>(predicate: #Predicate { $0.groupID == groupID })
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    private static func pushSuggestions(groupID: String, modelContext: ModelContext) async -> Bool {
        var allOK = true
        for row in localSuggestions(groupID: groupID, modelContext: modelContext) {
            switch row.syncState {
            case .synced:
                continue
            case .pendingCreate:
                do {
                    let created: RemoteMealSuggestion
                    if let recipeID = row.recipeID {
                        created = try await AccountsAPIClient.suggestGroupMeal(
                            groupID: groupID, date: row.date, slot: row.slot, recipeID: recipeID
                        )
                    } else if let restaurantName = row.restaurantName {
                        created = try await AccountsAPIClient.suggestGroupMeal(
                            groupID: groupID, date: row.date, slot: row.slot,
                            restaurantName: restaurantName, isOrderIn: row.isOrderIn
                        )
                    } else {
                        allOK = false
                        continue
                    }
                    row.id = created.id
                    row.proposedByDisplayName = created.proposedByDisplayName
                    row.createdAt = created.createdAt
                    row.myVote = created.myVote
                    row.lastKnownServerVote = created.myVote
                    row.upvoteCount = created.upvoteCount
                    row.downvoteCount = created.downvoteCount
                    row.voters = created.voters
                    row.syncState = .synced
                } catch {
                    allOK = false
                }
            case .pendingUpdate:
                // Only a vote change can ever put a suggestion in this
                // state (see `GroupMealSuggestion.syncState`'s doc comment)
                // — a brand-new, not-yet-pushed suggestion stays
                // `.pendingCreate` until its first push succeeds, never
                // also `.pendingUpdate` at the same time, so `row.id` here
                // is always a real server id already.
                //
                // The direction actually sent is derived, not just `myVote`
                // — see `SuggestionVoteReconciliation.directionToPush`'s own
                // doc comment (above, in this file) for why that derivation
                // is correct regardless of how many local vote changes
                // (switch, retract, switch again, ...) led up to this one
                // push.
                guard let direction = SuggestionVoteReconciliation.directionToPush(
                    myVote: row.myVote, lastKnownServerVote: row.lastKnownServerVote
                ) else {
                    // Can't happen given `.pendingUpdate`'s invariant (this
                    // state means `myVote != lastKnownServerVote`, so at
                    // least one must be non-nil), but fail loudly-but-safely
                    // (skip, don't crash) rather than force-unwrapping if
                    // that invariant is ever violated by a future change.
                    allOK = false
                    continue
                }
                do {
                    let updated = try await AccountsAPIClient.voteOnGroupMealSuggestion(
                        groupID: groupID, suggestionID: row.id, direction: direction
                    )
                    row.myVote = updated.myVote
                    row.lastKnownServerVote = updated.myVote
                    row.upvoteCount = updated.upvoteCount
                    row.downvoteCount = updated.downvoteCount
                    row.voters = updated.voters
                    row.syncState = .synced
                } catch {
                    allOK = false
                }
            case .pendingDelete:
                if row.isLocalPlaceholderID {
                    modelContext.delete(row)
                    continue
                }
                do {
                    try await AccountsAPIClient.deleteGroupMealSuggestion(groupID: groupID, suggestionID: row.id)
                    modelContext.delete(row)
                } catch {
                    allOK = false
                }
            }
        }
        return allOK
    }

    private static func localGroceryItems(groupID: String, modelContext: ModelContext) -> [GroupSharedGroceryItem] {
        let descriptor = FetchDescriptor<GroupSharedGroceryItem>(predicate: #Predicate { $0.groupID == groupID })
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    private static func pushGroceryItems(groupID: String, modelContext: ModelContext) async -> Bool {
        var allOK = true
        for row in localGroceryItems(groupID: groupID, modelContext: modelContext) {
            switch row.syncState {
            case .synced:
                continue
            case .pendingCreate:
                // `POST .../grocery` never accepts `isChecked` or
                // `aisleId`/`aisleManuallySet` at all (see `CreateItemSchema`
                // in routes/groupGrocery.js) — a freshly created row is
                // always `isChecked: false`, `aisleId: null`,
                // `aisleManuallySet: false` server-side, unconditionally. So
                // rather than snapshotting this row's fields at dispatch
                // time and comparing against that snapshot after the
                // `await` (which would only catch a concurrent edit made
                // *during* the network round-trip, and miss the equally
                // real case of the user checking a brand-new item off, or
                // placing it in an aisle, *before* its first sync ever
                // runs — see `GroceryCreateReconciliation`'s own doc comment
                // for the data-loss bug that blind spot caused), this
                // compares the row's CURRENT value directly against what the
                // create response itself says. Either way — changed before
                // dispatch or during flight — the response is the one source
                // of truth for what the create call was even capable of
                // communicating, so a mismatch against it always means "the
                // local value must win and still needs a follow-up PATCH."
                do {
                    let created = try await AccountsAPIClient.createGroupGroceryItem(
                        groupID: groupID, name: row.name, category: row.category, section: row.section,
                        quantityText: row.quantityText, quantityCount: row.quantityCount, orderIndex: row.orderIndex
                    )
                    let checkedOrOrderDiffersFromResponse = GroceryCreateReconciliation.shouldPreserveLocalCheckedAndOrder(
                        currentIsChecked: row.isChecked, remoteIsChecked: created.isChecked,
                        currentOrderIndex: row.orderIndex, remoteOrderIndex: created.orderIndex,
                        currentQuantityCount: row.quantityCount, remoteQuantityCount: created.quantityCount
                    )
                    let aisleDiffersFromResponse = row.aisleID != created.aisleID
                        || row.aisleManuallySet != created.aisleManuallySet
                    applyRemote(
                        created, to: row,
                        preserveLocalCheckedAndOrder: checkedOrOrderDiffersFromResponse,
                        preserveLocalAisle: aisleDiffersFromResponse
                    )
                } catch {
                    allOK = false
                }
            case .pendingUpdate:
                // `isChecked`/`orderIndex` are always sent (see
                // `GroupSharedGroceryItem.syncState`'s doc comment for why a
                // manager's name/category/quantityText/section edit is
                // handled by `editGroceryItem` below instead, never by
                // marking a row `.pendingUpdate`). `aisleId` is sent ONLY
                // when `aisleManuallySet` is true — see
                // `updateGroupGroceryItem`'s own doc comment on `aisleID`:
                // sending the key at all (even explicit `null`) permanently
                // marks the item as manually placed server-side, so a row
                // that was only marked `.pendingUpdate` for an unrelated
                // checkbox/reorder change must never send it by accident.
                // Resending an already-`true` `aisleManuallySet`'s current
                // `aisleID` on every subsequent update (even one that didn't
                // touch placement) is deliberately idempotent-safe — same
                // value in, same value out, no harm beyond one extra field
                // in the request body.
                do {
                    let updated: RemoteGroupGroceryItem
                    if row.aisleManuallySet {
                        updated = try await AccountsAPIClient.updateGroupGroceryItem(
                            groupID: groupID, id: row.id, isChecked: row.isChecked, orderIndex: row.orderIndex,
                            quantityCount: row.quantityCount, aisleID: .set(row.aisleID)
                        )
                    } else {
                        updated = try await AccountsAPIClient.updateGroupGroceryItem(
                            groupID: groupID, id: row.id, isChecked: row.isChecked, orderIndex: row.orderIndex,
                            quantityCount: row.quantityCount
                        )
                    }
                    applyRemote(updated, to: row)
                } catch {
                    allOK = false
                }
            case .pendingDelete:
                if row.isLocalPlaceholderID {
                    modelContext.delete(row)
                    continue
                }
                do {
                    try await AccountsAPIClient.deleteGroupGroceryItem(groupID: groupID, id: row.id)
                    modelContext.delete(row)
                } catch {
                    allOK = false
                }
            }
        }
        return allOK
    }

    /// Applies a server row's fields onto a local `GroupSharedGroceryItem`.
    /// `preserveLocalCheckedAndOrder` (see the `.pendingCreate` case in
    /// `pushGroceryItems` above, and `GroceryCreateReconciliation` below,
    /// for the one caller that ever passes `true`) skips overwriting
    /// `isChecked`/`orderIndex`/`quantityCount` from `remote` and marks the row
    /// `.pendingUpdate` instead of `.synced`, so a local change made either
    /// before this row's create call was ever dispatched, or while it was
    /// still in flight, isn't clobbered — the row's next push then sends
    /// those corrected values via the normal `updateGroupGroceryItem` path.
    /// `preserveLocalAisle` (Phase 4) is the "My Layout" placement
    /// counterpart of the same idea — same race, same fix, see that same
    /// `.pendingCreate` case for the one caller that ever passes it `true`.
    /// Every other caller (a `.pendingUpdate` push's own response, and
    /// `reconcileGroceryItems`'s pull-side upsert, neither of which race a
    /// create) leaves both flags at their default `false`, i.e. today's
    /// existing "the response is authoritative" behavior, unchanged.
    ///
    /// Not `private`, and explicitly `nonisolated` — unlike every other
    /// helper in this file, this is called directly by `HomeEatsTests` (see
    /// `GroupGroceryItemCreateRaceTests`), from plain synchronous test
    /// methods with no actor context of their own, so the exact state
    /// transition a create response applies can be exercised without a live
    /// network call or a `ModelContext` — same reasoning as
    /// `ReconciliationAction.decide` being a standalone testable function.
    /// Safe to opt out of this enum's `@MainActor` isolation here because
    /// this method only ever mutates the single `row` instance it's handed
    /// — it touches no other actor-isolated state of its own.
    nonisolated static func applyRemote(
        _ remote: RemoteGroupGroceryItem, to row: GroupSharedGroceryItem,
        preserveLocalCheckedAndOrder: Bool = false,
        preserveLocalAisle: Bool = false
    ) {
        row.id = remote.id
        row.name = remote.name
        row.category = remote.category.localCategory
        row.section = remote.section
        row.quantityText = remote.quantityText
        if !preserveLocalCheckedAndOrder {
            row.isChecked = remote.isChecked
            row.orderIndex = remote.orderIndex
            row.quantityCount = remote.quantityCount
        }
        if !preserveLocalAisle {
            row.aisleID = remote.aisleID
            row.aisleManuallySet = remote.aisleManuallySet
        }
        row.addedByUserID = remote.addedByUserID
        row.serverUpdatedAt = remote.updatedAt
        row.syncState = (preserveLocalCheckedAndOrder || preserveLocalAisle) ? .pendingUpdate : .synced
    }

    // MARK: - Pull + reconcile

    /// Fetches the group's full current server state and reconciles it into
    /// the local store. Returns `false` (touching nothing locally) the
    /// moment either network call fails — a half-applied pull (meal plan
    /// refreshed, grocery list not, or vice versa) would be a worse,
    /// harder-to-reason-about state than simply leaving both exactly as
    /// they were until a pull can fully succeed.
    private static func pull(groupID: String, modelContext: ModelContext) async -> Bool {
        async let mealPlanResult = try? AccountsAPIClient.getGroupMealPlan(groupID: groupID)
        async let groceryResult = try? AccountsAPIClient.getGroupGroceryList(groupID: groupID)
        // Phase 4 — "My Layout" aisles. Fetched every sync cycle (not only
        // when its screen happens to be on screen), same "small,
        // household-scale, low-traffic" reasoning the rest of this file's
        // periodic-resync design already accepts — and load-bearing:
        // `getGroupGroceryAisles` is also what lazily seeds a group's ten
        // starter aisles the first time it's ever called (see that method's
        // own doc comment) — calling it here, on every sync, means those
        // starter aisles are already seeded and synced locally well before
        // someone first switches "My Layout" on, rather than "My Layout"
        // opening to an empty/all-Unsorted list for the one sync cycle it
        // would otherwise take to catch up. Two former sibling fetches used
        // to be here: `getGroupGroceryStaples` (the standing "staples"
        // template-list feature) and `getGroupGroceryHistory` (the
        // group-shared "past groceries" catalog) — both removed outright per
        // direct user feedback; see `GroupStoreAisle`'s doc comment in
        // HomeEats/Models/GroupGroceryLayout.swift for both removal notes.
        async let aislesResult = try? AccountsAPIClient.getGroupGroceryAisles(groupID: groupID)
        let (mealPlan, grocery, aisles) = await (mealPlanResult, groceryResult, aislesResult)
        guard let mealPlan, let grocery, let aisles else { return false }

        await reconcilePlannedMeals(remote: mealPlan.plannedMeals, groupID: groupID, modelContext: modelContext)
        await reconcileSuggestions(remote: mealPlan.suggestions, groupID: groupID, modelContext: modelContext)
        reconcileGroceryItems(remote: grocery.items, groupID: groupID, modelContext: modelContext)
        reconcileAisles(remote: aisles.aisles, groupID: groupID, modelContext: modelContext)
        try? modelContext.save()
        return true
    }

    private static func reconcilePlannedMeals(remote: [RemotePlannedMeal], groupID: String, modelContext: ModelContext) async {
        let localRows = localPlannedMeals(groupID: groupID, modelContext: modelContext)
        var localByID: [String: GroupPlannedMeal] = [:]
        for row in localRows where !row.isLocalPlaceholderID { localByID[row.id] = row }
        let remoteIDs = Set(remote.map(\.id))

        for remoteMeal in remote {
            let existing = localByID[remoteMeal.id]
            guard ReconciliationAction.decide(localSyncState: existing?.syncState, presentInPull: true) == .upsertFromServer else { continue }

            let title: String?
            if let recipeID = remoteMeal.recipeID {
                // Not `existing?.cachedRecipeTitle ?? (await resolveRecipeTitle(...))` —
                // `??`'s right-hand side is an `@autoclosure`, which doesn't
                // support `await` inside it (a real compiler error, not a
                // style choice); spelling this out as an if/else sidesteps
                // the autoclosure entirely.
                if let cached = existing?.cachedRecipeTitle {
                    title = cached
                } else {
                    title = await resolveRecipeTitle(recipeID: recipeID, modelContext: modelContext)
                }
            } else {
                title = nil
            }

            if let existing {
                existing.date = GroupPlannedMeal.normalize(remoteMeal.date)
                existing.slot = remoteMeal.slot.localSlot
                existing.recipeID = remoteMeal.recipeID
                existing.cachedRecipeTitle = title
                existing.restaurantName = remoteMeal.restaurantName
                existing.isOrderIn = remoteMeal.isOrderIn
                existing.decidedByUserID = remoteMeal.decidedByUserID
                existing.decidedByDisplayName = remoteMeal.decidedByDisplayName
                existing.decidedAt = remoteMeal.decidedAt
                existing.syncState = .synced
                existing.serverUpdatedAt = remoteMeal.decidedAt
            } else {
                modelContext.insert(GroupPlannedMeal(
                    id: remoteMeal.id, groupID: groupID, date: remoteMeal.date, slot: remoteMeal.slot.localSlot,
                    recipeID: remoteMeal.recipeID, cachedRecipeTitle: title, restaurantName: remoteMeal.restaurantName,
                    isOrderIn: remoteMeal.isOrderIn, decidedByUserID: remoteMeal.decidedByUserID,
                    decidedByDisplayName: remoteMeal.decidedByDisplayName, decidedAt: remoteMeal.decidedAt,
                    syncState: .synced, serverUpdatedAt: remoteMeal.decidedAt
                ))
            }
        }

        for row in localRows where !row.isLocalPlaceholderID && !remoteIDs.contains(row.id) {
            if ReconciliationAction.decide(localSyncState: row.syncState, presentInPull: false) == .deleteLocal {
                modelContext.delete(row)
            }
        }
    }

    private static func reconcileSuggestions(remote: [RemoteMealSuggestion], groupID: String, modelContext: ModelContext) async {
        let localRows = localSuggestions(groupID: groupID, modelContext: modelContext)
        var localByID: [String: GroupMealSuggestion] = [:]
        for row in localRows where !row.isLocalPlaceholderID { localByID[row.id] = row }
        let remoteIDs = Set(remote.map(\.id))

        for remoteSuggestion in remote {
            let existing = localByID[remoteSuggestion.id]
            guard ReconciliationAction.decide(localSyncState: existing?.syncState, presentInPull: true) == .upsertFromServer else { continue }

            let title: String?
            if let recipeID = remoteSuggestion.recipeID {
                // See the identical pattern in reconcilePlannedMeals above —
                // `??`'s autoclosure doesn't support `await`.
                if let cached = existing?.cachedRecipeTitle {
                    title = cached
                } else {
                    title = await resolveRecipeTitle(recipeID: recipeID, modelContext: modelContext)
                }
            } else {
                title = nil
            }

            if let existing {
                existing.date = GroupPlannedMeal.normalize(remoteSuggestion.date)
                existing.slot = remoteSuggestion.slot.localSlot
                existing.recipeID = remoteSuggestion.recipeID
                existing.cachedRecipeTitle = title
                existing.restaurantName = remoteSuggestion.restaurantName
                existing.isOrderIn = remoteSuggestion.isOrderIn
                existing.proposedByUserID = remoteSuggestion.proposedByUserID
                existing.proposedByDisplayName = remoteSuggestion.proposedByDisplayName
                existing.createdAt = remoteSuggestion.createdAt
                existing.myVote = remoteSuggestion.myVote
                existing.lastKnownServerVote = remoteSuggestion.myVote
                existing.upvoteCount = remoteSuggestion.upvoteCount
                existing.downvoteCount = remoteSuggestion.downvoteCount
                existing.voters = remoteSuggestion.voters
                existing.syncState = .synced
            } else {
                modelContext.insert(GroupMealSuggestion(
                    id: remoteSuggestion.id, groupID: groupID, date: remoteSuggestion.date, slot: remoteSuggestion.slot.localSlot,
                    recipeID: remoteSuggestion.recipeID, cachedRecipeTitle: title, restaurantName: remoteSuggestion.restaurantName,
                    isOrderIn: remoteSuggestion.isOrderIn, proposedByUserID: remoteSuggestion.proposedByUserID,
                    proposedByDisplayName: remoteSuggestion.proposedByDisplayName,
                    createdAt: remoteSuggestion.createdAt, myVote: remoteSuggestion.myVote,
                    upvoteCount: remoteSuggestion.upvoteCount, downvoteCount: remoteSuggestion.downvoteCount,
                    voters: remoteSuggestion.voters, lastKnownServerVote: remoteSuggestion.myVote, syncState: .synced
                ))
            }
        }

        for row in localRows where !row.isLocalPlaceholderID && !remoteIDs.contains(row.id) {
            if ReconciliationAction.decide(localSyncState: row.syncState, presentInPull: false) == .deleteLocal {
                modelContext.delete(row)
            }
        }
    }

    private static func reconcileGroceryItems(remote: [RemoteGroupGroceryItem], groupID: String, modelContext: ModelContext) {
        let localRows = localGroceryItems(groupID: groupID, modelContext: modelContext)
        var localByID: [String: GroupSharedGroceryItem] = [:]
        for row in localRows where !row.isLocalPlaceholderID { localByID[row.id] = row }
        let remoteIDs = Set(remote.map(\.id))

        for remoteItem in remote {
            let existing = localByID[remoteItem.id]
            guard ReconciliationAction.decide(localSyncState: existing?.syncState, presentInPull: true) == .upsertFromServer else { continue }

            if let existing {
                applyRemote(remoteItem, to: existing)
            } else {
                let item = GroupSharedGroceryItem(
                    id: remoteItem.id, groupID: groupID, name: remoteItem.name, category: remoteItem.category.localCategory,
                    section: remoteItem.section, quantityText: remoteItem.quantityText, quantityCount: remoteItem.quantityCount,
                    isChecked: remoteItem.isChecked,
                    orderIndex: remoteItem.orderIndex, aisleID: remoteItem.aisleID, aisleManuallySet: remoteItem.aisleManuallySet,
                    addedByUserID: remoteItem.addedByUserID, createdAt: remoteItem.createdAt,
                    syncState: .synced, serverUpdatedAt: remoteItem.updatedAt
                )
                modelContext.insert(item)
            }
        }

        for row in localRows where !row.isLocalPlaceholderID && !remoteIDs.contains(row.id) {
            if ReconciliationAction.decide(localSyncState: row.syncState, presentInPull: false) == .deleteLocal {
                modelContext.delete(row)
            }
        }
    }

    // MARK: - Push + pull + reconcile: "My Layout" aisles (Phase 4)

    private static func localAisles(groupID: String, modelContext: ModelContext) -> [GroupStoreAisle] {
        let descriptor = FetchDescriptor<GroupStoreAisle>(predicate: #Predicate { $0.groupID == groupID })
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    private static func pushAisles(groupID: String, modelContext: ModelContext) async -> Bool {
        var allOK = true
        for row in localAisles(groupID: groupID, modelContext: modelContext) {
            switch row.syncState {
            case .synced:
                continue
            case .pendingCreate:
                // `POST .../grocery/aisles` never accepts a `sortIndex` at
                // all (see routes/groupGroceryAisles.js — a new aisle always
                // lands at the end of the group's current walking order
                // server-side), so a local reorder that already moved this
                // still-unsynced aisle to a different position — whether
                // that happened before this create was ever dispatched, or
                // while it was still in flight — can't be communicated by
                // this call, and would otherwise be silently reset back to
                // "appended at the end" the moment the response applies.
                // Same race class, same fix, as `GroceryCreateReconciliation`
                // (see that type's own doc comment for the full reasoning,
                // including why comparing against the response itself,
                // rather than a dispatch-time snapshot, is what catches both
                // halves of this uniformly).
                do {
                    let created = try await AccountsAPIClient.createGroupGroceryAisle(groupID: groupID, name: row.name)
                    let sortIndexDiffersFromResponse = row.sortIndex != created.sortIndex
                    applyRemote(created, to: row, preserveLocalSortIndex: sortIndexDiffersFromResponse)
                } catch {
                    allOK = false
                }
            case .pendingUpdate:
                // Always sends both `name` and `sortIndex` together, same
                // "no per-field-dirty-tracking, just resend the row's whole
                // current state" simplicity as `pushGroceryItems`'s
                // `isChecked`/`orderIndex` pair — harmless to resend a field
                // that didn't actually change, since it's still this row's
                // own correct current value either way.
                do {
                    let updated = try await AccountsAPIClient.updateGroupGroceryAisle(
                        groupID: groupID, id: row.id, name: row.name, sortIndex: row.sortIndex
                    )
                    applyRemote(updated, to: row)
                } catch {
                    allOK = false
                }
            case .pendingDelete:
                if row.isLocalPlaceholderID {
                    modelContext.delete(row)
                    continue
                }
                do {
                    try await AccountsAPIClient.deleteGroupGroceryAisle(groupID: groupID, id: row.id)
                    modelContext.delete(row)
                } catch {
                    allOK = false
                }
            }
        }
        return allOK
    }

    /// Not `private`, and explicitly `nonisolated` — same "`HomeEatsTests`
    /// calls this directly, from a plain synchronous test method with no
    /// actor context of its own" reasoning as the grocery-item `applyRemote`
    /// overload above (see its own doc comment). `preserveLocalSortIndex`
    /// (see the `.pendingCreate` case in `pushAisles` above for the one
    /// caller that ever passes `true`) is this model's counterpart of that
    /// overload's `preserveLocalCheckedAndOrder` — skips overwriting
    /// `sortIndex` from `remote` and marks the row `.pendingUpdate` instead
    /// of `.synced`, so a reorder this row's own create call couldn't
    /// possibly have communicated isn't clobbered; the row's next push then
    /// sends the corrected value via the normal `updateGroupGroceryAisle`
    /// path. Every other caller (a `.pendingUpdate` push's own response, and
    /// `reconcileAisles`'s pull-side upsert) leaves it at its default
    /// `false`, i.e. today's existing "the response is authoritative"
    /// behavior, unchanged. Safe to opt out of this enum's `@MainActor`
    /// isolation for the same reason as the grocery-item overload above: it
    /// only ever mutates the single `row` instance it's handed.
    nonisolated static func applyRemote(
        _ remote: RemoteGroupStoreAisle, to row: GroupStoreAisle, preserveLocalSortIndex: Bool = false
    ) {
        row.id = remote.id
        row.name = remote.name
        if !preserveLocalSortIndex {
            row.sortIndex = remote.sortIndex
        }
        row.linkedCategory = remote.linkedCategory?.localCategory
        row.syncState = preserveLocalSortIndex ? .pendingUpdate : .synced
    }

    private static func reconcileAisles(remote: [RemoteGroupStoreAisle], groupID: String, modelContext: ModelContext) {
        let localRows = localAisles(groupID: groupID, modelContext: modelContext)
        var localByID: [String: GroupStoreAisle] = [:]
        for row in localRows where !row.isLocalPlaceholderID { localByID[row.id] = row }
        let remoteIDs = Set(remote.map(\.id))

        for remoteAisle in remote {
            let existing = localByID[remoteAisle.id]
            guard ReconciliationAction.decide(localSyncState: existing?.syncState, presentInPull: true) == .upsertFromServer else { continue }

            if let existing {
                applyRemote(remoteAisle, to: existing)
            } else {
                modelContext.insert(GroupStoreAisle(
                    id: remoteAisle.id, groupID: groupID, name: remoteAisle.name, sortIndex: remoteAisle.sortIndex,
                    linkedCategory: remoteAisle.linkedCategory?.localCategory, createdAt: remoteAisle.createdAt,
                    syncState: .synced
                ))
            }
        }

        for row in localRows where !row.isLocalPlaceholderID && !remoteIDs.contains(row.id) {
            if ReconciliationAction.decide(localSyncState: row.syncState, presentInPull: false) == .deleteLocal {
                modelContext.delete(row)
            }
        }
    }

    // (Two former sibling sections lived here too: "Push + pull + reconcile:
    // staples", the sync half of the group-scoped standing "staples"
    // template-list feature, and "Pull + reconcile: grocery history", the
    // sync half of the group-shared "past groceries" catalog — both removed
    // outright per direct user feedback. See `GroupStoreAisle`'s doc
    // comment in HomeEats/Models/GroupGroceryLayout.swift for both removal
    // notes.)

    // MARK: - Recipe title resolution

    /// Resolves a display title for a group-planned/suggested meal's
    /// `recipeID` — free (no network) when the caller already has that
    /// exact recipe saved locally (a `Recipe` row with a matching
    /// `backendRecipeID`, e.g. from the recipe-sharing feature), otherwise a
    /// single `GET /recipe-library/:id` call. Callers cache the result into
    /// `cachedRecipeTitle` themselves (see `reconcilePlannedMeals`/
    /// `reconcileSuggestions` above, which only call this when
    /// `existing?.cachedRecipeTitle` is `nil`) so this only ever runs once
    /// per recipe per row, not on every sync. Returns `nil` (never throws)
    /// on any failure — offline, a deleted/inaccessible recipe, ... — the
    /// caller's `displayTitle` falls back to a generic placeholder rather
    /// than blocking the rest of the pull on one recipe's title.
    private static func resolveRecipeTitle(recipeID: String, modelContext: ModelContext) async -> String? {
        // Compared as `Optional == Optional` (both sides explicitly
        // `String?`), not `Optional == String` — `#Predicate` builds a
        // typed expression tree at compile time rather than going through
        // ordinary implicit-optional-promotion type-checking the way a
        // plain `if` condition would, so this stays deliberately
        // unambiguous rather than relying on that promotion happening
        // inside the macro.
        let targetRecipeID: String? = recipeID
        var descriptor = FetchDescriptor<Recipe>(predicate: #Predicate { $0.backendRecipeID == targetRecipeID })
        descriptor.fetchLimit = 1
        if let local = try? modelContext.fetch(descriptor).first {
            return local.title
        }
        return try? await AccountsAPIClient.getRecipe(id: recipeID).title
    }
}

// MARK: - Sign-out purge

extension GroupSyncService {
    /// Deletes every locally-cached group-sync row — `GroupPlannedMeal`,
    /// `GroupMealSuggestion`, `GroupSharedGroceryItem` — from `modelContext`,
    /// **regardless of `syncState`**, including anything still
    /// `.pendingCreate`/`.pendingUpdate`/`.pendingDelete`. Called on every
    /// sign-out (see `RootView`'s `.onChange(of: accountSession.isSignedIn)`,
    /// which covers both the explicit "Sign Out" tap and the automatic
    /// 401-triggered sign-out `AccountsAPIClient` performs — both flip
    /// `isSignedIn` to `false` the same way, so both are caught here
    /// uniformly with no separate wiring needed at either call site).
    ///
    /// **Why this exists**: the SwiftData `ModelContainer` these rows live
    /// in is shared per-*device*, not per-signed-in-account — on a shared
    /// device, User A's offline edit (still `.pendingCreate`/
    /// `.pendingUpdate`/`.pendingDelete` because it hasn't synced yet) would
    /// otherwise sit in this store untouched by a sign-out, and User B's
    /// very next visit to that same group's screen would have
    /// `GroupSyncService.push()` fire it off to the backend using B's own
    /// Keychain token — silently attributing A's action to B. Purging every
    /// row unconditionally on sign-out closes that window entirely: there is
    /// nothing left in the store for a subsequent `push()` to send under the
    /// wrong identity, no matter who signs in next or how soon. The
    /// trade-off this accepts on purpose — a genuinely un-synced pending
    /// change is lost rather than held for "whoever signs in next" — is the
    /// right one: losing an edit is recoverable (redo it), misattributing it
    /// to a different account is not.
    ///
    /// On the next sign-in (same device, same or different account), the
    /// normal `pull()` path re-populates these three models fresh from the
    /// server for whatever groups that account belongs to — identical to a
    /// first-ever sign-in, so there's no special-casing needed anywhere else
    /// for "this device used to have someone else's cached group data."
    ///
    /// Deliberately scoped to **only** these three group-sync mirrors —
    /// every personal/local-only model (`Recipe`, the personal `PlannedMeal`,
    /// `GroceryItem`, `FamilyMember`, ...) is untouched, since none of that
    /// is account-scoped server state in the first place; see each of those
    /// models' own doc comments on being purely local/per-device.
    static func purgeAllLocalGroupData(modelContext: ModelContext) {
        deleteAllRows(of: GroupPlannedMeal.self, modelContext: modelContext)
        deleteAllRows(of: GroupMealSuggestion.self, modelContext: modelContext)
        deleteAllRows(of: GroupSharedGroceryItem.self, modelContext: modelContext)
        // Phase 4 — the same shared-device/wrong-account-attribution risk
        // this method's own doc comment describes applies identically to
        // this newer mirror. (Two former sibling calls here —
        // `deleteAllRows(of: GroupStapleItem.self, ...)` and `deleteAllRows(of:
        // GroupGroceryHistoryEntry.self, ...)` — were removed along with the
        // rest of the standing "staples" template-list feature and the
        // group-shared "past groceries" catalog, respectively; see
        // `GroupStoreAisle`'s doc comment in
        // HomeEats/Models/GroupGroceryLayout.swift for both removal notes.)
        deleteAllRows(of: GroupStoreAisle.self, modelContext: modelContext)
        try? modelContext.save()
    }

    /// Same fetch-everything-then-loop-delete shape as this codebase's other
    /// one-time/global cleanups (see `RejectedGroceryItemCleanup`) rather
    /// than SwiftData's batch `ModelContext.delete(model:)` — keeps this
    /// consistent with the established pattern here and sidesteps needing to
    /// separately verify that newer batch-delete API's behavior against
    /// pending, not-yet-saved changes in the same context.
    private static func deleteAllRows<T: PersistentModel>(of type: T.Type, modelContext: ModelContext) {
        guard let rows = try? modelContext.fetch(FetchDescriptor<T>()) else { return }
        for row in rows { modelContext.delete(row) }
    }
}

// MARK: - Immediate/online-only manager actions (adopt, accept, manager edit)

extension GroupSyncService {
    /// Manager-only "turn this suggestion into a decided meal" action — see
    /// this file's own "Known limitations" note on why this is immediate/
    /// online-only rather than queued. Re-pulls afterward so the caller's
    /// local store reflects both sides of the transaction (the new
    /// `PlannedMeal`, the now-gone `MealSuggestion`) right away instead of
    /// waiting for the next periodic sync.
    static func adoptSuggestion(groupID: String, suggestionID: String, modelContext: ModelContext) async throws {
        _ = try await AccountsAPIClient.adoptGroupMealSuggestion(groupID: groupID, suggestionID: suggestionID)
        _ = await pull(groupID: groupID, modelContext: modelContext)
    }

    /// Manager-only "move this suggested item onto the real list" action —
    /// same immediate/online-only reasoning as `adoptSuggestion`.
    static func acceptGroceryItem(groupID: String, itemID: String, modelContext: ModelContext) async throws {
        _ = try await AccountsAPIClient.acceptGroupGroceryItem(groupID: groupID, id: itemID)
        _ = await pull(groupID: groupID, modelContext: modelContext)
    }

    /// Manager-only direct edit of an item's name/category/quantityText/
    /// section — see `GroupSharedGroceryItem.syncState`'s doc comment for
    /// why this, too, is immediate/online rather than queued through
    /// `.pendingUpdate` (sidesteps ever building a PATCH that mixes a
    /// manager-only field with a `PARTICIPANT`-safe one).
    static func editGroceryItem(
        groupID: String, itemID: String, name: String, category: GroceryCategory,
        quantityText: String, section: GroupGrocerySection, modelContext: ModelContext
    ) async throws {
        _ = try await AccountsAPIClient.updateGroupGroceryItem(
            groupID: groupID, id: itemID, name: name, category: category,
            quantityText: quantityText, section: section
        )
        _ = await pull(groupID: groupID, modelContext: modelContext)
    }
}
