import SwiftUI
import MapKit
import CoreLocation
import SwiftData

/// Shows a restaurant's details with a real map of its location (via
/// on-device geocoding — no API key needed) plus a one-tap button that opens
/// the exact same spot in Google Maps for reviews, photos, and hours, since
/// that data isn't something Apple's free MapKit APIs expose.
struct RestaurantDetailView: View {
    @Bindable var restaurant: Restaurant

    @Environment(\.openURL) private var openURL
    @State private var showEditor = false
    @State private var coordinate: CLLocationCoordinate2D?
    @State private var geocodingFailed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                mapSection

                actionButtons

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
                Label("Google Maps & Reviews", systemImage: "star.bubble")
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

    private func geocodeIfNeeded() async {
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
}
