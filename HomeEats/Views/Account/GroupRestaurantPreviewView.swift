import SwiftUI
import SwiftData

/// Read-only preview of a group meal's restaurant, for the case a decided
/// or suggested eat-out/order-in meal's `restaurantName` doesn't match any
/// `Restaurant` the viewer already has saved locally. Reached by tapping a
/// restaurant row in `GroupSharedMealPlanView` — direct user request ("same
/// issue with restaurant, we should be able to click in it and it takes us
/// to that restaurant page") — via `GroupPlanRestaurantLink`, which only
/// ever falls back to this view when no local match exists (see that
/// type's own doc comment).
///
/// Unlike a recipe (which always has a real backend id to fetch by),
/// `GroupPlannedMeal`/`GroupMealSuggestion.restaurantName` is plain free
/// text only — see that field's own doc comment in
/// `GroupSharedMealPlanView.swift` — there's no id to look up directly. So
/// this runs the exact same live search the personal restaurant list's own
/// search-as-you-type field uses (`RestaurantSearchModel`, Google Places
/// first, MapKit fallback) for `name` and shows its best (first) match,
/// with an "Add to My Restaurants" action that saves it exactly the way
/// that search flow already does (`Result.makeRestaurant()`).
struct GroupRestaurantPreviewView: View {
    let name: String

    @Environment(\.modelContext) private var modelContext
    @StateObject private var searchModel = RestaurantSearchModel()
    /// Set the moment "Add to My Restaurants" succeeds — swaps this whole
    /// view over to the real, full `RestaurantDetailView` for the
    /// newly-saved row, so tapping Add doesn't just sit there having "saved"
    /// with no visible next step.
    @State private var savedRestaurant: Restaurant?

    var body: some View {
        Group {
            if let savedRestaurant {
                RestaurantDetailView(restaurant: savedRestaurant)
            } else if searchModel.isSearching {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let result = searchModel.results.first {
                foundContent(result)
            } else if let errorMessage = searchModel.errorMessage {
                // Direct fix for a real gap: this used to always show
                // "Couldn't Find <name>" whenever `results` was empty,
                // even when the actual cause was a network failure rather
                // than a genuine no-match — `RestaurantSearchModel` has
                // carried its own `errorMessage` for exactly this
                // distinction all along (see `RestaurantListView`'s own
                // use of it), this screen just never read it.
                VStack(spacing: 16) {
                    ContentUnavailableView(
                        "Couldn't Load This Restaurant",
                        systemImage: "wifi.exclamationmark",
                        description: Text(errorMessage)
                    )
                    Button("Retry") { searchModel.search(name) }
                }
            } else {
                notFoundContent
            }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .task { searchModel.search(name) }
    }

    @ViewBuilder
    private func foundContent(_ result: RestaurantSearchModel.Result) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                RestaurantThumbnail(googlePhotoName: result.photoNames.first, size: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .frame(maxWidth: .infinity)

                Text(result.name).font(.brandTitle2.bold())

                if let address = result.address {
                    Text(address).foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    if let cuisine = result.cuisine { Text(cuisine) }
                    if let priceRange = result.priceRange { Text(priceRange) }
                    if let rating = result.rating {
                        Label(String(format: "%.1f", rating), systemImage: "star.fill")
                    }
                }
                .font(.brandCaption)
                .foregroundStyle(.secondary)

                Button {
                    let restaurant = result.makeRestaurant()
                    modelContext.insert(restaurant)
                    savedRestaurant = restaurant
                } label: {
                    Label("Add to My Restaurants", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.brandForest)

                if let mapsURLString = result.mapsURLString, let url = URL(string: mapsURLString) {
                    Link(destination: url) {
                        Label("Open in Maps", systemImage: "map")
                    }
                }
            }
            .padding()
        }
    }

    private var notFoundContent: some View {
        VStack(spacing: 16) {
            ContentUnavailableView(
                "Couldn't Find \"\(name)\"",
                systemImage: "fork.knife.circle",
                description: Text("No nearby match turned up for this name. You can still look it up yourself.")
            )
            if let mapsSearchURL {
                Link(destination: mapsSearchURL) {
                    Label("Search Maps for \"\(name)\"", systemImage: "map")
                }
            }
        }
    }

    private var mapsSearchURL: URL? {
        let query = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
        return URL(string: "http://maps.apple.com/?q=\(query)")
    }
}
