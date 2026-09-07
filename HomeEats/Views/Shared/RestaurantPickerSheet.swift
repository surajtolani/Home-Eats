import SwiftUI
import SwiftData

struct RestaurantPickerSheet: View {
    let onPick: (Restaurant) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Restaurant.name) private var restaurants: [Restaurant]

    @State private var searchText = ""
    @State private var showNewRestaurantSheet = false

    private var filtered: [Restaurant] {
        searchText.isEmpty
            ? restaurants
            : restaurants.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            List {
                if filtered.isEmpty {
                    ContentUnavailableView(
                        "No Restaurants Yet",
                        systemImage: "fork.knife",
                        description: Text("Add the places your family likes to eat out.")
                    )
                }
                ForEach(filtered) { restaurant in
                    Button {
                        onPick(restaurant)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading) {
                            Text(restaurant.name).foregroundStyle(.primary)
                            if let cuisine = restaurant.cuisine, !cuisine.isEmpty {
                                Text(cuisine).font(.brandCaption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search restaurants")
            .navigationTitle("Choose a Restaurant")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        showNewRestaurantSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showNewRestaurantSheet) {
                RestaurantEditorView { restaurant in
                    onPick(restaurant)
                    dismiss()
                }
            }
        }
    }
}
