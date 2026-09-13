import Foundation

/// The signed-in state of the *account* system — phone-number sign-in,
/// friends, groups, and recipe sharing (see backend/README.md's "Accounts,
/// friends, and groups" and "Recipe sharing" sections). Deliberately a
/// separate object from `ActiveUserSession` (which tracks "who's using the
/// app right now" among local, unauthenticated `FamilyMember`s on a shared
/// household device, stored in SwiftData): per this feature's design,
/// accounts are opt-in on top of an app that has always worked fully
/// offline with no sign-in at all, so nothing about `ActiveUserSession`'s
/// existing job changes, and this object's `isSignedIn` starts `false` for
/// everyone until they explicitly choose to sign in.
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
    }
}
