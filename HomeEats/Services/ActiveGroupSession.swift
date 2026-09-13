import Foundation

/// Tracks "which group's plan/grocery list am I currently looking at" — the
/// pivot's central new piece of state. Before this, the main Plan/Grocery
/// tabs rendered purely personal, local data; now they render whichever
/// group is "active", the same way `GroupSharedMealPlanView`/
/// `GroupSharedGroceryListView` already rendered *a* group's shared plan/
/// list when reached from that group's own detail page (see those views'
/// doc comments) — this object is just what decides *which* group that is
/// for the main tabs, plus a switcher to change it.
///
/// Deliberately a separate object from `AccountSession` (which owns
/// `isSignedIn`/`currentUser` — see its own doc comment) and from
/// `ActiveUserSession` (which is a different, older concept this pivot is
/// replacing as the app's gating/attribution mechanism — see
/// `ActiveUserSession`'s doc comment and this task's own notes on what
/// still depends on it). `ObservableObject`/`@Published` to match both of
/// those objects' established pattern, so the app keeps one consistent way
/// to declare a session object injected via `.environmentObject(...)` in
/// `HomeEatsApp.swift`.
///
/// **No local model, same reasoning as `GroupsListView`'s own doc
/// comment**: `groups` is never persisted to SwiftData — the backend is the
/// sole source of truth for group membership, and `refreshGroups()` just
/// calls straight through to `AccountsAPIClient.getGroups()` on demand. The
/// one thing that *is* worth remembering locally is which group the person
/// was last looking at — not because it's sensitive, purely because
/// reopening the app and losing your place would be annoying — so only
/// `activeGroupID` is persisted, in `UserDefaults`, the same low-stakes
/// storage choice `ActiveUserSession` already makes for the same reason
/// (contrast with `KeychainTokenStore`, which is where this app keeps
/// anything that actually needs to be kept secret).
@MainActor
final class ActiveGroupSession: ObservableObject {
    private static let storageKey = "activeGroupID"

    /// Every group the signed-in caller belongs to, as of the last
    /// successful `refreshGroups()` call. `private(set)`: nothing outside
    /// this object should be able to invent a group that didn't actually
    /// come back from the server — the only way this list changes is by
    /// re-fetching it.
    @Published private(set) var groups: [GroupSummary] = []

    /// Whether `refreshGroups()` has completed at least once (successfully
    /// or not) since this object was created. `RootView` reads this to show
    /// a brief loading state instead of jumping straight to "you have no
    /// groups" for the split second right after sign-in, before the first
    /// `GET /groups` call has actually come back — see `RootView`'s own
    /// gating comment for why that distinction matters (a real "create or
    /// join a group" screen flashing on screen for a frame, before
    /// immediately being replaced by the real group's content, would read
    /// as a bug even though the end state is correct).
    @Published private(set) var hasLoadedOnce = false

    /// Which group's plan/grocery list the main tabs currently render.
    /// Unlike `groups`, this is freely settable from outside — that's
    /// exactly what the group-switcher toolbar control (`GroupSwitcherMenu`)
    /// does — and it's the one piece of this object's state that's actually
    /// persisted (see the type's own doc comment on why).
    @Published var activeGroupID: String? {
        didSet {
            guard oldValue != activeGroupID else { return }
            if let activeGroupID {
                UserDefaults.standard.set(activeGroupID, forKey: Self.storageKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.storageKey)
            }
        }
    }

    init() {
        activeGroupID = UserDefaults.standard.string(forKey: Self.storageKey)
    }

    /// The full `GroupSummary` for `activeGroupID`, or `nil` if nothing's
    /// active yet (before the first `refreshGroups()`) or the active id
    /// somehow isn't in `groups` (shouldn't happen in practice — every path
    /// that sets `activeGroupID` either comes from `groups` itself or is
    /// immediately followed by a `refreshGroups()` that reconciles it, per
    /// that method's own doc comment — but a `nil` here is a safe, inert
    /// fallback rather than a crash if it ever does).
    var activeGroup: GroupSummary? {
        guard let activeGroupID else { return nil }
        return groups.first(where: { $0.id == activeGroupID })
    }

    /// Re-fetches the caller's groups from the server and reconciles
    /// `activeGroupID` against the fresh list. Called right after sign-in
    /// (see `RootView`'s `.task(id: accountSession.isSignedIn)`), after
    /// creating or joining a group for the first time
    /// (`CreateOrJoinFirstGroupView`), and by the periodic re-sync nothing
    /// here does but a future task reasonably could (this v1 only refreshes
    /// on those explicit triggers, not on a timer — the *group's own*
    /// content, once you're inside `GroupSharedMealPlanView`/
    /// `GroupSharedGroceryListView`, already re-syncs itself on its own
    /// periodic loop; this list of *which groups exist at all* changes far
    /// less often, on the order of "someone invited me", so refreshing it
    /// only on those specific triggers is enough for v1).
    ///
    /// Picking a default when the current `activeGroupID` is nil or stale
    /// (a group that's gone — left, removed, whatever) is deliberately
    /// simple: fall back to the first group in whatever order the server
    /// returned (`GET /groups`, unsorted beyond that), or `nil` if there
    /// are none. There's no "most recently used" or "alphabetical" logic
    /// here — with typically a small handful of groups, and a manual
    /// switcher always one tap away, that would be more machinery than the
    /// problem calls for.
    func refreshGroups() async {
        defer { hasLoadedOnce = true }
        // A failed fetch (offline, expired session about to get signed out
        // by `AccountsAPIClient`'s 401 handling, ...) leaves `groups`/
        // `activeGroupID` exactly as they were — same "just leave it, the
        // next screen that actually needs fresh data has its own error
        // handling" reasoning as `AccountSession.refreshCurrentUser()`. The
        // main tabs then keep showing the last group they successfully
        // loaded, which is a far better failure mode than bouncing back to
        // "you have no groups" on a transient network blip.
        guard let fetched = try? await AccountsAPIClient.getGroups() else { return }
        groups = fetched
        activeGroupID = Self.resolveActiveGroupID(current: activeGroupID, groups: fetched)
    }

    /// The actual "which group should be active" decision, factored out as
    /// a plain, `async`-free static function purely so it's unit-testable
    /// without needing to fake a network call — see
    /// `ActiveGroupSessionTests` for the table-driven cases this covers
    /// (current id still present -> unchanged; current id gone or nil ->
    /// first in the list; empty list -> `nil`). `refreshGroups()` above is
    /// the only real caller; this is deliberately `internal`, not
    /// `private`, so the test target can call it directly. `nonisolated`
    /// because it touches no actor-isolated state at all (plain value types
    /// in, plain value type out) — without that, this static member of a
    /// `@MainActor` class would inherit that isolation and force every
    /// caller, including a synchronous `XCTestCase` test method, to `await`
    /// it for no real reason.
    nonisolated static func resolveActiveGroupID(current: String?, groups: [GroupSummary]) -> String? {
        if let current, groups.contains(where: { $0.id == current }) {
            return current
        }
        return groups.first?.id
    }

    /// Clears every published property — called from `RootView`'s existing
    /// `.onChange(of: accountSession.isSignedIn)` sign-out handler,
    /// piggybacking on the exact same trigger `GroupSyncService
    /// .purgeAllLocalGroupData` already uses to wipe locally-cached
    /// group-sync rows on sign-out (see that method's own doc comment).
    /// Without this, signing out and back in as a different account would
    /// briefly show the *previous* account's groups (and could even try to
    /// select one of its group ids as active) until the next
    /// `refreshGroups()` call overwrote it — a real information leak
    /// between accounts on a shared device, not just a cosmetic glitch.
    func reset() {
        groups = []
        activeGroupID = nil
        hasLoadedOnce = false
    }
}
