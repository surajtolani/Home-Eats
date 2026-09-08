import SwiftUI

struct MoreView: View {
    var body: some View {
        List {
            NavigationLink {
                FamilyMembersView()
            } label: {
                Label("Family Members", systemImage: "person.2")
            }
            NavigationLink {
                MealHistoryView()
            } label: {
                Label("Meal History", systemImage: "clock.arrow.circlepath")
            }
            NavigationLink {
                SettingsView()
            } label: {
                Label("Settings", systemImage: "gearshape")
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
