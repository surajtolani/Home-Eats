import SwiftUI
import SwiftData

struct RootView: View {
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
            // anything else, including the app's own local onboarding
            // below. `AccountSignInView(allowsCancel: false)` is the exact
            // same phone -> code -> name flow used everywhere else in the
            // app (Settings' "Sign In" row, sharing a recipe while signed
            // out) — just embedded directly with nothing to cancel back to,
            // instead of presented as a dismissible `.sheet`.
            if !accountSession.isSignedIn {
                AccountSignInView(allowsCancel: false)
            } else if familyMembers.isEmpty {
                OnboardingView()
            } else {
                TabView(selection: $selectedTab) {
                    NavigationStack {
                        CalendarPlanView()
                    }
                    .tabItem { Label("Plan", systemImage: "calendar") }
                    .tag(Tab.plan)

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
                        GroceryListView()
                    }
                    .tabItem { Label("Grocery", systemImage: "cart") }
                    .tag(Tab.grocery)

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
        }
    }
}
