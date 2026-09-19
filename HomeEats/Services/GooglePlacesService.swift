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

    /// `near`, when available, biases (and ranks) results toward that
    /// coordinate — without it, Google's Text Search ranks purely by
    /// text relevance, which is how a common restaurant name search could
    /// surface a same-named place on another continent above the one
    /// actually nearby.
    static func search(_ query: String, near coordinate: CLLocationCoordinate2D? = nil) async throws -> [PlaceResult] {
        guard isConfigured, let base = URL(string: baseURLString) else {
            throw ServiceError.notConfigured
        }
        var components = URLComponents(
            url: base.appendingPathComponent("restaurants/search"),
            resolvingAgainstBaseURL: false
        )
        var queryItems = [URLQueryItem(name: "q", value: query)]
        if let coordinate {
            queryItems.append(URLQueryItem(name: "lat", value: String(coordinate.latitude)))
            queryItems.append(URLQueryItem(name: "lng", value: String(coordinate.longitude)))
        }
        components?.queryItems = queryItems
        guard let url = components?.url else { throw ServiceError.requestFailed }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ServiceError.requestFailed
        }

        let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
        return decoded.results.map(makePlaceResult)
    }

    /// The free-text, "casual pizza near Greenwich" version of `search` —
    /// the backend asks Claude to pull a concrete search query and any
    /// specific place named out of the sentence, geocodes that place if
    /// there was one, and searches there (falling back to `near` — the
    /// app's best guess at the user's current location — only if the
    /// sentence didn't name a place of its own).
    static func searchNatural(
        _ query: String,
        near coordinate: CLLocationCoordinate2D? = nil
    ) async throws -> NaturalSearchResult {
        guard isConfigured, let base = URL(string: baseURLString) else {
            throw ServiceError.notConfigured
        }
        var request = URLRequest(url: base.appendingPathComponent("restaurants/search-natural"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["query": query]
        if let coordinate {
            body["lat"] = coordinate.latitude
            body["lng"] = coordinate.longitude
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ServiceError.requestFailed
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ServiceError.requestFailed
        }

        let decoded = try JSONDecoder().decode(NaturalSearchResponse.self, from: data)
        return NaturalSearchResult(
            results: decoded.results.map(makePlaceResult),
            interpretedQuery: decoded.interpretedQuery,
            interpretedLocation: decoded.interpretedLocation,
            locationGeocodeFailed: decoded.locationGeocodeFailed
        )
    }

    struct NaturalSearchResult {
        let results: [PlaceResult]
        /// What the backend actually searched for, after Claude cleaned up
        /// the sentence — handy to show back to the user as confirmation
        /// ("Searching for \"casual pizza\"…").
        let interpretedQuery: String
        /// A specific place Claude picked out of the sentence, if any
        /// ("Greenwich, CT") — `nil` when the request didn't name one and
        /// the app's own location was used instead.
        let interpretedLocation: String?
        /// True when `interpretedLocation` was set but the backend's
        /// geocoder couldn't resolve it to actual coordinates — direct,
        /// confirmed user report: asked for restaurants in "BGC area in
        /// Manila Philippines," got results from Greenwich instead,
        /// because the named location silently failed to geocode and the
        /// search fell back to the device's own current-location
        /// coordinates while still showing "Searching near BGC, Manila,
        /// Philippines" as if that had worked. The caller uses this to
        /// show that honestly instead of the misleading confirmation.
        let locationGeocodeFailed: Bool
    }

    private static func makePlaceResult(from raw: RawResult) -> PlaceResult {
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

    /// One suggestion row from `searchCities` — enough for a type-ahead
    /// dropdown showing a city name and its disambiguating context
    /// ("Greenwich" / "CT, USA") per row. `placeID` is what `cityDetails
    /// (placeID:)` needs to turn a tapped suggestion into an actual
    /// city/state/country triple.
    struct CitySuggestion: Decodable, Identifiable {
        let placeID: String
        let mainText: String
        let secondaryText: String?
        var id: String { placeID }
    }

    /// The result of resolving one `CitySuggestion` via Place Details —
    /// mirrors the backend's own `{ city, state, country }` shape exactly,
    /// optionality included: any of the three can legitimately be `nil` if
    /// Google's response had no matching address component for that place
    /// (see `GET /cities/:placeID` in backend/index.js). `CitySearchField`
    /// hands this straight to its caller, which is responsible for only
    /// overwriting a field/picker when the corresponding value here is
    /// non-nil — never blanking out something the user already picked just
    /// because Google didn't return it for this particular place.
    struct CityDetails: Decodable {
        let city: String?
        let state: String?
        let country: String?
    }

    /// Type-ahead city search — Places API (New) Autocomplete, restricted
    /// server-side to city-level results. Callers are expected to debounce
    /// their own keystrokes before calling this (see `CitySearchField`,
    /// which mirrors `RestaurantSearchModel.search`'s own 300ms debounce);
    /// this method itself fires immediately, exactly once, per call.
    static func searchCities(_ query: String) async throws -> [CitySuggestion] {
        guard isConfigured, let base = URL(string: baseURLString) else {
            throw ServiceError.notConfigured
        }
        var components = URLComponents(
            url: base.appendingPathComponent("cities/search"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components?.url else { throw ServiceError.requestFailed }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ServiceError.requestFailed
        }
        return try JSONDecoder().decode(CitySearchResponse.self, from: data).predictions
    }

    /// Resolves a tapped `CitySuggestion.placeID` into an actual
    /// city/state/country triple via Place Details — the call that makes
    /// "pre-populates everything" work, since a suggestion's own display
    /// text isn't reliably parseable into those three fields on its own
    /// (see the backend route's own doc comment for why).
    static func cityDetails(placeID: String) async throws -> CityDetails {
        guard isConfigured, let base = URL(string: baseURLString) else {
            throw ServiceError.notConfigured
        }
        let url = base.appendingPathComponent("cities").appendingPathComponent(placeID)

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ServiceError.requestFailed
        }
        return try JSONDecoder().decode(CityDetails.self, from: data)
    }

    private struct CitySearchResponse: Decodable {
        let predictions: [CitySuggestion]
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

    private struct NaturalSearchResponse: Decodable {
        let results: [RawResult]
        let interpretedQuery: String
        let interpretedLocation: String?
        let locationGeocodeFailed: Bool
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
