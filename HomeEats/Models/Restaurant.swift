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
    /// A stable Google Places photo resource name ("places/ID/photos/REF"),
    /// captured when this restaurant was added from a Google search result
    /// — `GooglePlacesService.photoURL(for:)` turns it into an actual
    /// image URL on demand rather than downloading/storing the image
    /// itself, so it costs nothing until someone actually views it.
    var googlePhotoName: String?

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
        googlePhotoName: String? = nil
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
        self.googlePhotoName = googlePhotoName
    }

    /// A single "Italian · $$ · ★★★★☆" line for list/detail display, Google
    /// Maps info-card style — only the pieces that are actually set.
    var descriptorLine: String? {
        var parts: [String] = []
        if let cuisine, !cuisine.isEmpty { parts.append(cuisine) }
        if let priceRange, !priceRange.isEmpty { parts.append(priceRange) }
        if let rating, rating > 0 {
            parts.append(String(repeating: "★", count: rating) + String(repeating: "☆", count: 5 - rating))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
