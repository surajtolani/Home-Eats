import Foundation

/// The signed-in caller's own "things waiting on my response" feed —
/// `GET /notifications` (Phase 5, Part 3; see routes/notifications.js and
/// backend/README.md's "Notifications" section). Exists as its own shared
/// object, rather than each screen fetching independently, so the
/// notification bell's badge (`GroupTopBar`) and `NotificationsView`'s full
/// list always agree — both read the same `feed`, refreshed by the same
/// calls, instead of two independently-timed copies of the same data that
/// could show a stale badge next to an already-answered list or vice versa.
///
/// `ObservableObject`/`@Published`, injected via `.environmentObject(...)`
/// in `HomeEatsApp.swift` — same established pattern as `AccountSession`/
/// `ActiveGroupSession` (see either's own doc comment for why this codebase
/// keeps one consistent shape for session-like objects rather than the
/// newer `@Observable` macro).
///
/// **No local model, same reasoning as `FriendsListView`'s/
/// `ActiveGroupSession`'s own doc comments**: this is a live view onto
/// server-side pending state (an incoming friend request, a group invite) —
/// there's no offline-editing story for it (you can't usefully "accept a
/// friend request" while offline, since it's a write to a server-side
/// account either way), so there's nothing here worth persisting locally.
@MainActor
final class NotificationsSession: ObservableObject {
    @Published private(set) var feed: NotificationsFeed?

    /// The bell's badge number — `0` (no badge shown) until the first
    /// successful `refresh()`, same "nothing to show yet, not an error"
    /// treatment every other count-shaped property in this app's sibling
    /// session objects gives its own "not loaded yet" state.
    var count: Int { feed?.count ?? 0 }

    /// Re-fetches `GET /notifications`. Never throws — mirrors
    /// `ActiveGroupSession.refreshGroups()`'s own "a failed background fetch
    /// just leaves things as they were" reasoning: a badge that briefly
    /// can't reach the server should keep showing its last-known count
    /// rather than snapping to zero (which would read as "nothing pending"
    /// — actively wrong — instead of "couldn't check just now"). Called from
    /// `RootView`'s sign-in `.task` and its periodic poll loop (piggybacking
    /// on the same 25-second cadence `GroupSharedMealPlanView`/
    /// `GroupSharedGroceryListView` already use for their own background
    /// resync — see either view's doc comment), and from
    /// `NotificationsView`'s own `.task`/`.refreshable`.
    func refresh() async {
        guard let fetched = try? await AccountsAPIClient.getNotifications() else { return }
        feed = fetched
    }

    /// Called on sign-out (`RootView`'s existing `.onChange(of:
    /// accountSession.isSignedIn)` handler, the same trigger
    /// `ActiveGroupSession.reset()`/`GroupSyncService.purgeAllLocalGroupData`
    /// already piggyback on for the identical reason) — without this, a
    /// stale badge count left over from the previous account could flash on
    /// a shared device's next sign-in, for the moment before the first
    /// post-sign-in `refresh()` overwrites it.
    func reset() {
        feed = nil
    }
}
