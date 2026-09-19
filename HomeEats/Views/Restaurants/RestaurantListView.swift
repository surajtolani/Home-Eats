import SwiftUI
import SwiftData
import MapKit
import CoreLocation

struct RestaurantListView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var accountSession: AccountSession
    @Query(sort: \Restaurant.name) private var restaurants: [Restaurant]

    @State private var showEditor = false
    @State private var showNaturalSearch = false
    @State private var showDuplicates = false
    @State private var searchText = ""
    @StateObject private var searchModel = RestaurantSearchModel()
    @StateObject private var locationProvider = UserLocationProvider()
    /// Search results already added to the personal library this search
    /// session — see `addFromSearch`'s own doc comment for why this exists
    /// (multi-add without losing the results list) and `SearchResultRow`'s
    /// `isAdded` for how it's shown per row.
    @State private var addedResultIDs: Set<String> = []
    /// Backs `searchFieldRow`'s `TextField` — see `body`'s
    /// `.scrollDismissesKeyboard`/`.onSubmit` for why this exists: direct
    /// user report that there was no way to dismiss the keyboard after
    /// typing a search and get back to scrolling the results/restaurant
    /// list below it.
    @FocusState private var isSearchFieldFocused: Bool

    private var isSearchActive: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            searchFieldRow
            List {
                if isSearchActive {
                    searchResultsSection
                }

                if restaurants.isEmpty && !isSearchActive {
                    ContentUnavailableView(
                        "No Restaurants Yet",
                        systemImage: "fork.knife",
                        description: Text("Search above to find a place and add it, or tap + to add one manually.")
                    )
                } else if !restaurants.isEmpty {
                    Section {
                        ForEach(restaurants) { restaurant in
                            NavigationLink {
                                RestaurantDetailView(restaurant: restaurant)
                            } label: {
                                restaurantTile(restaurant)
                            }
                        }
                        .onDelete { offsets in
                            for index in offsets {
                                let restaurant = restaurants[index]
                                CascadeCleanup.removeReferences(toRestaurantID: restaurant.id, in: modelContext)
                                // Same "immediate, online-only, captured before
                                // the local delete" pattern as `RecipesHomeView`'s
                                // own recipe delete — see
                                // `PersonalLibrarySyncService`'s doc comment.
                                if let backendID = restaurant.backendID {
                                    Task { try? await AccountsAPIClient.deleteRestaurant(id: backendID) }
                                }
                                modelContext.delete(restaurant)
                            }
                        }
                    } header: {
                        Text("Your Restaurants")
                    }
                }
            }
            .listStyle(.plain)
            // Direct user report: nothing on this screen dismissed the
            // keyboard once it was up, so there was no way to get back to
            // scrolling the results/your restaurant list below it.
            // `.immediately` (not `.interactively`) matches the plain "swipe
            // down to dismiss" gesture users expect from Messages/Mail —
            // the list itself still scrolls normally either way, this only
            // changes what a scroll gesture does to a focused keyboard.
            .scrollDismissesKeyboard(.immediately)
        }
        .onChange(of: searchText) { _, newValue in
            searchModel.search(newValue)
            // A fresh search's results have nothing to do with whatever was
            // added from the previous one — reset so a result that happens
            // to reappear (searched again) doesn't show a stale checkmark.
            if newValue.trimmingCharacters(in: .whitespaces).isEmpty {
                addedResultIDs = []
            }
        }
        .onAppear {
            locationProvider.requestIfNeeded()
        }
        .onChange(of: locationProvider.coordinate) { _, newValue in
            searchModel.userCoordinate = newValue
        }
        .navigationTitle("Restaurants")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                BrandHeaderBanner()
            }
            // Direct user request: "There should be a way to eliminate
            // duplications." See `DuplicateRestaurantsView`'s own doc
            // comment for what this opens.
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showDuplicates = true
                } label: {
                    Image(systemName: "checkmark.circle.trianglebadge.exclamationmark")
                }
                .accessibilityLabel("Find Duplicate Restaurants")
            }
        }
        .sheet(isPresented: $showEditor) {
            RestaurantEditorView()
        }
        .sheet(isPresented: $showNaturalSearch) {
            NaturalLanguageRestaurantSearchView(userCoordinate: locationProvider.coordinate)
        }
        .sheet(isPresented: $showDuplicates) {
            DuplicateRestaurantsView()
        }
        // Opportunistic personal-library sync, same reasoning and pattern
        // as `RecipesHomeView`'s own identical `.task` — see
        // `PersonalLibrarySyncService`'s doc comment.
        .task(id: accountSession.isSignedIn) {
            guard accountSession.isSignedIn else { return }
            await PersonalLibrarySyncService.sync(modelContext: modelContext)
        }
    }

    /// A custom inline search field, not `.searchable(...)` (what this used
    /// to be) — direct user request to move the "+"/"Ask for a Restaurant"
    /// actions from the top-right toolbar to sit right next to the search
    /// bar itself. `.searchable`'s system search field always spans the
    /// full toolbar width with nothing else in it, so there's no way to
    /// place a button beside it there; a plain `TextField` in the same
    /// `HStack` as those two buttons is what actually makes "next to the
    /// search bar" possible. The extra `Spacer().frame(width: 6)` between
    /// the sparkles and plus buttons — direct user request for more
    /// breathing room specifically between those two (same change made to
    /// `RecipesHomeView.searchFieldRow`) — widens just that one gap; every
    /// other pair in this row keeps the plain 8pt `HStack` spacing.
    private var searchFieldRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search for a restaurant to add", text: $searchText)
                .focused($isSearchFieldFocused)
                .submitLabel(.search)
                .onSubmit { isSearchFieldFocused = false }
            if isSearchActive {
                Button {
                    searchText = ""
                    searchModel.clear()
                    addedResultIDs = []
                    isSearchFieldFocused = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            Divider().frame(height: 18)
            Button {
                showNaturalSearch = true
            } label: {
                Image(systemName: "sparkles")
            }
            .buttonStyle(.plain)
            .disabled(!GooglePlacesService.isConfigured || !ClaudeRecipeService.isConfigured)
            .accessibilityLabel("Ask for a Restaurant")
            Spacer().frame(width: 6)
            Button {
                showEditor = true
            } label: {
                Image(systemName: "plus.circle.fill")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add a Restaurant")
        }
        .foregroundStyle(.primary)
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    /// The `MediaTileRow`-based row for a saved restaurant — direct user
    /// request for a consistent tile format across the Plan/Restaurants/
    /// Recipes tabs (see that type's own doc comment). The favorite star
    /// that used to sit inline next to the name moves to a floating
    /// accessory badge (matching the reference tile's own corner button
    /// exactly) and a leading swipe action, rather than disappearing —
    /// there's only room for the one floating accessory this tile shape
    /// offers.
    private func restaurantTile(_ restaurant: Restaurant) -> some View {
        MediaTileRow(
            title: restaurant.name,
            metaItems: restaurantMetaItems(restaurant),
            thumbnail: { RestaurantThumbnail(googlePhotoName: restaurant.googlePhotoNames.first, size: mediaTileHeight) },
            actions: [
                MediaTileAction(
                    icon: restaurant.isFavorite ? "star.fill" : "star",
                    tint: restaurant.isFavorite ? .brandHoney : .secondary,
                    label: restaurant.isFavorite ? "Unfavorite" : "Favorite",
                    onTap: { restaurant.isFavorite.toggle() }
                )
            ]
        )
    }

    /// One plain-text line — cuisine, price, and rating together, direct
    /// user request: separate icons in front of each ("a fork+knife before
    /// cuisine, a "$" before the price") read as confusing extra symbols
    /// next to already-self-explanatory text (a "$" icon right before "$$"
    /// reading like a third dollar sign), and the rating should show as
    /// actual stars, not "4/5" text, on the same line as cuisine/price
    /// rather than wrapping to its own row. `Restaurant.descriptorLine`
    /// already builds exactly this ("Italian · $$ · ★★★★☆") for the list/
    /// detail views, so this reuses it instead of re-deriving the same
    /// three fields into three separate meta items.
    private func restaurantMetaItems(_ restaurant: Restaurant) -> [(icon: String?, text: String)] {
        guard let descriptorLine = restaurant.descriptorLine else { return [] }
        return [(icon: nil, text: descriptorLine)]
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
                    SearchResultRow(result: result, isAdded: addedResultIDs.contains(result.id)) {
                        addFromSearch(result)
                    }
                }
            }
        } header: {
            Text("Search Results")
        } footer: {
            Text(
                GooglePlacesService.isConfigured
                    ? "Powered by Google — includes rating, price, and cuisine. Tap a result to see more, or the ⊕ to add it."
                    : "Powered by Apple's local search — free, no account needed. Tap a result to see more, or the ⊕ to add it."
            )
        }
    }

    /// Direct user request: adding a result used to clear the search
    /// entirely, forcing a re-search to add a second one from the same
    /// list. Now it just marks that one result added (`addedResultIDs`,
    /// checked by `SearchResultRow`'s own `isAdded`) and leaves the rest of
    /// the results in place. Re-adding an already-added result is a no-op —
    /// there's no id to key an update against otherwise.
    ///
    /// **Duplicate prevention**: if this result matches a restaurant
    /// already in the library (`existingMatch(in:)` — same real place
    /// searched again, possibly in a later session where `addedResultIDs`
    /// has long since reset), this marks it added without inserting a
    /// second copy — direct user request that restaurants "should not be
    /// able to be added twice."
    private func addFromSearch(_ result: RestaurantSearchModel.Result) {
        guard !addedResultIDs.contains(result.id) else { return }
        if result.existingMatch(in: restaurants) == nil {
            modelContext.insert(result.makeRestaurant())
        }
        addedResultIDs.insert(result.id)
    }
}

extension RestaurantSearchModel.Result {
    /// A restaurant already in the library that this search result is the
    /// same real place as, if any — direct user request: "Restaurants...
    /// should not be able to be added twice." A Google-sourced result
    /// (`isGoogleSourced`) matches by `googlePlaceID` (the one truly
    /// reliable identifier: two different Google results never share a
    /// place ID, but two genuinely different restaurants can share a
    /// name), falling back to a case-insensitive name match for a MapKit
    /// result, which has no place ID to compare — same fallback
    /// `RestaurantEditorView.duplicateMatch` uses for a manually-typed
    /// name. Checked by both `addFromSearch` overloads below (plain search
    /// and the natural-language one) before inserting.
    func existingMatch(in restaurants: [Restaurant]) -> Restaurant? {
        if isGoogleSourced {
            if let match = restaurants.first(where: { $0.googlePlaceID == id }) {
                return match
            }
        }
        return restaurants.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Builds a `Restaurant` ready to insert from this search result —
    /// shared by both the plain search-as-you-type flow and the
    /// natural-language "Ask for a Restaurant" flow.
    func makeRestaurant() -> Restaurant {
        Restaurant(
            name: name,
            cuisine: cuisine,
            priceRange: priceRange,
            rating: rating.map { Int($0.rounded()) },
            websiteURL: websiteURLString,
            address: address,
            googlePhotoNames: photoNames,
            googlePlaceID: isGoogleSourced ? id : nil,
            latitude: coordinate?.latitude,
            longitude: coordinate?.longitude
        )
    }

    /// The same "Italian · $$ · ★★★★☆" line `Restaurant.descriptorLine`
    /// builds for a saved restaurant, computed here from a not-yet-saved
    /// search result's own fields instead — used by `SearchResultRow` and
    /// `RestaurantSearchResultDetailView` so a result previews with the
    /// identical formatting it'll have once actually added.
    var descriptorLine: String? {
        var parts: [String] = []
        if let cuisine, !cuisine.isEmpty { parts.append(cuisine) }
        if let priceRange, !priceRange.isEmpty { parts.append(priceRange) }
        if let rating, rating > 0 {
            let rounded = Int(rating.rounded())
            parts.append(String(repeating: "★", count: rounded) + String(repeating: "☆", count: max(0, 5 - rounded)))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// One search result row — tapping the name/thumbnail previews the full
/// info (`RestaurantSearchResultDetailView`, same page a saved restaurant's
/// own detail view shows); the trailing ⊕/checkmark is a separate tap
/// target that adds without leaving the results list. Direct user request
/// for both: search results used to be a dead-end row with just a name,
/// address, and an add button.
private struct SearchResultRow: View {
    let result: RestaurantSearchModel.Result
    let isAdded: Bool
    let onAdd: () -> Void

    var body: some View {
        HStack {
            NavigationLink {
                RestaurantSearchResultDetailView(result: result, isAdded: isAdded, onAdd: onAdd)
            } label: {
                HStack {
                    RestaurantThumbnail(googlePhotoName: result.photoNames.first, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.name)
                        if let descriptorLine = result.descriptorLine {
                            Text(descriptorLine)
                                .font(.brandCaption)
                                .foregroundStyle(.secondary)
                        }
                        if let address = result.address {
                            Text(address)
                                .font(.brandCaption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            Spacer()
            Button(action: onAdd) {
                Image(systemName: isAdded ? "checkmark.circle.fill" : "plus.circle.fill")
                    .font(.brandTitle2)
                    .foregroundStyle(isAdded ? Color.brandForest : .primary)
            }
            .buttonStyle(.plain)
            .disabled(isAdded)
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

/// "Casual pizza place near Greenwich," "somewhere kid-friendly for a quick
/// lunch" — a free-text description instead of a name, backed by
/// `GooglePlacesService.searchNatural` (the backend asks Claude to turn the
/// sentence into a concrete search + any place actually named in it). A
/// separate sheet from the plain search-as-you-type bar, since this is a
/// deliberate "search for this" action (with a real network round trip to
/// Claude) rather than something to fire on every keystroke.
///
/// **Dual-purpose via `onPick`**: opened standalone (from Restaurants —
/// `onPick` `nil`), picking a result inserts it straight into the personal
/// Restaurant library, same as always. `GroupSharedMealPlanView`'s "Add a
/// Meal" sheet also opens this exact same view, with `onPick` set — there,
/// picking a result hands the full `RestaurantSearchModel.Result` back to
/// that caller instead (which plans it for the group, then separately
/// offers to also save it to the personal library) and no local insert
/// happens here in that mode.
struct NaturalLanguageRestaurantSearchView: View {
    /// The app's best guess at the user's current location, if available —
    /// used only when the sentence itself doesn't name a specific place.
    let userCoordinate: CLLocationCoordinate2D?
    var onPick: ((RestaurantSearchModel.Result) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    /// Standalone mode only — see `addFromSearch`'s own doc comment for the
    /// duplicate check this backs.
    @Query(sort: \Restaurant.name) private var restaurants: [Restaurant]

    @State private var queryText = ""
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var results: [RestaurantSearchModel.Result] = []
    @State private var interpretedQuery: String?
    @State private var interpretedLocation: String?
    @State private var hasSearchedOnce = false
    /// Standalone mode only (`onPick == nil`) — see `addFromSearch`'s own
    /// doc comment for why this exists.
    @State private var addedResultIDs: Set<String> = []

    private var canSearch: Bool {
        !queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                if !GooglePlacesService.isConfigured || !ClaudeRecipeService.isConfigured {
                    Section {
                        Text("This feature isn't set up yet — see backend/README.md to enable it.")
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    TextField(
                        "e.g. casual pizza place near Greenwich",
                        text: $queryText,
                        axis: .vertical
                    )
                    .lineLimit(2...4)
                } header: {
                    Text("Describe what you're looking for")
                } footer: {
                    Text("Cuisine, vibe, or occasion, and a specific area if you have one in mind — \"quiet date-night spot near the harbor,\" \"quick kid-friendly lunch downtown.\"")
                        .font(.brandSubheadline)
                        .foregroundStyle(.secondary)
                }
                Section {
                    Button {
                        Task { await search() }
                    } label: {
                        HStack {
                            Spacer()
                            if isSearching {
                                ProgressView()
                            } else {
                                Text("Search")
                            }
                            Spacer()
                        }
                    }
                    .disabled(isSearching || !canSearch || !GooglePlacesService.isConfigured || !ClaudeRecipeService.isConfigured)
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
                if let interpretedQuery {
                    Section {
                        // Shows what was actually searched for once Claude's
                        // cleaned up the sentence — confirms the request was
                        // understood the way it was meant, especially for a
                        // named location that might have been misread.
                        Label {
                            if let interpretedLocation {
                                Text("Searching for \"\(interpretedQuery)\" near \(interpretedLocation)")
                            } else {
                                Text("Searching for \"\(interpretedQuery)\"")
                            }
                        } icon: {
                            Image(systemName: "sparkles")
                        }
                        .font(.brandCaption)
                        .foregroundStyle(.secondary)
                    }
                }
                if !results.isEmpty {
                    Section("Results") {
                        ForEach(results) { result in
                            SearchResultRow(result: result, isAdded: addedResultIDs.contains(result.id)) {
                                addFromSearch(result)
                            }
                        }
                    }
                } else if hasSearchedOnce && !isSearching {
                    Section {
                        Text("No matches found.").foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Ask for a Restaurant")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func search() async {
        errorMessage = nil
        isSearching = true
        defer {
            isSearching = false
            hasSearchedOnce = true
        }
        do {
            let response = try await GooglePlacesService.searchNatural(queryText, near: userCoordinate)
            interpretedQuery = response.interpretedQuery
            interpretedLocation = response.interpretedLocation
            results = response.results.map {
                RestaurantSearchModel.Result(
                    id: $0.id,
                    name: $0.name,
                    address: $0.address,
                    cuisine: $0.cuisine,
                    priceRange: $0.priceRange,
                    rating: $0.rating,
                    mapsURLString: $0.mapsURLString,
                    websiteURLString: $0.websiteURLString,
                    photoNames: $0.photoNames,
                    coordinate: $0.coordinate,
                    isGoogleSourced: true
                )
            }
        } catch {
            results = []
            errorMessage = error.localizedDescription
        }
    }

    /// `onPick` mode (picking a restaurant for one group meal slot) still
    /// dismisses on pick — that flow really is "choose exactly one." The
    /// standalone mode (`onPick == nil`, opened from the Restaurants tab's
    /// own sparkles button) used to dismiss too, which meant adding a
    /// second result from the same search meant closing this sheet, opening
    /// it again, and re-typing the same query — direct user request to fix
    /// that: it now just marks the result added (`addedResultIDs`) and
    /// leaves the sheet open on the same results, so multiple results can
    /// be added from one search. "Done" in the toolbar is how this mode
    /// actually closes now.
    private func addFromSearch(_ result: RestaurantSearchModel.Result) {
        if let onPick {
            onPick(result)
            dismiss()
            return
        }
        guard !addedResultIDs.contains(result.id) else { return }
        // Same duplicate check as the plain search bar's own
        // `addFromSearch` — see `existingMatch(in:)`'s own doc comment.
        if result.existingMatch(in: restaurants) == nil {
            modelContext.insert(result.makeRestaurant())
        }
        addedResultIDs.insert(result.id)
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
        /// The place's actual business website — what "Website" should
        /// open, as opposed to `mapsURLString` which opens Google/Apple
        /// Maps. `nil` when no site is on file, in which case no Website
        /// button is shown at all rather than falling back to the map link.
        let websiteURLString: String?
        /// Only ever non-empty for a Google-sourced result — see
        /// `GooglePlacesService.PlaceResult.photoNames`.
        let photoNames: [String]
        let coordinate: CLLocationCoordinate2D?
        /// Whether `id` is a real Google place ID (safe to keep and later
        /// use for `GooglePlacesService.placeDetails(placeID:)`) as opposed
        /// to a locally-synthesized id for a MapKit fallback result.
        let isGoogleSourced: Bool
    }

    @Published var results: [Result] = []
    @Published var isSearching = false
    @Published var errorMessage: String?

    /// The app's best guess at "nearby," if location access is available —
    /// biases (and, for Google, ranks) results toward it, so a common
    /// restaurant name search doesn't surface a same-named place a
    /// continent away above the one actually close by. Set by the view
    /// before searching; `nil` (denied, not yet answered, or simply
    /// unavailable) just falls back to the previous unbiased behavior.
    var userCoordinate: CLLocationCoordinate2D?

    private var searchTask: Task<Void, Never>?

    func search(_ query: String) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            results = []
            errorMessage = nil
            return
        }
        let coordinate = userCoordinate
        searchTask = Task {
            // Small debounce so we're not firing a search on every keystroke.
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }

            isSearching = true
            errorMessage = nil
            defer { isSearching = false }

            if GooglePlacesService.isConfigured {
                do {
                    let places = try await GooglePlacesService.search(trimmed, near: coordinate)
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
                            websiteURLString: $0.websiteURLString,
                            photoNames: $0.photoNames,
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

            await searchWithMapKit(trimmed, near: coordinate)
        }
    }

    private func searchWithMapKit(_ query: String, near coordinate: CLLocationCoordinate2D?) async {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = .pointOfInterest
        if let coordinate {
            // A ~50km region biases MapKit's own ranking toward this area —
            // without it, MapKit has no idea where "nearby" even means and
            // ranks purely by name/relevance, same problem as Google
            // without `locationBias`.
            request.region = MKCoordinateRegion(
                center: coordinate,
                latitudinalMeters: 100_000,
                longitudinalMeters: 100_000
            )
        }
        do {
            let response = try await MKLocalSearch(request: request).start()
            guard !Task.isCancelled else { return }
            let items = coordinate.map { userLocation in
                // MapKit's own ranking isn't strictly distance-first even
                // with a region set — sorting explicitly is what actually
                // guarantees the closest match shows up first.
                response.mapItems.sorted {
                    distance(from: userLocation, to: $0.placemark.coordinate)
                        < distance(from: userLocation, to: $1.placemark.coordinate)
                }
            } ?? response.mapItems
            results = items.enumerated().map { index, item in
                Result(
                    id: "mapkit-\(index)-\(item.name ?? "")",
                    name: item.name ?? "Unknown",
                    address: item.placemark.title,
                    cuisine: cuisineLabel(for: item),
                    priceRange: nil,
                    rating: nil,
                    // MapKit doesn't expose a separate "open in Maps" link
                    // the way Google does — there's nothing to put here.
                    mapsURLString: nil,
                    // For a MapKit point of interest, `.url` is the
                    // business's own website (not an Apple Maps link), so
                    // it maps directly to "Website" rather than to
                    // `mapsURLString`.
                    websiteURLString: item.url?.absoluteString,
                    photoNames: [],
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

    /// Straight-line distance in meters — plenty accurate for ranking
    /// nearby search results, no need for anything route-aware here.
    private func distance(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: from.latitude, longitude: from.longitude)
            .distance(from: CLLocation(latitude: to.latitude, longitude: to.longitude))
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
