import SwiftUI
import SwiftData

struct RootView: View {
    /// `ActiveUserSession`/`FamilyMember` are the older "who's using the app
    /// right now on this shared device" concept this pivot's *gating* no
    /// longer keys off of (see `ActiveGroupSession`'s doc comment for the
    /// full reasoning) — but the concept itself is untouched and still very
    /// much alive: recipe/restaurant attribution
    /// (`RecipeEditorView`/`RecommendMealView`/`LogMealSheet`/...),
    /// `ActiveUserMenu`, `FamilyMembersView` (still linked from `MoreView`),
    /// and the old local Plan/Grocery screens this task preserves-but-
    /// unreferences all still read it. This `@Query` and the `.onAppear`
    /// below that seeds `activeUserSession` from it are kept exactly as
    /// they were pre-pivot, purely as a QoL nicety for whoever already has
    /// `FamilyMember`s from before this change (or adds one later via
    /// `FamilyMembersView`) — see this task's own final report for the full
    /// list of what still depends on this.
    @Query(sort: \FamilyMember.createdAt) private var familyMembers: [FamilyMember]
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var reminderRouter: PlanningReminderRouter
    @EnvironmentObject private var activeUserSession: ActiveUserSession
    /// Watched here (rather than reacting inside `AccountSession` itself,
    /// which has no `ModelContext` of its own to touch SwiftData with) so
    /// every sign-out — the explicit "Sign Out" tap in `SettingsView` *and*
    /// the automatic one `AccountsAPIClient` triggers on a `401` — is caught
    /// by the same `.onChange` below regardless of which path flipped
    /// `isSignedIn` to `false`. See `GroupSyncService.purgeAllLocalGroupData`'s
    /// own doc comment for why this purge has to happen at all.
    @EnvironmentObject private var accountSession: AccountSession
    /// Which group's shared plan/grocery list the main tabs render — the
    /// pivot's new organizing concept (see its own doc comment). Refreshed
    /// right after sign-in below, and what both the "you have no groups
    /// yet" gate and the group-scoped tab content read from.
    @EnvironmentObject private var activeGroupSession: ActiveGroupSession
    /// The signed-in caller's own pending-notifications feed — see its own
    /// doc comment. Refreshed right after sign-in below, on the same
    /// periodic cadence `GroupSharedMealPlanView`/`GroupSharedGroceryListView`
    /// already use for their own background resync, for as long as the app
    /// stays signed in (see `runNotificationsPollLoop()` below) — kept as
    /// ONE loop here, at the root, rather than one per tab: `GroupTopBar`'s
    /// notification bell is placed on both main tabs at once, and `TabView`
    /// keeps every tab's content alive simultaneously, so a per-tab loop
    /// would mean two independent, concurrently-running pollers for the
    /// exact same feed.
    @EnvironmentObject private var notificationsSession: NotificationsSession

    @State private var selectedTab: Tab = .plan

    enum Tab {
        case plan, recipes, restaurants, grocery, more
    }

    var body: some View {
        Group {
            // Accounts became mandatory: nobody gets past this screen
            // without signing in first (a real gate, not the earlier
            // opt-in "Sign In" row buried in Settings) — every account,
            // friend, group, and shared list depends on knowing who's
            // actually using the app, so that has to be settled before
            // anything else. `AccountSignInView(allowsCancel: false)` is
            // the exact same phone -> code -> profile flow used everywhere
            // else in the app (Settings' "Sign In" row, sharing a recipe
            // while signed out) — just embedded directly with nothing to
            // cancel back to, instead of presented as a dismissible
            // `.sheet`.
            //
            // Next: is this account's profile actually complete — first
            // name, last name, city, state, AND country, all five (see
            // `AccountUser.profileComplete` and routes/me.js's
            // `computeProfileComplete`)? This sits ABOVE the group-
            // membership check below it, not below, because it's the more
            // fundamental of the two: a group invite, a friend's display
            // name, a shared grocery list's "added by" line — all of it
            // assumes every participant actually has a name/location on
            // file, so nothing group-shaped should even be reachable until
            // that's settled. This is also what catches every account that
            // signed up BEFORE these fields became mandatory (including
            // this session's own earlier test accounts, and the one
            // person who verified-then-skipped the old, skippable name
            // step) the very next time they open the app — not just brand
            // new signups, which `AccountSignInView`'s own post-verify
            // check (see its `verify()`) already routes straight into the
            // identical form before `isSignedIn` even has a chance to make
            // this branch relevant. `ProfileCompletionStepView` is the same
            // shared five-field form either way (see that type's own doc
            // comment on why it's factored out instead of living only in
            // `AccountSignInView`) — wrapped here in this gate's own
            // `NavigationStack`/`Form` since, unlike `AccountSignInView`,
            // there's no surrounding sheet chrome to borrow, and no
            // Cancel/Skip toolbar action at all: this step is not
            // optional. `!accountSession.hasLoadedProfileOnce` (checked
            // first) is the exact same "avoid a one-frame flash while a
            // still-loading answer would have said something else" guard
            // as `!activeGroupSession.hasLoadedOnce` just below it — see
            // `AccountSession.hasLoadedProfileOnce`'s own doc comment.
            //
            // Below that, the gate used to be "do you have a `FamilyMember`
            // yet" (`OnboardingView`). This pivot replaces that with "do you
            // belong to a group yet" — a group, not a locally-named
            // household member, is now the thing the main Plan/Grocery tabs
            // are organized around (see `ActiveGroupSession`'s doc comment
            // for the full reasoning), so getting into one is the next
            // "only truly required setup step," right after (never before)
            // the profile itself is settled. The middle branch
            // (`!activeGroupSession.hasLoadedOnce`) exists only to avoid a
            // one-frame flash of "you have no groups" while the first
            // `GET /groups` call from the `.task` below is still in
            // flight — see `ActiveGroupSession.hasLoadedOnce`'s own doc
            // comment.
            if !accountSession.isSignedIn {
                AccountSignInView(allowsCancel: false)
            } else if !accountSession.hasLoadedProfileOnce {
                ProgressView("Loading your profile…")
            } else if accountSession.currentUser?.profileComplete == false {
                NavigationStack {
                    Form {
                        ProfileCompletionStepView()
                    }
                    .navigationTitle("Complete Your Profile")
                    .navigationBarTitleDisplayMode(.inline)
                }
            } else if !activeGroupSession.hasLoadedOnce {
                ProgressView("Loading your groups…")
            } else if activeGroupSession.groups.isEmpty {
                CreateOrJoinFirstGroupView()
            } else {
                // Tab order: Plan, Grocery, Recipes, Eating Out, More — per
                // direct user request to move Grocery into the 2nd position
                // (it used to be 4th, after Recipes and Eating Out). `Tab`'s
                // own case order below is unchanged on purpose: `selectedTab`
                // is compared by value everywhere it's read (`.tag`/
                // `.onChange` in `PlanningReminderRouter`'s handling further
                // down), never by position, so reordering the `TabView`'s
                // children here doesn't require touching the enum or
                // anything that switches on it.
                TabView(selection: $selectedTab) {
                    NavigationStack {
                        GroupScopedPlanTab()
                    }
                    .tabItem { Label("Plan", systemImage: "calendar") }
                    .tag(Tab.plan)

                    NavigationStack {
                        GroupScopedGroceryTab()
                    }
                    .tabItem { Label("Grocery", systemImage: "cart") }
                    .tag(Tab.grocery)

                    NavigationStack {
                        RecipesHomeView()
                    }
                    .tabItem { Label("Recipes", systemImage: "book.closed") }
                    .tag(Tab.recipes)

                    NavigationStack {
                        RestaurantListView()
                    }
                    .tabItem { Label("Eating Out", systemImage: "fork.knife") }
                    .tag(Tab.restaurants)

                    NavigationStack {
                        MoreView()
                    }
                    .tabItem { Label("More", systemImage: "ellipsis.circle") }
                    .tag(Tab.more)
                }
            }
        }
        .onAppear {
            if activeUserSession.activeMemberID == nil {
                activeUserSession.setActive(familyMembers.first)
            }
        }
        // Fetches the signed-in user's groups the moment sign-in completes
        // (and again on every relaunch that's already signed in, since
        // `.task(id:)` also runs on first appearance with whatever
        // `accountSession.isSignedIn`'s initial value already is — see
        // `AccountSession.init`'s own doc comment on that optimistic
        // initial value). Re-keying on `accountSession.isSignedIn` (rather
        // than a plain `.task { }` that only ever ran once) is what makes
        // this fire again after a sign-out/sign-in-as-someone-else cycle,
        // not just at app launch.
        .task(id: accountSession.isSignedIn) {
            guard accountSession.isSignedIn else { return }
            await activeGroupSession.refreshGroups()
        }
        // Separate `.task(id:)` from the one just above — SwiftUI runs each
        // independently, cancelling and restarting both together on the
        // same `accountSession.isSignedIn` transitions, so this fetch+poll
        // loop and the groups refresh above it never interfere with each
        // other's lifetime. See `notificationsSession`'s own doc comment for
        // why this loop lives here (once, at the root) rather than inside
        // `GroupTopBar`/its notification bell.
        .task(id: accountSession.isSignedIn) {
            guard accountSession.isSignedIn else { return }
            await notificationsSession.refresh()
            await runNotificationsPollLoop()
        }
        // Backs up the signed-in account's personal Restaurant/Recipe
        // libraries to the backend (and recovers anything the server has
        // that this device doesn't) the moment sign-in completes, and again
        // on every relaunch that's already signed in — same `.task(id:)`
        // re-keying reasoning as the two `.task`s just above. See
        // `PersonalLibrarySyncService`'s own doc comment for the full sync
        // design and why this exists at all (a real local-data-loss
        // incident). Then keeps re-running periodically for as long as the
        // app stays open — a plain `.task(id:)` alone only ever fires once
        // per sign-in session (it re-keys on `accountSession.isSignedIn`
        // *changing*, not on every recipe/restaurant edit made afterward),
        // and `RecipesHomeView`/`RestaurantListView` mounted inside
        // `RootView`'s always-alive `TabView` (see either's own doc
        // comment) means their own identical one-shot `.task` triggers
        // would otherwise only ever really fire once too, in practice —
        // so a mid-session edit could sit unsynced until the next full app
        // relaunch without this loop. A longer cadence than the group
        // screens' own 25-second periodic resync (this is durability/
        // recovery, not real-time collaboration with competing writers —
        // nothing here needs to feel instant).
        .task(id: accountSession.isSignedIn) {
            guard accountSession.isSignedIn else { return }
            await runPersonalLibrarySyncLoop()
        }
        .onChange(of: reminderRouter.shouldPresentPlanningFlow) { _, shouldPresent in
            guard shouldPresent else { return }
            // The weekly planning notification used to launch a separate
            // guided flow on top of this — now it just switches to the
            // Plan tab itself, which already puts today's inline day
            // panel front and center under the calendar.
            selectedTab = .plan
            reminderRouter.shouldPresentPlanningFlow = false
        }
        .onChange(of: accountSession.isSignedIn) { wasSignedIn, isSignedIn in
            // Only the true->false transition is a sign-out; false->true
            // (signing in) and the launch-time initial value (no "old"
            // value to compare against — `onChange` doesn't fire for it)
            // must never trigger this.
            guard wasSignedIn, !isSignedIn else { return }
            GroupSyncService.purgeAllLocalGroupData(modelContext: modelContext)
            // Piggybacks on this exact same sign-out trigger — see
            // `ActiveGroupSession.reset()`'s own doc comment for why this
            // has to happen here rather than be left for the next
            // `refreshGroups()` to naturally overwrite.
            activeGroupSession.reset()
            // Same reasoning, same trigger — see `NotificationsSession.reset()`'s
            // own doc comment.
            notificationsSession.reset()
        }
    }

    /// Same "plain `Task.sleep` loop, cancelled automatically when its
    /// `.task` is torn down" design, and the same 25-second cadence, as
    /// `GroupSharedMealPlanView`/`GroupSharedGroceryListView`'s own periodic
    /// resync loops (see either view's doc comment) — piggybacking on that
    /// established cadence for the notification badge too, rather than
    /// inventing a second, differently-tuned polling interval for no real
    /// reason.
    private func runNotificationsPollLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            if Task.isCancelled { break }
            await notificationsSession.refresh()
        }
    }

    /// Runs `PersonalLibrarySyncService.sync` once immediately, then every
    /// two minutes for as long as this `.task` stays alive — see that
    /// `.task`'s own comment for why a one-shot call alone isn't enough
    /// here. Same "plain `Task.sleep` loop, cancelled automatically when
    /// its `.task` is torn down" shape as `runNotificationsPollLoop` above,
    /// just a slower cadence.
    private func runPersonalLibrarySyncLoop() async {
        while !Task.isCancelled {
            await PersonalLibrarySyncService.sync(modelContext: modelContext)
            try? await Task.sleep(nanoseconds: 120_000_000_000)
        }
    }
}

// MARK: - Group-scoped main tabs

/// The main "Plan" tab's content — the active group's shared meal plan,
/// reactive to `activeGroupSession.activeGroupID` changing. This is
/// deliberately a thin wrapper around the *same* `GroupSharedMealPlanView`
/// that `GroupDetailView` already shows for one specific group (see that
/// view's own doc comment) — not a new, parallel implementation — now
/// promoted to being reached directly from a main tab instead of only via
/// a group's detail page, per this pivot's whole premise.
///
/// `.id(activeGroupSession.activeGroupID)` is what makes switching groups
/// actually take effect: `GroupSharedMealPlanView` captures its `groupID`
/// into its `@Query`'s `#Predicate` once, in its own `init` (see that
/// view's own comment on why), so simply handing it a new `groupID` string
/// on an unchanged view identity would *not* re-run that `init` or restart
/// its `.task` (the load-group/sync/periodic-resync loop) — SwiftUI would
/// just keep the original identity's already-initialized `@Query`/`@State`
/// around. Giving it a fresh `.id()` whenever the active group changes
/// instead tells SwiftUI to treat it as a brand new view: the old one is
/// torn down (cancelling its in-flight `.task`, including that periodic
/// resync loop) and a new one is built from scratch against the
/// newly-active group, right down to a fresh `#Predicate` and a fresh
/// initial sync. This happens *inside* the tab's own `NavigationStack`, not
/// by resetting the stack itself, so it's just this content view being
/// swapped — not a jarring pop back to some root or a lost place in a
/// pushed-into screen (there's nothing pushed on top of this tab's root to
/// lose in the first place).
private struct GroupScopedPlanTab: View {
    @EnvironmentObject private var activeGroupSession: ActiveGroupSession

    var body: some View {
        Group {
            if let group = activeGroupSession.activeGroup {
                GroupSharedMealPlanView(groupID: group.id, groupName: group.name)
                    .id(group.id)
            } else {
                // Defensive only — `RootView`'s own gating means this tab
                // is never shown at all while `activeGroupSession.groups`
                // is empty, and `refreshGroups()` always picks *some*
                // active group whenever `groups` is non-empty (see its own
                // doc comment). Still cheaper and clearer than a forced
                // unwrap for the split second between `groups` updating and
                // `activeGroupID` catching up to it.
                ContentUnavailableView(
                    "No Group Selected",
                    systemImage: "person.3",
                    description: Text("Choose a group from the circular icon above.")
                )
            }
        }
        // `GroupTopBar` — the shared static top row (group switcher on the
        // left, notification bell + account icon on the right) — see its
        // own doc comment. Replaces the plain `GroupSwitcherMenu()`
        // `ToolbarItem` this used to be; the Calendar/Weekly picker and "Go
        // to This Week" that used to live partly here, partly in
        // `GroupSharedMealPlanView`'s own toolbar, are now entirely inside
        // that view's own body, in the "row below" this bar — see that
        // view's own doc comment on the move.
        .toolbar {
            GroupTopBar()
        }
    }
}

/// The main "Grocery" tab's content — same idea as `GroupScopedPlanTab`
/// above, wrapping `GroupSharedGroceryListView` instead; see that type's own
/// doc comment for the full reasoning (not repeated here).
private struct GroupScopedGroceryTab: View {
    @EnvironmentObject private var activeGroupSession: ActiveGroupSession

    var body: some View {
        Group {
            if let group = activeGroupSession.activeGroup {
                GroupSharedGroceryListView(groupID: group.id, groupName: group.name)
                    .id(group.id)
            } else {
                ContentUnavailableView(
                    "No Group Selected",
                    systemImage: "person.3",
                    description: Text("Choose a group from the circular icon above.")
                )
            }
        }
        // Same `GroupTopBar` as `GroupScopedPlanTab` above — see its own doc
        // comment. The "+"/"Manage My Layout" controls that used to live in
        // `GroupSharedGroceryListView`'s own toolbar moved into that view's
        // own body instead, in the row below this bar.
        .toolbar {
            GroupTopBar()
        }
    }
}
