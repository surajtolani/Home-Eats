import SwiftUI

struct MoreView: View {
    var body: some View {
        List {
            // "My Account" first (was "Settings", further down the list) —
            // it's where sign-in identity, profile, friends, and groups all
            // live now that accounts are mandatory (see SettingsView's own
            // doc comment), which makes it the thing most worth surfacing
            // first here rather than after less-central items.
            //
            // "Family Members" — the old "who's using the app right now on
            // this shared device" concept — no longer has its own entry
            // point here at all: every person who matters is now a member
            // of a group (see `ActiveGroupSession`'s doc comment for the
            // full group pivot), so a separate, disconnected Family Members
            // list next to it would just be a second, confusing roster of
            // people. `FamilyMembersView`/`FamilyMember` themselves are left
            // untouched (still read by recipe/restaurant attribution
            // elsewhere — see RootView's own doc comment) — only this entry
            // point into managing them is removed.
            NavigationLink {
                SettingsView()
            } label: {
                Label("My Account", systemImage: "person.crop.circle")
            }
            // Split out from "My Account" into their own top-level rows —
            // direct fix for a real gap: "Friends" and "Groups" used to
            // live nested two screens deep (More -> My Account -> "Friends
            // & Groups"), which read as account-management chores rather
            // than the day-to-day destinations most people are actually
            // looking for. Still the exact same `FriendsListView`/
            // `GroupsListView` screens SettingsView used to link to — see
            // that view's own doc comment.
            NavigationLink {
                GroupsListView()
            } label: {
                Label("My Groups", systemImage: "person.3")
            }
            NavigationLink {
                FriendsListView()
            } label: {
                Label("My Friends", systemImage: "person.2")
            }
            NavigationLink {
                MealHistoryView()
            } label: {
                Label("Meal History", systemImage: "clock.arrow.circlepath")
            }
        }
        .navigationTitle("More")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                BrandHeaderBanner()
            }
        }
    }
}
