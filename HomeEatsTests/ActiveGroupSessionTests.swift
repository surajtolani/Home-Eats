import XCTest
@testable import HomeEats

/// Table-driven coverage of `ActiveGroupSession.resolveActiveGroupID` — the
/// "which group should be active after a fresh `GET /groups`" decision (see
/// that function's own doc comment for why it's factored out as a plain,
/// synchronous static function specifically to make this possible without
/// faking a network call). This is the one piece of `ActiveGroupSession`'s
/// logic that's genuinely worth a real, isolated unit test: everything else
/// on that type is either a thin `AccountsAPIClient`/`UserDefaults`
/// pass-through (not meaningfully testable without a live backend or a real
/// device's defaults) or straightforward `@Published` state a hand-trace
/// covers just as well — see this task's own final report for what's
/// verified this way vs. only reasoned through.
final class ActiveGroupSessionTests: XCTestCase {
    private func group(_ id: String, name: String = "Group") -> GroupSummary {
        // `createdByUserID`/`createdAt` play no part in this decision —
        // fixed placeholder values keep every fixture below focused on the
        // one field (`id`) that actually matters here.
        GroupSummary(id: id, name: name, createdByUserID: "u1", createdAt: .distantPast)
    }

    func testCurrentGroupStillPresentIsKeptUnchanged() {
        // The whole point of persisting `activeGroupID` at all: a group you
        // were already looking at shouldn't silently jump to a different
        // one just because the server happened to return it in a different
        // position this time.
        let groups = [group("a"), group("b"), group("c")]
        XCTAssertEqual(
            ActiveGroupSession.resolveActiveGroupID(current: "b", groups: groups),
            "b"
        )
    }

    func testNilCurrentFallsBackToFirstInList() {
        // The very first `refreshGroups()` after sign-in, or after
        // `ActiveGroupSession.reset()` on sign-out — nothing was active
        // yet, so the simple "first in whatever order the server sent"
        // default kicks in (see that function's own doc comment on why
        // there's no fancier "most recent"/alphabetical logic here).
        let groups = [group("x"), group("y")]
        XCTAssertEqual(
            ActiveGroupSession.resolveActiveGroupID(current: nil, groups: groups),
            "x"
        )
    }

    func testStaleCurrentGroupFallsBackToFirstInList() {
        // The previously-active group is gone from the fresh list entirely
        // (left, removed by a manager, ...) — same fallback as the nil
        // case above, not an error state.
        let groups = [group("y"), group("z")]
        XCTAssertEqual(
            ActiveGroupSession.resolveActiveGroupID(current: "gone", groups: groups),
            "y"
        )
    }

    func testEmptyGroupListResolvesToNilRegardlessOfCurrent() {
        // Every group was left/removed, or this is a brand-new account with
        // none yet — `nil` here is exactly what makes `RootView`'s
        // `activeGroupSession.groups.isEmpty` gate show
        // `CreateOrJoinFirstGroupView` correctly; a stale non-nil id would
        // point at nothing.
        XCTAssertNil(ActiveGroupSession.resolveActiveGroupID(current: "anything", groups: []))
        XCTAssertNil(ActiveGroupSession.resolveActiveGroupID(current: nil, groups: []))
    }

    func testSingleGroupIsSelectedWhenNothingWasActive() {
        // The extremely common cold-start case (create-your-first-group,
        // or a fresh invite-accept in `CreateOrJoinFirstGroupView`) — one
        // group, nothing previously active, it becomes active.
        let groups = [group("only")]
        XCTAssertEqual(
            ActiveGroupSession.resolveActiveGroupID(current: nil, groups: groups),
            "only"
        )
    }
}
