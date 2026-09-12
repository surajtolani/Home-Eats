import SwiftUI
import SwiftData
import MapKit
import CoreLocation

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
                                RestaurantThumbnail(googlePhotoName: restaurant.googlePhotoName, size: 44)
                                VStack(alignment: .leading) {
                                    HStack {
                                        Text(restaurant.name).foregroundStyle(.primary)
                                        if restaurant.isFavorite {
                                            Image(systemName: "star.fill").foregroundStyle(.yellow).font(.brandCaption)
                                        }
                                    }
                                    if let descriptorLine = restaurant.descriptorLine {
                                        Text(descriptorLine).font(.brandCaption).foregroundStyle(.secondary)
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
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                BrandHeaderBanner()
            }
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
                ForEach(searchModel.results) { result in
                    SearchResultRow(result: result) {
                        addFromSearch(result)
                    }
                }
            }
        } header: {
            Text("Search Results")
        } footer: {
            Text(
                GooglePlacesService.isConfigured
                    ? "Powered by Google — includes rating, price, and cuisine. Tap the ⊕ on a result to add it."
                    : "Powered by Apple's local search — free, no account needed. Tap the ⊕ on a result to add it."
            )
        }
    }

    private func addFromSearch(_ result: RestaurantSearchModel.Result) {
        let restaurant = Restaurant(
            name: result.name,
            cuisine: result.cuisine,
            priceRange: result.priceRange,
            rating: result.rating.map { Int($0.rounded()) },
            websiteURL: result.mapsURLString,
            address: result.address,
            googlePhotoName: result.photoName,
            googlePlaceID: result.isGoogleSourced ? result.id : nil,
            latitude: result.coordinate?.latitude,
            longitude: result.coordinate?.longitude
        )
        modelContext.insert(restaurant)
        searchText = ""
        searchModel.clear()
    }
}

private struct SearchResultRow: View {
    let result: RestaurantSearchModel.Result
    let onAdd: () -> Void

    var body: some View {
        HStack {
            RestaurantThumbnail(googlePhotoName: result.photoName, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.name)
                if let address = result.address {
                    Text(address)
                        .font(.brandCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button(action: onAdd) {
                Image(systemName: "plus.circle.fill")
                    .font(.brandTitle2)
            }
            .buttonStyle(.plain)
        }
    }
}

/// A small circular photo for a restaurant — Google's photo when one was
/// captured at add-time (fetched on demand via the backend proxy, see
/// `GooglePlacesService.photoURL(for:)`), otherwise a plain placeholder
/// icon. Nothing to show for a restaurant added manually or from MapKit,
/// since neither source has a photo to offer.
struct RestaurantThumbnail: View {
    let googlePhotoName: String?
    var size: CGFloat = 44

    var body: some View {
        Group {
            if let googlePhotoName, let url = GooglePlacesService.photoURL(for: googlePhotoName, maxWidthPx: Int(size) * 2) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.secondary.opacity(0.12))
            .overlay {
                Image(systemName: "fork.knife")
                    .foregroundStyle(.secondary)
            }
    }
}

/// Searches for places matching the query — Google (via the backend proxy,
/// see `GooglePlacesService`) when it's configured, since it can return
/// rating/price/cuisine that Apple's free local-search index has no concept
/// of at all; falls back to `MKLocalSearch` (free, no account, no backend
/// needed) otherwise, or if the Google request fails for any reason.
@MainActor
final class RestaurantSearchModel: ObservableObject {
    /// One result row's worth of data, whichever source it came from — the
    /// view only ever deals with this, never `MKMapItem`/`GooglePlacesService.PlaceResult` directly.
    struct Result: Identifiable {
        let id: String
        let name: String
        let address: String?
        let cuisine: String?
        let priceRange: String?
        let rating: Double?
        let mapsURLString: String?
        /// Only ever set for a Google-sourced result — see
        /// `GooglePlacesService.PlaceResult.photoName`.
        let photoName: String?
        let coordinate: CLLocationCoordinate2D?
        /// Whether `id` is a real Google place ID (safe to keep and later
        /// use for `GooglePlacesService.placeDetails(placeID:)`) as opposed
        /// to a locally-synthesized id for a MapKit fallback result.
        let isGoogleSourced: Bool
    }

    @Published var results: [Result] = []
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

            if GooglePlacesService.isConfigured {
                do {
                    let places = try await GooglePlacesService.search(trimmed)
                    guard !Task.isCancelled else { return }
                    results = places.map {
                        Result(
                            id: $0.id,
                            name: $0.name,
                            address: $0.address,
                            cuisine: $0.cuisine,
                            priceRange: $0.priceRange,
                            rating: $0.rating,
                            mapsURLString: $0.mapsURLString,
                            photoName: $0.photoName,
                            coordinate: $0.coordinate,
                            isGoogleSourced: true
                        )
                    }
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    // Fall through to MapKit rather than dead-ending the
                    // search just because the backend had a bad moment.
                }
            }

            await searchWithMapKit(trimmed)
        }
    }

    private func searchWithMapKit(_ query: String) async {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = .pointOfInterest
        do {
            let response = try await MKLocalSearch(request: request).start()
            guard !Task.isCancelled else { return }
            results = response.mapItems.enumerated().map { index, item in
                Result(
                    id: "mapkit-\(index)-\(item.name ?? "")",
                    name: item.name ?? "Unknown",
                    address: item.placemark.title,
                    cuisine: cuisineLabel(for: item),
                    priceRange: nil,
                    rating: nil,
                    mapsURLString: item.url?.absoluteString,
                    photoName: nil,
                    coordinate: item.placemark.coordinate,
                    isGoogleSourced: false
                )
            }
        } catch {
            guard !Task.isCancelled else { return }
            results = []
            errorMessage = "Couldn't search right now — check your connection."
        }
    }

    /// Turns MapKit's point-of-interest category (e.g. "MKPOICategoryBakery")
    /// into a readable label ("Bakery"). The generic "Restaurant" category
    /// isn't useful as a label, so that one is left blank rather than shown.
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

    func clear() {
        searchTask?.cancel()
        results = []
        errorMessage = nil
    }
}
