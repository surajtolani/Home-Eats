import SwiftUI
import SwiftData

struct RootView: View {
    @Query(sort: \FamilyMember.createdAt) private var familyMembers: [FamilyMember]
    @EnvironmentObject private var reminderRouter: PlanningReminderRouter
    @EnvironmentObject private var activeUserSession: ActiveUserSession

    @State private var selectedTab: Tab = .plan

    enum Tab {
        case plan, recipes, restaurants, grocery, more
    }

    var body: some View {
        Group {
            if familyMembers.isEmpty {
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
    }
}
