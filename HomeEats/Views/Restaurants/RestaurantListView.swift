import SwiftUI
import SwiftData
import MapKit

struct RestaurantListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Restaurant.name) private var restaurants: [Restaurant]

    @State private var showEditor = false
    @State private var searchText = ""
    @StateObject private var searchModel = RestaurantSearchModel()

    private var isSearchActive: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        List {
            if isSearchActive {
                searchResultsSection
            }

            if restaurants.isEmpty && !isSearchActive {
                ContentUnavailableView(
                    "No Restaurants Yet",
                    systemImage: "fork.knife",
                    description: Text("Search above to find a place and add it, or add one manually from the toolbar.")
                )
            } else if !restaurants.isEmpty {
                Section {
                    ForEach(restaurants) { restaurant in
                        NavigationLink {
                            RestaurantDetailView(restaurant: restaurant)
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
                        for index in offsets {
                            let restaurant = restaurants[index]
                            CascadeCleanup.removeReferences(toRestaurantID: restaurant.id, in: modelContext)
                            modelContext.delete(restaurant)
                        }
                    }
                } header: {
                    Text("Your Restaurants")
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search for a restaurant to add")
        .onChange(of: searchText) { _, newValue in
            searchModel.search(newValue)
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
    }

    private var searchResultsSection: some View {
        Section {
            if searchModel.isSearching && searchModel.results.isEmpty {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else if let errorMessage = searchModel.errorMessage {
                Text(errorMessage).foregroundStyle(.secondary)
            } else if searchModel.results.isEmpty {
                Text("No matches found.").foregroundStyle(.secondary)
            } else {
                ForEach(Array(searchModel.results.enumerated()), id: \.offset) { _, item in
                    SearchResultRow(item: item) {
                        addFromSearch(item)
                    }
                }
            }
        } header: {
            Text("Search Results")
        } footer: {
            Text("Powered by Apple's local search — free, no account needed. Tap the ⊕ on a result to add it.")
        }
    }

    private func addFromSearch(_ item: MKMapItem) {
        let restaurant = Restaurant(
            name: item.name ?? "Unnamed Restaurant",
            cuisine: cuisineLabel(for: item),
            websiteURL: item.url?.absoluteString,
            address: item.placemark.title
        )
        modelContext.insert(restaurant)
        searchText = ""
        searchModel.clear()
    }

    /// Turns MapKit's point-of-interest category (e.g. "MKPOICategoryBakery")
    /// into a readable label ("Bakery") for the restaurant's cuisine field.
    /// The generic "Restaurant" category isn't useful as a label, so that
    /// one is left blank rather than shown.
    private func cuisineLabel(for item: MKMapItem) -> String? {
        guard let category = item.pointOfInterestCategory else { return nil }
        let raw = category.rawValue.replacingOccurrences(of: "MKPOICategory", with: "")
        guard raw != "Restaurant", !raw.isEmpty else { return nil }
        var spaced = ""
        for (index, character) in raw.enumerated() {
            if index > 0, character.isUppercase { spaced.append(" ") }
            spaced.append(character)
        }
        return spaced
    }
}

private struct SearchResultRow: View {
    let item: MKMapItem
    let onAdd: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name ?? "Unknown")
                if let address = item.placemark.title {
                    Text(address)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button(action: onAdd) {
                Image(systemName: "plus.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
        }
    }
}

/// Searches Apple's (free, no API key) local-search index for places
/// matching the query, so the user can find a real restaurant and add it
/// with one tap instead of typing everything by hand.
@MainActor
final class RestaurantSearchModel: ObservableObject {
    @Published var results: [MKMapItem] = []
    @Published var isSearching = false
    @Published var errorMessage: String?

    private var searchTask: Task<Void, Never>?

    func search(_ query: String) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            results = []
            errorMessage = nil
            return
        }
        searchTask = Task {
            // Small debounce so we're not firing a search on every keystroke.
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }

            isSearching = true
            errorMessage = nil
            defer { isSearching = false }

            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = trimmed
            request.resultTypes = .pointOfInterest
            do {
                let response = try await MKLocalSearch(request: request).start()
                guard !Task.isCancelled else { return }
                results = response.mapItems
            } catch {
                guard !Task.isCancelled else { return }
                results = []
                errorMessage = "Couldn't search right now — check your connection."
            }
        }
    }

    func clear() {
        searchTask?.cancel()
        results = []
        errorMessage = nil
    }
}
