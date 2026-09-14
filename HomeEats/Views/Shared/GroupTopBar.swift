import SwiftUI

/// The shared static top bar for both group-scoped main tabs
/// (`GroupScopedPlanTab`/`GroupScopedGroceryTab` in RootView.swift) — a
/// single `ToolbarContent` used identically by both, per direct user
/// request for the top-bar redesign: "there should probably also be a
/// notification icon at the top right next to the logo — the logo 'row'
/// should be static with just a small circular icon on the left to select
/// your group (should be able to also add a new group directly from here)
/// and then on the top right there should just be notification icon (with
/// a counter depending on number of notifications) and an 'account' icon.
/// All the other things like go to week or share or heart or anything else
/// should go in a 'row' below."
///
/// This IS that static row — it's the actual `NavigationStack` nav bar
/// (via `ToolbarItem`s), which iOS already keeps pinned in place while the
/// content below it scrolls, so nothing extra is needed to make it "static."
/// Everything screen-specific that used to live in
/// `GroupSharedMealPlanView`'s/`GroupSharedGroceryListView`'s own `.toolbar`
/// (the Calendar/Weekly picker's "Go to This Week" button, the grocery
/// list's "+"/"Manage My Layout" controls) moved OUT of the nav bar and into
/// each of those views' own body content instead, directly under where this
/// bar renders — see each view's own doc comment on that move for why.
/// Nothing screen-specific is declared here on purpose: this bar renders
/// identically regardless of which of the two tabs it's attached to.
///
/// A plain `ToolbarContent`, not a `View` — `RootView`'s
/// `GroupScopedPlanTab`/`GroupScopedGroceryTab` each place this via
/// `.toolbar { GroupTopBar() }`, the same way `GroupSwitcherMenu` used to be
/// placed as a single `ToolbarItem` directly; this just groups what's now
/// three `ToolbarItem`s (leading switcher, trailing bell, trailing account)
/// into one reusable unit instead of duplicating all three at both call
/// sites.
struct GroupTopBar: ToolbarContent {
    var body: some ToolbarContent {
        // The app's own logo, centered — not the active group's name. Each
        // screen still sets its own `.navigationTitle(group.name)` (needed
        // for the back button when pushed into from elsewhere, e.g.
        // `GroupDetailView`'s "Meal Plan"/"Grocery List" links, which reach
        // these same two views *without* `GroupTopBar` and so still show
        // that group's actual name as their title/principal content — this
        // `.principal` item only overrides what's visually shown on the two
        // main tabs specifically), but on the main Plan/Grocery tabs the
        // group you're looking at is already obvious from the circular
        // switcher icon right next to this — repeating it again as the big
        // centered title was redundant, and switching groups made that
        // title change felt like a different screen rather than the same
        // one now showing different data. Same `BrandHeaderBanner` every
        // other tab's root screen already uses in this exact slot (see its
        // own doc comment) — Plan/Grocery just hadn't been given it yet,
        // since they used to rely on `.navigationTitle` alone before this
        // bar's `.principal` item existed to override it.
        ToolbarItem(placement: .principal) {
            BrandHeaderBanner()
        }
        ToolbarItem(placement: .topBarLeading) {
            GroupSwitcherMenu()
        }
        ToolbarItem(placement: .topBarTrailing) {
            NotificationBellButton()
        }
        ToolbarItem(placement: .topBarTrailing) {
            // A shortcut straight to "My Account" (`SettingsView`) — per the
            // same user request, an account icon belongs right here so
            // reaching it doesn't require going through the "More" tab,
            // which is where `MoreView`'s own identical `NavigationLink` to
            // `SettingsView` still lives too (this is a second, faster path
            // to the same screen, not a replacement for that one).
            NavigationLink {
                SettingsView()
            } label: {
                Image(systemName: "person.crop.circle")
            }
            .accessibilityLabel("My Account")
        }
    }
}

/// The notification bell + numeric badge. Reads `NotificationsSession.count`
/// rather than fetching anything itself — `RootView` is what actually
/// refreshes that shared object (on sign-in, and on a periodic loop for as
/// long as the app is signed in; see its own doc comment), so this button
/// stays a plain, stateless reflection of whatever the session's last
/// successful fetch found, with no polling loop of its own to duplicate.
/// That matters because `GroupTopBar` is placed on BOTH main tabs at once —
/// `TabView` keeps every tab's content alive simultaneously, so if this
/// button owned its own periodic-refresh `.task` (mirroring
/// `GroupSharedMealPlanView`'s pattern verbatim), there would be two such
/// loops running concurrently the whole time the app is open, each polling
/// `GET /notifications` independently for no benefit over one. Tapping it
/// pushes `NotificationsView`.
private struct NotificationBellButton: View {
    @EnvironmentObject private var notificationsSession: NotificationsSession

    var body: some View {
        NavigationLink {
            NotificationsView()
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "bell")
                if notificationsSession.count > 0 {
                    Text(badgeText)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(Circle().fill(Color.red))
                        .offset(x: 10, y: -10)
                }
            }
        }
        .accessibilityLabel("Notifications, \(notificationsSession.count) pending")
    }

    private var badgeText: String {
        notificationsSession.count > 9 ? "9+" : "\(notificationsSession.count)"
    }
}
