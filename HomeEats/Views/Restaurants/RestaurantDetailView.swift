import SwiftUI
import MapKit
import CoreLocation
import SwiftData

/// Shows a restaurant's details: a map (using the coordinate captured when
/// it was added, so no on-device geocoding needed for anything found via
/// search — only a manually-typed address still needs that), plus — for a
/// restaurant added from Google — its hours, phone number, and reviews
/// pulled in directly, so seeing what other people think of the place
/// doesn't require leaving the app. "Open in Google Maps" is still there
/// for directions or the full photo/review gallery, but it's no longer the
/// only way to see a rating or a review.
struct RestaurantDetailView: View {
    @Bindable var restaurant: Restaurant

    @Environment(\.openURL) private var openURL
    @State private var showEditor = false
    @State private var coordinate: CLLocationCoordinate2D?
    @State private var geocodingFailed = false
    @State private var details: GooglePlacesService.PlaceDetails?
    @State private var isLoadingDetails = false
    @State private var detailsErrorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !restaurant.googlePhotoNames.isEmpty {
                    PhotoCarousel(photoNames: restaurant.googlePhotoNames)
                        .frame(height: 200)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }

                header

                mapSection

                actionButtons

                detailsSection

                if let notes = restaurant.notes, !notes.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Notes").font(.brandHeadline)
                        Text(notes)
                    }
                }
            }
            .padding()
        }
        .navigationTitle(restaurant.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") { showEditor = true }
            }
        }
        .sheet(isPresented: $showEditor) {
            RestaurantEditorView(existing: restaurant)
        }
        .task(id: restaurant.address) {
            await geocodeIfNeeded()
        }
        .task(id: restaurant.googlePlaceID) {
            await loadDetailsIfNeeded()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if let descriptorLine = restaurant.descriptorLine {
                    Text(descriptorLine)
                        .font(.brandSubheadline)
                        .foregroundStyle(.secondary)
                }
                if restaurant.isFavorite {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                        .font(.brandCaption)
                }
            }
            if let address = restaurant.address, !address.isEmpty {
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
                Marker(restaurant.name, coordinate: coordinate)
            }
            .frame(height: 200)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        } else if let address = restaurant.address, !address.isEmpty {
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

            if let websiteURL = restaurant.websiteURL, !websiteURL.isEmpty {
                Button {
                    openWebsite(websiteURL)
                } label: {
                    Label("Website", systemImage: "globe")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    /// Hours/phone/reviews, pulled directly from Google — only shown for a
    /// restaurant that actually has a `googlePlaceID` (added from a Google
    /// search result; a manual entry or a MapKit-fallback result has
    /// nothing to fetch here).
    @ViewBuilder
    private var detailsSection: some View {
        if restaurant.googlePlaceID != nil {
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
        let query = [restaurant.name, restaurant.address ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
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

    /// Uses the coordinate captured at add-time whenever one exists —
    /// which it always does for anything added via search, Google or
    /// MapKit — so a map pin shows up immediately with no async work at
    /// all. Only a restaurant with no stored coordinate (added by hand,
    /// with just a typed address) falls back to on-device geocoding.
    private func geocodeIfNeeded() async {
        if let latitude = restaurant.latitude, let longitude = restaurant.longitude {
            coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            geocodingFailed = false
            return
        }
        guard let address = restaurant.address, !address.isEmpty else {
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
        guard let placeID = restaurant.googlePlaceID else { return }
        isLoadingDetails = true
        detailsErrorMessage = nil
        defer { isLoadingDetails = false }
        do {
            details = try await GooglePlacesService.placeDetails(placeID: placeID)
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
