import XCTest
@testable import HomeEats

/// Table-driven tests for `ReconciliationAction.decide` — the actual
/// conflict-resolution rule `GroupSyncService.pull` applies uniformly across
/// `GroupPlannedMeal`, `GroupMealSuggestion`, and `GroupSharedGroceryItem`.
/// Exercised as the pure function it is (no `ModelContext`, no network),
/// covering every `(localSyncState, presentInPull)` combination the type
/// system allows — see `GroupSyncState`'s own doc comment for why this is
/// state-based rather than timestamp/version-based, and
/// `GroupSyncService`'s "Known limitations" note for the one real conflict
/// window this rule doesn't (and structurally can't) fully solve.
final class GroupSyncReconciliationTests: XCTestCase {

    // MARK: - No local row yet

    func testNoLocalRowAndServerHasIt_upsertsFromServer() {
        // A fresh row nobody on this device has seen before — the common
        // "someone else added something" case.
        XCTAssertEqual(
            ReconciliationAction.decide(localSyncState: nil, presentInPull: true),
            .upsertFromServer
        )
    }

    func testNoLocalRowAndServerDoesNotHaveIt_keepsLocalAsNoOp() {
        // Nothing to reconcile either way — answering "do nothing" is
        // correct even though callers don't actually ask this combination
        // in practice (see the function's own doc comment).
        XCTAssertEqual(
            ReconciliationAction.decide(localSyncState: nil, presentInPull: false),
            .keepLocal
        )
    }

    // MARK: - .synced: the server's current view always wins

    func testSyncedLocalRowStillOnServer_upsertsFromServer() {
        // No pending local change -> a fellow member's edit (e.g. someone
        // else checked an item off, or a manager renamed it) always applies.
        XCTAssertEqual(
            ReconciliationAction.decide(localSyncState: .synced, presentInPull: true),
            .upsertFromServer
        )
    }

    func testSyncedLocalRowNoLongerOnServer_deletesLocal() {
        // No pending local change, and the server no longer lists it ->
        // someone else deleted it remotely; this device should mirror that.
        XCTAssertEqual(
            ReconciliationAction.decide(localSyncState: .synced, presentInPull: false),
            .deleteLocal
        )
    }

    // MARK: - .pendingCreate: never touched by a pull, either way

    func testPendingCreateRow_keepsLocalRegardlessOfPullPresence() {
        // A pull literally cannot know about a `.pendingCreate` row under
        // its eventual server id (it's still keyed by a local placeholder),
        // so `presentInPull` is always `false` for it in practice — but the
        // rule holds even in the degenerate case where it's asked with
        // `true`, since `push` (not `pull`) is what's responsible for
        // clearing this state once the create actually lands.
        XCTAssertEqual(
            ReconciliationAction.decide(localSyncState: .pendingCreate, presentInPull: false),
            .keepLocal
        )
        XCTAssertEqual(
            ReconciliationAction.decide(localSyncState: .pendingCreate, presentInPull: true),
            .keepLocal
        )
    }

    // MARK: - .pendingUpdate: a local edit still waiting to be pushed wins

    func testPendingUpdateRow_keepsLocalEvenThoughServerStillHasIt() {
        // The classic "don't let a pull clobber a not-yet-pushed edit" case
        // this whole design exists for — e.g. a `PARTICIPANT` checked an
        // item off while offline; the next pull must not silently uncheck
        // it back to the server's stale "not checked" value.
        XCTAssertEqual(
            ReconciliationAction.decide(localSyncState: .pendingUpdate, presentInPull: true),
            .keepLocal
        )
    }

    func testPendingUpdateRow_keepsLocalEvenIfServerNoLongerHasIt() {
        // Rarer, but real: the row was deleted by someone else server-side
        // in between this device's edit and its next sync. The local
        // pending edit still must not be silently discarded/deleted out
        // from under the user without at least one push attempt (which
        // will itself fail cleanly against a 404 — a separate, acceptable
        // outcome handled by `push`, not by reconciliation quietly
        // resurrecting-then-redeleting the row here).
        XCTAssertEqual(
            ReconciliationAction.decide(localSyncState: .pendingUpdate, presentInPull: false),
            .keepLocal
        )
    }

    // MARK: - .pendingDelete: never resurrected by a pull

    func testPendingDeleteRow_keepsLocalIfServerStillListsIt() {
        // The delete simply hasn't reached the server yet — this is the
        // scenario called out explicitly in this task's own spec ("decide
        // what to do with a local row that's `.pendingDelete`... don't
        // resurrect it from the pull if the delete hasn't been pushed/
        // acknowledged yet").
        XCTAssertEqual(
            ReconciliationAction.decide(localSyncState: .pendingDelete, presentInPull: true),
            .keepLocal
        )
    }

    func testPendingDeleteRow_keepsLocalIfServerAlreadyAgrees() {
        // The delete has already landed server-side (this pull just hasn't
        // been paired with the push's own success yet, or ran concurrently
        // with it) — `push` is what actually removes the local row once its
        // own delete call succeeds; `pull`/reconciliation never deletes a
        // `.pendingDelete` row itself, so as not to race `push`'s own
        // handling of the exact same row within the same sync cycle.
        XCTAssertEqual(
            ReconciliationAction.decide(localSyncState: .pendingDelete, presentInPull: false),
            .keepLocal
        )
    }

    // MARK: - Full state coverage, table-driven

    /// Every `GroupSyncState` case crossed with both `presentInPull` values
    /// — a compact regression guard so a future new `GroupSyncState` case
    /// can't silently fall through this decision table untested (the
    /// individual scenario tests above are the ones worth reading for the
    /// *reasoning*; this one is the exhaustiveness net).
    func testEveryStateAndPullPresenceCombinationHasAnExplicitAnswer() {
        let table: [(state: GroupSyncState, presentInPull: Bool, expected: ReconciliationAction)] = [
            (.synced, true, .upsertFromServer),
            (.synced, false, .deleteLocal),
            (.pendingCreate, true, .keepLocal),
            (.pendingCreate, false, .keepLocal),
            (.pendingUpdate, true, .keepLocal),
            (.pendingUpdate, false, .keepLocal),
            (.pendingDelete, true, .keepLocal),
            (.pendingDelete, false, .keepLocal),
        ]
        for row in table {
            XCTAssertEqual(
                ReconciliationAction.decide(localSyncState: row.state, presentInPull: row.presentInPull),
                row.expected,
                "state=\(row.state), presentInPull=\(row.presentInPull)"
            )
        }
    }
}

/// Unit tests for the local vote-toggle bookkeeping on `GroupMealSuggestion`
/// — the logic `GroupSyncService.pushSuggestions` relies on to know whether
/// a suggestion's vote genuinely needs a `POST .../vote` call, including the
/// "toggled twice while offline, nets out to nothing" case its own doc
/// comment calls out.
final class GroupMealSuggestionVoteToggleTests: XCTestCase {

    private func makeSuggestion(votedByMe: Bool, voteCount: Int) -> GroupMealSuggestion {
        GroupMealSuggestion(
            id: "s1", groupID: "g1", date: .now, slot: .dinner,
            restaurantName: "Diner", proposedByUserID: "u1",
            votedByMe: votedByMe, voteCount: voteCount
        )
    }

    func testTogglingOnceMarksPendingUpdate() {
        let suggestion = makeSuggestion(votedByMe: false, voteCount: 3)
        suggestion.toggleVoteLocally()
        XCTAssertTrue(suggestion.votedByMe)
        XCTAssertEqual(suggestion.voteCount, 4)
        XCTAssertEqual(suggestion.syncState, .pendingUpdate)
    }

    func testTogglingTwiceReturnsToSyncedWithNoNetChange() {
        // Vote, then un-vote again, both before ever syncing — should net
        // out to "nothing to push," not two vote-endpoint calls (which
        // would incorrectly flip the caller's real server-side vote state
        // an extra time — see `GroupMealSuggestion.lastKnownServerVotedByMe`'s
        // own doc comment on exactly this scenario).
        let suggestion = makeSuggestion(votedByMe: false, voteCount: 3)
        suggestion.toggleVoteLocally()
        suggestion.toggleVoteLocally()
        XCTAssertFalse(suggestion.votedByMe)
        XCTAssertEqual(suggestion.voteCount, 3)
        XCTAssertEqual(suggestion.syncState, .synced)
    }

    func testUnvotingAnAlreadyVotedSuggestionDecrementsCount() {
        let suggestion = makeSuggestion(votedByMe: true, voteCount: 5)
        suggestion.toggleVoteLocally()
        XCTAssertFalse(suggestion.votedByMe)
        XCTAssertEqual(suggestion.voteCount, 4)
        XCTAssertEqual(suggestion.syncState, .pendingUpdate)
    }

    /// Regression guard for the bug this design note calls out on
    /// `toggleVoteLocally` itself: toggling the vote on a suggestion that
    /// hasn't even been pushed yet (`.pendingCreate`, still keyed by a local
    /// placeholder id) must NOT be promoted to `.pendingUpdate` — doing so
    /// would make the next sync try to `POST .../vote` against an id the
    /// server has never heard of, which can only fail and would permanently
    /// strand the row (never even attempting the create it still needs).
    func testTogglingVoteOnAPendingCreateSuggestionNeverBecomesPendingUpdate() {
        let suggestion = GroupMealSuggestion(
            id: GroupMealSuggestion.newLocalPlaceholderID(), groupID: "g1", date: .now, slot: .dinner,
            restaurantName: "Diner", proposedByUserID: "u1", votedByMe: true, voteCount: 1,
            syncState: .pendingCreate
        )
        suggestion.toggleVoteLocally()
        XCTAssertFalse(suggestion.votedByMe)
        XCTAssertEqual(suggestion.voteCount, 0)
        // Still `.pendingCreate` — the row's very first push (the create
        // itself) is still what's needed next, not a vote-toggle push.
        XCTAssertEqual(suggestion.syncState, .pendingCreate)
        XCTAssertTrue(suggestion.isLocalPlaceholderID)
    }

    /// Same guard, for `.pendingDelete`: a suggestion queued for deletion
    /// (but not yet acknowledged) must not have its sync state clobbered by
    /// a stray vote toggle either — the pending delete must win.
    func testTogglingVoteOnAPendingDeleteSuggestionStaysPendingDelete() {
        let suggestion = makeSuggestion(votedByMe: false, voteCount: 2)
        suggestion.syncState = .pendingDelete
        suggestion.toggleVoteLocally()
        XCTAssertEqual(suggestion.syncState, .pendingDelete)
    }
}

/// Unit tests for each local model's placeholder-id convention (the
/// not-yet-synced identity scheme `GroupPlannedMeal`/`GroupMealSuggestion`/
/// `GroupSharedGroceryItem` all share — see any one of their `id` doc
/// comments for the full reasoning).
final class GroupLocalPlaceholderIDTests: XCTestCase {
    func testFreshPlaceholderIDsAreRecognizedAndUnique() {
        let first = GroupPlannedMeal.newLocalPlaceholderID()
        let second = GroupPlannedMeal.newLocalPlaceholderID()
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(first.hasPrefix(GroupPlannedMeal.localPlaceholderIDPrefix))

        let meal = GroupPlannedMeal(
            id: first, groupID: "g1", date: .now, slot: .dinner,
            restaurantName: "Diner", decidedByUserID: "u1", syncState: .pendingCreate
        )
        XCTAssertTrue(meal.isLocalPlaceholderID)
    }

    func testARealServerIDIsNotMistakenForAPlaceholder() {
        // A real backend id (a Postgres/Prisma-generated UUID, no dashes
        // stripped, no special prefix) must never collide with this scheme
        // — regression guard against ever picking a placeholder prefix that
        // could plausibly appear at the start of a genuine UUID.
        let meal = GroupPlannedMeal(
            id: "550e8400-e29b-41d4-a716-446655440000", groupID: "g1", date: .now, slot: .dinner,
            restaurantName: "Diner", decidedByUserID: "u1", syncState: .synced
        )
        XCTAssertFalse(meal.isLocalPlaceholderID)
    }
}

/// Regression tests for the create-race protection
/// `GroupSyncService.pushGroceryItems`'s `.pendingCreate` handling applies: a
/// local `isChecked`/`orderIndex`/aisle-placement change that the create
/// call itself could never communicate — because it was made before the
/// create was ever dispatched, or because it changed while the call was
/// still in flight — must win over the create response's values, not be
/// silently clobbered by them. See `GroceryCreateReconciliation`'s own doc
/// comment for the exact bug this closes (a dispatch-time snapshot comparison
/// used to miss the "already set before dispatch" half of this entirely).
///
/// Split the same way `GroupSyncReconciliationTests`/
/// `GroupMealSuggestionVoteToggleTests` are: first the pure decision
/// function (no `ModelContext`, no network), then the actual model mutation
/// (`GroupSyncService.applyRemote`, exercised directly against a
/// `GroupSharedGroceryItem` constructed in-memory, no `ModelContext`
/// needed — same as `GroupMealSuggestionVoteToggleTests` constructing a
/// `GroupMealSuggestion` directly). The one piece this can't exercise
/// end-to-end without a live network layer — actually dispatching
/// `AccountsAPIClient.createGroupGroceryItem` and having a concurrent
/// `Task` mutate the row mid-`await` — is covered by hand-tracing
/// `pushGroceryItems`'s `.pendingCreate` case instead (see this task's
/// final report); this suite verifies that both pieces it's built from
/// behave correctly in every case that matters.
final class GroupGroceryItemCreateRaceTests: XCTestCase {

    // MARK: - `GroceryCreateReconciliation.shouldPreserveLocalCheckedAndOrder`

    func testNothingDiffersFromResponse_doesNotPreserveLocal() {
        XCTAssertFalse(GroceryCreateReconciliation.shouldPreserveLocalCheckedAndOrder(
            currentIsChecked: false, remoteIsChecked: false,
            currentOrderIndex: 2, remoteOrderIndex: 2
        ))
    }

    func testCheckedDiffersFromResponse_preservesLocal() {
        XCTAssertTrue(GroceryCreateReconciliation.shouldPreserveLocalCheckedAndOrder(
            currentIsChecked: true, remoteIsChecked: false,
            currentOrderIndex: 2, remoteOrderIndex: 2
        ))
    }

    func testOrderIndexDiffersFromResponse_preservesLocal() {
        XCTAssertTrue(GroceryCreateReconciliation.shouldPreserveLocalCheckedAndOrder(
            currentIsChecked: false, remoteIsChecked: false,
            currentOrderIndex: 5, remoteOrderIndex: 2
        ))
    }

    func testBothCheckedAndOrderDifferFromResponse_preservesLocal() {
        XCTAssertTrue(GroceryCreateReconciliation.shouldPreserveLocalCheckedAndOrder(
            currentIsChecked: true, remoteIsChecked: false,
            currentOrderIndex: 5, remoteOrderIndex: 2
        ))
    }

    /// Regression test for the exact bug `GroceryCreateReconciliation`'s own
    /// doc comment now calls out: `isChecked` was already `true` *before*
    /// the create call was ever dispatched (not toggled mid-flight) — e.g.
    /// the user added an item and immediately checked it off, all before its
    /// first sync ever ran. A dispatch-time-snapshot comparison would see
    /// "current == dispatched" (both `true`) and wrongly conclude nothing
    /// needed preserving; comparing against the create response's actual
    /// (always-`false`) `isChecked` catches this correctly.
    func testCheckedAlreadyTrueBeforeCreateWasEverDispatched_stillPreservesLocal() {
        XCTAssertTrue(GroceryCreateReconciliation.shouldPreserveLocalCheckedAndOrder(
            currentIsChecked: true, remoteIsChecked: false,
            currentOrderIndex: 0, remoteOrderIndex: 0
        ))
    }

    // MARK: - `GroupSyncService.applyRemote`

    private func makeLocalRow(
        isChecked: Bool, orderIndex: Double, syncState: GroupSyncState = .pendingCreate
    ) -> GroupSharedGroceryItem {
        GroupSharedGroceryItem(
            id: GroupSharedGroceryItem.newLocalPlaceholderID(), groupID: "g1", name: "Milk",
            category: .dairyAndEggs, section: .thisWeek, quantityText: "1 gal",
            isChecked: isChecked, orderIndex: orderIndex, addedByUserID: "u1", syncState: syncState
        )
    }

    private func makeRemoteItem(isChecked: Bool, orderIndex: Double) -> RemoteGroupGroceryItem {
        RemoteGroupGroceryItem(
            id: "server-1", groupID: "g1", name: "Milk", category: .dairyAndEggs, section: .thisWeek,
            quantityText: "1 gal", isChecked: isChecked, orderIndex: orderIndex, addedByUserID: "u1",
            createdAt: .now, updatedAt: .now
        )
    }

    func testCreateResponseWithNoConcurrentEdit_appliesRemoteCheckedAndOrderAndMarksSynced() {
        // The common case, unchanged by this fix: nothing local moved while
        // the create was in flight, so the server's response is fully
        // authoritative.
        let row = makeLocalRow(isChecked: false, orderIndex: 0)
        let remote = makeRemoteItem(isChecked: false, orderIndex: 0)
        GroupSyncService.applyRemote(remote, to: row, preserveLocalCheckedAndOrder: false)
        XCTAssertEqual(row.id, "server-1")
        XCTAssertFalse(row.isChecked)
        XCTAssertEqual(row.orderIndex, 0)
        XCTAssertEqual(row.syncState, .synced)
    }

    func testCreateResponseAfterConcurrentCheckToggle_preservesLocalCheckedAndMarksPendingUpdate() {
        // The user checked the item off in the window the create call was
        // in flight — the local `true` must win over the create response's
        // own `false`, and the row must still get pushed again
        // (`.pendingUpdate`), not be treated as fully synced with the wrong
        // value baked in.
        let row = makeLocalRow(isChecked: true, orderIndex: 0)
        let remote = makeRemoteItem(isChecked: false, orderIndex: 0)
        GroupSyncService.applyRemote(remote, to: row, preserveLocalCheckedAndOrder: true)
        XCTAssertTrue(row.isChecked, "local checkbox change must win, not be clobbered by the create response")
        XCTAssertEqual(row.syncState, .pendingUpdate, "must be re-pushed, not treated as fully synced")
    }

    func testCreateResponseAfterConcurrentReorder_preservesLocalOrderIndexAndMarksPendingUpdate() {
        let row = makeLocalRow(isChecked: false, orderIndex: 3)
        let remote = makeRemoteItem(isChecked: false, orderIndex: 0)
        GroupSyncService.applyRemote(remote, to: row, preserveLocalCheckedAndOrder: true)
        XCTAssertEqual(row.orderIndex, 3, "local reorder must win, not be clobbered by the create response")
        XCTAssertEqual(row.syncState, .pendingUpdate)
    }

    func testCreateResponseStillAdoptsServerIDAndOtherFieldsEvenWhenPreservingCheckedAndOrder() {
        // Preserving isChecked/orderIndex must not also strand the row on
        // its local placeholder id — it still needs the real server id for
        // its now-`.pendingUpdate` state to ever be push-able again via
        // `updateGroupGroceryItem`.
        let row = makeLocalRow(isChecked: true, orderIndex: 1)
        XCTAssertTrue(row.isLocalPlaceholderID)
        let remote = makeRemoteItem(isChecked: false, orderIndex: 0)
        GroupSyncService.applyRemote(remote, to: row, preserveLocalCheckedAndOrder: true)
        XCTAssertFalse(row.isLocalPlaceholderID)
        XCTAssertEqual(row.id, "server-1")
    }

    // MARK: - `GroupSyncService.applyRemote` — "My Layout" placement
    // (`preserveLocalAisle`), the same create-race protection extended to
    // Phase 4's aisle assignment. `POST .../grocery` never accepts
    // `aisleId`/`aisleManuallySet` at all (see `CreateItemSchema` in
    // routes/groupGrocery.js), so — exactly like `isChecked` above — an
    // aisle placement made before the create was ever dispatched is just as
    // real a case as one made mid-flight; `pushGroceryItems` computes
    // `aisleDiffersFromResponse` by comparing the row's current placement
    // against the create response's (always `nil`/`false`) values, which
    // catches both uniformly. These tests exercise `applyRemote` itself —
    // the actual field-preserving mutation — the same way the isChecked/
    // orderIndex tests above do.

    private func makeRemoteItemWithAisle(aisleID: String?, aisleManuallySet: Bool) -> RemoteGroupGroceryItem {
        RemoteGroupGroceryItem(
            id: "server-1", groupID: "g1", name: "Milk", category: .dairyAndEggs, section: .thisWeek,
            quantityText: "1 gal", isChecked: false, orderIndex: 0,
            aisleID: aisleID, aisleManuallySet: aisleManuallySet,
            addedByUserID: "u1", createdAt: .now, updatedAt: .now
        )
    }

    func testCreateResponseWithNoAislePlacement_appliesRemoteAisleAndMarksSynced() {
        // The common case: the item was never placed in an aisle before its
        // first sync, so the create response's "not placed" values are
        // authoritative.
        let row = makeLocalRow(isChecked: false, orderIndex: 0)
        XCTAssertNil(row.aisleID)
        XCTAssertFalse(row.aisleManuallySet)
        let remote = makeRemoteItemWithAisle(aisleID: nil, aisleManuallySet: false)
        GroupSyncService.applyRemote(remote, to: row, preserveLocalAisle: false)
        XCTAssertNil(row.aisleID)
        XCTAssertFalse(row.aisleManuallySet)
        XCTAssertEqual(row.syncState, .synced)
    }

    /// Regression test for the aisle-placement counterpart of the
    /// isChecked bug above: the user moved a still-`.pendingCreate` item
    /// into a specific aisle — whether that happened before the create call
    /// was ever dispatched, or while it was in flight, `POST .../grocery`
    /// has no way to carry that placement, so the create response always
    /// comes back "not placed." The local placement must win, and the row
    /// must be re-pushed (`.pendingUpdate`) via a follow-up `PATCH .../grocery/:id`
    /// so the placement actually reaches the server — not silently reset to
    /// "Unsorted" the moment the create response applies.
    func testCreateResponseAfterLocalAislePlacement_preservesLocalAisleAndMarksPendingUpdate() {
        let row = makeLocalRow(isChecked: false, orderIndex: 0)
        row.aisleID = "aisle-1"
        row.aisleManuallySet = true
        let remote = makeRemoteItemWithAisle(aisleID: nil, aisleManuallySet: false)
        GroupSyncService.applyRemote(remote, to: row, preserveLocalAisle: true)
        XCTAssertEqual(row.aisleID, "aisle-1", "local aisle placement must win, not be reset by the create response")
        XCTAssertTrue(row.aisleManuallySet)
        XCTAssertEqual(row.syncState, .pendingUpdate, "must be re-pushed, not treated as fully synced")
        // Still adopts the real server id — same "don't also strand the row
        // on its placeholder id" requirement as the isChecked/orderIndex
        // case above.
        XCTAssertFalse(row.isLocalPlaceholderID)
        XCTAssertEqual(row.id, "server-1")
    }
}
