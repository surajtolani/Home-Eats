import Foundation
import SwiftData

/// A restaurant / eating-out option. Functions much like a Recipe in the
/// planner: it can be assigned to a day and viewed by the whole family.
@Model
final class Restaurant {
    @Attribute(.unique) var id: UUID
    var name: String
    var cuisine: String?
    /// "$" through "$$$$" — the household's own call, not pulled from
    /// anywhere: Apple's free local-search API (what this app uses instead
    /// of the paid Google Places API — see `RestaurantSearchModel`) doesn't
    /// expose price level or ratings, so there's no real "Google rating" to
    /// fetch here without a billed API key.
    var priceRange: String?
    /// The household's own 1–5 rating, same reason as `priceRange`.
    var rating: Int?
    var notes: String?
    var websiteURL: String?
    /// Free-text address, used to look the place up on a map and to build
    /// the "open in Google Maps" link.
    var address: String?
    var isFavorite: Bool
    var createdAt: Date
    /// Stable Google Places photo resource names ("places/ID/photos/REF"),
    /// captured when this restaurant was added from a Google search result
    /// — `GooglePlacesService.photoURL(for:)` turns each one into an
    /// actual image URL on demand rather than downloading/storing the
    /// images themselves, so browsing them costs nothing until someone
    /// actually swipes to a given photo. Empty for a restaurant added
    /// manually or via the MapKit fallback.
    var googlePhotoNames: [String] = []
    /// Google's own place ID, captured when added from a Google search
    /// result — lets the detail page fetch that place's hours/phone/
    /// reviews later via `GooglePlacesService.placeDetails(placeID:)`. Not
    /// set for a restaurant added manually or found via the MapKit
    /// fallback, since neither of those has a matching Google place.
    var googlePlaceID: String?
    /// Captured at add-time (from the search result, whichever source it
    /// came from) so the detail page can drop a map pin immediately
    /// without re-geocoding the address on every visit. `nil` for a
    /// manually-added restaurant with no coordinate to capture — the
    /// detail view falls back to geocoding `address` in that case.
    var latitude: Double?
    var longitude: Double?
    /// This restaurant's id on the backend's personal restaurant library
    /// (`POST /restaurants/library`'s response — see `AccountsAPIClient`),
    /// once it's ever been synced there. `nil` until `PersonalLibrarySyncService`
    /// first pushes this row; kept around after that so every later push is
    /// an update (`PATCH .../library/:id`) against the same server row
    /// instead of creating a duplicate. Optional with no explicit default
    /// needed for migration — same reasoning as `Recipe.backendRecipeID`'s
    /// own doc comment (a `String?` already defaults to `nil`, unlike a
    /// non-optional field, which needs an explicit default value right on
    /// the property declaration — see that field's doc comment, and
    /// `GroupSharedGroceryItem.quantityCount`'s, for the real incident that
    /// taught this codebase why).
    ///
    /// Added specifically so this restaurant survives a local-store reset
    /// and is recoverable across devices/reinstalls — previously, every
    /// restaurant lived purely on-device with no server copy at all. See
    /// `PersonalLibrarySyncService`'s own doc comment for the full sync
    /// design.
    var backendID: String?

    init(
        id: UUID = UUID(),
        name: String,
        cuisine: String? = nil,
        priceRange: String? = nil,
        rating: Int? = nil,
        notes: String? = nil,
        websiteURL: String? = nil,
        address: String? = nil,
        isFavorite: Bool = false,
        createdAt: Date = .now,
        googlePhotoNames: [String] = [],
        googlePlaceID: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        backendID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.cuisine = cuisine
        self.priceRange = priceRange
        self.rating = rating
        self.notes = notes
        self.websiteURL = websiteURL
        self.address = address
        self.isFavorite = isFavorite
        self.createdAt = createdAt
        self.googlePhotoNames = googlePhotoNames
        self.googlePlaceID = googlePlaceID
        self.latitude = latitude
        self.longitude = longitude
        self.backendID = backendID
    }

    /// "★★★★☆" for a 1–5 `rating` — factored out of `descriptorLine` so a
    /// caller that wants the star glyphs on their own (see
    /// `RestaurantListView.restaurantMetaItems`, which puts them on a
    /// different line than cuisine) doesn't re-derive the same
    /// repeat-count logic a second time.
    var starRatingText: String? {
        guard let rating, rating > 0 else { return nil }
        return String(repeating: "★", count: rating) + String(repeating: "☆", count: max(0, 5 - rating))
    }

    /// A single "Italian · $$ · ★★★★☆" line for list/detail display, Google
    /// Maps info-card style — only the pieces that are actually set.
    var descriptorLine: String? {
        var parts: [String] = []
        if let cuisine, !cuisine.isEmpty { parts.append(cuisine) }
        if let priceRange, !priceRange.isEmpty { parts.append(priceRange) }
        if let starRatingText { parts.append(starRatingText) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
