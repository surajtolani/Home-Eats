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
        /// The place's actual business website, if Google has one on file —
        /// distinct from `mapsURLString` (a Google Maps link). `nil` when
        /// Google doesn't have a website for this place.
        let websiteURLString: String?
        let coordinate: CLLocationCoordinate2D?
        /// Stable Google photo resource names ("places/ID/photos/REF"),
        /// every one this place has — pass each to `photoURL(for:)` to
        /// build its actual image URL. Not the images themselves: fetching
        /// real photo bytes is a separate, billed Google request per
        /// photo, only worth making for a place someone actually adds.
        let photoNames: [String]
    }

    /// The extra detail (beyond what a search result already carries) shown
    /// on a restaurant's own detail page — hours, phone, reviews — fetched
    /// only when that page is actually opened, since it's a separate
    /// billed Place Details request.
    struct PlaceDetails: Decodable {
        let rating: Double?
        let userRatingCount: Int?
        let phoneNumber: String?
        /// Pre-formatted lines from Google ("Monday: 9:00 AM – 9:00 PM"),
        /// one per day — shown as-is rather than re-parsed.
        let openingHours: [String]
        let reviews: [Review]
        let websiteURL: String?

        struct Review: Decodable, Identifiable {
            let authorName: String
            let rating: Int?
            let text: String?
            let relativeTime: String?
            var id: String { authorName + (relativeTime ?? "") + (text?.prefix(20) ?? "") }
        }
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
                websiteURLString: raw.websiteURL,
                coordinate: coordinate,
                photoNames: raw.photoNames ?? []
            )
        }
    }

    /// Fetches a restaurant's hours/phone/reviews for its detail page.
    /// `placeID` is a `PlaceResult.id` captured when the restaurant was
    /// added from a Google search result (saved as `Restaurant.googlePlaceID`)
    /// — there's nothing to fetch for a restaurant added manually or via
    /// the MapKit fallback, since neither has a matching Google place.
    static func placeDetails(placeID: String) async throws -> PlaceDetails {
        guard isConfigured, let base = URL(string: baseURLString) else {
            throw ServiceError.notConfigured
        }
        var components = URLComponents(
            url: base.appendingPathComponent("restaurants/details"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "placeId", value: placeID)]
        guard let url = components?.url else { throw ServiceError.requestFailed }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ServiceError.requestFailed
        }
        return try JSONDecoder().decode(PlaceDetails.self, from: data)
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
        let websiteURL: String?
        let latitude: Double?
        let longitude: Double?
        let photoNames: [String]?
    }
}
