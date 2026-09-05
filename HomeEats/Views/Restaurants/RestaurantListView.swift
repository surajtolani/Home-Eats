import SwiftUI
import SwiftData

struct RestaurantListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Restaurant.name) private var restaurants: [Restaurant]

    @State private var showEditor = false
    @State private var editingRestaurant: Restaurant?

    var body: some View {
        List {
            if restaurants.isEmpty {
                ContentUnavailableView(
                    "No Restaurants Yet",
                    systemImage: "fork.knife",
                    description: Text("Add the places your family likes to eat out, so they're ready to assign to any day.")
                )
            }
            ForEach(restaurants) { restaurant in
                Button {
                    editingRestaurant = restaurant
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            HStack {
                                Text(restaurant.name).foregroundStyle(.primary)
                                if restaurant.isFavorite {
                                    Image(systemName: "star.fill").foregroundStyle(.yellow).font(.caption)
                                }
                            }
                            if let cuisine = restaurant.cuisine, !cuisine.isEmpty {
                                Text(cuisine).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                }
            }
            .onDelete { offsets in
                for index in offsets { modelContext.delete(restaurants[index]) }
            }
        }
        .navigationTitle("Eating Out")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showEditor = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showEditor) {
            RestaurantEditorView()
        }
        .sheet(item: $editingRestaurant) { restaurant in
            RestaurantEditorView(existing: restaurant)
        }
    }
}
