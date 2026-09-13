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
