import Foundation
import CoreLocation

/// Talks to the Home Eats backend's Google Places proxy (see
/// backend/README.md) rather than Google directly — the backend holds the
/// real, billed API key so it never ships inside the app. If `baseURLString`
/// below is ever cleared back to empty, `isConfigured` goes false and
/// `RestaurantListView` falls back to Apple's free (but
/// rating/price/cuisine-less) MapKit search instead.
enum GooglePlacesService {
    private static let baseURLString = "https://home-eats-uqbp.onrender.com"

    static var isConfigured: Bool { !baseURLString.isEmpty }

    struct PlaceResult: Identifiable {
        let id: String
        let name: String
        let address: String?
        let rating: Double?
        /// "$" through "$$$$", already normalized by the backend from
        /// Google's price-level enum to match `Restaurant.priceRange`.
        let priceRange: String?
        let cuisine: String?
        let mapsURLString: String?
        let coordinate: CLLocationCoordinate2D?
        /// A stable Google photo resource name ("places/ID/photos/REF"), if
        /// this place has one — pass it to `photoURL(for:)` to build the
        /// actual image URL. Not the image itself: fetching real photo
        /// bytes is a separate, billed Google request, only worth making
        /// for a place someone actually adds.
        let photoName: String?
    }

    enum ServiceError: LocalizedError {
        case notConfigured
        case requestFailed

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Google search isn't set up yet."
            case .requestFailed:
                return "Couldn't search right now — check your connection."
            }
        }
    }

    static func search(_ query: String) async throws -> [PlaceResult] {
        guard isConfigured, let base = URL(string: baseURLString) else {
            throw ServiceError.notConfigured
        }
        var components = URLComponents(
            url: base.appendingPathComponent("restaurants/search"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components?.url else { throw ServiceError.requestFailed }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ServiceError.requestFailed
        }

        let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
        return decoded.results.map { raw in
            var coordinate: CLLocationCoordinate2D?
            if let latitude = raw.latitude, let longitude = raw.longitude {
                coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            }
            return PlaceResult(
                id: raw.id,
                name: raw.name,
                address: raw.address,
                rating: raw.rating,
                priceRange: (raw.priceRange?.isEmpty ?? true) ? nil : raw.priceRange,
                cuisine: raw.cuisine,
                mapsURLString: raw.mapsURL,
                coordinate: coordinate,
                photoName: raw.photoName
            )
        }
    }

    /// Builds the URL to actually load a photo's image bytes from — points
    /// at this same backend's `/restaurants/photo` proxy (never at Google
    /// directly, so the API key stays server-side), suitable for handing
    /// straight to `AsyncImage`. Returns `nil` if the backend isn't
    /// configured or `photoName` is empty.
    static func photoURL(for photoName: String, maxWidthPx: Int = 800) -> URL? {
        guard isConfigured, !photoName.isEmpty, let base = URL(string: baseURLString) else { return nil }
        var components = URLComponents(
            url: base.appendingPathComponent("restaurants/photo"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "name", value: photoName),
            URLQueryItem(name: "maxWidthPx", value: String(maxWidthPx))
        ]
        return components?.url
    }

    private struct SearchResponse: Decodable {
        let results: [RawResult]
    }

    private struct RawResult: Decodable {
        let id: String
        let name: String
        let address: String?
        let rating: Double?
        let priceRange: String?
        let cuisine: String?
        let mapsURL: String?
        let latitude: Double?
        let longitude: Double?
        let photoName: String?
    }
}
