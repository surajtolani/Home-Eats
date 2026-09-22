import SwiftUI
import MapKit
import CoreLocation
import SwiftData

/// Shows a saved restaurant's details: a map (using the coordinate captured
/// when it was added, so no on-device geocoding needed for anything found
/// via search — only a manually-typed address still needs that), plus — for
/// a restaurant added from Google — its hours, phone number, and reviews
/// pulled in directly, so seeing what other people think of the place
/// doesn't require leaving the app. "Open in Google Maps" is still there
/// for directions or the full photo/review gallery, but it's no longer the
/// only way to see a rating or a review.
///
/// All the actual rendering lives in `RestaurantInfoScaffold` below, shared
/// with `RestaurantSearchResultDetailView` — this wrapper just adapts a real
/// `Restaurant` model object into that scaffold's plain-value parameters and
/// supplies the "Edit" toolbar action a saved restaurant gets (a not-yet-
/// added search result gets "Add" instead — see that view's own doc
/// comment).
struct RestaurantDetailView: View {
    @Bindable var restaurant: Restaurant

    @State private var showEditor = false

    var body: some View {
        RestaurantInfoScaffold(
            descriptorLine: restaurant.descriptorLine,
            address: restaurant.address,
            photoNames: restaurant.googlePhotoNames,
            googlePlaceID: restaurant.googlePlaceID,
            websiteURL: restaurant.websiteURL,
            storedCoordinate: storedCoordinate,
            isFavorite: restaurant.isFavorite,
            notes: restaurant.notes,
            onWebsiteBackfilled: { restaurant.websiteURL = $0 }
        )
        .navigationTitle(restaurant.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Direct fix for a real gap: the header below already shows a
            // star for a favorited restaurant, but there was no way to
            // actually set/unset it from this screen — only from
            // `RestaurantEditorView`'s own toggle. Matches
            // `RecipeDetailView`'s identical heart-toggle button, just
            // star/yellow to match this screen's own existing favorite
            // indicator rather than introducing a second visual language
            // for "favorited" on the same tab.
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    restaurant.isFavorite.toggle()
                } label: {
                    Image(systemName: restaurant.isFavorite ? "star.fill" : "star")
                }
                .tint(.yellow)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") { showEditor = true }
            }
        }
        .sheet(isPresented: $showEditor) {
            RestaurantEditorView(existing: restaurant)
        }
    }

    private var storedCoordinate: CLLocationCoordinate2D? {
        guard let latitude = restaurant.latitude, let longitude = restaurant.longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// A not-yet-added search result's own preview — same info a saved
/// restaurant's detail page shows (`RestaurantInfoScaffold`: photo, rating/
/// price/cuisine, address, map, Directions/Website, and — for a
/// Google-sourced result — hours/phone/reviews), reached by tapping a row in
/// either search flow (`RestaurantListView`'s inline search-as-you-type
/// results, or `NaturalLanguageRestaurantSearchView`'s "Ask for a
/// Restaurant" results). Direct user request: search results used to show
/// only a name/address/thumbnail in the row itself, with no way to see
/// rating, price, hours, phone, or reviews before deciding to add one.
///
/// "Add" in the toolbar here is deliberately the exact same `onAdd`/
/// `isAdded` the row itself already tracks (both search screens keep a
/// `Set` of already-added result ids — see their own `addFromSearch`), not
/// a separate insert path and not something that dismisses this screen or
/// the search sheet behind it — direct user request that adding one result
/// (from the row's own + button or from in here) shouldn't force searching
/// again to add a second one. Tapping back just returns to the results
/// list, still showing whichever were already added.
struct RestaurantSearchResultDetailView: View {
    let result: RestaurantSearchModel.Result
    let isAdded: Bool
    let onAdd: () -> Void

    var body: some View {
        RestaurantInfoScaffold(
            descriptorLine: result.descriptorLine,
            address: result.address,
            photoNames: result.photoNames,
            // Only a genuine Google place id can be looked up for hours/
            // phone/reviews — a MapKit-fallback result's `id` is a locally
            // synthesized string (see `RestaurantSearchModel
            // .searchWithMapKit`), not a real Google place.
            googlePlaceID: result.isGoogleSourced ? result.id : nil,
            websiteURL: result.websiteURLString,
            storedCoordinate: result.coordinate,
            isFavorite: false,
            notes: nil,
            onWebsiteBackfilled: nil
        )
        .navigationTitle(result.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onAdd) {
                    if isAdded {
                        Label("Added", systemImage: "checkmark")
                    } else {
                        Text("Add")
                    }
                }
                .disabled(isAdded)
            }
        }
    }
}

/// The actual rendering shared by `RestaurantDetailView` and
/// `RestaurantSearchResultDetailView` — everything about "what a
/// restaurant's info looks like" (map, Directions/Website buttons, Google
/// hours/phone/reviews, notes) lives here exactly once, driven entirely by
/// plain values rather than a `Restaurant` model object, so a not-yet-saved
/// search result can render through the identical code path a real saved
/// restaurant does. The two callers differ only in `onWebsiteBackfilled`
/// (a saved restaurant persists a Google-sourced website back onto itself;
/// a preview has nothing to persist to, so passes `nil`) and in their own
/// navigation title/toolbar (Edit vs. Add — see each view's own doc
/// comment).
private struct RestaurantInfoScaffold: View {
    let descriptorLine: String?
    let address: String?
    let photoNames: [String]
    let googlePlaceID: String?
    let websiteURL: String?
    let storedCoordinate: CLLocationCoordinate2D?
    let isFavorite: Bool
    let notes: String?
    let onWebsiteBackfilled: ((String) -> Void)?

    @Environment(\.openURL) private var openURL
    @State private var coordinate: CLLocationCoordinate2D?
    @State private var geocodingFailed = false
    @State private var details: GooglePlacesService.PlaceDetails?
    @State private var isLoadingDetails = false
    @State private var detailsErrorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !photoNames.isEmpty {
                    PhotoCarousel(photoNames: photoNames)
                        .frame(height: 200)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }

                header

                mapSection

                actionButtons

                detailsSection

                if let notes, !notes.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Notes").font(.brandHeadline)
                        Text(notes)
                    }
                }
            }
            .padding()
        }
        .task(id: address) {
            await geocodeIfNeeded()
        }
        .task(id: googlePlaceID) {
            await loadDetailsIfNeeded()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if let descriptorLine {
                    Text(descriptorLine)
                        .font(.brandSubheadline)
                        .foregroundStyle(.secondary)
                }
                if isFavorite {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                        .font(.brandCaption)
                }
            }
            if let address, !address.isEmpty {
                Text(address)
                    .font(.brandSubheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var mapSection: some View {
        if let coordinate {
            Map(initialPosition: .region(
                MKCoordinateRegion(center: coordinate, latitudinalMeters: 800, longitudinalMeters: 800)
            )) {
                Marker(descriptorLine ?? "Location", coordinate: coordinate)
            }
            .frame(height: 200)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        } else if let address, !address.isEmpty {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.1))
                .frame(height: 120)
                .overlay {
                    if geocodingFailed {
                        Text("Couldn't find this address on the map.")
                            .font(.brandCaption)
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView("Finding on map…")
                    }
                }
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button {
                openInGoogleMaps()
            } label: {
                Label("Directions", systemImage: "map")
            }
            .buttonStyle(.borderedProminent)

            if let websiteURL, !websiteURL.isEmpty {
                Button {
                    openWebsite(websiteURL)
                } label: {
                    Label("Website", systemImage: "globe")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    /// Hours/phone/reviews, pulled directly from Google — only shown when
    /// there's actually a `googlePlaceID` to fetch (a Google-sourced saved
    /// restaurant or search result; a manual entry or a MapKit-fallback
    /// result has nothing to fetch here).
    @ViewBuilder
    private var detailsSection: some View {
        if googlePlaceID != nil {
            VStack(alignment: .leading, spacing: 12) {
                if isLoadingDetails {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                } else if let detailsErrorMessage {
                    Text(detailsErrorMessage)
                        .font(.brandCaption)
                        .foregroundStyle(.secondary)
                } else if let details {
                    if let phoneNumber = details.phoneNumber, !phoneNumber.isEmpty {
                        Button {
                            callPhoneNumber(phoneNumber)
                        } label: {
                            Label(phoneNumber, systemImage: "phone")
                        }
                        .font(.brandSubheadline)
                    }

                    if !details.openingHours.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Hours").font(.brandHeadline)
                            ForEach(details.openingHours, id: \.self) { line in
                                Text(line)
                                    .font(.brandSubheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    if !details.reviews.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("Reviews").font(.brandHeadline)
                                if let count = details.userRatingCount {
                                    Text("(\(count))")
                                        .font(.brandCaption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            ForEach(details.reviews) { review in
                                ReviewRow(review: review)
                            }
                        }
                    }
                }
            }
        }
    }

    private func callPhoneNumber(_ phoneNumber: String) {
        let digitsAndPlus = phoneNumber.filter { $0.isNumber || $0 == "+" }
        guard let url = URL(string: "tel://\(digitsAndPlus)") else { return }
        openURL(url)
    }

    private func openInGoogleMaps() {
        let query = [descriptorLine, address]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        let fallbackQuery = coordinate.map { "\($0.latitude),\($0.longitude)" } ?? query
        let finalQuery = query.isEmpty ? fallbackQuery : query
        guard let encoded = finalQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://www.google.com/maps/search/?api=1&query=\(encoded)") else { return }
        openURL(url)
    }

    private func openWebsite(_ urlString: String) {
        var trimmed = urlString.trimmingCharacters(in: .whitespaces)
        if !trimmed.lowercased().hasPrefix("http://") && !trimmed.lowercased().hasPrefix("https://") {
            trimmed = "https://" + trimmed
        }
        guard let url = URL(string: trimmed) else { return }
        openURL(url)
    }

    /// Uses `storedCoordinate` whenever one exists — which it always does
    /// for anything from search, Google or MapKit — so a map pin shows up
    /// immediately with no async work at all. Only a manually-added
    /// restaurant with just a typed address (no stored coordinate) falls
    /// back to on-device geocoding.
    private func geocodeIfNeeded() async {
        if let storedCoordinate {
            coordinate = storedCoordinate
            geocodingFailed = false
            return
        }
        guard let address, !address.isEmpty else {
            coordinate = nil
            return
        }
        geocodingFailed = false
        do {
            let placemarks = try await CLGeocoder().geocodeAddressString(address)
            coordinate = placemarks.first?.location?.coordinate
            geocodingFailed = coordinate == nil
        } catch {
            geocodingFailed = true
        }
    }

    private func loadDetailsIfNeeded() async {
        guard let googlePlaceID else { return }
        isLoadingDetails = true
        detailsErrorMessage = nil
        defer { isLoadingDetails = false }
        do {
            details = try await GooglePlacesService.placeDetails(placeID: googlePlaceID)
            // Backfills a website that wasn't already on file — only a real
            // saved `Restaurant` has anywhere to persist this
            // (`onWebsiteBackfilled`, `nil` for a search-result preview with
            // nothing to save to yet), and even then never overwrites a
            // website the user has since edited by hand.
            if (websiteURL?.isEmpty ?? true), let fetchedWebsiteURL = details?.websiteURL, !fetchedWebsiteURL.isEmpty {
                onWebsiteBackfilled?(fetchedWebsiteURL)
            }
        } catch {
            detailsErrorMessage = "Couldn't load hours, phone, or reviews right now."
        }
    }
}

/// A swipeable photo gallery — Google Maps-style paging with dot
/// indicators — for every photo Google has on file for this restaurant,
/// each fetched (via the backend proxy) only once actually swiped to.
private struct PhotoCarousel: View {
    let photoNames: [String]

    var body: some View {
        TabView {
            ForEach(photoNames, id: \.self) { photoName in
                if let url = GooglePlacesService.photoURL(for: photoName, maxWidthPx: 900) {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else {
                            Color.secondary.opacity(0.12)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                }
            }
        }
        .tabViewStyle(.page)
        .indexViewStyle(.page(backgroundDisplayMode: .always))
    }
}

private struct ReviewRow: View {
    let review: GooglePlacesService.PlaceDetails.Review

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(review.authorName)
                    .font(.brandSubheadline.bold())
                if let rating = review.rating {
                    Text(String(repeating: "★", count: rating) + String(repeating: "☆", count: max(0, 5 - rating)))
                        .font(.brandCaption)
                        .foregroundStyle(Color.brandHoney)
                }
                Spacer()
                if let relativeTime = review.relativeTime {
                    Text(relativeTime)
                        .font(.brandCaption)
                        .foregroundStyle(.secondary)
                }
            }
            if let text = review.text, !text.isEmpty {
                Text(text)
                    .font(.brandSubheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
