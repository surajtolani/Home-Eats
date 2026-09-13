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
            // A local edit (or, for a suggestion, a vote toggle) is still
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
/// this exists to close (a local checkbox toggle or reorder, made while that
/// row's create call is still in flight, would otherwise be silently
/// overwritten by the create response's "as submitted" values once it comes
/// back). A pure function of the before/after snapshots, exposed standalone
/// for the same reason `ReconciliationAction.decide` is: unit-testable with
/// no `ModelContext` and no network at all (see
/// `GroupGroceryItemCreateRaceTests`).
enum GroceryCreateReconciliation {
    /// - Returns: `true` if either field has moved since the create request
    ///   was dispatched — meaning the local value, not the server's
    ///   as-submitted echo of it, should win, and the row should be marked
    ///   `.pendingUpdate` (not `.synced`) so the corrected value still gets
    ///   pushed. `false` (the common case — nothing changed mid-flight)
    ///   means the response is fully authoritative, same as before this fix.
    static func shouldPreserveLocalCheckedAndOrder(
        dispatchedIsChecked: Bool, currentIsChecked: Bool,
        dispatchedOrderIndex: Double, currentOrderIndex: Double
    ) -> Bool {
        currentIsChecked != dispatchedIsChecked || currentOrderIndex != dispatchedOrderIndex
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
/// - **A suggestion's vote toggle can still race a fellow member's vote.**
///   `POST .../vote` toggles unconditionally rather than "set my vote to
///   X" — this client compensates for *its own* double-toggle case (see
///   `GroupMealSuggestion.lastKnownServerVotedByMe`'s doc comment), but if
///   the caller's own pending toggle sits queued for a while (offline) and,
///   in the meantime, a push from a *different* device changes that same
///   suggestion's vote count, this device's eventual toggle still lands
///   correctly for the caller's own vote (toggling is per-user, keyed by
///   `@@unique([suggestionId, userId])` — see that model's doc comment in
///   prisma/schema.prisma) — so this particular case is actually fine; it's
///   called out here only because it's the one place a "toggle" endpoint
///   could plausibly have been a problem, and it's worth being explicit
///   that it isn't.
/// - **Un-voting your own suggestion before it's ever synced is a no-op
///   until the sync happens.** `GroupMealSuggestion.toggleVoteLocally()`
///   deliberately never promotes a still-`.pendingCreate` row to
///   `.pendingUpdate` (see that method's own doc comment for the stuck-row
///   bug that would otherwise cause) — the practical effect is that
///   proposing a suggestion and immediately un-voting your own default
///   vote, all before the next sync, has that vote silently reappear once
///   the create succeeds (the backend always auto-votes the proposer on
///   creation). One extra tap after syncing fixes it; a real fix would mean
///   queuing a separate "vote intent" ahead of a still-unconfirmed create,
///   which isn't worth the complexity for what's a narrow, low-stakes edge
///   case.
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
    static func sync(groupID: String, modelContext: ModelContext) async -> SyncOutcome {
        let pushSucceeded = await push(groupID: groupID, modelContext: modelContext)
        let pullSucceeded = await pull(groupID: groupID, modelContext: modelContext)
        return SyncOutcome(pushSucceeded: pushSucceeded, pullSucceeded: pullSucceeded)
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
        // Phase 4 — "My Layout" aisles and staples. Grocery history has no
        // push counterpart at all (see `reconcileGroceryHistory`'s own doc
        // comment: it's a read-only, server-populated catalog).
        allSucceeded = await pushAisles(groupID: groupID, modelContext: modelContext) && allSucceeded
        allSucceeded = await pushStaples(groupID: groupID, modelContext: modelContext) && allSucceeded
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
                    row.createdAt = created.createdAt
                    row.votedByMe = created.votedByMe
                    row.lastKnownServerVotedByMe = created.votedByMe
                    row.voteCount = created.voteCount
                    row.syncState = .synced
                } catch {
                    allOK = false
                }
            case .pendingUpdate:
                // Only a vote toggle can ever put a suggestion in this
                // state (see `GroupMealSuggestion.syncState`'s doc comment)
                // — a brand-new, not-yet-pushed suggestion stays
                // `.pendingCreate` until its first push succeeds, never
                // also `.pendingUpdate` at the same time, so `row.id` here
                // is always a real server id already.
                do {
                    let updated = try await AccountsAPIClient.toggleGroupMealSuggestionVote(
                        groupID: groupID, suggestionID: row.id
                    )
                    row.votedByMe = updated.votedByMe
                    row.lastKnownServerVotedByMe = updated.votedByMe
                    row.voteCount = updated.voteCount
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
                // Snapshot the checkbox/reorder fields at the moment this
                // create request is dispatched — the `await` below can
                // yield the main actor to a concurrent local
                // toggle/reorder (`setChecked`/`reorder` in
                // `GroupSharedGroceryListView`) made while this call is
                // still in flight. Unlike an already-`.synced` row, this
                // row's `syncState` stays `.pendingCreate` throughout that
                // window (there's no server id yet for a concurrent edit to
                // be queued as a `.pendingUpdate` against), so without this
                // check a local change made mid-flight would simply be
                // overwritten by whatever this row's own values were *at
                // dispatch time*, once the create response applies them
                // back via `applyRemote`. Same class of race — and the same
                // "capture, compare after the await, prefer the local value
                // if it moved" fix — as `GroupMealSuggestion.toggleVoteLocally()`'s
                // own protection against a concurrent vote toggle; see that
                // method's doc comment.
                let dispatchedIsChecked = row.isChecked
                let dispatchedOrderIndex = row.orderIndex
                // Same race-capture idea, extended to "My Layout" placement
                // (Phase 4): a manual aisle move made in this same in-flight
                // window can't be sent as part of THIS create call either
                // (`POST .../grocery` never accepts `aisleId` — see
                // `CreateItemSchema` in routes/groupGrocery.js), so it has to
                // be detected the same "snapshot, compare after the await"
                // way and preserved rather than silently lost the moment
                // `applyRemote` would otherwise mark this row `.synced`.
                let dispatchedAisleID = row.aisleID
                let dispatchedAisleManuallySet = row.aisleManuallySet
                do {
                    let created = try await AccountsAPIClient.createGroupGroceryItem(
                        groupID: groupID, name: row.name, category: row.category, section: row.section,
                        quantityText: row.quantityText, orderIndex: row.orderIndex
                    )
                    let checkedOrOrderChangedSinceDispatch = GroceryCreateReconciliation.shouldPreserveLocalCheckedAndOrder(
                        dispatchedIsChecked: dispatchedIsChecked, currentIsChecked: row.isChecked,
                        dispatchedOrderIndex: dispatchedOrderIndex, currentOrderIndex: row.orderIndex
                    )
                    let aisleChangedSinceDispatch = row.aisleID != dispatchedAisleID
                        || row.aisleManuallySet != dispatchedAisleManuallySet
                    applyRemote(
                        created, to: row,
                        preserveLocalCheckedAndOrder: checkedOrOrderChangedSinceDispatch,
                        preserveLocalAisle: aisleChangedSinceDispatch
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
                            aisleID: .set(row.aisleID)
                        )
                    } else {
                        updated = try await AccountsAPIClient.updateGroupGroceryItem(
                            groupID: groupID, id: row.id, isChecked: row.isChecked, orderIndex: row.orderIndex
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
    /// `isChecked`/`orderIndex` from `remote` and marks the row
    /// `.pendingUpdate` instead of `.synced`, so a local change made while
    /// this row's create call was still in flight isn't clobbered — the
    /// row's next push then sends those corrected values via the normal
    /// `updateGroupGroceryItem` path. `preserveLocalAisle` (Phase 4) is the
    /// "My Layout" placement counterpart of the same idea — same race, same
    /// fix, see that same `.pendingCreate` case for the one caller that ever
    /// passes it `true`. Every other caller (a `.pendingUpdate` push's own
    /// response, and `reconcileGroceryItems`'s pull-side upsert, neither of
    /// which race a create) leaves both flags at their default `false`, i.e.
    /// today's existing "the response is authoritative" behavior, unchanged.
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
        // Phase 4 — "My Layout" aisles, staples, and grocery history. Fetched
        // every sync cycle (not only when their screens happen to be on
        // screen), same "small, household-scale, low-traffic" reasoning the
        // rest of this file's periodic-resync design already accepts — and,
        // for aisles specifically, load-bearing: `getGroupGroceryAisles` is
        // also what lazily seeds a group's ten starter aisles the first time
        // it's ever called (see that method's own doc comment) — calling it
        // here, on every sync, means those starter aisles are already seeded
        // and synced locally well before someone first switches "My Layout"
        // on, rather than "My Layout" opening to an empty/all-Unsorted list
        // for the one sync cycle it would otherwise take to catch up.
        async let aislesResult = try? AccountsAPIClient.getGroupGroceryAisles(groupID: groupID)
        async let staplesResult = try? AccountsAPIClient.getGroupGroceryStaples(groupID: groupID)
        async let historyResult = try? AccountsAPIClient.getGroupGroceryHistory(groupID: groupID)
        let (mealPlan, grocery, aisles, staples, history) = await (
            mealPlanResult, groceryResult, aislesResult, staplesResult, historyResult
        )
        guard let mealPlan, let grocery, let aisles, let staples, let history else { return false }

        await reconcilePlannedMeals(remote: mealPlan.plannedMeals, groupID: groupID, modelContext: modelContext)
        await reconcileSuggestions(remote: mealPlan.suggestions, groupID: groupID, modelContext: modelContext)
        reconcileGroceryItems(remote: grocery.items, groupID: groupID, modelContext: modelContext)
        reconcileAisles(remote: aisles.aisles, groupID: groupID, modelContext: modelContext)
        reconcileStaples(remote: staples.staples, groupID: groupID, modelContext: modelContext)
        reconcileGroceryHistory(remote: history.items, groupID: groupID, modelContext: modelContext)
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
                existing.decidedAt = remoteMeal.decidedAt
                existing.syncState = .synced
                existing.serverUpdatedAt = remoteMeal.decidedAt
            } else {
                modelContext.insert(GroupPlannedMeal(
                    id: remoteMeal.id, groupID: groupID, date: remoteMeal.date, slot: remoteMeal.slot.localSlot,
                    recipeID: remoteMeal.recipeID, cachedRecipeTitle: title, restaurantName: remoteMeal.restaurantName,
                    isOrderIn: remoteMeal.isOrderIn, decidedByUserID: remoteMeal.decidedByUserID, decidedAt: remoteMeal.decidedAt,
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
                existing.createdAt = remoteSuggestion.createdAt
                existing.votedByMe = remoteSuggestion.votedByMe
                existing.lastKnownServerVotedByMe = remoteSuggestion.votedByMe
                existing.voteCount = remoteSuggestion.voteCount
                existing.syncState = .synced
            } else {
                modelContext.insert(GroupMealSuggestion(
                    id: remoteSuggestion.id, groupID: groupID, date: remoteSuggestion.date, slot: remoteSuggestion.slot.localSlot,
                    recipeID: remoteSuggestion.recipeID, cachedRecipeTitle: title, restaurantName: remoteSuggestion.restaurantName,
                    isOrderIn: remoteSuggestion.isOrderIn, proposedByUserID: remoteSuggestion.proposedByUserID,
                    createdAt: remoteSuggestion.createdAt, votedByMe: remoteSuggestion.votedByMe, voteCount: remoteSuggestion.voteCount,
                    lastKnownServerVotedByMe: remoteSuggestion.votedByMe, syncState: .synced
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
                    section: remoteItem.section, quantityText: remoteItem.quantityText, isChecked: remoteItem.isChecked,
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
                do {
                    let created = try await AccountsAPIClient.createGroupGroceryAisle(groupID: groupID, name: row.name)
                    applyRemote(created, to: row)
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
    /// overload above (see its own doc comment); this one has no
    /// create/dispatch race to guard against (aisles have no analogous
    /// "checked/order changed mid-flight" concern), so it's a plain
    /// field-mapping function, still worth unit-testing directly without a
    /// `ModelContext`. Safe to opt out of this enum's `@MainActor` isolation
    /// for the same reason as that overload: it only ever mutates the single
    /// `row` instance it's handed.
    nonisolated static func applyRemote(_ remote: RemoteGroupStoreAisle, to row: GroupStoreAisle) {
        row.id = remote.id
        row.name = remote.name
        row.sortIndex = remote.sortIndex
        row.linkedCategory = remote.linkedCategory?.localCategory
        row.syncState = .synced
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

    // MARK: - Push + pull + reconcile: staples (Phase 4)

    private static func localStaples(groupID: String, modelContext: ModelContext) -> [GroupStapleItem] {
        let descriptor = FetchDescriptor<GroupStapleItem>(predicate: #Predicate { $0.groupID == groupID })
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    private static func pushStaples(groupID: String, modelContext: ModelContext) async -> Bool {
        var allOK = true
        for row in localStaples(groupID: groupID, modelContext: modelContext) {
            switch row.syncState {
            case .synced:
                continue
            case .pendingCreate:
                do {
                    let created = try await AccountsAPIClient.createGroupGroceryStaple(
                        groupID: groupID, name: row.name, category: row.category, defaultQuantityText: row.defaultQuantityText
                    )
                    applyRemote(created, to: row)
                } catch {
                    allOK = false
                }
            case .pendingUpdate:
                // Only ever `isActive` in practice — see
                // `GroupStaplesManagerView` and
                // `AccountsAPIClient.updateGroupGroceryStaple`'s own doc
                // comment on why this app's UI never edits a staple's
                // name/category once created (matching the local, personal
                // `StaplesManagerView`'s own reference UI exactly).
                do {
                    let updated = try await AccountsAPIClient.updateGroupGroceryStaple(
                        groupID: groupID, id: row.id, isActive: row.isActive
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
                    try await AccountsAPIClient.deleteGroupGroceryStaple(groupID: groupID, id: row.id)
                    modelContext.delete(row)
                } catch {
                    allOK = false
                }
            }
        }
        return allOK
    }

    /// Not `private`, and explicitly `nonisolated` — same reasoning as the
    /// `RemoteGroupStoreAisle` overload above.
    nonisolated static func applyRemote(_ remote: RemoteGroupStapleItem, to row: GroupStapleItem) {
        row.id = remote.id
        row.name = remote.name
        row.category = remote.category.localCategory
        row.defaultQuantityText = remote.defaultQuantityText
        row.isActive = remote.isActive
        row.addedByUserID = remote.addedByUserID
        row.syncState = .synced
    }

    private static func reconcileStaples(remote: [RemoteGroupStapleItem], groupID: String, modelContext: ModelContext) {
        let localRows = localStaples(groupID: groupID, modelContext: modelContext)
        var localByID: [String: GroupStapleItem] = [:]
        for row in localRows where !row.isLocalPlaceholderID { localByID[row.id] = row }
        let remoteIDs = Set(remote.map(\.id))

        for remoteStaple in remote {
            let existing = localByID[remoteStaple.id]
            guard ReconciliationAction.decide(localSyncState: existing?.syncState, presentInPull: true) == .upsertFromServer else { continue }

            if let existing {
                applyRemote(remoteStaple, to: existing)
            } else {
                modelContext.insert(GroupStapleItem(
                    id: remoteStaple.id, groupID: groupID, name: remoteStaple.name, category: remoteStaple.category.localCategory,
                    defaultQuantityText: remoteStaple.defaultQuantityText, isActive: remoteStaple.isActive,
                    addedByUserID: remoteStaple.addedByUserID, createdAt: remoteStaple.createdAt, syncState: .synced
                ))
            }
        }

        for row in localRows where !row.isLocalPlaceholderID && !remoteIDs.contains(row.id) {
            if ReconciliationAction.decide(localSyncState: row.syncState, presentInPull: false) == .deleteLocal {
                modelContext.delete(row)
            }
        }
    }

    // MARK: - Pull + reconcile: grocery history (Phase 4, read-only)

    private static func localGroceryHistory(groupID: String, modelContext: ModelContext) -> [GroupGroceryHistoryEntry] {
        let descriptor = FetchDescriptor<GroupGroceryHistoryEntry>(predicate: #Predicate { $0.groupID == groupID })
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    /// Unlike every other reconcile method in this file, this one needs no
    /// `ReconciliationAction` decision at all: `GroupGroceryHistoryEntry` has
    /// no `syncState` and no local write path ever creates/edits/deletes one
    /// (see that model's own doc comment) — every local row is always,
    /// implicitly, "synced", so simply replacing this group's whole local
    /// set with the latest pull is correct on every cycle, no conflict ever
    /// possible.
    private static func reconcileGroceryHistory(remote: [RemoteGroupGroceryHistoryEntry], groupID: String, modelContext: ModelContext) {
        let localRows = localGroceryHistory(groupID: groupID, modelContext: modelContext)
        var localByID: [String: GroupGroceryHistoryEntry] = [:]
        for row in localRows { localByID[row.id] = row }

        var remoteIDs = Set<String>()
        for entry in remote {
            let id = GroupGroceryHistoryEntry.makeID(groupID: groupID, name: entry.name)
            remoteIDs.insert(id)
            if let existing = localByID[id] {
                existing.name = entry.name
                existing.category = entry.category.localCategory
                existing.addedAt = entry.addedAt
            } else {
                modelContext.insert(GroupGroceryHistoryEntry(
                    groupID: groupID, name: entry.name, category: entry.category.localCategory, addedAt: entry.addedAt
                ))
            }
        }

        for row in localRows where !remoteIDs.contains(row.id) {
            modelContext.delete(row)
        }
    }

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
        // these three newer mirrors; `GroupGroceryHistoryEntry` has no
        // pending state of its own to misattribute, but purging it too keeps
        // this method's "every group-sync mirror, unconditionally" contract
        // simple and exhaustive rather than special-casing the one type that
        // happens not to need it for this particular reason.
        deleteAllRows(of: GroupStoreAisle.self, modelContext: modelContext)
        deleteAllRows(of: GroupStapleItem.self, modelContext: modelContext)
        deleteAllRows(of: GroupGroceryHistoryEntry.self, modelContext: modelContext)
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
