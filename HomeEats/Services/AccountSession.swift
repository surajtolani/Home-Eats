import Foundation

/// The signed-in state of the *account* system — phone-number sign-in,
/// friends, groups, and recipe sharing (see backend/README.md's "Accounts,
/// friends, and groups" and "Recipe sharing" sections). Deliberately a
/// separate object from `ActiveUserSession` (which tracks "who's using the
/// app right now" among local, unauthenticated `FamilyMember`s on a shared
/// household device, stored in SwiftData) — that job is unchanged by this
/// one. Signing in itself is no longer optional: `RootView` gates the
/// entire app behind `isSignedIn`, since every account/friend/group/shared
/// list feature needs to know who's actually using the app before anything
/// else can work. `isSignedIn` still starts `false` at launch (until the
/// stored-token check in `init` below resolves it), which is exactly what
/// makes that gate work — this object doesn't know or care that it's
/// mandatory now, `RootView` is what enforces that.
///
/// `ObservableObject`/`@Published` (rather than the `@Observable` macro) to
/// match `ActiveUserSession`'s own pattern — see its doc comment — so the
/// app has one consistent way to declare a session object, and so this
/// injects into the environment via `.environmentObject(...)` exactly like
/// `ActiveUserSession` and `PlanningReminderRouter` already do in
/// `HomeEatsApp.swift`.
@MainActor
final class AccountSession: ObservableObject {
    @Published private(set) var isSignedIn: Bool
    @Published private(set) var currentUser: AccountUser?
    /// Whether this app has learned the signed-in caller's real profile at
    /// least once (successfully or not) since sign-in — either through
    /// `completeSignIn` (immediate, no network wait: `POST /auth/verify-code`
    /// already handed back the full profile) or through `refreshCurrentUser`
    /// resolving at launch. `RootView`'s completion gate reads this the same
    /// way it already reads `ActiveGroupSession.hasLoadedOnce` for the group
    /// check just below it in that same gating chain: without it, the split
    /// second between "a stored token means isSignedIn optimistically starts
    /// true" (see `init` below) and `refreshCurrentUser()` actually
    /// resolving would show the mandatory profile-completion screen to a
    /// perfectly complete, already-signed-in account for one frame, purely
    /// because `currentUser` hadn't loaded yet — exactly the kind of flash
    /// that doc comment on `ActiveGroupSession.hasLoadedOnce` calls out.
    @Published private(set) var hasLoadedProfileOnce = false

    init() {
        // A stored token means "signed in" optimistically, before this app
        // has even confirmed with the backend that the token still works —
        // `refreshCurrentUser()` below fills in `currentUser` moments
        // later, and if the token turns out to be expired/invalid,
        // `AccountsAPIClient`'s 401 handling calls `signOut()` right back.
        // The alternative (waiting on that network round-trip before ever
        // showing "signed in") would mean every launch briefly flashes a
        // signed-out "Sign In" row before flipping to the real state, which
        // is worse for the overwhelmingly common case where the token is
        // still perfectly valid.
        let hasStoredToken = KeychainTokenStore.readToken() != nil
        isSignedIn = hasStoredToken
        currentUser = nil

        // Wires this instance into `AccountsAPIClient` so a 401 from *any*
        // authenticated call, made from any view, can sign the user out
        // immediately — see `AccountsAPIClient.session`'s own doc comment
        // for why this centralized back-reference beats every call site
        // individually catching `.unauthorized`.
        AccountsAPIClient.session = self

        if hasStoredToken {
            Task { await refreshCurrentUser() }
        }
    }

    /// Fills in `currentUser` from `GET /me` — called once at launch (see
    /// `init`) and again after sign-in completes. A failure here (including
    /// a 401, which separately triggers `signOut()` via `AccountsAPIClient`)
    /// just leaves `currentUser` as whatever it already was; there's no
    /// dedicated error UI for this specific background refresh, since
    /// nothing the user directly tapped triggered it — the next screen that
    /// actually needs fresh data (`FriendsListView`, `GroupsListView`, ...)
    /// has its own loading/error handling for that.
    func refreshCurrentUser() async {
        guard isSignedIn else { return }
        // `defer` (not set only on success): a failed fetch still counts as
        // "we tried" for `hasLoadedProfileOnce`'s purpose — same reasoning
        // as `ActiveGroupSession.refreshGroups()`'s own `defer { hasLoadedOnce
        // = true }`. Getting this wrong (only setting it on success) would
        // leave a signed-in account stuck on `RootView`'s "Loading your
        // profile…" spinner forever the moment this one call fails offline,
        // instead of falling through to whatever `currentUser` already was
        // (`nil` here, which that gate treats as "can't confirm incomplete,
        // don't block" — see `RootView`'s own doc comment).
        defer { hasLoadedProfileOnce = true }
        currentUser = try? await AccountsAPIClient.getMe()
    }

    /// Called by `AccountSignInView` the moment `POST /auth/verify-code`
    /// succeeds — stores the token (Keychain, not `UserDefaults`; see
    /// `KeychainTokenStore`'s doc comment for why) and flips every
    /// `@Published` property that gates the rest of the app's account UI.
    func completeSignIn(token: String, user: AccountUser) {
        KeychainTokenStore.saveToken(token)
        currentUser = user
        isSignedIn = true
        // Already known for certain — `user` here IS this account's current
        // profile, straight from `POST /auth/verify-code`'s response, not a
        // guess pending a separate `GET /me` — so there's no "still loading"
        // moment for `RootView`'s completion gate to wait out here.
        hasLoadedProfileOnce = true
    }

    /// Reflects a display name change from `PATCH /me` (the post-sign-in
    /// name prompt in `AccountSignInView`, or a future profile editor)
    /// without a full extra `GET /me` round-trip — the response from
    /// `PATCH /me` already carries the updated user.
    func updateCurrentUser(_ user: AccountUser) {
        currentUser = user
    }

    /// Clears the stored token and every published field. Called both from
    /// an explicit "Sign Out" tap (`SettingsView`) and automatically by
    /// `AccountsAPIClient` the moment any authenticated call comes back
    /// `401` — either way the end state is identical, so both paths share
    /// this one method rather than duplicating the reset logic.
    func signOut() {
        KeychainTokenStore.deleteToken()
        currentUser = nil
        isSignedIn = false
        // Reset so a later sign-in (as the same or a different account)
        // goes through the normal "not loaded yet" spinner in `RootView`
        // again, rather than this flag still reading `true` from the
        // previous account and momentarily showing THAT account's stale
        // completeness state before the new `GET /me`/verify-code response
        // comes back — same "don't leak state across accounts" reasoning as
        // `ActiveGroupSession.reset()` resetting its own `hasLoadedOnce`.
        hasLoadedProfileOnce = false
    }
}
